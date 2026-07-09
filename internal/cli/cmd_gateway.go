package cli

import (
	"context"
	"flag"
	"fmt"
	"os"

	"github.com/davis7dotsh/tx9/internal/box"
	"github.com/davis7dotsh/tx9/internal/docker"
)

const singleWriterConfirmation = "I_CONFIRM_NO_OTHER_GATEWAY_USES_THIS_IDENTITY"

// cmdGateway controls the container-supervised Hermes gateway. It deliberately
// goes through hb rather than `hermes gateway run`: the latter is a foreground
// process and dies with the terminal or tmux pane that launched it.
func cmdGateway(args []string) error {
	fs := flag.NewFlagSet("gateway", flag.ContinueOnError)
	confirmed := fs.Bool(
		"confirm-single-writer",
		false,
		"confirm no other gateway is using this messaging identity",
	)
	if err := parseFlagsAnywhere(fs, args); err != nil {
		return err
	}
	if fs.NArg() != 2 {
		return fmt.Errorf("gateway: expected an action and box name (usage: tx9 gateway <status|enable|disable> <box>)")
	}
	action, name := fs.Arg(0), fs.Arg(1)
	hbCommands, err := gatewayHBCommands(action, *confirmed)
	if err != nil {
		return err
	}

	return withBoxLock(name, func(ctx context.Context, cli *docker.Client) error {
		b, err := box.Get(ctx, cli, name)
		if err != nil {
			return fmt.Errorf("gateway %s %s: %w", action, name, err)
		}
		if b.AgentState != "running" {
			return fmt.Errorf("gateway %s %s: agent container is not running; run: tx9 start %s", action, name, name)
		}
		// status and disable never talk to the executor, so they must keep
		// working on a box whose host-side token cache is missing — disable
		// especially, since it's the recovery path.
		token, err := box.Token(name)
		if err != nil {
			if action == "enable" {
				return fmt.Errorf("gateway %s %s: %w", action, name, err)
			}
			token = ""
		}
		for _, hbArgs := range hbCommands {
			if err := box.HB(ctx, cli, b, token, os.Stdout, os.Stderr, hbArgs...); err != nil {
				return fmt.Errorf("gateway %s %s: %w", action, name, err)
			}
		}
		return nil
	})
}

func gatewayHBCommands(action string, confirmed bool) ([][]string, error) {
	switch action {
	case "status":
		return [][]string{{"status"}}, nil
	case "disable":
		return [][]string{{"gateway-disable"}}, nil
	case "enable":
		if !confirmed {
			return nil, fmt.Errorf("gateway enable requires --confirm-single-writer after every identity migration or first activation")
		}
		return [][]string{
			{"gateway-disable"},
			{
				"gateway-enable",
				"--confirm-single-writer",
				singleWriterConfirmation,
			},
		}, nil
	default:
		return nil, fmt.Errorf("gateway: unknown action %q (expected status, enable, or disable)", action)
	}
}
