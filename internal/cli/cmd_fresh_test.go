package cli

import (
	"bytes"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/davis7dotsh/tx9/internal/archive"
	"github.com/davis7dotsh/tx9/internal/box"
	"github.com/davis7dotsh/tx9/internal/state"
)

func TestFreshCommandsPreserveOrphanedVolumeAndToken(t *testing.T) {
	for _, command := range []string{"create", "import"} {
		t.Run(command, func(t *testing.T) {
			t.Setenv("HOME", t.TempDir())
			if err := state.WriteBoxEnv("fixture", map[string]string{"EXECUTOR_MCP_TOKEN": "existing-synthetic-token"}); err != nil {
				t.Fatal(err)
			}
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Content-Type", "application/json")
				if r.URL.Path == "/_ping" {
					w.Header().Set("Api-Version", "1.47")
					return
				}
				if r.Method != http.MethodGet {
					t.Errorf("fresh command changed existing Docker state: %s %s", r.Method, r.URL.Path)
				}
				switch strings.TrimPrefix(r.URL.Path, "/v1.47") {
				case "/containers/json":
					_, _ = w.Write([]byte(`[]`))
				case "/volumes/tx9-fixture-agent-data":
					_, _ = w.Write([]byte(`{"Name":"tx9-fixture-agent-data","Labels":{"tx9":"1","tx9.box":"fixture"}}`))
				default:
					http.Error(w, `{"message":"fixture not found"}`, http.StatusNotFound)
				}
			}))
			defer server.Close()
			t.Setenv("DOCKER_HOST", server.URL)
			t.Setenv("DOCKER_API_VERSION", "1.47")
			t.Setenv("DOCKER_TLS_VERIFY", "")
			t.Setenv("DOCKER_CERT_PATH", "")
			var err error
			if command == "create" {
				err = cmdCreate([]string{"fixture"})
			} else {
				dir := t.TempDir()
				payload := filepath.Join(dir, "payload")
				if err := os.WriteFile(payload, []byte("preflight must reject before reading payload"), 0600); err != nil {
					t.Fatal(err)
				}
				var contents bytes.Buffer
				if err := archive.WriteTx9(&contents, archive.Metadata{BoxName: "fixture"}, payload); err != nil {
					t.Fatal(err)
				}
				path := filepath.Join(dir, "fixture.tx9")
				if err := os.WriteFile(path, contents.Bytes(), 0600); err != nil {
					t.Fatal(err)
				}
				err = cmdImport([]string{path})
			}
			if err == nil || !strings.Contains(err.Error(), "already has Docker volume") {
				t.Fatalf("%s did not reject orphaned volume: %v", command, err)
			}
			env, err := state.ReadBoxEnv("fixture")
			if err != nil || len(env) != 1 || env["EXECUTOR_MCP_TOKEN"] != "existing-synthetic-token" {
				t.Fatal("existing box token was changed")
			}
		})
	}
}

func TestGeneratedNamesSkipExistingDockerObjects(t *testing.T) {
	var occupied string
	checks := 0
	name, err := generateFreshBoxName(make(map[string]bool), func(candidate string) error {
		checks++
		if checks == 1 {
			occupied = candidate
			return fmt.Errorf("orphaned volume: %w", box.ErrObjectsExist)
		}
		if candidate == occupied {
			t.Fatal("generated the same conflicting name again")
		}
		return nil
	})
	if err != nil || name == "" || name == occupied || checks != 2 {
		t.Fatalf("name=%q, checks=%d, error=%v", name, checks, err)
	}
}

func TestGeneratedNameRetriesAreBoundedAndDoNotHideDockerErrors(t *testing.T) {
	for _, collision := range []bool{false, true} {
		t.Run(fmt.Sprint("collision=", collision), func(t *testing.T) {
			failure := errors.New("Docker unavailable")
			wantChecks := 1
			if collision {
				failure = box.ErrObjectsExist
				wantChecks = 100
			}
			checks := 0
			name, err := generateFreshBoxName(make(map[string]bool), func(string) error {
				checks++
				return failure
			})
			if name != "" || err == nil || checks != wantChecks {
				t.Fatalf("name=%q, checks=%d, error=%v", name, checks, err)
			}
			if !collision && !errors.Is(err, failure) {
				t.Fatalf("Docker error hidden: %v", err)
			}
		})
	}
}
