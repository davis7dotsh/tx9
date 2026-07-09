package cli

import (
	"flag"
	"testing"
)

func TestExecutorConfigFlagsRejectClearWithValues(t *testing.T) {
	fs := flag.NewFlagSet("test", flag.ContinueOnError)
	configFlags := addExecutorConfigFlags(fs)
	if err := fs.Parse([]string{
		"--clear-executor-config",
		"--executor-web-base-url=https://example.ts.net",
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := configFlags.load("media-bot"); err == nil {
		t.Fatal("expected conflicting configuration error")
	}
}
