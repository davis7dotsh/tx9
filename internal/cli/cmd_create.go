package cli

import (
	"context"
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
	if err := parseFlagsAnywhere(fs, args); err != nil {
		return err
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
		name, err = names.Generate(taken)
		if err != nil {
			return fmt.Errorf("create: %w", err)
		}
	} else if err := names.Validate(name); err != nil {
		return fmt.Errorf("create: %w", err)
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

	imageTag := fmt.Sprintf("tx9-box:%s", version.Version)
	if err := ensureBoxImage(ctx, cli, imageTag); err != nil {
		return fmt.Errorf("create %s: %w", name, err)
	}

	tok, err := token.Mint()
	if err != nil {
		return fmt.Errorf("create %s: %w", name, err)
	}
	if err := state.WriteBoxEnv(name, map[string]string{"EXECUTOR_MCP_TOKEN": tok}); err != nil {
		return fmt.Errorf("create %s: %w", name, err)
	}

	fmt.Printf("tx9: creating box %q (agent + executor containers, private network)\n", name)
	b, err := box.Create(ctx, cli, box.CreateOpts{Name: name, Image: imageTag, Token: tok})
	if err != nil {
		box.Destroy(ctx, cli, name)
		return fmt.Errorf("create %s: %w", name, err)
	}

	fmt.Println("tx9: preparing runtime (executor reachability, MCP wiring, doctor)")
	if err := box.PrepareRuntime(ctx, cli, b, tok, os.Stdout); err != nil {
		box.Destroy(ctx, cli, name)
		return fmt.Errorf("create %s: runtime failed, box removed: %w", name, err)
	}

	port, err := box.HostPort(ctx, cli, b)
	if err != nil {
		return fmt.Errorf("create %s: box is up but %w", name, err)
	}

	fmt.Printf("\nBox %q is ready. Next steps:\n", name)
	fmt.Printf("  1. tx9 enter %s\n", name)
	fmt.Println("  2. inside the box, authenticate: claude (Claude Code) and codex")
	fmt.Println("  3. when ready to go live, run (the only path that starts the gateway):")
	fmt.Println("       hb gateway-enable --confirm-single-writer I_CONFIRM_NO_OTHER_GATEWAY_USES_THIS_IDENTITY")
	fmt.Printf("  4. dashboard: %s (run `tx9 open %s` for an authenticated one-shot URL)\n", box.DashboardURL(port), name)
	return nil
}
