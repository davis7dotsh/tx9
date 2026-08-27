package cli

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/docker/docker/api/types/network"
	dockerclient "github.com/docker/docker/client"

	"github.com/davis7dotsh/tx9/internal/box"
	"github.com/davis7dotsh/tx9/internal/docker"
	"github.com/davis7dotsh/tx9/internal/lock"
	"github.com/davis7dotsh/tx9/internal/names"
	"github.com/davis7dotsh/tx9/internal/state"
	"github.com/davis7dotsh/tx9/internal/version"
)

// cmdPrune implements `tx9 prune`: garbage-collect stale tx9-box:* images
// (superseded versions no container references) and orphaned per-box state
// files (~/.tx9/boxes/*.env with no matching box left in the daemon).
// State files are checked again under their per-box lock before removal.
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
		if err := names.Validate(name); err != nil {
			fmt.Fprintf(os.Stderr, "tx9: skipping state file %q: invalid box name\n", e.Name())
			continue
		}
		if known[name] {
			continue
		}

		deleted, err := pruneStateFile(name, func() (bool, error) {
			return boxStateInUse(ctx, cli, name)
		})
		if err != nil {
			return removed, err
		}
		if deleted {
			removed = append(removed, filepath.Join(dir, e.Name()))
		}
	}
	return removed, nil
}

func boxStateInUse(ctx context.Context, cli *docker.Client, name string) (bool, error) {
	exists, err := box.Exists(ctx, cli, name)
	if err != nil || exists {
		return exists, err
	}
	// A failed upgrade or manual container removal can leave a recoverable
	// box with only its volumes. Keep its token and configuration until all
	// durable objects have gone, even if their ownership labels are missing.
	agent, executor := box.VolumeNames(name)
	for _, volume := range []string{agent, executor} {
		if _, err := cli.Raw().VolumeInspect(ctx, volume); err == nil {
			return true, nil
		} else if !dockerclient.IsErrNotFound(err) {
			return false, err
		}
	}
	if _, err := cli.Raw().NetworkInspect(ctx, box.NetworkName(name), network.InspectOptions{}); err == nil {
		return true, nil
	} else if !dockerclient.IsErrNotFound(err) {
		return false, err
	}
	return false, nil
}

func pruneStateFile(name string, exists func() (bool, error)) (bool, error) {
	lockPath, err := state.LockPath(name)
	if err != nil {
		return false, err
	}
	release, err := lock.Acquire(lockPath)
	if err != nil {
		if errors.Is(err, lock.ErrBusy) {
			fmt.Printf("tx9: skipping %s: operation in progress\n", name)
			return false, nil
		}
		return false, err
	}
	defer release()

	// Create/import may have finished since the initial list, or upgrade
	// may have temporarily removed both containers. The lock alone does
	// not make that earlier snapshot safe to use.
	live, err := exists()
	if err != nil {
		return false, fmt.Errorf("recheck box %s before pruning state: %w", name, err)
	}
	if live {
		return false, nil
	}
	path, err := state.BoxEnvPath(name)
	if err != nil {
		return false, err
	}
	if err := os.Remove(path); err != nil {
		if os.IsNotExist(err) {
			return false, nil
		}
		return false, fmt.Errorf("remove %s: %w", path, err)
	}
	return true, nil
}
