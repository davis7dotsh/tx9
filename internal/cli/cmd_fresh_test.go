package cli

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/davis7dotsh/tx9/internal/archive"
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
