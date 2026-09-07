// Package selfupdate implements `tx9 upgrade` with no box argument
// (docs/tx9-cli-design.md decision 11): it queries the tx9 release site
// (the same origin scripts/install.sh installs from — the GitHub repo is
// private, so the GitHub API is not usable anonymously) for the latest
// release version, compares it against the running binary's version,
// downloads and checksum-verifies the matching platform asset, and
// atomically replaces the currently running executable.
//
// Asset naming (the one invariant shared across this package, the
// Makefile's `dist` target, scripts/install.sh, site/src/index.ts, and
// .depot/workflows/release.yml): plain, uncompressed executables named
// "tx9_<GOOS>_<GOARCH>" (see AssetName), plus a "checksums.txt" asset in
// `sha256sum` output format (see ParseChecksums). Changing this naming
// means changing it everywhere.
package selfupdate

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"time"
)

const (
	checksumsAssetName = "checksums.txt"
	userAgent          = "tx9-selfupdate"
)

// Options configures Update.
type Options struct {
	// CurrentVersion is the running binary's version (internal/version.Version).
	CurrentVersion string
	// Force permits replacing a dev, custom, equal, or newer version with the
	// site's latest release.
	Force bool
	// Origin overrides the release site origin. Zero value means
	// DefaultOrigin, unless TX9_ORIGIN is set (same override install.sh
	// honors).
	Origin string
	// GOOS/GOARCH override runtime.GOOS/GOARCH. Tests only; zero value
	// means "use the running binary's platform".
	GOOS, GOARCH string
	// HTTPClient overrides the default client used for both the version
	// check and the asset downloads. Tests only; zero value means
	// "use a client with a sane timeout".
	HTTPClient *http.Client
	// Out receives human-readable progress lines. Defaults to io.Discard.
	Out io.Writer

	// execPathOverride replaces the os.Executable()+EvalSymlinks lookup.
	// Tests only (unexported): Update must never overwrite the actual
	// running test binary.
	execPathOverride string
}

// Result summarizes a completed (or skipped) update.
type Result struct {
	// Applied is false when the binary was already at the latest version
	// or newer and Force was not set. Nothing was downloaded or replaced.
	Applied bool
	// FromVersion is the version that was running before Update was called.
	FromVersion string
	// ToVersion is the latest release version, plain "X.Y.Z".
	ToVersion string
	// InstalledPath is the executable path that was replaced. Empty when
	// Applied is false.
	InstalledPath string
}

// ErrDevVersion is returned when CurrentVersion is "dev" (an unversioned
// `go build`/`go run`) and Force is not set — there is no meaningful
// "latest" to compare a dev build against, and self-replacing a
// developer's working binary without asking is surprising.
var ErrDevVersion = fmt.Errorf("running a dev build (no version baked in); build a release or pass --force")

// Update runs the full self-update flow described in the package doc.
func Update(opts Options) (*Result, error) {
	out := opts.Out
	if out == nil {
		out = io.Discard
	}

	if opts.CurrentVersion == "" || opts.CurrentVersion == "dev" {
		if !opts.Force {
			return nil, ErrDevVersion
		}
	}
	if _, numeric := splitNumeric(normalizeVersion(opts.CurrentVersion)); !numeric && !opts.Force {
		return nil, fmt.Errorf("cannot order custom version %q against releases; pass --force to replace it", opts.CurrentVersion)
	}

	client := opts.HTTPClient
	if client == nil {
		client = &http.Client{Timeout: 30 * time.Second}
	}

	origin := ResolveOrigin(opts.Origin)

	fmt.Fprintln(out, "tx9: checking latest release...")
	latest, err := fetchLatestVersion(client, origin)
	if err != nil {
		return nil, err
	}

	if !opts.Force && CompareVersions(opts.CurrentVersion, latest) >= 0 {
		return &Result{Applied: false, FromVersion: opts.CurrentVersion, ToVersion: latest}, nil
	}

	goos, goarch := opts.GOOS, opts.GOARCH
	if goos == "" {
		goos = runtime.GOOS
	}
	if goarch == "" {
		goarch = runtime.GOARCH
	}
	assetName := AssetName(goos, goarch)

	// Versioned paths are immutable on the site, so resolve the version
	// once and download both objects from it — a release published between
	// the two requests can't mismatch the checksums against the binary.
	baseURL := fmt.Sprintf("%s/releases/%s", origin, latest)
	assetURL := baseURL + "/" + assetName
	checksumsURL := baseURL + "/" + checksumsAssetName

	// Resolve the running executable's real path before touching the
	// network for the (larger) binary asset, so a broken install layout
	// fails fast instead of after a wasted download.
	realPath := opts.execPathOverride
	if realPath == "" {
		exePath, err := os.Executable()
		if err != nil {
			return nil, fmt.Errorf("selfupdate: locate running executable: %w", err)
		}
		realPath, err = filepath.EvalSymlinks(exePath)
		if err != nil {
			return nil, fmt.Errorf("selfupdate: resolve running executable %q: %w", exePath, err)
		}
	}

	fmt.Fprintf(out, "tx9: fetching checksums for %s...\n", latest)
	checksumsData, err := fetchBytes(client, checksumsURL)
	if err != nil {
		return nil, fmt.Errorf("selfupdate: download %s: %w", checksumsAssetName, err)
	}
	sums, err := ParseChecksums(checksumsData)
	if err != nil {
		return nil, fmt.Errorf("selfupdate: parse %s: %w", checksumsAssetName, err)
	}
	wantDigest, ok := sums[assetName]
	if !ok {
		return nil, fmt.Errorf("selfupdate: %s has no checksum entry for %q (unsupported platform?)", checksumsAssetName, assetName)
	}

	// Create an exclusive, private sibling so concurrent updates cannot
	// truncate each other's downloads or follow a pre-existing .new symlink.
	stage, err := os.CreateTemp(filepath.Dir(realPath), "."+filepath.Base(realPath)+".update-*")
	if err != nil {
		return nil, fmt.Errorf("selfupdate: create staged binary: %w", err)
	}
	stagePath := stage.Name()
	defer os.Remove(stagePath)
	defer stage.Close()
	fmt.Fprintf(out, "tx9: downloading %s %s -> %s\n", assetName, latest, stagePath)
	gotDigest, err := downloadToFile(client, assetURL, stage)
	if err != nil {
		return nil, fmt.Errorf("selfupdate: download %s: %w", assetName, err)
	}
	if gotDigest != wantDigest {
		return nil, fmt.Errorf("selfupdate: checksum mismatch for %s: got %s, want %s (old binary untouched)", assetName, gotDigest, wantDigest)
	}

	if err := stage.Chmod(0o755); err != nil {
		return nil, fmt.Errorf("selfupdate: chmod staged binary: %w (old binary untouched)", err)
	}
	if err := stage.Sync(); err != nil {
		return nil, fmt.Errorf("selfupdate: sync staged binary: %w (old binary untouched)", err)
	}
	if err := stage.Close(); err != nil {
		return nil, fmt.Errorf("selfupdate: close staged binary: %w (old binary untouched)", err)
	}

	// stagePath is a sibling of realPath (same directory), so this rename
	// is same-filesystem and atomic. On Linux, renaming over the binary a
	// process is currently executing is safe: the running process keeps
	// its already-mapped inode; the new inode simply takes the path.
	if err := os.Rename(stagePath, realPath); err != nil {
		return nil, fmt.Errorf("selfupdate: install new binary at %s: %w (old binary untouched)", realPath, err)
	}

	fmt.Fprintf(out, "tx9: installed %s at %s\n", latest, realPath)
	return &Result{
		Applied:       true,
		FromVersion:   opts.CurrentVersion,
		ToVersion:     latest,
		InstalledPath: realPath,
	}, nil
}

// fetchBytes downloads url and returns its full body. Used for the small
// checksums.txt asset.
func fetchBytes(client *http.Client, url string) ([]byte, error) {
	req, err := http.NewRequest(http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", userAgent)

	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("GET %s: %s", url, resp.Status)
	}
	return io.ReadAll(io.LimitReader(resp.Body, 1<<20)) // 1MiB is generous for a checksums file
}

// downloadToFile streams url's body into an already-open destination while
// hashing it. The caller owns the file and its permissions and lifetime.
func downloadToFile(client *http.Client, url string, dest io.Writer) (string, error) {
	req, err := http.NewRequest(http.MethodGet, url, nil)
	if err != nil {
		return "", err
	}
	req.Header.Set("User-Agent", userAgent)

	resp, err := client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("GET %s: %s", url, resp.Status)
	}

	h := sha256.New()
	if _, err := io.Copy(io.MultiWriter(dest, h), resp.Body); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}
