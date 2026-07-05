package cli

import (
	"context"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/davis7dotsh/tx9/internal/box"
	"github.com/davis7dotsh/tx9/internal/docker"
	"github.com/davis7dotsh/tx9/internal/lock"
	"github.com/davis7dotsh/tx9/internal/state"
	"github.com/davis7dotsh/tx9/internal/version"
)

// cmdPrune implements `tx9 prune`: garbage-collect stale tx9-box:* images
// (superseded versions no container references) and orphaned per-box state
// files (~/.tx9/boxes/*.env with no matching box left in the daemon).
// Unlike other lifecycle commands, prune spans every box at once, so it
// doesn't take a per-box lock — it only ever removes things nothing is
// using.
func cmdPrune(args []string) error {
	fs := flag.NewFlagSet("prune", flag.ContinueOnError)
	if err := parseFlagsAnywhere(fs, args); err != nil {
		return err
	}

	return withDocker(func(ctx context.Context, cli *docker.Client) error {
		removedImages, err := pruneImages(ctx, cli)
		if err != nil {
			return fmt.Errorf("prune: %w", err)
		}
		removedEnvFiles, err := pruneStateFiles(ctx, cli)
		if err != nil {
			return fmt.Errorf("prune: %w", err)
		}

		if len(removedImages) == 0 && len(removedEnvFiles) == 0 {
			fmt.Println("tx9: nothing to prune")
			return nil
		}
		for _, tag := range removedImages {
			fmt.Printf("tx9: removed unused image %s\n", tag)
		}
		for _, path := range removedEnvFiles {
			fmt.Printf("tx9: removed stale state file %s\n", path)
		}
		return nil
	})
}

// pruneImages removes tx9-box:* images whose version tag isn't the
// running CLI's own version AND aren't referenced by any container tx9
// still knows about (running or stopped — a stopped box still "uses" its
// image). The current version's image is always kept even if unused,
// since it's what the next `create`/`upgrade` needs.
func pruneImages(ctx context.Context, cli *docker.Client) ([]string, error) {
	images, err := cli.ImageList(ctx, "tx9-box:*")
	if err != nil {
		return nil, err
	}

	containers, err := cli.ListBoxContainers(ctx)
	if err != nil {
		return nil, err
	}
	inUse := map[string]bool{}
	for _, c := range containers {
		inUse[c.Image] = true
		inUse[c.ImageID] = true
	}

	currentTag := fmt.Sprintf("tx9-box:%s", version.Version)

	var removed []string
	for _, img := range images {
		if inUse[img.ID] {
			continue
		}

		keep := false
		usedByTag := false
		for _, tag := range img.RepoTags {
			if tag == currentTag {
				keep = true
			}
			if inUse[tag] {
				usedByTag = true
			}
		}
		if keep || usedByTag {
			continue
		}

		if err := cli.ImageRemove(ctx, img.ID); err != nil {
			return removed, err
		}
		if len(img.RepoTags) > 0 {
			removed = append(removed, img.RepoTags[0])
		} else {
			removed = append(removed, img.ID)
		}
	}
	return removed, nil
}

// pruneStateFiles removes ~/.tx9/boxes/<name>.env files with no
// corresponding box left in the daemon — leftovers from a box deleted by
// some other means (e.g. `docker rm` directly) that skipped tx9's own
// cleanup.
func pruneStateFiles(ctx context.Context, cli *docker.Client) ([]string, error) {
	boxes, err := box.List(ctx, cli)
	if err != nil {
		return nil, err
	}
	known := make(map[string]bool, len(boxes))
	for _, b := range boxes {
		known[b.Name] = true
	}

	dir, err := state.BoxesDir()
	if err != nil {
		return nil, err
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, fmt.Errorf("read %s: %w", dir, err)
	}

	var removed []string
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".env") {
			continue
		}
		name := strings.TrimSuffix(e.Name(), ".env")
		if known[name] {
			continue
		}

		// An env file is written by create/import before either of them
		// takes this box's per-box lock and holds it for their entire
		// run, so a box with no containers yet (known[name] == false)
		// might just be mid-create/mid-import rather than truly
		// orphaned. Try the same non-blocking lock they use; if it's
		// held, skip this file instead of deleting state out from under
		// a running operation.
		lockPath, err := state.LockPath(name)
		if err != nil {
			return removed, err
		}
		release, err := lock.Acquire(lockPath)
		if err != nil {
			fmt.Printf("tx9: skipping %s: operation in progress\n", name)
			continue
		}

		path := filepath.Join(dir, e.Name())
		rmErr := os.Remove(path)
		release()
		if rmErr != nil {
			return removed, fmt.Errorf("remove %s: %w", path, rmErr)
		}
		removed = append(removed, path)
	}
	return removed, nil
}
