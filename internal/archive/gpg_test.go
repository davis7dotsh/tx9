package archive

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

func requireGPG(t *testing.T) {
	t.Helper()
	if _, err := exec.LookPath("gpg"); err != nil {
		t.Skip("gpg not installed, skipping encryption test")
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

func TestIsGPG_NotFound(t *testing.T) {
	if IsGPG(filepath.Join(t.TempDir(), "does-not-exist")) {
		t.Fatal("expected IsGPG to return false for a missing file")
	}
}
