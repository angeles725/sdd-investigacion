package helpers

import (
	"bytes"
	"errors"
	"reflect"
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/adapter"
)

func TestRunTruncationLiteral(t *testing.T) {
	flag, lims := RunTruncation([]string{"analyzer-exit:1", "timeout"}, "floss")
	want := []string{"floss run truncated: timeout reached — inventory is incomplete"}
	if !flag || !reflect.DeepEqual(lims, want) {
		t.Fatalf("got %v %q, want true %q", flag, lims, want)
	}
	flag, lims = RunTruncation([]string{"process-cap", "output-cap", "timeout", "timeout"}, "x")
	if !flag || len(lims) != 3 || !strings.Contains(lims[0], "output-cap") || !strings.Contains(lims[1], "process-cap") || !strings.Contains(lims[2], "timeout") {
		t.Fatalf("not sorted per cap: %v %q", flag, lims)
	}
}

func TestRunTruncationNoCapIsNotTruncated(t *testing.T) {
	for _, in := range [][]string{nil, {}, {"analyzer-exit:2"}, {"Timeout"}, {"timeout "}} {
		flag, lims := RunTruncation(in, "t")
		if flag || lims == nil || len(lims) != 0 {
			t.Errorf("RunTruncation(%q) = %v %#v, want false and a non-nil empty slice", in, flag, lims)
		}
	}
}

func TestWarnEvidenceFormat(t *testing.T) {
	var b bytes.Buffer
	WarnEvidence(&b, "s.v1", "/d", "")
	WarnEvidence(&b, "s.v1", "/d", "analyzer-exit:1")
	want := "s.v1: completed with issues — see /d/s.v1.json\n" +
		"s.v1: completed with issues (analyzer-exit:1) — see /d/s.v1.json\n"
	if b.String() != want {
		t.Fatalf("got %q, want %q", b.String(), want)
	}
	WarnEvidence(nil, "s", "d", "") // a nil writer discards, it does not panic
}

func TestPcapMagicConstants(t *testing.T) {
	want := [][]byte{{0xd4, 0xc3, 0xb2, 0xa1}, {0xa1, 0xb2, 0xc3, 0xd4}, {0x4d, 0x3c, 0xb2, 0xa1}, {0xa1, 0xb2, 0x3c, 0x4d}}
	if !reflect.DeepEqual(PcapMagic, want) {
		t.Errorf("PcapMagic = %x", PcapMagic)
	}
	if !bytes.Equal(PcapngMagic, []byte{0x0a, 0x0d, 0x0d, 0x0a}) {
		t.Errorf("PcapngMagic = %x", PcapngMagic)
	}
}

func TestErrorIsAnAdapterError(t *testing.T) {
	cause := errors.New("boom")
	e := newErr(KindVenvBind, "msg", cause)
	var ae *adapter.Error
	if !errors.As(e, &ae) || ae.Msg != "msg" || ae.Err != cause {
		t.Fatalf("errors.As(*adapter.Error) failed: %+v", ae)
	}
	var he *Error
	if !errors.As(e, &he) || he.Kind != KindVenvBind || he.Error() != "msg" {
		t.Fatalf("errors.As(*Error) = %+v", he)
	}
	if !errors.Is(e, cause) {
		t.Fatal("the cause is not reachable through errors.Is")
	}
	var other *int
	if e.As(&other) {
		t.Fatal("As matched a foreign target type")
	}
}

func TestSafeSchemaLiteral(t *testing.T) {
	for s, want := range map[string]bool{"a": true, "a.b_c-d": true, "9x": true, "a\n": true, "": false, ".a": false, "a b": false, "a\n\n": false, "\na": false, "a/b": false} {
		if safeSchema(s) != want {
			t.Errorf("safeSchema(%q) = %v, want %v", s, !want, want)
		}
	}
}

func TestPyHelpersLiteral(t *testing.T) {
	for in, want := range map[string]string{"": ".", "a//b/./c/": "a/b/c", "//a": "//a", "///a": "/a", "/": "/", "..": "..", "a/../b": "a/../b"} {
		if got := pyNorm(in); got != want {
			t.Errorf("pyNorm(%q) = %q, want %q", in, got, want)
		}
	}
	for in, want := range map[string]string{"": ".", "//x": "//x", "///x": "/x", "/a/../..": "/", "a/../..": "..", "/tmp/rsdd//s": "/tmp/rsdd/s", "/tmp/rsdd/../e": "/tmp/e", "a/": "a"} {
		if got := pyNormpath(in); got != want {
			t.Errorf("pyNormpath(%q) = %q, want %q", in, got, want)
		}
	}
	for in, want := range map[string]string{"it's": `"it's"`, `a'b"c`: `'a\'b"c'`, "a\tb\n": `'a\tb\n'`, "\x00\x7f": `'\x00\x7f'`, "\u200b": `'\u200b'`, "\U0001F600": "'\U0001F600'", "\U000e0001": `'\U000e0001'`, "é": "'é'", `\`: `'\\'`} {
		if got := pyRepr(in); got != want {
			t.Errorf("pyRepr(%q) = %s, want %s", in, got, want)
		}
	}
	if got := pyParts("//a/./b"); !reflect.DeepEqual(got, []string{"//", "a", "b"}) {
		t.Errorf("pyParts = %q", got)
	}
	if got := pyParts(""); len(got) != 0 {
		t.Errorf("pyParts(\"\") = %q", got)
	}
}

func TestAssertSafeBindRootMessages(t *testing.T) {
	e := Env{Cwd: "/", Home: "/nonexistent/h/ome"}
	for path, want := range map[string]string{
		"/":                  `path is a blocked system root: '/'`,
		"/usr":               `path is a blocked system root: '/usr'`,
		"/home":              `path is a blocked system root: '/home'`,
		"/home/u":            `path too broad to bind safely (require /home/<user>/<subdir> or deeper, got 3 parts): '/home/u'`,
		"/a":                 `path too shallow to bind safely (2 parts, need ≥3): '/a'`,
		"":                   `path too shallow to bind safely (0 parts, need ≥3): '.'`,
		"/nonexistent/h/ome": `path resolves to the real home directory: '/nonexistent/h/ome'`,
	} {
		err := AssertSafeBindRoot(e, path)
		var he *Error
		if !errors.As(err, &he) || he.Kind != KindBindScope || he.Error() != want {
			t.Errorf("%s: %v, want BindScopeError %q", path, err, want)
		}
	}
	for _, ok := range []string{"/home/u/x", "/a/b", "/a/b/c", "/root/v", "/opt/x/y/z"} {
		if err := AssertSafeBindRoot(e, ok); err != nil {
			t.Errorf("%s: %v", ok, err)
		}
	}
}
