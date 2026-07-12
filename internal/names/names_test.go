package names

import "testing"

func TestGenerate(t *testing.T) {
	taken := map[string]bool{}
	name, err := Generate(taken)
	if err != nil {
		t.Fatalf("Generate: %v", err)
	}
	if err := Validate(name); err != nil {
		t.Fatalf("Generate produced invalid name %q: %v", name, err)
	}
	taken[name] = true
	name2, err := Generate(taken)
	if err != nil {
		t.Fatalf("Generate: %v", err)
	}
	if name2 == name {
		t.Fatalf("Generate: returned already-taken name %q", name)
	}
}

// TestGenerate_NotAlwaysTheSameFirstName guards against the original bug
// where Generate always walked the adjective x animal product in the same
// fixed order, so the very first box ever created (empty taken map) always
// got the same name. With randomized picks, repeated calls against a fresh
// empty map should not all agree.
func TestGenerate_NotAlwaysTheSameFirstName(t *testing.T) {
	first, err := Generate(map[string]bool{})
	if err != nil {
		t.Fatalf("Generate: %v", err)
	}
	for i := 0; i < 50; i++ {
		name, err := Generate(map[string]bool{})
		if err != nil {
			t.Fatalf("Generate: %v", err)
		}
		if name != first {
			return
		}
	}
	t.Fatalf("Generate returned %q on every one of 51 calls against an empty taken map; expected randomization", first)
}

func TestValidate(t *testing.T) {
	cases := []struct {
		name string
		ok   bool
	}{
		{"large-cat", true},
		{"my_box", true},
		{"box9", true},
		{"", false},
		{"Bad-Case", false},
		{"-leading-dash", false},
		{"create", false},
		{"new", false},
		{"ls", false},
		{"shell", false},
		{"save", false},
		{"load", false},
		{"restore", false},
		{"logs", false},
		{"resources", false},
		{"gateway", false},
		{"update", false},
		{"rm", false},
		{"remove", false},
		{"way-too-long-name-that-exceeds-the-maximum-length-allowed", false},
	}
	for _, c := range cases {
		err := Validate(c.name)
		if c.ok && err != nil {
			t.Errorf("Validate(%q): want ok, got %v", c.name, err)
		}
		if !c.ok && err == nil {
			t.Errorf("Validate(%q): want error, got nil", c.name)
		}
	}
}
