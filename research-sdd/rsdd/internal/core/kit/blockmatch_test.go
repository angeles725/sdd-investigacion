package kit

import (
	"math/rand"
	"reflect"
	"regexp"
	"strings"
	"testing"
)

// kit issue #2686: FilterBlockFiles decides a line by a hand-written matcher where the prefix is empty or plain
// literals, and by the POSIX regexp otherwise. The matcher must say what the regexp says on every line.

// blockRef is the regexp the matcher stands for, built the way FilterBlockFiles builds it.
func blockRef(prefix string) *regexp.Regexp {
	if prefix == "" {
		return reBlock
	}
	return regexp.MustCompilePOSIX(`(^|/)` + prefix + blockTail)
}

var matchTokens = []string{
	"a", "x", "-", "/", "block", "bloque", "bloc", "blocke", "1", "07", ".md", ".", "_", "é", "\n", "B", "tema3-", "a-", "M", " ", "\xff",
}

var matchPrefixes = []string{"", "a-", "tema3-", "x", "-", "A_1-", "block", "bloque-", "a-a-", "1", "_"}

func checkMatcher(t *testing.T, line string) {
	t.Helper()
	for _, p := range matchPrefixes {
		m := fastBlockMatcher(p)
		if m == nil {
			t.Fatalf("no matcher for the literal prefix %q", p)
		}
		if got, want := m(line), blockRef(p).MatchString(line); got != want {
			t.Fatalf("prefix %q, line %q: matcher says %v, regexp says %v", p, line, got, want)
		}
	}
}

func TestFastBlockMatcherAgreesWithRegexp(t *testing.T) {
	t.Parallel()
	var gen func(prefix string, depth int)
	n := 0
	gen = func(s string, depth int) {
		checkMatcher(t, s)
		n++
		if depth == 0 {
			return
		}
		for _, tok := range matchTokens {
			gen(s+tok, depth-1)
		}
	}
	gen("", 3)
	rng := rand.New(rand.NewSource(2686))
	for i := 0; i < 5000; i++ {
		var b strings.Builder
		for j, k := 0, 3+rng.Intn(8); j < k; j++ {
			b.WriteString(matchTokens[rng.Intn(len(matchTokens))])
		}
		checkMatcher(t, b.String())
		n++
	}
	for _, l := range []string{
		"/corpus/tema3-block1.md", "/corpus/prefix-bloque12.md", "/corpus/ab-block3-foo-bar.md", "/corpus/block12.md", "bloque3.md",
		"prefix-block7.md", "/c/a-block1-a_b-C9.md", "/c/a-block1-a.b.md", "/c/a-block1-.md", "/c/a-block-1.md", "/c/a-block1.md\r",
		"/c/a-block1.md/x", "/c/-block1.md", "-block1.md", "a--block1.md", "a-block1-block2.md", "a-blocks1.md", "a-bloque.md", "/", "", ".md",
		"/c/tema3-block1.md", "tema3-bloque4-x.md", "x-tema3-block1.md", "/d/a-bloque007.md", "a-block1-2-3.md", "a-block1--.md", "a-block1-é.md",
	} {
		checkMatcher(t, l)
	}
	if n < 10000 {
		t.Fatalf("only %d lines were compared", n)
	}
}

func TestFastBlockMatcherDeclinesWhatOnlyTheRegexpDecides(t *testing.T) {
	t.Parallel()
	for _, p := range []string{"(", "[", "t.", "x|y", "+", "a b", "a/", "é", "a\n", "[[:foo:]]", "a*", "\\"} {
		if fastBlockMatcher(p) != nil {
			t.Errorf("prefix %q is not plain literals: only the regexp may decide", p)
		}
	}
}

// Every byte is checked against the written-out alphabet, so a shifted class boundary ('0' vs '1', 'Z' vs 'Y')
// is caught at the exact byte it moves.
func TestIsLiteralPrefixAcceptsExactlyTheERELiteralBytes(t *testing.T) {
	t.Parallel()
	const alnum = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
	const literal = alnum + "_-"
	for b := 0; b < 256; b++ {
		s := string([]byte{byte(b)})
		want := strings.Contains(literal, s)
		if got := isLiteralPrefix(s); got != want {
			t.Errorf("isLiteralPrefix(%q) = %v, want %v", s, got, want)
		}
		if got := isLiteralPrefix("ok" + s + "ok"); got != want {
			t.Errorf("isLiteralPrefix judges %q differently in the middle of a prefix", s)
		}
	}
	if !isLiteralPrefix("") {
		t.Error("the empty prefix is literal")
	}
}

// The slug class is ASCII alphanumerics, '_' and '-': the byte just outside each range is not a slug byte.
func TestFastBlockMatcherSlugBytes(t *testing.T) {
	t.Parallel()
	const slug = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_-"
	for _, p := range []string{"", "a-"} {
		m := fastBlockMatcher(p)
		for b := 0; b < 256; b++ {
			s := string([]byte{byte(b)})
			if got, want := m("/c/a-block1-"+s+".md"), strings.Contains(slug, s); got != want {
				t.Errorf("prefix %q: slug byte %q: matcher %v, want %v", p, s, got, want)
			}
		}
	}
}

// FilterBlockFiles end to end over the shared cases and the regexp reference, in both directions.
func TestFilterBlockFilesAgreesWithRegexpReference(t *testing.T) {
	t.Parallel()
	lines := []string{"/c/a-block1.md", "/c/a-bloque2-x.md", "/c/b-block1.md", "/c/ab-block3.md", "/c/notes.md", "/c/a-block.md", "/c/xa-block9.md", "", "a-block1.md", "/c/a-block1.mdx"}
	for _, p := range append([]string{"a.", "(a|b)-", "[", "x|y"}, matchPrefixes...) {
		for _, invert := range []bool{false, true} {
			re := blockRef(p)
			var want []string
			for _, l := range lines {
				if re.MatchString(l) != invert {
					want = append(want, l)
				}
			}
			got, err := FilterBlockFiles(lines, invert, p)
			if (err == nil) != (len(want) > 0) || !reflect.DeepEqual(got, want) {
				t.Errorf("prefix %q invert %v: got %q (%v), want %q", p, invert, got, err, want)
			}
		}
	}
}
