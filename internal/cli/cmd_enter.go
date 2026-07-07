package cli

import (
	"context"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"syscall"

	"github.com/davis7dotsh/tx9/internal/box"
	"github.com/davis7dotsh/tx9/internal/docker"
)

// cmdEnter implements `tx9 enter <box>` (alias `ssh`): exec into the agent
// container as `agent`, dropping into the box's persistent tmux `main`
// session. Starts the box first if it isn't already running (no readiness
// retry loop here — that's `create`/`upgrade`'s job; enter just needs the
// containers up so `docker exec` has somewhere to attach).
//
// This replicates boxd's own `cmd_enter` exactly (recovered from git history
// at 6f1ced3, docker/boxd): `docker exec -it -u agent ... bash -l`. The
// login shell is what triggers guest/agent-bash-profile.sh, which runs
// `hb up`/`hb wire-once` and then execs into the tmux `main` session — there
// is no separate `hb enter` subcommand to invoke.
func cmdEnter(args []string) error {
	fs := flag.NewFlagSet("enter", flag.ContinueOnError)
	intoExecutor := fs.Bool("executor", false, "enter the box's executor container instead of the agent container")
	if err := parseFlagsAnywhere(fs, args); err != nil {
		return err
	}
	name, err := requireBoxName(fs, "enter")
	if err != nil {
		return err
	}

	var containerID, tok string
	err = withBoxLock(name, func(ctx context.Context, cli *docker.Client) error {
		b, err := box.Get(ctx, cli, name)
		if err != nil {
			return fmt.Errorf("enter %s: %w", name, err)
		}
		if b.AgentState != "running" || b.ExecutorState != "running" {
			if err := box.Start(ctx, cli, b); err != nil {
				return fmt.Errorf("enter %s: start: %w", name, err)
			}
		}
		tok, err = box.Token(name)
		if err != nil {
			return fmt.Errorf("enter %s: %w", name, err)
		}
		containerID = b.AgentID
		if *intoExecutor {
			containerID = b.ExecutorID
		}
		return nil
	})
	if err != nil {
		return err
	}

	dockerBin, err := exec.LookPath("docker")
	if err != nil {
		return fmt.Errorf("enter %s: docker binary not found on PATH: %w", name, err)
	}

	var argv []string
	if *intoExecutor {
		// The executor container runs only the daemon — no tmux session, no
		// login-profile automation. A plain interactive shell with the box
		// profile sourced (PATH to vp/executor, /data env) is what you want
		// for maintenance like `vp install -g executor@latest`. --norc keeps
		// bash from reading skel dotfiles for a home that doesn't exist here.
		argv = []string{
			dockerBin, "exec", "-it", "-u", "agent",
			"-e", "HOME=/data/home/agent",
			"-e", "USER=agent",
			"-e", "LOGNAME=agent",
			"-e", "SHELL=/bin/bash",
			"-e", "EXECUTOR_MCP_TOKEN=" + tok,
			"-w", "/data/home/agent",
			containerID, "bash", "--norc", "-c",
			". /etc/profile.d/hermes-box.sh; exec bash --norc -i",
		}
	} else {
		argv = []string{
			dockerBin, "exec", "-it", "-u", "agent",
			"-e", "HOME=/data/home/agent",
			"-e", "USER=agent",
			"-e", "LOGNAME=agent",
			"-e", "SHELL=/bin/bash",
			"-e", "EXECUTOR_HOST=executor",
			"-e", "BOXD_EXECUTOR_TOKEN=" + tok,
			"-w", "/data/home/agent",
			containerID, "bash", "-l",
		}
	}

	// syscall.Exec replaces this process outright so the TTY (job control,
	// signals, resize) is docker's problem from here on, exactly as boxd's
	// own `exec docker exec ...` did.
	if err := syscall.Exec(dockerBin, argv, os.Environ()); err != nil {
		return fmt.Errorf("enter %s: exec docker: %w", name, err)
	}
	return nil
}
