package archive

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"fmt"
	"strings"
	"testing"
)

// testEntry describes one tar member for building synthetic archives in
// tests, without going through the real docker/tar-inside-a-container path.
type testEntry struct {
	Name     string
	Typeflag byte
	Linkname string
	Body     string
}

func buildTarGz(t *testing.T, entries []testEntry) []byte {
	t.Helper()
	var buf bytes.Buffer
	gz := gzip.NewWriter(&buf)
	tw := tar.NewWriter(gz)
	for _, e := range entries {
		mode := int64(0644)
		if e.Typeflag == tar.TypeDir {
			mode = 0755
		}
		hdr := &tar.Header{
			Name:     e.Name,
			Typeflag: e.Typeflag,
			Linkname: e.Linkname,
			Size:     int64(len(e.Body)),
			Mode:     mode,
		}
		if err := tw.WriteHeader(hdr); err != nil {
			t.Fatalf("write header %q: %v", e.Name, err)
		}
		if e.Body != "" {
			if _, err := tw.Write([]byte(e.Body)); err != nil {
				t.Fatalf("write body %q: %v", e.Name, err)
			}
		}
	}
	if err := tw.Close(); err != nil {
		t.Fatalf("close tar: %v", err)
	}
	if err := gz.Close(); err != nil {
		t.Fatalf("close gzip: %v", err)
	}
	return buf.Bytes()
}

func dir(name string) testEntry { return testEntry{Name: name, Typeflag: tar.TypeDir} }

func file(name, body string) testEntry {
	return testEntry{Name: name, Typeflag: tar.TypeReg, Body: body}
}

func symlink(name, target string) testEntry {
	return testEntry{Name: name, Typeflag: tar.TypeSymlink, Linkname: target}
}

func hardlink(name, target string) testEntry {
	return testEntry{Name: name, Typeflag: tar.TypeLink, Linkname: target}
}

// validBase is the minimal set of members every accepted archive needs:
// a real root directory plus the required home/home-agent tree (rule 9).
func validBase() []testEntry {
	return []testEntry{
		dir(""),
		dir("home"),
		dir("home/agent"),
	}
}

func runValidate(t *testing.T, entries []testEntry) error {
	t.Helper()
	data := buildTarGz(t, entries)
	return ValidateDataTar(bytes.NewReader(data))
}

func TestValidateDataTar_AcceptsValidArchive(t *testing.T) {
	entries := append(validBase(),
		file("home/agent/foo.txt", "hello"),
		symlink("home/agent/link", "foo.txt"),
		hardlink("home/agent/hardlink", "home/agent/foo.txt"),
	)
	if err := runValidate(t, entries); err != nil {
		t.Fatalf("expected valid archive to pass, got: %v", err)
	}
}

func TestValidateDataTar_AcceptsMinimalArchive(t *testing.T) {
	if err := runValidate(t, validBase()); err != nil {
		t.Fatalf("expected minimal home/agent-only archive to pass, got: %v", err)
	}
}

// TestValidateDataTar_Rejects is the comprehensive table covering every
// rule enumerated in dossier §6.3 (the Python `_validate_archive` this
// validator ports), plus the extra corrupt-stream case.
func TestValidateDataTar_Rejects(t *testing.T) {
	cases := []struct {
		name    string
		entries []testEntry
		wantErr string
	}{
		{
			name:    "empty archive",
			entries: nil,
			wantErr: "archive is empty",
		},
		{
			name:    "absolute path",
			entries: append(validBase(), file("/etc/passwd", "x")),
			wantErr: "archive path escapes its extraction root",
		},
		{
			name:    "traversal path",
			entries: append(validBase(), file("home/../../etc/passwd", "x")),
			wantErr: "archive path escapes its extraction root",
		},
		{
			name:    "control char in name",
			entries: append(validBase(), file("home/agent/\x01bad", "x")),
			wantErr: "archive path contains control characters",
		},
		{
			name:    "control char in link target",
			entries: append(validBase(), symlink("home/agent/link", "\x01bad")),
			wantErr: "archive link target contains control characters",
		},
		{
			name: "duplicate path",
			entries: []testEntry{
				dir(""),
				dir("home/"),
				dir("./home"),
			},
			wantErr: "archive contains duplicate path: home",
		},
		{
			name:    "special file (fifo)",
			entries: append(validBase(), testEntry{Name: "home/agent/fifo", Typeflag: tar.TypeFifo}),
			wantErr: "archive contains a device, FIFO, socket, or unknown special file",
		},
		{
			name:    "root member not a directory",
			entries: []testEntry{file(".", "x")},
			wantErr: "archive root member must be a real directory",
		},
		{
			name:    "root member is a symlink",
			entries: []testEntry{symlink(".", "somewhere")},
			wantErr: "archive root member must be a real directory",
		},
		{
			name:    "root member is a hardlink",
			entries: []testEntry{hardlink(".", "somewhere")},
			wantErr: "archive root member must be a real directory",
		},
		{
			name:    "missing home",
			entries: []testEntry{dir("")},
			wantErr: "home must be a real directory",
		},
		{
			name: "home is a symlink",
			entries: []testEntry{
				dir(""),
				symlink("home", "somewhere"),
			},
			wantErr: "home must be a real directory",
		},
		{
			name: "missing home/agent",
			entries: []testEntry{
				dir(""),
				dir("home"),
			},
			wantErr: "home/agent must be a real directory",
		},
		{
			name:    "link target is absolute",
			entries: append(validBase(), symlink("home/agent/link", "/etc/passwd")),
			wantErr: "archive link target is absolute",
		},
		{
			name:    "link target is empty",
			entries: append(validBase(), symlink("home/agent/link", "")),
			wantErr: "archive link target is empty",
		},
		{
			name:    "link target lexically escapes root",
			entries: append(validBase(), symlink("home/agent/link", "../../../etc/passwd")),
			wantErr: "archive link target lexically escapes extraction root",
		},
		{
			name: "nested beneath a symlink",
			entries: append(validBase(),
				symlink("home/agent/alias", "placeholder"),
				file("home/agent/alias/child", "x"),
			),
			wantErr: "archive member is nested beneath a link: home/agent/alias/child",
		},
		{
			name: "nested beneath a hardlink",
			entries: append(validBase(),
				hardlink("home/agent/alias", "home/agent"),
				file("home/agent/alias/child", "x"),
			),
			wantErr: "archive member is nested beneath a link: home/agent/alias/child",
		},
		{
			name: "link cycle",
			entries: []testEntry{
				dir(""),
				dir("home"),
				dir("home/agent"),
				symlink("a", "b"),
				symlink("b", "a"),
			},
			wantErr: "archive link cycle detected",
		},
		{
			name: "link chain exceeds safety bound",
			entries: []testEntry{
				dir(""),
				dir("home"),
				dir("home/agent"),
				symlink("a", "a/a"),
			},
			wantErr: "archive link chain exceeds safety bound",
		},
		{
			name:    "link resolves to missing member",
			entries: append(validBase(), symlink("orphan", "ghost")),
			wantErr: "archive link resolves to missing member: ghost",
		},
		{
			name:    "path resolves through missing member",
			entries: append(validBase(), file("home/agent/x/y/child", "x")),
			wantErr: "archive path resolves through missing or non-directory member: home/agent/x",
		},
		{
			name: "path resolves through non-directory member",
			entries: append(validBase(),
				file("home/agent/notadir", "x"),
				file("home/agent/notadir/deeper/child", "x"),
			),
			wantErr: "archive path resolves through missing or non-directory member: home/agent/notadir",
		},
		{
			name: "member parent is not a directory",
			entries: append(validBase(),
				file("home/agent/notadir", "x"),
				file("home/agent/notadir/child", "x"),
			),
			wantErr: "archive member parent is not a directory: home/agent/notadir/child",
		},
		{
			name:    "hardlink does not resolve to a regular file",
			entries: append(validBase(), hardlink("home/agent/hardlink", "home/agent")),
			wantErr: "archive hardlink does not resolve to a regular file",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			err := runValidate(t, tc.entries)
			if err == nil {
				t.Fatalf("expected error containing %q, got nil", tc.wantErr)
			}
			if !strings.Contains(err.Error(), tc.wantErr) {
				t.Fatalf("expected error containing %q, got: %v", tc.wantErr, err)
			}
		})
	}
}

func TestValidateDataTar_NotGzip(t *testing.T) {
	if err := ValidateDataTar(strings.NewReader("not a gzip stream")); err == nil {
		t.Fatal("expected error for non-gzip input")
	}
}

// TestValidateDataTar_CorruptGzipTrailer guards against a bug where
// tar.Next() returning io.EOF (its own end-of-archive marker) was treated
// as proof the whole stream was sound, even though the gzip trailer's
// CRC32/ISIZE footer had never actually been read/verified. Flipping the
// last 4 bytes of a valid archive corrupts that trailer without touching
// any tar content, so this only fails if the trailer is actually checked.
func TestValidateDataTar_CorruptGzipTrailer(t *testing.T) {
	data := buildTarGz(t, append(validBase(), file("home/agent/foo.txt", "hello")))
	corrupted := append([]byte(nil), data...)
	for i := len(corrupted) - 4; i < len(corrupted); i++ {
		corrupted[i] ^= 0xff
	}
	if err := ValidateDataTar(bytes.NewReader(corrupted)); err == nil {
		t.Fatal("expected error for archive with a corrupt gzip trailer")
	}
}

// TestValidateDataTar_MemberCapExceeded exercises the maxArchiveMembers
// guard without needing to actually construct a million-entry archive: the
// var (not const) is lowered for the duration of the test.
func TestValidateDataTar_MemberCapExceeded(t *testing.T) {
	orig := maxArchiveMembers
	maxArchiveMembers = 10
	defer func() { maxArchiveMembers = orig }()

	entries := validBase()
	for i := 0; i < maxArchiveMembers+5; i++ {
		entries = append(entries, file(fmt.Sprintf("home/agent/f%d", i), "x"))
	}
	err := runValidate(t, entries)
	if err == nil {
		t.Fatal("expected error for archive exceeding the member cap")
	}
	if !strings.Contains(err.Error(), "more than") {
		t.Fatalf("expected a member-cap error, got: %v", err)
	}
}

func TestValidateDataTar_TruncatedGzip(t *testing.T) {
	// Cut the stream in half rather than trimming a few trailing bytes: the
	// gzip footer alone can be dropped without tripping an error, since the
	// tar reader may finish consuming all entries before the decompressor
	// ever needs to validate the trailing CRC/ISIZE. Truncating mid-stream
	// guarantees the tar/gzip readers hit a genuine unexpected EOF.
	data := buildTarGz(t, append(validBase(), file("home/agent/foo.txt", strings.Repeat("x", 4096))))
	truncated := data[:len(data)/2]
	if err := ValidateDataTar(bytes.NewReader(truncated)); err == nil {
		t.Fatal("expected error for truncated archive")
	}
}
