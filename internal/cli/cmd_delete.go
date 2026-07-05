package cli

import (
	"bufio"
	"context"
	"flag"
	"fmt"
	"os"
	"strings"

	"github.com/davis7dotsh/tx9/internal/box"
	"github.com/davis7dotsh/tx9/internal/docker"
)

// cmdDelete implements `tx9 delete <box>`: containers + volumes + token
// file, typed-name confirmation (--force to skip).
func cmdDelete(args []string) error {
	fs := flag.NewFlagSet("delete", flag.ContinueOnError)
	force := fs.Bool("force", false, "skip typed-name confirmation")
	if err := parseFlagsAnywhere(fs, args); err != nil {
		return err
	}
	name, err := requireBoxName(fs, "delete")
	if err != nil {
		return err
	}

	if !*force {
		if err := confirmName(name); err != nil {
			return err
		}
	}

	return withBoxLock(name, func(ctx context.Context, cli *docker.Client) error {
		if exists, err := box.Exists(ctx, cli, name); err != nil {
			return fmt.Errorf("delete %s: %w", name, err)
		} else if !exists {
			return fmt.Errorf("delete %s: box does not exist", name)
		}
		if err := box.Destroy(ctx, cli, name); err != nil {
			return fmt.Errorf("delete %s: %w", name, err)
		}
		fmt.Printf("tx9: box %s deleted\n", name)
		return nil
	})
}

// confirmName prompts on stdin and requires the operator to type the exact
// box name back, a deliberate "destructive-by-default" friction distinct
// from a plain --yes flag (mirrors gateway_enable's confirm-phrase pattern,
// dossier §9, though delete's confirmation is the name itself).
func confirmName(name string) error {
	fmt.Printf("Type the box name to confirm deletion of %q: ", name)
	reader := bufio.NewReader(os.Stdin)
	line, err := reader.ReadString('\n')
	if err != nil {
		return fmt.Errorf("delete %s: could not read confirmation: %w", name, err)
	}
	if strings.TrimSpace(line) != name {
		return fmt.Errorf("delete %s: confirmation did not match, aborting", name)
	}
	return nil
}
