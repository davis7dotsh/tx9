// Package names generates and validates friendly box names (e.g. "large-cat").
package names

import (
	"crypto/rand"
	"fmt"
	"math/big"
	"regexp"
)

var adjectives = []string{
	"large", "small", "quick", "slow", "quiet", "loud", "brave", "calm",
	"eager", "gentle", "happy", "jolly", "kind", "lively", "mighty", "noble",
	"proud", "silly", "witty", "young", "amber", "azure", "bold", "bright",
	"clever", "crisp", "dapper", "fuzzy", "grumpy", "handy", "icy", "keen",
	"lucky", "merry", "nifty", "plucky", "rowdy", "sturdy", "tidy", "vivid",
}

var animals = []string{
	"cat", "dog", "fox", "owl", "wolf", "bear", "hawk", "seal", "crane",
	"otter", "lynx", "moose", "heron", "raven", "gecko", "ibis", "koala",
	"mole", "newt", "puma", "quail", "ram", "shark", "toad", "vole",
	"whale", "yak", "zebra", "bison", "civet", "eagle", "ferret", "goose",
	"hare", "jay", "kite", "loris", "mink", "panda", "stoat",
}

// reserved names must never be generated or accepted, to avoid colliding
// with CLI vocabulary or Docker/filesystem-sensitive words.
var reserved = map[string]bool{
	"create": true, "list": true, "enter": true, "ssh": true,
	"start": true, "stop": true, "backup": true, "export": true,
	"import": true, "open": true, "doctor": true, "upgrade": true,
	"delete": true, "prune": true, "help": true, "version": true,
	"all": true, "none": true, "default": true,
}

var validPattern = regexp.MustCompile(`^[a-z0-9][a-z0-9_-]*$`)

const maxNameLen = 32

// Generate returns a friendly "adjective-animal" name not present in taken.
// Falls back to appending a random numeric suffix if the whole word-list
// product space is exhausted.
func Generate(taken map[string]bool) (string, error) {
	for _, adj := range adjectives {
		for _, an := range animals {
			name := adj + "-" + an
			if !taken[name] {
				return name, nil
			}
		}
	}
	// Word-list space exhausted (very unlikely) — disambiguate with a
	// random 4-digit suffix on a random base name.
	for attempt := 0; attempt < 100; attempt++ {
		adj := adjectives[randIndex(len(adjectives))]
		an := animals[randIndex(len(animals))]
		n, err := rand.Int(rand.Reader, big.NewInt(10000))
		if err != nil {
			return "", fmt.Errorf("names: generate: %w", err)
		}
		name := fmt.Sprintf("%s-%s-%04d", adj, an, n.Int64())
		if !taken[name] {
			return name, nil
		}
	}
	return "", fmt.Errorf("names: generate: exhausted candidates")
}

func randIndex(n int) int {
	i, err := rand.Int(rand.Reader, big.NewInt(int64(n)))
	if err != nil {
		return 0
	}
	return int(i.Int64())
}

// Validate reports whether name is an acceptable box name: lowercase
// [a-z0-9_-], starting with an alphanumeric, max 32 chars, not reserved.
func Validate(name string) error {
	if name == "" {
		return fmt.Errorf("names: validate: name must not be empty")
	}
	if len(name) > maxNameLen {
		return fmt.Errorf("names: validate: name %q exceeds %d characters", name, maxNameLen)
	}
	if !validPattern.MatchString(name) {
		return fmt.Errorf("names: validate: name %q must match %s", name, validPattern.String())
	}
	if reserved[name] {
		return fmt.Errorf("names: validate: name %q is reserved", name)
	}
	return nil
}
