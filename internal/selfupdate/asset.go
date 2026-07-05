package selfupdate

import "fmt"

// AssetName returns the release asset name tx9 publishes for a given
// GOOS/GOARCH pair: a plain, uncompressed executable, no extension. This
// is the one naming invariant shared by this package, the Makefile's
// `dist` target, and .github/workflows/release.yml — all three must agree,
// or self-update silently can't find its own binary.
func AssetName(goos, goarch string) string {
	return fmt.Sprintf("tx9_%s_%s", goos, goarch)
}
