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
	"time"
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
	assertNoStagedBinaries(t, dir)
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
	assertNoStagedBinaries(t, dir)
}

func assertNoStagedBinaries(t *testing.T, dir string) {
	t.Helper()
	paths, err := filepath.Glob(filepath.Join(dir, ".tx9.update-*"))
	if err != nil || len(paths) != 0 {
		t.Fatalf("staged binaries remain: %v (error: %v)", paths, err)
	}
}

func TestUpdateNewerVersionRequiresForce(t *testing.T) {
	for _, force := range []bool{false, true} {
		t.Run(fmt.Sprintf("force=%v", force), func(t *testing.T) {
			content := []byte("older release")
			srv := newTestServer(t, "1.2.3", "linux", "amd64", content)
			exePath := filepath.Join(t.TempDir(), "tx9")
			if err := os.WriteFile(exePath, []byte("newer release"), 0o755); err != nil {
				t.Fatal(err)
			}
			res, err := Update(Options{
				CurrentVersion: "1.2.4", Force: force, Origin: srv.URL,
				GOOS: "linux", GOARCH: "amd64", HTTPClient: srv.Client(),
				execPathOverride: exePath,
			})
			if err != nil || res.Applied != force {
				t.Fatalf("Update: result=%+v, error=%v", res, err)
			}
			got, err := os.ReadFile(exePath)
			want := "newer release"
			if force {
				want = string(content)
			}
			if err != nil || string(got) != want {
				t.Fatalf("installed binary=%q, error=%v; want %q", got, err, want)
			}
		})
	}
}

func TestUpdateCustomVersionRequiresForce(t *testing.T) {
	for _, force := range []bool{false, true} {
		t.Run(fmt.Sprintf("force=%v", force), func(t *testing.T) {
			srv := newTestServer(t, "2.0.0", "linux", "amd64", []byte("official release"))
			exePath := filepath.Join(t.TempDir(), "tx9")
			if err := os.WriteFile(exePath, []byte("custom build"), 0o755); err != nil {
				t.Fatal(err)
			}
			res, err := Update(Options{
				CurrentVersion: "10.0.0-custom", Force: force, Origin: srv.URL,
				GOOS: "linux", GOARCH: "amd64", HTTPClient: srv.Client(),
				execPathOverride: exePath,
			})
			want := "custom build"
			if force {
				want = "official release"
				if err != nil || res == nil || !res.Applied {
					t.Fatalf("forced update: result=%+v, error=%v", res, err)
				}
			} else if err == nil || !strings.Contains(err.Error(), "pass --force") || res != nil {
				t.Fatalf("unforced custom update: result=%+v, error=%v", res, err)
			}
			got, err := os.ReadFile(exePath)
			if err != nil || string(got) != want {
				t.Fatalf("installed binary=%q, error=%v; want %q", got, err, want)
			}
		})
	}
}

func TestUpdateDoesNotFollowPreexistingStageSymlink(t *testing.T) {
	dir := t.TempDir()
	exePath := filepath.Join(dir, "tx9")
	sentinel := filepath.Join(dir, "sentinel")
	if err := os.WriteFile(sentinel, []byte("untouched"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(sentinel, exePath+".new"); err != nil {
		t.Fatal(err)
	}
	srv := newTestServer(t, "1.2.4", "linux", "amd64", []byte("new release"))
	_, err := Update(Options{
		CurrentVersion: "1.2.3", Origin: srv.URL, GOOS: "linux", GOARCH: "amd64",
		HTTPClient: srv.Client(), execPathOverride: exePath,
	})
	if err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(sentinel)
	if err != nil || string(got) != "untouched" {
		t.Fatalf("stage symlink target was changed: %q, %v", got, err)
	}
	assertNoStagedBinaries(t, dir)
}

func TestConcurrentUpdatesUseIndependentStaging(t *testing.T) {
	content := []byte(strings.Repeat("complete binary", 1024))
	sum := sha256.Sum256(content)
	ready := make(chan struct{}, 2)
	release := make(chan struct{})
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/releases/latest":
			fmt.Fprintln(w, "1.2.4")
		case "/releases/1.2.4/checksums.txt":
			fmt.Fprintf(w, "%x  tx9_linux_amd64\n", sum)
		case "/releases/1.2.4/tx9_linux_amd64":
			ready <- struct{}{}
			<-release
			_, _ = w.Write(content)
		default:
			http.NotFound(w, r)
		}
	}))
	defer srv.Close()
	// Release blocked handlers even when an assertion below fails.
	defer func() {
		select {
		case <-release:
		default:
			close(release)
		}
	}()
	dir := t.TempDir()
	exePath := filepath.Join(dir, "tx9")
	results := make(chan error, 2)
	for range 2 {
		go func() {
			_, err := Update(Options{
				CurrentVersion: "1.2.3", Origin: srv.URL, GOOS: "linux", GOARCH: "amd64",
				HTTPClient: srv.Client(), execPathOverride: exePath,
			})
			results <- err
		}()
	}
	for range 2 {
		select {
		case <-ready:
		case <-time.After(5 * time.Second):
			t.Fatal("concurrent download did not start")
		}
	}
	close(release)
	for range 2 {
		if err := <-results; err != nil {
			t.Fatal(err)
		}
	}
	got, err := os.ReadFile(exePath)
	if err != nil || string(got) != string(content) {
		t.Fatalf("concurrent update installed incomplete content, error=%v", err)
	}
	assertNoStagedBinaries(t, dir)
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

func TestResolveOrigin(t *testing.T) {
	t.Setenv("TX9_ORIGIN", "")
	if got := ResolveOrigin(""); got != DefaultOrigin {
		t.Errorf("ResolveOrigin(\"\") = %q, want DefaultOrigin %q", got, DefaultOrigin)
	}
	if got := ResolveOrigin("https://example.com/"); got != "https://example.com" {
		t.Errorf("ResolveOrigin trailing slash = %q, want %q", got, "https://example.com")
	}

	t.Setenv("TX9_ORIGIN", "https://mirror.example.com/")
	if got := ResolveOrigin(""); got != "https://mirror.example.com" {
		t.Errorf("ResolveOrigin with TX9_ORIGIN = %q, want %q", got, "https://mirror.example.com")
	}
	if got := ResolveOrigin("https://override.example.com"); got != "https://override.example.com" {
		t.Errorf("ResolveOrigin override beats env: got %q", got)
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
