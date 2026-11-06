package cleancheck

import (
	"os"
	"strconv"
	"strings"
	"testing"
)

// A relative Cwd would be resolved against the process working directory by kitmaint.Abs: the same typed refusal as
// an empty one, one case per shape.
func TestRelativeCwdIsATypedRefusal(t *testing.T) {
	for _, cwd := range []string{".", "corpus"} {
		t.Run(cwd, func(t *testing.T) {
			w := newWorld(t)
			r := w.check(func(o *Options) { o.Cwd = cwd })
			if r.Exit != 2 || r.Verdict != Refused || r.Summary != "" || !strings.Contains(r.Stderr(), "Options.Cwd must be an absolute path") {
				t.Errorf("%s", w.dump(r))
			}
		})
	}
}

// withEnv appends KEY=VALUE pairs to the world's environment (the last value of a name wins).
func withEnv(kv ...string) func(*Options) {
	return func(o *Options) { o.Env = append(append([]string(nil), o.Env...), kv...) }
}

// The scratchpad and the owner uid come from Options.Env when the explicit field is empty, so an in-process caller
// that passes only {Target, Env, Cwd, Now} sees the same lines the command prints.
func TestEnvironmentFeedsTheScratchpad(t *testing.T) {
	w := newWorld(t)
	keep(w, "")
	w.writeAt(w.scratch+"/x.sh", "x")
	r := w.check(withEnv("CLEAN_CHECK_SCRATCHPAD=" + w.scratch))
	if r.Exit != 1 || !has(r, "UNMANIFESTED-SCRIPT "+w.scratch+"/x.sh") {
		t.Errorf("the environment scratchpad was not read:\n%s", w.dump(r))
	}
	other := w.root + "/other"
	w.mkdir(other)
	r = w.check(withEnv("CLEAN_CHECK_SCRATCHPAD="+w.scratch), func(o *Options) { o.Scratchpad = other })
	if r.Exit != 0 || !strings.Contains(r.Summary, "scratchpad: 0 file(s)") {
		t.Errorf("the field must win over the environment:\n%s", w.dump(r))
	}
	r = w.check(withEnv("CLEAN_CHECK_SCRATCHPAD="))
	if !strings.Contains(r.Summary, "scratchpad: not set") {
		t.Errorf("an empty variable is not configured:\n%s", w.dump(r))
	}
}

func TestEnvironmentFeedsTheOwnerUID(t *testing.T) {
	w := newWorld(t)
	keep(w, "")
	w.mkdir(w.tmp + "/tmp.old")
	w.ago(48, w.tmp+"/tmp.old")
	me := strconv.Itoa(os.Getuid())
	stale := "GARBAGE stale-tmp " + w.tmp + "/tmp.old age=48h"
	if r := w.check(withEnv("CLEAN_CHECK_UID=" + me)); !has(r, stale) {
		t.Errorf("the owner uid of the environment is the current user:\n%s", w.dump(r))
	}
	if r := w.check(withEnv("CLEAN_CHECK_UID=" + strconv.Itoa(os.Getuid()+1))); has(r, stale) || r.Exit != 0 {
		t.Errorf("another owner's uid must hide the entry:\n%s", w.dump(r))
	}
	if r := w.check(withEnv("CLEAN_CHECK_UID=x")); r.Exit != 2 || !strings.Contains(r.Stderr(), "cannot determine the owner uid ('x')") {
		t.Errorf("a bad uid in the environment is a refusal:\n%s", w.dump(r))
	}
	if r := w.check(withEnv("CLEAN_CHECK_UID=x"), func(o *Options) { o.UID = me }); !has(r, stale) {
		t.Errorf("the field must win over the environment:\n%s", w.dump(r))
	}
}
