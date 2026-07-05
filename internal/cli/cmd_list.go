package cli

import (
	"context"
	"flag"
	"fmt"
	"os"
	"text/tabwriter"

	"github.com/davis7dotsh/tx9/internal/box"
	"github.com/davis7dotsh/tx9/internal/docker"
	"github.com/davis7dotsh/tx9/internal/version"
)

// cmdList implements `tx9 list` (command surface: all boxes on this
// machine from daemon labels — state, image version vs CLI version drift,
// dashboard URL).
func cmdList(args []string) error {
	fs := flag.NewFlagSet("list", flag.ContinueOnError)
	if err := parseFlagsAnywhere(fs, args); err != nil {
		return err
	}

	return withDocker(func(ctx context.Context, cli *docker.Client) error {
		boxes, err := box.List(ctx, cli)
		if err != nil {
			return fmt.Errorf("list: %w", err)
		}
		if len(boxes) == 0 {
			fmt.Println("no boxes (tx9 create to make one)")
			return nil
		}

		w := tabwriter.NewWriter(os.Stdout, 0, 4, 2, ' ', 0)
		fmt.Fprintln(w, "NAME\tSTATE\tIMAGE VERSION\tURL")
		for _, b := range boxes {
			state := b.DerivedState()

			url := "-"
			if state == "running" {
				if port, err := box.HostPort(ctx, cli, &b); err == nil {
					url = box.DashboardURL(port)
				}
			}

			fmt.Fprintf(w, "%s\t%s\t%s\t%s\n", b.Name, state, imageVersionDisplay(b.Version), url)
		}
		return w.Flush()
	})
}

// imageVersionDisplay formats a box's tx9.version label against the
// running CLI's own version, flagging drift the way `tx9 upgrade <box>`
// would resolve (spec: "0.1.0 (cli: 0.2.0)" when they differ).
func imageVersionDisplay(boxVersion string) string {
	if boxVersion == "" {
		return "?"
	}
	if boxVersion == version.Version {
		return boxVersion
	}
	return fmt.Sprintf("%s (cli: %s)", boxVersion, version.Version)
}
