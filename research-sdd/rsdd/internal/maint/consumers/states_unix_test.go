//go:build unix

package consumers

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// wrapGit puts a `git` first on the fixture's PATH that runs the real git, except that for the subcommand sub it
// first runs body (a shell fragment). The fixture's own git commands are not affected when they run before the call.
func wrapGit(t *testing.T, f *fixture, sub, body string) {
	t.Helper()
	dir := filepath.Join(f.root, "wrap")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	script := "#!/bin/sh\nfor a in \"$@\"; do\n  if [ \"$a\" = " + sub + " ]; then\n" + body + "\n  fi\ndone\nexec " + gitDir(t) + "/git \"$@\"\n"
	if err := os.WriteFile(filepath.Join(dir, "git"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	f.env = envFor(t, f.root, dir+":"+gitDir(t)+":/usr/bin:/bin")
}

func TestUnreadableDirectoryDegradesTheRun(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root reads every directory")
	}
	f := newFixture(t)
	f.files(map[string]string{"research-sdd/toolbelt/a.sh": "x", "research-sdd/toolbelt/sub/b.sh": "x"})
	f.commit()
	f.write("research-sdd/toolbelt/sub/c.sh", "x")
	if got := f.run(); got.rc != 0 || line(got.out, "files: ") != "files: 3 listed (tracked, and untracked but not ignored)" {
		t.Fatalf("before the chmod: %+v", got)
	}
	sub := filepath.Join(f.dir, "research-sdd/toolbelt/sub")
	t.Cleanup(func() { os.Chmod(sub, 0o755) })
	if err := os.Chmod(sub, 0); err != nil {
		t.Fatal(err)
	}
	got := f.run()
	want := ran{"consumers: degraded\n", "DEGRADED: git ls-files wrote to stderr, so the file list may be incomplete: " +
		"warning: could not open directory 'research-sdd/toolbelt/sub/': Permission denied (and 0 more stderr lines); nothing was counted\n", 3}
	if got != want {
		t.Fatalf("got %+v\nwant %+v", got, want)
	}
}

func TestAnyStderrOfAnLsFilesRunDegradesIt(t *testing.T) {
	cases := []struct {
		name, stderr, shown string
	}{
		{"one line", "warning: one\n", "warning: one (and 0 more stderr lines)"},
		{"no trailing newline", "warning: one", "warning: one (and 0 more stderr lines)"},
		{"two lines", "warning: one\nwarning: two\n", "warning: one (and 1 more stderr lines)"},
		{"three lines", "warning: one\nwarning: two\nwarning: three\n", "warning: one (and 2 more stderr lines)"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			f := newFixture(t)
			f.files(map[string]string{"research-sdd/toolbelt/a.sh": "x"})
			f.commit()
			wrapGit(t, f, "ls-files", "printf '"+strings.ReplaceAll(c.stderr, "\n", "\\n")+"' >&2")
			got := f.run()
			want := ran{"consumers: degraded\n", "DEGRADED: git ls-files wrote to stderr, so the file list may be incomplete: " + c.shown + "; nothing was counted\n", 3}
			if got != want {
				t.Fatalf("got %+v\nwant %+v", got, want)
			}
		})
	}
}

func TestStderrOfRevParseDoesNotDegradeTheRun(t *testing.T) {
	f := newFixture(t)
	f.files(map[string]string{"research-sdd/toolbelt/a.sh": "x"})
	f.commit()
	wrapGit(t, f, "rev-parse", "echo noise >&2")
	if got := f.run(); got.rc != 0 || got.err != "" || line(got.out, "scripts: ") != "scripts: 1 (sh 1)" {
		t.Fatalf("got %+v", got)
	}
}

func TestListFailureKeepsItsExitCode(t *testing.T) {
	f := newFixture(t)
	f.files(map[string]string{"research-sdd/toolbelt/a.sh": "x"})
	f.commit()
	wrapGit(t, f, "ls-files", "echo boom >&2; exit 7")
	want := ran{"", "consumers: error: git ls-files failed (exit code 7) in " + f.dir + "\n", 1}
	if got := f.run(); got != want {
		t.Fatalf("got %+v\nwant %+v", got, want)
	}
}

func TestGitThatTimesOutOrHitsTheCap(t *testing.T) {
	oldT, oldB := childTimeout, childMaxBytes
	t.Cleanup(func() { childTimeout, childMaxBytes = oldT, oldB })
	childTimeout, childMaxBytes = 300*time.Millisecond, 4096
	big := "i=0; while [ $i -lt 600 ]; do printf 'xxxxxxxxxxxxxxxx'; i=$((i+1)); done"
	cases := []struct{ name, sub, body, want string }{
		{"timeout in rev-parse", "rev-parse", "sleep 30", "consumers: error: git rev-parse timed out after 300ms in %s\n"},
		{"timeout in ls-files", "ls-files", "sleep 30", "consumers: error: git ls-files timed out after 300ms in %s\n"},
		{"cap in rev-parse", "rev-parse", big, "consumers: error: git rev-parse produced more than 4096 bytes of output in %s\n"},
		{"cap in ls-files", "ls-files", big, "consumers: error: git ls-files produced more than 4096 bytes of output in %s\n"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			f := newFixture(t)
			f.files(map[string]string{"research-sdd/toolbelt/a.sh": "x"})
			f.commit()
			wrapGit(t, f, c.sub, c.body)
			where := f.dir
			want := ran{"", sprintf(c.want, where), 1}
			if got := f.run(); got != want {
				t.Fatalf("got %+v\nwant %+v", got, want)
			}
		})
	}
}

func TestRevParseThatPrintsNothingIsNotAWorkTree(t *testing.T) {
	f := newFixture(t)
	f.files(map[string]string{"research-sdd/toolbelt/a.sh": "x"})
	f.commit()
	wrapGit(t, f, "rev-parse", "exit 0")
	want := ran{"consumers: degraded\n", "DEGRADED: " + f.dir + " is not inside a git work tree; nothing was counted\n", 3}
	if got := f.run(); got != want {
		t.Fatalf("got %+v\nwant %+v", got, want)
	}
}

// brokenGit puts a `git` on the PATH that the lookup finds and the kernel cannot run.
func brokenGit(t *testing.T, f *fixture, content string) {
	t.Helper()
	dir := filepath.Join(f.root, "broken")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "git"), []byte(content), 0o755); err != nil {
		t.Fatal(err)
	}
	f.env = envFor(t, f.root, dir+":"+gitDir(t)+":/usr/bin:/bin")
}

func TestGitThatVanishesAfterTheProbeIsDegraded(t *testing.T) {
	f := newFixture(t)
	brokenGit(t, f, "#!/nonexistent/interpreter\n")
	want := ran{"consumers: degraded\n", "DEGRADED: git is not installed; nothing was counted\n", 3}
	if got := f.run(); got != want {
		t.Fatalf("got %+v\nwant %+v", got, want)
	}
}

func TestGitThatCannotBeExecutedIsAnError(t *testing.T) {
	f := newFixture(t)
	brokenGit(t, f, "\x00\x01 not a program\n")
	got := f.run()
	if got.rc != 1 || got.out != "" || !strings.HasPrefix(got.err, "consumers: error: git rev-parse could not run: git: ") || !strings.HasSuffix(got.err, " (in "+f.dir+")\n") {
		t.Fatalf("got %+v", got)
	}
}
