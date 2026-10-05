package cli

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"

	"github.com/davis7dotsh/tx9/internal/box"
	"github.com/davis7dotsh/tx9/internal/docker"
	"github.com/davis7dotsh/tx9/internal/state"
)

func TestLogsHelperArgs(t *testing.T) {
	opts := logsQueryOptions{
		Source:   "codex,executor",
		Tail:     50,
		Since:    "24h",
		Contains: "failed",
		Level:    "warn",
		JSON:     true,
		NoRedact: true,
	}

	got := logsHelperArgs("query", "large-cat", opts)

	want := []string{
		"query", "--agent-root", "/agent", "--executor-root", "/executor",
		"--box", "large-cat", "--source", "codex,executor", "--tail", "50",
		"--since", "24h", "--grep", "failed", "--level", "warn", "--json", "--no-redact",
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("helper args = %#v, want %#v", got, want)
	}
}

func TestLogsHelperArgsOmitsEmptyLevel(t *testing.T) {
	got := logsHelperArgs("query", "large-cat", logsQueryOptions{Source: "all", Tail: 10})
	for _, arg := range got {
		if arg == "--level" {
			t.Fatalf("helper args %#v include --level for an unset level", got)
		}
	}
}

func TestValidateLogsLevel(t *testing.T) {
	for _, level := range []string{"", "debug", "info", "warn", "error"} {
		if err := validateLogsLevel(level); err != nil {
			t.Fatalf("validateLogsLevel(%q) = %v, want nil", level, err)
		}
	}
	if err := validateLogsLevel("loud"); err == nil {
		t.Fatal("validateLogsLevel accepted an unknown level")
	}
}

func TestSplitLogsActionPreservesQueryBoxName(t *testing.T) {
	for _, input := range [][]string{
		{"query"},
		{"query", "--since", "24h"},
		{"query", "--json"},
	} {
		action, args := splitLogsAction(input)
		if action != "query" || !reflect.DeepEqual(args, input) {
			t.Fatalf("split %#v = %q/%#v, want query action with arguments unchanged", input, action, args)
		}
	}
}

func TestLogsHelperEnvironmentIncludesBoxTokenForExactRedaction(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	if err := state.WriteBoxEnv("large-cat", map[string]string{
		"EXECUTOR_MCP_TOKEN": "box-secret",
	}); err != nil {
		t.Fatal(err)
	}
	got, err := logsHelperEnvironment("large-cat")
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"TX9_QUERY_TOKEN=box-secret"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("helper environment = %#v, want token redaction input", got)
	}
}

func TestLogsHelperUsesContainerImageIDAfterTagMoves(t *testing.T) {
	for _, tc := range []struct {
		name         string
		agentStatus  int
		agentJSON    string
		executorJSON string
		want         string
		wantError    string
	}{
		{"immutable image", http.StatusOK, `{"Image":"sha256:original-image","Config":{"Image":"tx9-box:dev"}}`, "", "sha256:original-image", ""},
		{"missing image ID", http.StatusOK, `{"Config":{"Image":"tx9-box:dev"}}`, "", "tx9-box:dev", ""},
		{"agent disappeared", http.StatusNotFound, `{"message":"agent disappeared"}`, `{"Image":"sha256:executor-image"}`, "sha256:executor-image", ""},
		{"inspection failed", http.StatusServiceUnavailable, `{"message":"fixture daemon failure"}`, "", "", "fixture daemon failure"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Content-Type", "application/json")
				switch {
				case r.URL.Path == "/_ping":
					w.Header().Set("Api-Version", "1.47")
				case strings.HasSuffix(r.URL.Path, "/containers/agent/json"):
					w.WriteHeader(tc.agentStatus)
					fmt.Fprint(w, tc.agentJSON)
				case strings.HasSuffix(r.URL.Path, "/containers/executor/json") && tc.executorJSON != "":
					fmt.Fprint(w, tc.executorJSON)
				default:
					http.Error(w, `{"message":"missing fixture"}`, http.StatusNotFound)
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
			image, err := boxImageRef(context.Background(), cli, &box.Box{AgentID: "agent", ExecutorID: "executor"})
			if tc.wantError != "" {
				if err == nil || !strings.Contains(err.Error(), tc.wantError) {
					t.Fatalf("inspection failure lost: %v", err)
				}
			} else if err != nil || image != tc.want {
				t.Fatalf("image=%q error=%v, want %q", image, err, tc.want)
			}
		})
	}
}
