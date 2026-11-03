package java

import (
	"io"
	"strings"
	"testing"
)

func TestArgumentErrorsAreUsageErrors(t *testing.T) {
	h := newHarness(t)
	full := h.args("--output", h.out("o"))
	cases := []struct {
		name string
		args []string
		want string
	}{
		{"no arguments", nil, "the following arguments are required: --decompile-wrapper, --input, --output"},
		{"missing output", h.args(), "the following arguments are required: --output"},
		{"unknown option", append(append([]string{}, full...), "--bogus"), "flag provided but not defined: -bogus"},
		{"stray positional", append(append([]string{}, full...), "classfile-facts", "x.jar"), "unrecognized arguments: classfile-facts x.jar"},
		{"zero timeout", h.args("--output", "o", "--timeout-seconds", "0"), "argument --timeout-seconds: must be positive"},
		{"negative max-files", h.args("--output", "o", "--max-files", "-3"), "argument --max-files: must be positive"},
		{"non-numeric max-bytes", h.args("--output", "o", "--max-bytes", "lots"), "argument --max-bytes: invalid positive value: 'lots'"},
		{"max-classes zero", h.args("--output", "o", "--max-classes", "0"), "argument --max-classes: must be positive"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			r := h.run(c.args...)
			if r.rc != 2 || !strings.Contains(r.err, c.want) || !strings.HasPrefix(r.err, "usage: corroborate-java") {
				t.Fatalf("rc=%d stderr=%q, want rc 2, usage and %q", r.rc, r.err, c.want)
			}
			if r.stdout != "" {
				t.Errorf("stdout = %q", r.stdout)
			}
		})
	}
}

func TestMaxHeapMustLookLikeASize(t *testing.T) {
	h := newHarness(t)
	for _, bad := range []string{"", "0m", "1024", "12k", "1234567m", "m", "1.5g", "-1g", "1 g"} {
		r := h.run(h.args("--output", h.out("o"), "--max-heap", bad)...)
		if r.rc != 2 || !strings.Contains(r.err, "--max-heap must look like 1024m or 2g") {
			t.Errorf("--max-heap %q: rc=%d stderr=%q", bad, r.rc, r.err)
		}
	}
	for _, good := range []string{"1m", "128M", "2g", "999999G"} {
		if !validHeap(good) {
			t.Errorf("%q must be accepted", good)
		}
	}
}

func TestHelpPrintsUsageAndExitsZero(t *testing.T) {
	h := newHarness(t)
	r := h.run("--help")
	if r.rc != 0 || !strings.HasPrefix(r.stdout, "usage: corroborate-java") || r.err != "" {
		t.Fatalf("rc=%d stdout=%q stderr=%q", r.rc, r.stdout, r.err)
	}
}

func TestPositiveSaturatesInsteadOfFailing(t *testing.T) {
	v, err := positive("99999999999999999999")
	if err != nil || v != 1<<63-1 {
		t.Fatalf("positive(huge) = %d, %v", v, err)
	}
	if v, err := positive(" 7 "); err != nil || v != 7 {
		t.Fatalf("positive(' 7 ') = %d, %v", v, err)
	}
}

func TestDefaultsApplyWhenOptionsAreOmitted(t *testing.T) {
	h := newHarness(t)

	e := newEnv(h.stdio(io.Discard, io.Discard))
	o, rc := e.parse([]string{"--decompile-wrapper", "w", "--manifest-module", "m", "--input", "i", "--output", "o"})
	if rc != -1 {
		t.Fatalf("rc = %d", rc)
	}
	if o.timeoutSeconds != 120 || o.maxHeap != "1024m" || o.maxFiles != 20_000 || o.maxBytes != 1_073_741_824 || o.maxClasses != 10_000 || o.overwrite {
		t.Fatalf("defaults = %+v", o)
	}
}
