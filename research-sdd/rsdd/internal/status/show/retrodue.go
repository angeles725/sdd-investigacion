package show

import (
	"fmt"
	"io"
	"os"
	"path"
	"regexp"
	"strconv"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kit"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/retrogrammar"
)

// coversDerive is _rd_covers_derive (kit issue #1640): blocks_since_retro derived from the retros' machine-readable
// `covers_through: B<n>` lines, for a declared counter that would fire RETRO-DUE. The derived value is
// max(0, newest block id on disk - highest in-range covers_through of the target's retros) and it replaces the
// declared counter ONLY when LOWER (the effective counter and the RETRO-DUE suffix are returned).
//
// Fail-closed: coverage may only lower the counter when the evidence unambiguously belongs to THIS focus. Every
// state in which the derivation cannot run is named on stderr and keeps the declared counter: a non-unique focus
// slug, a range-scoped focus, no block files, an incomplete retro enumeration, no retros, no field. A line without
// a focus counts only when the corpus holds the single root state file; a value above the newest block is excluded
// from the maximum (never clamped to 0). Prose such as "coverage through B140" is deliberately not parsed.
func (c *ctx) coversDerive(state, declared string) (eff, note string) {
	d := coverDeriver{c: c, state: state, decl: declared, errw: c.s.Err}
	return d.run()
}

type coverDeriver struct {
	c           *ctx
	state, decl string
	errw        io.Writer
	base        string
	myslug      string
	unscOK      bool
	pfx         string // the block-file prefix of the focus
}

func (d *coverDeriver) warn(format string, a ...any) {
	fmt.Fprintf(d.errw, "status: WARN: "+format+"\n", a...)
}

// keep is the typed answer of a derivation that does not apply: the declared counter stays.
func (d *coverDeriver) keep(format string, a ...any) (string, string) {
	d.warn("covers_through not applied: "+format+" — using declared blocks_since_retro: %s", append(a, d.decl)...)
	return d.decl, ""
}

func (d *coverDeriver) run() (string, string) {
	slug := ""
	d.base = path.Base(d.state)
	if s, ok := strings.CutPrefix(d.base, "RESEARCH-STATE-"); ok && strings.HasSuffix(s, ".md") {
		slug = strings.TrimSuffix(s, ".md")
	}
	d.myslug = slug
	if d.myslug == "" {
		d.myslug = "root"
	}
	// More than one state file in the target is a multi-focus corpus: only a `focus=<own slug>` line is this
	// focus's evidence, and a slug shared by two state files cannot be told apart.
	multi := false
	if all := d.c.listStates(); len(all) > 1 { // RD-MULTI-FOCUS
		multi = true
		dups := 0
		for _, sf := range all {
			sfb := strings.TrimSuffix(strings.TrimPrefix(strings.TrimPrefix(path.Base(sf), "RESEARCH-STATE"), "-"), ".md")
			if sfb == "" {
				sfb = "root"
			}
			if sfb == d.myslug {
				dups++
			}
		}
		if dups > 1 {
			d.warn("covers_through not applied: focus slug [%s] is not unique among the corpus state files (split layout) — using declared blocks_since_retro: %s", d.myslug, d.decl)
			return d.decl, ""
		}
	}
	// An unscoped line is this focus's evidence only when the corpus has exactly one state file AND it is the root
	// RESEARCH-STATE.md (a lone slugged file left after a corpus shrank still needs its explicit focus=<slug>).
	d.unscOK = !multi && slug == ""
	pfx, _ := kit.DeriveFocusPrefix(d.state)
	d.pfx = pfx.Value
	if d.pfx == "" {
		if rng, _ := kit.DeriveFocusRange(d.state); rng.Value() != "" && !strings.HasPrefix(rng.Value(), "!") {
			return d.keep("range-scoped focus %s", d.base)
		}
	}
	newest, found := d.newestBlock()
	if !found {
		return d.keep("no block files found for %s", d.base)
	}
	retros, rc := d.c.retroFiles() // RD-FIND-EXIT: a partial listing is never read as the complete retro set
	if rc != 0 {
		return d.keep("retro enumeration incomplete (find exit %d)", rc)
	}
	return d.derive(retros, newest)
}

// blockIDRE is the `<prefix>(block|bloque)([0-9]+)(-[[:alnum:]_-]+)?\.md$` test of the newest-block loop, anchored at the
// base name; with no focus prefix the name needs a `.+-` before the marker.
func blockIDRE(prefix string) (*regexp.Regexp, int) {
	head := `^.+-`
	if prefix != "" {
		re, _ := grepERE(prefix)
		head = `^` + re
	}
	re, err := regexp.CompilePOSIX(head + `(block|bloque)([0-9]+)(-[[:alnum:]_-]+)?\.md$`)
	if err != nil {
		return nil, 0
	}
	return re, re.NumSubexp() - 1 // the digits are the second-to-last group, whatever groups the prefix holds
}

// newestBlock is the highest block id (at most nine digits) among the block files of this focus's scope, -1 when
// there is none: the same file predicate as the on-disk block count.
func (d *coverDeriver) newestBlock() (int, bool) {
	files := d.c.listBlockFiles(dirname(d.state), d.pfx)
	re, g := blockIDRE(d.pfx)
	if re == nil {
		return 0, false
	}
	newest, found := 0, false
	for _, f := range files {
		m := re.FindStringSubmatch(path.Base(f))
		if m == nil || len(m[g]) > 9 {
			continue
		}
		n, _ := strconv.Atoi(m[g])
		newest, found = max(newest, n), true
	}
	return newest, found
}

// derive reads the coverage lines of the retros and applies the fail-closed rules.
func (d *coverDeriver) derive(retros []string, newest int) (string, string) {
	maxcov, nret, nbad, nunsc, over := -1, 0, 0, 0, false
	badlist := ""
	for _, rf := range retros {
		src, err := os.ReadFile(d.c.abs(rf))
		if err == nil && retrogrammar.IsExcluded(retrogrammar.Parse(rf, string(src))) {
			continue // RD-EXCLUDED-RETRO
		}
		nret++
		if err != nil {
			continue // awk could not open it: no lines (awk's own complaint is not reproduced)
		}
		for _, l := range coverageLines(string(src)) {
			switch {
			case l.malformed:
				nbad++
				badlist += " " + path.Base(rf)
			case l.slug == "-" && !d.unscOK:
				nunsc++ // RD-UNSCOPED-IGNORED
			case l.slug != "-" && l.slug != d.myslug:
			case l.n > newest: // RD-OVER-RANGE
				over = true
				d.warn("covers_through B%d in %s exceeds newest block B%d on disk — value excluded (never clamped to 0)", l.n, path.Base(rf), newest)
			case l.n > maxcov:
				maxcov = l.n
			}
		}
	}
	if nbad > 0 {
		d.warn("covers_through: malformed in%s (want `covers_through: B<n>` with a number) — malformed lines ignored", badlist)
	}
	if nunsc > 0 {
		d.warn("covers_through: %d unscoped line(s) ignored — only a lone root RESEARCH-STATE.md owns unscoped evidence; write `covers_through: B<n> focus=%s` (root focus: focus=root)", nunsc, d.myslug)
	}
	if nret == 0 {
		d.warn("covers_through: absent (no retros found) — using declared blocks_since_retro: %s", d.decl)
		return d.decl, ""
	}
	if maxcov < 0 {
		if nbad == 0 && nunsc == 0 && !over {
			d.warn("covers_through: absent in %d retro(s) — using declared blocks_since_retro: %s", nret, d.decl)
		}
		return d.decl, ""
	}
	derived := newest - maxcov
	if decl, _ := intOf(d.decl); int64(derived) < decl {
		fmt.Fprintf(d.errw, "status: INFO: blocks_since_retro: %s overridden by retro coverage (covers_through B%d, newest block B%d → %d)\n", d.decl, maxcov, newest, derived)
		return strconv.Itoa(derived), fmt.Sprintf(" [derived: newest block B%d − covers_through B%d; declared counter was %s]", newest, maxcov, d.decl)
	}
	return d.decl, ""
}
