package cli

import (
	"context"
	"flag"
	"fmt"

	"github.com/davis7dotsh/tx9/internal/box"
	"github.com/davis7dotsh/tx9/internal/docker"
)

// cmdStart implements `tx9 start <box>`: start both containers together.
// Volumes persist.
func cmdStart(args []string) error {
	fs := flag.NewFlagSet("start", flag.ContinueOnError)
	if err := parseFlagsAnywhere(fs, args); err != nil {
		return err
	}
	name, err := requireBoxName(fs, "start")
	if err != nil {
		return err
	}

	return withBoxLock(name, func(ctx context.Context, cli *docker.Client) error {
		b, err := box.Get(ctx, cli, name)
		if err != nil {
			return fmt.Errorf("start %s: %w", name, err)
		}
		if err := box.Start(ctx, cli, b); err != nil {
			return fmt.Errorf("start %s: %w", name, err)
		}
		fmt.Printf("tx9: box %s started\n", name)
		return nil
	})
}

// cmdStop implements `tx9 stop <box>`: stop both containers together.
// Volumes persist.
func cmdStop(args []string) error {
	fs := flag.NewFlagSet("stop", flag.ContinueOnError)
	if err := parseFlagsAnywhere(fs, args); err != nil {
		return err
	}
	name, err := requireBoxName(fs, "stop")
	if err != nil {
		return err
	}

	return withBoxLock(name, func(ctx context.Context, cli *docker.Client) error {
		b, err := box.Get(ctx, cli, name)
		if err != nil {
			return fmt.Errorf("stop %s: %w", name, err)
		}
		if err := box.Stop(ctx, cli, b); err != nil {
			return fmt.Errorf("stop %s: %w", name, err)
		}
		fmt.Printf("tx9: box %s stopped\n", name)
		return nil
	})
}
