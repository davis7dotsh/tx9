// Command tx9 creates and manages hermes boxes (see docs/tx9-cli-design.md).
package main

import (
	"os"

	"github.com/davis7dotsh/tx9/internal/cli"
)

func main() {
	os.Exit(cli.Run(os.Args, BuildContext))
}
