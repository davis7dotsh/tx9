package cli

import (
	"bytes"
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
