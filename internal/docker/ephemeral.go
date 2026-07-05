package docker

import (
	"context"
	"fmt"
	"io"
	"sync"

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

	if _, err := stdcopy.StdCopy(stdout, stderr, attach.Reader); err != nil {
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
func (c *Client) RunEphemeral(ctx context.Context, opts EphemeralOpts) (int, error) {
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
	hostCfg := &container.HostConfig{Binds: opts.Binds}

	resp, err := c.cli.ContainerCreate(ctx, cfg, hostCfg, nil, nil, "")
	if err != nil {
		return 0, fmt.Errorf("docker: ephemeral create: %w", err)
	}
	defer c.cli.ContainerRemove(ctx, resp.ID, container.RemoveOptions{Force: true})

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

	// Reserve "not running" wait BEFORE start so we can't miss a fast exit.
	statusCh, waitErrCh := c.cli.ContainerWait(ctx, resp.ID, container.WaitConditionNotRunning)

	if err := c.cli.ContainerStart(ctx, resp.ID, container.StartOptions{}); err != nil {
		return 0, fmt.Errorf("docker: ephemeral start: %w", err)
	}

	var stdinWG sync.WaitGroup
	if hasStdin {
		stdinWG.Add(1)
		go func() {
			defer stdinWG.Done()
			io.Copy(attach.Conn, opts.Stdin)
			attach.CloseWrite()
		}()
	}

	copyDone := make(chan error, 1)
	go func() {
		_, cerr := stdcopy.StdCopy(opts.Stdout, opts.Stderr, attach.Reader)
		copyDone <- cerr
	}()

	var exitCode int
	select {
	case werr := <-waitErrCh:
		return 0, fmt.Errorf("docker: ephemeral wait: %w", werr)
	case status := <-statusCh:
		exitCode = int(status.StatusCode)
	}

	if hasStdin {
		stdinWG.Wait()
	}
	if cerr := <-copyDone; cerr != nil {
		return exitCode, fmt.Errorf("docker: ephemeral read output: %w", cerr)
	}
	return exitCode, nil
}
