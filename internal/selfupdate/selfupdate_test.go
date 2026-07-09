package selfupdate

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// newTestServer serves a fake release site (site/src/index.ts's URL
// contract) for one release. assetContent is the payload for the platform
// binary asset named tx9_<goos>_<goarch>; checksums.txt is generated to
// match it.
func newTestServer(t *testing.T, version, goos, goarch string, assetContent []byte) *httptest.Server {
	t.Helper()
	assetName := AssetName(goos, goarch)
	sum := sha256.Sum256(assetContent)
	checksums := fmt.Sprintf("%s  %s\n", hex.EncodeToString(sum[:]), assetName)

	mux := http.NewServeMux()
	mux.HandleFunc("/releases/latest", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, "%s\n", version)
	})
	mux.HandleFunc("/releases/"+version+"/"+assetName, func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write(assetContent)
	})
	mux.HandleFunc("/releases/"+version+"/"+checksumsAssetName, func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(checksums))
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return srv
}

func TestUpdateAlreadyUpToDate(t *testing.T) {
	srv := newTestServer(t, "1.2.3", "linux", "amd64", []byte("binary contents"))
	res, err := Update(Options{
		CurrentVersion: "1.2.3",
		Origin:         srv.URL,
		GOOS:           "linux",
		GOARCH:         "amd64",
		HTTPClient:     srv.Client(),
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
	srv := newTestServer(t, "1.2.4", "linux", "amd64", content)

	dir := t.TempDir()
	exePath := filepath.Join(dir, "tx9")
	if err := os.WriteFile(exePath, []byte("old binary contents"), 0o755); err != nil {
		t.Fatalf("seed old binary: %v", err)
	}

	opts := Options{
		CurrentVersion:   "1.2.3",
		Origin:           srv.URL,
		GOOS:             "linux",
		GOARCH:           "amd64",
		HTTPClient:       srv.Client(),
		execPathOverride: exePath,
	}
	res, err := Update(opts)
	if err != nil {
		t.Fatalf("Update: %v", err)
	}
	if !res.Applied {
		t.Fatal("Update: Applied = false, want true")
	}
	if res.ToVersion != "1.2.4" {
		t.Errorf("Update: ToVersion = %q, want 1.2.4", res.ToVersion)
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
	mux.HandleFunc("/releases/latest", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintln(w, "1.2.4")
	})
	mux.HandleFunc("/releases/1.2.4/"+assetName, func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte("new binary contents"))
	})
	mux.HandleFunc("/releases/1.2.4/"+checksumsAssetName, func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(badChecksum + "  " + assetName + "\n"))
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)

	_, err := Update(Options{
		CurrentVersion:   "1.2.3",
		Origin:           srv.URL,
		GOOS:             "linux",
		GOARCH:           "amd64",
		HTTPClient:       srv.Client(),
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
	mux.HandleFunc("/releases/latest", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNotFound)
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)

	_, err := Update(Options{
		CurrentVersion: "1.2.3",
		Origin:         srv.URL,
		HTTPClient:     srv.Client(),
	})
	if err != ErrNoRelease {
		t.Fatalf("Update: err = %v, want ErrNoRelease", err)
	}
}

func TestUpdateRejectsMalformedLatestVersion(t *testing.T) {
	// A version string that isn't plain X.Y.Z must be rejected before it
	// reaches a URL path (mirrors install.sh's guard against traversal).
	mux := http.NewServeMux()
	mux.HandleFunc("/releases/latest", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintln(w, "../secrets")
	})
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)

	_, err := Update(Options{
		CurrentVersion: "1.2.3",
		Origin:         srv.URL,
		HTTPClient:     srv.Client(),
	})
	if err == nil || !strings.Contains(err.Error(), "unexpected version string") {
		t.Fatalf("Update: err = %v, want unexpected-version-string error", err)
	}
}
