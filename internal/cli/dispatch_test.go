package cli

import (
	"bytes"
	"errors"
	"io"
	"os"
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

func TestUsageMentionsCustomServiceLogs(t *testing.T) {
	var usage bytes.Buffer
	printUsage(&usage)
	if !strings.Contains(usage.String(), "custom-service events") {
		t.Fatalf("logs help does not mention custom services:\n%s", usage.String())
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

func TestSubcommandHelpSucceedsWithoutDocker(t *testing.T) {
	t.Setenv("DOCKER_HOST", "invalid://help-must-not-connect")
	originalStderr := os.Stderr
	file, err := os.CreateTemp(t.TempDir(), "help-output")
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	os.Stderr = file
	t.Cleanup(func() { os.Stderr = originalStderr })
	for _, spec := range commandSpecs {
		t.Run(spec.name, func(t *testing.T) {
			var stdout, stderr bytes.Buffer
			status := runWithOverview([]string{"tx9", spec.name, "--help"}, nil, func(io.Writer) error {
				t.Fatal("help attempted to collect overview")
				return nil
			}, &stdout, &stderr)
			if status != 0 || stderr.Len() != 0 {
				t.Fatalf("help status=%d stderr=%s", status, stderr.String())
			}
		})
	}
	for _, args := range [][]string{
		{"mount", "add", "--help"}, {"mount", "list", "--help"}, {"mount", "remove", "--help"},
		{"resources", "set", "--help"}, {"resources", "reset", "--help"}, {"logs", "export", "--help"},
		{"delete", "fixture", "--help"},
	} {
		var stdout, stderr bytes.Buffer
		if status := runWithOverview(append([]string{"tx9"}, args...), nil, nil, &stdout, &stderr); status != 0 || stderr.Len() != 0 {
			t.Errorf("%v: status=%d stderr=%s", args, status, stderr.String())
		}
	}
}

func TestSubcommandUnknownFlagsFail(t *testing.T) {
	var stdout, stderr bytes.Buffer
	if status := runWithOverview([]string{"tx9", "list", "--unknown"}, nil, nil, &stdout, &stderr); status != 1 || !strings.Contains(stderr.String(), "flag provided but not defined") {
		t.Fatalf("unknown flag status=%d stderr=%s", status, stderr.String())
	}
}
