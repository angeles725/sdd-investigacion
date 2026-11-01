package lint

import (
	"regexp"
	"sync"
)

// lazyRE is a regular expression compiled on its first use instead of at package init.
//
// Every rsdd process links this package, so compiling its ~80 package-level patterns at init cost every
// command ~45 ms and ~6 MB before main ran (GODEBUG=inittrace=1), lint or not. A lazyRE keeps the pattern
// source and compiles it once, under a sync.Once, the first time a method needs it. A pattern that does not
// compile panics on that first use, exactly as regexp.MustCompile did at init; TestLazyREAllCompile forces
// every registered pattern so a bad one still fails in tests, not first in production.
type lazyRE struct {
	src  string
	once sync.Once
	re   *regexp.Regexp
}

// allLazy registers every lazyRE built by newLazyRE, for TestLazyREAllCompile.
var (
	allLazyMu sync.Mutex
	allLazy   []*lazyRE
)

func newLazyRE(src string) *lazyRE {
	l := &lazyRE{src: src}
	allLazyMu.Lock()
	allLazy = append(allLazy, l)
	allLazyMu.Unlock()
	return l
}

// get compiles the pattern on the first call and returns the compiled form.
func (l *lazyRE) get() *regexp.Regexp {
	l.once.Do(func() { l.re = regexp.MustCompile(l.src) })
	return l.re
}

func (l *lazyRE) String() string                 { return l.src }
func (l *lazyRE) MatchString(s string) bool      { return l.get().MatchString(s) }
func (l *lazyRE) FindStringIndex(s string) []int { return l.get().FindStringIndex(s) }
func (l *lazyRE) FindStringSubmatch(s string) []string {
	return l.get().FindStringSubmatch(s)
}
func (l *lazyRE) FindStringSubmatchIndex(s string) []int {
	return l.get().FindStringSubmatchIndex(s)
}
func (l *lazyRE) FindAllString(s string, n int) []string { return l.get().FindAllString(s, n) }
func (l *lazyRE) FindAllStringIndex(s string, n int) [][]int {
	return l.get().FindAllStringIndex(s, n)
}
func (l *lazyRE) FindAllStringSubmatch(s string, n int) [][]string {
	return l.get().FindAllStringSubmatch(s, n)
}
func (l *lazyRE) ReplaceAllString(src, repl string) string {
	return l.get().ReplaceAllString(src, repl)
}
func (l *lazyRE) ReplaceAllStringFunc(src string, repl func(string) string) string {
	return l.get().ReplaceAllStringFunc(src, repl)
}
func (l *lazyRE) Split(s string, n int) []string { return l.get().Split(s, n) }
