// Package cli is tx9's command dispatcher: it parses the subcommand off
// os.Args and routes to the per-command implementation in its own
// cmd_*.go file. Every command is registered here so later work on
// individual commands never needs to touch this file.
package cli

import (
	"fmt"
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

// commands maps canonical subcommand names to their implementation.
// Registered in registerCommands below.
var commands = map[string]commandFunc{}

// commandOrder lists canonical subcommand names in the order they should
// appear in help output (matches the command surface table in
// docs/tx9-cli-design.md).
var commandOrder = []string{
	"create", "list", "enter", "start", "stop", "backup", "import",
	"gateway", "open", "doctor", "upgrade", "delete", "prune",
}

// commandHelp is a one-line description per canonical command, for help
// output (matches docs/tx9-cli-design.md's command surface table).
var commandHelp = map[string]string{
	"create":  "generate/build if needed, create and start a new box",
	"list":    "list boxes on this machine (state, image version, dashboard URL)",
	"enter":   "exec into a box's agent container (alias: ssh; --executor for the executor container)",
	"start":   "start a stopped box",
	"stop":    "stop a running box",
	"backup":  "archive a box to a .tx9 file (alias: export)",
	"import":  "restore a box from a .tx9 file",
	"gateway": "status/enable/disable the supervised Hermes gateway",
	"open":    "print/open a box's authenticated dashboard URL",
	"doctor":  "run health checks against a box",
	"upgrade": "self-update the CLI, or move a box onto the current image",
	"delete":  "delete a box's containers, volumes, and state",
	"prune":   "remove unused tx9-box images and stale state",
}

// aliases maps alternate spellings to their canonical command name
// (decision 4: enter/ssh and backup/export are aliases).
var aliases = map[string]string{
	"ssh":    "enter",
	"export": "backup",
}

func registerCommands() {
	commands["create"] = cmdCreate
	commands["list"] = cmdList
	commands["enter"] = cmdEnter
	commands["start"] = cmdStart
	commands["stop"] = cmdStop
	commands["backup"] = cmdBackup
	commands["import"] = cmdImport
	commands["gateway"] = cmdGateway
	commands["open"] = cmdOpen
	commands["doctor"] = cmdDoctor
	commands["upgrade"] = cmdUpgrade
	commands["delete"] = cmdDelete
	commands["prune"] = cmdPrune
}

func init() {
	registerCommands()
}

// Run parses os.Args-style arguments (args[0] is the program name),
// dispatches to the matching subcommand, and returns a process exit code.
// buildContext is the embedded build-context filesystem from /assets.go.
func Run(args []string, buildContext fs.FS) int {
	BuildContext = buildContext

	if len(args) < 2 {
		printUsage(os.Stdout)
		return 1
	}

	sub := args[1]
	rest := args[2:]

	switch sub {
	case "-h", "-help", "--help", "help":
		printUsage(os.Stdout)
		return 0
	case "-v", "-version", "--version", "version":
		fmt.Println(version.Version)
		return 0
	}

	if canonical, ok := aliases[sub]; ok {
		sub = canonical
	}

	fn, ok := commands[sub]
	if !ok {
		fmt.Fprintf(os.Stderr, "tx9: unknown command %q\n\n", sub)
		printUsage(os.Stderr)
		return 1
	}

	if err := fn(rest); err != nil {
		fmt.Fprintf(os.Stderr, "tx9: %v\n", err)
		return 1
	}
	return 0
}

func printUsage(w *os.File) {
	fmt.Fprintf(w, "tx9 %s — manage hermes boxes\n\n", version.Version)
	fmt.Fprintln(w, "Usage: tx9 <command> [args]")
	fmt.Fprintln(w, "\nCommands:")
	for _, name := range commandOrder {
		fmt.Fprintf(w, "  %-10s %s\n", name, commandHelp[name])
	}
	fmt.Fprintln(w, "\nAliases: ssh -> enter, export -> backup")
	fmt.Fprintln(w, "\nOther:")
	fmt.Fprintln(w, "  help       show this message")
	fmt.Fprintln(w, "  version    print the CLI version")
	fmt.Fprintln(w, "\nFlags:")
	fmt.Fprintln(w, "  -h, --help     show this message")
	fmt.Fprintln(w, "  -v, --version  print the CLI version")
}
