package formats

import (
	"syscall"
	"testing"
)

func TestPyRepr(t *testing.T) {
	for in, want := range map[string]string{
		`/tmp/a b`:       `'/tmp/a b'`,
		`it's`:           `"it's"`,
		`say "hi" it's`:  `'say "hi" it\'s'`,
		"tab\there":      `'tab\there'`,
		"nl\n":           `'nl\n'`,
		`back\slash`:     `'back\\slash'`,
		"\x01":           `'\x01'`,
		"café":           "'café'",
		"\x80":           `'\udc80'`,
		"zero\u200bwith": "'zero\\u200bwith'",
	} {
		if got := pyRepr(in); got != want {
			t.Errorf("pyRepr(%q) = %s, want %s", in, got, want)
		}
	}
}

func TestOSErrorText(t *testing.T) {
	if got, want := osErrorText(syscall.EEXIST, "/x"), "[Errno 17] File exists: '/x'"; got != want {
		t.Errorf("got %q, want %q", got, want)
	}
	if got, want := osErrorText(syscall.EINVAL, ""), "[Errno 22] Invalid argument"; got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestPyPathJoin(t *testing.T) {
	for _, c := range []struct{ cwd, p, want string }{
		{"/work", "a/b", "/work/a/b"},
		{"/work/", "a", "/work/a"},
		{"/work", "/abs", "/abs"},
		{"/work", "a/../b", "/work/a/../b"},
		{"", "rel", "rel"},
	} {
		if got := pyPathJoin(c.cwd, c.p); got != c.want {
			t.Errorf("pyPathJoin(%q, %q) = %q, want %q", c.cwd, c.p, got, c.want)
		}
	}
}
