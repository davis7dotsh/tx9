// Package archive implements the .tx9 backup container format: a small,
// pure-Go, docker-free library used by `tx9 backup`/`tx9 import`
// (internal/cli) for building, reading, and validating archives. Nothing
// here talks to Docker — callers hand it files/streams and get files/
// streams back, so it's independently testable and reusable if a future
// remote-move feature (docs/tx9-cli-design.md "saved for later") needs the
// same format without a live daemon.
//
// Container shape (docs/tx9-cli-design.md decision 6): a `.tx9` file is an
// uncompressed outer tar with exactly two members, in order:
//
//  1. metadata.json — always present, always plaintext, so `import` can
//     read the target box name and whether a password prompt is needed
//     without touching the (possibly encrypted) payload.
//  2. data.tar.gz or data.tar.gz.gpg — the actual box data, gzip-compressed
//     (and optionally GPG-symmetric-encrypted on top). The outer tar is
//     deliberately uncompressed: this member is already compressed (and
//     possibly encrypted, i.e. incompressible), so wrapping it in another
//     compression pass would only burn CPU.
package archive

import (
	"archive/tar"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"time"
)

// FormatVersion is the current .tx9 container format version, written into
// every archive's metadata.json and checked on read so a future incompatible
// format change fails loudly instead of silently misparsing.
const FormatVersion = 1

// Tar member names inside a .tx9 container, in fixed order.
const (
	metadataMember    = "metadata.json"
	dataMemberPlain   = "data.tar.gz"
	dataMemberEncrypt = "data.tar.gz.gpg"
	maxMetadataBytes  = 64 << 10
)

// Metadata is the JSON header every .tx9 archive carries as its first tar
// member.
type Metadata struct {
	BoxName       string    `json:"box_name"`
	CreatedAt     time.Time `json:"created_at"`
	CLIVersion    string    `json:"cli_version"`
	ImageVersion  string    `json:"image_version"`
	Encrypted     bool      `json:"encrypted"`
	FormatVersion int       `json:"format_version"`
}

// dataMemberName returns the name the data member must have for a given
// Encrypted flag.
func dataMemberName(encrypted bool) string {
	if encrypted {
		return dataMemberEncrypt
	}
	return dataMemberPlain
}

// WriteTx9 writes a complete .tx9 container to w: metadata.json first, then
// the verbatim contents of dataFile as the second member (named
// data.tar.gz or data.tar.gz.gpg per meta.Encrypted). meta.FormatVersion is
// overwritten with the current FormatVersion regardless of what the caller
// set.
func WriteTx9(w io.Writer, meta Metadata, dataFile string) error {
	meta.FormatVersion = FormatVersion

	metaBytes, err := json.MarshalIndent(meta, "", "  ")
	if err != nil {
		return fmt.Errorf("archive: marshal metadata: %w", err)
	}

	df, err := os.Open(dataFile)
	if err != nil {
		return fmt.Errorf("archive: open data file %s: %w", dataFile, err)
	}
	defer df.Close()
	info, err := df.Stat()
	if err != nil {
		return fmt.Errorf("archive: stat data file %s: %w", dataFile, err)
	}

	now := time.Now()
	tw := tar.NewWriter(w)

	if err := tw.WriteHeader(&tar.Header{
		Typeflag: tar.TypeReg,
		Name:     metadataMember,
		Mode:     0600,
		Size:     int64(len(metaBytes)),
		ModTime:  now,
	}); err != nil {
		return fmt.Errorf("archive: write metadata header: %w", err)
	}
	if _, err := tw.Write(metaBytes); err != nil {
		return fmt.Errorf("archive: write metadata: %w", err)
	}

	if err := tw.WriteHeader(&tar.Header{
		Typeflag: tar.TypeReg,
		Name:     dataMemberName(meta.Encrypted),
		Mode:     0600,
		Size:     info.Size(),
		ModTime:  info.ModTime(),
	}); err != nil {
		return fmt.Errorf("archive: write data header: %w", err)
	}
	if _, err := io.Copy(tw, df); err != nil {
		return fmt.Errorf("archive: write data: %w", err)
	}

	if err := tw.Close(); err != nil {
		return fmt.Errorf("archive: close container: %w", err)
	}
	return nil
}

// readMetadataMember reads and decodes the first tar member of path,
// erroring clearly if path doesn't look like a .tx9 container. It returns
// the open file positioned right after the metadata member (so
// ExtractData can continue reading the data member from the same reader)
// along with the decoded metadata.
func readMetadataMember(f *os.File) (Metadata, *tar.Reader, error) {
	tr := tar.NewReader(f)
	hdr, err := tr.Next()
	if err != nil {
		return Metadata{}, nil, fmt.Errorf("does not look like a .tx9 file (reading first member): %w", err)
	}
	if hdr.Name != metadataMember {
		return Metadata{}, nil, fmt.Errorf("does not look like a .tx9 file (expected first member %q, got %q)", metadataMember, hdr.Name)
	}
	if hdr.Typeflag != tar.TypeReg || hdr.Size > maxMetadataBytes {
		return Metadata{}, nil, fmt.Errorf("metadata.json must be a regular file no larger than %d bytes", maxMetadataBytes)
	}
	metadataJSON, err := io.ReadAll(tr)
	if err != nil {
		return Metadata{}, nil, fmt.Errorf("read metadata.json: %w", err)
	}

	var meta Metadata
	if err := json.Unmarshal(metadataJSON, &meta); err != nil {
		return Metadata{}, nil, fmt.Errorf("invalid metadata.json: %w", err)
	}
	if meta.FormatVersion < 1 {
		return Metadata{}, nil, fmt.Errorf("invalid metadata.json: format_version must be positive")
	}
	if meta.FormatVersion > FormatVersion {
		return Metadata{}, nil, fmt.Errorf("archive format version %d is newer than this tx9 (supports up to %d) — upgrade tx9 first", meta.FormatVersion, FormatVersion)
	}
	return meta, tr, nil
}

// ReadMetadata reads only the first member of the .tx9 file at path and
// decodes it as Metadata, never touching the (possibly encrypted) second
// member. This is what lets `import` discover the target box name and
// whether a password prompt is needed before doing any real work.
func ReadMetadata(path string) (Metadata, error) {
	f, err := os.Open(path)
	if err != nil {
		return Metadata{}, fmt.Errorf("archive: open %s: %w", path, err)
	}
	defer f.Close()

	meta, _, err := readMetadataMember(f)
	if err != nil {
		return Metadata{}, fmt.Errorf("archive: %s %w", path, err)
	}
	return meta, nil
}

// ExtractData reads the .tx9 file at path and writes its second tar member
// (the data payload — gzip tar, or GPG-wrapped gzip tar if the metadata
// says Encrypted) verbatim to destFile. Returns the metadata read along the
// way, so callers don't need a separate ReadMetadata call.
func ExtractData(path, destFile string) (Metadata, error) {
	f, err := os.Open(path)
	if err != nil {
		return Metadata{}, fmt.Errorf("archive: open %s: %w", path, err)
	}
	defer f.Close()

	meta, tr, err := readMetadataMember(f)
	if err != nil {
		return Metadata{}, fmt.Errorf("archive: %s %w", path, err)
	}

	hdr, err := tr.Next()
	if err != nil {
		return Metadata{}, fmt.Errorf("archive: %s: missing data member: %w", path, err)
	}
	wantName := dataMemberName(meta.Encrypted)
	if hdr.Name != wantName {
		return Metadata{}, fmt.Errorf("archive: %s: expected data member %q, got %q", path, wantName, hdr.Name)
	}
	if hdr.Typeflag != tar.TypeReg {
		return Metadata{}, fmt.Errorf("archive: %s: data member must be a regular file", path)
	}

	out, err := os.OpenFile(destFile, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0600)
	if err != nil {
		return Metadata{}, fmt.Errorf("archive: create %s: %w", destFile, err)
	}
	defer out.Close()
	if _, err := io.Copy(out, tr); err != nil {
		return Metadata{}, fmt.Errorf("archive: extract data from %s: %w", path, err)
	}
	if _, err := tr.Next(); err != io.EOF {
		if err == nil {
			return Metadata{}, fmt.Errorf("archive: %s: unexpected member after data payload", path)
		}
		return Metadata{}, fmt.Errorf("archive: %s: invalid archive trailer: %w", path, err)
	}
	if err := out.Close(); err != nil {
		return Metadata{}, fmt.Errorf("archive: close extracted data: %w", err)
	}
	return meta, nil
}
