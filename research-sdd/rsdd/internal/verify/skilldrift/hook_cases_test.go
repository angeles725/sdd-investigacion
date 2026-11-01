package skilldrift

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// The case table of `verify skill-drift-hook`, run like the drift table: the frozen hook (beside a frozen or stubbed drift
// script and an install --verify stub), the Go hook, and the golden recorded from the frozen hook. `legacy` names the cases of
// tests/verify-skill-drift-hook.test.sh and tests/verify-skill-drift.test.sh the row replaces.
//
//	kit "stub"  the drift half is a stub (STUB_DRIFT_RC / STUB_DRIFT_OUT), as in the hook suite
//	kit "real"  the drift half is the real script (or, on the Go side, the real command) against a home built by `home`
//	kdir        turns the kit-staleness check ON against that fixture (a directory under @FIX@, which is also HOME)

type hcase struct {
	name     string
	legacy   string
	kit      string
	kdir     string
	home     func(t testing.TB, w *world)
	env      []string
	has      []string
	not      []string
	silent   bool
	max      int  // upper bound of the decoded context, in characters (0 = none)
	oracle   bool // false: not run against the frozen hook (timing-heavy, or it would leave a background process behind)
	diverg   bool // an intended divergence (intended.go): expectations only
	need     string
	limitSec int // upper bound of the Go run's wall time in seconds (0 = none)
}

func E(kv ...string) []string { return kv }

func long(n int) string { return strings.Repeat("0", n) }

var (
	longDeg = "verify harness=claude status=degraded reason=" + long(300)
	manyDeg = strings.TrimSuffix(strings.Repeat(longDeg+"\n", 8), "\n")
	annot   = "verify harness=gentle-shell status=drift drifted=research-sdd/profile/general/BREAKTHROUGHS.md (extra: kit file written into the rendered profile — reconcile them into /home/u/code/research-sdd-kit/research-sdd/BREAKTHROUGHS.md by hand),research-sdd/profile/general/TARGETS.md (extra: registry edits written into the rendered profile — reconcile them into /home/u/code/research-sdd-kit/research-sdd/TARGETS.md by hand)"
	caps    = func() string {
		pad := long(360)
		var e1, e2 []string
		for i := 1; i <= 8; i++ {
			e1 = append(e1, fmt.Sprintf("research-sdd/profile/general/a%d-%s.md (extra)", i, pad))
			e2 = append(e2, fmt.Sprintf("research-sdd/profile/general/b%d-%s.md (extra)", i, pad))
		}
		e2 = append(e2, "research-sdd/profile/general/TARGETS.md (extra: registry edits written into the rendered profile — reconcile them into /k/TARGETS.md by hand)")
		return "verify harness=pi status=drift drifted=" + strings.Join(e1, ",") + "\n" +
			"verify harness=gentle-shell status=drift drifted=" + strings.Join(e2, ",") + " kept-hand-edit=research-sdd/profile/general/k1.md,research-sdd/profile/general/k2.md"
	}()
)

func stubEnv(verifyOut string, more ...string) []string {
	return append([]string{"STUB_VERIFY_OUT=" + verifyOut}, more...)
}

var hookCases = []hcase{
	// ---- install --verify findings (stub drift half) ------------------------------------------------------------------------
	{name: "all-clear", legacy: "H1", kit: "stub", env: stubEnv(matchOut), silent: true, oracle: true},
	{name: "behind-surfaced", legacy: "H2 H3 H3b", kit: "stub", env: stubEnv(matchOut + "\n" + behindOut), has: []string{"WARN", "status=behind", "behind=47"},
		not: []string{"status=match", "status=absent", "status=current"}, oracle: true},
	{name: "kit-degraded-silent", legacy: "H4", kit: "stub", env: stubEnv("verify kit status=degraded reason=git not found; cannot tell whether the kit checkout is behind its upstream"), silent: true, oracle: true},
	{name: "harness-degraded", legacy: "H4b", kit: "stub", env: stubEnv("verify harness=pi status=degraded reason=installed files present but no bundle record", "STUB_VERIFY_RC=2"),
		has: []string{"harness=pi status=degraded"}, oracle: true},
	{name: "verify-hung-timeout", legacy: "H4c", kit: "stub", env: E("STUB_VERIFY_SLEEP=5", "RESEARCH_SDD_INSTALL_VERIFY_TIMEOUT=1"), has: []string{"timed out"}, oracle: true},
	{name: "verify-hung-no-timeout-bin", legacy: "H4c2", kit: "stub", env: E("STUB_VERIFY_SLEEP=5", "RESEARCH_SDD_INSTALL_VERIFY_TIMEOUT=1", "RESEARCH_SDD_NO_TIMEOUT_BIN=1"), has: []string{"timed out"}, oracle: true},
	{name: "verify-fast-no-timeout-bin", legacy: "H4c3 H4h", kit: "stub", env: stubEnv(behindOut, "RESEARCH_SDD_NO_TIMEOUT_BIN=1", "extra_skip=1"), has: []string{"status=behind"}, not: []string{"skipped"}, oracle: true},
	{name: "grandchild-holds-stdout", legacy: "H4e", kit: "stub", env: E("STUB_VERIFY_SLEEP=30", "STUB_VERIFY_GRANDCHILD=20", "RESEARCH_SDD_INSTALL_VERIFY_TIMEOUT=1"), has: []string{"timed out"}, limitSec: 10},
	{name: "real-exit-137", legacy: "H4f", kit: "stub", env: E("STUB_VERIFY_RC=137", "RESEARCH_SDD_INSTALL_VERIFY_TIMEOUT=1"), has: []string{"exited 137 with no typed line"}, not: []string{"timed out"}, oracle: true},
	{name: "mktemp-fails-findings-kept", legacy: "H4i", kit: "stub", env: stubEnv(behindOut, "TMPDIR=@ROOT@/no-such-tmp"), has: []string{"status=behind", "not bounded"}, not: []string{"skipped"}, oracle: true},
	{name: "mktemp-fails-hung-bounded", legacy: "H4i2", kit: "stub", env: E("STUB_VERIFY_SLEEP=5", "RESEARCH_SDD_INSTALL_VERIFY_TIMEOUT=1", "TMPDIR=@ROOT@/no-such-tmp"), has: []string{"timed out"}, oracle: true},
	{name: "no-timeout-no-mktemp", legacy: "H4d", kit: "stub", diverg: true, env: E("STUB_VERIFY_SLEEP=1", "RESEARCH_SDD_NO_TIMEOUT_BIN=1", "TMPDIR=@ROOT@/no-such-tmp"), not: []string{"skipped"}},
	{name: "drift-line", legacy: "H5", kit: "stub", env: stubEnv("verify harness=claude status=drift drifted=skills/research-sdd/SKILL.md (modified)", "STUB_VERIFY_RC=1"),
		has: []string{"verify harness=claude status=drift\\n  - skills/research-sdd/SKILL.md (modified)"}, oracle: true},
	{name: "exit-no-typed-line", legacy: "H6", kit: "stub", env: E("STUB_VERIFY_RC=2"), has: []string{"exited 2 with no typed line"}, oracle: true},
	{name: "install-unrunnable", legacy: "H7", kit: "stub", env: stubEnv(matchOut, "RESEARCH_SDD_INSTALL_VERIFY_CMD=@TB@/does-not-exist.sh"), has: []string{"could not run (not executable: does-not-exist.sh)"}, oracle: true},
	{name: "capped-lines", legacy: "H8 H9", kit: "stub", env: stubEnv(manyDeg, "STUB_VERIFY_RC=2"), has: []string{"status=degraded"}, max: 1199, oracle: true},
	{name: "drift-and-behind", legacy: "H10", kit: "stub", env: stubEnv(behindOut, "STUB_DRIFT_RC=1", "STUB_DRIFT_OUT=verify-skill-drift: diverged harness=claude"),
		has: []string{"diverged harness=claude", "status=behind", "SKILL.md stale"}, oracle: true},
	{name: "drift-could-not-run", legacy: "AX7", kit: "stub", env: E("STUB_DRIFT_RC=2", "STUB_DRIFT_OUT=verify-skill-drift: could-not-run"), has: []string{"ERROR: verify-skill-drift.sh could not run"}, not: []string{"WARN"}, oracle: true},
	{name: "drift-rc-other", legacy: "AX7", kit: "stub", env: E("STUB_DRIFT_RC=5"), has: []string{"ERROR: verify-skill-drift.sh could not run"}, oracle: true},
	{name: "annotated-drift", legacy: "H11 H12", kit: "stub", env: stubEnv(annot, "STUB_VERIFY_RC=1"),
		has: []string{"research-sdd-kit/research-sdd/BREAKTHROUGHS.md by hand", "research-sdd-kit/research-sdd/TARGETS.md by hand"}, max: 1199, oracle: true},
	{name: "drift-caps", legacy: "H13 H14", kit: "stub", env: stubEnv(caps, "STUB_VERIFY_RC=1"), has: []string{"TARGETS.md (extra: registry edits", "(+"}, not: []string{"  - research-sdd/profile/general/k2.md"}, max: 3599, oracle: true},
	{name: "drift-no-drifted-field", legacy: "H13", kit: "stub", env: stubEnv("verify harness=pi status=drift extra "+long(300)+"\nverify harness=gentle-shell status=drift drifted=", "STUB_VERIFY_RC=1"), oracle: true},
	{name: "drift-kept-only", legacy: "H13", kit: "stub", env: stubEnv("verify harness=pi status=drift drifted=a.md,b.md kept-hand-edit=x.md"), has: []string{"  kept-hand-edit: x.md"}, oracle: true},
	{name: "drift-empty-entries", legacy: "H13", kit: "stub", env: stubEnv("verify harness=pi status=drift drifted=,a.md,,b.md,c.md,d.md"), oracle: true},
	{name: "drift-order-annotated-first", legacy: "H13 TOOTH L", kit: "stub", env: stubEnv("verify harness=pi status=drift drifted=p1.md,p2.md,p3.md,p4.md,z.md (extra: reconcile)"), has: []string{"z.md (extra: reconcile)"}, not: []string{"p3.md"}, oracle: true},
	// ---- timeout validation --------------------------------------------------------------------------------------------------
	{name: "timeout-invalid-empty", legacy: "H4l", kit: "stub", env: stubEnv(behindOut, "RESEARCH_SDD_INSTALL_VERIFY_TIMEOUT="), has: []string{"verify: invalid RESEARCH_SDD_INSTALL_VERIFY_TIMEOUT (empty), using 10s", "status=behind"}, oracle: true},
	{name: "timeout-invalid-fraction", legacy: "H4l", kit: "stub", env: stubEnv(behindOut, "RESEARCH_SDD_INSTALL_VERIFY_TIMEOUT=.5"), has: []string{"invalid RESEARCH_SDD_INSTALL_VERIFY_TIMEOUT='.5', using 10s", "status=behind"}, oracle: true},
	{name: "timeout-invalid-unit", legacy: "H4l", kit: "stub", env: stubEnv(behindOut, "RESEARCH_SDD_INSTALL_VERIFY_TIMEOUT=10s"), has: []string{"='10s', using 10s"}, oracle: true},
	{name: "timeout-invalid-zero", legacy: "H4l", kit: "stub", env: stubEnv(behindOut, "RESEARCH_SDD_INSTALL_VERIFY_TIMEOUT=0"), has: []string{"='0', using 10s"}, oracle: true},
	{name: "timeout-invalid-negative", legacy: "H4l", kit: "stub", env: stubEnv(behindOut, "RESEARCH_SDD_INSTALL_VERIFY_TIMEOUT=-3"), has: []string{"='-3', using 10s"}, oracle: true},
	{name: "timeout-invalid-seven-digits", legacy: "H4l", kit: "stub", env: stubEnv(behindOut, "RESEARCH_SDD_INSTALL_VERIFY_TIMEOUT=1234567"), has: []string{"='1234567', using 10s"}, oracle: true},
	{name: "timeout-invalid-substitution", legacy: "H4l H4m", kit: "stub", env: stubEnv(behindOut, "RESEARCH_SDD_INSTALL_VERIFY_TIMEOUT=a[$(touch vt-pwned)]"), has: []string{"invalid RESEARCH_SDD_INSTALL_VERIFY_TIMEOUT='atouchvt-pwned', using 10s"}, not: []string{"syntax error", "operand"}, oracle: true},
	{name: "timeout-zero-padded-valid", legacy: "H4n", kit: "stub", env: E("RESEARCH_SDD_INSTALL_VERIFY_TIMEOUT=007"), silent: true, oracle: true},
	// ---- the real drift half --------------------------------------------------------------------------------------------------
	{name: "real-insync", legacy: "12 AN-hook-1 BDG1", kit: "real", home: claudeSync, env: E("RESEARCH_SDD_INSTALL_VERIFY_CMD=@TB@/install-verify-stub.sh"), silent: true, oracle: true},
	{name: "real-absent", legacy: "14 AN-hook-3", kit: "real", home: func(t testing.TB, w *world) {}, env: E("RESEARCH_SDD_INSTALL_VERIFY_CMD=@TB@/install-verify-stub.sh"), silent: true, oracle: true},
	{name: "real-diverged", legacy: "13 15 15b BDG2", kit: "real", home: claudeStale, env: E("RESEARCH_SDD_INSTALL_VERIFY_CMD=@TB@/install-verify-stub.sh"),
		has: []string{"force-skill", "WARN: research-sdd SKILL.md stale for one or more harnesses"}, max: 541, oracle: true},
	{name: "real-pi-diverged", legacy: "AN-hook-2", kit: "real", home: claudeSyncPiStale, env: E("RESEARCH_SDD_INSTALL_VERIFY_CMD=@TB@/install-verify-stub.sh"), has: []string{"force-skill", "--harness pi"}, oracle: true},
	{name: "real-all-diverged", legacy: "BDG3", kit: "real", home: allStale, env: E("RESEARCH_SDD_INSTALL_VERIFY_CMD=@TB@/install-verify-stub.sh"), has: []string{"also diverged: pi, gentle-shell"}, max: 541, oracle: true},
	{name: "real-home-unset", legacy: "AX7", kit: "real", env: E("-HOME", "RESEARCH_SDD_INSTALL_VERIFY_CMD=@TB@/install-verify-stub.sh"), has: []string{"ERROR", "HOME is unset"}, oracle: true},
	{name: "real-diverged-and-behind", legacy: "H10", kit: "real", home: claudeStale, env: stubEnv(behindOut, "RESEARCH_SDD_INSTALL_VERIFY_CMD=@TB@/install-verify-stub.sh"), has: []string{"force-skill", "status=behind"}, oracle: true},
	// ---- the SessionStart envelope (encoding pinned to jq) ----------------------------------------------------------------------
	{name: "emit-escapes", legacy: "H3b", kit: "stub", env: E("STUB_DRIFT_RC=1", "STUB_DRIFT_OUT=quote \" backslash \\ tab\t ctl \x01 del \x7f accents é — emoji 😀 <&>   end"), has: []string{"accents"}, oracle: true},
	{name: "emit-invalid-utf8", legacy: "H3b", kit: "stub", env: E("STUB_DRIFT_RC=1", "STUB_DRIFT_OUT=bad \xff\xfe bytes"), has: []string{"bad"}, oracle: true},
	{name: "cut-splits-multibyte", legacy: "H8", kit: "stub", env: stubEnv("verify harness=pi status=degraded reason="+strings.Repeat("é", 100), "STUB_VERIFY_RC=2"), has: []string{"status=degraded"}, oracle: true},
	// ---- kit staleness (#2130) ----------------------------------------------------------------------------------------------------
	{name: "kit-current", legacy: "K1", kit: "stub", kdir: "k0", silent: true, oracle: true},
	{name: "kit-3-behind-silent", legacy: "K2", kit: "stub", kdir: "k3", silent: true, oracle: true},
	{name: "kit-25-behind-stale", legacy: "K3 K3b K3c", kit: "stub", kdir: "k25", has: []string{"verify kit-stale status=stale fix (no live session): git -C ~/k25 pull --ff-only", "behind=25", "may understate", "WARN"}, not: []string{"kit status=behind"}, oracle: true},
	{name: "kit-threshold-commits", legacy: "K4", kit: "stub", kdir: "k3", env: E("RESEARCH_SDD_KIT_STALE_MAX_COMMITS=2"), has: []string{"behind=3"}, oracle: true},
	{name: "kit-threshold-garbage", legacy: "K5", kit: "stub", kdir: "k25", env: E("RESEARCH_SDD_KIT_STALE_MAX_COMMITS=a[$(touch k-pwned)]", "RESEARCH_SDD_KIT_STALE_MAX_DAYS=1x"),
		has: []string{"behind=25", "invalid RESEARCH_SDD_KIT_STALE_MAX_COMMITS='atouchk-pwned', using 20", "invalid RESEARCH_SDD_KIT_STALE_MAX_DAYS='1x', using 7"}, oracle: true},
	{name: "kit-optout", legacy: "K6", kit: "stub", kdir: "k25", env: E("RESEARCH_SDD_KIT_STALE_CHECK=off"), has: []string{"kit status=behind"}, not: []string{"kit-stale"}, oracle: true},
	{name: "kit-diverged-kept", legacy: "K7", kit: "stub", kdir: "k25", env: E("STUB_VERIFY_OUT=" + matchOut + "\nverify kit status=behind ref=origin/main behind=25 ahead=2 (diverged: local commits, a fast-forward is not possible — reconcile by hand; local ref, no fetch)"),
		has: []string{"diverged"}, not: []string{"kit-stale"}, oracle: true},
	{name: "kit-old-fetch", legacy: "K8", kit: "stub", kdir: "kold", has: []string{"kit-stale", "fetch_age=10d", "behind=0"}, oracle: true},
	{name: "kit-old-fetch-days-raised", legacy: "K8b", kit: "stub", kdir: "kold", env: E("RESEARCH_SDD_KIT_STALE_MAX_DAYS=30"), silent: true, oracle: true},
	{name: "kit-nested-one-level", legacy: "K9", kit: "stub", kdir: "k25/research-sdd", has: []string{"behind=25"}, oracle: true},
	{name: "kit-nested-deep-silent", legacy: "K9b", kit: "stub", kdir: "k25/deep/er", env: E("STUB_VERIFY_OUT=" + matchOut), silent: true, oracle: true},
	{name: "kit-nested-deep-verbose", legacy: "K9c", kit: "stub", kdir: "k25/deep/er", env: E("STUB_VERIFY_OUT="+matchOut, "RESEARCH_SDD_KIT_STALE_VERBOSE=1"), has: []string{"kit-stale status=degraded reason=kit dir sits inside an unrelated repo"}, oracle: true},
	{name: "kit-no-upstream-silent", legacy: "K10", kit: "stub", kdir: "norem", silent: true, oracle: true},
	{name: "kit-no-upstream-verbose", legacy: "K10b", kit: "stub", kdir: "norem", env: E("RESEARCH_SDD_KIT_STALE_VERBOSE=1"), has: []string{"kit-stale status=degraded", "no upstream"}, oracle: true},
	{name: "kit-not-a-checkout-silent", legacy: "K11", kit: "stub", kdir: "plain", silent: true, oracle: true},
	{name: "kit-not-a-checkout-verbose", legacy: "K11b", kit: "stub", kdir: "plain", env: E("RESEARCH_SDD_KIT_STALE_VERBOSE=1"), has: []string{"kit-stale status=degraded", "not a git checkout"}, oracle: true},
	{name: "kit-git-absent-silent", legacy: "K12", kit: "stub", kdir: "norem", env: E("PATH=@ROOT@/nogitbin"), silent: true, oracle: true},
	{name: "kit-git-absent-verbose", legacy: "K12b", kit: "stub", kdir: "norem", env: E("PATH=@ROOT@/nogitbin", "RESEARCH_SDD_KIT_STALE_VERBOSE=1"), has: []string{"kit-stale status=degraded", "git not found"}, oracle: true},
	{name: "kit-never-fetched-quiet", legacy: "K13", kit: "stub", kdir: "kquiet", silent: true, oracle: true},
	{name: "kit-never-fetched-old-config", legacy: "K13b", kit: "stub", kdir: "kquiet2", silent: true, oracle: true},
	{name: "kit-never-fetched-verbose", legacy: "K13c", kit: "stub", kdir: "kquiet", env: E("RESEARCH_SDD_KIT_STALE_VERBOSE=1"), has: []string{"kit-stale status=degraded reason=no FETCH_HEAD (never fetched): age criterion skipped"}, oracle: true},
	{name: "kit-fallback-origin-main", legacy: "K14", kit: "stub", kdir: "kfb", env: E("RESEARCH_SDD_KIT_STALE_MAX_COMMITS=2"), has: []string{"fetch && git -C ~/kfb merge --ff-only origin/main"}, not: []string{"pull --ff-only"}, oracle: true},
	{name: "kit-real-like-path", legacy: "K15", kit: "stub", kdir: "homefix/investigacion/sdd-investigacion/research-sdd", env: E("HOME=@FIX@/homefix"),
		has: []string{"git -C ~/investigacion/sdd-investigacion/research-sdd pull --ff-only", "may understate"}, oracle: true},
	{name: "kit-long-path", legacy: "K15b", kit: "stub", kdir: "k25-" + strings.Repeat("x", 150), has: []string{"pull --ff-only"}, oracle: true},
	{name: "kit-verify-exit-after-dedupe", legacy: "K20", kit: "stub", kdir: "k3", env: E("STUB_VERIFY_RC=1"), has: []string{"exited 1 with no typed line"}, oracle: true},
	{name: "kit-home-unset-tilde-quirk", legacy: "K3c", kit: "stub", kdir: "k25", env: E("-HOME"), has: []string{"git -C ~@FIX@/k25 pull --ff-only"}, oracle: true},
	{name: "kit-git-hangs-bounded", legacy: "K16", kit: "stub", kdir: "k25", env: E("PATH=@ROOT@/hangbin:@PATH@"), has: []string{"kit status=behind"}, not: []string{"kit-stale"}, limitSec: 8, oracle: true},
	{name: "kit-skipped-after-verify-timeout", legacy: "K17", kit: "stub", kdir: "k25", env: E("PATH=@ROOT@/hangbin:@PATH@", "STUB_VERIFY_SLEEP=5", "RESEARCH_SDD_INSTALL_VERIFY_TIMEOUT=1"), has: []string{"timed out"}, not: []string{"kit-stale"}, limitSec: 5, oracle: true},
	{name: "kit-gitpath-fails", legacy: "K19 K19b", kit: "stub", kdir: "k3", env: E("PATH=@ROOT@/gpfailbin:@PATH@", "RESEARCH_SDD_KIT_STALE_VERBOSE=1"), has: []string{"kit status=behind", "reason=could not locate FETCH_HEAD"}, not: []string{"kit-stale status=stale"}, oracle: true},
	{name: "kit-no-timeout-bin", legacy: "K21", kit: "stub", kdir: "k25", diverg: true, env: E("RESEARCH_SDD_NO_TIMEOUT_BIN=1"), has: []string{"kit-stale"}},
}

// ---- running a case -------------------------------------------------------------------------------------------------------------

// decode is the additionalContext of a SessionStart envelope; any other output is returned as is.
func decode(out string) string {
	var v struct {
		H struct {
			C string `json:"additionalContext"`
		} `json:"hookSpecificOutput"`
	}
	if json.Unmarshal([]byte(out), &v) == nil && v.H.C != "" {
		return v.H.C
	}
	return out
}

// prepare builds the world of a hook case and returns it with the environment of the run.
func (c hcase) prepare(t *testing.T) (*world, []string) {
	t.Helper()
	needTool(t, "bash", "RSDD_REQUIRE_BASH")
	needTool(t, "jq", "RSDD_REQUIRE_JQ")
	w := newWorld(t, c.kit)
	if c.home != nil {
		c.home(t, w)
	}
	extra := []string{"RESEARCH_SDD_INSTALL_VERIFY_CMD=@TB@/install-verify-stub.sh"}
	if c.kit == "real" {
		extra = append(extra, "HOME=@HOME@") // the drift half reads HOME, as the legacy suite's patched --home did
	}
	// PATH helpers of the cases that need a tool to be absent, hanging or failing
	if err := os.MkdirAll(filepath.Join(w.root, "nogitbin"), 0o755); err != nil {
		t.Fatal(err)
	}
	for _, tool := range strings.Fields("bash env sleep cat grep awk cut head tr mktemp rm dirname readlink jq date stat sed basename timeout") {
		if p, ok := findExe(tool, os.Getenv("PATH")); ok {
			symlink(t, p, filepath.Join(w.root, "nogitbin", tool))
		}
	}
	write(t, filepath.Join(w.root, "hangbin", "git"), "#!/bin/sh\nexec sleep 20\n", 0o755)
	write(t, filepath.Join(w.root, "gpfailbin", "git"), fmt.Sprintf("#!/bin/sh\ncase \"$*\" in *--git-path*) exit 1 ;; esac\nexec %s \"$@\"\n", mustLook(t, "git")), 0o755)
	if c.kdir != "" {
		fx := fixtures(t)
		d := filepath.Join(fx, c.kdir)
		extra = append(extra, "RESEARCH_SDD_KIT_STALE_CHECK=", "RESEARCH_SDD_KIT_DIR="+d, "HOME="+fx)
		if !hasKey(c.env, "STUB_VERIFY_OUT") {
			root := filepath.Join(fx, strings.SplitN(c.kdir, "/", 2)[0])
			extra = append(extra, "STUB_VERIFY_OUT="+kitStubOut(d, fixBehnd[root]))
		}
	}
	if c.need != "" {
		needTool(t, c.need, "")
	}
	for _, e := range c.env {
		extra = append(extra, strings.ReplaceAll(e, "@PATH@", os.Getenv("PATH")))
	}
	return w, w.runEnv(extra)
}

func mustLook(t testing.TB, name string) string {
	t.Helper()
	p, ok := findExe(name, os.Getenv("PATH"))
	if !ok {
		t.Skipf("%s not on PATH", name)
	}
	return p
}

func hasKey(env []string, k string) bool {
	for _, e := range env {
		if strings.HasPrefix(e, k+"=") {
			return true
		}
	}
	return false
}

func (w *world) runBashHook(env []string) result {
	return w.runBash("verify-skill-drift-hook.sh", nil, env)
}

func (w *world) runGoHook(c hcase, env []string) result {
	var out, errb bytes.Buffer
	s := w.goStdio(env, &out, &errb)
	d := hookDeps{drift: RunDrift}
	if c.kit == "stub" {
		d.drift = func(_ []string, s2 cli.Stdio) int {
			if o := s2.Env("STUB_DRIFT_OUT"); o != "" {
				fmt.Fprintf(s2.Out, "%s\n", o)
			}
			rc, _ := strconv.Atoi(s2.Env("STUB_DRIFT_RC"))
			return rc
		}
	}
	code := runHook(s, d)
	return result{out.String(), errb.String(), code}
}
