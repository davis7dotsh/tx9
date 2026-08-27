package archive

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func requireGPG(t *testing.T) {
	t.Helper()
	if _, err := exec.LookPath("gpg"); err != nil {
		t.Skip("gpg not installed, skipping encryption test")
	}
	t.Setenv("GNUPGHOME", t.TempDir())
	t.Cleanup(func() { _ = exec.Command("gpgconf", "--kill", "gpg-agent").Run() })
}

func TestGPGOutputDoesNotFollowSymlinksOrOverwriteFiles(t *testing.T) {
	for _, encrypt := range []bool{false, true} {
		for _, symlink := range []bool{false, true} {
			dir := t.TempDir()
			src := filepath.Join(dir, "source")
			target := filepath.Join(dir, "existing")
			if err := os.WriteFile(src, []byte("fixture input"), 0600); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(target, []byte("preserve me"), 0644); err != nil {
				t.Fatal(err)
			}
			dst := target
			if symlink {
				dst = filepath.Join(dir, "link")
				if err := os.Symlink(target, dst); err != nil {
					t.Fatal(err)
				}
			}
			operation := Decrypt
			if encrypt {
				operation = Encrypt
			}
			if err := operation(src, dst, "synthetic passphrase"); err == nil {
				t.Fatal("existing output was accepted")
			}
			contents, err := os.ReadFile(target)
			if err != nil || string(contents) != "preserve me" {
				t.Fatal("existing file was overwritten")
			}
		}
	}
}

func TestRunGPGPassphraseUsesOnlyPrivateDescriptor(t *testing.T) {
	dir := t.TempDir()
	script := "#!/bin/sh\n[ -z \"${TX9_PASSWORD+x}\" ] || exit 61\nIFS= read -r passphrase <&3\n[ \"$passphrase\" = 'synthetic passphrase' ] || exit 62\nprintf fixture\n"
	if err := os.WriteFile(filepath.Join(dir, "gpg"), []byte(script), 0700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir)
	t.Setenv("TX9_PASSWORD", "synthetic passphrase")
	var output bytes.Buffer
	if err := runGPG("synthetic passphrase", nil, nil, &output); err != nil {
		t.Fatal(err)
	}
	if output.String() != "fixture" {
		t.Fatal("GPG fixture did not receive the passphrase on fd 3")
	}
}

func TestRunGPGRejectsPassphrasesItWouldTruncate(t *testing.T) {
	for _, passphrase := range []string{"first\nsecond", "first\rsecond", "first\x00second"} {
		if err := runGPG(passphrase, nil, nil, nil); err == nil || !strings.Contains(err.Error(), "passphrase must not contain") {
			t.Fatal("passphrase accepted despite a descriptor delimiter")
		}
	}
}

func TestEncryptDecryptRoundTrip(t *testing.T) {
	requireGPG(t)

	dir := t.TempDir()
	src := filepath.Join(dir, "plain.bin")
	enc := filepath.Join(dir, "cipher.gpg")
	dec := filepath.Join(dir, "roundtrip.bin")

	want := []byte("tx9 archive encryption round-trip test payload")
	if err := os.WriteFile(src, want, 0600); err != nil {
		t.Fatalf("write plaintext: %v", err)
	}

	if err := Encrypt(src, enc, "correct horse battery staple"); err != nil {
		t.Fatalf("encrypt: %v", err)
	}

	if !IsGPG(enc) {
		t.Fatal("expected encrypted output to sniff as GPG")
	}
	if IsGPG(src) {
		t.Fatal("expected plaintext not to sniff as GPG")
	}

	if err := Decrypt(enc, dec, "correct horse battery staple"); err != nil {
		t.Fatalf("decrypt: %v", err)
	}

	got, err := os.ReadFile(dec)
	if err != nil {
		t.Fatalf("read decrypted: %v", err)
	}
	if !bytes.Equal(got, want) {
		t.Fatalf("round-trip mismatch: got %q, want %q", got, want)
	}

	if err := Decrypt(enc, filepath.Join(dir, "wrong.bin"), "not the passphrase"); err == nil {
		t.Fatal("expected decrypt with wrong passphrase to fail")
	}
}

func TestVerifyEncrypted(t *testing.T) {
	requireGPG(t)

	dir := t.TempDir()
	src := filepath.Join(dir, "data.tar.gz")
	enc := filepath.Join(dir, "data.tar.gz.gpg")

	entries := append(validBase(), file("home/agent/foo.txt", "hello"))
	data := buildTarGz(t, entries)
	if err := os.WriteFile(src, data, 0600); err != nil {
		t.Fatalf("write plaintext tar.gz: %v", err)
	}

	if err := Encrypt(src, enc, "s3cret"); err != nil {
		t.Fatalf("encrypt: %v", err)
	}

	if err := VerifyEncrypted(enc, "s3cret"); err != nil {
		t.Fatalf("verify with correct passphrase: %v", err)
	}
	if err := VerifyEncrypted(enc, "wrong"); err == nil {
		t.Fatal("expected verify with wrong passphrase to fail")
	}
}

// TestVerifyEncrypted_NotTarGz guards against the wrong-passphrase
// misclassification bug: when the decrypted plaintext isn't a valid
// tar.gz at all, VerifyEncrypted's own early exit from listTarGz closes
// the pipe out from under the still-writing decrypt goroutine, which used
// to surface as an io.ErrClosedPipe reported as "wrong passphrase?" even
// though the CORRECT passphrase was used.
func TestVerifyEncrypted_NotTarGz(t *testing.T) {
	requireGPG(t)

	dir := t.TempDir()
	src := filepath.Join(dir, "not-a-tar.bin")
	enc := filepath.Join(dir, "not-a-tar.bin.gpg")

	// Deliberately not a valid gzip/tar stream, and large enough that gpg
	// is still writing plaintext when listTarGz gives up on the gzip
	// header.
	if err := os.WriteFile(src, []byte(strings.Repeat("not a tar.gz stream ", 4096)), 0600); err != nil {
		t.Fatalf("write plaintext: %v", err)
	}

	if err := Encrypt(src, enc, "s3cret"); err != nil {
		t.Fatalf("encrypt: %v", err)
	}

	err := VerifyEncrypted(enc, "s3cret")
	if err == nil {
		t.Fatal("expected verify of a non-tar.gz payload to fail")
	}
	if !strings.Contains(err.Error(), "not a valid tar.gz") {
		t.Fatalf("expected a tar.gz classification error, got: %v", err)
	}
	if strings.Contains(err.Error(), "wrong passphrase") {
		t.Fatalf("misreported as wrong passphrase despite using the correct one: %v", err)
	}
}

func TestIsGPG_NotFound(t *testing.T) {
	if IsGPG(filepath.Join(t.TempDir(), "does-not-exist")) {
		t.Fatal("expected IsGPG to return false for a missing file")
	}
}
