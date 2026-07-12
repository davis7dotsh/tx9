package cli

import (
	"bytes"
	"errors"
	"io"
	"strings"
	"testing"
)

func TestCommandAliasesTargetRegisteredCommands(t *testing.T) {
	want := map[string]string{
		"new":     "create",
		"ls":      "list",
		"ssh":     "enter",
		"shell":   "enter",
		"export":  "backup",
		"save":    "backup",
		"load":    "import",
		"restore": "import",
		"update":  "upgrade",
		"rm":      "delete",
		"remove":  "delete",
	}

	if len(aliases) != len(want) {
		t.Fatalf("alias count = %d, want %d: %v", len(aliases), len(want), aliases)
	}
	for alias, target := range want {
		if got := aliases[alias]; got != target {
			t.Errorf("aliases[%q] = %q, want %q", alias, got, target)
		}
		if commands[target] == nil {
			t.Errorf("alias %q targets unregistered command %q", alias, target)
		}
	}
}

func TestUsageShowsAliasesFromCommandSpecs(t *testing.T) {
	var usage bytes.Buffer
	printUsage(&usage)

	for _, line := range []string{
		"  new        create",
		"  ls         list",
		"  ssh        enter",
		"  shell      enter",
		"  export     backup",
		"  save       backup",
		"  load       import",
		"  restore    import",
		"  update     upgrade",
		"  rm         delete",
		"  remove     delete",
	} {
		if !strings.Contains(usage.String(), line) {
			t.Errorf("usage does not contain alias line %q:\n%s", line, usage.String())
		}
	}
}

func TestNoArgumentsShowsOverviewAndCommands(t *testing.T) {
	var stdout, stderr bytes.Buffer
	status := runWithOverview([]string{"tx9"}, nil, func(w io.Writer) error {
		_, err := io.WriteString(w, "ASCII BOX DIAGRAM\n")
		return err
	}, &stdout, &stderr)
	if status != 0 {
		t.Fatalf("status = %d, want 0; stderr=%s", status, stderr.String())
	}
	for _, want := range []string{"ASCII BOX DIAGRAM", "Commands:", "logs", "resources"} {
		if !strings.Contains(stdout.String(), want) {
			t.Errorf("stdout missing %q:\n%s", want, stdout.String())
		}
	}
}

func TestNoArgumentsFallsBackToCommandsWhenOverviewFails(t *testing.T) {
	var stdout, stderr bytes.Buffer
	status := runWithOverview([]string{"tx9"}, nil, func(io.Writer) error {
		return errors.New("daemon unavailable")
	}, &stdout, &stderr)
	if status != 0 {
		t.Fatalf("status = %d, want 0", status)
	}
	if !strings.Contains(stdout.String(), "overview unavailable") || !strings.Contains(stdout.String(), "Commands:") {
		t.Fatalf("stdout missing fallback:\n%s", stdout.String())
	}
	if !strings.Contains(stderr.String(), "daemon unavailable") {
		t.Fatalf("stderr missing cause:\n%s", stderr.String())
	}
}
