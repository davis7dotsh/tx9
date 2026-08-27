package cli

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"

	"github.com/davis7dotsh/tx9/internal/docker"
	"github.com/davis7dotsh/tx9/internal/lock"
	"github.com/davis7dotsh/tx9/internal/state"
)

func TestPruneKeepsStateForDurableObjectsAndInspectionFailures(t *testing.T) {
	for _, resource := range []string{"agent-data", "exec-data", "network", "unavailable", "none"} {
		t.Run(resource, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Content-Type", "application/json")
				switch {
				case r.URL.Path == "/_ping":
					w.Header().Set("API-Version", "1.47")
					fmt.Fprint(w, "OK")
				case strings.HasSuffix(r.URL.Path, "/containers/json"):
					fmt.Fprint(w, "[]")
				case resource == "unavailable":
					http.Error(w, `{"message":"unavailable"}`, http.StatusServiceUnavailable)
				case strings.HasSuffix(r.URL.Path, "/volumes/tx9-box-"+resource), resource == "network" && strings.HasSuffix(r.URL.Path, "/networks/tx9-box"):
					fmt.Fprint(w, "{}")
				default:
					http.Error(w, `{"message":"missing"}`, http.StatusNotFound)
				}
			}))
			defer server.Close()
			t.Setenv("DOCKER_HOST", "tcp://"+strings.TrimPrefix(server.URL, "http://"))
			t.Setenv("DOCKER_TLS_VERIFY", "")
			t.Setenv("DOCKER_CERT_PATH", "")
			t.Setenv("DOCKER_API_VERSION", "1.47")
			cli, err := docker.NewClient(context.Background())
			if err != nil {
				t.Fatal(err)
			}
			defer cli.Close()
			inUse, err := boxStateInUse(context.Background(), cli, "box")
			if resource == "unavailable" {
				if err == nil {
					t.Fatal("inspection failure treated as absence")
				}
			} else if err != nil || inUse != (resource != "none") {
				t.Fatalf("inUse=%t err=%v", inUse, err)
			}
		})
	}
}

func TestPruneStateRechecksBoxWhileLocked(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	if err := state.WriteBoxEnv("fresh", map[string]string{"EXECUTOR_MCP_TOKEN": "test-token"}); err != nil {
		t.Fatal(err)
	}
	lockPath, err := state.LockPath("fresh")
	if err != nil {
		t.Fatal(err)
	}
	checked := false
	deleted, err := pruneStateFile("fresh", func() (bool, error) {
		checked = true
		if release, err := lock.Acquire(lockPath); err == nil {
			release()
			t.Error("box was rechecked without holding its lock")
		}
		return true, nil // creation completed after prune's initial snapshot
	})
	if err != nil || deleted || !checked {
		t.Fatalf("deleted=%t checked=%t err=%v", deleted, checked, err)
	}
	env, err := state.ReadBoxEnv("fresh")
	if err != nil || env["EXECUTOR_MCP_TOKEN"] != "test-token" {
		t.Fatalf("live box state lost: %v", err)
	}
}

func TestPruneStateRetainsFileOnLookupFailure(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	if err := state.WriteBoxEnv("box", map[string]string{"key": "value"}); err != nil {
		t.Fatal(err)
	}
	want := errors.New("daemon unavailable")
	deleted, err := pruneStateFile("box", func() (bool, error) { return false, want })
	if deleted || !errors.Is(err, want) {
		t.Fatalf("deleted=%t err=%v", deleted, err)
	}
	env, err := state.ReadBoxEnv("box")
	if err != nil || env["key"] != "value" {
		t.Fatalf("state lost after failed lookup: %v", err)
	}
}

func TestPruneStateSkipsInProgressAndDeletesOrphan(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	if err := state.WriteBoxEnv("box", map[string]string{"key": "value"}); err != nil {
		t.Fatal(err)
	}
	lockPath, err := state.LockPath("box")
	if err != nil {
		t.Fatal(err)
	}
	release, err := lock.Acquire(lockPath)
	if err != nil {
		t.Fatal(err)
	}
	defer release()
	deleted, err := pruneStateFile("box", func() (bool, error) {
		t.Fatal("lookup ran while another operation held the lock")
		return false, nil
	})
	if err != nil || deleted {
		t.Fatalf("deleted=%t err=%v", deleted, err)
	}
	release()
	deleted, err = pruneStateFile("box", func() (bool, error) { return false, nil })
	if err != nil || !deleted {
		t.Fatalf("deleted=%t err=%v", deleted, err)
	}
	path, _ := state.BoxEnvPath("box")
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("orphan file remains: %v", err)
	}
}
