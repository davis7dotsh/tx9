package selfupdate

import "testing"

func TestCompareVersions(t *testing.T) {
	cases := []struct {
		a, b string
		want int
	}{
		{"1.2.3", "1.2.3", 0},
		{"v1.2.3", "1.2.3", 0},
		{"1.2.3", "v1.2.3", 0},
		{"0.2.0", "0.10.0", -1},
		{"0.10.0", "0.2.0", 1},
		{"1.2", "1.2.0", 0},
		{"1.2.0", "1.2", 0},
		{"1.2.1", "1.2", 1},
		{"1.2", "1.2.1", -1},
		{"2.0.0", "1.9.9", 1},
		{"1.9.9", "2.0.0", -1},
	}
	for _, c := range cases {
		if got := CompareVersions(c.a, c.b); got != c.want {
			t.Errorf("CompareVersions(%q, %q) = %d, want %d", c.a, c.b, got, c.want)
		}
	}
}

func TestCompareVersionsNonNumericFallsBackToStringCompare(t *testing.T) {
	// Doesn't parse as dotted integers on either side (or both) -- must
	// not panic, and equal normalized strings must still compare equal.
	if CompareVersions("dev", "dev") != 0 {
		t.Error(`CompareVersions("dev", "dev") != 0`)
	}
	if CompareVersions("dev", "0.1.0") == 0 {
		t.Error(`CompareVersions("dev", "0.1.0") unexpectedly equal`)
	}
}

func TestSameVersion(t *testing.T) {
	if !SameVersion("v0.2.0", "0.2.0") {
		t.Error(`SameVersion("v0.2.0", "0.2.0") = false, want true`)
	}
	if SameVersion("v0.2.0", "0.2.1") {
		t.Error(`SameVersion("v0.2.0", "0.2.1") = true, want false`)
	}
	if SameVersion("dev", "0.2.0") {
		t.Error(`SameVersion("dev", "0.2.0") = true, want false`)
	}
}
