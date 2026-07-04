package assets

import (
	"archive/tar"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"testing"
)

// repoRootFS builds an fs.FS over the same subset of the repo the real
// go:embed directive in the root assets.go covers, without needing to
// import package main (which is impossible — see assets.go's doc comment).
func repoRootFS(t *testing.T) fs.FS {
	t.Helper()
	wd, err := os.Getwd()
	if err != nil {
		t.Fatalf("Getwd: %v", err)
	}
	root := filepath.Join(wd, "..", "..")
	return os.DirFS(root)
}

func TestBuildContextTar(t *testing.T) {
	r, err := BuildContextTar(repoRootFS(t))
	if err != nil {
		t.Fatalf("BuildContextTar: %v", err)
	}

	modes := map[string]int64{}
	tr := tar.NewReader(r)
	for {
		hdr, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatalf("tar.Next: %v", err)
		}
		modes[hdr.Name] = hdr.Mode
	}

	if _, ok := modes["docker/Dockerfile"]; !ok {
		t.Errorf("docker/Dockerfile missing from build context tar")
	}
	mode, ok := modes["guest/hb"]
	if !ok {
		t.Fatalf("guest/hb missing from build context tar")
	}
	if mode != 0o755 {
		t.Errorf("guest/hb mode = %o, want 0755", mode)
	}
	for _, want := range []string{"box.env", "provision/provision.sh", "docker/entrypoint.sh", "docker/executor-entrypoint.sh", "guest/hb-workload", "guest/hermes-state"} {
		if _, ok := modes[want]; !ok {
			t.Errorf("%s missing from build context tar", want)
		}
	}
	for name := range modes {
		if name == "guest/__pycache__/" || name == "guest/__pycache__" {
			t.Errorf("build context tar should not contain __pycache__, found %s", name)
		}
	}
}
