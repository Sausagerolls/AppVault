package main

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"log"
	"net/http"
	"os"
	"syscall"
	"time"
)

const version = "1.0.0"

func logf(format string, args ...any) { log.Printf(format, args...) }

func env(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func randomID() string {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return hex.EncodeToString(b)
}

func diskSpace(path string) (total, free uint64, err error) {
	var st syscall.Statfs_t
	if err = syscall.Statfs(path, &st); err != nil {
		return
	}
	return uint64(st.Blocks) * uint64(st.Bsize), uint64(st.Bavail) * uint64(st.Bsize), nil
}

func humanBytes(n int64) string {
	const unit = 1024
	if n < unit {
		return fmt.Sprintf("%d B", n)
	}
	div, exp := int64(unit), 0
	for m := n / unit; m >= unit; m /= unit {
		div *= unit
		exp++
	}
	return fmt.Sprintf("%.1f %ciB", float64(n)/float64(div), "KMGTPE"[exp])
}

func main() {
	port := env("APPVAULT_PORT", "8420")

	if len(os.Args) > 1 && os.Args[1] == "healthcheck" {
		c := http.Client{Timeout: 5 * time.Second}
		resp, err := c.Get("http://127.0.0.1:" + port + "/api/health")
		if err != nil || resp.StatusCode != 200 {
			os.Exit(1)
		}
		os.Exit(0)
	}

	dataDir := env("APPVAULT_DATA", "/data")
	token := os.Getenv("APPVAULT_TOKEN")
	if len(token) < 16 {
		log.Fatal("APPVAULT_TOKEN must be set to a secret of at least 16 characters")
	}

	store, err := NewStore(dataDir)
	if err != nil {
		log.Fatalf("cannot open library at %s: %v", dataDir, err)
	}
	api := &API{store: store, uploads: NewUploads(store), token: token}

	srv := &http.Server{
		Addr:              ":" + port,
		Handler:           api.Routes(),
		ReadHeaderTimeout: 30 * time.Second,
		IdleTimeout:       120 * time.Second,
		// No Read/Write timeouts: archives can be hundreds of GB.
	}
	logf("AppVault server %s listening on :%s, library %s", version, port, dataDir)
	log.Fatal(srv.ListenAndServe())
}
