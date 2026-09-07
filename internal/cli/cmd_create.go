package cli

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"os"

	"github.com/davis7dotsh/tx9/internal/box"
	"github.com/davis7dotsh/tx9/internal/docker"
	"github.com/davis7dotsh/tx9/internal/lock"
	"github.com/davis7dotsh/tx9/internal/names"
	"github.com/davis7dotsh/tx9/internal/state"
	"github.com/davis7dotsh/tx9/internal/token"
	"github.com/davis7dotsh/tx9/internal/version"
)

// cmdCreate implements `tx9 create [name]` (command surface: generate a
// friendly name if absent, build tx9-box:<version> if missing, create
// network + volumes + both containers, mint token, wire MCP, run doctor).
func cmdCreate(args []string) error {
	fs := flag.NewFlagSet("create", flag.ContinueOnError)
	executorFlags := addExecutorConfigFlags(fs)
	resourceFlags := addResourceConfigFlags(fs)
	if err := parseFlagsAnywhere(fs, args); err != nil {
		return err
	}
	if fs.NArg() > 1 {
		return fmt.Errorf("create: expected at most one box name (usage: tx9 create [box])")
	}
	requested := fs.Arg(0)

	ctx := context.Background()
	cli, err := docker.NewClient(ctx)
	if err != nil {
		return err
	}
	defer cli.Close()

	name := requested
	if name == "" {
		existing, err := box.List(ctx, cli)
		if err != nil {
			return fmt.Errorf("create: %w", err)
		}
		taken := make(map[string]bool, len(existing))
		for _, b := range existing {
			taken[b.Name] = true
		}
		name, err = generateFreshBoxName(taken, func(candidate string) error {
			return box.PreflightFreshObjects(ctx, cli, candidate)
		})
		if err != nil {
			return fmt.Errorf("create: %w", err)
		}
	} else if err := names.Validate(name); err != nil {
		return fmt.Errorf("create: %w", err)
	}
	executorConfig, err := executorFlags.loadFresh(name)
	if err != nil {
		return fmt.Errorf("create %s: %w", name, err)
	}
	resources, err := resourceFlags.apply(box.DefaultResources())
	if err != nil {
		return fmt.Errorf("create %s: %w", name, err)
	}

	lockPath, err := state.LockPath(name)
	if err != nil {
		return fmt.Errorf("create %s: %w", name, err)
	}
	release, err := lock.Acquire(lockPath)
	if err != nil {
		return fmt.Errorf("create %s: %w", name, err)
	}
	defer release()

	exists, err := box.Exists(ctx, cli, name)
	if err != nil {
		return fmt.Errorf("create %s: %w", name, err)
	}
	if exists {
		return fmt.Errorf("create %s: box already exists", name)
	}
	if err := box.PreflightFreshObjects(ctx, cli, name); err != nil {
		return fmt.Errorf("create %s: %w", name, err)
	}

	imageTag := fmt.Sprintf("tx9-box:%s", version.Version)
	if err := ensureBoxImage(ctx, cli, imageTag); err != nil {
		return fmt.Errorf("create %s: %w", name, err)
	}

	tok, err := token.Mint()
	if err != nil {
		return fmt.Errorf("create %s: %w", name, err)
	}
	if err := box.SaveExecutorConfig(name, tok, executorConfig); err != nil {
		return fmt.Errorf("create %s: %w", name, err)
	}
	// Host mounts are machine-local desired state, not part of a portable
	// box. Never inherit them from a stale same-named env file.
	if err := box.SaveAgentMounts(name, nil); err != nil {
		return fmt.Errorf("create %s: %w", name, err)
	}
	if err := box.SaveResources(name, resources); err != nil {
		return fmt.Errorf("create %s: %w", name, err)
	}

	fmt.Printf("tx9: creating box %q (agent + executor containers, private network)\n", name)
	b, err := box.Create(ctx, cli, box.CreateOpts{
		Name: name, Image: imageTag, Token: tok, Executor: executorConfig, Resources: resources,
	})
	if err != nil {
		return errors.Join(fmt.Errorf("create %s: %w", name, err), box.Destroy(ctx, cli, name))
	}

	fmt.Println("tx9: preparing runtime (executor reachability, MCP wiring, doctor)")
	if err := box.PrepareRuntime(ctx, cli, b, tok, os.Stdout); err != nil {
		return errors.Join(fmt.Errorf("create %s: runtime failed: %w", name, err), box.Destroy(ctx, cli, name))
	}

	port, err := box.HostPort(ctx, cli, b)
	if err != nil {
		return fmt.Errorf("create %s: box is up but %w", name, err)
	}

	fmt.Printf("\nBox %q is ready. Next steps:\n", name)
	fmt.Printf("  1. tx9 enter %s\n", name)
	fmt.Println("  2. inside the box, authenticate claude/codex and run: hermes gateway setup")
	fmt.Println("  3. leave the foreground setup process, then enable TX9's durable gateway from the host:")
	fmt.Printf("       tx9 gateway enable %s --confirm-single-writer\n", name)
	fmt.Printf("  4. dashboard: %s (run `tx9 open %s` for a URL containing the persistent bearer token)\n", box.DashboardURL(port, b.ExecutorWebBaseURL), name)
	return nil
}

func generateFreshBoxName(taken map[string]bool, preflight func(string) error) (string, error) {
	for range 100 {
		name, err := names.Generate(taken)
		if err != nil {
			return "", err
		}
		if err := preflight(name); err == nil {
			return name, nil
		} else if !errors.Is(err, box.ErrObjectsExist) {
			return "", err
		}
		taken[name] = true
	}
	return "", fmt.Errorf("could not find an unused box name after 100 choices; pass an explicit name")
}
