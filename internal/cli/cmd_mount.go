package cli

import (
	"context"
	"flag"
	"fmt"
	"io"
	"os"
	"path"
	"text/tabwriter"

	"github.com/davis7dotsh/tx9/internal/box"
	"github.com/davis7dotsh/tx9/internal/docker"
)

func cmdMount(args []string) error {
	if len(args) == 0 {
		return fmt.Errorf("mount: action required (usage: tx9 mount <add|list|remove> ...)")
	}
	switch args[0] {
	case "add":
		return cmdMountAdd(args[1:])
	case "list":
		return cmdMountList(args[1:])
	case "remove", "rm":
		return cmdMountRemove(args[1:])
	default:
		return fmt.Errorf("mount: unknown action %q (usage: tx9 mount <add|list|remove> ...)", args[0])
	}
}

func cmdMountAdd(args []string) error {
	fs := flag.NewFlagSet("mount add", flag.ContinueOnError)
	readOnly := fs.Bool("read-only", false, "mount read-only inside the agent container")
	requireMountpoint := fs.Bool("require-mountpoint", false, "refuse recreation unless the source is an active host mountpoint")
	if err := parseFlagsAnywhere(fs, args); err != nil {
		return err
	}
	if fs.NArg() != 3 {
		return fmt.Errorf("mount add: expected box, host source, and container target (usage: tx9 mount add <box> <source> <target>)")
	}
	name, source, target := fs.Arg(0), fs.Arg(1), fs.Arg(2)
	mount, err := box.NewAgentMount(source, target, *readOnly, *requireMountpoint)
	if err != nil {
		return fmt.Errorf("mount add %s: %w", name, err)
	}

	return withBoxLock(name, func(ctx context.Context, cli *docker.Client) error {
		b, err := box.Get(ctx, cli, name)
		if err != nil {
			return fmt.Errorf("mount add %s: %w", name, err)
		}
		mounts, err := box.LoadAgentMounts(name)
		if err != nil {
			return fmt.Errorf("mount add %s: %w", name, err)
		}
		for _, existing := range mounts {
			if existing.Target != mount.Target {
				continue
			}
			if existing == mount {
				// Idempotent no-op: recreating the agent here would kill
				// in-flight agent work for zero configuration change.
				fmt.Printf("tx9: mount already configured for %s; nothing to do\n", name)
				return nil
			}
			return fmt.Errorf("mount add %s: target %s is already configured from %s; remove it first", name, mount.Target, existing.Source)
		}
		mounts = append(mounts, mount)
		if err := applyAgentMounts(ctx, cli, b, name, mounts); err != nil {
			return fmt.Errorf("mount add %s: %w", name, err)
		}
		fmt.Printf("tx9: mounted %s at %s in %s (%s)\n", mount.Source, mount.Target, name, mountMode(mount))
		return nil
	})
}

func cmdMountList(args []string) error {
	fs := flag.NewFlagSet("mount list", flag.ContinueOnError)
	if err := parseFlagsAnywhere(fs, args); err != nil {
		return err
	}
	name, err := requireBoxName(fs, "mount list")
	if err != nil {
		return err
	}
	return withDocker(func(ctx context.Context, cli *docker.Client) error {
		if _, err := box.Get(ctx, cli, name); err != nil {
			return fmt.Errorf("mount list %s: %w", name, err)
		}
		mounts, err := box.LoadAgentMounts(name)
		if err != nil {
			return fmt.Errorf("mount list %s: %w", name, err)
		}
		if len(mounts) == 0 {
			fmt.Printf("tx9: no agent mounts configured for %s\n", name)
			return nil
		}
		w := tabwriter.NewWriter(os.Stdout, 0, 4, 2, ' ', 0)
		fmt.Fprintln(w, "SOURCE\tTARGET\tMODE\tREQUIRE MOUNTPOINT")
		for _, mount := range mounts {
			fmt.Fprintf(w, "%s\t%s\t%s\t%t\n", mount.Source, mount.Target, mountMode(mount), mount.RequireMountpoint)
		}
		return w.Flush()
	})
}

func cmdMountRemove(args []string) error {
	fs := flag.NewFlagSet("mount remove", flag.ContinueOnError)
	if err := parseFlagsAnywhere(fs, args); err != nil {
		return err
	}
	if fs.NArg() != 2 {
		return fmt.Errorf("mount remove: expected box and container target (usage: tx9 mount remove <box> <target>)")
	}
	name, target := fs.Arg(0), path.Clean(fs.Arg(1))

	return withBoxLock(name, func(ctx context.Context, cli *docker.Client) error {
		b, err := box.Get(ctx, cli, name)
		if err != nil {
			return fmt.Errorf("mount remove %s: %w", name, err)
		}
		mounts, err := box.LoadAgentMounts(name)
		if err != nil {
			return fmt.Errorf("mount remove %s: %w", name, err)
		}
		kept := mounts[:0]
		found := false
		for _, mount := range mounts {
			if mount.Target == target {
				found = true
				continue
			}
			kept = append(kept, mount)
		}
		if !found {
			// Idempotent no-op (or a typo'd target): never recreate the
			// agent when the desired mount set did not change.
			fmt.Printf("tx9: no configured mount at %s; nothing to do\n", target)
			return nil
		}
		if err := applyAgentMounts(ctx, cli, b, name, kept); err != nil {
			return fmt.Errorf("mount remove %s: %w", name, err)
		}
		fmt.Printf("tx9: removed mount at %s from %s\n", target, name)
		return nil
	})
}

// applyAgentMounts recreates the agent with the desired mount set and only
// then persists it, so state and container cannot diverge in a way a retry
// of the same command would skip: a recreation failure leaves the old state
// (the retry is not an idempotent no-op), and a persisted set always
// describes a container that actually carried it.
func applyAgentMounts(ctx context.Context, cli *docker.Client, b *box.Box, name string, mounts []box.AgentMount) error {
	token, err := box.Token(b.Name)
	if err != nil {
		return err
	}
	wasRunning, err := box.RecreateAgent(ctx, cli, b, token, mounts)
	if err != nil {
		return err
	}
	if err := box.SaveAgentMounts(name, mounts); err != nil {
		return fmt.Errorf("agent was recreated with the desired mounts but persisting them failed; re-run the command: %w", err)
	}
	if !wasRunning {
		return nil
	}
	// A quiesced box (e.g. freshly imported, single-writer safety gate) must
	// stay quiesced: PrepareRuntime runs `hb up`, which clears the quiesce
	// marker and wires MCP — exactly what cmd_import deliberately avoids.
	if err := box.HB(ctx, cli, b, token, io.Discard, io.Discard, "is-paused"); err == nil {
		fmt.Println("tx9: box is quiesced; skipping runtime preparation (run `hb resume` inside the box when ready)")
		return nil
	}
	fmt.Println("tx9: preparing recreated agent runtime")
	return box.PrepareRuntime(ctx, cli, b, token, os.Stdout)
}

func mountMode(mount box.AgentMount) string {
	if mount.ReadOnly {
		return "ro"
	}
	return "rw"
}
