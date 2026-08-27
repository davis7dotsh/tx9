package cli

import (
	"context"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"strings"
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

	argv, env := enterExecCommand(dockerBin, containerID, tok, *intoExecutor, os.Environ())
	// Replace this process so Docker owns terminal signals and resizing.
	if err := syscall.Exec(dockerBin, argv, env); err != nil {
		return fmt.Errorf("enter %s: exec docker: %w", name, err)
	}
	return nil
}

// Pass bearer tokens through Docker's environment lookup, never its arguments.
// An interactive docker exec can stay visible in host process listings for
// hours. Remove inherited token values before supplying this box's token.
func enterExecCommand(dockerBin, containerID, token string, intoExecutor bool, inheritedEnv []string) ([]string, []string) {
	env := make([]string, 0, len(inheritedEnv)+1)
	for _, entry := range inheritedEnv {
		key, _, _ := strings.Cut(entry, "=")
		if key != "BOXD_EXECUTOR_TOKEN" && key != "EXECUTOR_MCP_TOKEN" {
			env = append(env, entry)
		}
	}
	var argv []string
	if intoExecutor {
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
			"-e", "EXECUTOR_MCP_TOKEN",
			"-w", "/data/home/agent",
			containerID, "bash", "--norc", "-c",
			". /etc/profile.d/hermes-box.sh; exec bash --norc -i",
		}
		env = append(env, "EXECUTOR_MCP_TOKEN="+token)
	} else {
		argv = []string{
			dockerBin, "exec", "-it", "-u", "agent",
			"-e", "HOME=/data/home/agent",
			"-e", "USER=agent",
			"-e", "LOGNAME=agent",
			"-e", "SHELL=/bin/bash",
			"-e", "EXECUTOR_HOST=executor",
			"-e", "BOXD_EXECUTOR_TOKEN",
			"-w", "/data/home/agent",
			containerID, "bash", "-l",
		}
		env = append(env, "BOXD_EXECUTOR_TOKEN="+token)
	}
	return argv, env
}
