package reconcile

import (
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

// The audit is read-only toward both tools it drives. gh is held to the call shape of the legacy script by the
// stub (ghstub_test.go: unknown flags, unknown --json fields and --limit 0 are rejected and recorded in
// box/gh.reject). git is held to a read-only verb set by a logging wrapper first on the box PATH (box/bin/git,
// box/git.log): the legacy script never fetched ("no fetch is performed" is in two typed lines), and the
// kit-wide runner (core/git) states "no network verbs" only in prose. runGo calls checkToolCalls after every run.

// readOnlyGitVerbs is what the port runs: the repository probe and the ref and commit lookups of the closure
// evidence (session.probe and session.check in closed.go through core/git: rev-parse, cat-file and
// merge-base --is-ancestor). Anything else, a fetch, pull, push, ls-remote, remote, checkout or reset above all,
// fails the run.
var readOnlyGitVerbs = map[string]bool{"rev-parse": true, "cat-file": true, "merge-base": true}

// installGitLogger writes box/bin/git: a wrapper that logs its argv (tab separated, one call per line) to
// box/git.log and runs the real git. It is written with the rest of the box, before any subtest forks (ETXTBSY).
func installGitLogger(t *testing.T, root string) {
	t.Helper()
	real, err := exec.LookPath("git")
	if err != nil {
		return // no git: the repository cases cannot run either
	}
	bash, err := exec.LookPath("bash")
	if err != nil {
		t.Fatalf("the git logger needs bash: %v", err)
	}
	mustMkdir(t, filepath.Join(root, "bin"))
	script := "#!" + bash + "\nprintf '%s\\t' \"$@\" >> '" + root + "/git.log'\nprintf '\\n' >> '" + root + "/git.log'\nexec '" + real + "' \"$@\"\n"
	if err := os.WriteFile(filepath.Join(root, "bin", "git"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
}

// gitVerbs is the verb of every call in a git.log, in order; a call whose argv has a global option other than
// -C (for example -c) is reported as that option.
func gitVerbs(log string) []string {
	var out []string
	for _, line := range strings.Split(log, "\n") {
		if line == "" {
			continue
		}
		args := strings.Split(strings.TrimSuffix(line, "\t"), "\t")
		verb := ""
		for i := 0; i < len(args); i++ {
			if args[i] == "-C" {
				i++
				continue
			}
			verb = args[i]
			break
		}
		out = append(out, verb)
	}
	return out
}

// forbiddenGit lists the verbs of a git.log that are not read-only (each once, sorted).
func forbiddenGit(log string) []string {
	seen := map[string]bool{}
	var bad []string
	for _, v := range gitVerbs(log) {
		if !readOnlyGitVerbs[v] && !seen[v] {
			seen[v] = true
			bad = append(bad, v)
		}
	}
	sort.Strings(bad)
	return bad
}

// checkToolCalls fails the test when the run called git with a verb outside readOnlyGitVerbs, or called the stub
// gh in a shape the legacy script never used.
func checkToolCalls(t *testing.T, b *box) {
	t.Helper()
	if data, err := os.ReadFile(filepath.Join(b.root, "git.log")); err == nil {
		if bad := forbiddenGit(string(data)); len(bad) > 0 {
			t.Errorf("the port ran git verbs outside the read-only set %v: %q\nfull log:\n%s", boolKeys(readOnlyGitVerbs), bad, data)
		}
	}
	if data, err := os.ReadFile(filepath.Join(b.root, "gh.reject")); err == nil {
		t.Errorf("the stub gh rejected a call the legacy script never makes:\n%s", data)
	}
}

func boolKeys(m map[string]bool) []string {
	var out []string
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

func TestGitVerbGuard(t *testing.T) {
	ok := "-C\t/r\trev-parse\t--git-dir\t\n-C\t/r\tcat-file\t-e\tabc^{commit}\t\n-C\t/r\tmerge-base\t--is-ancestor\ta\tb\t\n"
	if bad := forbiddenGit(ok); len(bad) != 0 {
		t.Errorf("read-only calls flagged: %q", bad)
	}
	for _, verb := range strings.Fields("fetch pull push ls-remote remote checkout reset clone gc") {
		if bad := forbiddenGit(ok + "-C\t/r\t" + verb + "\t--all\t\n"); len(bad) != 1 || bad[0] != verb {
			t.Errorf("git %s not flagged: %q", verb, bad)
		}
	}
	if bad := forbiddenGit("-c\tprotocol.version=2\trev-parse\t\n"); len(bad) != 1 || bad[0] != "-c" {
		t.Errorf("a global -c option must be flagged, got %q", bad)
	}
}

// TestGitLoggerIsOnThePath proves the wrapper really sits in front of git for the repository cases: the closure
// evidence runs rev-parse, cat-file and merge-base through it. Without this a broken wrapper would make the
// guard above vacuous (an empty log has no forbidden verb).
func TestGitLoggerIsOnThePath(t *testing.T) {
	seen := map[string]bool{}
	for _, c := range allCases() {
		if c.noGit || c.noGH || c.env["PATH"] != "" {
			continue
		}
		b := mkBox(t, c)
		if first, _, _ := strings.Cut(b.environ()["PATH"], ":"); first != filepath.Join(b.root, "bin") {
			t.Errorf("%s: box/bin is not first on PATH (%s): git would not be logged", c.name, first)
		}
		if c.repo == "" {
			continue
		}
		runGo(t, b)
		data, err := os.ReadFile(filepath.Join(b.root, "git.log"))
		if err != nil {
			continue
		}
		for _, v := range gitVerbs(string(data)) {
			seen[v] = true
		}
	}
	for v := range readOnlyGitVerbs {
		if !seen[v] {
			t.Errorf("no repository case reached git %s through the logging wrapper (saw %v)", v, boolKeys(seen))
		}
	}
	if len(seen) != len(readOnlyGitVerbs) {
		t.Errorf("the port runs git verbs %v, the allowlist says %v: keep readOnlyGitVerbs equal to what the port calls", boolKeys(seen), boolKeys(readOnlyGitVerbs))
	}
}

// TestGHStubRejectsWhatTheLegacyStubRejected pins the stub itself: each call below exits 98 and is recorded, and
// the real shapes of the port are accepted.
func TestGHStubRejectsWhatTheLegacyStubRejected(t *testing.T) {
	root := t.TempDir()
	writeStubs(t, root, nil)
	gh := filepath.Join(root, "bin", "gh")
	run := func(args ...string) int {
		err := exec.Command(gh, args...).Run()
		var ee *exec.ExitError
		switch {
		case err == nil:
			return 0
		case errors.As(err, &ee):
			return ee.ExitCode()
		}
		t.Fatalf("stub gh did not run: %v", err)
		return -1
	}
	base := []string{"issue", "list", "--repo", "o/r", "--state", "open", "--limit", "1000", "--json", "body", "--jq", ".[]"}
	with := func(from, to string) []string {
		out := append([]string(nil), base...)
		for i, a := range out {
			if a == from {
				out[i] = to
			}
		}
		return out
	}
	extra := func(more ...string) []string { return append(append([]string(nil), base...), more...) }
	if rc := run(base...); rc != 0 {
		t.Fatalf("the real call shape is rejected: rc %d", rc)
	}
	bad := map[string][]string{
		"unknown flag":       extra("--frobnicate", "x"),
		"stray positional":   extra("extra"),
		"unknown json field": with("body", "body,nope"),
		"limit zero":         with("1000", "0"),
		"limit 000":          with("1000", "000"),
		"limit not a number": with("1000", "ten"),
		"unknown state":      with("open", "merged"),
		"flag without value": {"issue", "list", "--state"},
		"api unknown flag":   {"api", "--paginate", "repos/o/r/issues", "--jq", ".", "--bogus"},
		"api no endpoint":    {"api", "--paginate", "--jq", "."},
		"unexpected command": {"repo", "view"},
	}
	for name, args := range bad {
		if rc := run(args...); rc != 98 {
			t.Errorf("%s: rc %d, want 98", name, rc)
		}
	}
	if rc := run("api", "--paginate", "repos/o/r/issues?state=closed", "--jq", "."); rc != 0 {
		t.Errorf("the real api shape is rejected: rc %d", rc)
	}
	if rc := run("issue", "list", "--repo", "o/r", "--state", "closed", "--limit", "007", "--search", "x", "--json", "number,body,comments,stateReason", "--jq", "."); rc != 0 {
		t.Errorf("the real closed shape is rejected: rc %d", rc)
	}
	data, _ := os.ReadFile(filepath.Join(root, "gh.reject"))
	if n := strings.Count(string(data), "\n"); n != len(bad) {
		t.Errorf("gh.reject has %d lines, want %d:\n%s", n, len(bad), data)
	}
}
