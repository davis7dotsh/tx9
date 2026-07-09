package selfupdate

import (
	"fmt"
	"io"
	"net/http"
	"os"
	"regexp"
	"strings"
)

// DefaultOrigin is the release site self-update downloads from — the same
// Cloudflare Worker scripts/install.sh installs from (site/src/index.ts).
// The GitHub repo is private, so the GitHub releases API is not usable
// without credentials; the site mirrors every release publicly:
//
//	GET /releases/latest             current version, text/plain ("0.2.0\n")
//	GET /releases/<version>/<asset>  binaries + checksums.txt
//
// TX9_ORIGIN overrides it, mirroring install.sh's TX9_ORIGIN.
const DefaultOrigin = "https://tx9.col-agents.com"

// ErrNoRelease indicates the release site has no published version yet.
// /releases/latest returns 404 in that case, which is the expected state
// until the first `v*` tag is pushed (see .depot/workflows/release.yml) —
// callers should surface this as a clean, actionable message rather than
// a raw HTTP error.
var ErrNoRelease = fmt.Errorf("no releases published yet")

// ResolveOrigin returns the release site origin Update uses for a given
// Options.Origin: the override itself when non-empty, else TX9_ORIGIN,
// else DefaultOrigin. Trailing slashes are trimmed either way — the site
// worker routes exact paths, so "https://host//releases/latest" would 404
// and misread as "no releases". Exported so callers (internal/cli) can
// name the same origin Update actually queried in their own messages.
func ResolveOrigin(override string) string {
	origin := override
	if origin == "" {
		origin = DefaultOrigin
		if env := os.Getenv("TX9_ORIGIN"); env != "" {
			origin = env
		}
	}
	return strings.TrimRight(origin, "/")
}

// versionRE mirrors site/src/index.ts's VERSION_RE and install.sh's
// version check: plain X.Y.Z only. Anything else from /releases/latest is
// rejected before it's interpolated into a URL path.
var versionRE = regexp.MustCompile(`^\d+\.\d+\.\d+$`)

// fetchLatestVersion asks origin's /releases/latest for the current
// release version and returns it as a plain "X.Y.Z" string.
func fetchLatestVersion(client *http.Client, origin string) (string, error) {
	url := origin + "/releases/latest"
	req, err := http.NewRequest(http.MethodGet, url, nil)
	if err != nil {
		return "", fmt.Errorf("selfupdate: build request: %w", err)
	}
	req.Header.Set("User-Agent", userAgent)

	resp, err := client.Do(req)
	if err != nil {
		return "", fmt.Errorf("selfupdate: fetch latest version: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode == http.StatusNotFound {
		return "", ErrNoRelease
	}
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return "", fmt.Errorf("selfupdate: GET %s returned %s: %s", url, resp.Status, strings.TrimSpace(string(body)))
	}

	body, err := io.ReadAll(io.LimitReader(resp.Body, 4096))
	if err != nil {
		return "", fmt.Errorf("selfupdate: read %s: %w", url, err)
	}
	version := strings.TrimSpace(string(body))
	if !versionRE.MatchString(version) {
		return "", fmt.Errorf("selfupdate: unexpected version string from %s: %q", url, version)
	}
	return version, nil
}
