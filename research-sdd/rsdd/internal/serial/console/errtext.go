package console

import (
	"errors"
	"syscall"
	"unicode"
	"unicode/utf8"
)

// errnoOf returns the errno inside err, if any.
func errnoOf(err error) (syscall.Errno, bool) {
	var en syscall.Errno
	if errors.As(err, &en) {
		return en, true
	}
	return 0, false
}

// strerror is C's strerror text, as mkdir(1) and tee(1) print it: Go's message for the errno with an upper-case
// first letter (the Linux strings are glibc's, lower-cased). The serial package keeps the same two lines for its
// Python-compatible texts; it cannot be imported from here (it imports this package) and no core package owns
// them yet.
func strerror(en syscall.Errno) string {
	m := en.Error()
	if m == "" {
		return m
	}
	r, w := utf8.DecodeRuneInString(m)
	return string(unicode.ToUpper(r)) + m[w:]
}
