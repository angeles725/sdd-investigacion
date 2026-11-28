package lazyre

import (
	"reflect"
	"regexp"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
)

// countCompiles swaps the compile seam for a counting one and restores it on cleanup.
func countCompiles(t *testing.T) *atomic.Int64 {
	t.Helper()
	var n atomic.Int64
	prev := compile
	compile = func(expr string) *regexp.Regexp { n.Add(1); return regexp.MustCompile(expr) }
	t.Cleanup(func() { compile = prev })
	return &n
}

func mustPanic(t *testing.T, f func()) (msg string) {
	t.Helper()
	defer func() {
		r := recover()
		if r == nil {
			t.Fatal("expected a panic, got none")
		}
		msg, _ = r.(string)
		if msg == "" {
			if e, ok := r.(error); ok {
				msg = e.Error()
			}
		}
	}()
	f()
	return ""
}

func TestMustCompileDoesNotCompileUntilFirstUse(t *testing.T) {
	n := countCompiles(t)
	r := MustCompile(`^a+b$`)
	if got := n.Load(); got != 0 {
		t.Fatalf("compiled %d times at declaration, want 0", got)
	}
	if !r.MatchString("aaab") {
		t.Fatal("MatchString(aaab) = false, want true")
	}
	if got := n.Load(); got != 1 {
		t.Fatalf("compiled %d times after first use, want 1", got)
	}
}

func TestCompilesExactlyOnceAcrossManyUses(t *testing.T) {
	n := countCompiles(t)
	r := MustCompile(`(\d+)-(\d+)`)
	for i := 0; i < 50; i++ {
		_ = r.MatchString("1-2")
		_ = r.FindStringSubmatch("3-4")
		_ = r.ReplaceAllString("5-6", "$2")
	}
	if got := n.Load(); got != 1 {
		t.Fatalf("compiled %d times over 150 uses, want 1", got)
	}
}

func TestInvalidPatternPanicsAtFirstUseNotAtDeclaration(t *testing.T) {
	n := countCompiles(t)
	var r *Regexp
	var atDeclaration any
	func() {
		defer func() { atDeclaration = recover() }()
		r = MustCompile(`(unclosed`)
	}()
	if atDeclaration != nil {
		t.Fatalf("MustCompile panicked at declaration: %v", atDeclaration)
	}
	t.Cleanup(func() { unregisterForTest(t, r) })
	msg := mustPanic(t, func() { r.MatchString("x") })
	if !strings.Contains(msg, "(unclosed") {
		t.Fatalf("panic %q does not name the pattern", msg)
	}
	// a second use panics again with the same message, never with a nil dereference
	if again := mustPanic(t, func() { r.FindString("x") }); again != msg {
		t.Fatalf("second panic %q differs from first %q", again, msg)
	}
	if got := n.Load(); got != 1 {
		t.Fatalf("an invalid pattern was compiled %d times over two uses, want 1", got)
	}
}

func TestConcurrentFirstUseCompilesOnce(t *testing.T) {
	n := countCompiles(t)
	r := MustCompile(`^(?P<k>[a-z]+)=(?P<v>\d+)$`)
	const workers = 64
	var wg sync.WaitGroup
	start := make(chan struct{})
	res := make([][]string, workers)
	for i := 0; i < workers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			<-start
			res[i] = r.FindStringSubmatch("key=42")
		}()
	}
	close(start)
	wg.Wait()
	if got := n.Load(); got != 1 {
		t.Fatalf("compiled %d times under %d concurrent first uses, want 1", got, workers)
	}
	for i, got := range res {
		if !reflect.DeepEqual(got, []string{"key=42", "key", "42"}) {
			t.Fatalf("worker %d got %q", i, got)
		}
	}
}

func TestMethodsMatchRegexp(t *testing.T) {
	const expr = `(\w)(\d+)`
	const in = "a1 b22 c333 d"
	ref := regexp.MustCompile(expr)
	r := MustCompile(expr)
	same := func(name string, got, want any) {
		t.Helper()
		if !reflect.DeepEqual(got, want) {
			t.Errorf("%s: got %#v, want %#v", name, got, want)
		}
	}
	same("MatchString", r.MatchString(in), ref.MatchString(in))
	same("MatchString-no", r.MatchString("zzz"), ref.MatchString("zzz"))
	same("Match", r.Match([]byte(in)), ref.Match([]byte(in)))
	same("FindString", r.FindString(in), ref.FindString(in))
	same("FindStringIndex", r.FindStringIndex(in), ref.FindStringIndex(in))
	same("FindStringIndex-no", r.FindStringIndex("zzz"), ref.FindStringIndex("zzz"))
	same("FindStringSubmatch", r.FindStringSubmatch(in), ref.FindStringSubmatch(in))
	same("FindStringSubmatchIndex", r.FindStringSubmatchIndex(in), ref.FindStringSubmatchIndex(in))
	same("FindAllStringIndex", r.FindAllStringIndex(in, -1), ref.FindAllStringIndex(in, -1))
	same("FindAllString", r.FindAllString(in, -1), ref.FindAllString(in, -1))
	same("FindAllString-n", r.FindAllString(in, 2), ref.FindAllString(in, 2))
	same("FindAllStringSubmatch", r.FindAllStringSubmatch(in, -1), ref.FindAllStringSubmatch(in, -1))
	same("FindAllIndex", r.FindAllIndex([]byte(in), -1), ref.FindAllIndex([]byte(in), -1))
	same("FindSubmatch", r.FindSubmatch([]byte(in)), ref.FindSubmatch([]byte(in)))
	same("ReplaceAllString", r.ReplaceAllString(in, "<$2$1>"), ref.ReplaceAllString(in, "<$2$1>"))
	up := strings.ToUpper
	same("ReplaceAllStringFunc", r.ReplaceAllStringFunc(in, up), ref.ReplaceAllStringFunc(in, up))
	same("Split", r.Split(in, -1), ref.Split(in, -1))
	same("String", r.String(), ref.String())
	if r.Get() != r.Get() {
		t.Error("Get must return the one compiled expression every time")
	}
}

func TestCompileAllReportsCountAndBadPatterns(t *testing.T) {
	before, err := CompileAll()
	if err != nil {
		t.Fatalf("baseline CompileAll: %v", err)
	}
	good := MustCompile(`^ok$`)
	bad := MustCompile(`[unterminated`)
	t.Cleanup(func() { unregisterForTest(t, good); unregisterForTest(t, bad) })
	n, err := CompileAll()
	if n != before+2 {
		t.Fatalf("CompileAll counted %d patterns, want %d (baseline %d + 2 registered)", n, before+2, before)
	}
	if err == nil || !strings.Contains(err.Error(), "[unterminated") {
		t.Fatalf("CompileAll error %v does not name the bad pattern", err)
	}
	if strings.Contains(err.Error(), "^ok$") {
		t.Fatalf("CompileAll error %v blames the good pattern", err)
	}
}

func TestCompileAllEmptyRegistryIsZeroNotError(t *testing.T) {
	saved := swapRegistryForTest(nil)
	t.Cleanup(func() { swapRegistryForTest(saved) })
	n, err := CompileAll()
	if n != 0 || err != nil {
		t.Fatalf("empty registry: got (%d, %v), want (0, nil)", n, err)
	}
}

func TestStatsCountsRegisteredAndCompiled(t *testing.T) {
	saved := swapRegistryForTest(nil)
	t.Cleanup(func() { swapRegistryForTest(saved) })
	if reg, comp := Stats(); reg != 0 || comp != 0 {
		t.Fatalf("empty registry: Stats() = (%d, %d), want (0, 0)", reg, comp)
	}
	a, b := MustCompile(`a`), MustCompile(`b`)
	if reg, comp := Stats(); reg != 2 || comp != 0 {
		t.Fatalf("two declared, none used: Stats() = (%d, %d), want (2, 0)", reg, comp)
	}
	a.MatchString("a")
	if reg, comp := Stats(); reg != 2 || comp != 1 {
		t.Fatalf("one used: Stats() = (%d, %d), want (2, 1)", reg, comp)
	}
	b.MatchString("b")
	if reg, comp := Stats(); reg != 2 || comp != 2 {
		t.Fatalf("both used: Stats() = (%d, %d), want (2, 2)", reg, comp)
	}
}

func TestMustCompileLongestIsLeftmostLongest(t *testing.T) {
	const expr, in = `a|ab`, "xab"
	first, longest := MustCompile(expr), MustCompileLongest(expr)
	if got := first.FindString(in); got != "a" {
		t.Fatalf("MustCompile leftmost-first: got %q, want %q", got, "a")
	}
	if got := longest.FindString(in); got != "ab" {
		t.Fatalf("MustCompileLongest leftmost-longest: got %q, want %q", got, "ab")
	}
	ref := regexp.MustCompile(expr)
	ref.Longest()
	if got, want := longest.FindAllIndex([]byte("ab a ab"), -1), ref.FindAllIndex([]byte("ab a ab"), -1); !reflect.DeepEqual(got, want) {
		t.Fatalf("FindAllIndex: got %v, want %v", got, want)
	}
}
