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
