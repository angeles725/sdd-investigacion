// Package lazyre is a regular expression that compiles on first use instead of at package initialisation.
//
// A package-level `var re = regexp.MustCompile(...)` runs during process start for every package the rsdd binary
// links, whichever command was asked for: ~100 patterns across the domains cost several milliseconds and several
// hundred KB before main (GODEBUG=inittrace=1 shows it). `var re = lazyre.MustCompile(...)` costs one small
// allocation at start and compiles when the first call needs it, exactly once, safely from many goroutines.
//
// Behaviour kept: the method set mirrors *regexp.Regexp for the methods the callers use, and an invalid pattern
// still panics with the same regexp message. What moves is WHEN: at first use instead of at init, so a bad
// pattern would no longer stop the process before main. CompileAll restores that guarantee for tests: every
// handle registers itself, and a test in the registry tier (internal/commands) compiles them all.
//
// Use it for package-level patterns only. Build function-local patterns with regexp directly.
package lazyre

import (
	"errors"
	"fmt"
	"regexp"
	"sync"
	"sync/atomic"
)

// compile is the seam the tests count compiles through.
var compile = regexp.MustCompile

// Regexp is a lazily compiled regular expression. Build it with MustCompile; the zero value is not usable.
type Regexp struct {
	expr    string
	longest bool // leftmost-longest matching, as regexp.Regexp.Longest
	once    sync.Once
	re      *regexp.Regexp
	fail    any         // the panic value of a pattern that does not compile, replayed on every later use
	done    atomic.Bool // set once re is usable, so Stats can read it without racing the compile
}

var (
	mu       sync.Mutex
	registry []*Regexp
)

// MustCompile returns a handle for expr without compiling it. The pattern is compiled by regexp.MustCompile at
// the first method call; an invalid pattern panics there (and on every later call) with regexp's own message.
func MustCompile(expr string) *Regexp { return register(&Regexp{expr: expr}) }

// MustCompileLongest is MustCompile followed by Longest() on the compiled expression (POSIX leftmost-longest
// matching, what `grep -E -o` prints), applied before the first match.
func MustCompileLongest(expr string) *Regexp { return register(&Regexp{expr: expr, longest: true}) }

func register(r *Regexp) *Regexp {
	mu.Lock()
	registry = append(registry, r)
	mu.Unlock()
	return r
}

// get compiles the pattern on the first call (exactly once, whatever the number of goroutines) and returns it.
func (r *Regexp) get() *regexp.Regexp {
	r.once.Do(r.build)
	if r.fail != nil {
		panic(r.fail)
	}
	return r.re
}

func (r *Regexp) build() {
	defer func() {
		if p := recover(); p != nil {
			r.fail = p
		}
	}()
	re := compile(r.expr)
	if r.longest {
		re.Longest()
	}
	r.re = re
	r.done.Store(true)
}

// Stats reports how many handles are registered and how many of them have compiled. A process that has only
// started has compiled none: that is the point of the package, and a test that links the whole binary asserts it.
func Stats() (registered, compiled int) {
	mu.Lock()
	defer mu.Unlock()
	for _, r := range registry {
		if r.done.Load() {
			compiled++
		}
	}
	return len(registry), compiled
}

// CompileAll compiles every pattern registered so far and returns how many there were and the joined errors of the
// ones that do not compile (nil when all do). It is the init-time check that lazy compilation gives up: a test
// that links the whole binary calls it, and a count of 0 there means the test looked at nothing.
func CompileAll() (int, error) {
	mu.Lock()
	all := append([]*Regexp(nil), registry...)
	mu.Unlock()
	var errs []error
	for _, r := range all {
		if err := r.try(); err != nil {
			errs = append(errs, err)
		}
	}
	return len(all), errors.Join(errs...)
}

func (r *Regexp) try() (err error) {
	defer func() {
		if p := recover(); p != nil {
			err = fmt.Errorf("lazyre: %v", p)
		}
	}()
	r.get()
	return nil
}

// Get returns the compiled expression, for the rare callee that needs a *regexp.Regexp.
func (r *Regexp) Get() *regexp.Regexp { return r.get() }

// String returns the source text of the pattern without compiling it.
func (r *Regexp) String() string { return r.expr }

func (r *Regexp) MatchString(s string) bool              { return r.get().MatchString(s) }
func (r *Regexp) Match(b []byte) bool                    { return r.get().Match(b) }
func (r *Regexp) FindString(s string) string             { return r.get().FindString(s) }
func (r *Regexp) FindStringIndex(s string) []int         { return r.get().FindStringIndex(s) }
func (r *Regexp) FindStringSubmatch(s string) []string   { return r.get().FindStringSubmatch(s) }
func (r *Regexp) FindAllString(s string, n int) []string { return r.get().FindAllString(s, n) }
func (r *Regexp) FindAllStringSubmatch(s string, n int) [][]string {
	return r.get().FindAllStringSubmatch(s, n)
}
func (r *Regexp) FindStringSubmatchIndex(s string) []int     { return r.get().FindStringSubmatchIndex(s) }
func (r *Regexp) FindAllStringIndex(s string, n int) [][]int { return r.get().FindAllStringIndex(s, n) }
func (r *Regexp) FindAllIndex(b []byte, n int) [][]int       { return r.get().FindAllIndex(b, n) }
func (r *Regexp) FindSubmatch(b []byte) [][]byte             { return r.get().FindSubmatch(b) }
func (r *Regexp) ReplaceAllString(src, repl string) string {
	return r.get().ReplaceAllString(src, repl)
}
func (r *Regexp) Split(s string, n int) []string { return r.get().Split(s, n) }
func (r *Regexp) ReplaceAllStringFunc(src string, f func(string) string) string {
	return r.get().ReplaceAllStringFunc(src, f)
}
