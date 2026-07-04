package cli

import (
	"context"
	"flag"
	"fmt"
	"os"
	"strings"

	"github.com/davis7dotsh/tx9/internal/assets"
	"github.com/davis7dotsh/tx9/internal/docker"
	"github.com/davis7dotsh/tx9/internal/lock"
	"github.com/davis7dotsh/tx9/internal/state"
)

// parseFlagsAnywhere parses fs accepting flags before or after positional
// arguments (stdlib flag stops at the first positional, which silently
// ignores trailing flags like `tx9 delete mybox --force`). Everything after
// a literal "--" stays positional.
func parseFlagsAnywhere(fs *flag.FlagSet, args []string) error {
	var flags, positionals []string
	rest := false
	for i := 0; i < len(args); i++ {
		a := args[i]
		switch {
		case rest || a == "-" || len(a) == 0 || a[0] != '-':
			positionals = append(positionals, a)
		case a == "--":
			rest = true
		default:
			flags = append(flags, a)
			// a bool flag never consumes the next arg; others do unless
			// written as -name=value
			name := strings.TrimLeft(a, "-")
			if eq := strings.IndexByte(name, '='); eq >= 0 {
				name = name[:eq]
			} else if f := fs.Lookup(name); f != nil {
				if bf, ok := f.Value.(interface{ IsBoolFlag() bool }); !ok || !bf.IsBoolFlag() {
					if i+1 < len(args) {
						i++
						flags = append(flags, args[i])
					}
				}
			}
		}
	}
	return fs.Parse(append(flags, positionals...))
}

// requireBoxName returns fs's first positional argument as a box name, or
// an actionable usage error if it's missing.
func requireBoxName(fs *flag.FlagSet, cmd string) (string, error) {
	if fs.NArg() < 1 {
		return "", fmt.Errorf("%s: box name required (usage: tx9 %s <box>)", cmd, cmd)
	}
	return fs.Arg(0), nil
}

// withDocker opens a Docker Engine API client from the environment, runs
// fn, and always closes the client afterward.
func withDocker(fn func(ctx context.Context, cli *docker.Client) error) error {
	ctx := context.Background()
	cli, err := docker.NewClient(ctx)
	if err != nil {
		return err
	}
	defer cli.Close()
	return fn(ctx, cli)
}

// withBoxLock acquires the named box's non-blocking per-box operation lock
// (dossier §8.1: fail fast, never queue two concurrent tx9 operations
// against the same box), then runs fn with a connected Docker client. The
// lock is released and the client closed on return.
func withBoxLock(name string, fn func(ctx context.Context, cli *docker.Client) error) error {
	lockPath, err := state.LockPath(name)
	if err != nil {
		return err
	}
	release, err := lock.Acquire(lockPath)
	if err != nil {
		return err
	}
	defer release()

	return withDocker(fn)
}

// ensureBoxImage builds tag (e.g. "tx9-box:<version>") if the local image
// store doesn't already have it. Shared by create and upgrade: both need a
// current-version image on hand before creating containers from it, and
// the first build is the slow part (~10 min) either way.
func ensureBoxImage(ctx context.Context, cli *docker.Client, tag string) error {
	haveImage, err := cli.ImageExists(ctx, tag)
	if err != nil {
		return err
	}
	if haveImage {
		return nil
	}
	fmt.Printf("tx9: building %s (first build takes ~10 min; cached after)\n", tag)
	buildCtx, err := assets.BuildContextTar(BuildContext)
	if err != nil {
		return err
	}
	return cli.BuildImage(ctx, buildCtx, tag, os.Stdout)
}
