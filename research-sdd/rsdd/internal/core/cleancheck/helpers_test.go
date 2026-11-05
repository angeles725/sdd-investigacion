package cleancheck

import (
	"fmt"
	"os"
	"os/exec"
	"strings"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/execfile"
)

// rule makes a stubbed git answer a call whose argument string contains match: print out and errText, exit rc.
type rule struct {
	match, out, errText string
	rc                  int
}

// stubRules puts a git in front of the real one that answers the rules (first match wins) and runs the real git for
// every other call. The scenarios use it for what a repository cannot be made to produce on demand.
func (w *world) stubRules(rules ...rule) {
	w.t.Helper()
	real, err := exec.LookPath("git")
	if err != nil {
		w.t.Fatal(err)
	}
	var b strings.Builder
	b.WriteString("#!/bin/sh\nargs=\" $* \"\n")
	for _, r := range rules {
		fmt.Fprintf(&b, "case \"$args\" in *' %s '*) printf '%%b' '%s'; printf '%%b' '%s' >&2; exit %d;; esac\n", r.match, r.out, r.errText, r.rc)
	}
	fmt.Fprintf(&b, "exec %s \"$@\"\n", real)
	execfile.Write(w.t, w.root+"/bin/git", b.String())
	w.env = append(w.env, "PATH="+w.root+"/bin:"+os.Getenv("PATH"))
}

// opts is a plain run of the world: its repository and tmp directory, the default ages.
func (w *world) opts() Options {
	return Options{Target: w.repo, Tmp: w.tmp, Cwd: w.root, Env: w.env, Now: time.Now, StaleHours: DefaultStaleHours, BackupDays: DefaultBackupDays}
}

// check runs Check on a plain run of the world, after letting the test adjust the options.
func (w *world) check(adjust ...func(*Options)) Result {
	w.t.Helper()
	o := w.opts()
	for _, f := range adjust {
		f(&o)
	}
	return Check(o)
}

// has reports whether the merged output holds the line.
func has(r Result, line string) bool {
	for _, l := range r.Lines {
		if l.Text == line {
			return true
		}
	}
	return false
}

// without is the merged output with the world's root shown as <R>, for a failure message.
func (w *world) dump(r Result) string { return fmt.Sprintf("exit %d\n%s", r.Exit, w.show(r.Merged())) }
