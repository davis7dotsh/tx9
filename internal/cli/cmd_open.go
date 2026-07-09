package cli

import (
	"context"
	"flag"
	"fmt"
	"os"
	"os/exec"

	"github.com/davis7dotsh/tx9/internal/box"
	"github.com/davis7dotsh/tx9/internal/docker"
)

// cmdOpen implements `tx9 open <box>`: print (or open) the authenticated
// dashboard URL (?_token=). Mirrors boxd's cmd_open (dossier §4): the
// token-bearing URL is a one-shot secret, distinct from `create`'s printed
// (unauthenticated) dashboard URL.
func cmdOpen(args []string) error {
	fs := flag.NewFlagSet("open", flag.ContinueOnError)
	if err := parseFlagsAnywhere(fs, args); err != nil {
		return err
	}
	name, err := requireBoxName(fs, "open")
	if err != nil {
		return err
	}

	return withDocker(func(ctx context.Context, cli *docker.Client) error {
		b, err := box.Get(ctx, cli, name)
		if err != nil {
			return fmt.Errorf("open %s: %w", name, err)
		}
		if b.DerivedState() != "running" {
			return fmt.Errorf("open %s: box is not running; run: tx9 start %s", name, name)
		}

		port, err := box.HostPort(ctx, cli, b)
		if err != nil {
			return fmt.Errorf("open %s: %w", name, err)
		}
		tok, err := box.Token(name)
		if err != nil {
			return fmt.Errorf("open %s: %w", name, err)
		}

		url, err := box.OpenURL(port, tok, b.ExecutorWebBaseURL)
		if err != nil {
			return fmt.Errorf("open %s: %w", name, err)
		}

		if browser := firstNonEmpty(os.Getenv("TX9_BROWSER"), os.Getenv("BOX_BROWSER")); browser != "" {
			if _, lookErr := exec.LookPath(browser); lookErr == nil {
				if runErr := exec.Command(browser, url).Start(); runErr == nil {
					fmt.Printf("tx9: opened dashboard for %s\n", name)
					return nil
				}
			}
		}

		fmt.Println("tx9: dashboard URL — this embeds a bearer token, treat it as a secret:")
		fmt.Println(url)
		return nil
	})
}

func firstNonEmpty(vals ...string) string {
	for _, v := range vals {
		if v != "" {
			return v
		}
	}
	return ""
}
