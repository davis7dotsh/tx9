package box

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"testing"

	"github.com/davis7dotsh/tx9/internal/docker"
	"github.com/docker/docker/api/types/container"
)

func TestRecreateAgentPreservesImageAndCurrentRunningState(t *testing.T) {
	for _, running := range []bool{false, true} {
		t.Run(map[bool]string{false: "stopped", true: "running"}[running], func(t *testing.T) {
			const imageID = "sha256:original-image"
			var started, stopped bool
			cli := newObjectTestClient(t, func(w http.ResponseWriter, r *http.Request) {
				labels := docker.BoxLabels("fixture", "test", docker.RoleAgent)
				switch {
				case r.URL.Path == "/containers/original/json":
					_ = json.NewEncoder(w).Encode(map[string]any{
						"Id": "original", "Image": imageID,
						"Config":     map[string]any{"Image": "tx9-box:dev", "Labels": labels},
						"HostConfig": map[string]any{"NanoCpus": int64(750_000_000), "Memory": int64(3 << 30)},
						"State":      map[string]any{"Running": running},
					})
				case r.URL.Path == "/networks/tx9-fixture":
					_ = json.NewEncoder(w).Encode(map[string]any{"Id": "network", "Labels": labels})
				case r.URL.Path == "/volumes/tx9-fixture-agent-data":
					_ = json.NewEncoder(w).Encode(map[string]any{"Name": "tx9-fixture-agent-data", "Labels": labels})
				case r.Method == http.MethodPost && r.URL.Path == "/containers/create":
					var request struct {
						container.Config
						HostConfig container.HostConfig
					}
					if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
						t.Error(err)
					}
					if request.Image != imageID {
						t.Errorf("replacement image=%q, want original image ID %q; tag may now point elsewhere", request.Image, imageID)
					}
					if request.HostConfig.NanoCPUs != 750_000_000 || request.HostConfig.Memory != 3<<30 {
						t.Errorf("replacement resource limits were lost: %#v", request.HostConfig.Resources)
					}
					_ = json.NewEncoder(w).Encode(map[string]string{"Id": "replacement"})
				case r.URL.Path == "/containers/original/stop":
					stopped = true
					w.WriteHeader(http.StatusNoContent)
				case r.URL.Path == "/containers/replacement/start":
					started = true
					w.WriteHeader(http.StatusNoContent)
				case r.Method == http.MethodDelete && r.URL.Path == "/containers/original":
					w.WriteHeader(http.StatusNoContent)
				default:
					t.Errorf("unexpected request: %s %s", r.Method, r.URL.Path)
					http.Error(w, "unexpected request", http.StatusNotFound)
				}
			})
			// The list snapshot can be stale after another actor starts/stops
			// the container. Preserve the state from the inspected container.
			snapshot := "running"
			if running {
				snapshot = "exited"
			}
			b := &Box{Name: "fixture", AgentID: "original", AgentState: snapshot, Version: "test"}
			wasRunning, err := RecreateAgent(context.Background(), cli, b, "synthetic-token", nil)
			if err != nil {
				t.Fatal(err)
			}
			if wasRunning != running || started != running || stopped != running {
				t.Errorf("running state changed: wasRunning=%v started=%v stopped=%v, want %v", wasRunning, started, stopped, running)
			}
		})
	}
}

func TestRecreateAgentRejectsIncompleteOrForeignContainerBeforeMutation(t *testing.T) {
	for _, problem := range []string{"image", "config", "state", "ownership"} {
		t.Run(problem, func(t *testing.T) {
			cli := newObjectTestClient(t, func(w http.ResponseWriter, r *http.Request) {
				if r.Method != http.MethodGet || r.URL.Path != "/containers/original/json" {
					t.Errorf("incomplete preflight reached %s %s", r.Method, r.URL.Path)
				}
				response := map[string]any{
					"Id": "original", "Image": "sha256:original-image",
					"Config": map[string]any{"Image": "tx9-box:dev", "Labels": docker.BoxLabels("fixture", "test", docker.RoleAgent)},
					"State":  map[string]any{"Running": false}, "HostConfig": map[string]any{},
				}
				if problem == "ownership" {
					response["Config"] = map[string]any{"Image": "tx9-box:dev", "Labels": docker.BoxLabels("different", "test", docker.RoleAgent)}
				} else {
					delete(response, strings.ToUpper(problem[:1])+problem[1:])
				}
				_ = json.NewEncoder(w).Encode(response)
			})
			_, err := RecreateAgent(context.Background(), cli, &Box{Name: "fixture", AgentID: "original"}, "synthetic-token", nil)
			if err == nil {
				t.Fatal("unsafe recreation succeeded")
			}
		})
	}
}
