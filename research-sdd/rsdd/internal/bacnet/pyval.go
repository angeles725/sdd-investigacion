package bacnet

import (
	"errors"
	"fmt"
	"math"
	"math/big"
	"os"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"unicode"
	"unicode/utf8"
)

// pyError is a Python exception the legacy tool could raise, carried with its class so the command can give
// each class the exit code the Python tool gave it.
type pyError struct {
	kind string // "OSError", "OverflowError" or "ValueError"
	msg  string
}

func (e *pyError) Error() string { return e.msg }

// pyRepr is Python's repr() of a str, which is how an OSError message names its file.
func pyRepr(s string) string {
	quote := byte('\'')
	if strings.ContainsRune(s, '\'') && !strings.ContainsRune(s, '"') {
		quote = '"'
	}
	var b strings.Builder
	b.WriteByte(quote)
	for i := 0; i < len(s); {
		r, w := utf8.DecodeRuneInString(s[i:])
		switch {
		case r == utf8.RuneError && w == 1:
			fmt.Fprintf(&b, "\\udc%02x", s[i]) // surrogateescape, as a Python str with an undecodable byte
		case r == rune(quote) || r == '\\':
			b.WriteByte('\\')
			b.WriteRune(r)
		case r == '\n':
			b.WriteString(`\n`)
		case r == '\r':
			b.WriteString(`\r`)
		case r == '\t':
			b.WriteString(`\t`)
		case r < 0x20 || r == 0x7f:
			fmt.Fprintf(&b, "\\x%02x", r)
		case !unicode.IsPrint(r):
			switch {
			case r < 0x100:
				fmt.Fprintf(&b, "\\x%02x", r)
			case r < 0x10000:
				fmt.Fprintf(&b, "\\u%04x", r)
			default:
				fmt.Fprintf(&b, "\\U%08x", r)
			}
		default:
			b.WriteRune(r)
		}
		i += w
	}
	b.WriteByte(quote)
	return b.String()
}

// errnoOf returns the errno inside err, if any.
func errnoOf(err error) (syscall.Errno, bool) {
	var en syscall.Errno
	if errors.As(err, &en) {
		return en, true
	}
	return 0, false
}

// strerror is C's strerror text as Python's OSError.strerror shows it: Go's message with an upper-case first
// letter (the Linux strings are glibc's, lower-cased).
func strerror(en syscall.Errno) string {
	m := en.Error()
	if m == "" {
		return m
	}
	r, w := utf8.DecodeRuneInString(m)
	return string(unicode.ToUpper(r)) + m[w:]
}

// osErrorText is str(OSError(errno, strerror[, filename])): "[Errno N] text", with ": 'filename'" when named.
func osErrorText(err error, filename string) string {
	en, ok := errnoOf(err)
	if !ok {
		return err.Error()
	}
	if filename == "" {
		return fmt.Sprintf("[Errno %d] %s", int(en), strerror(en))
	}
	return fmt.Sprintf("[Errno %d] %s: %s", int(en), strerror(en), pyRepr(filename))
}

var (
	pyIntRe   = regexp.MustCompile(`^[+-]?[0-9](?:_?[0-9])*$`)
	pyFloatRe = regexp.MustCompile(`^[+-]?(?:(?:[0-9](?:_?[0-9])*)(?:\.(?:[0-9](?:_?[0-9])*)?)?|\.[0-9](?:_?[0-9])*)(?:[eE][+-]?[0-9](?:_?[0-9])*)?$`)
	pySpecial = regexp.MustCompile(`^[+-]?(?:inf|infinity|nan)$`)
)

// parsePyInt reads what Python's int(str) reads in base 10: surrounding whitespace, a sign, digits with single
// underscores between them (ASCII digits only), any magnitude.
func parsePyInt(s string) (*big.Int, bool) {
	t := strings.TrimSpace(s)
	if !pyIntRe.MatchString(t) {
		return nil, false
	}
	n, ok := new(big.Int).SetString(strings.ReplaceAll(t, "_", ""), 10)
	return n, ok
}

// parsePyFloat reads what Python's float(str) reads: whitespace, a sign, decimal digits with underscores, a
// fraction, an exponent, inf, infinity and nan in any case. A magnitude beyond float64 is an infinity.
func parsePyFloat(s string) (float64, bool) {
	t := strings.TrimSpace(s)
	lower := strings.ToLower(t)
	switch {
	case pySpecial.MatchString(lower):
		switch strings.TrimLeft(lower, "+-") {
		case "nan":
			return math.NaN(), true
		}
		if strings.HasPrefix(lower, "-") {
			return math.Inf(-1), true
		}
		return math.Inf(1), true
	case pyFloatRe.MatchString(t):
		f, err := strconv.ParseFloat(strings.ReplaceAll(t, "_", ""), 64)
		if err != nil && !errors.Is(err, strconv.ErrRange) {
			return 0, false
		}
		return f, true
	}
	return 0, false
}

// pySplit is os.path.split for a POSIX path: the head loses its trailing slashes unless it is all slashes.
func pySplit(p string) (head, tail string) {
	i := strings.LastIndex(p, "/") + 1
	head, tail = p[:i], p[i:]
	if head != "" && strings.Trim(head, "/") != "" {
		head = strings.TrimRight(head, "/")
	}
	return head, tail
}

// pyJoin is os.path.join(dir, name) for a relative name.
func pyJoin(dir, name string) string {
	switch {
	case dir == "":
		return name
	case strings.HasSuffix(dir, "/"):
		return dir + name
	}
	return dir + "/" + name
}

// pyMakedirs is os.makedirs(name, exist_ok=True). abs maps a name to the path the system call uses, so the
// errors keep the name the caller wrote.
func pyMakedirs(name string, abs func(string) string) *pyError {
	head, tail := pySplit(name)
	if tail == "" {
		head, tail = pySplit(head)
	}
	if head != "" && tail != "" {
		if _, err := os.Stat(abs(head)); err != nil {
			if e := pyMakedirs(head, abs); e != nil && !strings.HasPrefix(e.msg, "[Errno 17]") {
				return e
			}
		}
	}
	if tail == "." {
		return nil
	}
	if name == "" { // mkdir('') is ENOENT; the injected working directory must not make it succeed
		return &pyError{kind: "OSError", msg: "[Errno 2] No such file or directory: ''"}
	}
	if err := os.Mkdir(abs(name), 0o777); err != nil {
		if st, serr := os.Stat(abs(name)); serr == nil && st.IsDir() {
			return nil
		}
		return &pyError{kind: "OSError", msg: osErrorText(err, name)}
	}
	return nil
}
