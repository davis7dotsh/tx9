package cli

import (
	"bytes"
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"

	"golang.org/x/term"

	"github.com/davis7dotsh/tx9/internal/archive"
	"github.com/davis7dotsh/tx9/internal/box"
	"github.com/davis7dotsh/tx9/internal/docker"
	"github.com/davis7dotsh/tx9/internal/version"
)

// tarExclusions is the exact --exclude set boxd's cmd_save uses (dossier
// §6.2), in order: (1) the quiesce marker itself — a restored box must not
// start life "already quiesced" for no reason (import re-arms it
// deliberately instead, dossier §7.3); (2/3) codex/hermes tmp dirs (dossier
// §10 gotcha); (4-6) package manager caches/venvs (bulk, regenerable);
// (7/8) compiled Python bytecode; (9-11) live SQLite WAL/SHM/journal
// sidecar files (checkpointed separately by `hermes-state verify
// --checkpoint` during pause, so excluding them here is safe and avoids
// restoring a torn WAL); (12-15) process-lifecycle PID/lock/state files
// meaningless outside the process that wrote them.
var tarExclusions = []string{
	"./home/agent/.config/hermes-box/quiesced",
	"./home/agent/.codex/tmp",
	"./home/agent/.hermes/tmp",
	// Self-update launcher symlinks (claude update, codex update). Their
	// targets are absolute — which the archive validator refuses — and
	// point at either image content (/opt) or a versioned path that the
	// next self-update in the restored box recreates anyway.
	"./home/agent/.local/bin/claude",
	"./home/agent/.local/bin/codex",
	"*/node_modules",
	"*/.venv",
	"*/venv",
	"*/__pycache__",
	"*/.cache",
	"*.pyc",
	"*.pyo",
	"*/.hermes/*.db-wal",
	"*/.hermes/*.db-shm",
	"*/.hermes/*.db-journal",
	"*/gateway.pid",
	"*/cron.pid",
	"*/gateway.lock",
	"*/processes.json",
}

// buildTarScript reproduces boxd's cmd_save tar invocation verbatim
// (dossier §6.2): `tar czf - -C /data <excludes> .`, run inside the
// running agent container so /data (the agent-data volume) is captured
// exactly as the box sees it, with `sync` first so any just-flushed
// writes are on disk before the tar starts.
func buildTarScript() string {
	var b strings.Builder
	b.WriteString("set -euo pipefail; umask 077; sync\n")
	b.WriteString("tar czf - -C /data")
	for _, ex := range tarExclusions {
		fmt.Fprintf(&b, " --exclude=%q", ex)
	}
	b.WriteString(" .")
	return b.String()
}

// cmdBackup implements `tx9 backup <box>` (alias: export), the Go port of
// boxd's cmd_save (dossier §6): quiesce -> tar /data inside the running
// agent container -> validate -> encrypt (unless --no-encrypt) -> verify
// -> assemble a .tx9 container -> place it atomically -> resume the box if
// backup was the one that paused it.
func cmdBackup(args []string) error {
	fs := flag.NewFlagSet("backup", flag.ContinueOnError)
	path := fs.String("path", "", "output directory (default ~/Downloads)")
	password := fs.String("password", "", "archive passphrase (else TX9_PASSWORD env, else prompt)")
	noEncrypt := fs.Bool("no-encrypt", false, "skip GPG encryption")
	if err := parseFlagsAnywhere(fs, args); err != nil {
		return err
	}
	name, err := requireBoxName(fs, "backup")
	if err != nil {
		return err
	}

	destDir := *path
	if destDir == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return fmt.Errorf("backup %s: %w", name, err)
		}
		destDir = filepath.Join(home, "Downloads")
	}
	if err := os.MkdirAll(destDir, 0o755); err != nil {
		return fmt.Errorf("backup %s: create output directory %s: %w", name, destDir, err)
	}

	encrypted := !*noEncrypt
	var passphrase string
	if encrypted {
		passphrase, err = resolvePassword(*password, true)
		if err != nil {
			return fmt.Errorf("backup %s: %w", name, err)
		}
	}

	return withBoxLock(name, func(ctx context.Context, cli *docker.Client) error {
		b, err := box.Get(ctx, cli, name)
		if err != nil {
			return fmt.Errorf("backup %s: %w", name, err)
		}
		if b.AgentID == "" {
			return fmt.Errorf("backup %s: agent container missing", name)
		}
		tok, err := box.Token(name)
		if err != nil {
			return fmt.Errorf("backup %s: %w", name, err)
		}

		weQuiesced, err := quiesceForBackup(ctx, cli, b, tok)
		if err != nil {
			return fmt.Errorf("backup %s: %w", name, err)
		}
		if weQuiesced {
			defer func() {
				fmt.Println("tx9: resuming box")
				if rerr := box.HB(ctx, cli, b, tok, os.Stdout, os.Stderr, "resume"); rerr != nil {
					fmt.Fprintf(os.Stderr, "tx9: warning: failed to resume box %s after backup, resume it manually with `hb resume`: %v\n", name, rerr)
				}
			}()
		}

		// boxd's cmd_save always runs these two after quiescing,
		// unconditionally (dossier §6 / git show 9a030e2^:docker/boxd
		// ~L405-415) — not just when we were the ones who paused. Relying
		// solely on `hb pause`'s own checkpoint would skip it whenever
		// the box was already paused, and boxd's runtime-manifest write
		// never happened at all, so both are run here regardless of
		// weQuiesced.
		fmt.Println("tx9: checkpointing state")
		if err := box.HB(ctx, cli, b, tok, io.Discard, os.Stderr, "verify-state", "--checkpoint"); err != nil {
			return fmt.Errorf("backup %s: %w", name, err)
		}
		if err := box.HB(ctx, cli, b, tok, os.Stdout, os.Stderr, "write-manifest"); err != nil {
			return fmt.Errorf("backup %s: %w", name, err)
		}

		fmt.Println("tx9: capturing /data from the agent container")
		rawFile, err := os.CreateTemp("", "tx9-backup-*.tar.gz")
		if err != nil {
			return fmt.Errorf("backup %s: %w", name, err)
		}
		rawPath := rawFile.Name()
		defer os.Remove(rawPath)

		var stderrBuf bytes.Buffer
		exitCode, err := cli.ExecStream(ctx, b.AgentID, []string{"bash", "-c", buildTarScript()}, nil, "", rawFile, &stderrBuf)
		closeErr := rawFile.Close()
		if err != nil {
			return fmt.Errorf("backup %s: tar exec: %w", name, err)
		}
		if closeErr != nil {
			return fmt.Errorf("backup %s: %w", name, closeErr)
		}
		if exitCode != 0 {
			return fmt.Errorf("backup %s: tar exited %d: %s", name, exitCode, strings.TrimSpace(stderrBuf.String()))
		}

		fmt.Println("tx9: validating archive contents")
		if err := validateFileAsDataTar(rawPath); err != nil {
			return fmt.Errorf("backup %s: refusing to save an unsafe archive: %w", name, err)
		}

		dataFile := rawPath
		if encrypted {
			fmt.Println("tx9: encrypting archive")
			encPath := rawPath + ".gpg"
			defer os.Remove(encPath)
			if err := archive.Encrypt(rawPath, encPath, passphrase); err != nil {
				return fmt.Errorf("backup %s: %w", name, err)
			}
			if err := archive.VerifyEncrypted(encPath, passphrase); err != nil {
				return fmt.Errorf("backup %s: %w", name, err)
			}
			dataFile = encPath
		}

		ts := time.Now()
		meta := archive.Metadata{
			BoxName:      name,
			CreatedAt:    ts,
			CLIVersion:   version.Version,
			ImageVersion: b.Version,
			Encrypted:    encrypted,
		}

		finalName := fmt.Sprintf("%s-%s.tx9", name, ts.Format("20060102-150405"))
		finalPath := filepath.Join(destDir, finalName)
		stagingPath := filepath.Join(destDir, fmt.Sprintf(".%s.staging-%d", finalName, os.Getpid()))

		if err := writeTx9Staged(stagingPath, meta, dataFile); err != nil {
			os.Remove(stagingPath)
			return fmt.Errorf("backup %s: %w", name, err)
		}
		// ln (hard link), not mv/cp: fails loudly if finalPath already
		// exists rather than silently clobbering a prior backup of the
		// same name (dossier §6.5's atomic no-clobber placement).
		if err := os.Link(stagingPath, finalPath); err != nil {
			os.Remove(stagingPath)
			return fmt.Errorf("backup %s: place archive at %s: %w", name, finalPath, err)
		}
		os.Remove(stagingPath)

		info, statErr := os.Stat(finalPath)
		if statErr != nil {
			fmt.Printf("tx9: backup complete: %s\n", finalPath)
		} else {
			fmt.Printf("tx9: backup complete: %s (%d bytes)\n", finalPath, info.Size())
		}
		return nil
	})
}

// quiesceForBackup implements dossier §6.1: check `hb is-paused`; if not
// already paused, call `hb pause` and report that the caller must resume
// afterward. A non-nil error from `is-paused` is treated as "not paused"
// (hb's own is-paused check exits non-zero in that case, mirroring boxd's
// `_guest_hb` usage).
func quiesceForBackup(ctx context.Context, cli *docker.Client, b *box.Box, token string) (weQuiesced bool, err error) {
	paused := box.HB(ctx, cli, b, token, nil, nil, "is-paused") == nil
	if paused {
		return false, nil
	}
	fmt.Println("tx9: pausing box for a consistent snapshot")
	if err := box.HB(ctx, cli, b, token, os.Stdout, os.Stderr, "pause"); err != nil {
		return false, fmt.Errorf("pause: %w", err)
	}
	return true, nil
}

// validateFileAsDataTar opens path and runs archive.ValidateDataTar over it.
func validateFileAsDataTar(path string) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()
	return archive.ValidateDataTar(f)
}

// writeTx9Staged assembles a complete .tx9 container at stagingPath using
// archive.WriteTx9, so the potentially-slow copy/gzip-framing work happens
// on a name nothing else can be watching before the atomic hard-link
// promotion in cmdBackup.
func writeTx9Staged(stagingPath string, meta archive.Metadata, dataFile string) error {
	out, err := os.OpenFile(stagingPath, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return fmt.Errorf("stage archive: %w", err)
	}
	writeErr := archive.WriteTx9(out, meta, dataFile)
	closeErr := out.Close()
	if writeErr != nil {
		return fmt.Errorf("stage archive: %w", writeErr)
	}
	if closeErr != nil {
		return fmt.Errorf("stage archive: %w", closeErr)
	}
	return nil
}

// readPassword prompts on /dev/tty with echo disabled (dossier §6.4's
// interactive-prompt fallback) and always restores the original terminal
// state afterward. x/term rather than raw termios ioctls: TCGETS/TCSETS
// are Linux-only names (darwin spells them TIOCGETA/TIOCSETA), which broke
// the darwin cross-compile in the release workflow.
func readPassword(prompt string) (string, error) {
	tty, err := os.OpenFile("/dev/tty", os.O_RDWR, 0)
	if err != nil {
		return "", fmt.Errorf("read password: open /dev/tty: %w", err)
	}
	defer tty.Close()

	fmt.Fprint(tty, prompt)
	pw, err := term.ReadPassword(int(tty.Fd()))
	fmt.Fprintln(tty)
	if err != nil {
		return "", fmt.Errorf("read password: %w", err)
	}
	return string(pw), nil
}

// resolvePassword implements the flag > env > interactive-prompt
// precedence used by both backup and import ("--password" flag, else
// TX9_PASSWORD env, else prompt). When confirm is true (backup minting a
// new passphrase), the operator must type it twice matching.
func resolvePassword(flagVal string, confirm bool) (string, error) {
	if flagVal != "" {
		return flagVal, nil
	}
	if env := os.Getenv("TX9_PASSWORD"); env != "" {
		return env, nil
	}
	pw, err := readPassword("Archive passphrase: ")
	if err != nil {
		return "", err
	}
	if pw == "" {
		return "", errors.New("archive passphrase must not be empty")
	}
	if confirm {
		pw2, err := readPassword("Confirm passphrase: ")
		if err != nil {
			return "", err
		}
		if pw2 != pw {
			return "", errors.New("passphrases did not match")
		}
	}
	return pw, nil
}
