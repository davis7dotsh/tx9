package selfupdate

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
)

// Repo is the GitHub repository release assets are published to.
const Repo = "davis7dotsh/tx9"

// ErrNoRelease indicates the repository has no published releases yet.
// GitHub's /releases/latest returns 404 in that case, which is the
// expected state until the first `v*` tag is pushed (see
// .github/workflows/release.yml) — callers should surface this as a
// clean, actionable message rather than a raw HTTP error.
var ErrNoRelease = fmt.Errorf("no releases published yet")

// Asset is one file attached to a GitHub release.
type Asset struct {
	Name               string `json:"name"`
	BrowserDownloadURL string `json:"browser_download_url"`
}

// Release is the subset of the GitHub releases API response this package
// needs.
type Release struct {
	TagName string  `json:"tag_name"`
	Assets  []Asset `json:"assets"`
}

// FindAsset returns the asset in r named name, or false if absent.
func (r *Release) FindAsset(name string) (Asset, bool) {
	for _, a := range r.Assets {
		if a.Name == name {
			return a, true
		}
	}
	return Asset{}, false
}

func (r *Release) assetNames() string {
	names := make([]string, len(r.Assets))
	for i, a := range r.Assets {
		names[i] = a.Name
	}
	return strings.Join(names, ", ")
}

// FetchLatestRelease queries the GitHub API for Repo's latest release. It
// honors the GITHUB_TOKEN environment variable (if set) as a bearer
// credential on the API call only, to avoid the low unauthenticated rate
// limit — it is deliberately NOT attached to asset download requests,
// since browser_download_url responses are signed redirects that an extra
// Authorization header can break.
func FetchLatestRelease(httpClient *http.Client) (*Release, error) {
	url := fmt.Sprintf("https://api.github.com/repos/%s/releases/latest", Repo)
	req, err := http.NewRequest(http.MethodGet, url, nil)
	if err != nil {
		return nil, fmt.Errorf("selfupdate: build request: %w", err)
	}
	req.Header.Set("User-Agent", userAgent)
	req.Header.Set("Accept", "application/vnd.github+json")
	if tok := os.Getenv("GITHUB_TOKEN"); tok != "" {
		req.Header.Set("Authorization", "Bearer "+tok)
	}

	resp, err := httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("selfupdate: fetch latest release: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode == http.StatusNotFound {
		return nil, ErrNoRelease
	}
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return nil, fmt.Errorf("selfupdate: GitHub API returned %s: %s", resp.Status, strings.TrimSpace(string(body)))
	}

	var rel Release
	if err := json.NewDecoder(resp.Body).Decode(&rel); err != nil {
		return nil, fmt.Errorf("selfupdate: decode release response: %w", err)
	}
	if rel.TagName == "" {
		return nil, fmt.Errorf("selfupdate: release response missing tag_name")
	}
	return &rel, nil
}
