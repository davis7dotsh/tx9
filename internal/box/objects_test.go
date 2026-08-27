package box

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
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
			if err := PreflightFreshObjects(context.Background(), cli, "fixture"); !errors.Is(err, ErrObjectsExist) || !strings.Contains(err.Error(), "already has Docker") {
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
			if strings.HasPrefix(r.URL.Path, "/containers/") {
				http.Error(w, `{"message":"not found"}`, http.StatusNotFound)
				return
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

func TestPreflightExistingObjectsRejectsForeignCanonicalContainer(t *testing.T) {
	for _, role := range []string{docker.RoleAgent, docker.RoleExecutor} {
		t.Run(role, func(t *testing.T) {
			foreign := "tx9-fixture-" + role
			cli := newObjectTestClient(t, func(w http.ResponseWriter, r *http.Request) {
				if r.Method != http.MethodGet {
					t.Errorf("preflight changed Docker state: %s %s", r.Method, r.URL.Path)
				}
				labels := docker.BoxLabels("fixture", "previous", "")
				if r.URL.Path == "/containers/"+foreign+"/json" {
					labels = docker.BoxLabels("different", "previous", role)
				}
				_ = json.NewEncoder(w).Encode(map[string]any{
					"Id": "existing-id", "Labels": labels, "Config": map[string]any{"Labels": labels},
				})
			})
			if err := PreflightExistingObjects(context.Background(), cli, "fixture"); err == nil || !strings.Contains(err.Error(), foreign) || !strings.Contains(err.Error(), "not owned") {
				t.Fatalf("preflight accepted foreign canonical container: %v", err)
			}
		})
	}
}

func TestDestroyInspectsEveryOwnedContainerBeforeCleanup(t *testing.T) {
	for _, badOwnership := range []bool{false, true} {
		t.Run(fmt.Sprintf("badOwnership=%t", badOwnership), func(t *testing.T) {
			t.Setenv("HOME", t.TempDir())
			if err := state.WriteBoxEnv("fixture", map[string]string{"EXECUTOR_MCP_TOKEN": "synthetic-token"}); err != nil {
				t.Fatal(err)
			}
			owned := map[string]string{
				"agent-first": docker.RoleAgent, "agent-second": docker.RoleAgent,
				"executor-id": docker.RoleExecutor, "unknown-role-id": "",
			}
			inspected := make(map[string]bool)
			deleted := make(map[string]bool)
			cli := newObjectTestClient(t, func(w http.ResponseWriter, r *http.Request) {
				if r.Method == http.MethodDelete {
					if len(inspected) != len(owned) {
						t.Error("deletion started before every matching container was inspected")
					}
					deleted[r.URL.Path] = true
					w.WriteHeader(http.StatusNoContent)
					return
				}
				if r.URL.Path == "/containers/json" {
					containers := []map[string]any{}
					for _, id := range []string{"agent-first", "agent-second", "executor-id", "unknown-role-id"} {
						containers = append(containers, map[string]any{"Id": id, "Labels": docker.BoxLabels("fixture", "previous", owned[id])})
					}
					containers = append(containers, map[string]any{"Id": "other-box-id", "Labels": docker.BoxLabels("different", "previous", docker.RoleAgent)})
					_ = json.NewEncoder(w).Encode(containers)
					return
				}
				id := strings.TrimSuffix(strings.TrimPrefix(r.URL.Path, "/containers/"), "/json")
				role, ok := owned[id]
				if !ok {
					if id == "other-box-id" {
						t.Error("destroy inspected a container belonging to another box")
					}
					http.Error(w, `{"message":"not found"}`, http.StatusNotFound)
					return
				}
				inspected[id] = true
				labels := docker.BoxLabels("fixture", "previous", role)
				if badOwnership && id == "agent-first" {
					labels = docker.BoxLabels("different", "previous", role)
				}
				_ = json.NewEncoder(w).Encode(map[string]any{"Id": id, "Config": map[string]any{"Labels": labels}})
			})
			err := Destroy(context.Background(), cli, "fixture")
			if (err != nil) != badOwnership {
				t.Errorf("destroy error = %v, want ownership failure %t", err, badOwnership)
			}
			env, err := state.ReadBoxEnv("fixture")
			if err != nil {
				t.Fatal(err)
			}
			if badOwnership {
				if len(deleted) != 0 || env["EXECUTOR_MCP_TOKEN"] != "synthetic-token" {
					t.Errorf("failed ownership preflight changed resources: %d DELETE requests, token preserved=%t", len(deleted), env["EXECUTOR_MCP_TOKEN"] == "synthetic-token")
				}
				return
			}
			for id := range owned {
				if !deleted["/containers/"+id] {
					t.Errorf("matching container was not removed: %s", id)
				}
			}
			if len(deleted) != len(owned) || len(env) != 0 {
				t.Errorf("successful cleanup: %d DELETE requests, token removed=%t", len(deleted), len(env) == 0)
			}
		})
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

func TestDestroyPreservesMixedOwnershipBeforeAnyDeletion(t *testing.T) {
	for _, listed := range []bool{false, true} {
		for _, foreign := range []string{
			"/containers/tx9-fixture-agent/json", "/containers/tx9-fixture-executor/json",
			"/networks/tx9-fixture", "/volumes/tx9-fixture-agent-data", "/volumes/tx9-fixture-exec-data",
		} {
			t.Run(fmt.Sprintf("listed=%t/%s", listed, foreign), func(t *testing.T) {
				t.Setenv("HOME", t.TempDir())
				if err := state.WriteBoxEnv("fixture", map[string]string{"EXECUTOR_MCP_TOKEN": "synthetic-token"}); err != nil {
					t.Fatal(err)
				}
				var deletes atomic.Int32
				cli := newObjectTestClient(t, func(w http.ResponseWriter, r *http.Request) {
					if r.Method == http.MethodDelete {
						deletes.Add(1)
						w.WriteHeader(http.StatusNoContent)
						return
					}
					if r.URL.Path == "/containers/json" {
						containers := []map[string]any{}
						if listed {
							for _, role := range []string{docker.RoleAgent, docker.RoleExecutor} {
								if foreign != "/containers/tx9-fixture-"+role+"/json" {
									containers = append(containers, map[string]any{
										"Id": role + "-id", "Labels": docker.BoxLabels("fixture", "previous", role),
									})
								}
							}
						}
						_ = json.NewEncoder(w).Encode(containers)
						return
					}
					path := r.URL.Path
					id := "network-id"
					for _, role := range []string{docker.RoleAgent, docker.RoleExecutor} {
						if path == "/containers/"+role+"-id/json" || path == "/containers/tx9-fixture-"+role+"/json" {
							path = "/containers/tx9-fixture-" + role + "/json"
							id = role + "-id"
						}
					}
					labels := docker.BoxLabels("fixture", "previous", "")
					if path == foreign {
						labels = docker.BoxLabels("different", "previous", "")
					}
					_ = json.NewEncoder(w).Encode(map[string]any{"Id": id, "Labels": labels, "Config": map[string]any{"Labels": labels}})
				})
				if err := Destroy(context.Background(), cli, "fixture"); err == nil {
					t.Error("destroy accepted mixed ownership")
				}
				if got := deletes.Load(); got != 0 {
					t.Errorf("destroy made %d DELETE requests before rejecting mixed ownership", got)
				}
				env, err := state.ReadBoxEnv("fixture")
				if err != nil || len(env) != 1 || env["EXECUTOR_MCP_TOKEN"] != "synthetic-token" {
					t.Error("failed ownership preflight did not preserve token state")
				}
			})
		}
	}
}

func TestDestroyRemovesOnlyInspectedOwnedObjectIDs(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	if err := state.WriteBoxEnv("fixture", map[string]string{"EXECUTOR_MCP_TOKEN": "synthetic-token"}); err != nil {
		t.Fatal(err)
	}
	deletions := make(map[string]bool)
	inspected := make(map[string]bool)
	cli := newObjectTestClient(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodDelete {
			if len(inspected) != 5 {
				t.Error("deletion started before every existing resource was inspected")
			}
			deletions[r.URL.Path] = true
			w.WriteHeader(http.StatusNoContent)
			return
		}
		if r.URL.Path == "/containers/json" {
			_, _ = w.Write([]byte(`[]`))
			return
		}
		inspected[r.URL.Path] = true
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

func TestDestroyCleansPartialOwnedObjects(t *testing.T) {
	for _, renamedAgent := range []bool{false, true} {
		t.Run(fmt.Sprint(renamedAgent), func(t *testing.T) {
			t.Setenv("HOME", t.TempDir())
			if err := state.WriteBoxEnv("fixture", map[string]string{"EXECUTOR_MCP_TOKEN": "synthetic-token"}); err != nil {
				t.Fatal(err)
			}
			var deletes atomic.Int32
			cli := newObjectTestClient(t, func(w http.ResponseWriter, r *http.Request) {
				if r.Method == http.MethodDelete {
					if r.URL.Path != "/networks/network-id" && r.URL.Path != "/volumes/tx9-fixture-agent-data" && (!renamedAgent || r.URL.Path != "/containers/renamed-agent-id") {
						t.Errorf("unexpected DELETE request for absent resource: %s", r.URL.Path)
					}
					deletes.Add(1)
					w.WriteHeader(http.StatusNoContent)
					return
				}
				labels := docker.BoxLabels("fixture", "previous", docker.RoleAgent)
				if r.URL.Path == "/containers/json" {
					containers := []map[string]any{}
					if renamedAgent {
						containers = append(containers, map[string]any{"Id": "renamed-agent-id", "Labels": labels})
					}
					_ = json.NewEncoder(w).Encode(containers)
					return
				}
				id := "network-id"
				if r.URL.Path == "/containers/renamed-agent-id/json" && renamedAgent {
					id = "renamed-agent-id"
				} else if r.URL.Path != "/networks/tx9-fixture" && r.URL.Path != "/volumes/tx9-fixture-agent-data" {
					http.Error(w, `{"message":"not found"}`, http.StatusNotFound)
					return
				}
				_ = json.NewEncoder(w).Encode(map[string]any{"Id": id, "Labels": labels, "Config": map[string]any{"Labels": labels}})
			})
			if err := Destroy(context.Background(), cli, "fixture"); err != nil {
				t.Fatal(err)
			}
			wantDeletes := int32(2)
			if renamedAgent {
				wantDeletes++
			}
			if got := deletes.Load(); got != wantDeletes {
				t.Errorf("DELETE requests = %d, want %d existing owned resources", got, wantDeletes)
			}
			env, err := state.ReadBoxEnv("fixture")
			if err != nil || len(env) != 0 {
				t.Fatal("successful partial cleanup did not remove cached state")
			}
		})
	}
}

func TestDestroyPreservesOwnedObjectsOnInspectFailure(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	if err := state.WriteBoxEnv("fixture", map[string]string{"EXECUTOR_MCP_TOKEN": "synthetic-token"}); err != nil {
		t.Fatal(err)
	}
	var deletes atomic.Int32
	cli := newObjectTestClient(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodDelete {
			deletes.Add(1)
			w.WriteHeader(http.StatusNoContent)
			return
		}
		if r.URL.Path == "/containers/json" {
			_, _ = w.Write([]byte(`[]`))
			return
		}
		if r.URL.Path == "/volumes/tx9-fixture-exec-data" {
			http.Error(w, `{"message":"inspection failed"}`, http.StatusInternalServerError)
			return
		}
		labels := docker.BoxLabels("fixture", "previous", "")
		_ = json.NewEncoder(w).Encode(map[string]any{"Id": r.URL.Path, "Labels": labels, "Config": map[string]any{"Labels": labels}})
	})
	if err := Destroy(context.Background(), cli, "fixture"); err == nil {
		t.Fatal("destroy ignored an inspection failure")
	}
	if got := deletes.Load(); got != 0 {
		t.Errorf("destroy made %d DELETE requests despite incomplete preflight", got)
	}
	env, err := state.ReadBoxEnv("fixture")
	if err != nil || env["EXECUTOR_MCP_TOKEN"] != "synthetic-token" {
		t.Fatal("incomplete preflight did not preserve cached token")
	}
}
