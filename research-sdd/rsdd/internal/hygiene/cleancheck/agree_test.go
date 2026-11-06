package cleancheck

import (
	"context"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/cleancheck"
)

// agreeWorld holds one thing for every default and every environment input: stale and fresh tmp.* entries (the 24 h
// default), old and recent backups (the 14 d default), and a scratchpad file only the environment configures.
func agreeWorld(t *testing.T) *world {
	t.Helper()
	w := newWorld(t)
	w.write(w.repo+"/.research-sdd/keep.txt", "_evidence/\n")
	w.write(w.repo+"/stray.txt", "x")
	w.write(w.scratch+"/x.sh", "x")
	age := func(path string, d time.Duration) {
		if err := os.MkdirAll(path, 0o755); err != nil {
			t.Fatal(err)
		}
		at := time.Now().Add(-d)
		if err := os.Chtimes(path, at, at); err != nil {
			t.Fatal(err)
		}
	}
	age(w.tmp+"/tmp.old", 30*time.Hour)
	age(w.tmp+"/tmp.fresh", time.Hour)
	age(w.repo+"/_evidence/t/rollback-old", 20*24*time.Hour)
	age(w.repo+"/_evidence/t/rollback-new", 5*24*time.Hour)
	w.env = append(w.env, "TMPDIR="+w.tmp, "CLEAN_CHECK_SCRATCHPAD="+w.scratch)
	return w
}

// The same environment gives the same Result through the command and through a bare Check call, and an Options
// literal that sets no age is the bare command line (`clean-check --target X`): the defaults live in the engine.
func TestBareCheckBehavesLikeTheBareCommand(t *testing.T) {
	w := agreeWorld(t)
	rc := w.run(nil, "--target", w.repo)
	res := cleancheck.Check(context.Background(), cleancheck.Options{Target: w.repo, Env: w.env, Cwd: w.root, Now: time.Now})
	if res.Exit != rc || res.Stdout() != w.out.String() || res.Stderr() != w.err.String() {
		t.Fatalf("command: exit %d\n%s%s\nCheck: exit %d\n%s%s", rc, w.out, w.err, res.Exit, res.Stdout(), res.Stderr())
	}
	for _, want := range []string{
		"GARBAGE stale-tmp " + w.tmp + "/tmp.old age=30h",
		"WARN stale-backup " + w.repo + "/_evidence/t/rollback-old age=20d retention=14d",
		"UNMANIFESTED-SCRIPT " + w.scratch + "/x.sh",
	} {
		if !strings.Contains(w.out.String(), want+"\n") {
			t.Errorf("missing %q in:\n%s", want, w.out)
		}
	}
	for _, not := range []string{"tmp.fresh", "rollback-new"} {
		if strings.Contains(w.out.String(), not) {
			t.Errorf("%s is inside the default age and must not be listed:\n%s", not, w.out)
		}
	}
}
