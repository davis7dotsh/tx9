package selfupdate

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// newTestServer serves a fake GitHub releases API + asset downloads for
// one release. assetContent is the payload for the platform binary asset
// named tx9_<goos>_<goarch>; checksums.txt is generated to match it.
func newTestServer(t *testing.T, tag, goos, goarch string, assetContent []byte) *httptest.Server {
	t.Helper()
	assetName := AssetName(goos, goarch)
	sum := sha256.Sum256(assetContent)
	checksums := fmt.Sprintf("%s  %s\n", hex.EncodeToString(sum[:]), assetName)

	mux := http.NewServeMux()
	var srv *httptest.Server
	mux.HandleFunc("/repos/"+Repo+"/releases/latest", func(w http.ResponseWriter, r *http.Request) {
		rel := Release{
			TagName: tag,
			Assets: []Asset{
				{Name: assetName, BrowserDownloadURL: srv.URL + "/download/" + assetName},
				{Name: checksumsAssetName, BrowserDownloadURL: srv.URL + "/download/" + checksumsAssetName},
			},
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(rel)
	})
	mux.HandleFunc("/download/"+assetName, func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write(assetContent)
	})
	mux.HandleFunc("/download/"+checksumsAssetName, func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(checksums))
	})
	srv = httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return srv
}

// apiURLClient points FetchLatestRelease's github.com/api URL at our test
// server by overriding the transport's DialContext... Instead of faking
// DNS, selfupdate.go builds the URL from the Repo constant against a fixed
// host, so tests use a small indirection: an http.Client whose Transport
// rewrites api.github.com requests to the test server.
type rewriteTransport struct {
	target string
	rt     http.RoundTripper
}

func (rt rewriteTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	if req.URL.Host == "api.github.com" {
		req.URL.Scheme = "http"
		req.URL.Host = rt.target[len("http://"):]
	}
	return rt.rt.RoundTrip(req)
}

func clientFor(srv *httptest.Server) *http.Client {
	return &http.Client{Transport: rewriteTransport{target: srv.URL, rt: http.DefaultTransport}}
}

func TestUpdateAlreadyUpToDate(t *testing.T) {
	srv := newTestServer(t, "v1.2.3", "linux", "amd64", []byte("binary contents"))
	res, err := Update(Options{
		CurrentVersion: "1.2.3",
		GOOS:           "linux",
		GOARCH:         "amd64",
		HTTPClient:     clientFor(srv),
	})
	if err != nil {
		t.Fatalf("Update: %v", err)
	}
	if res.Applied {
		t.Fatal("Update: Applied = true, want false (already up to date)")
	}
}

func TestUpdateDevVersionRefusesWithoutForce(t *testing.T) {
	_, err := Update(Options{CurrentVersion: "dev"})
	if err != ErrDevVersion {
		t.Fatalf("Update: err = %v, want ErrDevVersion", err)
	}
}

func TestUpdateDownloadsVerifiesAndReplaces(t *testing.T) {
	content := []byte("new binary contents v1.2.4")
	srv := newTestServer(t, "v1.2.4", "linux", "amd64", content)

	dir := t.TempDir()
	exePath := filepath.Join(dir, "tx9")
	if err := os.WriteFile(exePath, []byte("old binary contents"), 0o755); err != nil {
		t.Fatalf("seed old binary: %v", err)
	}

	opts := Options{
		CurrentVersion:   "1.2.3",
		GOOS:             "linux",
		GOARCH:           "amd64",
		HTTPClient:       clientFor(srv),
		execPathOverride: exePath,
	}
	res, err := Update(opts)
	if err != nil {
		t.Fatalf("Update: %v", err)
	}
	if !res.Applied {
		t.Fatal("Update: Applied = false, want true")
	}
	if res.ToVersion != "v1.2.4" {
		t.Errorf("Update: ToVersion = %q, want v1.2.4", res.ToVersion)
	}
	if res.InstalledPath != exePath {
		t.Errorf("Update: InstalledPath = %q, want %q", res.InstalledPath, exePath)
	}

	got, err := os.ReadFile(exePath)
	if err != nil {
		t.Fatalf("read installed binary: %v", err)
	}
	if string(got) != string(content) {
		t.Errorf("installed binary = %q, want %q", got, content)
	}
	info, err := os.Stat(exePath)
	if err != nil {
		t.Fatalf("stat installed binary: %v", err)
	}
	if info.Mode().Perm() != 0o755 {
		t.Errorf("installed binary mode = %o, want 0755", info.Mode().Perm())
	}
	if _, err := os.Stat(exePath + ".new"); !os.IsNotExist(err) {
		t.Errorf("stage file %s.new should be gone after a successful rename", exePath)
	}
}

func TestUpdateChecksumMismatchLeavesOldBinaryUntouched(t *testing.T) {
	dir := t.TempDir()
	exePath := filepath.Join(dir, "tx9")
	original := []byte("old binary contents")
	if err := os.WriteFile(exePath, original, 0o755); err != nil {
		t.Fatalf("seed old binary: %v", err)
	}

	// A server whose checksums.txt deliberately doesn't match the asset
	// it describes, to exercise the verify-before-install path.
	assetName := AssetName("linux", "amd64")
	badChecksum := strings.Repeat("0", 64)
	mux := http.NewServeMux()
	var srv *httptest.Server
	mux.HandleFunc("/repos/"+Repo+"/releases/latest", func(w http.ResponseWriter, r *http.Request) {
		rel := Release{
			TagName: "v1.2.4",
			Assets: []Asset{
				{Name: assetName, BrowserDownloadURL: srv.URL + "/download/" + assetName},
				{Name: checksumsAssetName, BrowserDownloadURL: srv.URL + "/download/checksums.txt"},
			},
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(rel)
	})
	mux.HandleFunc("/download/"+assetName, func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte("new binary contents"))
	})
	mux.HandleFunc("/download/checksums.txt", func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(badChecksum + "  " + assetName + "\n"))
	})
	srv = httptest.NewServer(mux)
	t.Cleanup(srv.Close)

	_, err := Update(Options{
		CurrentVersion:   "1.2.3",
		GOOS:             "linux",
		GOARCH:           "amd64",
		HTTPClient:       clientFor(srv),
		execPathOverride: exePath,
	})
	if err == nil {
		t.Fatal("Update: want checksum mismatch error, got nil")
	}

	got, err := os.ReadFile(exePath)
	if err != nil {
		t.Fatalf("read binary after failed update: %v", err)
	}
	if string(got) != string(original) {
		t.Errorf("binary was modified despite checksum mismatch: got %q, want unchanged %q", got, original)
	}
	if _, err := os.Stat(exePath + ".new"); !os.IsNotExist(err) {
		t.Errorf("stage file %s.new should be cleaned up after a failed update", exePath)
	}
}

func TestUpdateNoReleaseYet(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("/repos/"+Repo+"/releases/latest", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNotFound)
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)

	_, err := Update(Options{
		CurrentVersion: "1.2.3",
		HTTPClient:     clientFor(srv),
	})
	if err != ErrNoRelease {
		t.Fatalf("Update: err = %v, want ErrNoRelease", err)
	}
}
