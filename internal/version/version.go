// Package version holds the CLI's build-time version string.
package version

// Version is set via -ldflags at build time (see Makefile). Defaults to
// "dev" for `go run`/unversioned builds.
var Version = "dev"
