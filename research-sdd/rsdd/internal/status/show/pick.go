package show

import (
	"errors"
	"fmt"
	"os"
	"path"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kit"
)

// stateRC maps the typed result of kit.ResolveStateFile back to the bash rc of resolve_state_file: 0 found, 1
// absent, 2 ambiguous (the path is still the C-first pick), 3 usage.
func stateRC(err error) int {
	switch {
	case err == nil:
		return 0
	case errors.Is(err, kit.ErrStateAbsent):
		return 1
	case errors.Is(err, kit.ErrStateAmbiguous):
		return 2
	}
	return 3
}

// resolver is kit.ResolveStateFile; a field so a test can force the rc the real corpus cannot reach.
type resolver func(dir string, opt kit.ResolveOptions) (string, error)

// pick selects the state file the way the script does and sets c.state / c.corpus. done is true when the run is
// over: a BOOTSTRAP line (rc 0), an ambiguous --root (rc 1) or a failed resolution (rc 1).
func (c *ctx) pick(resolve resolver) (rc int, done bool) {
	switch {
	case c.opts.root:
		return c.pickRoot()
	case c.opts.focus != "":
		return c.pickResolved(resolve, kit.ResolveOptions{FocusSet: true, Focus: c.opts.focus}, "RESEARCH-STATE-"+c.opts.focus+".md")
	}
	return c.pickResolved(resolve, kit.ResolveOptions{}, "RESEARCH-STATE")
}

// pickResolved is the resolve_state_file pick of --focus and the default form: rc 1 (absent) and 2 (ambiguous,
// the C-first path) are accepted, anything above is a failed resolution.
func (c *ctx) pickResolved(resolve resolver, opt kit.ResolveOptions, name string) (int, bool) {
	p, err := resolve(c.abs(c.target), opt)
	if r := stateRC(err); r > 2 {
		fmt.Fprintf(c.s.Err, "research-sdd-status: state-file resolution failed (rc %d)\n", r)
		return 1, true
	}
	c.state = c.show(p)
	return c.bootstrap(name)
}

// bootstrap ends the run with the typed "no state file" answer when the pick is not a regular file; otherwise it
// derives the corpus directory.
func (c *ctx) bootstrap(name string) (int, bool) {
	if !c.isFile(c.state) {
		if c.opts.mode == modeNext {
			fmt.Fprintf(c.s.Out, "BOOTSTRAP | no %s under %s\n", name, c.target)
		} else {
			fmt.Fprintf(c.s.Out, "no %s under %s — run research-sdd-init.sh\n", name, c.target)
		}
		return 0, true
	}
	c.corpus = dirname(c.state)
	return 0, false
}

// pickRoot is --root: exactly the un-suffixed RESEARCH-STATE.md. A root is the TOP-LEVEL file, or the sole nested
// one that sits beside RESEARCH-STATE-<focus>.md siblings; a lone nested file with no siblings (archive/, backup/)
// or several candidates is refused.
func (c *ctx) pickRoot() (int, bool) {
	if c.isFile(c.target + "/RESEARCH-STATE.md") {
		c.state = c.target + "/RESEARCH-STATE.md"
	} else if cands := c.rootCandidates(); len(cands) > 0 {
		sib, n := "", 0
		for _, rc := range cands {
			if c.hasFocusSibling(dirname(rc)) { // ROOT-PICK-SIBLINGS
				sib, n = rc, n+1
			}
		}
		if n != 1 {
			lines := make([]string, len(cands))
			for i, cand := range cands {
				lines[i] = "  " + cand
			}
			fmt.Fprintf(c.s.Err, "root-select: ERROR: --root is ambiguous or unsupported under %s: no top-level RESEARCH-STATE.md and %d root candidate(s) beside focus siblings; candidates:\n%s\n",
				c.target, n, strings.Join(lines, "\n"))
			return 1, true
		}
		c.state = sib
	}
	if !c.isFile(c.state) && c.opts.mode == modeSync {
		fmt.Fprintf(c.s.Err, "sync-state: no RESEARCH-STATE.md under %s\n", c.target)
		return 1, true
	}
	return c.bootstrap("RESEARCH-STATE.md")
}

// rootCandidates is `find "$target" -maxdepth 3 -name RESEARCH-STATE.md -not -path '*/.git/*' | sort`, shown with
// the target prefix as the caller wrote it.
func (c *ctx) rootCandidates() []string {
	all, err := kit.ListStateFiles(c.abs(c.target))
	if err != nil {
		return nil
	}
	var out []string
	for _, p := range all {
		if path.Base(p) == "RESEARCH-STATE.md" {
			out = append(out, c.show(p))
		}
	}
	return out
}

// hasFocusSibling is `find <dir> -maxdepth 1 -name 'RESEARCH-STATE-*.md' -not -name '*.template.md' -print -quit`.
func (c *ctx) hasFocusSibling(dir string) bool {
	ents, err := os.ReadDir(c.abs(dir))
	if err != nil {
		return false
	}
	for _, e := range ents {
		n := e.Name()
		if ok, _ := path.Match("RESEARCH-STATE-*.md", n); ok && !strings.HasSuffix(n, ".template.md") {
			return true
		}
	}
	return false
}
