package corrections

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// Run is `rsdd verify corrections <target-dir>`.
//
// Exit: 0 every declared correction is reciprocated (or none) - 1 a one-directional correction, or an
// operational failure (a block file that could not be read) reported as a typed `degraded:` line - 2 bad
// arguments or no block files. The report is byte-identical to verify-corrections.sh's; the differences, all
// by design, are listed in tool-registry.d/verify-corrections.md.
func Run(args []string, s cli.Stdio) int { return runFS(args, s, os.ReadFile, os.ReadDir) }

// run is Run with the file reader injected, so a test can make a block file unreadable on any host.
func run(args []string, s cli.Stdio, read func(string) ([]byte, error)) int {
	return runFS(args, s, read, os.ReadDir)
}

// runFS is run with the directory lister injected as well.
func runFS(args []string, s cli.Stdio, read func(string) ([]byte, error), readDir readDirFunc) int {
	target := ""
	if len(args) > 0 {
		target = args[0]
	}
	if st, err := os.Stat(target); err != nil || !st.IsDir() {
		fmt.Fprintln(s.Err, "usage: verify-corrections.sh <target-dir>")
		return cli.ExitUsage
	}
	blocks, walkErrs := listBlocks(target, readDir)
	if len(walkErrs) > 0 { // an unreadable directory is not "no block files" and not a partial corpus: nothing was proven
		return degraded(s, "cannot read directory %s: %s", walkErrs[0].path, errText(walkErrs[0].err))
	}
	if len(blocks) == 0 {
		fmt.Fprintf(s.Err, "verify-corrections: no block files under %s\n", target)
		return cli.ExitUsage
	}
	c, err := newCheck(target, blocks, s, read, readDir)
	if err != nil {
		return degraded(s, "%s", err)
	}
	return c.run()
}

type check struct {
	target string
	blocks []string
	s      cli.Stdio
	read   func(string) ([]byte, error)

	numfile map[string]string // prefix|number -> file (the last one wins within a prefix)
	numany  map[string]string // number -> file across all prefixes (last wins)
	numcnt  map[string]int    // number -> how many prefixes carry it
	pfxset  map[string]bool
	focus   map[string]string

	files map[string][]string // path -> lines, for the target reads
	fatal error               // the first operational failure of a lookup; the run stops on it
	nouns map[string]*regexp.Regexp

	rc, unbound, negated, skipped, unchecked, ambiguous int
	negnames, skipnames                                 string
}

func newCheck(target string, blocks []string, s cli.Stdio, read func(string) ([]byte, error), readDir readDirFunc) (*check, error) {
	c := &check{
		target: target, blocks: blocks, s: s, read: read,
		numfile: map[string]string{}, numany: map[string]string{}, numcnt: map[string]int{}, pfxset: map[string]bool{},
		files: map[string][]string{}, nouns: map[string]*regexp.Regexp{},
	}
	for _, f := range blocks {
		p, n := blockKey(filepath.Base(f))
		if _, seen := c.numfile[p+"|"+n]; !seen {
			c.numcnt[n]++
		}
		c.numfile[p+"|"+n] = f
		c.numany[n] = f
		c.pfxset[p] = true
	}
	var err error
	c.focus, err = readFocuses(target, func(p string) (string, error) {
		b, err := read(p)
		return string(b), err
	}, readDir)
	return c, err
}

// resolveSlug maps a focus slug to the block prefix of an existing block file, else to the FOCUSES.md row's
// prefix; "" when the slug names no focus we can resolve (never guessed). Several prefixes that differ only by
// case resolve to the byte-smallest one, so the answer does not depend on map order.
func (c *check) resolveSlug(slug string) string {
	s := strings.ToLower(slug)
	var hits []string
	for p := range c.pfxset {
		if strings.ToLower(p) == s {
			hits = append(hits, p)
		}
	}
	if len(hits) > 0 {
		sort.Strings(hits)
		return hits[0]
	}
	return c.focus[s]
}

// targetLines are the lines of a target block file, read once. A file that cannot be read is an operational
// failure (c.fatal), never "no backlink": the legacy grep swallowed that error and reported a false FAIL.
func (c *check) targetLines(path string) []string {
	if l, ok := c.files[path]; ok {
		return l
	}
	var lines []string
	if b, err := c.read(path); err != nil {
		if c.fatal == nil {
			c.fatal = fmt.Errorf("cannot read target block %s: %s", filepath.Base(path), errText(err))
		}
	} else {
		lines = splitRecords(string(b))
	}
	c.files[path] = lines
	return lines
}

// degraded prints the typed operational-failure line and returns its exit code (1).
func degraded(s cli.Stdio, format string, a ...any) int {
	fmt.Fprintf(s.Err, "verify-corrections: degraded: "+format+"; the corpus was NOT checked\n", a...)
	return cli.ExitOperational
}

func (c *check) noun(num string) *regexp.Regexp {
	if re, ok := c.nouns[num]; ok {
		return re
	}
	re := nounRegexp(num)
	c.nouns[num] = re
	return re
}

func (c *check) out(format string, a ...any) { fmt.Fprintf(c.s.Out, format, a...) }

func (c *check) run() int {
	c.out("== verify-corrections: %s ==\n", filepath.Base(c.target))
	for _, f := range c.blocks {
		_, num := blockKey(filepath.Base(f))
		src, err := c.read(f)
		if err != nil {
			return degraded(c.s, "extractor (awk) failed on %s: %s", filepath.Base(f), errText(err))
		}
		for _, rec := range extract(string(src)) {
			c.judge(f, num, rec)
			if c.fatal != nil {
				return degraded(c.s, "%s", c.fatal)
			}
		}
	}
	if c.unbound != 0 {
		c.out("   note   %d correction verb(s) governed no bracketed [Block N] ref in their own clause (unbound, or a word that merely contains the verb) and were NOT checked (#1790)\n", c.unbound)
	}
	if c.negated != 0 {
		c.out("   note   %d correction verb(s) were negated ('corrects nothing in B21', 'no corrige') and declare nothing (#1874): %s\n", c.negated, c.negnames)
	}
	if c.skipped != 0 {
		c.out("   note   %d correction verb(s) in a non-assertive form (passive 'se corrige', conditional, or past tense) were skipped, not treated as declarations (#1835): %s\n", c.skipped, c.skipnames)
	}
	if c.rc == 0 {
		if partial := c.unchecked + c.ambiguous + c.negated; partial == 0 {
			c.out("   ok     every declared correction has its reciprocal 'corrected in BN' backlink.\n")
		} else {
			c.out("   ok-partial %d declared correction(s) NOT checked (ambiguous/missing target: %d AMBIG, %d WARN; %d negated) — see WARN/AMBIG above\n", partial, c.ambiguous, c.unchecked, c.negated)
		}
	}
	c.out("== exit %d ==\n", c.rc)
	return c.rc
}

func joinNames(list, name string) string {
	if list == "" {
		return name
	}
	return list + ", " + name
}

// judge applies one extracted record of correcting block f (number cnum).
func (c *check) judge(f, cnum string, rec record) {
	switch rec.kind {
	case kindUnbound:
		c.unbound++
		return
	case kindSkipped:
		c.skipped++
		c.skipnames = joinNames(c.skipnames, "B"+cnum)
		return
	case kindNegated:
		c.negated++
		c.negnames = joinNames(c.negnames, "B"+cnum)
		return
	}
	cls, qual, qkind := "", "", ""
	switch rec.kind {
	case kindQualified:
		qual, qkind = rec.qual, rec.qkind
	case kindAmbiguous:
		cls = rec.cls
	}
	n := trimZeros(rec.n)
	amb := func(why string) {
		c.out("   AMBIG  B%s corrects [Block %s] — %s; NOT checked as a declaration (typed ambiguous, not a refusal) [correcting: %s]\n", cnum, n, why, filepath.Base(f))
		c.ambiguous++
	}
	rd, adv := fmt.Sprintf("bare B%s reference", n), "bare"
	if cls == "mixed" {
		rd, adv = fmt.Sprintf("bracketed [Block %s] joined to a leading bare B<N> list (#1874)", n), "joined bracketed"
	}
	switch cls {
	case "object":
		amb("the verb governs a non-block object (a possessive or a gap label), not this block")
		return
	case "locator":
		amb(fmt.Sprintf("locator reference: the block only LOCATES the thing corrected ('junto a'/'alongside [Block %s]'), it carries no claim of its own", n))
		return
	case "assumption":
		amb(fmt.Sprintf("a reader-assumption correction ('the assumption behind [Block %s]'), not a claim the cited block makes", n))
		return
	case "possessive":
		amb(fmt.Sprintf("possessive 'corrigendum of [Block %s]': a reference to that block's corrigendum, not a declaration to check; the clause cannot say which block corrects which", n))
		return
	case "list":
		amb("joined-list reference: the correction clause follows the whole list, so only its FIRST ref is checked and this later one is not guessed")
		return
	}
	own, _ := blockKey(filepath.Base(f))
	softHint := ""
	qp := ""
	if qual != "" {
		qp = c.resolveSlug(qual)
		// A SOFT qualifier (a backticked token after in/of/en/de with no `focus` word: probably a file name) or a LEAD
		// one (a backticked token right before the ref: probably a code identifier, #1874 item 7) that names no focus
		// falls back to the strict unqualified lookup (#1868 review); only a HARD one is a typed ambiguity.
		if qp == "" && (qkind == "soft" || qkind == "lead") {
			softHint, qual = qual, ""
		}
	}
	var tgt string
	if qual != "" {
		// An explicit focus qualifier (#1868 item 1): the target lives in THAT focus, never in the own prefix.
		if qp == "" {
			amb(fmt.Sprintf("cross-focus qualifier `%s` names no focus prefix (no block file carries it, no FOCUSES.md row maps it); target NOT guessed", qual))
			return
		}
		tgt = c.numfile[qp+"|"+n]
		if tgt == "" {
			c.out("   WARN   B%s declares a correction of [Block %s] of focus `%s` but no block-%s file exists in its prefix '%s'; NOT checked\n", cnum, n, qual, n, qp)
			c.unchecked++
			return
		}
	} else {
		tgt = c.numfile[own+"|"+n] // the correcting block's OWN prefix first (#1835 item 1)
		if tgt == "" {
			switch cnt := c.numcnt[n]; cnt {
			case 0:
			case 1:
				tgt = c.numany[n]
			default:
				if cls == "bare" || cls == "mixed" {
					amb(fmt.Sprintf("%s, number ambiguous across %d other prefixes (advisory)", rd, cnt))
					return
				}
				c.out("   WARN   B%s declares a correction of [Block %s] but no block-%s file exists in its prefix '%s' and the number is ambiguous across %d other prefixes; NOT checked\n", cnum, n, n, own, cnt)
				c.unchecked++
				return
			}
		}
		if tgt == "" {
			if cls == "bare" || cls == "mixed" {
				amb(fmt.Sprintf("%s, no block-%s file exists on disk (advisory)", rd, n))
				return
			}
			c.out("   WARN   B%s declares a correction of [Block %s] but no block-%s file exists on disk\n", cnum, n, n)
			c.unchecked++
			return
		}
	}
	// A block correcting ITSELF (the RESOLVED target is this very file) is not a cross-block backlink.
	if tgt == f {
		return
	}
	// Reciprocal backlink: the target file must carry a backlink-vocabulary word AND name B<c>/Block <c>.
	lines := c.targetLines(tgt)
	if c.fatal != nil || reciprocated(lines, cnum, c.noun(cnum)) {
		return // a failed read is reported by the caller, never as a finding
	}
	if cls == "bare" || cls == "mixed" {
		amb(fmt.Sprintf("%s with no reciprocal backlink in %s (advisory: a %s ref is checked, never refused)", rd, filepath.Base(tgt), adv))
		return
	}
	hint := ""
	if softHint != "" {
		hint = fmt.Sprintf(" — hint: the backticked token `%s` named no focus (no block prefix, no FOCUSES.md row), so the own prefix was searched; add a FOCUSES.md row for it, or write the word `focus` next to it (of the `%s` focus) to resolve it", softHint, softHint)
	}
	c.out("   FAIL   B%s corrects [Block %s] but %s has no reciprocal backlink to B%s (accepted: 'corrected in'/'corregido en'/'refined in'/corrigendum/erratum/'CORRECCIÓN — [Block %s]' naming it) (§14) [correcting: %s]%s\n", cnum, n, filepath.Base(tgt), cnum, cnum, filepath.Base(f), hint)
	c.rc = 1
}
