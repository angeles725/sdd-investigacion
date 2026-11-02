package lint

import (
	"os"
	"reflect"
	"regexp"
	"testing"
)

// compiledAtInit is how many registered patterns were already compiled when the tests started, i.e. by
// package initialisation. It must be zero: compiling at init is the ~45 ms every rsdd command paid.
var compiledAtInit = -1

func TestMain(m *testing.M) {
	compiledAtInit = countCompiled()
	os.Exit(m.Run())
}

func countCompiled() int {
	allLazyMu.Lock()
	defer allLazyMu.Unlock()
	n := 0
	for _, l := range allLazy {
		if l.re != nil {
			n++
		}
	}
	return n
}

func TestLazyRENothingCompiledAtInit(t *testing.T) {
	allLazyMu.Lock()
	registered := len(allLazy)
	allLazyMu.Unlock()
	if registered < 50 {
		t.Fatalf("empty-input: only %d lazy patterns registered; the package-level patterns are not built through newLazyRE", registered)
	}
	if compiledAtInit != 0 {
		t.Fatalf("%d of %d patterns were compiled during package init, want 0 (startup cost on every rsdd command)", compiledAtInit, registered)
	}
}

// TestLazyREAllCompile forces every registered pattern, so a pattern that does not compile fails here and not
// first on a user's block.
func TestLazyREAllCompile(t *testing.T) {
	allLazyMu.Lock()
	all := append([]*lazyRE(nil), allLazy...)
	allLazyMu.Unlock()
	for _, l := range all {
		func() {
			defer func() {
				if r := recover(); r != nil {
					t.Errorf("pattern %q does not compile: %v", l.src, r)
				}
			}()
			if l.get() == nil || l.String() != l.src {
				t.Errorf("pattern %q: get()=nil or String()=%q", l.src, l.String())
			}
		}()
	}
}

func TestLazyREDefersCompileAndPanicsOnFirstUse(t *testing.T) {
	bad := &lazyRE{src: `(`} // not registered: TestLazyREAllCompile must not see it
	if bad.re != nil {
		t.Fatal("compiled before first use")
	}
	defer func() {
		if recover() == nil {
			t.Fatal("an invalid pattern did not panic on first use (regexp.MustCompile semantics lost)")
		}
	}()
	bad.MatchString("x")
}

func TestLazyRECompilesOnce(t *testing.T) {
	l := &lazyRE{src: `a+`}
	first := l.get()
	if first == nil || l.get() != first {
		t.Fatal("get() must compile once and return the same *regexp.Regexp")
	}
}

func TestLazyREForwardsLikeRegexp(t *testing.T) {
	const src, in = `(b)(\d+)?`, "ab1 b22 c b"
	l, r := &lazyRE{src: src}, regexp.MustCompile(src)
	up := func(s string) string { return "<" + s + ">" }
	pairs := []struct {
		name      string
		got, want any
	}{
		{"MatchString", l.MatchString(in), r.MatchString(in)},
		{"MatchString-miss", l.MatchString("zzz"), r.MatchString("zzz")},
		{"FindStringIndex", l.FindStringIndex(in), r.FindStringIndex(in)},
		{"FindStringSubmatch", l.FindStringSubmatch(in), r.FindStringSubmatch(in)},
		{"FindStringSubmatchIndex", l.FindStringSubmatchIndex(in), r.FindStringSubmatchIndex(in)},
		{"FindAllString", l.FindAllString(in, 2), r.FindAllString(in, 2)},
		{"FindAllStringIndex", l.FindAllStringIndex(in, -1), r.FindAllStringIndex(in, -1)},
		{"FindAllStringSubmatch", l.FindAllStringSubmatch(in, -1), r.FindAllStringSubmatch(in, -1)},
		{"ReplaceAllString", l.ReplaceAllString(in, "[$1]"), r.ReplaceAllString(in, "[$1]")},
		{"ReplaceAllStringFunc", l.ReplaceAllStringFunc(in, up), r.ReplaceAllStringFunc(in, up)},
		{"Split", l.Split(in, -1), r.Split(in, -1)},
		{"Split-n", l.Split(in, 2), r.Split(in, 2)},
		{"String", l.String(), r.String()},
	}
	for _, p := range pairs {
		if !reflect.DeepEqual(p.got, p.want) {
			t.Errorf("%s: lazyRE=%#v, regexp=%#v", p.name, p.got, p.want)
		}
	}
}
