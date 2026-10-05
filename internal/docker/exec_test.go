package docker

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/docker/docker/api/types/container"
)

func TestExecWaitsForExitStatusAfterOutputCloses(t *testing.T) {
	for _, cancelWhileRunning := range []bool{false, true} {
		t.Run(fmt.Sprintf("cancel=%v", cancelWhileRunning), func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			var inspected atomic.Int32
			cli := newTestDockerClient(t, func(w http.ResponseWriter, r *http.Request) {
				switch {
				case strings.HasSuffix(r.URL.Path, "/containers/agent/exec"):
					w.Header().Set("Content-Type", "application/json")
					fmt.Fprint(w, `{"Id":"command"}`)
				case strings.HasSuffix(r.URL.Path, "/exec/command/start"):
					io.Copy(io.Discard, r.Body)
					conn, rw, err := w.(http.Hijacker).Hijack()
					if err != nil {
						t.Error(err)
						return
					}
					defer conn.Close()
					fmt.Fprint(rw, "HTTP/1.1 101 UPGRADED\r\nContent-Type: application/vnd.docker.raw-stream\r\nConnection: Upgrade\r\nUpgrade: tcp\r\n\r\n")
					rw.Flush()
				case strings.HasSuffix(r.URL.Path, "/exec/command/json"):
					w.Header().Set("Content-Type", "application/json")
					if inspected.Add(1) < 3 || cancelWhileRunning {
						fmt.Fprint(w, `{"Running":true,"ExitCode":0}`)
						if cancelWhileRunning {
							cancel()
						}
						return
					}
					fmt.Fprint(w, `{"Running":false,"ExitCode":42}`)
				default:
					http.Error(w, "unexpected request", http.StatusNotFound)
				}
			})
			exitCode, err := cli.ExecStream(ctx, "agent", []string{"command"}, nil, "agent", io.Discard, io.Discard)
			if cancelWhileRunning {
				if !errors.Is(err, context.Canceled) {
					t.Fatalf("error=%v, want cancellation while awaiting process exit", err)
				}
				return
			}
			if err != nil || exitCode != 42 {
				t.Fatalf("exitCode=%d err=%v, want final exitCode 42", exitCode, err)
			}
		})
	}
}

// Opt in using an existing shell-capable image. This helper never mounts data.
func TestExecDockerIntegration(t *testing.T) {
	image := os.Getenv("TX9_TEST_DOCKER_IMAGE")
	if image == "" {
		t.Skip("set TX9_TEST_DOCKER_IMAGE to an existing shell-capable image")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	cli, err := NewClient(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer cli.Close()
	helper, err := cli.Raw().ContainerCreate(ctx, &container.Config{
		Image: image, Entrypoint: []string{"/bin/sh"}, Cmd: []string{"-c", "sleep 30"},
	}, &container.HostConfig{NetworkMode: "none"}, nil, nil, "")
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		cleanupCtx, stop := context.WithTimeout(context.Background(), 5*time.Second)
		defer stop()
		if err := cli.ContainerRemove(cleanupCtx, helper.ID, true); err != nil {
			t.Error(err)
		}
	}()
	if err := cli.ContainerStart(ctx, helper.ID); err != nil {
		t.Fatal(err)
	}
	exitCode, err := cli.ExecStream(ctx, helper.ID, []string{"/bin/sh", "-c", "exec 1>&- 2>&-; sleep 1; exit 42"}, nil, "", io.Discard, io.Discard)
	if err != nil || exitCode != 42 {
		t.Fatalf("exitCode=%d err=%v, want final exitCode 42", exitCode, err)
	}
}
