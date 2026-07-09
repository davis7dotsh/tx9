package cli

import (
	"slices"
	"testing"
)

func TestTarExclusionsPreserveUnrelatedLocalBinEntries(t *testing.T) {
	if slices.Contains(tarExclusions, "./home/agent/.local/bin") {
		t.Fatal("tarExclusions drops all of ~/.local/bin")
	}
	for _, launcher := range []string{
		"./home/agent/.local/bin/claude",
		"./home/agent/.local/bin/codex",
	} {
		if !slices.Contains(tarExclusions, launcher) {
			t.Errorf("tarExclusions does not drop regenerable launcher %q", launcher)
		}
	}
}
