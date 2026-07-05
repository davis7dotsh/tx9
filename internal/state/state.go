// Package state manages tx9's on-host state directory (~/.tx9).
package state

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// Dir returns ~/.tx9, creating it (mode 0700) if absent.
func Dir() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("state: dir: %w", err)
	}
	dir := filepath.Join(home, ".tx9")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", fmt.Errorf("state: dir: %w", err)
	}
	return dir, nil
}

// BoxesDir returns ~/.tx9/boxes, creating it if absent.
func BoxesDir() (string, error) {
	dir, err := Dir()
	if err != nil {
		return "", err
	}
	d := filepath.Join(dir, "boxes")
	if err := os.MkdirAll(d, 0o700); err != nil {
		return "", fmt.Errorf("state: boxesDir: %w", err)
	}
	return d, nil
}

// LocksDir returns ~/.tx9/locks, creating it if absent.
func LocksDir() (string, error) {
	dir, err := Dir()
	if err != nil {
		return "", err
	}
	d := filepath.Join(dir, "locks")
	if err := os.MkdirAll(d, 0o700); err != nil {
		return "", fmt.Errorf("state: locksDir: %w", err)
	}
	return d, nil
}

// BoxEnvPath returns ~/.tx9/boxes/<name>.env.
func BoxEnvPath(name string) (string, error) {
	dir, err := BoxesDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, name+".env"), nil
}

// LockPath returns ~/.tx9/locks/<name>.lock.
func LockPath(name string) (string, error) {
	dir, err := LocksDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, name+".lock"), nil
}

// ReadBoxEnv reads a KEY=VALUE env file into a map. Returns an empty map
// (no error) if the file does not exist.
func ReadBoxEnv(name string) (map[string]string, error) {
	path, err := BoxEnvPath(name)
	if err != nil {
		return nil, err
	}
	f, err := os.Open(path)
	if err != nil {
		if os.IsNotExist(err) {
			return map[string]string{}, nil
		}
		return nil, fmt.Errorf("state: readBoxEnv: %w", err)
	}
	defer f.Close()

	env := map[string]string{}
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		k, v, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		env[k] = v
	}
	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("state: readBoxEnv: %w", err)
	}
	return env, nil
}

// WriteBoxEnv writes a KEY=VALUE env file (mode 0600), overwriting any
// existing file.
func WriteBoxEnv(name string, env map[string]string) error {
	path, err := BoxEnvPath(name)
	if err != nil {
		return err
	}
	keys := make([]string, 0, len(env))
	for k := range env {
		keys = append(keys, k)
	}
	sort.Strings(keys)

	var b strings.Builder
	for _, k := range keys {
		fmt.Fprintf(&b, "%s=%s\n", k, env[k])
	}
	if err := os.WriteFile(path, []byte(b.String()), 0o600); err != nil {
		return fmt.Errorf("state: writeBoxEnv: %w", err)
	}
	return nil
}

// RemoveBoxEnv deletes ~/.tx9/boxes/<name>.env, if present.
func RemoveBoxEnv(name string) error {
	path, err := BoxEnvPath(name)
	if err != nil {
		return err
	}
	if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("state: removeBoxEnv: %w", err)
	}
	return nil
}
