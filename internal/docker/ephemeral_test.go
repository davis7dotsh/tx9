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
	"github.com/docker/docker/pkg/stdcopy"
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

func TestEphemeralWaitsForCallerIOOnFailure(t *testing.T) {
	for _, failure := range []string{"cancel", "wait", "status", "input"} {
		for _, blockedInput := range []bool{false, true} {
			if blockedInput && failure == "input" {
				continue
			}
			t.Run(fmt.Sprintf("%s/blockedInput=%v", failure, blockedInput), func(t *testing.T) {
				ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
				defer cancel()
				entered := make(chan struct{})
				release := make(chan struct{})
				defer func() {
					select {
					case <-release:
					default:
						close(release)
					}
				}()
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
						stdcopy.NewStdWriter(rw, stdcopy.Stdout).Write([]byte("fixture output"))
						rw.Flush()
						io.Copy(io.Discard, rw)
					case strings.HasSuffix(r.URL.Path, "/containers/helper/wait"):
						w.Header().Set("Content-Type", "application/json")
						w.WriteHeader(http.StatusOK)
						w.(http.Flusher).Flush()
						select {
						case <-entered:
						case <-r.Context().Done():
							return
						}
						switch failure {
						case "cancel":
							cancel()
						case "wait":
							fmt.Fprint(w, "invalid wait response")
						case "status":
							fmt.Fprint(w, `{"StatusCode":1,"Error":{"Message":"fixture failure"}}`)
						case "input":
							fmt.Fprint(w, `{"StatusCode":0}`)
						}
					case strings.HasSuffix(r.URL.Path, "/containers/helper/start"), r.Method == http.MethodDelete:
						w.WriteHeader(http.StatusNoContent)
					default:
						http.Error(w, "unexpected request", http.StatusNotFound)
					}
				})
				opts := EphemeralOpts{Image: "fixture", Stdout: io.Discard, Stderr: io.Discard}
				if blockedInput {
					opts.Stdin = heldReader{entered, release}
				} else {
					opts.Stdout = heldWriter{entered, release}
				}
				if failure == "input" {
					opts.Stdin = errorReader{errors.New("fixture input failure")}
				}
				done := make(chan error, 1)
				go func() {
					_, err := cli.RunEphemeral(ctx, opts)
					done <- err
				}()
				select {
				case <-entered:
				case err := <-done:
					t.Fatalf("helper returned before caller I/O: %v", err)
				case <-ctx.Done():
					t.Fatal("helper never entered caller I/O")
				}
				select {
				case err := <-done:
					t.Fatalf("helper returned while caller I/O was still active: %v", err)
				case <-time.After(50 * time.Millisecond):
				}
				close(release)
				select {
				case err := <-done:
					if err == nil {
						t.Fatal("helper failure was lost")
					}
				case <-time.After(5 * time.Second):
					t.Fatal("helper did not return after caller I/O finished")
				}
			})
		}
	}
}

type heldWriter struct{ entered, release chan struct{} }

func (w heldWriter) Write(p []byte) (int, error) {
	close(w.entered)
	<-w.release
	return len(p), nil
}

type heldReader struct{ entered, release chan struct{} }

func (r heldReader) Read([]byte) (int, error) {
	close(r.entered)
	<-r.release
	return 0, io.EOF
}
