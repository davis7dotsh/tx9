package archive

import (
	"archive/tar"
	"bytes"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestReadMetadataRejectsUnboundedOrInvalidHeader(t *testing.T) {
	for _, tc := range []struct {
		name     string
		body     string
		typeflag byte
	}{
		{name: "oversized metadata", body: `{"box_name":"` + strings.Repeat("x", maxMetadataBytes) + `","format_version":1}`, typeflag: tar.TypeReg},
		{name: "negative version", body: `{"format_version":-1}`, typeflag: tar.TypeReg},
		{name: "trailing JSON", body: `{"format_version":1}{"format_version":2}`, typeflag: tar.TypeReg},
		{name: "nonregular metadata", typeflag: tar.TypeDir},
	} {
		t.Run(tc.name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "fixture.tx9")
			var contents bytes.Buffer
			tw := tar.NewWriter(&contents)
			if err := tw.WriteHeader(&tar.Header{Name: metadataMember, Typeflag: tc.typeflag, Size: int64(len(tc.body)), Mode: 0600}); err != nil {
				t.Fatal(err)
			}
			if _, err := tw.Write([]byte(tc.body)); err != nil {
				t.Fatal(err)
			}
			if err := tw.Close(); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(path, contents.Bytes(), 0600); err != nil {
				t.Fatal(err)
			}
			if _, err := ReadMetadata(path); err == nil {
				t.Fatal("invalid metadata accepted")
			}
		})
	}
}

func TestExtractDataRejectsExtraOrNonregularMembers(t *testing.T) {
	for _, extra := range []bool{false, true} {
		t.Run(fmt.Sprint(extra), func(t *testing.T) {
			dir := t.TempDir()
			path := filepath.Join(dir, "fixture.tx9")
			var contents bytes.Buffer
			tw := tar.NewWriter(&contents)
			writeTestTarMember(t, tw, metadataMember, []byte(`{"box_name":"fixture","format_version":1}`))
			if extra {
				writeTestTarMember(t, tw, dataMemberPlain, []byte("payload"))
				writeTestTarMember(t, tw, "unexpected", nil)
			} else if err := tw.WriteHeader(&tar.Header{Name: dataMemberPlain, Typeflag: tar.TypeSymlink, Linkname: "elsewhere"}); err != nil {
				t.Fatal(err)
			}
			if err := tw.Close(); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(path, contents.Bytes(), 0600); err != nil {
				t.Fatal(err)
			}
			if _, err := ExtractData(path, filepath.Join(dir, "payload")); err == nil {
				t.Fatal("invalid outer archive accepted")
			}
		})
	}
}

func tarWriterForTest(t *testing.T, w io.Writer) *tar.Writer {
	t.Helper()
	return tar.NewWriter(w)
}

func writeTestTarMember(t *testing.T, tw *tar.Writer, name string, body []byte) {
	t.Helper()
	if err := tw.WriteHeader(&tar.Header{
		Typeflag: tar.TypeReg,
		Name:     name,
		Mode:     0600,
		Size:     int64(len(body)),
	}); err != nil {
		t.Fatalf("write header %q: %v", name, err)
	}
	if _, err := tw.Write(body); err != nil {
		t.Fatalf("write body %q: %v", name, err)
	}
}

func TestWriteTx9RoundTrip(t *testing.T) {
	dir := t.TempDir()
	dataFile := filepath.Join(dir, "data.tar.gz")
	payload := []byte("fake gzip tar payload")
	if err := os.WriteFile(dataFile, payload, 0600); err != nil {
		t.Fatalf("write data file: %v", err)
	}

	meta := Metadata{
		BoxName:      "large-cat",
		CreatedAt:    time.Date(2026, 7, 4, 12, 0, 0, 0, time.UTC),
		CLIVersion:   "dev",
		ImageVersion: "dev",
		Encrypted:    false,
	}

	tx9Path := filepath.Join(dir, "archive.tx9")
	out, err := os.Create(tx9Path)
	if err != nil {
		t.Fatalf("create tx9: %v", err)
	}
	if err := WriteTx9(out, meta, dataFile); err != nil {
		t.Fatalf("WriteTx9: %v", err)
	}
	if err := out.Close(); err != nil {
		t.Fatalf("close tx9: %v", err)
	}

	gotMeta, err := ReadMetadata(tx9Path)
	if err != nil {
		t.Fatalf("ReadMetadata: %v", err)
	}
	if gotMeta.BoxName != meta.BoxName || gotMeta.FormatVersion != FormatVersion {
		t.Fatalf("metadata mismatch: got %+v", gotMeta)
	}
	if gotMeta.Encrypted {
		t.Fatal("expected Encrypted=false")
	}

	extracted := filepath.Join(dir, "extracted.tar.gz")
	extractedMeta, err := ExtractData(tx9Path, extracted)
	if err != nil {
		t.Fatalf("ExtractData: %v", err)
	}
	if extractedMeta.BoxName != meta.BoxName {
		t.Fatalf("extracted metadata mismatch: got %+v", extractedMeta)
	}

	got, err := os.ReadFile(extracted)
	if err != nil {
		t.Fatalf("read extracted data: %v", err)
	}
	if !bytes.Equal(got, payload) {
		t.Fatalf("extracted data mismatch: got %q, want %q", got, payload)
	}
}

func TestWriteTx9EncryptedMemberName(t *testing.T) {
	dir := t.TempDir()
	dataFile := filepath.Join(dir, "data.tar.gz.gpg")
	if err := os.WriteFile(dataFile, []byte("ciphertext"), 0600); err != nil {
		t.Fatalf("write data file: %v", err)
	}

	meta := Metadata{BoxName: "x", Encrypted: true}
	tx9Path := filepath.Join(dir, "archive.tx9")
	out, err := os.Create(tx9Path)
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	if err := WriteTx9(out, meta, dataFile); err != nil {
		t.Fatalf("WriteTx9: %v", err)
	}
	if err := out.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}

	gotMeta, err := ReadMetadata(tx9Path)
	if err != nil {
		t.Fatalf("ReadMetadata: %v", err)
	}
	if !gotMeta.Encrypted {
		t.Fatal("expected Encrypted=true")
	}

	extracted := filepath.Join(dir, "extracted.gpg")
	if _, err := ExtractData(tx9Path, extracted); err != nil {
		t.Fatalf("ExtractData: %v", err)
	}
	got, err := os.ReadFile(extracted)
	if err != nil {
		t.Fatalf("read extracted: %v", err)
	}
	if string(got) != "ciphertext" {
		t.Fatalf("got %q", got)
	}
}

func TestReadMetadata_NotATx9File(t *testing.T) {
	dir := t.TempDir()
	junk := filepath.Join(dir, "junk.tx9")
	if err := os.WriteFile(junk, []byte("not a tar file at all"), 0600); err != nil {
		t.Fatalf("write junk: %v", err)
	}
	if _, err := ReadMetadata(junk); err == nil {
		t.Fatal("expected error reading metadata from non-tar file")
	}
}

// TestReadMetadata_FutureFormatVersion builds a .tx9 container by hand
// (bypassing WriteTx9, which always forces the current FormatVersion) to
// confirm readMetadataMember's version gate rejects an archive from a
// hypothetical newer tx9 instead of silently misparsing it.
func TestReadMetadata_FutureFormatVersion(t *testing.T) {
	dir := t.TempDir()
	tx9Path := filepath.Join(dir, "archive.tx9")

	metaJSON := []byte(`{"box_name":"x","format_version":999}`)
	dataBody := []byte("irrelevant")

	f, err := os.Create(tx9Path)
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	tw := tarWriterForTest(t, f)
	writeTestTarMember(t, tw, metadataMember, metaJSON)
	writeTestTarMember(t, tw, dataMemberName(false), dataBody)
	if err := tw.Close(); err != nil {
		t.Fatalf("close tar: %v", err)
	}
	if err := f.Close(); err != nil {
		t.Fatalf("close file: %v", err)
	}

	if _, err := ReadMetadata(tx9Path); err == nil {
		t.Fatal("expected error for a future format_version")
	}
}
