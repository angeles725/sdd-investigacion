package stage

import (
	"bytes"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/retrogrammar"
)

// The tests of this file run under -tags nodiff as well (no oracle needed): they pin the range edges of the slug
// alphabet, the fetch bound, the absent-retro answer and the wording of every self-reference advice case, so that a
// boundary or negation mutant of those lines cannot live.

// slugs keep [A-Za-z0-9._-]; every other byte becomes '-'. The edge bytes sit one step outside each range:
// ` a z { (letters), @ A Z [ (capitals), / 0 9 : (digits; '/' cannot be part of a base name and is covered by
// the neighbours), and the three punctuation bytes the alphabet keeps.
func TestSlugAlphabetEdges(t *testing.T) {
	kept := "azAZ09._"
	dropped := "`{@[:"
	for _, c := range kept + dropped {
		x := string(c)
		isKept := strings.ContainsRune(kept, c)
		first, middle, last := "ab", "ab", "ab"
		if isKept {
			first, middle, last = x+"ab", "a"+x+"b", "ab"+x
		}
		if !isKept {
			middle = "a-b"
		}
		for _, p := range []struct{ name, in, want string }{
			{"first", x + "ab.md", first},
			{"middle", "a" + x + "b.md", middle},
			{"last", "ab" + x + ".md", last},
		} {
			if got := slugOf(p.in); got != p.want {
				t.Errorf("%s byte %q: slugOf(%q) = %q, want %q", p.name, x, p.in, got, p.want)
			}
		}
	}
	// '-' is kept, but a leading and a trailing one are trimmed and a run collapses
	for in, want := range map[string]string{"-ab.md": "ab", "a-b.md": "a-b", "ab-.md": "ab", "a--b.md": "a-b", "a-@-b.md": "a-b"} {
		if got := slugOf(in); got != want {
			t.Errorf("slugOf(%q) = %q, want %q", in, got, want)
		}
	}
}

// RunCommand hands the caller's Environ (not the process environment) to every child process: a variable that
// exists only in that Environ and makes the child fail is observed whatever the host environment holds.
func TestRunCommandHandsTheCallersEnvironToTheChildren(t *testing.T) {
	f := box(t, simple(mPending))
	f.setEnv("GIT_DIR", filepath.Join(f.root, "no-such-dir"))
	var so, se bytes.Buffer
	rc := RunCommand([]string{"--toolbelt", f.abs("research-sdd/toolbelt"), f.abs("targetA/retros/r1.md")}, f.stdio(f.repo, &so, &se))
	got := f.normalize(se.String())
	want := "fatal: not a git repository: '@BOX@/no-such-dir'\n" +
		"degraded: git could not read the state of the kit repo in @BOX@/repo (git status --porcelain: exit 128: fatal: not a git repository: '@BOX@/no-such-dir') — nothing was changed.\n"
	if rc != 4 || so.String() != "" || !strings.HasSuffix(got, want) {
		t.Errorf("rc %d out %q err %q", rc, so.String(), got)
	}
}

func TestDefaultFetchTimeout(t *testing.T) {
	if DefaultFetchTimeout != 120*time.Second {
		t.Errorf("DefaultFetchTimeout = %v, want 2m0s", DefaultFetchTimeout)
	}
}

// A reader that answers absent-input is the usage error, not "not readable"; an unreadable one is exit 1 with
// the degraded line (TestUnreadableRetroIsRefusedBeforeAnyGitCall asserts that the second also runs no git).
func TestAbsentAndUnreadableRetroAreDistinct(t *testing.T) {
	f := box(t, simple(mPending))
	r := f.run(f.retroArg(), func(o *Options) {
		o.Read = func(string) (*retrogrammar.Doc, error) { return nil, retrogrammar.ErrAbsentInput }
	})
	if r.RC != 1 || r.Stdout != "" || r.Stderr != "usage: stage-retro.sh <path-to-retro.md>\n" {
		t.Errorf("absent: rc %d out %q err %q", r.RC, r.Stdout, r.Stderr)
	}
	f = box(t, simple(mPending))
	r = f.run(f.retroArg(), func(o *Options) {
		o.Read = func(string) (*retrogrammar.Doc, error) { return nil, retrogrammar.ErrUnreadable }
	})
	if r.RC != 1 || r.Stdout != "" || !strings.HasPrefix(r.Stderr, "degraded: retro not readable: ") {
		t.Errorf("unreadable: rc %d out %q err %q", r.RC, r.Stdout, r.Stderr)
	}
}

// Every self-reference advice case refuses with exit 7 and its own wording, and nothing else.
func TestSelfReferenceAdviceCases(t *testing.T) {
	byName := map[string]dcase{}
	for _, c := range selfRefCases() {
		byName[c.name] = c
	}
	wants := map[string]string{
		"parity/16d-selfref-origin-ahead":           "origin/main is AHEAD of local main: it has this retro, local main does not. Fast-forward\n",
		"parity/16e-selfref-diverged":               "local main and origin/main have DIVERGED: origin/main has this retro, local main does not.\n",
		"parity/16f-selfref-ignored-untracked":      "this retro exists only on another branch (or is untracked): it is not committed on local\n",
		"parity/16b-selfref-local-ahead":            "local main is AHEAD of origin/main. Push it first:",
		"parity/16g-selfref-origin-ahead-same-file": "origin/main is AHEAD of local main. Fast-forward local main first:\n",
		"parity/16h-selfref-diverged-same-file":     "local main and origin/main have DIVERGED for this file. Reconcile them (rebase or merge),\n",
	}
	for name, want := range wants {
		c, ok := byName[name]
		if !ok {
			t.Fatalf("no case %s", name)
		}
		t.Run(name, func(t *testing.T) {
			f := mkBox(t, c)
			args, _ := c.resolve(f)
			r := f.run(args, nil)
			if r.RC != 7 {
				t.Fatalf("rc %d: %s", r.RC, r.Stderr)
			}
			contains(t, "stderr", r.Stderr, want, "...then re-run stage-retro.sh.\n")
			for otherName, other := range wants {
				if otherName != name && strings.Contains(r.Stderr, other) {
					t.Errorf("stderr carries the wording of %s:\n%s", otherName, r.Stderr)
				}
			}
		})
	}
}
