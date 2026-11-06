//go:build unix

package verify

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/hookenv"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/gitfixture"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/execfile"
)

// sandbox is one test's world: a HOME, a PATH holding only the tools the scripts need, and a fixed git
// environment, so nothing of the developer's configuration reaches git.
type sandbox struct {
	t    *testing.T
	home string
	path string
	env  map[string]string
}

func newSandbox(t *testing.T) *sandbox {
	t.Helper()
	dirs := map[string]bool{}
	var path []string
	for _, tool := range []string{"git", "bash", "jq", "cat", "basename", "dirname", "grep", "readlink", "env"} {
		p, err := exec.LookPath(tool)
		if err != nil {
			t.Fatalf("%s is required (a skipped differential proves nothing): %v", tool, err)
		}
		if d := filepath.Dir(p); !dirs[d] {
			dirs[d] = true
			path = append(path, d)
		}
	}
	home := t.TempDir()
	sb := &sandbox{t: t, home: home, path: strings.Join(path, ":")}
	sb.env = map[string]string{
		"PATH": sb.path, "HOME": home, "LC_ALL": "C", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
		"GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.invalid", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.invalid",
	}
	return sb
}

func (sb *sandbox) environ() []string {
	var e []string
	for k, v := range sb.env {
		e = append(e, k+"="+v)
	}
	return e
}

// git runs a fixture git command and fails the test when it fails.
func (sb *sandbox) git(dir string, args ...string) {
	sb.t.Helper()
	cmd := exec.Command("git", append([]string{"-C", dir}, args...)...)
	cmd.Env = gitfixture.Env(sb.environ()) // no background maintenance racing the fixture (kit issue #2624)
	if out, err := cmd.CombinedOutput(); err != nil {
		sb.t.Fatalf("git %v: %v: %s", args, err, out)
	}
}

// write puts an executable (a stub the kit-clean run may exec) under the fork lock (ETXTBSY, testkit/execfile).
func (sb *sandbox) write(path, text string) {
	sb.t.Helper()
	execfile.Write(sb.t, path, text)
}

// repo makes a committed repository on branch main with files, pushed (with -u when track) to a bare origin.
func (sb *sandbox) repo(name string, track bool, files map[string]string) string {
	sb.t.Helper()
	d := filepath.Join(sb.home, name)
	sb.git(sb.home, "init", "-q", "-b", "main", d)
	if len(files) == 0 {
		files = map[string]string{"f.txt": "x\n"}
	}
	for p, c := range files {
		sb.write(filepath.Join(d, p), c)
	}
	sb.git(d, "add", "-A")
	sb.git(d, "commit", "-q", "-m", "init")
	origin := d + ".origin.git"
	sb.git(sb.home, "init", "-q", "--bare", origin)
	sb.git(d, "remote", "add", "origin", origin)
	if track {
		sb.git(d, "push", "-q", "-u", "origin", "main")
	} else {
		sb.git(d, "push", "-q", "origin", "main")
	}
	return d
}

// run executes the Go command through the dispatcher, as the binary does.
func (sb *sandbox) run(args ...string) (stdout, stderr string, rc int) {
	var out, errb bytes.Buffer
	s := cli.Stdio{
		In: strings.NewReader(""), Out: &out, Err: &errb,
		Env:   func(k string) string { return sb.env[k] },
		Clock: func() time.Time { return time.Unix(0, 0) },
		Cwd:   sb.home,
	}
	rc = cli.Run(Commands, args, s)
	return out.String(), errb.String(), rc
}

func TestKitCleanReports(t *testing.T) {
	t.Parallel()
	sb := newSandbox(t)
	clean := sb.repo("clean", true, nil)
	dirty := sb.repo("dirty", true, nil)
	sb.write(filepath.Join(dirty, "f.txt"), "changed\n")
	untracked := sb.repo("untracked", true, nil)
	sb.write(filepath.Join(untracked, "extra.txt"), "n\n")
	mixed := sb.repo("mixed", true, nil)
	sb.write(filepath.Join(mixed, "f.txt"), "changed\n")
	sb.write(filepath.Join(mixed, "staged.txt"), "s\n")
	sb.git(mixed, "add", "staged.txt")
	sb.write(filepath.Join(mixed, "u1.txt"), "1\n")
	sb.write(filepath.Join(mixed, "u2.txt"), "2\n")
	unpushed := sb.repo("unpushed", true, nil)
	sb.write(filepath.Join(unpushed, "g.txt"), "y\n")
	sb.git(unpushed, "add", "-A")
	sb.git(unpushed, "commit", "-q", "-m", "local")
	noU := sb.repo("nou", false, nil)
	sb.write(filepath.Join(noU, "h.txt"), "z\n")
	sb.git(noU, "add", "-A")
	sb.git(noU, "commit", "-q", "-m", "local")
	noUpstream := filepath.Join(sb.home, "noup")
	sb.git(sb.home, "init", "-q", "-b", "main", noUpstream)
	sb.write(filepath.Join(noUpstream, "f.txt"), "x\n")
	sb.git(noUpstream, "add", "-A")
	sb.git(noUpstream, "commit", "-q", "-m", "init")
	audits := sb.repo("audits", true, nil)
	if err := os.Mkdir(filepath.Join(audits, "audits"), 0o755); err != nil {
		t.Fatal(err)
	}
	notGit := filepath.Join(sb.home, "notgit")
	if err := os.Mkdir(notGit, 0o755); err != nil {
		t.Fatal(err)
	}

	const okTail = "   verdict      : clean — safe to stage a retro / start clean kit work\n== exit 0 ==\n"
	const badTail = "   verdict      : NOT clean — commit/stash + push before staging a retro (else mixed history)\n== exit 1 ==\n"
	const warnAudits = "   WARN: audits/ exists at the kit/supervisor root — audits are TARGET-scoped only (§13 / PROMPT-AUDIT); this is likely mis-committed target evidence — relocate to <target>/audits/ or remove.\n"
	hdr := func(d, branch string) string {
		return "== verify-kit-clean: " + filepath.Base(d) + " (branch: " + branch + ") ==\n"
	}
	cases := []struct {
		name         string
		dir          string
		stdout, errs string
		rc           int
	}{
		{"clean", clean, hdr(clean, "main") + "   working tree : CLEAN\n   sync         : up to date with origin/main\n" + okTail, "", 0},
		{"modified", dirty, hdr(dirty, "main") + "   working tree : DIRTY — uncommitted: 0 staged · 1 unstaged · 0 untracked\n   sync         : up to date with origin/main\n" + badTail, "", 1},
		{"untracked", untracked, hdr(untracked, "main") + "   working tree : DIRTY — uncommitted: 0 staged · 0 unstaged · 1 untracked\n   sync         : up to date with origin/main\n" + badTail, "", 1},
		{"mixed counters", mixed, hdr(mixed, "main") + "   working tree : DIRTY — uncommitted: 1 staged · 1 unstaged · 2 untracked\n   sync         : up to date with origin/main\n" + badTail, "", 1},
		{"unpushed", unpushed, hdr(unpushed, "main") + "   working tree : CLEAN\n   sync         : 1 local commit(s) NOT pushed to origin/main\n" + badTail, "", 1},
		{"origin fallback without -u", noU, hdr(noU, "main") + "   working tree : CLEAN\n   sync         : 1 local commit(s) NOT pushed to origin/main\n" + badTail, "", 1},
		{"no upstream", noUpstream, hdr(noUpstream, "main") + "   working tree : CLEAN\n   sync         : (no upstream configured for main — nothing to be un-pushed against)\n" + okTail, "", 0},
		{"audits advisory keeps the verdict", audits, hdr(audits, "main") + "   working tree : CLEAN\n   sync         : up to date with origin/main\n" + warnAudits + okTail, "", 0},
		{"not a repo", notGit, "", "verify-kit-clean: not a git repo: " + notGit + "\n", 2},
		{"not a directory", filepath.Join(sb.home, "missing"), "", "usage: verify-kit-clean.sh [<kit-repo>]\n", 2},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			stdout, stderr, rc := sb.run("verify", "kit-clean", c.dir)
			if stdout != c.stdout || stderr != c.errs || rc != c.rc {
				t.Errorf("got rc=%d\nstdout:\n%s\nstderr:\n%s\nwant rc=%d\nstdout:\n%s\nstderr:\n%s", rc, stdout, stderr, c.rc, c.stdout, c.errs)
			}
		})
	}
}

// stubGit writes a PATH-first git that answers rev-parse itself and applies one rule to the rest.
func (sb *sandbox) stubGit(name, body string) string {
	d := filepath.Join(sb.home, name)
	sb.write(filepath.Join(d, "git"), "#!/usr/bin/env bash\n"+body)
	return d + ":" + sb.path
}

func TestKitCleanGitStatusFailureIsNotClean(t *testing.T) {
	t.Parallel()
	sb := newSandbox(t)
	sb.env["PATH"] = sb.stubGit("stub-status", `case "$*" in
  *rev-parse*--show-toplevel*) echo /tmp/fake-root; exit 0 ;;
  *rev-parse*--abbrev-ref*) echo main; exit 0 ;;
  *status*--porcelain*) exit 5 ;;
  *) exit 0 ;;
esac
`)
	dir := filepath.Join(sb.home, "gsf")
	if err := os.Mkdir(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	stdout, stderr, rc := sb.run("verify", "kit-clean", dir)
	if want := "== verify-kit-clean: fake-root (branch: main) ==\n"; stdout != want {
		t.Errorf("stdout = %q, want %q", stdout, want)
	}
	if want := "   git status failed (rc=5) — cannot determine cleanliness\n"; stderr != want || rc != 1 {
		t.Errorf("stderr = %q rc=%d, want %q rc=1", stderr, rc, want)
	}
}

func TestKitCleanCountersContradiction(t *testing.T) {
	t.Parallel()
	sb := newSandbox(t)
	sb.env["PATH"] = sb.stubGit("stub-contra", `case "$*" in
  *rev-parse*--show-toplevel*) echo /tmp/fake-r11; exit 0 ;;
  *rev-parse*--abbrev-ref*HEAD*) echo main; exit 0 ;;
  *status*--porcelain*) printf '?? newfile.txt\n'; exit 0 ;;
  *rev-parse*upstream*) exit 1 ;;
  *) exit 0 ;;
esac
`)
	dir := filepath.Join(sb.home, "contra")
	if err := os.Mkdir(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	stdout, _, rc := sb.run("verify", "kit-clean", dir)
	if want := "   WARN: DIRTY but all three counters read 0 — porcelain has 1 line(s); counters disagree\n"; !strings.Contains(stdout, want) || rc != 1 {
		t.Errorf("rc=%d stdout=%q, want rc 1 containing %q", rc, stdout, want)
	}
}

// Kit issue #1820: a SessionStart read must never take index.lock, so every git run carries GIT_OPTIONAL_LOCKS=0
// whatever the caller's environment says.
func TestKitCleanEveryGitCallCarriesOptionalLocksZero(t *testing.T) {
	t.Parallel()
	sb := newSandbox(t)
	realGit, _ := exec.LookPath("git")
	logf := filepath.Join(sb.home, "git.log")
	sb.env["PATH"] = sb.stubGit("stub-rec", `printf 'LOCKS=%s :: %s\n' "${GIT_OPTIONAL_LOCKS-UNSET}" "$*" >> "`+logf+`"
exec `+realGit+` "$@"
`)
	sb.env["GIT_OPTIONAL_LOCKS"] = "1" // the caller's value must not leak through
	d := sb.repo("locks", true, nil)
	sb.write(filepath.Join(d, "f.txt"), "changed\n")
	sb.write(filepath.Join(d, "new.txt"), "n\n")
	if err := os.WriteFile(logf, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	sb.run("verify", "kit-clean", d)
	b, err := os.ReadFile(logf)
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSpace(string(b)), "\n")
	if len(lines) < 7 {
		t.Fatalf("expected the rev-parse, status, diff, ls-files and rev-list reads, got %d calls:\n%s", len(lines), b)
	}
	for _, l := range lines {
		if !strings.HasPrefix(l, "LOCKS=0 :: ") {
			t.Errorf("git call without GIT_OPTIONAL_LOCKS=0: %s", l)
		}
	}
}

func TestKitCleanDefaultsToWorkingDirectory(t *testing.T) {
	t.Parallel()
	sb := newSandbox(t)
	d := sb.repo("cwdrepo", true, nil)
	var out, errb bytes.Buffer
	s := cli.Stdio{Out: &out, Err: &errb, Env: func(k string) string { return sb.env[k] }, Clock: time.Now, Cwd: d}
	for _, arg := range [][]string{nil, {""}} { // `${1:-default}`: an empty argument is a missing one
		out.Reset()
		if rc := RunKitClean(arg, s); rc != 0 || !strings.HasPrefix(out.String(), "== verify-kit-clean: cwdrepo (branch: main) ==\n") {
			t.Errorf("args %q: rc=%d out=%q", arg, rc, out.String())
		}
	}
}

func TestKitCleanGitMissingIsTypedDegraded(t *testing.T) {
	t.Parallel()
	sb := newSandbox(t)
	d := sb.repo("nogit", true, nil)
	sb.env["PATH"] = filepath.Join(sb.home, "empty-bin")
	_, stderr, rc := sb.run("verify", "kit-clean", d)
	if rc != 2 || !strings.Contains(stderr, "verify-kit-clean: degraded: git unavailable: ") || !strings.HasSuffix(stderr, "verify-kit-clean: not a git repo: "+d+"\n") {
		t.Errorf("rc=%d stderr=%q, want a typed degraded line before the legacy not-a-git-repo line", rc, stderr)
	}
}

func TestKitCleanHookEnvelope(t *testing.T) {
	t.Parallel()
	sb := newSandbox(t)
	clean := sb.repo("hclean", true, nil)
	dirty := sb.repo("hdirty", true, nil)
	sb.write(filepath.Join(dirty, "x.txt"), "n\n")
	notGit := filepath.Join(sb.home, "hnotgit")
	if err := os.Mkdir(notGit, 0o755); err != nil {
		t.Fatal(err)
	}
	if stdout, stderr, rc := sb.run("verify", "kit-clean-hook", clean); stdout != "" || stderr != "" || rc != 0 {
		t.Errorf("clean kit must be silent: rc=%d stdout=%q stderr=%q", rc, stdout, stderr)
	}
	stdout, _, rc := sb.run("verify", "kit-clean-hook", dirty)
	wantCtx := hdrNotClean + "\n== verify-kit-clean: hdirty (branch: main) ==\n   working tree : DIRTY — uncommitted: 0 staged · 0 unstaged · 1 untracked\n   sync         : up to date with origin/main\n" +
		"   verdict      : NOT clean — commit/stash + push before staging a retro (else mixed history)\n== exit 1 =="
	want := "{\n  \"hookSpecificOutput\": {\n    \"hookEventName\": \"SessionStart\",\n    \"additionalContext\": " + hookenv.JQString(wantCtx) + "\n  }\n}\n"
	if stdout != want || rc != 0 {
		t.Errorf("dirty: rc=%d got:\n%s\nwant:\n%s", rc, stdout, want)
	}
	stdout, _, rc = sb.run("verify", "kit-clean-hook", notGit)
	if rc != 0 || !strings.Contains(stdout, "Research-SDD kit-clean check could not run (exit 2 — misconfigured path or not a git repo):\\nverify-kit-clean: not a git repo: "+notGit) {
		t.Errorf("not a repo: rc=%d stdout=%s", rc, stdout)
	}
}

// git's environment-borne configuration reaches every git run as the script's whole environment did:
// GIT_CONFIG_COUNT with its GIT_CONFIG_KEY_<n>/GIT_CONFIG_VALUE_<n> pairs, and GIT_CONFIG_PARAMETERS (what
// `git -c` hands its children). A count without its pairs makes git die, which read as "not a git repo".
func TestKitCleanHonoursGitConfigEnvironment(t *testing.T) {
	t.Parallel()
	sb := newSandbox(t)
	clean := sb.repo("clean", true, nil)
	hidden := sb.repo("hidden", true, nil)
	sb.write(filepath.Join(hidden, "untracked.txt"), "u\n")

	sb.env["GIT_CONFIG_COUNT"] = "2"
	sb.env["GIT_CONFIG_KEY_0"] = "core.quotePath"
	sb.env["GIT_CONFIG_VALUE_0"] = "false"
	sb.env["GIT_CONFIG_KEY_1"] = "status.showUntrackedFiles"
	sb.env["GIT_CONFIG_VALUE_1"] = "no"
	out, errOut, rc := sb.run("verify", "kit-clean", clean)
	if rc != 0 || !strings.Contains(out, "working tree : CLEAN") {
		t.Fatalf("GIT_CONFIG_COUNT pairs: rc=%d stdout=%q stderr=%q, want rc 0 and a CLEAN tree", rc, out, errOut)
	}
	if out, errOut, rc = sb.run("verify", "kit-clean", hidden); rc != 0 || !strings.Contains(out, "working tree : CLEAN") {
		t.Fatalf("GIT_CONFIG_VALUE_1 not applied: rc=%d stdout=%q stderr=%q, want the untracked file hidden", rc, out, errOut)
	}

	for _, k := range []string{"GIT_CONFIG_COUNT", "GIT_CONFIG_KEY_0", "GIT_CONFIG_VALUE_0", "GIT_CONFIG_KEY_1", "GIT_CONFIG_VALUE_1"} {
		delete(sb.env, k)
	}
	sb.env["GIT_CONFIG_PARAMETERS"] = "'status.showUntrackedFiles'='no'"
	if out, errOut, rc = sb.run("verify", "kit-clean", hidden); rc != 0 || !strings.Contains(out, "working tree : CLEAN") {
		t.Fatalf("GIT_CONFIG_PARAMETERS not applied: rc=%d stdout=%q stderr=%q, want the untracked file hidden", rc, out, errOut)
	}
}
