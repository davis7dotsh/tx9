package box

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/davis7dotsh/tx9/internal/docker"
	"github.com/davis7dotsh/tx9/internal/state"
)

func newObjectTestClient(t *testing.T, handler http.HandlerFunc) *docker.Client {
	t.Helper()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if r.URL.Path == "/_ping" {
			w.Header().Set("Api-Version", "1.47")
			return
		}
		r.URL.Path = strings.TrimPrefix(r.URL.Path, "/v1.47")
		handler(w, r)
	}))
	t.Cleanup(server.Close)
	t.Setenv("DOCKER_HOST", server.URL)
	t.Setenv("DOCKER_API_VERSION", "1.47")
	t.Setenv("DOCKER_TLS_VERIFY", "")
	t.Setenv("DOCKER_CERT_PATH", "")
	cli, err := docker.NewClient(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = cli.Close() })
	return cli
}

func TestPreflightFreshObjectsRejectsEveryExistingObject(t *testing.T) {
	for _, existing := range []string{
		"/containers/tx9-fixture-agent/json", "/containers/tx9-fixture-executor/json",
		"/networks/tx9-fixture", "/volumes/tx9-fixture-agent-data", "/volumes/tx9-fixture-exec-data",
	} {
		t.Run(existing, func(t *testing.T) {
			cli := newObjectTestClient(t, func(w http.ResponseWriter, r *http.Request) {
				if r.Method != http.MethodGet {
					t.Errorf("preflight changed Docker state: %s %s", r.Method, r.URL.Path)
				}
				if r.URL.Path == existing {
					_, _ = w.Write([]byte(`{"Id":"existing","Config":{}}`))
					return
				}
				http.Error(w, `{"message":"not found"}`, http.StatusNotFound)
			})
			if err := PreflightFreshObjects(context.Background(), cli, "fixture"); err == nil || !strings.Contains(err.Error(), "already has Docker") {
				t.Fatalf("preflight did not preserve existing object: %v", err)
			}
		})
	}
}

func TestPreflightFreshObjectsRequiresConfirmedAbsence(t *testing.T) {
	for _, status := range []int{http.StatusNotFound, http.StatusForbidden} {
		cli := newObjectTestClient(t, func(w http.ResponseWriter, r *http.Request) {
			if r.Method != http.MethodGet {
				t.Errorf("preflight changed Docker state: %s %s", r.Method, r.URL.Path)
			}
			http.Error(w, `{"message":"fixture"}`, status)
		})
		err := PreflightFreshObjects(context.Background(), cli, "fixture")
		if (err == nil) != (status == http.StatusNotFound) {
			t.Fatalf("preflight status %d: %v", status, err)
		}
	}
}

func TestEnsureObjectsOnlyReusesOwnedNetworkAndVolumes(t *testing.T) {
	for _, labels := range []map[string]string{
		nil, {docker.LabelManaged: "1", docker.LabelBox: "different"}, docker.BoxLabels("fixture", "previous", ""),
	} {
		cli := newObjectTestClient(t, func(w http.ResponseWriter, r *http.Request) {
			if r.Method != http.MethodGet {
				t.Errorf("existing object changed: %s %s", r.Method, r.URL.Path)
			}
			_ = json.NewEncoder(w).Encode(map[string]any{"Id": "network-id", "Name": "tx9-fixture-agent-data", "Labels": labels})
		})
		_, networkErr := ensureNetwork(context.Background(), cli, "tx9-fixture", "fixture", "new")
		_, volumeErr := ensureVolume(context.Background(), cli, "tx9-fixture-agent-data", "fixture", "new")
		preflightErr := PreflightExistingObjects(context.Background(), cli, "fixture")
		wantSuccess := ownedByBox(labels, "fixture")
		if (networkErr == nil) != wantSuccess || (volumeErr == nil) != wantSuccess || (preflightErr == nil) != wantSuccess {
			t.Fatalf("ownership validation = network:%v volume:%v preflight:%v, want success %t", networkErr, volumeErr, preflightErr, wantSuccess)
		}
	}
}

func TestDestroyPreservesForeignObjectsAndToken(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	if err := state.WriteBoxEnv("fixture", map[string]string{"EXECUTOR_MCP_TOKEN": "synthetic-token"}); err != nil {
		t.Fatal(err)
	}
	cli := newObjectTestClient(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			t.Errorf("foreign object changed: %s %s", r.Method, r.URL.Path)
		}
		if r.URL.Path == "/containers/json" {
			_, _ = w.Write([]byte(`[]`))
			return
		}
		_, _ = w.Write([]byte(`{"Id":"foreign","Config":{"Labels":{}},"Labels":{}}`))
	})
	if err := Destroy(context.Background(), cli, "fixture"); err == nil {
		t.Fatal("destroy accepted foreign objects")
	}
	env, err := state.ReadBoxEnv("fixture")
	if err != nil || env["EXECUTOR_MCP_TOKEN"] != "synthetic-token" {
		t.Fatal("failed destroy did not preserve token state")
	}
}

func TestDestroyRemovesOnlyInspectedOwnedObjectIDs(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	if err := state.WriteBoxEnv("fixture", map[string]string{"EXECUTOR_MCP_TOKEN": "synthetic-token"}); err != nil {
		t.Fatal(err)
	}
	deletions := make(map[string]bool)
	cli := newObjectTestClient(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodDelete {
			deletions[r.URL.Path] = true
			w.WriteHeader(http.StatusNoContent)
			return
		}
		if r.URL.Path == "/containers/json" {
			_, _ = w.Write([]byte(`[]`))
			return
		}
		id := "network-id"
		if strings.Contains(r.URL.Path, "-agent/json") {
			id = "agent-id"
		} else if strings.Contains(r.URL.Path, "-executor/json") {
			id = "executor-id"
		}
		labels := docker.BoxLabels("fixture", "previous", "")
		_ = json.NewEncoder(w).Encode(map[string]any{"Id": id, "Labels": labels, "Config": map[string]any{"Labels": labels}})
	})
	if err := Destroy(context.Background(), cli, "fixture"); err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{"/containers/agent-id", "/containers/executor-id", "/networks/network-id", "/volumes/tx9-fixture-agent-data", "/volumes/tx9-fixture-exec-data"} {
		if !deletions[path] {
			t.Errorf("owned object was not removed by its inspected ID: %s", path)
		}
	}
	if len(deletions) != 5 {
		t.Fatalf("unexpected deletions: %v", deletions)
	}
	env, err := state.ReadBoxEnv("fixture")
	if err != nil || len(env) != 0 {
		t.Fatal("successful destroy did not remove cached state")
	}
}
