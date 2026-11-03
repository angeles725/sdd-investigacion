package corrections

import (
	"regexp"
	"testing"
)

// The awk-shaped helpers are pinned on their boundaries: every comparison edge, the first and last index, and the
// position just past the end.

func TestAsciiLower(t *testing.T) {
	for _, c := range []struct{ in, want string }{
		{"", ""}, {"abc", "abc"}, {"ABC", "abc"}, {"aBc", "abc"}, {"abC", "abc"}, {"Abc", "abc"}, {"@AZ[", "@az["},
		{"a`{", "a`{"}, {"É", "É"}, {"xÉY", "xÉy"}, {"ZZ", "zz"},
	} {
		if got := asciiLower(c.in); got != c.want {
			t.Errorf("asciiLower(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestSubstr(t *testing.T) {
	for _, c := range []struct {
		s    string
		i, n int
		want string
	}{
		{"abcde", 1, 2, "ab"}, {"abcde", 2, 3, "bcd"}, {"abcde", 5, 1, "e"}, {"abcde", 5, 9, "e"}, {"abcde", 4, 2, "de"}, {"abcde", 3, -1, "cde"},
		{"abcde", 1, -1, "abcde"}, {"abcde", 6, 1, ""}, {"abcde", 6, -1, ""}, {"abcde", 7, 2, ""}, {"abcde", 9, -1, ""}, {"abcde", 2, 0, ""},
		{"abcde", 0, 2, "a"}, {"abcde", -1, 3, "a"}, {"abcde", 0, 1, ""}, {"abcde", 0, -1, "abcde"}, {"abcde", 1, 5, "abcde"}, {"abcde", 1, 6, "abcde"},
		{"abcde", 3, 3, "cde"}, {"abcde", 3, 4, "cde"}, {"", 1, 1, ""}, {"", 1, -1, ""}, {"a", 1, 1, "a"}, {"a", 1, 2, "a"}, {"a", 2, 1, ""},
	} {
		if got := substr(c.s, c.i, c.n); got != c.want {
			t.Errorf("substr(%q, %d, %d) = %q, want %q", c.s, c.i, c.n, got, c.want)
		}
	}
	if got := from("abcde", 4); got != "de" {
		t.Errorf("from = %q", got)
	}
}

func TestMatchHelper(t *testing.T) {
	re := regexp.MustCompile(`b+`)
	if s, l := match(re, "aabbb"); s != 3 || l != 3 {
		t.Errorf("match = %d,%d, want 3,3", s, l)
	}
	if s, l := match(re, "xyz"); s != 0 || l != -1 {
		t.Errorf("no match = %d,%d, want 0,-1", s, l)
	}
}

func TestWordBytes(t *testing.T) {
	for c := 0; c < 256; c++ {
		b := byte(c)
		want := b >= 'a' && b <= 'z' || b >= '0' && b <= '9' || b == '_' || b >= 0x80
		if got := isWordByte(b); got != want {
			t.Errorf("isWordByte(%#x) = %v, want %v", c, got, want)
		}
		wantStart := b >= 'a' && b <= 'z' || b == '_' || b >= 0x80
		if got := startsWordByte(string([]byte{b, 'x'})); got != wantStart {
			t.Errorf("startsWordByte(%#x) = %v, want %v", c, got, wantStart)
		}
	}
	if startsWordByte("") {
		t.Error("startsWordByte of the empty string")
	}
	for _, c := range []struct {
		s    string
		i    int
		want bool
	}{{"a", 1, true}, {"a", 0, false}, {"a", -1, false}, {"a", 2, false}, {"-a", 1, false}, {"-a", 2, true}, {"ab", 2, true}, {"ab", 3, false}, {"", 1, false}} {
		if got := wordAt(c.s, c.i); got != c.want {
			t.Errorf("wordAt(%q, %d) = %v, want %v", c.s, c.i, got, c.want)
		}
	}
}
