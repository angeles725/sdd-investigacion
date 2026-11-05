package stageissues

import "testing"

// Pure unit tests for the scrub helpers and the word-boundary rules (kit issue #2592).

func TestUpperASCIIEdges(t *testing.T) {
	if got := upperASCII("abcxyz`{@[Az09"); got != "ABCXYZ`{@[AZ09" {
		t.Errorf("upperASCII = %q", got)
	}
}

func TestIsAlnumEdges(t *testing.T) {
	yes := "azAZ09mM5"
	no := "`{@[/:_-. "
	for i := 0; i < len(yes); i++ {
		if !isAlnum(yes[i]) {
			t.Errorf("isAlnum(%q) = false", yes[i])
		}
	}
	for i := 0; i < len(no); i++ {
		if isAlnum(no[i]) {
			t.Errorf("isAlnum(%q) = true", no[i])
		}
	}
}

func TestScrubTextBoundaries(t *testing.T) {
	tok := "0123456789abcdef0123"
	cases := []struct {
		name, in, want string
		count          int
	}{
		{"token at line start", "ghp_abcdef", "<redacted>", 1},
		{"token after an underscore is word-internal", "_ghp_abcdef", "_ghp_abcdef", 0},
		{"bearer after a space", "x Bearer " + tok, "x Bearer <redacted>", 1},
		{"bearer after a letter is word-internal", "xbearer " + tok, "xbearer " + tok, 0},
		{"bearer after an underscore is word-internal", "_bearer " + tok, "_bearer " + tok, 0},
		{"assignment with an empty value at end of line", "TOKEN=", "TOKEN=", 0},
		{"assignment key stops before the equals sign", "TOKEN=abc", "TOKEN=<redacted>", 1},
		{"rejected path candidate does not hide a later path", "a/home/x /home/y", "a/home/x <path>", 1},
		{"a rejected candidate past index 1 keeps the later path's offset", "ab/home/x  /home/y", "ab/home/x  <path>", 1},
	}
	for _, c := range cases {
		got, n := scrubText(c.in)
		if got != c.want || n != c.count {
			t.Errorf("%s: scrubText(%q) = %q,%d want %q,%d", c.name, c.in, got, n, c.want, c.count)
		}
	}
}
