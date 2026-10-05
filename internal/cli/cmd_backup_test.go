package cli

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"

	"github.com/davis7dotsh/tx9/internal/archive"
	"github.com/davis7dotsh/tx9/internal/docker"
	"github.com/davis7dotsh/tx9/internal/state"
)

func TestTarExclusionsPreserveUnrelatedLocalBinEntries(t *testing.T) {
	if slices.Contains(tarExclusions, "./home/agent/.local/bin") {
		t.Fatal("tarExclusions drops all of ~/.local/bin")
	}
	for _, launcher := range []string{
		"./home/agent/.local/bin/claude",
		"./home/agent/.local/bin/codex",
	} {
		if !slices.Contains(tarExclusions, launcher) {
			t.Errorf("tarExclusions does not drop regenerable launcher %q", launcher)
		}
	}
}

func TestWriteTx9StagedCleansOnlyOwnedOutput(t *testing.T) {
	for _, existing := range []bool{false, true} {
		t.Run(map[bool]string{false: "new output", true: "existing output"}[existing], func(t *testing.T) {
			dir := t.TempDir()
			stage := filepath.Join(dir, "archive.staging")
			if existing {
				if err := os.WriteFile(stage, []byte("preserve me"), 0600); err != nil {
					t.Fatal(err)
				}
			}
			if err := writeTx9Staged(stage, archive.Metadata{BoxName: "fixture"}, filepath.Join(dir, "missing")); err == nil {
				t.Fatal("missing payload was accepted")
			}
			contents, err := os.ReadFile(stage)
			if existing {
				if err != nil || string(contents) != "preserve me" {
					t.Fatalf("existing stage changed: %q, %v", contents, err)
				}
			} else if !os.IsNotExist(err) {
				t.Fatalf("failed write left a stage behind: %v", err)
			}
		})
	}
}

func TestBackupResumesFailedPauseWithoutResumingPreviouslyPausedBox(t *testing.T) {
	for _, alreadyPaused := range []bool{false, true} {
		t.Run(fmt.Sprint("alreadyPaused=", alreadyPaused), func(t *testing.T) {
			t.Setenv("HOME", t.TempDir())
			if err := state.WriteBoxEnv("fixture", map[string]string{"EXECUTOR_MCP_TOKEN": "synthetic-token"}); err != nil {
				t.Fatal(err)
			}
			var mu sync.Mutex
			var commands []string
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				path := strings.TrimPrefix(r.URL.Path, "/v1.47")
				w.Header().Set("Content-Type", "application/json")
				switch {
				case path == "/_ping":
					w.Header().Set("Api-Version", "1.47")
				case path == "/containers/json":
					_ = json.NewEncoder(w).Encode([]map[string]any{{"Id": "agent", "Labels": docker.BoxLabels("fixture", "dev", docker.RoleAgent)}})
				case path == "/containers/agent/exec":
					var body struct{ Cmd []string }
					if err := json.NewDecoder(r.Body).Decode(&body); err != nil || len(body.Cmd) == 0 {
						t.Errorf("decode exec command: %v", err)
						w.WriteHeader(http.StatusBadRequest)
						return
					}
					command := body.Cmd[len(body.Cmd)-1]
					mu.Lock()
					commands = append(commands, command)
					mu.Unlock()
					_ = json.NewEncoder(w).Encode(map[string]string{"Id": command})
				case strings.HasSuffix(path, "/start"):
					_, _ = io.Copy(io.Discard, r.Body)
					conn, rw, err := w.(http.Hijacker).Hijack()
					if err != nil {
						t.Error(err)
						return
					}
					defer conn.Close()
					_, _ = fmt.Fprint(rw, "HTTP/1.1 101 UPGRADED\r\nContent-Type: application/vnd.docker.raw-stream\r\nConnection: Upgrade\r\nUpgrade: tcp\r\n\r\n")
					_ = rw.Flush()
				case strings.HasSuffix(path, "/json"):
					command := strings.TrimSuffix(strings.TrimPrefix(path, "/exec/"), "/json")
					exitCode := 1
					if command == "resume" || (command == "is-paused" && alreadyPaused) {
						exitCode = 0
					}
					_ = json.NewEncoder(w).Encode(map[string]any{"Running": false, "ExitCode": exitCode})
				default:
					t.Errorf("unexpected Docker request: %s %s", r.Method, path)
					w.WriteHeader(http.StatusNotFound)
				}
			}))
			defer server.Close()
			t.Setenv("DOCKER_HOST", "tcp://"+strings.TrimPrefix(server.URL, "http://"))
			t.Setenv("DOCKER_API_VERSION", "1.47")
			t.Setenv("DOCKER_TLS_VERIFY", "")
			t.Setenv("DOCKER_CERT_PATH", "")
			if err := cmdBackup([]string{"fixture", "--no-encrypt", "--path", t.TempDir()}); err == nil {
				t.Fatal("backup ignored the failed guest command")
			}
			mu.Lock()
			defer mu.Unlock()
			want := []string{"is-paused", "pause", "resume"}
			if alreadyPaused {
				want = []string{"is-paused", "--checkpoint"}
			}
			if !slices.Equal(commands, want) {
				t.Fatalf("guest calls = %v, want %v", commands, want)
			}
		})
	}
}
