package cli

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"reflect"
	"strings"
	"testing"

	"github.com/docker/docker/api/types/image"

	"github.com/davis7dotsh/tx9/internal/docker"
	"github.com/davis7dotsh/tx9/internal/lock"
	"github.com/davis7dotsh/tx9/internal/state"
	"github.com/davis7dotsh/tx9/internal/version"
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

func TestPruneRemovesOnlyUnusedTX9ImageTags(t *testing.T) {
	var removed []string
	images := []image.Summary{
		{ID: "sha256:obsolete", RepoTags: []string{"tx9-box:old-a", "tx9-box:old-b", "other-project:keep"}},
		{ID: "sha256:current", RepoTags: []string{"tx9-box:" + version.Version, "tx9-box:older-same-image"}},
		{ID: "sha256:used", RepoTags: []string{"tx9-box:used"}},
		{ID: "sha256:used-by-tag", RepoTags: []string{"tx9-box:used-by-tag"}},
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		path := strings.TrimPrefix(r.URL.Path, "/v1.47")
		switch {
		case path == "/_ping":
			w.Header().Set("Api-Version", "1.47")
		case path == "/images/json":
			_ = json.NewEncoder(w).Encode(images)
		case path == "/containers/json":
			fmt.Fprint(w, `[{"Image":"tx9-box:used","ImageID":"sha256:used"},{"Image":"tx9-box:used-by-tag","ImageID":"sha256:other-id"}]`)
		case r.Method == http.MethodDelete && strings.HasPrefix(path, "/images/"):
			ref := strings.TrimPrefix(path, "/images/")
			if !strings.HasPrefix(ref, "tx9-box:") {
				t.Errorf("prune tried removing image ID or unrelated alias: %s", ref)
				http.Error(w, `{"message":"image has multiple tags"}`, http.StatusConflict)
				return
			}
			removed = append(removed, ref)
			fmt.Fprint(w, `[]`)
		default:
			t.Errorf("unexpected request: %s %s", r.Method, r.URL.Path)
			http.Error(w, `{"message":"unexpected request"}`, http.StatusNotFound)
		}
	}))
	defer server.Close()
	t.Setenv("DOCKER_HOST", server.URL)
	t.Setenv("DOCKER_API_VERSION", "1.47")
	t.Setenv("DOCKER_TLS_VERIFY", "")
	t.Setenv("DOCKER_CERT_PATH", "")
	cli, err := docker.NewClient(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	defer cli.Close()
	got, err := pruneImages(context.Background(), cli)
	want := []string{"tx9-box:old-a", "tx9-box:old-b"}
	if err != nil || !reflect.DeepEqual(got, want) || !reflect.DeepEqual(removed, want) {
		t.Fatalf("prune returned=%v deleted=%v error=%v; want only %v", got, removed, err, want)
	}
}
