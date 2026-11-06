//go:build unix && !nodiff

package deploy

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Config roots of the three harnesses below the scratch home (adapters.sh _RSDD_CONFIG_ROOT_REL).
var harnessRoot = map[string]string{"claude": ".claude", "pi": ".pi/agent", "gentle-shell": ".gentle-shell/agent"}

// harnesses in registration order (adapters.sh RESEARCH_SDD_HARNESSES).
var harnesses = []string{"claude", "pi", "gentle-shell"}

// hp is the absolute path of rel below the scratch home.
func (w *world) hp(rel string) string { return join(w.home, filepath.FromSlash(rel)) }

// seed writes text at rel below the scratch home, creating parents (a pre-existing user file).
func (w *world) seed(rel, text string) {
	w.t.Helper()
	w.put(w.hp(rel), []byte(text), 0o644)
}

// link makes the symlink rel -> target (target is used verbatim) below the scratch home.
func (w *world) link(rel, target string) {
	w.t.Helper()
	mkdir(w.t, filepath.Dir(w.hp(rel)))
	if err := os.Symlink(target, w.hp(rel)); err != nil {
		w.t.Fatal(err)
	}
}

// homeText is the normalized content of rel below the scratch home.
func (w *world) homeText(rel string) string { return w.read(w.hp(rel)) }

// blocks counts the launcher start markers in a home file.
func (w *world) blocks(rel string) int {
	return strings.Count(w.homeText(rel), "<!-- research-sdd:start -->")
}

// assertEq fails with a first-line diff when two texts differ.
func assertEq(t *testing.T, what, got, want string) {
	t.Helper()
	if got != want {
		t.Errorf("%s differs\n%s", what, firstDiff(want, got))
	}
}
