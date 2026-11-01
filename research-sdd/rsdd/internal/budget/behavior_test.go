package budget

import (
	"crypto/sha256"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// The behavior of `rsdd budget verify`, one Go test per case of the retired verify-session-budget.test.sh. The test names carry
// the old case number (case_NN_...) so the mapping is greppable. Parity with the frozen script is parity_test.go; these pin the
// OBSERVABLE rule of each case on its own, so a regression names the rule that broke.
//
// Mapping (old suite case -> Go test):
//   F1                      TestFrozenOutputs (parity_test.go)
//   1-8                     TestCase_mixed
//   9-15                    TestCase_degraded
//   16-17                   TestCase_over
//   18,19,22                TestCase_inputStates
//   20,21,50                TestCase_usage
//   23,24,25,26             TestCase_toolFaults
//   27-29                   TestCase_sources
//   30                      TestCase_newline
//   31                      TestCase_ownTimeout
//   32,33                   TestCase_characters
//   34                      TestCase_unreadableCopy
//   35-37                   TestCase_containment
//   40,41                   TestCase_containmentArgv
//   42,43 (matchers)        TestCase_matchers
//   42,43 (gate), 80,81     TestGateDecision
//   44                      TestCase_partialmix
//   45                      TestCase_capped
//   46                      TestCase_fresh
//   51,52,53                TestCase_piToolFaults
//   54,55                   TestCase_piContainmentArgv
//   56-60a                  TestCase_piCard
//   61,62                   TestCase_piKitSections
//   63,64,64a               TestCase_piDegradedSections
//   65                      TestCase_piAmbientEnv
//   66                      TestCase_piBoth
//   67-74                   TestHelper_*
//   75-79                   TestCase_piRoutes, _piExit, _piHang, _piSub, _piNoDotClaude
//   82,83                   TestCase_piForgery

func caseByName(t testing.TB, name string) pcase {
	t.Helper()
	for _, c := range cases {
		if c.name == name {
			return c
		}
	}
	t.Fatalf("no case %q", name)
	return pcase{}
}

// goRun runs one named case through the Go command.
func goRun(t *testing.T, name string) (result, prepared) {
	t.Helper()
	c := caseByName(t, name)
	c.gate(t)
	p := c.prepare(t, "")
	return runGo(append([]string{"--toolbelt", p.toolbelt}, p.args...), p.env, p.root), p
}

func has(t *testing.T, s, re string) bool {
	t.Helper()
	return regexp.MustCompile("(?m)" + re).MatchString(s)
}

func mustHave(t *testing.T, id, s, re string) {
	t.Helper()
	if !has(t, s, re) {
		t.Errorf("%s: output lacks /%s/:\n%s", id, re, s)
	}
}

func mustNotHave(t *testing.T, id, s, re string) {
	t.Helper()
	if has(t, s, re) {
		t.Errorf("%s: output has /%s/:\n%s", id, re, s)
	}
}

func mustExit(t *testing.T, id string, r result, want int) {
	t.Helper()
	if r.code != want {
		t.Errorf("%s: exit %d, want %d: [%s]", id, r.code, want, r.both())
	}
}

// block is one source's report lines, from `source X:` to `aggregate[X]`.
func block(s, src string) string {
	var b []string
	on := false
	for _, l := range strings.Split(s, "\n") {
		if strings.HasPrefix(l, "source "+src+":") {
			on = true
		}
		if on {
			b = append(b, l)
		}
		if on && strings.HasPrefix(l, "aggregate["+src+"]") {
			break
		}
	}
	return strings.Join(b, "\n")
}

func countLines(s, prefix string) int {
	n := 0
	for _, l := range strings.Split(s, "\n") {
		if strings.HasPrefix(l, prefix) {
			n++
		}
	}
	return n
}

// snapshot is the old suite's snap(): path, type, size and mtime of every entry plus the sha256 of every file.
func snapshot(t testing.TB, dir string) string {
	t.Helper()
	var sb strings.Builder
	err := filepath.WalkDir(dir, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		fi, err := d.Info()
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(dir, p)
		fmt.Fprintf(&sb, "%s %v %d %d\n", rel, fi.Mode(), fi.Size(), fi.ModTime().UnixNano())
		if fi.Mode().IsRegular() {
			b, err := os.ReadFile(p)
			if err != nil {
				return err
			}
			fmt.Fprintf(&sb, "  %x\n", sha256.Sum256(b))
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	return sb.String()
}

func TestCase_inputStates(t *testing.T) {
	t.Parallel()
	r, _ := goRun(t, "empty")
	mustHave(t, "case 18", r.out, `^state: empty-input`)
	r, _ = goRun(t, "absent")
	mustHave(t, "case 19", r.out, `^state: absent-input \(no .*/absent/\.claude/settings\.json\)$`)
	r, _ = goRun(t, "badjson")
	mustHave(t, "case 22", r.out, `^state: degraded \(settings\.json is not a readable JSON object`)
	mustExit(t, "case 22", r, 0)
}

func TestCase_usage(t *testing.T) {
	t.Parallel()
	for _, name := range []string{"usage-nodir", "usage-noarg", "usage-twoargs", "usage-harness-novalue", "usage-file-not-dir"} {
		r, _ := goRun(t, name)
		mustExit(t, "case 20/21 "+name, r, 2)
		if r.out != "" || r.err != usageLine+"\n" {
			t.Errorf("%s: usage must be the script's line on stderr only, got stdout=%q stderr=%q", name, r.out, r.err)
		}
	}
	r, _ := goRun(t, "usage-badharness")
	mustExit(t, "case 50 an unknown --harness value is a usage error", r, 2)
}

func TestCase_toolFaults(t *testing.T) {
	t.Parallel()
	r, _ := goRun(t, "nojq")
	mustHave(t, "case 23", r.out, `^state: degraded \(jq unavailable`)
	mustExit(t, "case 23", r, 0)
	mustNotHave(t, "case 23 no hook run", r.out, `hook\[`)

	c := caseByName(t, "nobwrap")
	p := c.prepare(t, "")
	before := snapshot(t, p.target)
	r = runGo(append([]string{"--toolbelt", p.toolbelt}, p.args...), p.env, p.root)
	after := snapshot(t, p.target)
	mustHave(t, "case 24", r.out, `hook\[1\] chars=n/a status=degraded\(no-sandbox: bwrap not installed\)`)
	mustHave(t, "case 24", r.out, `^state: degraded`)
	mustExit(t, "case 24", r, 0)
	if before != after || hasFile(filepath.Join(p.target, ".claude", ".hook-wrote-this")) {
		t.Errorf("case 25: the target changed although no sandbox was available (a hook ran unprotected)")
	}

	r, _ = goRun(t, "badbwrap")
	mustHave(t, "case 26", r.out, `status=degraded\(no-sandbox: bwrap cannot start: bwrap: No permissions`)
	mustNotHave(t, "case 26 not a plain exit", r.out, `degraded\(exit 1\)`)
}

func TestCase_mixed(t *testing.T) {
	t.Parallel()
	c := caseByName(t, "mixed")
	c.gate(t)
	p := c.prepare(t, "")
	before := snapshot(t, p.target)
	r := runGo(append([]string{"--toolbelt", p.toolbelt}, p.args...), p.env, p.root)
	after := snapshot(t, p.target)
	mustHave(t, "case 1 plain 500-char hook measured as 500", r.out, `hook\[1\] chars=500 status=ok`)
	mustHave(t, "case 2 10,500-char hook is TRUNCATED", r.out, `hook\[2\] chars=10500 status=TRUNCATED`)
	mustHave(t, "case 3 JSON additionalContext+systemMessage counted (300+200)", r.out, `hook\[3\] chars=500 status=ok`)
	mustHave(t, "case 4 writing hook still measured", r.out, `hook\[4\] chars=5 status=ok`)
	mustHave(t, "case 5 aggregate 11505 flagged OVER BUDGET", r.out, `aggregate: 11505 chars .*OVER BUDGET`)
	mustExit(t, "case 6 findings are WARN-only", r, 0)
	if before != after {
		t.Errorf("case 7: target CHANGED (content+mtime) after the run")
	}
	if hasFile(filepath.Join(p.target, ".claude", ".hook-wrote-this")) || hasFile(filepath.Join(p.target, "stray-root-file")) {
		t.Errorf("case 8: a hook write leaked into the target")
	}
	if ents, _ := os.ReadDir(filepath.Join(p.root, "tmp")); len(ents) != 0 {
		t.Errorf("the run left its temp dir behind: %v", ents)
	}
}

func TestCase_degraded(t *testing.T) {
	t.Parallel()
	r, _ := goRun(t, "degraded")
	mustHave(t, "case 9 healthy hook still measured beside degraded ones", r.out, `hook\[1\] chars=100 status=ok`)
	mustHave(t, "case 10 hanging hook is degraded(timeout)", r.out, `hook\[2\] .*status=degraded\(timeout`)
	mustHave(t, "case 11 failing hook is degraded(exit 1), partial output not counted", r.out, `hook\[3\] .*status=degraded\(exit 1`)
	mustHave(t, "case 12 unresolvable hook is degraded", r.out, `hook\[4\] .*status=degraded\(`)
	mustNotHave(t, "case 13 a degraded hook is never counted as 0 chars", r.out, `hook\[2\] chars=0`)
	mustHave(t, "case 14 aggregate is marked partial with the degraded count", r.out, `aggregate: 100 chars .*partial: 3 degraded`)
	mustExit(t, "case 15 degraded is WARN-only", r, 0)
}

func TestCase_over(t *testing.T) {
	t.Parallel()
	r, _ := goRun(t, "over")
	mustNotHave(t, "case 16 no TRUNCATED when every hook is under 10,000", r.out, `TRUNCATED`)
	mustHave(t, "case 17 aggregate 9000 (3x3000) OVER BUDGET", r.out, `aggregate: 9000 chars .*OVER BUDGET`)
}

func TestCase_sources(t *testing.T) {
	t.Parallel()
	r, _ := goRun(t, "sources")
	mustHave(t, "case 27 startup 500", r.out, `aggregate\[startup\]: 500 chars .* OK`)
	mustHave(t, "case 27 resume 5500", r.out, `aggregate\[resume\]: 5500 chars .* OK`)
	mustHave(t, "case 27 clear 500", r.out, `aggregate\[clear\]: 500 chars .* OK`)
	mustHave(t, "case 27 compact 9100", r.out, `aggregate\[compact\]: 9100 chars .*OVER BUDGET`)
	mustHave(t, "case 28 the worst source decides the verdict", r.out, `aggregate: 9100 chars .*OVER BUDGET worst-source=compact`)
	if n := countLines(block(r.out, "startup"), "hook["); n != 2 {
		t.Errorf("case 29: an identical command under two entries must run once within a source, startup has %d hook lines", n)
	}
}

func TestCase_newline(t *testing.T) {
	t.Parallel()
	r, _ := goRun(t, "newline")
	if n := countLines(block(r.out, "startup"), "hook["); n != 1 {
		t.Errorf("case 30: a command with embedded newlines is ONE hook, got %d", n)
	}
	mustHave(t, "case 30", r.out, `aggregate\[startup\]: 10 chars`)
}

func TestCase_ownTimeout(t *testing.T) {
	t.Parallel()
	r, _ := goRun(t, "timeouts")
	mustHave(t, "case 31 typed timed-out note, counts 0", r.out, `hook\[1\] chars=0 status=timed-out\(hook timeout 1s\)`)
	mustHave(t, "case 31 counted on the state line", r.out, `state: ok \(1 hook runs, 0 truncated, 1 timed-out\)`)
}

func TestCase_matchers(t *testing.T) {
	t.Parallel()
	r, _ := goRun(t, "matchers")
	mustHave(t, "case 42 regex ^start (unanchored) selects startup", r.out, `aggregate\[startup\]: 500 chars`)
	mustHave(t, "case 42 list 'startup, resume' (comma, spaces) selects resume", r.out, `aggregate\[resume\]: 300 chars`)
	mustHave(t, "case 42 exact 'fork' selects fork", r.out, `aggregate\[fork\]: 50 chars`)
	mustHave(t, "case 43", r.out, `source clear: \(no matching`)
	mustHave(t, "case 43", r.out, `source compact: \(no matching`)
	mustNotHave(t, "case 43 exact 'start' does NOT match 'startup' (its 7000-char hook never runs)", r.out, `exact7000|chars=7000`)
}

func TestCase_partialmix(t *testing.T) {
	t.Parallel()
	r, _ := goRun(t, "partialmix")
	mustHave(t, "case 44 the final aggregate is partial even when the WORST source is clean (names the degraded source)", r.out,
		`aggregate: 9000 chars .*OVER BUDGET \(partial: 1 degraded in startup\) worst-source=compact`)
}

func TestCase_capped(t *testing.T) {
	t.Parallel()
	r, _ := goRun(t, "capped")
	if n := strings.Count(r.out, "not re-run"); n != 4 {
		t.Errorf("case 45: a command that hit the script cap runs once, later sources say 'not re-run' (4), got %d:\n%s", n, r.out)
	}
	mustHave(t, "case 45", r.out, `aggregate\[startup\].*partial`)
	mustHave(t, "case 45", r.out, `partial: 5 degraded in startup,resume,clear,compact,fork`)
}

func TestCase_fresh(t *testing.T) {
	t.Parallel()
	r, _ := goRun(t, "fresh")
	if n := strings.Count(r.out, "chars=5 status=ok"); n != 5 {
		t.Errorf("case 46: each of the five sources sees a fresh .claude copy (order-independent), got %d of 5:\n%s", n, r.out)
	}
}

func TestCase_characters(t *testing.T) {
	t.Parallel()
	r, _ := goRun(t, "utf8")
	mustHave(t, "case 32 three accented characters count as 3 (code points)", r.out, `hook\[1\] chars=3 status=ok`)
	r, _ = goRun(t, "nowc")
	mustHave(t, "case 33 a wc that counts bytes -> typed degraded(no-utf8-locale)", r.out, `status=degraded\(no-utf8-locale`)
	mustHave(t, "case 33", r.out, `^state: degraded`)
}

func TestCase_unreadableCopy(t *testing.T) {
	t.Parallel()
	r, _ := goRun(t, "unreadable-copy")
	mustHave(t, "case 34 a .claude entry that cannot be copied -> degraded(incomplete-sandbox-copy)", r.out, `status=degraded\(incomplete-sandbox-copy`)
}

func TestCase_containment(t *testing.T) {
	t.Parallel()
	c := caseByName(t, "escape")
	c.gate(t)
	p := c.prepare(t, "")
	r := runGo(append([]string{"--toolbelt", p.toolbelt}, p.args...), p.env, p.root)
	mustHave(t, "case 35", r.out, `hook\[1\] chars=23 status=ok`)
	if hasFile(filepath.Join(p.root, "home", "rsdd-budget-escape")) || hasFile(filepath.Join(p.root, "escape-marker")) {
		t.Errorf("case 35: writes to $HOME and to a path outside TMPDIR must be blocked")
	}
	mustHave(t, "case 36 only the loopback interface is visible (no network)", r.out, `hook\[2\] chars=1 status=ok`)
	mustHave(t, "case 37 SSH_AUTH_SOCK / SSH_AGENT_PID / DBUS variables are not inherited", r.out, `hook\[3\] chars=0 status=ok`)
}

// shimBwrap installs a recording bwrap first on PATH: it answers the start probe, logs every other argv, runs nothing.
func shimBwrap(t testing.TB, root string, readStdin bool) (path, log string) {
	t.Helper()
	dir, log := filepath.Join(root, "shim-bin"), filepath.Join(root, "shim.log")
	body := "#!/bin/sh\nif [ \"$*\" = \"--ro-bind / / true\" ]; then exit 0; fi\n"
	if readStdin {
		body += "cat >/dev/null\n"
	}
	body += "{ for a in \"$@\"; do printf \"%s\\n\" \"$a\"; done; echo \"--END--\"; } >> \"$RSDD_SHIM_LOG\"\nexit 0\n"
	write(t, filepath.Join(dir, "bwrap"), body, 0o755)
	write(t, log, "", 0o644)
	return dir, log
}

func recordedRuns(t testing.TB, log string) [][]string {
	t.Helper()
	b, err := os.ReadFile(log)
	if err != nil {
		t.Fatal(err)
	}
	var runs [][]string
	var cur []string
	for _, l := range strings.Split(strings.TrimSuffix(string(b), "\n"), "\n") {
		if l == "--END--" {
			runs = append(runs, cur)
			cur = nil
			continue
		}
		cur = append(cur, l)
	}
	return runs
}

// missingArgs names each containment argument absent from one recorded bwrap argv.
func missingArgs(rec []string, target string) []string {
	seq := func(want ...string) bool {
		for a := 0; a+len(want) <= len(rec); a++ {
			ok := true
			for b := range want {
				if rec[a+b] != want[b] {
					ok = false
					break
				}
			}
			if ok {
				return true
			}
		}
		return false
	}
	var out []string
	if !seq("--ro-bind", "/", "/") {
		out = append(out, "ro-bind-root")
	}
	for _, f := range []string{"--unshare-pid", "--unshare-net", "--unshare-ipc", "--new-session", "--die-with-parent"} {
		if !seq(f) {
			out = append(out, f)
		}
	}
	for _, v := range []string{"SSH_AUTH_SOCK", "SSH_AGENT_PID", "GPG_AGENT_INFO", "DBUS_SESSION_BUS_ADDRESS", "XDG_RUNTIME_DIR"} {
		if !seq("--unsetenv", v) {
			out = append(out, "unsetenv-"+v)
		}
	}
	if !seq("--setenv", "CLAUDE_PROJECT_DIR", target) {
		out = append(out, "setenv-CLAUDE_PROJECT_DIR")
	}
	found := false
	for i := 0; i+2 < len(rec); i++ {
		if rec[i] == "--bind" && rec[i+2] == target+"/.claude" && rec[i+1] != rec[i+2] {
			found = true
		}
	}
	if !found {
		out = append(out, "dotclaude-copy-bind")
	}
	return out
}

// Cases 40 and 41: containment is asserted in EVERY environment through a recording bwrap shim, even where bwrap cannot run.
func TestCase_containmentArgv(t *testing.T) {
	t.Parallel()
	c := caseByName(t, "mixed")
	p := c.prepare(t, "")
	dir, log := shimBwrap(t, p.root, true)
	env := withEnv(p.env, "PATH="+dir+":"+os.Getenv("PATH"), "RSDD_SHIM_LOG="+log)
	r := runGo(append([]string{"--toolbelt", p.toolbelt}, p.args...), env, p.root)
	runs := recordedRuns(t, log)
	if len(runs) != 4 {
		t.Fatalf("case 40: the shim saw %d bwrap runs, want one per hook (4); zero runs would fail closed: [%s]", len(runs), r.both())
	}
	for i, rec := range runs {
		if m := missingArgs(rec, p.target); len(m) != 0 {
			t.Errorf("case 41: bwrap run %d lacks %v", i+1, m)
		}
	}
}

// The gate behind needBwrap/needNode (old cases 42/43 gate, 80/81): an unusable tool FAILS under REQUIRE=1 and SKIPs otherwise.
func TestGateDecision(t *testing.T) {
	for _, tc := range []struct {
		usable  bool
		require string
		want    string
	}{{true, "", "run"}, {true, "1", "run"}, {false, "1", "fail"}, {false, "0", "skip"}, {false, "", "skip"}} {
		if got := gateDecision(tc.usable, tc.require); got != tc.want {
			t.Errorf("gateDecision(%v, %q) = %s, want %s", tc.usable, tc.require, got, tc.want)
		}
	}
}

func TestCase_piToolFaults(t *testing.T) {
	t.Parallel()
	r, _ := goRun(t, "pi-nonode")
	mustHave(t, "case 51 node missing", r.out, `pi: DEGRADED — node unavailable`)
	mustHave(t, "case 51", r.out, `^state: degraded`)
	mustNotHave(t, "case 51 never a silent 0", r.out, `aggregate\[pi\]`)
	mustExit(t, "case 51", r, 0)
	r, _ = goRun(t, "pi-nots")
	mustHave(t, "case 52 node without TypeScript type stripping", r.out, `pi: DEGRADED — node .*no built-in TypeScript type stripping`)
	mustNotHave(t, "case 52", r.out, `aggregate\[pi\]`)
	r, _ = goRun(t, "pi-nobwrap")
	mustHave(t, "case 53 nothing is run unprotected", r.out, `pi: DEGRADED — no-sandbox: bwrap not installed`)
	mustNotHave(t, "case 53", r.out, `aggregate\[pi\]`)
	r, _ = goRun(t, "pi-ext-missing")
	mustHave(t, "pi kit extension missing is typed", r.out, `pi: DEGRADED — kit extension not found: `)
	r, _ = goRun(t, "pi-helper-missing")
	mustHave(t, "pi measuring helper missing is typed", r.out, `pi: DEGRADED — measuring helper not found: `)
}

// Cases 54 and 55: the pi run is ONE bwrap invocation with the full containment argv, and a harness that prints nothing is a typed
// DEGRADED, not 0 chars.
func TestCase_piContainmentArgv(t *testing.T) {
	t.Parallel()
	needNode(t)
	c := caseByName(t, "pi-card")
	p := c.prepare(t, "")
	dir, log := shimBwrap(t, p.root, false)
	env := withEnv(p.env, "PATH="+dir+":"+os.Getenv("PATH"), "RSDD_SHIM_LOG="+log)
	r := runGo(append([]string{"--toolbelt", p.toolbelt}, p.args...), env, p.root)
	runs := recordedRuns(t, log)
	if len(runs) != 1 {
		t.Fatalf("case 54: the pi run must be ONE bwrap invocation, saw %d: [%s]", len(runs), r.both())
	}
	if m := missingArgs(runs[0], p.target); len(m) != 0 {
		t.Errorf("case 54: pi containment argv lacks %v", m)
	}
	mustHave(t, "case 55 a harness that prints nothing is a typed DEGRADED, not 0 chars", r.out, `pi: DEGRADED — extension harness produced no records`)
	mustNotHave(t, "case 55", r.out, `aggregate\[pi\]`)
}

func TestCase_piCard(t *testing.T) {
	t.Parallel()
	c := caseByName(t, "pi-card")
	c.gate(t)
	p := c.prepare(t, "")
	before := snapshot(t, p.target)
	r := runGo(append([]string{"--toolbelt", p.toolbelt}, p.args...), p.env, p.root)
	after := snapshot(t, p.target)
	mustHave(t, "case 56 harness line", r.out, `^harness: pi `)
	mustHave(t, "case 56 emulation limits", r.out, `^limits: fake pi `)
	mustHave(t, "case 57 a target .pi extension section is measured at its decoded length", r.out, `^section\[card\.ts\] card-section chars=2500 status=ok`)
	mustHave(t, "case 58 the kit extension's section is measured (non-zero)", r.out, `^section\[research-sdd-hooks\.ts\] research-sdd-session chars=[1-9][0-9]* status=ok`)
	if n := countLines(r.out, "section["); n != 2 {
		t.Errorf("case 59a: exactly two sections are attributed (kit + card), got %d", n)
	}
	sum := 0
	for _, m := range regexp.MustCompile(`(?m)^section\[[^\]]*\] .* chars=([0-9]*) status=`).FindAllStringSubmatch(r.out, -1) {
		var n int
		fmt.Sscan(m[1], &n)
		sum += n
	}
	m := regexp.MustCompile(`(?m)^aggregate\[pi\]: ([0-9]*) chars`).FindStringSubmatch(r.out)
	if m == nil || m[1] != fmt.Sprint(sum) || sum <= 2500 {
		t.Errorf("case 59: aggregate[pi] must equal the sum of the section lines (%d) and exceed 2500: [%s]", sum, r.out)
	}
	mustHave(t, "case 59", r.out, `^aggregate\[pi\]: [0-9]+ chars \(budget < 8000\) OK$`)
	mustHave(t, "case 59", r.out, `^state: ok`)
	if before != after {
		t.Errorf("case 60: the target must be byte-identical after the pi run (writes land in the sandbox copy)")
	}
	if ents, _ := os.ReadDir(filepath.Join(p.root, "tmp")); len(ents) != 0 {
		t.Errorf("case 60a: the pi run must remove its temp dir on exit, left %v", ents)
	}
	mustNotHave(t, "case 60a no shell error", r.both(), `unbound|not found|No such`)
}

func TestCase_piKitSections(t *testing.T) {
	t.Parallel()
	r, _ := goRun(t, "pi-big")
	mustHave(t, "case 61 kit sweeps (8 x 1200, capped) + a 6000-char target section", r.out, `^aggregate\[pi\]: [0-9]+ chars \(budget < 8000\) OVER BUDGET$`)
	mustHave(t, "case 61", r.out, `section\[big\.ts\] big-section chars=6000`)
	r, _ = goRun(t, "pi-none")
	mustHave(t, "case 62 a target without .pi/extensions measures the kit section alone", r.out, `^section\[research-sdd-hooks\.ts\]`)
	mustNotHave(t, "case 62", r.out, `ext\[|section\[card`)
	mustHave(t, "case 62", r.out, `^state: ok`)
}

func TestCase_piDegradedSections(t *testing.T) {
	t.Parallel()
	r, _ := goRun(t, "pi-broken")
	mustHave(t, "case 63 an extension that fails to load is degraded", r.out, `ext\[broken\.ts\] status=degraded\(load failed: .*boom at import`)
	mustHave(t, "case 63 and marks the aggregate partial (not 0 chars)", r.out, `aggregate\[pi\]: [0-9]+ chars .*\(partial: 1 degraded\)`)
	mustHave(t, "case 63", r.out, `^state: degraded`)
	r, _ = goRun(t, "pi-kit-missing")
	mustHave(t, "case 64 an unresolvable kit (the extension's own DEGRADED text) is measured but marked partial", r.out,
		`section\[research-sdd-hooks\.ts\].*status=degraded\(section text reports DEGRADED\)`)
	mustHave(t, "case 64", r.out, `partial: 1 degraded`)
	r, _ = goRun(t, "pi-slow-sweeps")
	mustHave(t, "case 64a sweeps that outlive the cap are measured but marked partial", r.out,
		`section\[research-sdd-hooks\.ts\].*status=degraded\(section text reports DEGRADED\)`)
	mustHave(t, "case 64a", r.out, `partial: 1 degraded`)
}

func TestCase_piAmbientEnv(t *testing.T) {
	t.Parallel()
	r, _ := goRun(t, "pi-ambient-env")
	mustHave(t, "case 65 GENTLE_PI_AGENTS_CHILD / RSDD_PI_HOOKS do not turn the kit extension off inside the probe", r.out, `section\[card\.ts\] card-section chars=2500`)
	mustHave(t, "case 65", r.out, `section\[research-sdd-hooks\.ts\] research-sdd-session chars=[1-9]`)
}

func TestCase_piBoth(t *testing.T) {
	t.Parallel()
	r, _ := goRun(t, "pi-both")
	mustHave(t, "case 66 --harness both prints the Claude report (absent-input here)", r.out, `^state: absent-input`)
	mustHave(t, "case 66 and then aggregate[pi]", r.out, `^aggregate\[pi\]: `)
}

func TestCase_piRoutes(t *testing.T) {
	t.Parallel()
	r, _ := goRun(t, "pi-routes")
	mustHave(t, "case 75 a returned message is counted", r.out, `^section\[msg\.ts\] message:note chars=300 status=ok`)
	mustHave(t, "case 75 a returned systemPrompt is unmeasured", r.out, `^ext\[sysprompt\.ts\] status=unmeasured\(returned systemPrompt`)
	mustHave(t, "case 75 an event.systemPrompt edit is unmeasured", r.out, `^ext\[mutate\.ts\] status=unmeasured\(mutated event\.systemPrompt`)
	mustHave(t, "case 75 marks the aggregate partial (never a 0-char OK)", r.out, `partial: 2 degraded`)
	mustHave(t, "case 75", r.out, `^state: degraded`)
}

func TestCase_piExit(t *testing.T) {
	t.Parallel()
	r, _ := goRun(t, "pi-exit")
	mustHave(t, "case 76 an extension that calls process.exit leaves a missing marker / short record set", r.out,
		`^harness: degraded\(incomplete record set: 1 of 2 extensions finished, closing marker missing\)`)
	mustHave(t, "case 76", r.out, `^section\[research-sdd-hooks\.ts\]`)
	mustHave(t, "case 76", r.out, `partial: 1 degraded`)
	mustHave(t, "case 76", r.out, `^state: degraded`)
}

func TestCase_piHang(t *testing.T) {
	t.Parallel()
	r, _ := goRun(t, "pi-hang")
	mustHave(t, "case 77 one hanging extension yields its own degraded line", r.out, `^ext\[hang\.ts\] status=degraded\(before_agent_start failed: timed out`)
	mustHave(t, "case 77 the kit section is still measured", r.out, `^section\[research-sdd-hooks\.ts\]`)
	mustNotHave(t, "case 77 no run-wide timeout", r.out, `pi: DEGRADED`)
}

func TestCase_piSub(t *testing.T) {
	t.Parallel()
	r, _ := goRun(t, "pi-sub")
	mustHave(t, "case 78 section names are paths below .pi/extensions", r.out, `^section\[index\.ts\] idx-root chars=10`)
	mustHave(t, "case 78", r.out, `^section\[tools/index\.ts\] idx-tools chars=20`)
}

func TestCase_piNoDotClaude(t *testing.T) {
	t.Parallel()
	c := caseByName(t, "pi-nodot-git")
	c.gate(t)
	p := c.prepare(t, "")
	before := snapshot(t, p.target)
	r := runGo(append([]string{"--toolbelt", p.toolbelt}, p.args...), p.env, p.root)
	after := snapshot(t, p.target)
	mustHave(t, "case 79 a corpus target with NO .claude is measured like one with a copy bound", r.out, `^section\[research-sdd-hooks\.ts\] research-sdd-session chars=[1-9][0-9]* status=ok`)
	mustHave(t, "case 79", r.out, `^state: ok`)
	// the .git directory is created by prep, before the snapshot
	if before != after || isDir(filepath.Join(p.target, ".claude")) {
		t.Errorf("case 79: target untouched and no .claude created in it")
	}
}

func TestCase_piForgery(t *testing.T) {
	t.Parallel()
	c := caseByName(t, "pi-evil")
	c.gate(t)
	p := c.prepare(t, "")
	r := runGo(append([]string{"--toolbelt", p.toolbelt}, p.args...), p.env, p.root)
	if hasFile(filepath.Join(p.root, "canary-evil")) {
		t.Errorf("case 82: a forged record ran a command (canary created)")
	}
	mustNotHave(t, "case 82 forged section not believed", r.out, `section\[evil\.ts\]`)
	mustHave(t, "case 82", r.out, `^harness: degraded\([0-9]+ unauthenticated or malformed record`)
	mustHave(t, "case 82", r.out, `partial: `)
	mustHave(t, "case 82", r.out, `^state: degraded`)

	c = caseByName(t, "pi-forged-record")
	c.gate(t)
	p = c.prepare(t, "")
	r = runGo(append([]string{"--toolbelt", p.toolbelt}, p.args...), p.env, p.root)
	if hasFile(filepath.Join(p.root, "canary-forge")) {
		t.Errorf("case 83: a record with the CORRECT nonce and a non-numeric chars field was evaluated (canary created)")
	}
	mustHave(t, "case 83 a non-numeric field is never evaluated", r.out, `^harness: degraded\(1 unauthenticated or malformed record`)
	mustHave(t, "case 83", r.out, `partial: `)
}

// --- the helper alone (old cases 67-74): lib/session-budget-pi.mjs stays in Node and is exercised directly ---

func runHelper(t *testing.T, waitMS string, cwd string, files ...string) []string {
	t.Helper()
	needNode(t)
	c := exec.Command("node", append([]string{abs(t, piHelperRel), cwd}, files...)...)
	c.Stdin = strings.NewReader("N\n")
	c.Env = os.Environ()
	if waitMS != "" {
		c.Env = append(c.Env, "RSDD_BUDGET_PI_WAIT_MS="+waitMS)
	}
	out, _ := c.Output()
	var lines []string
	for _, l := range strings.Split(strings.TrimRight(string(out), "\n"), "\n") {
		lines = append(lines, strings.TrimPrefix(l, "N\t"))
	}
	return lines
}

func helperDir(t *testing.T) (dir string, files map[string]string) {
	dir = scratch(t, "")
	files = map[string]string{
		"a-emoji.ts":    `export default (pi: any) => pi.on("before_agent_start", async (e: any) => { e.systemPromptOptions.sections["emoji"] = "\u{1F600}".repeat(10); });`,
		"b-pending.ts":  `export default (pi: any) => pi.on("before_agent_start", async (e: any) => { e.systemPromptOptions.sections["p"] = "x sweeps pending (started now)"; });`,
		"c-degraded.ts": `export default (pi: any) => pi.on("before_agent_start", async (e: any) => { e.systemPromptOptions.sections["d"] = "hook DEGRADED: gone"; });`,
		"d-silent.ts":   `export default (pi: any) => pi.on("before_agent_start", async () => {});`,
		"e-throws.ts":   `export default (pi: any) => pi.on("before_agent_start", async () => { throw new Error("handler boom"); });`,
	}
	for n, c := range files {
		write(t, filepath.Join(dir, n), c+"\n", 0o644)
	}
	return dir, files
}

func TestHelper_flagsAndRecords(t *testing.T) {
	t.Parallel()
	dir, _ := helperDir(t)
	f := func(n string) string { return filepath.Join(dir, n) }
	r := runHelper(t, "", dir, f("a-emoji.ts"), f("b-pending.ts"), f("c-degraded.ts"), f("d-silent.ts"), f("e-throws.ts"))
	j := strings.Join(r, "\n")
	mustHave(t, "case 67 the helper counts code points (10 emoji = 10, not 20 UTF-16 units)", j, `^S.a-emoji\.ts.emoji.10.ok$`)
	mustHave(t, "case 68 flags 'sweeps pending'", j, `^S.b-pending\.ts.p.[0-9]+.pending$`)
	mustHave(t, "case 68 flags DEGRADED section text", j, `^S.c-degraded\.ts.d.[0-9]+.degraded-text$`)
	mustHave(t, "case 69 a silent extension is T 0", j, `^T.d-silent\.ts.0$`)
	mustHave(t, "case 69 a throwing handler is an E record, not a zero", j, `^E.e-throws\.ts.before_agent_start failed: handler boom`)
	finals := 0
	for _, l := range r {
		if strings.HasPrefix(l, "T\t") || strings.HasPrefix(l, "E\t") {
			finals++
		}
	}
	if finals != 5 || r[len(r)-1] != "Z\t5" {
		t.Errorf("case 70: every extension gets exactly one final T or E record and the output ends with 'Z <n>': %q", r)
	}
}

func TestHelper_routes(t *testing.T) {
	t.Parallel()
	dir, _ := helperDir(t)
	fx := filepath.Join(abs(t, fixturesRel), "pi-routes", ".pi", "extensions")
	r := strings.Join(runHelper(t, "", dir, filepath.Join(fx, "msg.ts"), filepath.Join(fx, "sysprompt.ts"), filepath.Join(fx, "mutate.ts")), "\n")
	mustHave(t, "case 71 a returned message's content is counted as a section (300 chars)", r, `^S.msg\.ts.message:note.300.ok$`)
	mustHave(t, "case 72 a returned systemPrompt is typed U", r, `^U.sysprompt\.ts.returned systemPrompt`)
	mustHave(t, "case 72 an event.systemPrompt edit is typed U", r, `^U.mutate\.ts.mutated event\.systemPrompt`)
	mustNotHave(t, "case 72 never a 0-char success", r, `^T.(sysprompt|mutate)\.ts.[1-9]`)
}

func TestHelper_waitAndNames(t *testing.T) {
	t.Parallel()
	dir, _ := helperDir(t)
	fx := abs(t, fixturesRel)
	r := runHelper(t, "500", dir, filepath.Join(fx, "pi-hang", ".pi", "extensions", "hang.ts"), filepath.Join(fx, "pi-card", ".pi", "extensions", "card.ts"))
	j := strings.Join(r, "\n")
	mustHave(t, "case 73 a hanging handler yields ITS OWN E record after the per-handler wait", j, `^E.hang\.ts.before_agent_start failed: timed out after 500ms`)
	mustHave(t, "case 73 the next extension is still measured", j, `^S.card\.ts.card-section.2500.ok`)
	if r[len(r)-1] != "Z\t2" {
		t.Errorf("case 73: closing marker: %q", r)
	}
	r = runHelper(t, "", dir, filepath.Join(fx, "pi-sub", ".pi", "extensions", "index.ts"), filepath.Join(fx, "pi-sub", ".pi", "extensions", "tools", "index.ts"))
	j = strings.Join(r, "\n")
	mustHave(t, "case 74 extension names are paths below .pi/extensions", j, `^S.index\.ts.idx-root.10`)
	mustHave(t, "case 74", j, `^S.tools/index\.ts.idx-tools.20`)
}
