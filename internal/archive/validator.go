package archive

import (
	"archive/tar"
	"compress/gzip"
	"errors"
	"fmt"
	"io"
	"strings"
)

// ValidateDataTar is a check-for-check Go port of boxd's `_validate_archive`
// Python validator (dossier §6.3 — "the production implementation from
// ./box, lifted verbatim"). r must be a gzip-compressed tar stream (a
// decrypted data.tar.gz, or the plaintext one before encryption). It is the
// safety core of both backup (called after the tar is built, before
// encryption) and import (called on the decrypted payload, before anything
// is extracted onto a real volume) — do not weaken any check here without
// re-reading dossier §6.3 rule-by-rule.
//
// It returns the first violation found, matching the Python version's
// fail-fast, single-error behavior (the original never accumulates
// multiple errors; it raises immediately at first fault).

// maxArchiveMembers hard-caps how many tar entries ValidateDataTar will
// read before erroring out, so a crafted archive with millions of tiny
// entries can't exhaust memory before validation even gets a chance to
// reject it. It's a var (not a const) so tests can lower it without having
// to generate a million-entry archive.
var maxArchiveMembers = 1_000_000

func ValidateDataTar(r io.Reader) error {
	gz, err := gzip.NewReader(r)
	if err != nil {
		return fmt.Errorf("archive is not a valid gzip stream: %w", err)
	}

	tr := tar.NewReader(gz)

	// members = archive.getmembers() — the Python version reads the whole
	// member list eagerly before doing anything else.
	var headers []*tar.Header
	for {
		hdr, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			gz.Close()
			return fmt.Errorf("archive is corrupt: %w", err)
		}
		headers = append(headers, hdr)
		// A crafted archive with millions of tiny entries would otherwise
		// exhaust memory (the entire header slice is buffered) before any
		// of the checks below ever run. maxArchiveMembers is a var, not a
		// const, so tests can lower it without generating a
		// million-entry archive.
		if len(headers) > maxArchiveMembers {
			gz.Close()
			return fmt.Errorf("archive contains more than %d members", maxArchiveMembers)
		}
	}
	// tar.Next() returning io.EOF only means the tar reader saw its own
	// end-of-archive marker; it does not by itself force the underlying
	// gzip stream to be read to its own end, so a corrupt trailing
	// CRC32/ISIZE footer would otherwise go unnoticed. Drain the rest of
	// the gzip stream and check gzip.Reader.Close (which validates that
	// footer) so a corrupt one is still caught here.
	if _, err := io.Copy(io.Discard, gz); err != nil {
		gz.Close()
		return fmt.Errorf("archive is corrupt: %w", err)
	}
	if err := gz.Close(); err != nil {
		return fmt.Errorf("archive is corrupt: %w", err)
	}
	if len(headers) == 0 {
		return errors.New("archive is empty")
	}

	idx := &memberIndex{byName: map[string]*tarMember{}}

	// First pass: per-member checks, building the ordered by_name index.
	for _, hdr := range headers {
		if err := safeText(hdr.Name, "archive path"); err != nil {
			return err
		}

		absolute := strings.HasPrefix(hdr.Name, "/")
		rawParts := posixPartsRaw(hdr.Name)
		for _, p := range rawParts {
			if p == ".." {
				return errors.New("archive path escapes its extraction root")
			}
		}
		if absolute {
			return errors.New("archive path escapes its extraction root")
		}

		var parts []string
		for _, p := range rawParts {
			if p != "." {
				parts = append(parts, p)
			}
		}
		key := strings.Join(parts, "/")

		if _, exists := idx.byName[key]; exists {
			return fmt.Errorf("archive contains duplicate path: %s", displayKey(key))
		}

		m := &tarMember{Name: key, Linkname: hdr.Linkname}
		switch hdr.Typeflag {
		case tar.TypeReg, tar.TypeRegA:
			m.IsFile = true
		case tar.TypeDir:
			m.IsDir = true
		case tar.TypeSymlink:
			m.IsSymlink = true
		case tar.TypeLink:
			m.IsHardlink = true
		default:
			return errors.New("archive contains a device, FIFO, socket, or unknown special file")
		}

		if key == "" && !m.IsDir {
			return errors.New("archive root member must be a real directory")
		}

		if m.IsSymlink || m.IsHardlink {
			if err := validateLinkTarget(m, key); err != nil {
				return err
			}
		}

		idx.order = append(idx.order, key)
		idx.byName[key] = m
	}

	// Second pass: no member may be nested beneath a link ancestor.
	for _, key := range idx.order {
		var parts []string
		if key != "" {
			parts = strings.Split(key, "/")
		}
		for length := 1; length < len(parts); length++ {
			parentKey := strings.Join(parts[:length], "/")
			if parent, ok := idx.byName[parentKey]; ok {
				if parent.IsSymlink || parent.IsHardlink {
					return fmt.Errorf("archive member is nested beneath a link: %s", key)
				}
			}
		}
	}

	// home and home/agent must exist as real (non-link) directories.
	for _, required := range []string{"home", "home/agent"} {
		entry, ok := idx.byName[required]
		if !ok || !entry.IsDir || entry.IsSymlink || entry.IsHardlink {
			return fmt.Errorf("%s must be a real directory", required)
		}
	}

	// Third pass: every member's parent must resolve to a directory, and
	// hardlinks must resolve to a regular file.
	for _, key := range idx.order {
		if key == "" {
			continue
		}
		parent := ""
		if i := strings.LastIndex(key, "/"); i >= 0 {
			parent = key[:i]
		}
		if parent != "" {
			parentEntry, err := idx.resolve(parent)
			if err != nil {
				return err
			}
			if !parentEntry.IsDir {
				return fmt.Errorf("archive member parent is not a directory: %s", key)
			}
		}
		member := idx.byName[key]
		if member.IsSymlink || member.IsHardlink {
			target, err := idx.resolve(key)
			if err != nil {
				return err
			}
			if member.IsHardlink && !target.IsFile {
				return errors.New("archive hardlink does not resolve to a regular file")
			}
		}
	}

	return nil
}

// tarMember is the subset of a tar.Header ValidateDataTar's rules care
// about, keyed by its normalized path (see the key computation above).
type tarMember struct {
	Name       string
	IsDir      bool
	IsFile     bool
	IsSymlink  bool
	IsHardlink bool
	Linkname   string
}

// memberIndex is an insertion-ordered map from normalized path to member —
// order matters because the Go port must report the same *first* violation
// the Python dict-iteration-order version would (Python 3.7+ dicts preserve
// insertion order).
type memberIndex struct {
	order  []string
	byName map[string]*tarMember
}

// displayKey mirrors Python's `key or '.'` idiom used when reporting the
// root member by name.
func displayKey(key string) string {
	if key == "" {
		return "."
	}
	return key
}

// safeText mirrors safe_text(): rejects NUL and other C0/DEL control
// characters in a member name or link target.
func safeText(value, label string) error {
	for _, r := range value {
		if r < 32 || r == 127 {
			return fmt.Errorf("%s contains control characters", label)
		}
	}
	return nil
}

// posixPartsRaw splits a POSIX path into its components the way
// PurePosixPath(...).parts does before any "." filtering: repeated/leading/
// trailing slashes collapse away, but "." segments are preserved literally
// (pathlib doesn't collapse "." either) so ".." detection above can see
// them in their original positions. It never returns the pseudo "/" root
// component pathlib.parts would include for an absolute path — callers that
// care about absoluteness check hdr.Name's leading "/" directly instead.
func posixPartsRaw(p string) []string {
	var out []string
	for _, seg := range strings.Split(p, "/") {
		if seg == "" {
			continue
		}
		out = append(out, seg)
	}
	return out
}

// linkParts mirrors link_parts(): validates the raw link target text, then
// returns its normalized path components (dropping "" and "." segments;
// ".." is kept literally so the caller can walk it).
func linkParts(value string) ([]string, error) {
	if err := safeText(value, "archive link target"); err != nil {
		return nil, err
	}
	if strings.HasPrefix(value, "/") {
		return nil, errors.New("archive link target is absolute")
	}
	var out []string
	for _, seg := range posixPartsRaw(value) {
		if seg != "." {
			out = append(out, seg)
		}
	}
	return out, nil
}

// validateLinkTarget mirrors validate_link_target(): simulates walking the
// link target's ".." segments against a stack seeded with the *link's own*
// containing directory (for symlinks only — hardlink targets in this format
// are always tar-root-relative, per the original), and rejects a target
// that would underflow past the extraction root. It only proves the target
// text is lexically well-formed; resolve() (below) does the real
// existence/type checks.
func validateLinkTarget(member *tarMember, key string) error {
	parts, err := linkParts(member.Linkname)
	if err != nil {
		return err
	}
	if len(parts) == 0 {
		return errors.New("archive link target is empty")
	}

	var resolved []string
	if member.IsSymlink {
		resolved = keyDirParts(key)
	}
	for _, part := range parts {
		if part == ".." {
			if len(resolved) == 0 {
				return errors.New("archive link target lexically escapes extraction root")
			}
			resolved = resolved[:len(resolved)-1]
		} else {
			resolved = append(resolved, part)
		}
	}
	return nil
}

// keyDirParts mirrors `key.split("/")[:-1]`: the path components of key's
// containing directory.
func keyDirParts(key string) []string {
	if key == "" {
		return nil
	}
	parts := strings.Split(key, "/")
	return parts[:len(parts)-1]
}

// resolve mirrors the Python resolve() closure: fully walks key's
// symlink/hardlink chain (if any) to the real member it ultimately names,
// with the same cycle detection and safety-bound semantics as the
// original.
func (idx *memberIndex) resolve(key string) (*tarMember, error) {
	var pending []string
	if key != "" {
		pending = strings.Split(key, "/")
	}
	var resolved []string
	seenStates := map[string]bool{}
	steps := 0
	maxSteps := len(idx.order)*8 + 32

	for len(pending) > 0 {
		steps++
		if steps > maxSteps {
			return nil, errors.New("archive link chain exceeds safety bound")
		}
		state := resolveStateKey(resolved, pending)
		if seenStates[state] {
			return nil, errors.New("archive link cycle detected")
		}
		seenStates[state] = true

		part := pending[0]
		pending = pending[1:]

		if part == "" || part == "." {
			continue
		}
		if part == ".." {
			if len(resolved) == 0 {
				return nil, errors.New("archive link target escapes extraction root")
			}
			resolved = resolved[:len(resolved)-1]
			continue
		}

		// candidate == strings.Join(append(resolved, part), "/"); computed
		// without mutating resolved since it's only used for a lookup here.
		candidate := part
		if len(resolved) > 0 {
			candidate = strings.Join(resolved, "/") + "/" + part
		}

		entry, ok := idx.byName[candidate]
		if ok && (entry.IsSymlink || entry.IsHardlink) {
			var base []string
			if entry.IsSymlink {
				base = append([]string{}, resolved...)
			}
			targetParts, err := linkParts(entry.Linkname)
			if err != nil {
				return nil, err
			}
			next := make([]string, 0, len(base)+len(targetParts)+len(pending))
			next = append(next, base...)
			next = append(next, targetParts...)
			next = append(next, pending...)
			pending = next
			resolved = nil
			continue
		}

		if len(pending) > 0 && (!ok || !entry.IsDir) {
			return nil, fmt.Errorf("archive path resolves through missing or non-directory member: %s", candidate)
		}
		resolved = append(resolved, part)
	}

	final := strings.Join(resolved, "/")
	entry, ok := idx.byName[final]
	if !ok {
		return nil, fmt.Errorf("archive link resolves to missing member: %s", displayKey(final))
	}
	return entry, nil
}

// resolveStateKey mirrors `(tuple(resolved), tuple(pending))` as a hashable
// set element. NUL is safe as an internal separator: every path component
// reaching here already passed safeText, which rejects NUL and other
// control characters.
func resolveStateKey(resolved, pending []string) string {
	return strings.Join(resolved, "\x00") + "\x01" + strings.Join(pending, "\x00")
}
