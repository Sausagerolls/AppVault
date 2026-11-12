package main

import (
	"crypto/sha256"
	"encoding"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"hash"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// Resumable upload sessions.
//
// Each session lives in <data>/.staging/<id>/ :
//   session.json      upload metadata
//   app.tar           bytes received so far for part "app"
//   app.tar.state     {offset, sha256 state} saved after every chunk
//   data.tar(.state)  same for optional part "data"
//   icon.png          optional icon
//
// The SHA-256 state is saved together with the offset, so a session
// survives container restarts and the final hash never needs a re-read.

var uploadParts = map[string]string{"app": "app.tar", "data": "data.tar"}

const staleUploadAge = 30 * 24 * time.Hour

type UploadSession struct {
	ID       string    `json:"id"`
	Meta     Meta      `json:"meta"`
	Replaces string    `json:"replaces,omitempty"`
	Created  time.Time `json:"created"`

	dir   string
	mu    sync.Mutex
	parts map[string]*partState
}

type partState struct {
	offset int64
	h      hash.Hash
}

type partStateFile struct {
	Offset int64  `json:"offset"`
	State  string `json:"state"` // base64 of sha256 MarshalBinary
}

// UploadView is the JSON shape returned to clients.
type UploadView struct {
	ID       string           `json:"id"`
	Meta     Meta             `json:"meta"`
	Replaces string           `json:"replaces,omitempty"`
	Created  time.Time        `json:"created"`
	Offsets  map[string]int64 `json:"offsets"`
}

type Uploads struct {
	mu       sync.Mutex
	store    *Store
	sessions map[string]*UploadSession
}

func NewUploads(store *Store) *Uploads {
	u := &Uploads{store: store, sessions: map[string]*UploadSession{}}
	u.load()
	return u
}

func (u *Uploads) load() {
	entries, err := os.ReadDir(u.store.stagingDir())
	if err != nil {
		return
	}
	for _, e := range entries {
		dir := filepath.Join(u.store.stagingDir(), e.Name())
		if strings.HasPrefix(e.Name(), "trash-") {
			_ = os.RemoveAll(dir) // leftovers from an interrupted delete
			continue
		}
		if !e.IsDir() {
			continue
		}
		s, err := loadSession(dir)
		if err != nil {
			logf("uploads: dropping broken session %s: %v", e.Name(), err)
			_ = os.RemoveAll(dir)
			continue
		}
		if time.Since(s.Created) > staleUploadAge {
			logf("uploads: dropping stale session %s (%s)", s.ID, s.Meta.Name)
			_ = os.RemoveAll(dir)
			continue
		}
		u.sessions[s.ID] = s
	}
	if len(u.sessions) > 0 {
		logf("uploads: %d unfinished session(s) can be resumed", len(u.sessions))
	}
}

func loadSession(dir string) (*UploadSession, error) {
	b, err := os.ReadFile(filepath.Join(dir, "session.json"))
	if err != nil {
		return nil, err
	}
	var s UploadSession
	if err := json.Unmarshal(b, &s); err != nil {
		return nil, err
	}
	s.dir = dir
	s.parts = map[string]*partState{}
	for part, file := range uploadParts {
		ps, err := loadPartState(filepath.Join(dir, file))
		if err != nil {
			return nil, fmt.Errorf("part %s: %w", part, err)
		}
		s.parts[part] = ps
	}
	return &s, nil
}

func loadPartState(dataPath string) (*partState, error) {
	ps := &partState{h: sha256.New()}
	b, err := os.ReadFile(dataPath + ".state")
	if errors.Is(err, os.ErrNotExist) {
		// No state yet: anything in the data file is unverified, start over.
		_ = os.Remove(dataPath)
		return ps, nil
	}
	if err != nil {
		return nil, err
	}
	var sf partStateFile
	if err := json.Unmarshal(b, &sf); err != nil {
		return nil, err
	}
	raw, err := base64.StdEncoding.DecodeString(sf.State)
	if err != nil {
		return nil, err
	}
	if err := ps.h.(encoding.BinaryUnmarshaler).UnmarshalBinary(raw); err != nil {
		return nil, err
	}
	ps.offset = sf.Offset
	fi, err := os.Stat(dataPath)
	if err != nil {
		if ps.offset == 0 {
			return ps, nil
		}
		return nil, err
	}
	switch {
	case fi.Size() > ps.offset:
		// Crash after writing data but before saving state: drop the tail.
		if err := os.Truncate(dataPath, ps.offset); err != nil {
			return nil, err
		}
	case fi.Size() < ps.offset:
		return nil, errors.New("data file shorter than saved offset")
	}
	return ps, nil
}

func (s *UploadSession) savePartState(part string) error {
	ps := s.parts[part]
	raw, err := ps.h.(encoding.BinaryMarshaler).MarshalBinary()
	if err != nil {
		return err
	}
	b, _ := json.Marshal(partStateFile{Offset: ps.offset, State: base64.StdEncoding.EncodeToString(raw)})
	return writeFileAtomic(filepath.Join(s.dir, uploadParts[part])+".state", b)
}

func (s *UploadSession) view() UploadView {
	s.mu.Lock()
	defer s.mu.Unlock()
	v := UploadView{ID: s.ID, Meta: s.Meta, Replaces: s.Replaces, Created: s.Created, Offsets: map[string]int64{}}
	for p, ps := range s.parts {
		v.Offsets[p] = ps.offset
	}
	return v
}

type CreateUploadRequest struct {
	Meta          Meta   `json:"meta"`
	Replaces      string `json:"replaces"`
	ExpectedBytes int64  `json:"expectedBytes"`
}

var errNoSpace = errors.New("not enough free space on server")

func (u *Uploads) Create(req CreateUploadRequest) (*UploadSession, error) {
	if strings.TrimSpace(req.Meta.Name) == "" {
		return nil, errors.New("meta.name is required")
	}
	if req.Meta.Kind != "app" && req.Meta.Kind != "folder" {
		return nil, errors.New(`meta.kind must be "app" or "folder"`)
	}
	if req.ExpectedBytes > 0 {
		if _, free, err := diskSpace(u.store.root); err == nil && free < uint64(req.ExpectedBytes)+(1<<30) {
			return nil, errNoSpace
		}
	}
	req.Meta.ID = ""
	req.Meta.Parts = nil
	req.Meta.HasIcon = false

	s := &UploadSession{
		ID:       randomID(),
		Meta:     req.Meta,
		Replaces: req.Replaces,
		Created:  time.Now().UTC(),
		parts:    map[string]*partState{},
	}
	s.dir = filepath.Join(u.store.stagingDir(), s.ID)
	if err := os.MkdirAll(s.dir, 0o775); err != nil {
		return nil, err
	}
	b, _ := json.MarshalIndent(s, "", "  ")
	if err := writeFileAtomic(filepath.Join(s.dir, "session.json"), b); err != nil {
		_ = os.RemoveAll(s.dir)
		return nil, err
	}
	for p := range uploadParts {
		s.parts[p] = &partState{h: sha256.New()}
	}
	u.mu.Lock()
	u.sessions[s.ID] = s
	u.mu.Unlock()
	return s, nil
}

func (u *Uploads) Get(id string) (*UploadSession, error) {
	u.mu.Lock()
	defer u.mu.Unlock()
	s, ok := u.sessions[id]
	if !ok {
		return nil, errNotFound
	}
	return s, nil
}

func (u *Uploads) List() []UploadView {
	u.mu.Lock()
	list := make([]*UploadSession, 0, len(u.sessions))
	for _, s := range u.sessions {
		list = append(list, s)
	}
	u.mu.Unlock()
	out := make([]UploadView, 0, len(list))
	for _, s := range list {
		out = append(out, s.view())
	}
	return out
}

func (u *Uploads) Abort(id string) error {
	u.mu.Lock()
	s, ok := u.sessions[id]
	delete(u.sessions, id)
	u.mu.Unlock()
	if !ok {
		return errNotFound
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	return os.RemoveAll(s.dir)
}

// OffsetMismatch is returned when a chunk does not start where the server expects.
type OffsetMismatch struct{ Expected int64 }

func (e *OffsetMismatch) Error() string {
	return fmt.Sprintf("offset mismatch, expected %d", e.Expected)
}

// Append writes body to the end of part, if offset matches. It returns the
// new offset. A partially received body still counts: the client asks for
// the new offset and continues from there.
func (s *UploadSession) Append(part string, offset int64, body io.Reader) (int64, error) {
	file, ok := uploadParts[part]
	if !ok {
		return 0, errNotFound
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	ps := s.parts[part]
	if offset != ps.offset {
		return ps.offset, &OffsetMismatch{Expected: ps.offset}
	}
	path := filepath.Join(s.dir, file)
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY, 0o664)
	if err != nil {
		return ps.offset, err
	}
	defer f.Close()
	if _, err := f.Seek(ps.offset, io.SeekStart); err != nil {
		return ps.offset, err
	}

	// fileHashWriter feeds the hash exactly the bytes the file accepted,
	// so file and hash stay in step even on a short write.
	n, copyErr := io.Copy(&fileHashWriter{f: f, h: ps.h}, body)
	err = f.Truncate(ps.offset + n)
	if err == nil {
		err = f.Sync()
	}
	if err != nil {
		// Hash is now ahead of what is safely on disk: reload saved state.
		if fresh, e := loadPartState(path); e == nil {
			s.parts[part] = fresh
			return fresh.offset, err
		}
		return ps.offset, err
	}
	ps.offset += n
	if err := s.savePartState(part); err != nil {
		return ps.offset, err
	}
	return ps.offset, copyErr
}

type fileHashWriter struct {
	f *os.File
	h hash.Hash
}

func (w *fileHashWriter) Write(p []byte) (int, error) {
	n, err := w.f.Write(p)
	w.h.Write(p[:n])
	return n, err
}

func (s *UploadSession) PutIcon(body io.Reader) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	b, err := io.ReadAll(io.LimitReader(body, 8<<20))
	if err != nil {
		return err
	}
	if len(b) == 0 {
		return errors.New("empty icon")
	}
	if err := writeFileAtomic(filepath.Join(s.dir, "icon.png"), b); err != nil {
		return err
	}
	s.Meta.HasIcon = true
	return nil
}

type CompleteRequest struct {
	Parts map[string]PartInfo `json:"parts"`
}

type VerifyError struct{ Msg string }

func (e *VerifyError) Error() string { return e.Msg }

func (u *Uploads) Complete(id string, req CompleteRequest) (*Meta, error) {
	s, err := u.Get(id)
	if err != nil {
		return nil, err
	}
	s.mu.Lock()
	if _, ok := req.Parts["app"]; !ok {
		s.mu.Unlock()
		return nil, &VerifyError{"part \"app\" is required"}
	}
	files := map[string]string{}
	parts := map[string]PartInfo{}
	for part, want := range req.Parts {
		file, ok := uploadParts[part]
		if !ok {
			s.mu.Unlock()
			return nil, &VerifyError{"unknown part " + part}
		}
		ps := s.parts[part]
		got := hex.EncodeToString(ps.h.Sum(nil))
		if ps.offset != want.Size {
			s.mu.Unlock()
			return nil, &VerifyError{fmt.Sprintf("part %s: server has %d bytes, client sent %d", part, ps.offset, want.Size)}
		}
		if !strings.EqualFold(got, want.SHA256) {
			s.mu.Unlock()
			return nil, &VerifyError{fmt.Sprintf("part %s: checksum mismatch (server %s, client %s)", part, got, want.SHA256)}
		}
		path := filepath.Join(s.dir, file)
		if want.Size == 0 {
			// Ensure an empty file exists for zero-length parts.
			if f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY, 0o664); err == nil {
				f.Close()
			}
		}
		files[file] = path
		parts[part] = PartInfo{Size: want.Size, SHA256: strings.ToLower(got)}
	}
	if s.Meta.HasIcon {
		files["icon.png"] = filepath.Join(s.dir, "icon.png")
	}
	meta := s.Meta
	meta.Parts = parts
	replaces := s.Replaces
	s.mu.Unlock()

	installed, err := u.store.Install(&meta, replaces, files)
	if err != nil {
		return nil, err
	}
	u.mu.Lock()
	delete(u.sessions, id)
	u.mu.Unlock()
	_ = os.RemoveAll(s.dir)
	return installed, nil
}
