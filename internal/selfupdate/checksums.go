package selfupdate

import (
	"bufio"
	"fmt"
	"strings"
)

// ParseChecksums parses a checksums.txt in the standard `sha256sum` output
// format — one "<64-hex-char-digest>  <filename>" pair per line (the
// classic tool emits two spaces; a single space or tab is also accepted)
// — and returns a filename -> lowercase hex digest map. Blank lines and
// "#"-prefixed comment lines are ignored, so the release workflow is free
// to add a header.
func ParseChecksums(data []byte) (map[string]string, error) {
	out := make(map[string]string)
	sc := bufio.NewScanner(strings.NewReader(string(data)))
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) != 2 {
			return nil, fmt.Errorf("checksums: malformed line %q (want \"<digest> <filename>\")", line)
		}
		digest := strings.ToLower(fields[0])
		// sha256sum -b (binary mode) prefixes the filename with "*".
		name := strings.TrimPrefix(fields[1], "*")
		if len(digest) != 64 || !isHex(digest) {
			return nil, fmt.Errorf("checksums: %q: digest %q is not 64 hex chars", name, fields[0])
		}
		if name == "" {
			return nil, fmt.Errorf("checksums: malformed line %q (empty filename)", line)
		}
		if _, dup := out[name]; dup {
			return nil, fmt.Errorf("checksums: duplicate entry for %q", name)
		}
		out[name] = digest
	}
	if err := sc.Err(); err != nil {
		return nil, fmt.Errorf("checksums: %w", err)
	}
	return out, nil
}

func isHex(s string) bool {
	for _, c := range s {
		if (c < '0' || c > '9') && (c < 'a' || c > 'f') {
			return false
		}
	}
	return true
}
