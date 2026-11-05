package kitmaint

import (
	"bytes"
	"strings"
	"testing"
	"time"
)

type clock struct{ slept []time.Duration }

func (c *clock) sleep(d time.Duration) { c.slept = append(c.slept, d) }

func testRunner(env []string, cwd string, errBuf *bytes.Buffer, c *clock, getenv map[string]string) *Runner {
	return &Runner{Env: env, Cwd: cwd, Err: errBuf, Sleep: c.sleep, Getenv: func(k string) string { return getenv[k] }}
}

func TestRetrySemantics(t *testing.T) {
	var eb bytes.Buffer
	c := &clock{}
	r := testRunner(nil, "/", &eb, c, map[string]string{"KIT_RETRY_SLEEP": "2"})
	n := 0
	res := r.Retry("kit-x", 3, "cmd a b", false, func() Res {
		n++
		return Res{Out: "o" + string(rune('0'+n)), Err: "e" + string(rune('0'+n)) + "\n", RC: 7}
	})
	if n != 3 || res.RC != 7 || res.Out != "o1o2o3" || res.Err != "e3\n" {
		t.Errorf("attempts=%d res=%+v", n, res)
	}
	if want := "e1\nkit-x: retry 1/3 after rc=7: cmd a b\ne2\nkit-x: retry 2/3 after rc=7: cmd a b\ne3\n"; eb.String() != want {
		t.Errorf("stderr = %q, want %q", eb.String(), want)
	}
	if len(c.slept) != 2 || c.slept[0] != 2*time.Second || c.slept[1] != 4*time.Second {
		t.Errorf("backoff = %v: attempt n sleeps KIT_RETRY_SLEEP x n", c.slept)
	}
}

func TestRetryQuietAndSuccess(t *testing.T) {
	var eb bytes.Buffer
	c := &clock{}
	r := testRunner(nil, "/", &eb, c, nil)
	n := 0
	res := r.Retry("t", 3, "w", true, func() Res {
		n++
		if n == 2 {
			return Res{Out: "ok", RC: 0}
		}
		return Res{Err: "boom\n", RC: 1}
	})
	if n != 2 || !res.OK() || res.Out != "ok" || eb.Len() != 0 {
		t.Errorf("n=%d res=%+v stderr=%q: quiet drops notes and child stderr, success stops", n, res, eb.String())
	}
	if len(c.slept) != 1 || c.slept[0] != 5*time.Second {
		t.Errorf("default KIT_RETRY_SLEEP is 5 s: %v", c.slept)
	}
	// a non-numeric KIT_RETRY_SLEEP is no sleep at all, as in $(( x * n ))
	c2 := &clock{}
	r2 := testRunner(nil, "/", &eb, c2, map[string]string{"KIT_RETRY_SLEEP": "abc"})
	r2.Retry("t", 2, "w", true, func() Res { return Res{RC: 1} })
	if len(c2.slept) != 1 || c2.slept[0] != 0 {
		t.Errorf("bad knob: %v", c2.slept)
	}
	// a single try never sleeps or notes
	one := 0
	if r.Retry("t", 1, "w", false, func() Res { one++; return Res{RC: 1} }).RC != 1 || one != 1 || len(c.slept) != 1 {
		t.Error("tries=1")
	}
}

func TestRunnerGitAndGh(t *testing.T) {
	dir := scratch(t)
	bin := scratch(t)
	script(t, bin, "gh", `echo "gh $* in $PWD"; echo warn >&2; exit 4`)
	polled := 0
	var eb bytes.Buffer
	c := &clock{}
	r := testRunner([]string{"PATH=" + bin + ":/usr/bin:/bin"}, dir, &eb, c, nil)
	r.Poll = func() { polled++ }

	g := r.Gh(dir, "pr", "checks", "7")
	if g.RC != 4 || g.Out != "gh pr checks 7 in "+dir+"\n" || g.Err != "warn\n" || polled != 1 {
		t.Errorf("gh: %+v polled=%d", g, polled)
	}
	if res := r.Git("", "--version"); !res.OK() || !strings.HasPrefix(res.Out, "git version") || polled != 2 {
		t.Errorf("git --version: %+v polled=%d", res, polled)
	}
	res := r.Git(dir, "rev-parse", "--git-dir")
	if res.RC == 0 || res.RC == 127 || res.Err == "" {
		t.Errorf("git outside a repo must exit non-zero with stderr: %+v", res)
	}
	res = r.Git("relative-missing", "status")
	if res.RC == 0 {
		t.Errorf("a missing dir must fail: %+v", res)
	}
	none := testRunner([]string{"PATH=" + dir}, dir, &eb, c, nil)
	if res := none.Gh(dir, "x"); res.RC != 127 {
		t.Errorf("gh not found must be rc 127: %+v", res)
	}
	if res := none.Git("", "status"); res.RC != 127 {
		t.Errorf("git not found must be rc 127: %+v", res)
	}
}

func TestMissingDepsAndProbe(t *testing.T) {
	bin := scratch(t)
	script(t, bin, "present", ":")
	env := []string{"PATH=" + bin}
	if m := MissingDeps(env, bin, "present"); len(m) != 0 {
		t.Errorf("present reported missing: %v", m)
	}
	if m := MissingDeps(env, bin, "gone", "present", "also-gone"); strings.Join(m, ",") != "gone,also-gone" {
		t.Errorf("missing = %v, want the absent ones in order", m)
	}
	var out, errb bytes.Buffer
	if !ProbeDeps(&out, &errb, "kit-x", env, bin, "present") || out.Len() != 0 || errb.Len() != 0 {
		t.Errorf("complete and silent expected: %q %q", out.String(), errb.String())
	}
	if ProbeDeps(&out, &errb, "kit-x", env, bin, "a-gone", "present", "b-gone") {
		t.Error("a missing dependency must return false")
	}
	if out.String() != "kit-x: degraded: missing runtime dependency: a-gone b-gone\n" || errb.String() != "DEGRADED: missing runtime dependency: a-gone b-gone\n" {
		t.Errorf("stdout %q stderr %q", out.String(), errb.String())
	}
}
