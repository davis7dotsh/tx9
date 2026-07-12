// Package names generates and validates friendly box names (e.g. "large-cat").
package names

import (
	"fmt"
	"math/rand/v2"
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
	"create": true, "new": true, "list": true, "ls": true,
	"enter": true, "ssh": true, "shell": true, "start": true, "stop": true,
	"backup": true, "export": true, "save": true,
	"import": true, "load": true, "restore": true,
	"logs": true, "resources": true,
	"gateway": true, "open": true, "doctor": true, "upgrade": true, "update": true,
	"delete": true, "rm": true, "remove": true, "prune": true,
	"help": true, "version": true,
	"all": true, "none": true, "default": true,
}

var validPattern = regexp.MustCompile(`^[a-z0-9][a-z0-9_-]*$`)

const maxNameLen = 32

// Generate returns a friendly "adjective-animal" name not present in taken,
// picked randomly rather than always starting from the same fixed point in
// the word-list product (which used to mean the first box ever created
// always got the same name). No cryptographic randomness is needed here,
// so math/rand/v2 is fine.
//
// It tries a bounded number of random (adjective, animal) picks first; if
// that's unlucky (the product space is nearly exhausted), it falls back to
// the exhaustive scan that used to be the only strategy; if even the whole
// product space turns out to be taken, it disambiguates with a random
// numeric suffix.
func Generate(taken map[string]bool) (string, error) {
	maxAttempts := 10 * len(adjectives) * len(animals)
	for attempt := 0; attempt < maxAttempts; attempt++ {
		adj := adjectives[rand.IntN(len(adjectives))]
		an := animals[rand.IntN(len(animals))]
		name := adj + "-" + an
		if !taken[name] {
			return name, nil
		}
	}

	// Random attempts didn't land on a free name — fall back to an
	// exhaustive scan so a merely-crowded (but not full) namespace still
	// resolves deterministically instead of relying on luck.
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
		adj := adjectives[rand.IntN(len(adjectives))]
		an := animals[rand.IntN(len(animals))]
		name := fmt.Sprintf("%s-%s-%04d", adj, an, rand.IntN(10000))
		if !taken[name] {
			return name, nil
		}
	}
	return "", fmt.Errorf("names: generate: exhausted candidates")
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
