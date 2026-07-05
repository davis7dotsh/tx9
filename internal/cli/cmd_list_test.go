package cli

import (
	"testing"

	"github.com/davis7dotsh/tx9/internal/version"
)

func TestImageVersionDisplay(t *testing.T) {
	cases := []struct {
		name       string
		boxVersion string
		want       string
	}{
		{name: "empty label", boxVersion: "", want: "?"},
		{name: "matches CLI version", boxVersion: version.Version, want: version.Version},
		{
			name:       "drifted from CLI version",
			boxVersion: "0.1.0-not-the-cli-version",
			want:       "0.1.0-not-the-cli-version (cli: " + version.Version + ")",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := imageVersionDisplay(tc.boxVersion); got != tc.want {
				t.Errorf("imageVersionDisplay(%q) = %q, want %q", tc.boxVersion, got, tc.want)
			}
		})
	}
}
