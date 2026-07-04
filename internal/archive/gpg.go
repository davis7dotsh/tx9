package archive

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
)

// runGPG shells out to gpg (no Go dependency — decision: replicate boxd's
// approach exactly, dossier §6.4). The passphrase is delivered on fd 3 via
// an *os.Pipe handed to the child as ExtraFiles[0] (which os/exec always
// places at fd 3, since 0/1/2 are stdin/stdout/stderr), matching boxd's
// `3<<<"$_BOX_PASS"` here-string — never a CLI argument or a plain
// GPG_PASSPHRASE-style env var, both of which would leak via `ps` or
// /proc/<pid>/environ.
func runGPG(passphrase string, args []string, stdin io.Reader, stdout io.Writer) error {
	gpgPath, err := exec.LookPath("gpg")
	if err != nil {
		return fmt.Errorf("gpg not found in PATH (required for encrypted archives; install gnupg, or pass --no-encrypt): %w", err)
	}

	pr, pw, err := os.Pipe()
	if err != nil {
		return fmt.Errorf("create passphrase pipe: %w", err)
	}

	cmd := exec.Command(gpgPath, args...)
	cmd.ExtraFiles = []*os.File{pr}
	cmd.Stdin = stdin
	cmd.Stdout = stdout
	var stderrBuf bytes.Buffer
	cmd.Stderr = &stderrBuf

	if err := cmd.Start(); err != nil {
		pr.Close()
		pw.Close()
		return fmt.Errorf("start gpg: %w", err)
	}
	pr.Close() // child has its own dup; parent's copy isn't needed once started

	if _, werr := io.WriteString(pw, passphrase+"\n"); werr != nil {
		pw.Close()
		cmd.Wait()
		return fmt.Errorf("write passphrase to gpg: %w", werr)
	}
	pw.Close()

	if err := cmd.Wait(); err != nil {
		return fmt.Errorf("gpg failed: %w: %s", err, strings.TrimSpace(stderrBuf.String()))
	}
	return nil
}

// gpgArgsEncrypt/gpgArgsDecrypt are exactly boxd's gpg_enc/gpg_dec flag
// sets (dossier §6.4): GPG-compatible AES-256 symmetric encryption, batch
// mode (never blocks on a pinentry prompt), passphrase on fd 3.
func gpgArgsEncrypt(dst string) []string {
	return []string{
		"--batch", "--yes", "--pinentry-mode", "loopback", "--passphrase-fd", "3",
		"--symmetric", "--cipher-algo", "AES256", "-o", dst,
	}
}

func gpgArgsDecrypt(src string) []string {
	return []string{
		"--batch", "--yes", "--pinentry-mode", "loopback", "--passphrase-fd", "3",
		"-d", src,
	}
}

// Encrypt GPG-symmetric-encrypts src (read as gpg's stdin, matching boxd's
// `gpg_enc "$encrypted" <"$raw"`) to dst using passphrase.
func Encrypt(src, dst, passphrase string) error {
	in, err := os.Open(src)
	if err != nil {
		return fmt.Errorf("archive: open %s for encryption: %w", src, err)
	}
	defer in.Close()

	if err := runGPG(passphrase, gpgArgsEncrypt(dst), in, nil); err != nil {
		return fmt.Errorf("archive: encrypt %s: %w", src, err)
	}
	return nil
}

// DecryptStream decrypts src (a GPG-symmetric-encrypted file) and streams
// the plaintext to w, never touching disk for the cleartext — used by
// VerifyEncrypted (dossier §6.5) and by Decrypt below.
func DecryptStream(src, passphrase string, w io.Writer) error {
	if err := runGPG(passphrase, gpgArgsDecrypt(src), nil, w); err != nil {
		return fmt.Errorf("archive: decrypt %s: %w", src, err)
	}
	return nil
}

// Decrypt GPG-symmetric-decrypts src to dst using passphrase.
func Decrypt(src, dst, passphrase string) error {
	out, err := os.OpenFile(dst, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0600)
	if err != nil {
		return fmt.Errorf("archive: create %s for decryption: %w", dst, err)
	}
	defer out.Close()
	return DecryptStream(src, passphrase, out)
}

// IsGPG sniffs whether the file at path is GPG binary output rather than a
// plain data.tar.gz. Neither boxd nor tx9 ever pass --armor, so ciphertext
// is always binary OpenPGP with the packet-format high bit (0x80) set on
// its first byte — unambiguous against a gzip stream, whose first byte
// (0x1f) does not have that bit set.
func IsGPG(path string) bool {
	f, err := os.Open(path)
	if err != nil {
		return false
	}
	defer f.Close()
	var b [1]byte
	if _, err := f.Read(b[:]); err != nil {
		return false
	}
	return b[0]&0x80 != 0
}

// VerifyEncrypted replicates boxd's post-encrypt verification (dossier
// §6.5): decrypt encPath into a pipe and list the resulting tar's contents,
// so a round-trip failure (wrong passphrase, truncated write, corrupt gpg
// output) is caught before the archive is committed to its final path —
// without ever writing cleartext to disk.
func VerifyEncrypted(encPath, passphrase string) error {
	pr, pw := io.Pipe()

	decErrCh := make(chan error, 1)
	go func() {
		decErrCh <- DecryptStream(encPath, passphrase, pw)
		pw.Close()
	}()

	listErr := listTarGz(pr)
	decErr := <-decErrCh

	if decErr != nil {
		return fmt.Errorf("archive: verify %s: decrypt failed (wrong passphrase?): %w", encPath, decErr)
	}
	if listErr != nil {
		return fmt.Errorf("archive: verify %s: decrypted data is not a valid tar.gz: %w", encPath, listErr)
	}
	return nil
}

// listTarGz reads through every entry of a gzip-compressed tar stream
// without extracting anything, erroring on the first corrupt/truncated
// entry.
func listTarGz(r io.Reader) error {
	gz, err := gzip.NewReader(r)
	if err != nil {
		return err
	}
	defer gz.Close()
	tr := tar.NewReader(gz)
	for {
		if _, err := tr.Next(); err != nil {
			if err == io.EOF {
				return nil
			}
			return err
		}
	}
}
