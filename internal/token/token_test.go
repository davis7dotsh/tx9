package token

import "testing"

func TestMint(t *testing.T) {
	tok, err := Mint()
	if err != nil {
		t.Fatalf("Mint: %v", err)
	}
	if len(tok) != 64 {
		t.Fatalf("Mint: want 64 hex chars, got %d (%q)", len(tok), tok)
	}
	for _, c := range tok {
		if (c < '0' || c > '9') && (c < 'a' || c > 'f') {
			t.Fatalf("Mint: non-hex char %q in %q", c, tok)
		}
	}
	tok2, err := Mint()
	if err != nil {
		t.Fatalf("Mint: %v", err)
	}
	if tok == tok2 {
		t.Fatalf("Mint: two calls returned the same token")
	}
}
