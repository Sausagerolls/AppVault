package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
	"unicode"
)

const (
	metaFile            = "meta.json"
	stagingDirName      = ".staging"
	defaultCategory     = "Uncategorized"
	maxNameBytes        = 200
	maxCategoryNameRune = 100
)

var (
	errNotFound      = errors.New("not found")
	errConflict      = errors.New("conflict")
	errBadName       = errors.New("invalid name")
	errCategoryInUse = errors.New("category is not empty")
)

// PartInfo describes one stored archive (app.tar or data.tar).
type PartInfo struct {
	Size   int64  `json:"size"`
	SHA256 string `json:"sha256"`
}

// Meta is the description of one stored item. It is written to
// <data>/<Category>/<Item>/meta.json and is the source of truth.
type Meta struct {
	ID            string              `json:"id"`
	Name          string              `json:"name"`
	Kind          string              `json:"kind"` // "app" or "folder"
	BundleID      string              `json:"bundleId,omitempty"`
	Version       string              `json:"version,omitempty"`
	Build         string              `json:"build,omitempty"`
	AppCategory   string              `json:"appCategory,omitempty"` // LSApplicationCategoryType
	Category      string              `json:"category"`
	OriginalPath  string              `json:"originalPath"`
	Fingerprint   string              `json:"fingerprint"`
	InstalledSize int64               `json:"installedSize"`
	DataPaths     []string            `json:"dataPaths,omitempty"` // relative to the user's home folder
	Parts         map[string]PartInfo `json:"parts"`
	HasIcon       bool                `json:"hasIcon"`
	Notes         string              `json:"notes,omitempty"`
	UploadedAt    time.Time           `json:"uploadedAt"`
}

func (m *Meta) storedBytes() int64 {
	var n int64
	for _, p := range m.Parts {
		n += p.Size
	}
	return n
}

// CategoryInfo is returned by the categories endpoint.
type CategoryInfo struct {
	Name      string `json:"name"`
	ItemCount int    `json:"itemCount"`
	Bytes     int64  `json:"bytes"`
}

// Store keeps an in-memory index of the library on disk.
type Store struct {
	mu    sync.RWMutex
	root  string
	items map[string]*Meta
	dirs  map[string]string // item id -> absolute directory
}

func NewStore(root string) (*Store, error) {
	s := &Store{root: root, items: map[string]*Meta{}, dirs: map[string]string{}}
	if err := os.MkdirAll(filepath.Join(root, stagingDirName), 0o775); err != nil {
		return nil, err
	}
	if err := os.MkdirAll(filepath.Join(root, defaultCategory), 0o775); err != nil {
		return nil, err
	}
	if err := s.scan(); err != nil {
		return nil, err
	}
	return s, nil
}

func (s *Store) stagingDir() string { return filepath.Join(s.root, stagingDirName) }

func (s *Store) scan() error {
	cats, err := os.ReadDir(s.root)
	if err != nil {
		return err
	}
	for _, c := range cats {
		if !c.IsDir() || strings.HasPrefix(c.Name(), ".") {
			continue
		}
		catDir := filepath.Join(s.root, c.Name())
		entries, err := os.ReadDir(catDir)
		if err != nil {
			logf("scan: %v", err)
			continue
		}
		for _, e := range entries {
			if !e.IsDir() || strings.HasPrefix(e.Name(), ".") {
				continue
			}
			dir := filepath.Join(catDir, e.Name())
			m, err := readMeta(dir)
			if err != nil {
				logf("scan: skipping %s: %v", dir, err)
				continue
			}
			if prev, dup := s.dirs[m.ID]; dup {
				logf("scan: duplicate id %s in %s and %s, skipping second", m.ID, prev, dir)
				continue
			}
			// Folder name wins over whatever meta.json says.
			if m.Category != c.Name() {
				m.Category = c.Name()
				_ = writeMeta(dir, m)
			}
			s.items[m.ID] = m
			s.dirs[m.ID] = dir
		}
	}
	logf("library loaded: %d items", len(s.items))
	return nil
}

func readMeta(dir string) (*Meta, error) {
	b, err := os.ReadFile(filepath.Join(dir, metaFile))
	if err != nil {
		return nil, err
	}
	var m Meta
	if err := json.Unmarshal(b, &m); err != nil {
		return nil, err
	}
	if m.ID == "" {
		return nil, errors.New("meta.json has no id")
	}
	if m.Parts == nil {
		m.Parts = map[string]PartInfo{}
	}
	return &m, nil
}

func writeMeta(dir string, m *Meta) error {
	b, err := json.MarshalIndent(m, "", "  ")
	if err != nil {
		return err
	}
	return writeFileAtomic(filepath.Join(dir, metaFile), b)
}

func writeFileAtomic(path string, b []byte) error {
	tmp := path + ".tmp"
	f, err := os.OpenFile(tmp, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o664)
	if err != nil {
		return err
	}
	if _, err := f.Write(b); err != nil {
		f.Close()
		return err
	}
	if err := f.Sync(); err != nil {
		f.Close()
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// ---- names ----

func validCategoryName(name string) (string, error) {
	name = strings.TrimSpace(name)
	if name == "" || strings.HasPrefix(name, ".") || len([]rune(name)) > maxCategoryNameRune {
		return "", errBadName
	}
	for _, r := range name {
		if r == '/' || r == '\\' || r == ':' || unicode.IsControl(r) {
			return "", errBadName
		}
	}
	return name, nil
}

// safeDirName turns an arbitrary display name into a single safe path component.
func safeDirName(name string) string {
	var b strings.Builder
	for _, r := range name {
		if r == '/' || r == '\\' || r == ':' || unicode.IsControl(r) {
			b.WriteRune('_')
		} else {
			b.WriteRune(r)
		}
	}
	out := strings.TrimLeft(strings.TrimSpace(b.String()), ".")
	for len(out) > maxNameBytes {
		r := []rune(out)
		out = string(r[:len(r)-1])
	}
	if out == "" {
		out = "item"
	}
	return out
}

// uniqueDir returns a not-yet-existing directory path inside parent.
func uniqueDir(parent, base string) string {
	p := filepath.Join(parent, base)
	for i := 2; ; i++ {
		if _, err := os.Lstat(p); os.IsNotExist(err) {
			return p
		}
		p = filepath.Join(parent, fmt.Sprintf("%s (%d)", base, i))
	}
}

// ---- categories ----

func (s *Store) Categories() ([]CategoryInfo, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	entries, err := os.ReadDir(s.root)
	if err != nil {
		return nil, err
	}
	byName := map[string]*CategoryInfo{}
	for _, e := range entries {
		if e.IsDir() && !strings.HasPrefix(e.Name(), ".") {
			byName[e.Name()] = &CategoryInfo{Name: e.Name()}
		}
	}
	for _, m := range s.items {
		c := byName[m.Category]
		if c == nil {
			c = &CategoryInfo{Name: m.Category}
			byName[m.Category] = c
		}
		c.ItemCount++
		c.Bytes += m.storedBytes()
	}
	out := make([]CategoryInfo, 0, len(byName))
	for _, c := range byName {
		out = append(out, *c)
	}
	sort.Slice(out, func(i, j int) bool { return strings.ToLower(out[i].Name) < strings.ToLower(out[j].Name) })
	return out, nil
}

func (s *Store) CreateCategory(name string) (string, error) {
	name, err := validCategoryName(name)
	if err != nil {
		return "", err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	return name, s.ensureCategoryLocked(name)
}

func (s *Store) ensureCategoryLocked(name string) error {
	return os.MkdirAll(filepath.Join(s.root, name), 0o775)
}

func (s *Store) RenameCategory(oldName, newName string) error {
	newName, err := validCategoryName(newName)
	if err != nil {
		return err
	}
	if _, err := validCategoryName(oldName); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	oldDir := filepath.Join(s.root, oldName)
	newDir := filepath.Join(s.root, newName)
	if _, err := os.Stat(oldDir); err != nil {
		return errNotFound
	}
	if _, err := os.Lstat(newDir); err == nil && !strings.EqualFold(oldName, newName) {
		return errConflict
	}
	if err := os.Rename(oldDir, newDir); err != nil {
		return err
	}
	for id, m := range s.items {
		if m.Category == oldName {
			m.Category = newName
			dir := filepath.Join(newDir, filepath.Base(s.dirs[id]))
			s.dirs[id] = dir
			if err := writeMeta(dir, m); err != nil {
				logf("rename category: meta write failed for %s: %v", id, err)
			}
		}
	}
	return nil
}

func (s *Store) DeleteCategory(name string) error {
	if _, err := validCategoryName(name); err != nil {
		return err
	}
	if name == defaultCategory {
		return errConflict
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, m := range s.items {
		if m.Category == name {
			return errCategoryInUse
		}
	}
	dir := filepath.Join(s.root, name)
	if _, err := os.Stat(dir); err != nil {
		return errNotFound
	}
	// Remove harmless junk files (e.g. .DS_Store) but never real content.
	entries, _ := os.ReadDir(dir)
	for _, e := range entries {
		if !e.IsDir() && strings.HasPrefix(e.Name(), ".") {
			_ = os.Remove(filepath.Join(dir, e.Name()))
		}
	}
	if err := os.Remove(dir); err != nil {
		return errCategoryInUse
	}
	return nil
}

// ---- items ----

func (s *Store) List() []*Meta {
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := make([]*Meta, 0, len(s.items))
	for _, m := range s.items {
		c := *m
		out = append(out, &c)
	}
	sort.Slice(out, func(i, j int) bool { return strings.ToLower(out[i].Name) < strings.ToLower(out[j].Name) })
	return out
}

func (s *Store) Get(id string) (*Meta, string, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	m, ok := s.items[id]
	if !ok {
		return nil, "", errNotFound
	}
	c := *m
	return &c, s.dirs[id], nil
}

type ItemPatch struct {
	Category *string `json:"category"`
	Notes    *string `json:"notes"`
}

func (s *Store) Update(id string, p ItemPatch) (*Meta, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	m, ok := s.items[id]
	if !ok {
		return nil, errNotFound
	}
	dir := s.dirs[id]
	if p.Category != nil && *p.Category != m.Category {
		cat, err := validCategoryName(*p.Category)
		if err != nil {
			return nil, err
		}
		if err := s.ensureCategoryLocked(cat); err != nil {
			return nil, err
		}
		newDir := uniqueDir(filepath.Join(s.root, cat), filepath.Base(dir))
		if err := os.Rename(dir, newDir); err != nil {
			return nil, err
		}
		dir = newDir
		s.dirs[id] = dir
		m.Category = cat
	}
	if p.Notes != nil {
		m.Notes = *p.Notes
	}
	if err := writeMeta(dir, m); err != nil {
		return nil, err
	}
	c := *m
	return &c, nil
}

func (s *Store) Delete(id string) error {
	s.mu.Lock()
	dir, ok := s.dirs[id]
	if !ok {
		s.mu.Unlock()
		return errNotFound
	}
	// Move out of the library first so the delete looks atomic to clients.
	trash := filepath.Join(s.stagingDir(), "trash-"+id+"-"+randomID()[:8])
	err := os.Rename(dir, trash)
	if err == nil {
		delete(s.items, id)
		delete(s.dirs, id)
	}
	s.mu.Unlock()
	if err != nil {
		return err
	}
	go func() {
		if err := os.RemoveAll(trash); err != nil {
			logf("delete: cleanup of %s failed: %v", trash, err)
		}
	}()
	return nil
}

// Install moves a finished upload's files into the library.
// files maps the stored file name (app.tar, data.tar, icon.png) to its staged path.
func (s *Store) Install(m *Meta, replaces string, files map[string]string) (*Meta, error) {
	cat, err := validCategoryName(m.Category)
	if err != nil {
		cat = defaultCategory
	}
	m.Category = cat

	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.ensureCategoryLocked(cat); err != nil {
		return nil, err
	}

	var oldTrash string
	if replaces != "" {
		if oldDir, ok := s.dirs[replaces]; ok {
			oldTrash = filepath.Join(s.stagingDir(), "trash-"+replaces+"-"+randomID()[:8])
			if err := os.Rename(oldDir, oldTrash); err != nil {
				return nil, fmt.Errorf("moving old version aside: %w", err)
			}
			delete(s.items, replaces)
			delete(s.dirs, replaces)
			m.ID = replaces
		}
	}
	if m.ID == "" {
		m.ID = randomID()
	}

	dir := uniqueDir(filepath.Join(s.root, cat), safeDirName(m.Name))
	rollback := func() {
		_ = os.RemoveAll(dir)
		if oldTrash != "" {
			if old, err := readMeta(oldTrash); err == nil {
				restored := uniqueDir(filepath.Join(s.root, old.Category), safeDirName(old.Name))
				if os.Rename(oldTrash, restored) == nil {
					s.items[old.ID] = old
					s.dirs[old.ID] = restored
				}
			}
		}
	}
	if err := os.MkdirAll(dir, 0o775); err != nil {
		rollback()
		return nil, err
	}
	for name, src := range files {
		if err := os.Rename(src, filepath.Join(dir, name)); err != nil {
			rollback()
			return nil, fmt.Errorf("moving %s into library: %w", name, err)
		}
	}
	m.UploadedAt = time.Now().UTC()
	if err := writeMeta(dir, m); err != nil {
		rollback()
		return nil, err
	}
	s.items[m.ID] = m
	s.dirs[m.ID] = dir
	if oldTrash != "" {
		go func() { _ = os.RemoveAll(oldTrash) }()
	}
	c := *m
	return &c, nil
}

func (s *Store) LibraryBytes() (int64, int) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	var n int64
	for _, m := range s.items {
		n += m.storedBytes()
	}
	return n, len(s.items)
}
