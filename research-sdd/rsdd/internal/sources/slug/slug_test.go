package slug

import (
	"strings"
	"testing"
)

// The expected values are what the frozen legacy web_slug printed (see ../fetchdoc/testdata/legacy).
func TestWebMatchesLegacy(t *testing.T) {
	long := "http://h/" + strings.Repeat("0", 90) + "7"
	long2 := "http://h/" + strings.Repeat("a", 120) + "?x=1"
	for _, c := range []struct{ url, want string }{
		{"http://a.b/c?d=e", "a.b_c_d_e"},
		{"https://x/é/ü", "x______"},
		{"ftp://x/?u=http://y/z", "ftp___x__u_y_z"},
		{long, "h_" + strings.Repeat("0", 44) + "_" + strings.Repeat("0", 19) + "7-e25922ff4a1b"},
		{long2, "h_" + strings.Repeat("a", 44) + "_" + strings.Repeat("a", 16) + "_x_1-bf49db32c8b2"},
	} {
		if got := Web(c.url); got != c.want {
			t.Errorf("%q: got %q want %q", c.url, got, c.want)
		}
	}
}

func TestWebBoundaryAt80(t *testing.T) {
	at80 := strings.Repeat("b", 80)
	if got := Web("http://" + at80); got != at80 {
		t.Errorf("80 bytes must stay unchanged, got %q", got)
	}
	got := Web("http://" + at80 + "c")
	if len(got) != 80 || !strings.Contains(got, "-") {
		t.Errorf("81 bytes must be shortened to 80 with a hash: %q (%d)", got, len(got))
	}
}

func TestWebHashCoversTheSchemeAndTheFullURL(t *testing.T) {
	a := Web("http://" + strings.Repeat("x", 100))
	b := Web("https://" + strings.Repeat("x", 100))
	if a == b {
		t.Error("http and https long URLs must get different names")
	}
	if Web("http://"+strings.Repeat("x", 100)+"1") == Web("http://"+strings.Repeat("x", 100)+"2") {
		t.Error("URLs differing only in the tail must not collide")
	}
}

func TestWebIsBytewiseForMultibyteCharacters(t *testing.T) {
	if got := Web("é"); got != "__" {
		t.Errorf("one underscore per byte, got %q", got)
	}
	if got := Web("a\xffb"); got != "a_b" {
		t.Errorf("invalid UTF-8 byte: %q", got)
	}
}

// Every class edge: the byte just inside is kept, the byte just outside becomes "_".
func TestSafeClassEdges(t *testing.T) {
	for _, c := range []struct {
		b    byte
		keep bool
	}{
		{'`', false}, {'a', true}, {'z', true}, {'{', false},
		{'@', false}, {'A', true}, {'Z', true}, {'[', false},
		{'/', false}, {'0', true}, {'9', true}, {':', false},
		{'.', true}, {'_', true}, {'-', true}, {',', false}, {'~', false}, {'^', false},
	} {
		if safe(c.b) != c.keep {
			t.Errorf("safe(%q) = %v, want %v", c.b, !c.keep, c.keep)
		}
		if got := bytewise(string([]byte{c.b})); (got == string([]byte{c.b})) != c.keep {
			t.Errorf("bytewise(%q) = %q", c.b, got)
		}
	}
}
