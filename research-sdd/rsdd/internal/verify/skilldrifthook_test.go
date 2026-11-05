//go:build unix

package verify

import (
	"bytes"
	"encoding/json"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/hookenv"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/gitfixture"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// The SessionStart hook of verify skill-drift: silent unless something needs saying, then one envelope whose
// text is a header, the drift check's own lines and the surfaced `install --verify` / kit-staleness lines.

// envelopeOf is the SessionStart envelope the hook prints for ctx.
func envelopeOf(ctx string) string {
	var b bytes.Buffer
	hookenv.WriteSessionStart(&b, ctx)
	return b.String()
}

const (
	hdrInstall = "WARN: research-sdd install --verify reports issues — see lines below"
	hdrStale   = "WARN: research-sdd SKILL.md stale for one or more harnesses — run the fix command(s) shown"
	hdrCannot  = "ERROR: verify-skill-drift.sh could not run for one or more harnesses — check kit install/adapters.sh"
)

// installStub writes an executable that stands in for research-sdd-install.sh and points the hook at it.
func (w *sdWorld) installStub(body string) string {
	w.t.Helper()
	p := w.put(filepath.Join(w.root, "install-stub.sh"), "#!/usr/bin/env bash\n"+body+"\n", 0o755)
	w.env["RESEARCH_SDD_INSTALL_VERIFY_CMD"] = p
	return p
}

func (w *sdWorld) wantHook(ctx string) {
	w.t.Helper()
	out, errs, rc := w.runGoHook()
	want := ""
	if ctx != "" {
		want = envelopeOf(ctx)
	}
	if out != want || errs != "" || rc != 0 {
		w.t.Errorf("hook\ngot rc=%d\nstdout %q\nstderr %q\nwant stdout %q", rc, out, errs, want)
	}
}

func hookWorld(t *testing.T) *sdWorld {
	w := newSDWorld(t)
	w.installStub("exit 0")
	return w
}

func TestSkillDriftHookIsSilentWhenNothingNeedsSaying(t *testing.T) {
	w := hookWorld(t)
	w.wantHook("") // nothing deployed
	w.deploy(claudeRel, sdKitSkill)
	w.wantHook("") // in sync
	w.installStub("echo 'verify harness=claude status=match'; echo 'verify kit status=current'; echo 'verify kit status=degraded reason=tarball'")
	w.wantHook("") // only silent findings
}

func TestSkillDriftHookDriftAndCouldNotRun(t *testing.T) {
	w := hookWorld(t)
	w.deploy(claudeRel, "stale\n")
	w.wantHook(hdrStale + "\n" +
		"verify-skill-drift: fix: research-sdd-install.sh --harness claude --force-skill  # deployed: ~/.claude/skills/research-sdd/SKILL.md\n" +
		"verify-skill-drift: all: checked=3 in-sync=0 diverged=1 absent=2 could-not-run=0")

	w2 := hookWorld(t)
	w2.env["HOME"] = ""
	w2.wantHook(hdrCannot + "\n" +
		"verify-skill-drift: could-not-run: HOME is unset or empty and no --home given")
}

func TestSkillDriftHookSurfacesInstallVerifyFindings(t *testing.T) {
	w := hookWorld(t)
	w.installStub(`cat <<'EOF'
verify harness=pi status=degraded reason=no-profiles
verify harness=claude status=match
verify kit status=behind by 3
verify harness=gentle-shell status=degraded reason=x
verify harness=a status=degraded 4
verify harness=b status=degraded 5
EOF`)
	w.wantHook(hdrInstall + "\n" +
		"verify harness=pi status=degraded reason=no-profiles\n" +
		"verify kit status=behind by 3\n" +
		"verify harness=gentle-shell status=degraded reason=x\n" +
		"verify harness=a status=degraded 4") // at most 4 lines
}

func TestSkillDriftHookTypedLinesAreCutTo170Characters(t *testing.T) {
	w := hookWorld(t)
	long := "verify harness=pi status=degraded " + strings.Repeat("x", 300)
	w.installStub("echo '" + long + "'")
	w.wantHook(hdrInstall + "\n" + long[:170])
}

func TestSkillDriftHookDriftBlock(t *testing.T) {
	w := hookWorld(t)
	w.installStub(`echo 'verify harness=claude status=drift drifted=a.md,(extra: TARGETS.md -> /x),b.md,c.md,d.md,e.md kept-hand-edit=f.md,g.md'
echo 'verify harness=pi status=drift drifted=only.md'
echo 'verify harness=gentle-shell status=drift no-members-field'`)
	w.wantHook(hdrInstall + "\n" +
		"verify harness=claude status=drift\n" +
		"  - (extra: TARGETS.md -> /x)\n" +
		"  - a.md\n" +
		"  - b.md\n" +
		"  (+3 more - run research-sdd-install.sh --verify for the full list)\n" +
		"  kept-hand-edit: f.md,g.md\n" +
		"verify harness=pi status=drift\n" +
		"  - only.md\n" +
		"verify harness=gentle-shell status=drift no-members-field")
}

func TestSkillDriftHookDriftBlockWidths(t *testing.T) {
	w := hookWorld(t)
	ent, kept := strings.Repeat("e", 400), strings.Repeat("k", 400)
	w.installStub("echo 'verify harness=claude status=drift drifted=" + ent + " kept-hand-edit=" + kept + "'\necho 'verify harness=pi status=drift " + ent + "'")
	w.wantHook(hdrInstall + "\n" +
		"verify harness=claude status=drift\n" +
		"  - " + ent[:280] + "\n" +
		"  kept-hand-edit: " + kept[:160] + "\n" +
		("verify harness=pi status=drift " + ent)[:280])
}

func TestSkillDriftHookInstallVerifyFailureIsNeverSilent(t *testing.T) {
	w := hookWorld(t)
	w.installStub("echo 'nothing typed'; exit 3")
	w.wantHook(hdrInstall + "\nverify: install --verify exited 3 with no typed line")

	w.installStub("echo 'verify harness=pi status=degraded reason=x'; exit 3") // a typed line is enough
	w.wantHook(hdrInstall + "\nverify harness=pi status=degraded reason=x")

	w.env["RESEARCH_SDD_INSTALL_VERIFY_CMD"] = filepath.Join(w.root, "no-such-install.sh")
	w.wantHook(hdrInstall + "\nverify: install --verify could not run (not executable: no-such-install.sh)")
}

func TestSkillDriftHookInstallVerifyIsBounded(t *testing.T) {
	w := hookWorld(t)
	w.installStub("exec sleep 30")
	w.env["RESEARCH_SDD_INSTALL_VERIFY_TIMEOUT"] = "1"
	start := time.Now()
	w.wantHook(hdrInstall + "\nverify: install --verify timed out (RESEARCH_SDD_INSTALL_VERIFY_TIMEOUT, default 10s; on the pure-bash watchdog path the bound is that value plus up to ~0.5 s of sleep-probe time)")
	if d := time.Since(start); d > 15*time.Second {
		t.Errorf("the hook took %v with a 1 s bound", d)
	}
}

func TestSkillDriftHookInvalidTimeoutIsAnnounced(t *testing.T) {
	w := hookWorld(t)
	for raw, shown := range map[string]string{"": " (empty)", "abc": "='abc'", "0": "='0'", "10s": "='10s'", "-1": "='-1'", "1234567": "='1234567'", ".5": "='.5'"} {
		w.env["RESEARCH_SDD_INSTALL_VERIFY_TIMEOUT"] = raw
		w.wantHook(hdrInstall + "\nverify: invalid RESEARCH_SDD_INSTALL_VERIFY_TIMEOUT" + shown + ", using 10s")
	}
	w.env["RESEARCH_SDD_INSTALL_VERIFY_TIMEOUT"] = "007" // base 10, valid
	w.wantHook("")
	w.env["RESEARCH_SDD_INSTALL_VERIFY_TIMEOUT"] = "a b;$(touch " + filepath.Join(w.root, "pwned") + ")"
	out, _, _ := w.runGoHook()
	if !strings.Contains(out, "invalid RESEARCH_SDD_INSTALL_VERIFY_TIMEOUT='abtouch") || strings.Contains(out, "$(") {
		t.Errorf("the env value is not sanitised in the note: %q", out)
	}
	if _, err := os.Stat(filepath.Join(w.root, "pwned")); err == nil {
		t.Error("the env value was executed")
	}
}

// git helpers for the kit-staleness scenarios

func (w *sdWorld) git(dir string, args ...string) string {
	w.t.Helper()
	cmd := exec.Command("git", append([]string{"-C", dir}, args...)...)
	cmd.Env = gitfixture.Env(append(w.environ(), "GIT_AUTHOR_NAME=t", "GIT_AUTHOR_EMAIL=t@example.invalid", "GIT_COMMITTER_NAME=t", "GIT_COMMITTER_EMAIL=t@example.invalid")) // no background maintenance racing the fixture (kit issue #2624)
	out, err := cmd.CombinedOutput()
	if err != nil {
		w.t.Fatalf("git %v: %v: %s", args, err, out)
	}
	return strings.TrimSpace(string(out))
}

// gitKit builds a kit checkout under the world's home that tracks origin/main and is `behind` commits behind
// it after a fetch (so FETCH_HEAD exists, stamped now).
func (w *sdWorld) gitKit(behind int) string {
	w.t.Helper()
	origin, seed, kit := filepath.Join(w.root, "origin.git"), filepath.Join(w.root, "seed"), filepath.Join(w.home, "kitrepo")
	w.git(w.root, "init", "-q", "--bare", "-b", "main", origin)
	w.git(w.root, "init", "-q", "-b", "main", seed)
	w.put(filepath.Join(seed, "f.txt"), "1\n", 0o644)
	w.git(seed, "add", "-A")
	w.git(seed, "commit", "-q", "-m", "c0")
	w.git(seed, "remote", "add", "origin", origin)
	w.git(seed, "push", "-q", "-u", "origin", "main")
	w.git(w.root, "clone", "-q", origin, kit)
	for i := 0; i < behind; i++ {
		w.put(filepath.Join(seed, "f.txt"), strings.Repeat("x", i+2), 0o644)
		w.git(seed, "commit", "-q", "-am", "next")
	}
	w.git(seed, "push", "-q", "origin", "main")
	w.git(kit, "fetch", "-q")
	w.env["RESEARCH_SDD_KIT_DIR"] = kit
	delete(w.env, "RESEARCH_SDD_KIT_STALE_CHECK")
	return kit
}

func (w *sdWorld) ageFetchHead(kit string, days int) {
	w.t.Helper()
	old := time.Now().Add(-time.Duration(days) * 24 * time.Hour)
	if err := os.Chtimes(filepath.Join(kit, ".git", "FETCH_HEAD"), old, old); err != nil {
		w.t.Fatal(err)
	}
}

func TestSkillDriftHookKitStaleness(t *testing.T) {
	w := hookWorld(t)
	kit := w.gitKit(3)
	w.wantHook("") // 3 behind, a fresh fetch: within both thresholds

	w.env["RESEARCH_SDD_KIT_STALE_MAX_COMMITS"] = "2"
	disp := "~/kitrepo"
	w.wantHook(hdrInstall + "\n" + staleLine(disp, "pull --ff-only", "3", "2", "0", "7"))

	// a long kit path cuts the tail, never the command, and the line stays within 200 characters
	long := filepath.Join(w.home, strings.Repeat("d", 80), "kitrepo")
	if err := os.MkdirAll(filepath.Dir(long), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(kit, long); err != nil {
		t.Fatal(err)
	}
	w.env["RESEARCH_SDD_KIT_DIR"] = long
	var env struct {
		HookSpecificOutput struct {
			AdditionalContext string `json:"additionalContext"`
		} `json:"hookSpecificOutput"`
	}
	if err := json.Unmarshal([]byte(w.hookContext()), &env); err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(env.HookSpecificOutput.AdditionalContext, "\n")
	stale := lines[len(lines)-1]
	if !strings.HasPrefix(stale, "verify kit-stale status=stale fix (no live session): git -C ~/"+strings.Repeat("d", 80)+"/kitrepo pull --ff-only") || len([]rune(stale)) != 200 {
		t.Errorf("stale line (%d chars) is not the command followed by a tail cut to 200: %q", len([]rune(stale)), stale)
	}
	if err := os.Rename(long, kit); err != nil {
		t.Fatal(err)
	}
	w.env["RESEARCH_SDD_KIT_DIR"] = kit

	// age alone: 10 days since the last fetch, thresholds otherwise fine
	delete(w.env, "RESEARCH_SDD_KIT_STALE_MAX_COMMITS")
	w.ageFetchHead(kit, 10)
	w.wantHook(hdrInstall + "\n" + staleLine(disp, "pull --ff-only", "3", "20", "10", "7"))

	// install --verify's own behind line is replaced by this check's verdict, within thresholds too
	w.ageFetchHead(kit, 0)
	w.installStub("echo 'verify kit status=behind by 3'")
	w.wantHook("")
	// ... except a diverged one, which stays and replaces the stale line
	w.env["RESEARCH_SDD_KIT_STALE_MAX_COMMITS"] = "0"
	w.installStub("echo 'verify kit status=behind diverged from origin/main'")
	w.wantHook(hdrInstall + "\nverify kit status=behind diverged from origin/main")
	// ... and a failing install --verify is never silenced by that dedupe
	w.installStub("echo 'verify kit status=behind by 3'; exit 4")
	w.wantHook(hdrInstall + "\nverify: install --verify exited 4 with no typed line\n" + staleLine(disp, "pull --ff-only", "3", "0", "0", "7"))
}

// The thresholds are "more than": exactly the limit is not stale, one past it is.
func TestSkillDriftHookKitStalenessLimitsAreExclusive(t *testing.T) {
	w := hookWorld(t)
	kit := w.gitKit(2)
	w.env["RESEARCH_SDD_KIT_STALE_MAX_COMMITS"] = "2"
	w.wantHook("") // behind == max
	w.env["RESEARCH_SDD_KIT_STALE_MAX_COMMITS"] = "1"
	w.wantHook(hdrInstall + "\n" + staleLine("~/kitrepo", "pull --ff-only", "2", "1", "0", "7")) // behind > max

	delete(w.env, "RESEARCH_SDD_KIT_STALE_MAX_COMMITS")
	w.ageFetchHead(kit, 7)
	w.wantHook("") // age == max days
	w.ageFetchHead(kit, 8)
	w.wantHook(hdrInstall + "\n" + staleLine("~/kitrepo", "pull --ff-only", "2", "20", "8", "7")) // age > max days
}

func staleLine(disp, fix, behind, max, age, maxDays string) string {
	head := "verify kit-stale status=stale fix (no live session): git -C " + disp + " " + fix
	tail := "; behind=" + behind + " (max " + max + ") fetch_age=" + age + "d (max " + maxDays + "d); local refs, may understate"
	if room := 200 - len([]rune(head)); room < len([]rune(tail)) {
		if room < 0 {
			room = 0
		}
		tail = string([]rune(tail)[:room])
	}
	return head + tail
}

func (w *sdWorld) hookContext() string {
	out, _, _ := w.runGoHook()
	return out
}

func TestSkillDriftHookKitStalenessFallsBackToOriginMain(t *testing.T) {
	w := hookWorld(t)
	kit := w.gitKit(2)
	w.git(kit, "branch", "--unset-upstream")
	w.env["RESEARCH_SDD_KIT_STALE_MAX_COMMITS"] = "1"
	w.wantHook(hdrInstall + "\n" + staleLine("~/kitrepo", "fetch && git -C ~/kitrepo merge --ff-only origin/main", "2", "1", "0", "7"))
}

func TestSkillDriftHookKitStalenessUnmeasurableIsSilentUnlessVerbose(t *testing.T) {
	w := hookWorld(t)
	notGit := filepath.Join(w.root, "tarball")
	if err := os.MkdirAll(notGit, 0o755); err != nil {
		t.Fatal(err)
	}
	delete(w.env, "RESEARCH_SDD_KIT_STALE_CHECK")
	w.env["RESEARCH_SDD_KIT_DIR"] = notGit
	w.wantHook("")
	w.env["RESEARCH_SDD_KIT_STALE_VERBOSE"] = "1"
	w.wantHook(hdrInstall + "\nverify kit-stale status=degraded reason=kit dir is not a git checkout (tarball install?)")

	kit := w.gitKit(0)
	w.git(kit, "branch", "--unset-upstream")
	w.git(kit, "remote", "remove", "origin")
	w.wantHook(hdrInstall + "\nverify kit-stale status=degraded reason=no upstream ref (no @{upstream}, no origin/main); cannot tell whether the kit is behind")

	w2 := hookWorld(t)
	k2 := w2.gitKit(0)
	if err := os.Remove(filepath.Join(k2, ".git", "FETCH_HEAD")); err != nil {
		t.Fatal(err)
	}
	w2.env["RESEARCH_SDD_KIT_STALE_VERBOSE"] = "1"
	w2.wantHook(hdrInstall + "\nverify kit-stale status=degraded reason=no FETCH_HEAD (never fetched): age criterion skipped, judged by commit count only (behind=0 of max 20)")
}

func TestSkillDriftHookKitStalenessGitMissingIsTyped(t *testing.T) {
	w := hookWorld(t)
	delete(w.env, "RESEARCH_SDD_KIT_STALE_CHECK")
	w.env["RESEARCH_SDD_KIT_STALE_VERBOSE"] = "1"
	w.env["RESEARCH_SDD_KIT_DIR"] = w.kit
	empty := filepath.Join(w.root, "emptybin")
	if err := os.MkdirAll(empty, 0o755); err != nil {
		t.Fatal(err)
	}
	w.env["PATH"] = empty
	w.env["RESEARCH_SDD_INSTALL_VERIFY_CMD"] = w.put(filepath.Join(w.root, "sh-stub.sh"), "#!/bin/sh\nexit 0\n", 0o755) // no env, no bash on this PATH
	w.wantHook(hdrInstall + "\nverify kit-stale status=degraded reason=git not found; cannot tell whether the kit is behind its upstream")
}

func TestSkillDriftHookInvalidStaleThresholdsAreAnnounced(t *testing.T) {
	w := hookWorld(t)
	delete(w.env, "RESEARCH_SDD_KIT_STALE_CHECK")
	w.env["RESEARCH_SDD_KIT_DIR"] = w.kit
	w.env["RESEARCH_SDD_KIT_STALE_MAX_COMMITS"] = "ten"
	w.env["RESEARCH_SDD_KIT_STALE_MAX_DAYS"] = ""
	w.wantHook(hdrInstall + "\nverify kit-stale: invalid RESEARCH_SDD_KIT_STALE_MAX_COMMITS='ten', using 20\nverify kit-stale: invalid RESEARCH_SDD_KIT_STALE_MAX_DAYS='', using 7")
}

func TestSkillDriftHookKitStaleCheckOffSkipsIt(t *testing.T) {
	w := hookWorld(t)
	w.gitKit(5)
	w.env["RESEARCH_SDD_KIT_STALE_MAX_COMMITS"] = "1"
	w.env["RESEARCH_SDD_KIT_STALE_CHECK"] = "off"
	w.wantHook("")
}

// A killed install --verify reads as the shell's 128+signal. (The frozen script prints the same envelope, plus
// the shell's own "Killed" job notice on stderr, which is why this is not in the differential.)
func TestSkillDriftHookInstallKilledBySignal(t *testing.T) {
	w := hookWorld(t)
	w.installStub("kill -9 $$")
	w.wantHook(hdrInstall + "\nverify: install --verify exited 137 with no typed line")
}

func TestSkillDriftHookResolvesTheKitWhenNoDirIsGiven(t *testing.T) {
	// an unresolvable kit never fails the session: silence, exit 0
	w := hookWorld(t)
	var out, errb bytes.Buffer
	delete(w.env, "RESEARCH_SDD_KIT")
	w.env["HOME"] = filepath.Join(w.root, "nohome")
	rc := RunSkillDrift([]string{"--hook"}, w.stdio(&out, &errb))
	if rc != 0 || out.Len() != 0 {
		t.Errorf("rc=%d stdout=%q stderr=%q", rc, out.String(), errb.String())
	}
}
