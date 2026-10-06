package state

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestStatePathsRejectUnsafeNamesBeforeFilesystemAccess(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	for _, name := range []string{"", ".", "..", "../../outside", "/absolute", "a/b", "a\\b", "bad\nname", strings.Repeat("x", 33)} {
		t.Run(name, func(t *testing.T) {
			for _, path := range []func(string) (string, error){BoxEnvPath, LockPath} {
				if _, err := path(name); err == nil {
					t.Fatal("unsafe name accepted as a state path")
				}
			}
			if _, err := ReadBoxEnv(name); err == nil {
				t.Fatal("unsafe name accepted for state read")
			}
			if err := WriteBoxEnv(name, map[string]string{"A": "one"}); err == nil {
				t.Fatal("unsafe name accepted for state write")
			}
			if err := RemoveBoxEnv(name); err == nil {
				t.Fatal("unsafe name accepted for state removal")
			}
		})
	}
}

func TestWriteBoxEnvIsPrivateAndLeavesNoTemporaryFile(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	if err := WriteBoxEnv("fixture", map[string]string{"B": "two", "A": "one"}); err != nil {
		t.Fatal(err)
	}

	path, err := BoxEnvPath("fixture")
	if err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("env mode = %o, want 600", info.Mode().Perm())
	}
	contents, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(contents) != "A=one\nB=two\n" {
		t.Fatalf("env contents = %q", contents)
	}
	temps, err := filepath.Glob(filepath.Join(filepath.Dir(path), ".fixture.env.tmp-*"))
	if err != nil {
		t.Fatal(err)
	}
	if len(temps) != 0 {
		t.Fatalf("temporary files remain: %v", temps)
	}
}

func TestWriteBoxEnvRenameFailureLeavesNoTemporaryFile(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	path, err := BoxEnvPath("blocked")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(path, 0o700); err != nil {
		t.Fatal(err)
	}

	if err := WriteBoxEnv("blocked", map[string]string{"A": "one"}); err == nil {
		t.Fatal("WriteBoxEnv() error = nil, want rename failure")
	}
	if info, err := os.Stat(path); err != nil || !info.IsDir() {
		t.Fatalf("existing target changed after failure: info=%v err=%v", info, err)
	}
	temps, err := filepath.Glob(filepath.Join(filepath.Dir(path), ".blocked.env.tmp-*"))
	if err != nil {
		t.Fatal(err)
	}
	if len(temps) != 0 {
		t.Fatalf("temporary files remain after failure: %v", temps)
	}
}

func TestBoxEnvRoundTripPreservesValues(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	want := map[string]string{
		"EMPTY":       "",
		"WHITESPACE":  " \t ",
		"TRAILING":    "keep trailing \t ",
		"LEADING":     " \t keep leading",
		"EQUALS":      "a=b=c",
		"LARGE_VALUE": strings.Repeat("x", 128*1024),
	}
	if err := WriteBoxEnv("round-trip", want); err != nil {
		t.Fatal(err)
	}
	got, err := ReadBoxEnv("round-trip")
	if err != nil {
		t.Fatal(err)
	}
	for key, value := range want {
		actual, ok := got[key]
		if !ok || actual != value {
			t.Errorf("value %s changed: present=%t, got length %d, want length %d", key, ok, len(actual), len(value))
		}
	}
}

func TestReadBoxEnvPreservesWhitespaceWithCommentsAndCRLF(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	path, err := BoxEnvPath("fixture")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("  # comment\r\n\r\nTOKEN=synthetic-token\r\nVALUE= keep spaces \t \r\ninvalid line\r\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	got, err := ReadBoxEnv("fixture")
	if err != nil {
		t.Fatal(err)
	}
	if got["TOKEN"] != "synthetic-token" || got["VALUE"] != " keep spaces \t " || len(got) != 2 {
		t.Fatalf("ReadBoxEnv() = %#v", got)
	}
}
