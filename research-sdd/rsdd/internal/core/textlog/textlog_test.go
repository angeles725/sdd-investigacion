package textlog

import "testing"

func TestBinary(t *testing.T) {
	for _, c := range []struct {
		name string
		in   string
		want bool
	}{
		{"empty", "", false},
		{"ascii", "== 3 passed · 0 failed ==\n", false},
		{"multibyte utf8", "ñ · teeth ✓\n", false},
		{"invalid utf8 is text to grep", "ab\xffc\n", false},
		{"nul first", "\x00abc", true},
		{"nul middle", "ab\x00c", true},
		{"nul last", "abc\x00", true},
		{"nul only", "\x00", true},
	} {
		if got := Binary([]byte(c.in)); got != c.want {
			t.Errorf("%s: Binary(%q) = %v, want %v", c.name, c.in, got, c.want)
		}
	}
}
