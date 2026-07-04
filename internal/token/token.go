// Package token mints executor bearer tokens.
package token

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
)

// Mint returns a 256-bit random token, hex-encoded (64 chars) — matches
// `head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'` from the bash
// prototype (dossier §2.1).
func Mint() (string, error) {
	buf := make([]byte, 32)
	if _, err := rand.Read(buf); err != nil {
		return "", fmt.Errorf("token: mint: %w", err)
	}
	return hex.EncodeToString(buf), nil
}
