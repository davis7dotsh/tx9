package cli

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/davis7dotsh/tx9/internal/docker"
	"github.com/davis7dotsh/tx9/internal/state"
)

func TestUpgradeRemovesEveryValidatedContainer(t *testing.T) {
	for _, canonicalRole := range []string{docker.RoleAgent, "unknown"} {
		for _, foreignVolume := range []bool{false, true} {
			t.Run(fmt.Sprintf("canonicalRole=%s/foreignVolume=%t", canonicalRole, foreignVolume), func(t *testing.T) {
				t.Setenv("HOME", t.TempDir())
				if err := state.WriteBoxEnv("fixture", map[string]string{"EXECUTOR_MCP_TOKEN": "synthetic-token"}); err != nil {
					t.Fatal(err)
				}
				roles := map[string]string{"canonical-id": canonicalRole, "renamed-id": docker.RoleAgent, "executor-id": docker.RoleExecutor}
				deleted := make(map[string]bool)
				inspected := make(map[string]bool)
				mutations := 0
				createReached := false
				server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
					w.Header().Set("Content-Type", "application/json")
					path := strings.TrimPrefix(r.URL.Path, "/v1.47")
					if path == "/_ping" {
						w.Header().Set("Api-Version", "1.47")
						return
					}
					if r.Method != http.MethodGet {
						mutations++
						if len(inspected) != 6 {
							t.Error("upgrade mutated Docker before inspecting every container, network, and volume")
						}
						if path == "/containers/create" {
							createReached = true
							for id := range roles {
								if !deleted[id] {
									t.Errorf("upgrade recreated containers before removing %s", id)
								}
							}
							http.Error(w, `{"message":"fixture stops at recreation"}`, http.StatusInternalServerError)
							return
						}
						id := strings.TrimSuffix(strings.TrimPrefix(path, "/containers/"), "/stop")
						if _, ok := roles[id]; !ok {
							t.Errorf("upgrade mutated an unexpected resource: %s %s", r.Method, path)
						}
						if r.Method == http.MethodDelete {
							deleted[id] = true
						}
						w.WriteHeader(http.StatusNoContent)
						return
					}
					if path == "/containers/json" {
						containers := []map[string]any{}
						for _, id := range []string{"canonical-id", "renamed-id", "executor-id"} {
							containers = append(containers, map[string]any{"Id": id, "Labels": docker.BoxLabels("fixture", "previous", roles[id])})
						}
						_ = json.NewEncoder(w).Encode(containers)
						return
					}
					if strings.HasPrefix(path, "/images/") {
						_, _ = w.Write([]byte(`{"Id":"cached-image"}`))
						return
					}
					id := strings.TrimSuffix(strings.TrimPrefix(path, "/containers/"), "/json")
					if id == "tx9-fixture-agent" {
						id = "canonical-id"
					} else if id == "tx9-fixture-executor" {
						id = "executor-id"
					}
					inspected[id] = true
					labels := docker.BoxLabels("fixture", "previous", roles[id])
					if foreignVolume && path == "/volumes/tx9-fixture-exec-data" {
						labels = docker.BoxLabels("different", "previous", "")
					}
					_ = json.NewEncoder(w).Encode(map[string]any{"Id": id, "Labels": labels, "Config": map[string]any{"Labels": labels}, "HostConfig": map[string]any{}})
				}))
				defer server.Close()
				t.Setenv("DOCKER_HOST", server.URL)
				t.Setenv("DOCKER_API_VERSION", "1.47")
				t.Setenv("DOCKER_TLS_VERIFY", "")
				t.Setenv("DOCKER_CERT_PATH", "")
				err := cmdUpgrade([]string{"fixture", "--clear-executor-config"})
				if err == nil {
					t.Fatal("upgrade ignored fixture failure")
				}
				if foreignVolume {
					if !strings.Contains(err.Error(), "not owned") || mutations != 0 {
						t.Errorf("ownership rejection = %v, Docker mutations = %d", err, mutations)
					}
				} else if !createReached || !strings.Contains(err.Error(), "fixture stops at recreation") || len(deleted) != len(roles) {
					t.Errorf("upgrade teardown = %v, recreate reached = %t, deleted = %v", err, createReached, deleted)
				}
				env, err := state.ReadBoxEnv("fixture")
				if err != nil || env["EXECUTOR_MCP_TOKEN"] != "synthetic-token" || (foreignVolume && len(env) != 1) {
					t.Error("upgrade did not preserve cached state")
				}
			})
		}
	}
}
