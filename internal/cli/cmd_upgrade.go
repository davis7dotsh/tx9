package cli

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"os"

	"github.com/davis7dotsh/tx9/internal/box"
	"github.com/davis7dotsh/tx9/internal/docker"
	"github.com/davis7dotsh/tx9/internal/selfupdate"
	"github.com/davis7dotsh/tx9/internal/version"
)

// cmdUpgrade implements `tx9 upgrade [box]`.
//
// With a box argument: stop and remove both of the box's containers
// (network, volumes, and the minted token are left untouched), make sure
// the current CLI's image is built, then recreate both containers on that
// image via box.Create (which is idempotent against the pre-existing
// network/volumes) and run the same readiness gate `create` uses.
//
// With no argument: self-update the tx9 binary itself (internal/selfupdate,
// tx9-cli-design.md decision 11) — query the tx9 release site, download +
// checksum-verify the matching asset, and atomically replace the running
// executable.
func cmdUpgrade(args []string) error {
	fs := flag.NewFlagSet("upgrade", flag.ContinueOnError)
	force := fs.Bool("force", false, "self-update: skip the dev-build guard and reinstall even if already current")
	executorFlags := addExecutorConfigFlags(fs)
	if err := parseFlagsAnywhere(fs, args); err != nil {
		return err
	}

	if fs.NArg() == 0 {
		if executorFlags.hasOverrides() {
			return fmt.Errorf("upgrade: executor flags require a box name")
		}
		return cmdUpgradeSelf(*force)
	}
	if fs.NArg() != 1 {
		return fmt.Errorf("upgrade: expected at most one box name (usage: tx9 upgrade [box])")
	}
	name := fs.Arg(0)

	return withBoxLock(name, func(ctx context.Context, cli *docker.Client) error {
		b, err := box.Get(ctx, cli, name)
		if err != nil {
			return fmt.Errorf("upgrade %s: %w", name, err)
		}
		fromVersion := b.Version
		executorConfig, err := executorFlags.load(name)
		if err != nil {
			return fmt.Errorf("upgrade %s: %w", name, err)
		}
		agentMounts, err := box.LoadAgentMounts(name)
		if err != nil {
			return fmt.Errorf("upgrade %s: %w", name, err)
		}

		imageTag := fmt.Sprintf("tx9-box:%s", version.Version)
		if err := ensureBoxImage(ctx, cli, imageTag); err != nil {
			return fmt.Errorf("upgrade %s: %w", name, err)
		}

		// After the image build (which can take minutes) and immediately
		// before the destructive teardown, so a mount source that goes
		// offline in between fails while the old containers still exist.
		if err := box.PreflightAgentMounts(agentMounts); err != nil {
			return fmt.Errorf("upgrade %s: agent mount preflight: %w", name, err)
		}

		tok, err := box.Token(name)
		if err != nil {
			return fmt.Errorf("upgrade %s: %w", name, err)
		}
		if err := box.SaveExecutorConfig(name, tok, executorConfig); err != nil {
			return fmt.Errorf("upgrade %s: %w", name, err)
		}

		fmt.Printf("tx9: stopping and removing %s's containers (network/volumes/token kept)\n", name)
		if err := removeBoxContainers(ctx, cli, b); err != nil {
			return fmt.Errorf("upgrade %s: %w", name, err)
		}

		fmt.Printf("tx9: recreating %s on %s\n", name, imageTag)
		newB, err := box.Create(ctx, cli, box.CreateOpts{
			Name: name, Image: imageTag, Token: tok, Executor: executorConfig, AgentMounts: agentMounts,
		})
		if err != nil {
			// Create returns the box when the containers exist but failed to
			// start (e.g. a fixed --executor-publish port already bound).
			// They are labeled, so retrying the upgrade removes and recreates
			// them; no manual docker cleanup is needed either way.
			if newB != nil {
				return fmt.Errorf("upgrade %s: containers recreated but failed to start (fix the cause, then `tx9 start %s` or re-run the upgrade): %w", name, name, err)
			}
			return fmt.Errorf("upgrade %s: containers not recreated, box left without them (re-run the upgrade): %w", name, err)
		}

		fmt.Println("tx9: preparing runtime (executor reachability, MCP wiring, doctor)")
		if err := box.PrepareRuntime(ctx, cli, newB, tok, os.Stdout); err != nil {
			return fmt.Errorf("upgrade %s: runtime failed: %w", name, err)
		}

		if fromVersion == version.Version {
			fmt.Printf("tx9: box %s recreated (already on %s; containers reset)\n", name, version.Version)
		} else {
			fmt.Printf("tx9: box %s upgraded %s -> %s\n", name, displayVersion(fromVersion), version.Version)
		}
		return nil
	})
}

// cmdUpgradeSelf implements `tx9 upgrade` with no box argument: self-update
// the running binary via internal/selfupdate. ErrNoRelease and
// ErrDevVersion get their own actionable messages since they're the
// expected/common cases (no releases published yet; a `go run`/unversioned
// build); anything else from Update is returned as-is, already wrapped
// with context by that package.
func cmdUpgradeSelf(force bool) error {
	res, err := selfupdate.Update(selfupdate.Options{
		CurrentVersion: version.Version,
		Force:          force,
		Out:            os.Stdout,
	})
	if err != nil {
		if errors.Is(err, selfupdate.ErrNoRelease) {
			// ResolveOrigin("") names the origin Update actually queried
			// (TX9_ORIGIN or the default), not necessarily DefaultOrigin.
			return fmt.Errorf("upgrade: no releases published yet at %s (build from source, or check back after the first release)", selfupdate.ResolveOrigin(""))
		}
		// ErrDevVersion and everything else already read fine wrapped
		// plainly; selfupdate's own errors carry their own context.
		return fmt.Errorf("upgrade: %w", err)
	}

	if !res.Applied {
		fmt.Printf("tx9: already up to date (%s)\n", displayVersion(version.Version))
		return nil
	}
	fmt.Printf("tx9: upgraded %s -> %s\n", displayVersion(version.Version), res.ToVersion)
	return nil
}

// removeBoxContainers stops (best-effort) then force-removes a box's
// agent/executor containers, leaving its network, volumes, and token file
// alone — the part of box.Destroy this needs, without the rest of the
// teardown.
func removeBoxContainers(ctx context.Context, cli *docker.Client, b *box.Box) error {
	var errs []error
	if b.AgentID != "" {
		_ = cli.ContainerStop(ctx, b.AgentID, nil)
		if err := cli.ContainerRemove(ctx, b.AgentID, true); err != nil {
			errs = append(errs, fmt.Errorf("remove agent: %w", err))
		}
	}
	if b.ExecutorID != "" {
		_ = cli.ContainerStop(ctx, b.ExecutorID, nil)
		if err := cli.ContainerRemove(ctx, b.ExecutorID, true); err != nil {
			errs = append(errs, fmt.Errorf("remove executor: %w", err))
		}
	}
	return errors.Join(errs...)
}

func displayVersion(v string) string {
	if v == "" {
		return "?"
	}
	return v
}
