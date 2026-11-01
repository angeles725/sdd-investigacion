//go:build unix

package verify

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"unicode/utf8"
)

// Differential tests: the legacy scripts (testdata/legacy, the bytes of verify-kit-clean.sh,
// verify-kit-clean-hook.sh and lib/hook-emit.sh before the port; the live ones are shims now) and the Go
// commands must print the same stdout, the same stderr and exit with the same code from the same repository
// states and environment. A missing bash, git or jq FAILS: a skipped differential proves nothing.

type observed struct {
	stdout, stderr string
	rc             int
}

// bash runs a legacy script (or any bash args) in the sandbox environment.
func (sb *sandbox) bash(dir string, args ...string) observed {
	sb.t.Helper()
	cmd := exec.Command("bash", args...)
	cmd.Dir = dir
	cmd.Env = sb.environ()
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	err := cmd.Run()
	rc := 0
	if ee, ok := err.(*exec.ExitError); ok {
		rc = ee.ExitCode()
	} else if err != nil {
		sb.t.Fatalf("bash %v: %v", args, err)
	}
	return observed{out.String(), errb.String(), rc}
}

func (sb *sandbox) golden(args ...string) observed {
	o := observed{}
	o.stdout, o.stderr, o.rc = sb.run(args...)
	return o
}

func legacy(t *testing.T, name string) string {
	t.Helper()
	p, err := filepath.Abs(filepath.Join("testdata", "legacy", name))
	if err != nil {
		t.Fatal(err)
	}
	return p
}

func same(t *testing.T, what string, want, got observed) {
	t.Helper()
	if want != got {
		t.Errorf("%s differs from the legacy script:\nlegacy rc=%d stdout=%q stderr=%q\n    go rc=%d stdout=%q stderr=%q",
			what, want.rc, want.stdout, want.stderr, got.rc, got.stdout, got.stderr)
	}
}

// states builds one repository per state, named by case, with the legacy hook and check committed inside it
// (the hook inspects its own directory) before the state is applied.
func (sb *sandbox) states() map[string]string {
	t := sb.t
	files := map[string]string{"keep.txt": "x\n"}
	for _, f := range []string{"verify-kit-clean.sh", "verify-kit-clean-hook.sh", "lib/hook-emit.sh"} {
		b, err := os.ReadFile(legacy(t, f))
		if err != nil {
			t.Fatal(err)
		}
		files[f] = string(b)
	}
	st := map[string]string{}
	mk := func(name string, track bool) string {
		d := sb.repo(name, track, files)
		st[name] = d
		return d
	}
	mk("clean", true)
	d := mk("modified", true)
	sb.write(filepath.Join(d, "keep.txt"), "changed\n")
	d = mk("untracked", true)
	sb.write(filepath.Join(d, "extra.txt"), "n\n")
	d = mk("staged", true)
	sb.write(filepath.Join(d, "s.txt"), "s\n")
	sb.git(d, "add", "s.txt")
	d = mk("mixed", true)
	sb.write(filepath.Join(d, "keep.txt"), "edited\n")
	sb.write(filepath.Join(d, "s.txt"), "s\n")
	sb.git(d, "add", "s.txt")
	sb.write(filepath.Join(d, "u 1.txt"), "1\n") // a path with a space
	sb.write(filepath.Join(d, "ü.txt"), "2\n")   // a path git quotes
	d = mk("unpushed", true)
	sb.write(filepath.Join(d, "g.txt"), "y\n")
	sb.git(d, "add", "-A")
	sb.git(d, "commit", "-q", "-m", "a")
	sb.write(filepath.Join(d, "h.txt"), "y\n")
	sb.git(d, "add", "-A")
	sb.git(d, "commit", "-q", "-m", "b")
	d = mk("fallback-ahead", false)
	sb.write(filepath.Join(d, "g.txt"), "y\n")
	sb.git(d, "add", "-A")
	sb.git(d, "commit", "-q", "-m", "a")
	d = mk("fallback-even", false)
	_ = d
	d = mk("audits", true)
	if err := os.Mkdir(filepath.Join(d, "audits"), 0o755); err != nil {
		t.Fatal(err)
	}
	d = mk("detached", true)
	sb.git(d, "checkout", "-q", "--detach")
	// a clone has refs/remotes/origin/HEAD: on a detached HEAD (branch "HEAD") the origin/<branch> fallback must
	// not read it as a remote branch, so the local commit is reported as "no upstream", not as unpushed
	cl := filepath.Join(sb.home, "clone-detached")
	sb.git(st["clean"]+".origin.git", "symbolic-ref", "HEAD", "refs/heads/main") // so the clone gets refs/remotes/origin/HEAD
	sb.git(sb.home, "clone", "-q", "-b", "main", st["clean"]+".origin.git", cl)
	sb.git(cl, "checkout", "-q", "--detach")
	sb.write(filepath.Join(cl, "local.txt"), "l\n")
	sb.git(cl, "add", "-A")
	sb.git(cl, "commit", "-q", "-m", "local on detached")
	st["clone-detached"] = cl
	d = mk("other-branch", true)
	sb.git(d, "checkout", "-q", "-b", "feature/x-y")
	d = mk("subdir", true)
	if err := os.Mkdir(filepath.Join(d, "sub"), 0o755); err != nil {
		t.Fatal(err)
	}
	st["subdir-arg"] = filepath.Join(d, "sub")
	// an unborn repository: rev-parse HEAD fails, so the branch reads "HEAD"
	unborn := filepath.Join(sb.home, "unborn")
	sb.git(sb.home, "init", "-q", "-b", "main", unborn)
	st["unborn"] = unborn
	noUp := filepath.Join(sb.home, "noup")
	sb.git(sb.home, "init", "-q", "-b", "main", noUp)
	sb.write(filepath.Join(noUp, "f.txt"), "x\n")
	sb.git(noUp, "add", "-A")
	sb.git(noUp, "commit", "-q", "-m", "init")
	st["no-upstream"] = noUp
	notGit := filepath.Join(sb.home, "notgit")
	if err := os.Mkdir(notGit, 0o755); err != nil {
		t.Fatal(err)
	}
	st["not-a-repo"] = notGit
	st["missing-dir"] = filepath.Join(sb.home, "no-such-dir")
	return st
}

func TestKitCleanMatchesLegacy(t *testing.T) {
	sb := newSandbox(t)
	for name, dir := range sb.states() {
		t.Run(name, func(t *testing.T) {
			same(t, "verify kit-clean", sb.bash(sb.home, legacy(t, "verify-kit-clean.sh"), dir), sb.golden("verify", "kit-clean", dir))
		})
	}
}

// The default repository of the script is its own directory; the shim passes it, so the Go command given
// that path must read the same repository.
func TestKitCleanDefaultRepoMatchesLegacy(t *testing.T) {
	sb := newSandbox(t)
	for name, dir := range sb.states() {
		if _, err := os.Stat(filepath.Join(dir, "verify-kit-clean.sh")); err != nil {
			continue
		}
		t.Run(name, func(t *testing.T) {
			same(t, "default repo", sb.bash(sb.home, filepath.Join(dir, "verify-kit-clean.sh")), sb.golden("verify", "kit-clean", dir))
		})
	}
}

func TestKitCleanHookMatchesLegacy(t *testing.T) {
	sb := newSandbox(t)
	for name, dir := range sb.states() {
		hook := filepath.Join(dir, "verify-kit-clean-hook.sh")
		if _, err := os.Stat(hook); err != nil {
			continue
		}
		t.Run(name, func(t *testing.T) {
			same(t, "verify kit-clean-hook", sb.bash(sb.home, hook), sb.golden("verify", "kit-clean-hook", dir))
		})
	}
	// A directory that is not a repository: the staged legacy hook sits in a plain directory (rc 2 banner).
	plain := filepath.Join(sb.home, "plainhook")
	for _, f := range []string{"verify-kit-clean.sh", "verify-kit-clean-hook.sh", "lib/hook-emit.sh"} {
		b, err := os.ReadFile(legacy(t, f))
		if err != nil {
			t.Fatal(err)
		}
		sb.write(filepath.Join(plain, f), string(b))
	}
	t.Run("not-a-repo", func(t *testing.T) {
		same(t, "hook outside a repo", sb.bash(sb.home, filepath.Join(plain, "verify-kit-clean-hook.sh")), sb.golden("verify", "kit-clean-hook", plain))
	})
}

func TestKitCleanStubbedGitMatchesLegacy(t *testing.T) {
	sb := newSandbox(t)
	cases := map[string]string{
		"status-fails": `case "$*" in
  *rev-parse*--show-toplevel*) echo /tmp/fake-root; exit 0 ;;
  *rev-parse*--abbrev-ref*) echo main; exit 0 ;;
  *status*--porcelain*) exit 5 ;;
  *) exit 0 ;;
esac
`,
		"counters-disagree": `case "$*" in
  *rev-parse*--show-toplevel*) echo /tmp/fake-r11; exit 0 ;;
  *rev-parse*--abbrev-ref*HEAD*) echo main; exit 0 ;;
  *status*--porcelain*) printf '?? a\n?? b\n'; exit 0 ;;
  *rev-parse*upstream*) exit 1 ;;
  *) exit 0 ;;
esac
`,
		"rev-list-fails": `case "$*" in
  *rev-parse*--show-toplevel*) echo /tmp/fake-rl; exit 0 ;;
  *rev-parse*--abbrev-ref*HEAD*) echo main; exit 0 ;;
  *rev-parse*upstream*) echo origin/main; exit 0 ;;
  *status*--porcelain*) exit 0 ;;
  *rev-list*) exit 3 ;;
  *) exit 0 ;;
esac
`,
		"rev-list-count": `case "$*" in
  *rev-parse*--show-toplevel*) echo /tmp/fake-rc; exit 0 ;;
  *rev-parse*--abbrev-ref*HEAD*) echo main; exit 0 ;;
  *rev-parse*upstream*) echo up/main; exit 0 ;;
  *status*--porcelain*) exit 0 ;;
  *rev-list*) echo 12; exit 0 ;;
  *) exit 0 ;;
esac
`,
		"empty-branch": `case "$*" in
  *rev-parse*--show-toplevel*) echo /tmp/fake-eb; exit 0 ;;
  *) exit 1 ;;
esac
`,
	}
	for name, body := range cases {
		t.Run(name, func(t *testing.T) {
			sb.env["PATH"] = sb.stubGit("stub-"+name, body)
			dir := filepath.Join(sb.home, "dir-"+name)
			if err := os.Mkdir(dir, 0o755); err != nil {
				t.Fatal(err)
			}
			same(t, "stubbed git", sb.bash(sb.home, legacy(t, "verify-kit-clean.sh"), dir), sb.golden("verify", "kit-clean", dir))
		})
	}
}

// The envelope of the hook against jq itself, for the characters a git report can carry.
func TestHookEnvelopeMatchesJq(t *testing.T) {
	sb := newSandbox(t)
	texts := []string{
		"", "plain", "quote \" and \\ backslash", "tab\tcr\rnl\n", "ctrl \x01\x02\x08\x0b\x0c\x1b\x1f del \x7f",
		"héllo ü — · § 😀", "line sep \u2028 para \u2029 <tag> & amp", "100% %s %d", "trailing\n\n\n", "x\xffy", "bad \xc3(",
	}
	for _, text := range texts {
		cmd := exec.Command("jq", "-n", "--arg", "c", text, `{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$c}}`)
		cmd.Env = sb.environ()
		want, err := cmd.Output()
		if err != nil {
			t.Fatal(err)
		}
		var got bytes.Buffer
		writeSessionStart(&got, text)
		if got.String() != string(want) {
			t.Errorf("text %q (valid=%v):\n got %q\nwant %q", text, utf8.ValidString(text), got.String(), want)
		}
	}
	if strings.Contains(string(mustJq(t, sb)), "\u2028") == false {
		t.Error("jq no longer prints U+2028 raw: the encoder's assumption changed")
	}
}

func mustJq(t *testing.T, sb *sandbox) []byte {
	t.Helper()
	cmd := exec.Command("jq", "-n", "--arg", "c", "\u2028", "$c")
	cmd.Env = sb.environ()
	out, err := cmd.Output()
	if err != nil {
		t.Fatal(err)
	}
	return out
}
