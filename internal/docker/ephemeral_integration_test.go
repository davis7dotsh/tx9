package docker

import (
	"bytes"
	"context"
	"errors"
	"io"
	"os"
	"strings"
	"testing"
	"time"
)

// Opt in with an already-installed image that provides /bin/sh, cat, ls, and sleep.
// These tests create only disposable containers and never mount host data.
func TestEphemeralDockerIntegration(t *testing.T) {
	image := os.Getenv("TX9_TEST_DOCKER_IMAGE")
	if image == "" {
		t.Skip("set TX9_TEST_DOCKER_IMAGE to an existing shell-capable image")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	cli, err := NewClient(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer cli.Close()
	t.Run("offline stdin roundtrip", func(t *testing.T) {
		var output bytes.Buffer
		exitCode, err := cli.RunEphemeral(ctx, EphemeralOpts{
			Image: image, Entrypoint: []string{"/bin/sh"},
			Cmd:   []string{"-c", `test "$(ls /sys/class/net)" = lo && cat`},
			Stdin: strings.NewReader("fixture-only\n"), Stdout: &output, Stderr: io.Discard,
		})
		if err != nil || exitCode != 0 || output.String() != "fixture-only\n" {
			t.Fatalf("code=%d output=%q err=%v", exitCode, output.String(), err)
		}
	})
	t.Run("cancel running helper", func(t *testing.T) {
		cancelCtx, stop := context.WithTimeout(ctx, time.Second)
		defer stop()
		_, err := cli.RunEphemeral(cancelCtx, EphemeralOpts{
			Image: image, Entrypoint: []string{"/bin/sh"}, Cmd: []string{"-c", "sleep 30"},
			Stdout: io.Discard, Stderr: io.Discard,
		})
		if !errors.Is(err, context.DeadlineExceeded) {
			t.Fatalf("cancellation error lost: %v", err)
		}
	})
}
