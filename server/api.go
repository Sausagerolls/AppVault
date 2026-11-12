package main

import (
	"crypto/subtle"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

const maxChunkBytes = 1 << 30 // 1 GiB per PATCH request

type API struct {
	store   *Store
	uploads *Uploads
	token   string
}

func (a *API) Routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/health", a.health)

	auth := func(pattern string, h http.HandlerFunc) { mux.Handle(pattern, a.requireToken(h)) }

	auth("GET /api/stats", a.stats)

	auth("GET /api/categories", a.listCategories)
	auth("POST /api/categories", a.createCategory)
	auth("PATCH /api/categories/{name}", a.renameCategory)
	auth("DELETE /api/categories/{name}", a.deleteCategory)

	auth("GET /api/items", a.listItems)
	auth("GET /api/items/{id}", a.getItem)
	auth("PATCH /api/items/{id}", a.updateItem)
	auth("DELETE /api/items/{id}", a.deleteItem)
	auth("GET /api/items/{id}/icon", a.getIcon)
	auth("GET /api/items/{id}/parts/{part}", a.getPart)

	auth("GET /api/uploads", a.listUploads)
	auth("POST /api/uploads", a.createUpload)
	auth("GET /api/uploads/{id}", a.getUpload)
	auth("DELETE /api/uploads/{id}", a.abortUpload)
	auth("PATCH /api/uploads/{id}/parts/{part}", a.appendPart)
	auth("PUT /api/uploads/{id}/icon", a.putIcon)
	auth("POST /api/uploads/{id}/complete", a.completeUpload)

	return logRequests(mux)
}

func (a *API) requireToken(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
		if subtle.ConstantTimeCompare([]byte(got), []byte(a.token)) != 1 {
			writeErr(w, http.StatusUnauthorized, "missing or wrong token")
			return
		}
		next.ServeHTTP(w, r)
	})
}

// ---- helpers ----

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeErr(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}

func writeStoreErr(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, errNotFound):
		writeErr(w, http.StatusNotFound, err.Error())
	case errors.Is(err, errConflict):
		writeErr(w, http.StatusConflict, "name already exists or is reserved")
	case errors.Is(err, errCategoryInUse):
		writeErr(w, http.StatusConflict, err.Error())
	case errors.Is(err, errBadName):
		writeErr(w, http.StatusBadRequest, err.Error())
	case errors.Is(err, errNoSpace):
		writeErr(w, http.StatusInsufficientStorage, err.Error())
	default:
		logf("error: %v", err)
		writeErr(w, http.StatusInternalServerError, err.Error())
	}
}

func decode(w http.ResponseWriter, r *http.Request, v any) bool {
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<20)).Decode(v); err != nil {
		writeErr(w, http.StatusBadRequest, "bad JSON: "+err.Error())
		return false
	}
	return true
}

// ---- general ----

func (a *API) health(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, 200, map[string]any{"ok": true, "version": version})
}

func (a *API) stats(w http.ResponseWriter, r *http.Request) {
	total, free, err := diskSpace(a.store.root)
	if err != nil {
		writeStoreErr(w, err)
		return
	}
	lib, count := a.store.LibraryBytes()
	writeJSON(w, 200, map[string]any{
		"totalBytes":   total,
		"freeBytes":    free,
		"libraryBytes": lib,
		"itemCount":    count,
		"version":      version,
	})
}

// ---- categories ----

func (a *API) listCategories(w http.ResponseWriter, r *http.Request) {
	cats, err := a.store.Categories()
	if err != nil {
		writeStoreErr(w, err)
		return
	}
	writeJSON(w, 200, cats)
}

func (a *API) createCategory(w http.ResponseWriter, r *http.Request) {
	var body struct{ Name string }
	if !decode(w, r, &body) {
		return
	}
	name, err := a.store.CreateCategory(body.Name)
	if err != nil {
		writeStoreErr(w, err)
		return
	}
	writeJSON(w, 201, CategoryInfo{Name: name})
}

func (a *API) renameCategory(w http.ResponseWriter, r *http.Request) {
	var body struct{ Name string }
	if !decode(w, r, &body) {
		return
	}
	if err := a.store.RenameCategory(r.PathValue("name"), body.Name); err != nil {
		writeStoreErr(w, err)
		return
	}
	writeJSON(w, 200, map[string]string{"name": strings.TrimSpace(body.Name)})
}

func (a *API) deleteCategory(w http.ResponseWriter, r *http.Request) {
	if err := a.store.DeleteCategory(r.PathValue("name")); err != nil {
		writeStoreErr(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// ---- items ----

func (a *API) listItems(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, 200, a.store.List())
}

func (a *API) getItem(w http.ResponseWriter, r *http.Request) {
	m, _, err := a.store.Get(r.PathValue("id"))
	if err != nil {
		writeStoreErr(w, err)
		return
	}
	writeJSON(w, 200, m)
}

func (a *API) updateItem(w http.ResponseWriter, r *http.Request) {
	var p ItemPatch
	if !decode(w, r, &p) {
		return
	}
	m, err := a.store.Update(r.PathValue("id"), p)
	if err != nil {
		writeStoreErr(w, err)
		return
	}
	writeJSON(w, 200, m)
}

func (a *API) deleteItem(w http.ResponseWriter, r *http.Request) {
	if err := a.store.Delete(r.PathValue("id")); err != nil {
		writeStoreErr(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (a *API) getIcon(w http.ResponseWriter, r *http.Request) {
	m, dir, err := a.store.Get(r.PathValue("id"))
	if err != nil || !m.HasIcon {
		writeErr(w, 404, "no icon")
		return
	}
	w.Header().Set("Content-Type", "image/png")
	w.Header().Set("Cache-Control", "private, max-age=86400")
	http.ServeFile(w, r, filepath.Join(dir, "icon.png"))
}

// getPart streams app.tar / data.tar. http.ServeContent handles Range and
// If-Range, which the Mac client uses to resume interrupted downloads.
func (a *API) getPart(w http.ResponseWriter, r *http.Request) {
	m, dir, err := a.store.Get(r.PathValue("id"))
	if err != nil {
		writeStoreErr(w, err)
		return
	}
	part := r.PathValue("part")
	info, ok := m.Parts[part]
	file, known := uploadParts[part]
	if !ok || !known {
		writeErr(w, 404, "no such part")
		return
	}
	f, err := os.Open(filepath.Join(dir, file))
	if err != nil {
		writeStoreErr(w, err)
		return
	}
	defer f.Close()
	w.Header().Set("Content-Type", "application/x-tar")
	w.Header().Set("ETag", `"`+info.SHA256+`"`)
	w.Header().Set("X-Content-SHA256", info.SHA256)
	http.ServeContent(w, r, file, m.UploadedAt, f)
}

// ---- uploads ----

func (a *API) listUploads(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, 200, a.uploads.List())
}

func (a *API) createUpload(w http.ResponseWriter, r *http.Request) {
	var req CreateUploadRequest
	if !decode(w, r, &req) {
		return
	}
	s, err := a.uploads.Create(req)
	if err != nil {
		if errors.Is(err, errNoSpace) {
			writeStoreErr(w, err)
		} else {
			writeErr(w, 400, err.Error())
		}
		return
	}
	logf("upload %s started: %s -> %s", s.ID, s.Meta.Name, s.Meta.Category)
	writeJSON(w, 201, s.view())
}

func (a *API) getUpload(w http.ResponseWriter, r *http.Request) {
	s, err := a.uploads.Get(r.PathValue("id"))
	if err != nil {
		writeStoreErr(w, err)
		return
	}
	writeJSON(w, 200, s.view())
}

func (a *API) abortUpload(w http.ResponseWriter, r *http.Request) {
	if err := a.uploads.Abort(r.PathValue("id")); err != nil {
		writeStoreErr(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (a *API) appendPart(w http.ResponseWriter, r *http.Request) {
	s, err := a.uploads.Get(r.PathValue("id"))
	if err != nil {
		writeStoreErr(w, err)
		return
	}
	offset, err := strconv.ParseInt(r.URL.Query().Get("offset"), 10, 64)
	if err != nil || offset < 0 {
		writeErr(w, 400, "offset query parameter required")
		return
	}
	body := http.MaxBytesReader(w, r.Body, maxChunkBytes)
	newOffset, err := s.Append(r.PathValue("part"), offset, body)
	var mismatch *OffsetMismatch
	switch {
	case errors.As(err, &mismatch):
		writeJSON(w, http.StatusConflict, map[string]any{"error": err.Error(), "offset": mismatch.Expected})
	case errors.Is(err, errNotFound):
		writeErr(w, 404, "unknown part")
	case err != nil:
		// Body was cut off or disk failed. Report how far we got.
		logf("upload %s: append stopped at %d: %v", s.ID, newOffset, err)
		writeJSON(w, http.StatusUnprocessableEntity, map[string]any{"error": err.Error(), "offset": newOffset})
	default:
		writeJSON(w, 200, map[string]int64{"offset": newOffset})
	}
}

func (a *API) putIcon(w http.ResponseWriter, r *http.Request) {
	s, err := a.uploads.Get(r.PathValue("id"))
	if err != nil {
		writeStoreErr(w, err)
		return
	}
	if err := s.PutIcon(r.Body); err != nil {
		writeErr(w, 400, err.Error())
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (a *API) completeUpload(w http.ResponseWriter, r *http.Request) {
	var req CompleteRequest
	if !decode(w, r, &req) {
		return
	}
	m, err := a.uploads.Complete(r.PathValue("id"), req)
	var verr *VerifyError
	switch {
	case errors.As(err, &verr):
		writeErr(w, http.StatusUnprocessableEntity, verr.Msg)
	case err != nil:
		writeStoreErr(w, err)
	default:
		logf("upload %s complete: %s (%s) in %s", r.PathValue("id"), m.Name, humanBytes(m.storedBytes()), m.Category)
		writeJSON(w, 200, m)
	}
}

// ---- logging ----

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (s *statusRecorder) WriteHeader(code int) {
	s.status = code
	s.ResponseWriter.WriteHeader(code)
}

// ReadFrom keeps sendfile fast paths working through the wrapper.
func (s *statusRecorder) ReadFrom(r io.Reader) (int64, error) {
	if rf, ok := s.ResponseWriter.(io.ReaderFrom); ok {
		return rf.ReadFrom(r)
	}
	return io.Copy(s.ResponseWriter, r)
}

func (s *statusRecorder) Unwrap() http.ResponseWriter { return s.ResponseWriter }

func logRequests(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, status: 200}
		next.ServeHTTP(rec, r)
		if r.URL.Path == "/api/health" {
			return
		}
		logf("%s %s %d %s", r.Method, r.URL.Path, rec.status, time.Since(start).Round(time.Millisecond))
	})
}
