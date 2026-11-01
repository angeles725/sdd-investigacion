package stageissues

import (
	"strings"
	"testing"
)

// Unit tests of the pure helpers. They carry no build tag and use no bash, so the mutation run (-tags nodiff)
// exercises them too; the behaviour of the whole command is pinned by the golden and differential tests.

func TestCksumKnownVectors(t *testing.T) {
	// POSIX cksum(1): `printf %s 123456789 | cksum` prints 930766865 9.
	for _, c := range []struct {
		in   string
		want uint32
	}{
		{"123456789", 930766865},
		{"", 4294967295},
		{"a\n", 1220704766},
	} {
		if got := cksum([]byte(c.in)); got != c.want {
			t.Errorf("cksum(%q) = %d, want %d", c.in, got, c.want)
		}
	}
}

func TestTitleUnusable(t *testing.T) {
	for _, c := range []struct {
		title  string
		bad    bool
		reason string
	}{
		{"LOW", true, "a bare priority/type token"},
		{" Feature ", true, "a bare priority/type token"},
		{"doc-fix", true, "a bare priority/type token"},
		{"short", true, "a title under 12 characters"},
		{"elevenchars", true, "a title under 12 characters"},
		{"twelve chars", false, ""},
		{"éééééééééééé", false, ""},                          // 12 characters, 24 bytes
		{"ééééééééééé", true, "a title under 12 characters"}, // 11 characters, 22 bytes
		{"regression in the parser", false, ""},
	} {
		bad, why := titleUnusable(c.title)
		if bad != c.bad || why != c.reason {
			t.Errorf("titleUnusable(%q) = %v, %q; want %v, %q", c.title, bad, why, c.bad, c.reason)
		}
	}
}

func TestLocaleUTF8(t *testing.T) {
	env := func(m map[string]string) func(string) string { return func(k string) string { return m[k] } }
	for _, c := range []struct {
		name string
		env  map[string]string
		want bool
	}{
		{"none", nil, false},
		{"LANG utf8", map[string]string{"LANG": "en_US.UTF-8"}, true},
		{"LANG utf8 lower", map[string]string{"LANG": "C.utf8"}, true},
		{"LC_ALL beats LANG", map[string]string{"LC_ALL": "C", "LANG": "en_US.UTF-8"}, false},
		{"LC_CTYPE beats LANG", map[string]string{"LC_CTYPE": "POSIX", "LANG": "en_US.UTF-8"}, false},
		{"LC_ALL utf8 beats LC_CTYPE", map[string]string{"LC_ALL": "C.UTF-8", "LC_CTYPE": "C"}, true},
		{"latin1", map[string]string{"LANG": "en_US.ISO-8859-1"}, false},
	} {
		if got := localeUTF8(env(c.env)); got != c.want {
			t.Errorf("%s: got %v want %v", c.name, got, c.want)
		}
	}
}

func TestCharCounting(t *testing.T) {
	a := &app{utf8: true}
	s := "aé\xffz" // 4 characters in a UTF-8 locale (the invalid byte counts as one), 5 bytes
	if a.charLen(s) != 4 || a.cutChars(s, 2) != "aé" || a.cutChars(s, 3) != "aé\xff" || a.cutChars(s, 99) != s {
		t.Errorf("utf8 counting: len=%d cut2=%q cut3=%q", a.charLen(s), a.cutChars(s, 2), a.cutChars(s, 3))
	}
	b := &app{}
	if b.charLen(s) != 5 || b.cutChars(s, 2) != "a\xc3" || b.cutChars(s, 99) != s {
		t.Errorf("byte counting: len=%d cut2=%q", b.charLen(s), b.cutChars(s, 2))
	}
}

func TestUncAddFlattensEscapesAndCuts(t *testing.T) {
	a := &app{}
	a.uncAdd(true, "3", " a|b\r\n\tc ", "why")
	a.uncAdd(false, "4", strings.Repeat("x", 120), "long")
	if a.uncN != 2 || a.uncSec != 1 {
		t.Fatalf("counters: n=%d sec=%d", a.uncN, a.uncSec)
	}
	if got := a.uncRecs[0].head; got != `a\|b   c` {
		t.Errorf("flatten/escape/trim: %q", got)
	}
	if got := a.uncRecs[1].head; got != strings.Repeat("x", 97)+"..." {
		t.Errorf("cut at 100: %q (len %d)", got, len(got))
	}
}

func TestSedTableAndIndent(t *testing.T) {
	body := "intro\n\n| # | where | head | reason |\n|---|---|---|---|\n| 1 | r.md:3 | h | r |\n\n---\nsig"
	if got, want := sedTable(body), "| # | where | head | reason |\n|---|---|---|---|\n| 1 | r.md:3 | h | r |\n"; got != want {
		t.Errorf("sedTable = %q, want %q", got, want)
	}
	if got := sedTable("no table here"); got != "" {
		t.Errorf("sedTable without a table = %q", got)
	}
	if got := indent4("a\n\nb"); got != "    a\n    \n    b" {
		t.Errorf("indent4 = %q", got)
	}
}

func TestSortIntsAndHasLine(t *testing.T) {
	v := []int{9, 3, 12, 3, 1}
	sortInts(v)
	for i, w := range []int{1, 3, 3, 9, 12} {
		if v[i] != w {
			t.Fatalf("sortInts = %v", v)
		}
	}
	if !hasLine("a\nsig\nb", "sig") || hasLine("a\nsig x\nb", "sig") || hasLine("", "sig") {
		t.Error("hasLine must match a whole line only")
	}
}

func TestListFilled(t *testing.T) {
	a := &app{listLimit: "3", listLimitN: 3}
	for _, c := range []struct {
		scan string
		want bool
	}{
		{"total=2", false},
		{"total=3", true},
		{"OPEN\ntotal=9", true},
		{"no total line", true}, // an unreadable scan never reads as "not filled"
		{"total=99999999999999999999", false},
	} {
		if got := a.listFilled(c.scan); got != c.want {
			t.Errorf("listFilled(%q) = %v, want %v", c.scan, got, c.want)
		}
	}
	// An out-of-range limit is still "a positive integer": the run goes on and the limit never reads as filled.
	h := &app{listLimit: "99999999999999999999", listLimitN: 1<<63 - 1}
	if h.listFilled("total=1000000") {
		t.Error("a huge limit must never read as filled")
	}
}
