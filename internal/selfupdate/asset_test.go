package selfupdate

import "testing"

func TestAssetName(t *testing.T) {
	cases := []struct {
		goos, goarch, want string
	}{
		{"linux", "amd64", "tx9_linux_amd64"},
		{"linux", "arm64", "tx9_linux_arm64"},
		{"darwin", "amd64", "tx9_darwin_amd64"},
		{"darwin", "arm64", "tx9_darwin_arm64"},
	}
	for _, c := range cases {
		if got := AssetName(c.goos, c.goarch); got != c.want {
			t.Errorf("AssetName(%q, %q) = %q, want %q", c.goos, c.goarch, got, c.want)
		}
	}
}
