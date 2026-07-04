package selfupdate

import (
	"strconv"
	"strings"
)

// normalizeVersion strips a leading "v" (GitHub tags look like "v0.2.0";
// internal/version.Version has no leading v) and surrounding whitespace.
func normalizeVersion(v string) string {
	return strings.TrimPrefix(strings.TrimSpace(v), "v")
}

// SameVersion reports whether a and b denote the same version once
// normalized (leading "v" stripped, dotted-numeric components compared
// numerically so "0.2" == "0.2.0"). Falls back to a normalized string
// compare for anything that doesn't parse as dotted integers, so an
// unexpected tag format never panics — it just compares unequal to
// anything else unexpected.
func SameVersion(a, b string) bool {
	return CompareVersions(a, b) == 0
}

// CompareVersions compares two dotted-numeric version strings (a leading
// "v" is tolerated on either side). It returns -1 if a<b, 0 if equal, and 1
// if a>b. Missing trailing components compare as 0 ("1.2" == "1.2.0").
// If either side doesn't parse as dotted integers, it falls back to a
// plain string comparison of the normalized strings.
func CompareVersions(a, b string) int {
	na, nb := normalizeVersion(a), normalizeVersion(b)
	if na == nb {
		return 0
	}
	pa, oka := splitNumeric(na)
	pb, okb := splitNumeric(nb)
	if !oka || !okb {
		return strings.Compare(na, nb)
	}
	for i := 0; i < len(pa) || i < len(pb); i++ {
		var va, vb int
		if i < len(pa) {
			va = pa[i]
		}
		if i < len(pb) {
			vb = pb[i]
		}
		if va != vb {
			if va < vb {
				return -1
			}
			return 1
		}
	}
	return 0
}

// splitNumeric splits a dotted version string into integer components,
// reporting false if any component isn't a non-negative integer.
func splitNumeric(v string) ([]int, bool) {
	if v == "" {
		return nil, false
	}
	parts := strings.Split(v, ".")
	out := make([]int, len(parts))
	for i, p := range parts {
		n, err := strconv.Atoi(p)
		if err != nil || n < 0 {
			return nil, false
		}
		out[i] = n
	}
	return out, true
}
