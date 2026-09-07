// Package lock provides per-box, non-blocking flock-based mutual exclusion,
// mirroring boxd's `_lock()` semantics: fail fast, never queue (dossier §8.1).
package lock

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"golang.org/x/sys/unix"
)

var ErrBusy = errors.New("another tx9 operation holds the box lock")

// Acquire takes an exclusive, non-blocking flock on path (creating it if
// needed) and returns a release func. If another process already holds the
// lock, it returns an error immediately rather than blocking.
func Acquire(path string) (release func(), err error) {
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, fmt.Errorf("lock: acquire: %w", err)
	}
	if err := unix.Flock(int(f.Fd()), unix.LOCK_EX|unix.LOCK_NB); err != nil {
		f.Close()
		if err == unix.EWOULDBLOCK {
			return nil, fmt.Errorf("lock: another tx9 operation is running on box %s: %w", boxNameFromPath(path), ErrBusy)
		}
		return nil, fmt.Errorf("lock: acquire: %w", err)
	}
	released := false
	return func() {
		if released {
			return
		}
		released = true
		unix.Flock(int(f.Fd()), unix.LOCK_UN)
		f.Close()
	}, nil
}

func boxNameFromPath(path string) string {
	return strings.TrimSuffix(filepath.Base(path), ".lock")
}
