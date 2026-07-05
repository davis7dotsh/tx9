// Package main embeds the Docker build context (provision/, guest/,
// docker/Dockerfile + entrypoints, box.env) so tx9 ships a self-contained
// binary with no repo checkout required (decision 1, tx9-cli-design.md).
//
// This lives at the module root — not under internal/ — because go:embed
// patterns are resolved relative to the source file's directory and cannot
// reach outside it; provision/, guest/, and docker/ are siblings of this
// file, not of internal/assets. Since this file must share its directory
// with main.go (package main), and Go forbids importing a package literally
// named "main", internal/assets cannot import BuildContext directly. Instead
// main.go passes BuildContext down through internal/cli into internal/assets
// functions that accept an fs.FS parameter.
package main

import "embed"

//go:embed provision guest docker/Dockerfile docker/entrypoint.sh docker/executor-entrypoint.sh box.env
var BuildContext embed.FS
