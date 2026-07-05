package selfupdate

import (
	"strings"
	"testing"
)

func TestParseChecksums(t *testing.T) {
	digestA := strings.Repeat("a", 64)
	digestB := strings.Repeat("b", 64)
	data := "# checksums for v0.2.0\n" +
		digestA + "  tx9_linux_amd64\n" +
		"\n" +
		digestB + " tx9_darwin_arm64\n"

	sums, err := ParseChecksums([]byte(data))
	if err != nil {
		t.Fatalf("ParseChecksums: %v", err)
	}
	if sums["tx9_linux_amd64"] != digestA {
		t.Errorf("tx9_linux_amd64 = %q, want %q", sums["tx9_linux_amd64"], digestA)
	}
	if sums["tx9_darwin_arm64"] != digestB {
		t.Errorf("tx9_darwin_arm64 = %q, want %q", sums["tx9_darwin_arm64"], digestB)
	}
	if len(sums) != 2 {
		t.Errorf("len(sums) = %d, want 2", len(sums))
	}
}

func TestParseChecksumsBinaryModeStar(t *testing.T) {
	digest := strings.Repeat("c", 64)
	sums, err := ParseChecksums([]byte(digest + " *tx9_linux_amd64\n"))
	if err != nil {
		t.Fatalf("ParseChecksums: %v", err)
	}
	if sums["tx9_linux_amd64"] != digest {
		t.Errorf("tx9_linux_amd64 = %q, want %q", sums["tx9_linux_amd64"], digest)
	}
}

func TestParseChecksumsRejectsBadDigest(t *testing.T) {
	if _, err := ParseChecksums([]byte("not-a-digest tx9_linux_amd64\n")); err == nil {
		t.Fatal("ParseChecksums: want error for non-hex digest, got nil")
	}
	if _, err := ParseChecksums([]byte(strings.Repeat("a", 63) + " tx9_linux_amd64\n")); err == nil {
		t.Fatal("ParseChecksums: want error for short digest, got nil")
	}
}

func TestParseChecksumsRejectsMalformedLine(t *testing.T) {
	if _, err := ParseChecksums([]byte("just-one-field\n")); err == nil {
		t.Fatal("ParseChecksums: want error for one-field line, got nil")
	}
	if _, err := ParseChecksums([]byte("a b c\n")); err == nil {
		t.Fatal("ParseChecksums: want error for three-field line, got nil")
	}
}

func TestParseChecksumsRejectsDuplicate(t *testing.T) {
	digest := strings.Repeat("a", 64)
	data := digest + " tx9_linux_amd64\n" + digest + " tx9_linux_amd64\n"
	if _, err := ParseChecksums([]byte(data)); err == nil {
		t.Fatal("ParseChecksums: want error for duplicate entry, got nil")
	}
}
