package docker

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/docker/docker/api/types/container"
)

func TestExecCancellationClosesAttachedStream(t *testing.T) {
	for _, buffered := range []bool{false, true} {
		t.Run(fmt.Sprint("buffered=", buffered), func(t *testing.T) {
			attached := make(chan struct{})
			cli := newTestDockerClient(t, func(w http.ResponseWriter, r *http.Request) {
				switch {
				case strings.HasSuffix(r.URL.Path, "/containers/agent/exec"):
					w.Header().Set("Content-Type", "application/json")
					fmt.Fprint(w, `{"Id":"command"}`)
				case strings.HasSuffix(r.URL.Path, "/exec/command/start"):
					conn, rw, err := w.(http.Hijacker).Hijack()
					if err != nil {
						t.Error(err)
						return
					}
					defer conn.Close()
					fmt.Fprint(rw, "HTTP/1.1 101 UPGRADED\r\nContent-Type: application/vnd.docker.raw-stream\r\nConnection: Upgrade\r\nUpgrade: tcp\r\n\r\n")
					rw.Flush()
					close(attached)
					io.Copy(io.Discard, rw)
				default:
					http.Error(w, "unexpected request", http.StatusNotFound)
				}
			})
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			done := make(chan error, 1)
			go func() {
				if buffered {
					_, err := cli.Exec(ctx, "agent", []string{"command"}, nil, "agent")
					done <- err
				} else {
					_, err := cli.ExecStream(ctx, "agent", []string{"command"}, nil, "agent", io.Discard, io.Discard)
					done <- err
				}
			}()
			select {
			case <-attached:
			case err := <-done:
				t.Fatalf("exec ended before attaching: %v", err)
			case <-time.After(5 * time.Second):
				t.Fatal("exec did not attach")
			}
			cancel()
			select {
			case err := <-done:
				if !errors.Is(err, context.Canceled) {
					t.Fatalf("error=%v, want cancellation", err)
				}
			case <-time.After(5 * time.Second):
				t.Fatal("canceled exec is stuck on the attached stream")
			}
		})
	}
}

func TestEphemeralIsOfflineAndCleansUpAfterCancellation(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	removed := false
	cli := newTestDockerClient(t, func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.HasSuffix(r.URL.Path, "/containers/create"):
			var request struct{ HostConfig container.HostConfig }
			if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
				t.Error(err)
			}
			if request.HostConfig.NetworkMode != "none" {
				t.Errorf("helper has network access: %q", request.HostConfig.NetworkMode)
			}
			if len(request.HostConfig.SecurityOpt) != 1 || request.HostConfig.SecurityOpt[0] != "no-new-privileges:true" {
				t.Errorf("helper can gain privileges: %v", request.HostConfig.SecurityOpt)
			}
			w.Header().Set("Content-Type", "application/json")
			fmt.Fprint(w, `{"Id":"helper"}`)
		case strings.HasSuffix(r.URL.Path, "/containers/helper/attach"):
			cancel()
			http.Error(w, "canceled", http.StatusServiceUnavailable)
		case r.Method == http.MethodDelete && strings.HasSuffix(r.URL.Path, "/containers/helper"):
			removed = true
			if r.URL.Query().Get("force") != "1" {
				t.Error("cleanup must remove a running helper")
			}
			if r.URL.Query().Get("v") != "1" {
				t.Error("cleanup must remove anonymous image volumes")
			}
			w.WriteHeader(http.StatusNoContent)
		default:
			http.Error(w, "unexpected request", http.StatusNotFound)
		}
	})
	if _, err := cli.RunEphemeral(ctx, EphemeralOpts{Image: "fixture"}); err == nil {
		t.Fatal("cancellation error missing")
	}
	if !removed {
		t.Fatal("helper was left behind after context cancellation")
	}
}

func TestEphemeralReportsInputFailure(t *testing.T) {
	inputDone := make(chan struct{})
	cli := newTestDockerClient(t, func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.HasSuffix(r.URL.Path, "/containers/create"):
			w.Header().Set("Content-Type", "application/json")
			fmt.Fprint(w, `{"Id":"helper"}`)
		case strings.HasSuffix(r.URL.Path, "/containers/helper/attach"):
			conn, rw, err := w.(http.Hijacker).Hijack()
			if err != nil {
				t.Error(err)
				return
			}
			defer conn.Close()
			fmt.Fprint(rw, "HTTP/1.1 101 UPGRADED\r\nContent-Type: application/vnd.docker.raw-stream\r\nConnection: Upgrade\r\nUpgrade: tcp\r\n\r\n")
			rw.Flush()
			io.Copy(io.Discard, rw)
			close(inputDone)
		case strings.HasSuffix(r.URL.Path, "/containers/helper/wait"):
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusOK)
			w.(http.Flusher).Flush()
			select {
			case <-inputDone:
			case <-r.Context().Done():
				return
			}
			fmt.Fprint(w, `{"StatusCode":0}`)
		case strings.HasSuffix(r.URL.Path, "/containers/helper/start"), r.Method == http.MethodDelete:
			w.WriteHeader(http.StatusNoContent)
		default:
			http.Error(w, "unexpected request", http.StatusNotFound)
		}
	})
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	want := errors.New("fixture input failed")
	_, err := cli.RunEphemeral(ctx, EphemeralOpts{Image: "fixture", Stdin: errorReader{want}, Stdout: io.Discard, Stderr: io.Discard})
	if !errors.Is(err, want) {
		t.Fatalf("input error lost: %v", err)
	}
}

type errorReader struct{ err error }

func (r errorReader) Read([]byte) (int, error) { return 0, r.err }
