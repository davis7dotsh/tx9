// Package cli is tx9's command dispatcher: it parses the subcommand off
// os.Args and routes to the per-command implementation in its own
// cmd_*.go file. Every command is registered here so later work on
// individual commands never needs to touch this file.
package cli

import (
	"fmt"
	"io"
	"io/fs"
	"os"

	"github.com/davis7dotsh/tx9/internal/version"
)

// BuildContext is the embedded Docker build-context filesystem (provision/,
// guest/, docker/, box.env). It is set by Run from the root-level embed.FS
// in /assets.go — package main can't be imported by internal packages (see
// that file's doc comment for why), so it's threaded through here instead.
// Commands that build or rebuild the box image (create, upgrade) read it.
var BuildContext fs.FS

// commandFunc is the signature every subcommand implements. Each owns its
// own flag.FlagSet; args excludes the program name and the subcommand
// itself (i.e. it's exactly what flag.FlagSet.Parse expects).
type commandFunc func(args []string) error

type commandSpec struct {
	name    string
	help    string
	aliases []string
	run     commandFunc
}

// commandSpecs is the ordered source of truth for the command surface and
// aliases shown in help (matches docs/tx9-cli-design.md). registerCommands
// derives the dispatcher maps from it so aliases cannot drift from help.
var commandSpecs = []commandSpec{
	{name: "create", help: "generate/build if needed, create and start a new box", aliases: []string{"new"}, run: cmdCreate},
	{name: "list", help: "list boxes on this machine (state, image version, dashboard URL)", aliases: []string{"ls"}, run: cmdList},
	{name: "enter", help: "exec into a box's agent container (--executor for the executor container)", aliases: []string{"ssh", "shell"}, run: cmdEnter},
	{name: "start", help: "start a stopped box", run: cmdStart},
	{name: "stop", help: "stop a running box", run: cmdStop},
	{name: "logs", help: "query/export durable agent, Executor, Hermes, Codex, Claude, and custom-service events", run: cmdLogs},
	{name: "resources", help: "show/update container limits and volume budgets", run: cmdResources},
	{name: "backup", help: "archive a box to a .tx9 file", aliases: []string{"export", "save"}, run: cmdBackup},
	{name: "import", help: "restore a box from a .tx9 file", aliases: []string{"load", "restore"}, run: cmdImport},
	{name: "mount", help: "add/list/remove persistent agent host mounts", run: cmdMount},
	{name: "gateway", help: "status/enable/disable the supervised Hermes gateway", run: cmdGateway},
	{name: "open", help: "print/open a box's authenticated dashboard URL", run: cmdOpen},
	{name: "doctor", help: "run health checks against a box", run: cmdDoctor},
	{name: "upgrade", help: "self-update the CLI, or move a box onto the current image", aliases: []string{"update"}, run: cmdUpgrade},
	{name: "delete", help: "delete a box's containers, volumes, and state", aliases: []string{"rm", "remove"}, run: cmdDelete},
	{name: "prune", help: "remove unused tx9-box images and stale state", run: cmdPrune},
}

// commands and aliases are derived from commandSpecs in registerCommands.
var commands = map[string]commandFunc{}
var aliases = map[string]string{}

func registerCommands() {
	for _, spec := range commandSpecs {
		commands[spec.name] = spec.run
		for _, alias := range spec.aliases {
			aliases[alias] = spec.name
		}
	}
}

func init() {
	registerCommands()
}

// Run parses os.Args-style arguments (args[0] is the program name),
// dispatches to the matching subcommand, and returns a process exit code.
// buildContext is the embedded build-context filesystem from /assets.go.
func Run(args []string, buildContext fs.FS) int {
	return runWithOverview(args, buildContext, showOverview, os.Stdout, os.Stderr)
}

func runWithOverview(args []string, buildContext fs.FS, overview func(io.Writer) error, stdout, stderr io.Writer) int {
	BuildContext = buildContext

	if len(args) < 2 {
		if err := overview(stdout); err != nil {
			fmt.Fprintf(stderr, "tx9: overview: %v\n", err)
			fmt.Fprintf(stdout, "tx9 %s - box overview unavailable\n", version.Version)
			printCommandList(stdout)
			return 0
		}
		printCommandList(stdout)
		return 0
	}

	sub := args[1]
	rest := args[2:]

	switch sub {
	case "-h", "-help", "--help", "help":
		printUsage(stdout)
		return 0
	case "-v", "-version", "--version", "version":
		fmt.Fprintln(stdout, version.Version)
		return 0
	}

	if canonical, ok := aliases[sub]; ok {
		sub = canonical
	}

	fn, ok := commands[sub]
	if !ok {
		fmt.Fprintf(stderr, "tx9: unknown command %q\n\n", sub)
		printUsage(stderr)
		return 1
	}

	if err := fn(rest); err != nil {
		fmt.Fprintf(stderr, "tx9: %v\n", err)
		return 1
	}
	return 0
}

func printUsage(w io.Writer) {
	fmt.Fprintf(w, "tx9 %s — manage hermes boxes\n\n", version.Version)
	fmt.Fprintln(w, "Usage: tx9 <command> [args]")
	printCommandList(w)
	fmt.Fprintln(w, "\nAliases:")
	for _, spec := range commandSpecs {
		for _, alias := range spec.aliases {
			fmt.Fprintf(w, "  %-10s %s\n", alias, spec.name)
		}
	}
	fmt.Fprintln(w, "\nOther:")
	fmt.Fprintln(w, "  help       show this message")
	fmt.Fprintln(w, "  version    print the CLI version")
	fmt.Fprintln(w, "\nFlags:")
	fmt.Fprintln(w, "  -h, --help     show this message")
	fmt.Fprintln(w, "  -v, --version  print the CLI version")
}

func printCommandList(w io.Writer) {
	fmt.Fprintln(w, "\nCommands:")
	for _, spec := range commandSpecs {
		fmt.Fprintf(w, "  %-10s %s\n", spec.name, spec.help)
	}
}
