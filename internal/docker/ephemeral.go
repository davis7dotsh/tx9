package docker

import (
	"context"
	"errors"
	"fmt"
	"io"
	"time"

	"github.com/docker/docker/api/types/container"
	"github.com/docker/docker/pkg/stdcopy"
)

// ExecStream runs cmd inside the already-running container containerID,
// like Exec, but streams stdout/stderr directly to the caller's writers
// instead of buffering them in memory. This is what `tx9 backup` uses to
// pull a multi-gigabyte tar stream out of the agent container's /data
// volume without holding the whole archive in RAM.
func (c *Client) ExecStream(ctx context.Context, containerID string, cmd []string, env []string, user string, stdout, stderr io.Writer) (int, error) {
	created, err := c.cli.ContainerExecCreate(ctx, containerID, container.ExecOptions{
		Cmd:          cmd,
		Env:          env,
		User:         user,
		AttachStdout: true,
		AttachStderr: true,
	})
	if err != nil {
		return 0, fmt.Errorf("docker: exec create: %w", err)
	}

	attach, err := c.cli.ContainerExecAttach(ctx, created.ID, container.ExecAttachOptions{})
	if err != nil {
		return 0, fmt.Errorf("docker: exec attach: %w", err)
	}
	defer attach.Close()
	stopCancel := context.AfterFunc(ctx, attach.Close)
	defer stopCancel()

	if _, err := stdcopy.StdCopy(stdout, stderr, attach.Reader); err != nil {
		if ctx.Err() != nil {
			return 0, ctx.Err()
		}
		return 0, fmt.Errorf("docker: exec read output: %w", err)
	}

	inspect, err := c.cli.ContainerExecInspect(ctx, created.ID)
	if err != nil {
		return 0, fmt.Errorf("docker: exec inspect: %w", err)
	}
	return inspect.ExitCode, nil
}

// EphemeralOpts parameterizes RunEphemeral.
type EphemeralOpts struct {
	Image      string
	Entrypoint []string
	Cmd        []string
	Env        []string
	Binds      []string  // "volume:/container/path"
	Stdin      io.Reader // optional; nil means no stdin is attached
	Stdout     io.Writer
	Stderr     io.Writer
}

// RunEphemeral creates, starts, waits for, and always removes a throwaway
// container from opts.Image with opts.Binds mounted — the "stage-then-
// promote" pattern `tx9 import` uses to write into a box's agent-data
// volume before the agent container itself has ever started (dossier
// §7.2's `docker run --rm -i -v ... --entrypoint bash "$IMAGE" -c '...'`).
// It returns the container's exit code; a non-nil error means the
// container could not be run at all (create/attach/start/wait failure),
// not merely that the command inside it exited non-zero.
// Caller I/O finishes before return, including on cancellation. Readers and
// writers must not block indefinitely; closing the attachment cannot interrupt
// a Read or Write that is already executing inside a caller's implementation.
func (c *Client) RunEphemeral(ctx context.Context, opts EphemeralOpts) (exitCode int, err error) {
	hasStdin := opts.Stdin != nil
	cfg := &container.Config{
		Image:        opts.Image,
		Entrypoint:   opts.Entrypoint,
		Cmd:          opts.Cmd,
		Env:          opts.Env,
		AttachStdin:  hasStdin,
		AttachStdout: true,
		AttachStderr: true,
		OpenStdin:    hasStdin,
		StdinOnce:    hasStdin,
	}
	// Helpers only inspect or restore local volumes. In particular the log
	// reader mounts both trust domains and must not have network access.
	hostCfg := &container.HostConfig{
		Binds: opts.Binds, NetworkMode: "none",
		SecurityOpt: []string{"no-new-privileges:true"},
	}

	resp, err := c.cli.ContainerCreate(ctx, cfg, hostCfg, nil, nil, "")
	if err != nil {
		return 0, fmt.Errorf("docker: ephemeral create: %w", err)
	}
	defer func() {
		cleanupCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 10*time.Second)
		defer cancel()
		if cleanupErr := c.cli.ContainerRemove(cleanupCtx, resp.ID, container.RemoveOptions{Force: true, RemoveVolumes: true}); cleanupErr != nil {
			err = errors.Join(err, fmt.Errorf("docker: remove ephemeral container %s: %w", resp.ID, cleanupErr))
		}
	}()

	attach, err := c.cli.ContainerAttach(ctx, resp.ID, container.AttachOptions{
		Stream: true,
		Stdin:  hasStdin,
		Stdout: true,
		Stderr: true,
	})
	if err != nil {
		return 0, fmt.Errorf("docker: ephemeral attach: %w", err)
	}
	defer attach.Close()
	stopCancel := context.AfterFunc(ctx, attach.Close)
	defer stopCancel()

	// Reserve "not running" wait BEFORE start so we can't miss a fast exit.
	statusCh, waitErrCh := c.cli.ContainerWait(ctx, resp.ID, container.WaitConditionNotRunning)

	if err := c.cli.ContainerStart(ctx, resp.ID, container.StartOptions{}); err != nil {
		return 0, fmt.Errorf("docker: ephemeral start: %w", err)
	}

	var stdinDone chan error
	if hasStdin {
		stdinDone = make(chan error, 1)
		go func() {
			defer close(stdinDone)
			_, copyErr := io.Copy(attach.Conn, opts.Stdin)
			closeErr := attach.CloseWrite()
			stdinDone <- errors.Join(copyErr, closeErr)
		}()
	}

	copyDone := make(chan error, 1)
	go func() {
		defer close(copyDone)
		_, cerr := stdcopy.StdCopy(opts.Stdout, opts.Stderr, attach.Reader)
		copyDone <- cerr
	}()
	defer func() {
		// Closing the socket interrupts Docker I/O, but a caller's file may
		// still be in use. Join both copies before its owner can close it.
		attach.Close()
		<-copyDone
		if stdinDone != nil {
			<-stdinDone
		}
	}()

	select {
	case <-ctx.Done():
		return 0, ctx.Err()
	case werr := <-waitErrCh:
		return 0, fmt.Errorf("docker: ephemeral wait: %w", werr)
	case status := <-statusCh:
		exitCode = int(status.StatusCode)
		if status.Error != nil {
			return exitCode, fmt.Errorf("docker: ephemeral wait: %s", status.Error.Message)
		}
	}

	if hasStdin {
		select {
		case <-ctx.Done():
			return exitCode, ctx.Err()
		case copyErr := <-stdinDone:
			if copyErr != nil {
				return exitCode, fmt.Errorf("docker: ephemeral write input: %w", copyErr)
			}
		}
	}
	select {
	case <-ctx.Done():
		return exitCode, ctx.Err()
	case cerr := <-copyDone:
		if cerr != nil {
			return exitCode, fmt.Errorf("docker: ephemeral read output: %w", cerr)
		}
	}
	return exitCode, nil
}
