package cli

import (
	"flag"
	"io"
	"testing"
)

// Trailing flags (`tx9 delete mybox --force`) were silently ignored when
// commands called fs.Parse directly — stdlib flag stops at the first
// positional. parseFlagsAnywhere reorders so both spellings work.
func TestParseFlagsAnywhere(t *testing.T) {
	cases := []struct {
		name      string
		args      []string
		wantForce bool
		wantPath  string
		wantPos   []string
	}{
		{"flag before positional", []string{"--force", "mybox"}, true, "", []string{"mybox"}},
		{"flag after positional", []string{"mybox", "--force"}, true, "", []string{"mybox"}},
		{"value flag after positional", []string{"mybox", "--path", "/tmp/x"}, false, "/tmp/x", []string{"mybox"}},
		{"value flag equals form", []string{"mybox", "--path=/tmp/y"}, false, "/tmp/y", []string{"mybox"}},
		{"double dash stops parsing", []string{"mybox", "--", "--force"}, false, "", []string{"mybox", "--force"}},
		{"no flags", []string{"mybox"}, false, "", []string{"mybox"}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			fs := flag.NewFlagSet("test", flag.ContinueOnError)
			fs.SetOutput(io.Discard)
			force := fs.Bool("force", false, "")
			path := fs.String("path", "", "")
			if err := parseFlagsAnywhere(fs, tc.args); err != nil {
				t.Fatalf("parse: %v", err)
			}
			if *force != tc.wantForce {
				t.Errorf("force = %v, want %v", *force, tc.wantForce)
			}
			if *path != tc.wantPath {
				t.Errorf("path = %q, want %q", *path, tc.wantPath)
			}
			if got := fs.Args(); len(got) != len(tc.wantPos) {
				t.Fatalf("positionals = %v, want %v", got, tc.wantPos)
			} else {
				for i := range got {
					if got[i] != tc.wantPos[i] {
						t.Errorf("positional[%d] = %q, want %q", i, got[i], tc.wantPos[i])
					}
				}
			}
		})
	}
}
