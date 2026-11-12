package main

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
)

func TestDownloadRetriesConnectionErrors(t *testing.T) {
	for _, shouldRecover := range []bool{true, false} {
		t.Run(fmt.Sprintf("recover=%t", shouldRecover), func(t *testing.T) {
			var attempts atomic.Int32
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if attempts.Add(1) < 3 || !shouldRecover {
					conn, _, err := w.(http.Hijacker).Hijack()
					if err != nil {
						t.Errorf("hijack connection: %v", err)
						return
					}
					conn.Close()
					return
				}
				fmt.Fprint(w, "downloaded")
			}))
			defer server.Close()

			path := filepath.Join(t.TempDir(), "download")
			err := download(server.URL, path)
			if (err == nil) != shouldRecover {
				t.Fatalf("download error = %v, recover = %t", err, shouldRecover)
			}
			if got := attempts.Load(); got != 3 {
				t.Fatalf("attempts = %d, want 3", got)
			}
			if shouldRecover {
				contents, err := os.ReadFile(path)
				if err != nil || string(contents) != "downloaded" {
					t.Fatalf("downloaded contents = %q, error = %v", contents, err)
				}
			}
		})
	}
}
