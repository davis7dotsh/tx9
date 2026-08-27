package cli

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/davis7dotsh/tx9/internal/docker"
	"github.com/davis7dotsh/tx9/internal/state"
)

func TestPruneSkipsInvalidStateNamesAndContinues(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	if err := state.WriteBoxEnv("orphan", map[string]string{"key": "value"}); err != nil {
		t.Fatal(err)
	}
	dir, err := state.BoxesDir()
	if err != nil {
		t.Fatal(err)
	}
	invalid := filepath.Join(dir, ".env")
	if err := os.WriteFile(invalid, []byte("unrecognized state"), 0600); err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if r.URL.Path == "/_ping" {
			w.Header().Set("API-Version", "1.47")
			return
		}
		if r.Method != http.MethodGet {
			t.Errorf("unexpected Docker mutation: %s %s", r.Method, r.URL.Path)
		}
		if strings.HasSuffix(r.URL.Path, "/containers/json") {
			fmt.Fprint(w, "[]")
			return
		}
		http.Error(w, `{"message":"missing"}`, http.StatusNotFound)
	}))
	defer server.Close()
	t.Setenv("DOCKER_HOST", server.URL)
	t.Setenv("DOCKER_TLS_VERIFY", "")
	t.Setenv("DOCKER_CERT_PATH", "")
	t.Setenv("DOCKER_API_VERSION", "1.47")
	cli, err := docker.NewClient(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	defer cli.Close()
	removed, err := pruneStateFiles(context.Background(), cli)
	if err != nil || len(removed) != 1 || removed[0] != filepath.Join(dir, "orphan.env") {
		t.Fatalf("removed=%v, error=%v", removed, err)
	}
	if data, err := os.ReadFile(invalid); err != nil || string(data) != "unrecognized state" {
		t.Fatalf("unrecognized state changed: %q, %v", data, err)
	}
	if _, err := os.Stat(filepath.Join(dir, "orphan.env")); !os.IsNotExist(err) {
		t.Fatalf("orphan file remains: %v", err)
	}
}
