package verify

import (
	"io"
	"regexp"
	"sort"
	"strings"
	"sync"
	"unicode"
	"unicode/utf8"
)

// Shell-compatible helpers of the verify-block port: the pieces of grep, awk, sed, sort, cut, dirname and
// basename that verify-block.sh leans on, with the semantics the script saw (GNU tools, a UTF-8 locale whose
// collation is the code-point order). Nothing here reads the environment.

// vbRE is a regular expression compiled on first use (every rsdd process links this package) and set to
// leftmost-longest, the POSIX rule of grep -E, gawk and sed -E that Go's default leftmost-first does not follow.
type vbRE struct {
	src  string
	once sync.Once
	re   *regexp.Regexp
}

var (
	vbAllMu sync.Mutex
	vbAll   []*vbRE
)

func newVB(src string) *vbRE {
	l := &vbRE{src: src}
	vbAllMu.Lock()
	vbAll = append(vbAll, l)
	vbAllMu.Unlock()
	return l
}

func (l *vbRE) get() *regexp.Regexp {
	l.once.Do(func() {
		l.re = regexp.MustCompile(l.src)
		l.re.Longest()
	})
	return l.re
}

func (l *vbRE) MatchString(s string) bool      { return l.get().MatchString(s) }
func (l *vbRE) FindStringIndex(s string) []int { return l.get().FindStringIndex(s) }
func (l *vbRE) FindAllStringIndex(s string) [][]int {
	return l.get().FindAllStringIndex(s, -1)
}
func (l *vbRE) FindAllString(s string) []string { return l.get().FindAllString(s, -1) }
func (l *vbRE) FindStringSubmatch(s string) []string {
	return l.get().FindStringSubmatch(s)
}

// spc is the body of a [[:space:]] bracket as glibc's iswspace sees it in a UTF-8 locale (the no-break spaces
// are not in it).
const spc = `\t\n\v\f\r \x{1680}\x{2000}-\x{2006}\x{2008}-\x{200A}\x{2028}\x{2029}\x{205F}\x{3000}`

// isSpace is [[:space:]].
func isSpace(r rune) bool {
	switch {
	case r >= 9 && r <= 13, r == ' ', r == 0x1680, r >= 0x2000 && r <= 0x2006, r >= 0x2008 && r <= 0x200A,
		r == 0x2028, r == 0x2029, r == 0x205F, r == 0x3000:
		return true
	}
	return false
}

func trimSpace(s string) string { return strings.TrimFunc(s, isSpace) }

// isWordRune is a GNU \w character (alnum or underscore) as the UTF-8 locale classifies it.
func isWordRune(r rune) bool { return r == '_' || unicode.IsLetter(r) || unicode.IsDigit(r) }

// wordBoundaryBefore reports GNU's `\b` at byte index i when the pattern continues with a word character: the
// previous character must not be a word character.
func wordBoundaryBefore(s string, i int) bool {
	if i == 0 {
		return true
	}
	r, _ := utf8.DecodeLastRuneInString(s[:i])
	return !isWordRune(r)
}

// findAllFiltered is `grep -o` with a start condition: matches are taken left to right and non-overlapping, and
// a leftmost-longest match whose start fails ok is skipped one character on (the regex engine of grep tries the
// next start, which is what a leading `\b` does).
func findAllFiltered(re *vbRE, s string, ok func(s string, i int) bool) []string {
	var out []string
	pos := 0
	for pos <= len(s) {
		loc := re.FindStringIndex(s[pos:])
		if loc == nil {
			break
		}
		start := pos + loc[0]
		if ok != nil && !ok(s, start) {
			_, w := utf8.DecodeRuneInString(s[start:])
			if w == 0 {
				break
			}
			pos = start + w
			continue
		}
		end := pos + loc[1]
		out = append(out, s[start:end])
		if end == start { // an empty match cannot advance; no pattern here is nullable
			pos = end + 1
			continue
		}
		pos = end
	}
	return out
}

// fileLines splits text the way grep and awk see a file: a trailing newline ends the last line, a final
// fragment without one is still a line, an empty file has none.
func fileLines(text string) []string {
	if text == "" {
		return nil
	}
	ls := strings.Split(text, "\n")
	if ls[len(ls)-1] == "" {
		ls = ls[:len(ls)-1]
	}
	return ls
}

// sortedUnique is `sort -u` under the code-point (C.UTF-8) collation.
func sortedUnique(ss []string) []string {
	if len(ss) == 0 {
		return nil
	}
	c := append([]string(nil), ss...)
	sort.Strings(c)
	out := c[:1]
	for _, s := range c[1:] {
		if s != out[len(out)-1] {
			out = append(out, s)
		}
	}
	return out
}

// dirnameSh is dirname(1): no cleaning, trailing slashes dropped.
func dirnameSh(p string) string {
	if p == "" {
		return "."
	}
	t := strings.TrimRight(p, "/")
	if t == "" {
		return "/"
	}
	i := strings.LastIndex(t, "/")
	if i < 0 {
		return "."
	}
	d := strings.TrimRight(t[:i], "/")
	if d == "" {
		return "/"
	}
	return d
}

// basenameSh is basename(1) without a suffix.
func basenameSh(p string) string {
	if p == "" {
		return ""
	}
	t := strings.TrimRight(p, "/")
	if t == "" {
		return "/"
	}
	if i := strings.LastIndex(t, "/"); i >= 0 {
		return t[i+1:]
	}
	return t
}

// cutBytes is `cut -cN-M` (GNU cut counts bytes): the first n bytes.
func cutBytes(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n]
}

// shellInt reads a decimal operand the way the `[` builtin does for -eq/-le/...: ok is false for an operand
// bash rejects ("integer expression expected"), which makes the test false.
func shellInt(s string) (int64, bool) {
	if s == "" {
		return 0, false
	}
	var n int64
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c < '0' || c > '9' {
			return 0, false
		}
		d := int64(c - '0')
		if n > (1<<63-1-d)/10 {
			return 0, false
		}
		n = n*10 + d
	}
	return n, true
}

// numLE is `[ a -le b ]`; numGT, numEQ likewise. A rejected operand makes the test false.
func numLE(a, b string) bool {
	x, ok1 := shellInt(a)
	y, ok2 := shellInt(b)
	return ok1 && ok2 && x <= y
}

func numGT(a, b string) bool {
	x, ok1 := shellInt(a)
	y, ok2 := shellInt(b)
	return ok1 && ok2 && x > y
}

func numEQ(a, b string) bool {
	x, ok1 := shellInt(a)
	y, ok2 := shellInt(b)
	return ok1 && ok2 && x == y
}

// vbCountLines is _vb_lines: awk's record count of r, stopping once end records were read (end 0 reads all). An
// unterminated last line counts. A read error is the counter failing: the caller types it DEGRADED.
func vbCountLines(r io.Reader, end int64) (int64, error) {
	buf := make([]byte, 64<<10)
	var nl int64
	last := byte('\n')
	for {
		m, err := r.Read(buf)
		for _, b := range buf[:m] {
			if b == '\n' {
				nl++
				if end > 0 && nl >= end {
					return nl, nil
				}
			}
		}
		if m > 0 {
			last = buf[m-1]
		}
		if err == io.EOF {
			if last != '\n' {
				nl++
			}
			return nl, nil
		}
		if err != nil {
			return 0, err
		}
	}
}
