package cli

import (
	"context"
	"flag"
	"fmt"
	"os"

	"github.com/davis7dotsh/tx9/internal/archive"
	"github.com/davis7dotsh/tx9/internal/box"
	"github.com/davis7dotsh/tx9/internal/docker"
	"github.com/davis7dotsh/tx9/internal/names"
	"github.com/davis7dotsh/tx9/internal/token"
	"github.com/davis7dotsh/tx9/internal/version"
)

// restoreStageScript is boxd's stage-then-promote restore script, lifted
// verbatim (dossier §7.2), run inside a throwaway container that mounts
// the freshly-created (but not-yet-started) box's agent-data volume
// directly at /data. It wipes /data, extracts into a staging subdirectory,
// sanity-checks the tree, fixes ownership, re-arms the quiesce/gateway
// markers (dossier §7.3 — a restored box must always arrive quiesced and
// gateway-disabled regardless of the source box's state when it was
// saved), runs a last-chance hermes-state integrity check against the
// staged (not yet live) Hermes home, and only then promotes the staged
// tree up into /data itself.
const restoreStageScript = `set -euo pipefail
find /data -mindepth 1 -delete
stage=/data/.hb-restore-stage
mkdir -m 0700 "$stage"
tar xzf - --no-same-owner -C "$stage"
test -d "$stage/home/agent"
chown root:root "$stage" "$stage/home"
chmod 0711 "$stage" "$stage/home"
chown -R agent:agent "$stage/home/agent" "$stage/logs" 2>/dev/null || true
mkdir -p "$stage/home/agent/.config/hermes-box"
touch "$stage/home/agent/.config/hermes-box/quiesced" \
      "$stage/home/agent/.config/hermes-box/gateway-disabled" \
      "$stage/home/agent/.config/hermes-box/gateway-policy-initialized"
chown -R agent:agent "$stage/home/agent/.config/hermes-box"
runuser -u agent -- env HOME=/data/home/agent \
  /opt/hermes-box/bin/hermes-state verify --home "$stage/home/agent/.hermes" >/dev/null
shopt -s dotglob
mv "$stage"/* /data/
rmdir "$stage"
chown root:root /data && chmod 0711 /data
`

// cmdImport implements `tx9 import <file.tx9>`, the Go port of boxd's
// cmd_load (dossier §7): read metadata (plaintext, before touching the
// possibly-encrypted payload) -> resolve target name -> hard fail on
// collision -> decrypt+validate BEFORE creating anything -> mint a fresh
// token -> create network/volumes/containers without starting them ->
// stage-then-promote restore via a throwaway container -> start the box ->
// verify-state (not the full runtime-prep gate, since that would try to
// wire MCP against a box the restore deliberately leaves quiesced).
func cmdImport(args []string) error {
	fs := flag.NewFlagSet("import", flag.ContinueOnError)
	executorFlags := addExecutorConfigFlags(fs)
	nameOverride := fs.String("name", "", "box name to restore under (default: from archive metadata)")
	password := fs.String("password", "", "archive passphrase (else TX9_PASSWORD env, else prompt)")
	if err := parseFlagsAnywhere(fs, args); err != nil {
		return err
	}
	if fs.NArg() < 1 {
		return fmt.Errorf("import: archive file required (usage: tx9 import <file.tx9>)")
	}
	archivePath := fs.Arg(0)

	meta, err := archive.ReadMetadata(archivePath)
	if err != nil {
		return fmt.Errorf("import %s: %w", archivePath, err)
	}

	name := *nameOverride
	if name == "" {
		name = meta.BoxName
	}
	if err := names.Validate(name); err != nil {
		return fmt.Errorf("import %s: %w", archivePath, err)
	}
	executorConfig, err := executorFlags.load(name)
	if err != nil {
		return fmt.Errorf("import %s: %w", name, err)
	}

	var passphrase string
	if meta.Encrypted {
		passphrase, err = resolvePassword(*password, false)
		if err != nil {
			return fmt.Errorf("import %s: %w", archivePath, err)
		}
	}

	return withBoxLock(name, func(ctx context.Context, cli *docker.Client) error {
		if exists, err := box.Exists(ctx, cli, name); err != nil {
			return fmt.Errorf("import %s: %w", name, err)
		} else if exists {
			return fmt.Errorf("import %s: box %q already exists, choose a different --name or delete it first", name, name)
		}

		tmpDir, err := os.MkdirTemp("", "tx9-import-*")
		if err != nil {
			return fmt.Errorf("import %s: %w", name, err)
		}
		defer os.RemoveAll(tmpDir)

		fmt.Println("tx9: extracting archive payload")
		rawPath := tmpDir + "/data.payload"
		if _, err := archive.ExtractData(archivePath, rawPath); err != nil {
			return fmt.Errorf("import %s: %w", name, err)
		}

		dataTarGzPath := rawPath
		if meta.Encrypted {
			fmt.Println("tx9: decrypting archive")
			decPath := tmpDir + "/data.tar.gz"
			if err := archive.Decrypt(rawPath, decPath, passphrase); err != nil {
				return fmt.Errorf("import %s: %w", name, err)
			}
			dataTarGzPath = decPath
		}

		fmt.Println("tx9: validating archive contents")
		if err := validateFileAsDataTar(dataTarGzPath); err != nil {
			return fmt.Errorf("import %s: archive failed validation, refusing to restore: %w", name, err)
		}

		tok, err := token.Mint()
		if err != nil {
			return fmt.Errorf("import %s: %w", name, err)
		}
		if err := box.SaveExecutorConfig(name, tok, executorConfig); err != nil {
			return fmt.Errorf("import %s: %w", name, err)
		}

		imageTag := fmt.Sprintf("tx9-box:%s", version.Version)
		if err := ensureBoxImage(ctx, cli, imageTag); err != nil {
			return fmt.Errorf("import %s: %w", name, err)
		}

		fmt.Printf("tx9: creating box %q (network, volumes, containers — not started yet)\n", name)
		b, err := box.Create(ctx, cli, box.CreateOpts{
			Name: name, Image: imageTag, Token: tok, Executor: executorConfig, NoStart: true,
		})
		if err != nil {
			box.Destroy(ctx, cli, name)
			return fmt.Errorf("import %s: %w", name, err)
		}

		fmt.Println("tx9: restoring data into the agent volume (stage-then-promote)")
		agentVol, _ := box.VolumeNames(name)
		sf, err := os.Open(dataTarGzPath)
		if err != nil {
			box.Destroy(ctx, cli, name)
			return fmt.Errorf("import %s: %w", name, err)
		}
		exitCode, err := cli.RunEphemeral(ctx, docker.EphemeralOpts{
			Image:      imageTag,
			Entrypoint: []string{"bash"},
			Cmd:        []string{"-c", restoreStageScript},
			Binds:      []string{agentVol + ":/data"},
			Stdin:      sf,
			Stdout:     os.Stdout,
			Stderr:     os.Stderr,
		})
		sf.Close()
		if err != nil {
			box.Destroy(ctx, cli, name)
			return fmt.Errorf("import %s: stage-then-promote restore: %w", name, err)
		}
		if exitCode != 0 {
			box.Destroy(ctx, cli, name)
			return fmt.Errorf("import %s: stage-then-promote restore exited %d", name, exitCode)
		}

		fmt.Println("tx9: starting box")
		if err := box.Start(ctx, cli, b); err != nil {
			box.Destroy(ctx, cli, name)
			return fmt.Errorf("import %s: %w", name, err)
		}

		// Deliberately NOT box.PrepareRuntime: it unconditionally runs
		// `hb wire-once`, which would try to wire MCP against a box the
		// restore just arranged to arrive quiesced + gateway-disabled
		// (dossier §7.3). verify-state confirms the container/daemon
		// stack is healthy without touching that contract; a failure here
		// is a warning, not a reason to tear the box back down, since the
		// restore itself already succeeded.
		if err := box.HB(ctx, cli, b, tok, os.Stdout, os.Stderr, "verify-state"); err != nil {
			fmt.Fprintf(os.Stderr, "tx9: warning: post-import verify-state reported a problem, inspect the box before trusting it: %v\n", err)
		}

		fmt.Printf("\ntx9: box %q restored from %s.\n", name, archivePath)
		fmt.Println("It has arrived quiesced and with the Hermes gateway disabled (single-writer safety gate). Next steps:")
		fmt.Printf("  1. tx9 enter %s\n", name)
		fmt.Println("  2. hb resume")
		fmt.Printf("  3. tx9 gateway enable %s --confirm-single-writer\n", name)
		return nil
	})
}
