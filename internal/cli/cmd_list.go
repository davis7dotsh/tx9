package cli

import (
	"context"
	"flag"
	"fmt"
	"os"
	"sync"
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
	if fs.NArg() != 0 {
		return fmt.Errorf("list: unexpected positional arguments (usage: tx9 list)")
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

		urls := collectListURLs(boxes, func(b *box.Box) (string, error) {
			port, err := box.HostPort(ctx, cli, b)
			if err != nil {
				return "", err
			}
			return box.DashboardURL(port, b.ExecutorWebBaseURL), nil
		})
		w := tabwriter.NewWriter(os.Stdout, 0, 4, 2, ' ', 0)
		fmt.Fprintln(w, "NAME\tSTATE\tIMAGE VERSION\tURL")
		for i, b := range boxes {
			fmt.Fprintf(w, "%s\t%s\t%s\t%s\n", b.Name, b.DerivedState(), imageVersionDisplay(b.Version), urls[i])
		}
		return w.Flush()
	})
}

// Limit daemon load while inspecting independent dashboards in parallel.
// Indexed writes preserve the box list's sorted order and tolerate disappearing
// containers without hiding other boxes' URLs.
func collectListURLs(boxes []box.Box, lookup func(*box.Box) (string, error)) []string {
	urls := make([]string, len(boxes))
	for i := range urls {
		urls[i] = "-"
	}
	var wg sync.WaitGroup
	jobs := make(chan int)
	for range min(4, len(boxes)) {
		wg.Go(func() {
			for i := range jobs {
				if url, err := lookup(&boxes[i]); err == nil {
					urls[i] = url
				}
			}
		})
	}
	for i := range boxes {
		if boxes[i].DerivedState() == "running" {
			jobs <- i
		}
	}
	close(jobs)
	wg.Wait()
	return urls
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
