package cli

import (
	"reflect"
	"testing"

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
