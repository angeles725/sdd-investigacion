package writercheck

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/execfile"
)

// Cases from the #2764 cross-read: "could not look" is exit 2, never a finding and never a clean pass.

func impactStub(k *kase) string {
	stub := k.root + "/impact-stub.sh"
	execfile.Write(k.t, stub, "#!/usr/bin/env bash\necho 'Impacted: 0 of 0 suites (stub)'\n")
	return stub
}

func wantDegraded(t *testing.T, r ran, err string) {
	t.Helper()
	if r.rc != 2 || r.out != "" || r.err != "degraded: kit-writer-check: "+err+"\n" {
		t.Errorf("got rc %d\nout %q\nerr %q\nwant rc 2, empty stdout, err %q", r.rc, r.out, r.err, err)
	}
}

// The tool reads only the logs it needs. A log directory it cannot search (mode 000, or 600/400: listable but
// not searchable) makes each required log unreadable: exit 2 with the typed line, never a finding. A directory it
// can search but not list (mode 300) is enough: the logs in it are read.
func TestTeethLogDirModes(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root reads and searches any directory, so these modes cannot be exercised")
	}
	k := newKase(t)
	k.touch(alpha)
	imp := []string{"KIT_WRITER_CHECK_IMPACT=" + k.impact}
	suite := firstRequired(t, k, imp)
	for _, mode := range []os.FileMode{0, 0o600, 0o400} {
		dir := filepath.Join(k.root, "logs"+mode.String())
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, logName(suite)), []byte("x\n"), 0o644); err != nil {
			t.Fatal(err)
		}
		if err := os.Chmod(dir, mode); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { os.Chmod(dir, 0o755) })
		r := k.goRun(imp, "--repo", k.dir, "--base", "base", "--teeth-log", dir)
		wantDegraded(t, r, "teeth log unreadable: "+filepath.Join(dir, logName(suite))+" (permission denied)")
	}
	dir := filepath.Join(k.root, "logs300")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(dir, 0o300); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.Chmod(dir, 0o755) })
	if r := k.goRun(imp, "--repo", k.dir, "--base", "base", "--teeth-log", dir); r.rc != 1 || !strings.Contains(r.out, "missing-teeth "+suite+" (no log ") {
		t.Errorf("mode 300: rc %d out %q err %q", r.rc, r.out, r.err)
	}
}

func firstRequired(t *testing.T, k *kase, imp []string) string {
	t.Helper()
	first := k.goRun(imp, "--repo", k.dir, "--base", "base")
	if lines := strings.Split(first.out, "\n"); len(lines) > 1 && strings.HasPrefix(lines[0], "Required suites: ") {
		if s := strings.TrimSpace(lines[1]); s != "" {
			return s
		}
	}
	t.Fatalf("no required suite: %q", first.out)
	return ""
}

func TestUnreadableTeethLogIsDegraded(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root reads a mode-000 file")
	}
	k := newKase(t)
	k.touch(alpha)
	imp := []string{"KIT_WRITER_CHECK_IMPACT=" + k.impact}
	suite := firstRequired(t, k, imp)
	dir := k.root + "/logs"
	p := filepath.Join(dir, logName(suite))
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte("x\n"), 0); err != nil {
		t.Fatal(err)
	}
	r := k.goRun(imp, "--repo", k.dir, "--base", "base", "--teeth-log", dir)
	wantDegraded(t, r, "teeth log unreadable: "+p+" (permission denied)")
}

func TestNoMergeBaseUnderWorktreeIsDegraded(t *testing.T) {
	k := newKase(t)
	orphan := strings.TrimSpace(k.git("commit-tree", "4b825dc642cb6eb9a060e54bf8d69288fbee4904", "-m", "orphan"))
	r := k.goRun([]string{"KIT_WRITER_CHECK_IMPACT=" + impactStub(k)}, "--repo", k.dir, "--base", orphan, "--worktree")
	wantDegraded(t, r, "no merge-base of "+orphan+" and HEAD")
}

func TestUncreatableTeethLogDirIsDegraded(t *testing.T) {
	k := newKase(t)
	file := k.root + "/plain"
	if err := os.WriteFile(file, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	r := k.goRun(nil, "--repo", k.dir, "--write-teeth-log", file+"/sub", "--base", "base", "research-sdd/toolbelt/tests/a.test.sh")
	wantDegraded(t, r, "cannot create teeth-log dir: "+file+"/sub")
}

// A user git config that drops or renames the a/ b/ diff prefixes cannot move a name-kill to another path (the
// bash missed every name-kill under diff.noprefix: a silent zero).
func TestNameKillUnderDiffPrefixConfig(t *testing.T) {
	for name, kv := range map[string][2]string{
		"noprefix":       {"diff.noprefix", "true"},
		"mnemonicPrefix": {"diff.mnemonicPrefix", "true"},
		"dstPrefix":      {"diff.dstPrefix", "Z/"},
	} {
		k := newKase(t)
		k.write(tb+"/kill.sh", "pkill -f x\n")
		k.commit("kill")
		cfg := []string{"GIT_CONFIG_COUNT=1", "GIT_CONFIG_KEY_0=" + kv[0], "GIT_CONFIG_VALUE_0=" + kv[1], "KIT_WRITER_CHECK_IMPACT=" + impactStub(k)}
		raw, err := gitIn(k.dir, append(append([]string(nil), k.env...), cfg...), "diff", "-U0", "base")
		if err != nil || strings.Contains(raw, "+++ b/") { // the config must really change git's output here
			t.Fatalf("%s: config did not apply (err %v):\n%s", name, err, raw)
		}
		k.write(tb+"/wt.sh", "pkill -f y\n") // an uncommitted change: the worktree diff
		k.git("add", "-N", tb+"/wt.sh")
		for _, mode := range [][]string{{"--base", "base"}, {"--base", "base", "--worktree"}} {
			r := k.goRun(cfg, append([]string{"--repo", k.dir}, mode...)...)
			if !strings.Contains(r.out, "name-kill "+tb+"/kill.sh:1 (name-based process kill)\n") ||
				(len(mode) == 3 && !strings.Contains(r.out, "name-kill "+tb+"/wt.sh:1 (name-based process kill)\n")) {
				t.Errorf("%s %v: rc %d out:\n%s\nerr:\n%s", name, mode, r.rc, r.out, r.err)
			}
		}
	}
}

// Suites run under --write-teeth-log read /dev/null, not the caller's stdin (intended divergence: the bash passed
// its own stdin through, so a suite that reads stdin could block or consume the caller's input).
func TestWriteTeethLogSuitesReadDevNull(t *testing.T) {
	k := newKase(t)
	k.write("research-sdd/toolbelt/tests/in.test.sh", "#!/usr/bin/env bash\nIFS= read -r x || x=EOF\necho \"stdin=[$x]\"\n")
	k.commit("stdin suite")
	dir := k.root + "/logs"
	var o, e strings.Builder
	env := k.env
	get := func(key string) string {
		for _, kv := range env {
			if v, ok := strings.CutPrefix(kv, key+"="); ok {
				return v
			}
		}
		return ""
	}
	s := cli.Stdio{In: strings.NewReader("from-caller\n"), Out: &o, Err: &e, Env: get, Environ: func() []string { return env }, Clock: time.Now, Cwd: k.root}
	Run([]string{"--repo", k.dir, "--write-teeth-log", dir, "--base", "base", "research-sdd/toolbelt/tests/in.test.sh"}, s)
	b, err := os.ReadFile(filepath.Join(dir, logName("research-sdd/toolbelt/tests/in.test.sh")))
	if err != nil || !strings.Contains(string(b), "stdin=[EOF]\n") || strings.Contains(string(b), "from-caller") {
		t.Errorf("log %q (err %v); stdout %q stderr %q", b, err, o.String(), e.String())
	}
}
