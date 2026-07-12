package cli

import (
	"context"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"time"

	"github.com/davis7dotsh/tx9/internal/box"
	"github.com/davis7dotsh/tx9/internal/docker"
)

const logsHelperPath = "/opt/hermes-box/bin/tx9-logs"

type logsQueryOptions struct {
	Source   string
	Tail     int
	Since    string
	Contains string
	JSON     bool
	NoRedact bool
}

func cmdLogs(args []string) error {
	action, args := splitLogsAction(args)
	if action == "export" {
		return cmdLogsExport(args)
	}

	fs := flag.NewFlagSet("logs", flag.ContinueOnError)
	opts := logsQueryOptions{}
	fs.StringVar(&opts.Source, "source", "all", "comma-separated sources: agent,executor,hermes,codex,claude")
	fs.IntVar(&opts.Tail, "tail", 200, "show the newest N matching events")
	fs.StringVar(&opts.Since, "since", "", "only events after a duration or RFC3339 timestamp (for example 24h)")
	fs.StringVar(&opts.Contains, "grep", "", "only events containing text")
	fs.BoolVar(&opts.JSON, "json", false, "emit normalized JSONL")
	fs.BoolVar(&opts.NoRedact, "no-redact", false, "include sensitive values instead of redacting known token forms")
	if err := parseFlagsAnywhere(fs, args); err != nil {
		return err
	}
	name, err := requireBoxName(fs, "logs")
	if err != nil {
		return err
	}
	if opts.Tail < 1 {
		return fmt.Errorf("logs %s: --tail must be at least 1", name)
	}

	return withBoxLock(name, func(ctx context.Context, cli *docker.Client) error {
		b, err := box.Get(ctx, cli, name)
		if err != nil {
			return fmt.Errorf("logs %s: %w", name, err)
		}
		image, err := boxImageRef(ctx, cli, b)
		if err != nil {
			return fmt.Errorf("logs %s: %w", name, err)
		}
		return runLogsHelper(ctx, cli, image, name, "query", opts, os.Stdout, os.Stderr)
	})
}

func splitLogsAction(args []string) (string, []string) {
	if len(args) > 0 && args[0] == "export" {
		return "export", args[1:]
	}
	// Query is the default and intentionally has no explicit action word:
	// `query` was already a valid box name before this command existed.
	return "query", args
}

func cmdLogsExport(args []string) error {
	fs := flag.NewFlagSet("logs export", flag.ContinueOnError)
	opts := logsQueryOptions{}
	output := fs.String("output", "", "output .tar.gz path (default: <box>-logs-<timestamp>.tar.gz)")
	fs.StringVar(&opts.Source, "source", "all", "comma-separated sources: agent,executor,hermes,codex,claude")
	fs.StringVar(&opts.Since, "since", "", "only events after a duration or RFC3339 timestamp (for example 24h)")
	fs.StringVar(&opts.Contains, "grep", "", "only events containing text")
	fs.BoolVar(&opts.NoRedact, "no-redact", false, "include sensitive values instead of redacting known token forms")
	if err := parseFlagsAnywhere(fs, args); err != nil {
		return err
	}
	name, err := requireBoxName(fs, "logs export")
	if err != nil {
		return err
	}

	destination := *output
	if destination == "" {
		destination = fmt.Sprintf("%s-logs-%s.tar.gz", name, time.Now().UTC().Format("20060102T150405Z"))
	}
	destination, err = filepath.Abs(destination)
	if err != nil {
		return fmt.Errorf("logs export %s: resolve output: %w", name, err)
	}
	if err := os.MkdirAll(filepath.Dir(destination), 0o755); err != nil {
		return fmt.Errorf("logs export %s: create output directory: %w", name, err)
	}
	out, err := os.OpenFile(destination, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return fmt.Errorf("logs export %s: create %s: %w", name, destination, err)
	}
	succeeded := false
	defer func() {
		_ = out.Close()
		if !succeeded {
			_ = os.Remove(destination)
		}
	}()

	err = withBoxLock(name, func(ctx context.Context, cli *docker.Client) error {
		b, err := box.Get(ctx, cli, name)
		if err != nil {
			return fmt.Errorf("logs export %s: %w", name, err)
		}
		image, err := boxImageRef(ctx, cli, b)
		if err != nil {
			return fmt.Errorf("logs export %s: %w", name, err)
		}
		return runLogsHelper(ctx, cli, image, name, "export", opts, out, os.Stderr)
	})
	if err != nil {
		return err
	}
	if err := out.Sync(); err != nil {
		return fmt.Errorf("logs export %s: sync %s: %w", name, destination, err)
	}
	if err := out.Close(); err != nil {
		return fmt.Errorf("logs export %s: close %s: %w", name, destination, err)
	}
	succeeded = true
	fmt.Printf("tx9: exported logs for %s to %s\n", name, destination)
	return nil
}

func runLogsHelper(ctx context.Context, cli *docker.Client, image, name, action string, opts logsQueryOptions, stdout, stderr io.Writer) error {
	agentVolume, executorVolume := box.VolumeNames(name)
	cmd := logsHelperArgs(action, name, opts)
	helperEnv, err := logsHelperEnvironment(name)
	if err != nil {
		return fmt.Errorf("load redaction values: %w", err)
	}

	exitCode, err := cli.RunEphemeral(ctx, docker.EphemeralOpts{
		Image:      image,
		Entrypoint: []string{logsHelperPath},
		Cmd:        cmd,
		Env:        helperEnv,
		Binds: []string{
			agentVolume + ":/agent:ro",
			executorVolume + ":/executor:ro",
		},
		Stdout: stdout,
		Stderr: stderr,
	})
	if err != nil {
		return fmt.Errorf("log helper failed (upgrade the box if it predates tx9 logs): %w", err)
	}
	if exitCode != 0 {
		return fmt.Errorf("log helper exited %d (upgrade the box if it predates tx9 logs)", exitCode)
	}
	return nil
}

func logsHelperEnvironment(name string) ([]string, error) {
	token, err := box.Token(name)
	if err != nil {
		return nil, err
	}
	return []string{"TX9_QUERY_TOKEN=" + token}, nil
}

func logsHelperArgs(action, name string, opts logsQueryOptions) []string {
	cmd := []string{
		action,
		"--agent-root", "/agent",
		"--executor-root", "/executor",
		"--box", name,
		"--source", opts.Source,
	}
	if opts.Tail > 0 {
		cmd = append(cmd, "--tail", strconv.Itoa(opts.Tail))
	}
	if opts.Since != "" {
		cmd = append(cmd, "--since", opts.Since)
	}
	if opts.Contains != "" {
		cmd = append(cmd, "--grep", opts.Contains)
	}
	if opts.JSON {
		cmd = append(cmd, "--json")
	}
	if opts.NoRedact {
		cmd = append(cmd, "--no-redact")
	}
	return cmd
}

func boxImageRef(ctx context.Context, cli *docker.Client, b *box.Box) (string, error) {
	for _, id := range []string{b.AgentID, b.ExecutorID} {
		if id == "" {
			continue
		}
		inspect, err := cli.ContainerInspect(ctx, id)
		if err != nil {
			continue
		}
		if inspect.Config != nil && inspect.Config.Image != "" {
			return inspect.Config.Image, nil
		}
	}
	return "", fmt.Errorf("could not determine a box image from its containers")
}
