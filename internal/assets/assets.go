// Package assets turns the embedded build-context filesystem (see the
// root-level assets.go) into a tar stream suitable for the Docker Engine
// API's ImageBuild. It is parameterized over fs.FS rather than importing
// the embed var directly, since that var lives in package main (see
// assets.go for why) and Go forbids importing package main.
package assets

import (
	"archive/tar"
	"bytes"
	"fmt"
	"io"
	"io/fs"
	"path"
	"strings"
)

// DockerfilePath is where the embedded Dockerfile lands inside the build
// context tar; pass this as the ImageBuild Dockerfile option.
const DockerfilePath = "docker/Dockerfile"

// BuildContextTar walks src and produces a tar stream matching the layout
// docker/Dockerfile's COPY instructions expect (build context = repo root:
// box.env, provision/, guest/, docker/entrypoint.sh, docker/executor-entrypoint.sh).
//
// go:embed strips the executable bit from every file, so shell scripts and
// other executables are explicitly re-marked 0755 here; everything else is
// 0644 (files) / 0755 (directories). Python bytecode caches (__pycache__,
// *.pyc) that may be present on disk under guest/ are skipped — they are
// build artifacts, not source.
func BuildContextTar(src fs.FS) (io.Reader, error) {
	var buf bytes.Buffer
	tw := tar.NewWriter(&buf)

	err := fs.WalkDir(src, ".", func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if p == "." {
			return nil
		}
		if skip(p) {
			if d.IsDir() {
				return fs.SkipDir
			}
			return nil
		}

		if d.IsDir() {
			hdr := &tar.Header{
				Name:     p + "/",
				Typeflag: tar.TypeDir,
				Mode:     0o755,
			}
			return tw.WriteHeader(hdr)
		}

		data, err := fs.ReadFile(src, p)
		if err != nil {
			return fmt.Errorf("assets: read %s: %w", p, err)
		}
		hdr := &tar.Header{
			Name:     p,
			Typeflag: tar.TypeReg,
			Mode:     fileMode(p),
			Size:     int64(len(data)),
		}
		if err := tw.WriteHeader(hdr); err != nil {
			return fmt.Errorf("assets: write header %s: %w", p, err)
		}
		if _, err := tw.Write(data); err != nil {
			return fmt.Errorf("assets: write %s: %w", p, err)
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	if err := tw.Close(); err != nil {
		return nil, fmt.Errorf("assets: close tar: %w", err)
	}
	return &buf, nil
}

// skip reports whether p is a build artifact that should not ship in the
// build context (Python bytecode caches under guest/).
func skip(p string) bool {
	if strings.Contains(p, "__pycache__") {
		return true
	}
	if path.Ext(p) == ".pyc" {
		return true
	}
	return false
}

// fileMode returns the tar mode for path p, restoring the executable bit
// go:embed strips: any *.sh script, guest/hb and guest/hb-workload (the
// guest control binaries), guest/hermes-state, and everything under
// provision/ need 0755. Everything else is a plain 0644 data file.
func fileMode(p string) int64 {
	switch {
	case strings.HasSuffix(p, ".sh"):
		return 0o755
	case p == "guest/hb" || strings.HasPrefix(p, "guest/hb-"):
		return 0o755
	case p == "guest/hermes-state":
		return 0o755
	case strings.HasPrefix(p, "provision/"):
		return 0o755
	default:
		return 0o644
	}
}
