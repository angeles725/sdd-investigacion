package show

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kit"
)

// Port of the --sync-state mode of research-sdd-status.sh: seed or refresh the research-state.v1 envelope of the
// targeted RESEARCH-STATE*.md. Every field is derived per state file, from its own backlog and its own directory,
// with the same helpers the status display uses; the figures that are declared in prose (gaps_closed, known_gaps)
// are kept when the derivation cannot disprove them and the keep is always reported.

// syncOr answers --sync-state and leaves every other mode to rest.
func syncOr(rest tail) tail {
	return func(c *ctx) int {
		if c.opts.mode == modeSync {
			return c.syncState()
		}
		return rest(c)
	}
}

// counterOrder is _OWNED_COUNTERS in the order the reconciliation walks it.
var counterOrder = strings.Fields(ownedCounters)

// syncState is the whole mode. The scope guard and the blocked_open pre-pass run before the first write, so a
// refusal never leaves a half-rewritten set of files.
func (c *ctx) syncState() int {
	states, _ := kit.ListStateFiles(c.abs(c.target))
	if c.opts.focus != "" || c.opts.root {
		focused := c.state // ROOT-SYNC-SELECT: the root was resolved (and vetted) at startup
		if !c.opts.root {
			p, err := kit.ResolveStateFile(c.abs(c.target), kit.ResolveOptions{FocusSet: true, Focus: c.opts.focus})
			if rc := stateRC(err); rc > 2 {
				fmt.Fprintf(c.s.Err, "research-sdd-status: state-file resolution failed (rc %d)\n", rc)
				return 1
			}
			focused = c.show(p)
		}
		if !c.isFile(focused) {
			suffix := ""
			if c.opts.focus != "" {
				suffix = "-" + c.opts.focus
			}
			fmt.Fprintf(c.s.Err, "sync-state: no RESEARCH-STATE%s.md under %s\n", suffix, c.target)
			return 1
		}
		states = []string{focused}
	}
	if c.opts.focus == "" && !c.opts.root && len(states) > 1 { // SYNC-SCOPE-GUARD
		fmt.Fprintf(c.s.Err, "sync-state: WARN: %d RESEARCH-STATE files found under %s — use --focus <slug> (or --root for the un-suffixed RESEARCH-STATE.md) to target one focus (refusing without explicit scope)\n", len(states), c.target)
		return 1
	}
	blocked := map[string]int{} // BO-DEGRADED-SYNC: every file is derived before the first write
	for i, st := range states {
		states[i] = c.readlinkF(st)
		c.state = states[i]
		n, rc := c.blockedOpen()
		if rc != 0 {
			fmt.Fprintf(c.s.Err, "research-sdd-status: blocked_open derivation degraded (blocked_open_count rc %d on %s) — NO envelope written\n", rc, c.state)
			return 1
		}
		blocked[c.state] = n
	}
	for _, st := range states {
		c.state = st
		if rc := c.syncOne(blocked[st]); rc != 0 {
			return rc
		}
	}
	return 0
}

// readlinkF is `readlink -f p || p`: the canonical absolute path, so the write goes THROUGH a symlinked state file.
func (c *ctx) readlinkF(p string) string {
	if r, err := filepath.EvalSymlinks(c.abs(p)); err == nil {
		return r
	}
	return p
}

// derived is the set of counters of one state file as the envelope writes them. The figures that can be kept from
// a declaration stay strings, because what is kept is written back as it was declared.
type derived struct {
	cb, gc, kg, io, req, bo, def, uf string
}

func (d *derived) field(name string) *string {
	switch name {
	case "covered_blocks":
		return &d.cb
	case "gaps_closed":
		return &d.gc
	case "known_gaps":
		return &d.kg
	case "investigable_open":
		return &d.io
	case "requires_execution_open":
		return &d.req
	case "blocked_open":
		return &d.bo
	case "deferred_open":
		return &d.def
	}
	return &d.uf
}

// onlyHas is only_has: the counter will be written (no --only, or named in it).
func (c *ctx) onlyHas(name string) bool {
	return !c.opts.onlySet || strings.Contains(","+c.opts.onlyList+",", ","+name+",")
}

// syncOne derives and rewrites the file c.state; blocked is its pre-derived blocked_open.
func (c *ctx) syncOne(blocked int) int {
	base := filepath.Base(c.state)
	text := c.stateText()
	warn := func(format string, a ...any) { fmt.Fprintf(c.s.Err, format, a...) }

	// BACKLOG PARSE CHECK: an unparseable backlog must not seed a wrong investigable_open.
	rows, rowsWarn := backlogRows(text, false)
	fmt.Fprint(c.s.Err, rowsWarn)
	for _, r := range splitLines(rows) {
		if strings.HasPrefix(r, "INVALID_PRIORITY") { // BP-SYNC-INVALID-REFUSE
			warn("sync-state: ERROR: %s: backlog NOT FULLY PARSEABLE — unknown priority value(s) found\n", base)
			warn("  (diagnostics above name the offending row(s); envelope NOT rewritten — fix the priority value(s) first)\n")
			return 1
		}
	}

	// block_scope is carried through; only legal values are used, an illegal one stays for verify-state to FAIL on.
	scope, _ := c.envGet("block_scope")
	if scope == "" {
		if raw := c.envProbe("block_scope"); raw == "per-focus" || raw == "shared-global" { // BS-SYNC-PROBE
			scope = raw
		}
	}
	extra := c.carriedLines(text) // PREAMBLE-CARRY-FORWARD

	d := derived{}
	pfx, _ := kit.DeriveFocusPrefix(c.state)
	var rng kit.FocusRange
	if pfx.Value == "" {
		rng, _ = kit.DeriveFocusRange(c.state)
		diags, _ := kit.FocusRangeReport(c.state) // RANGE-REPORT
		for _, dg := range diags {
			warn("sync-state: %s: RESEARCH-STATE.md: %s\n", dg.Kind, dg.Text)
		}
	}
	ranged := pfx.Value == "" && rng.State == kit.RangeOK
	switch {
	case scope == "shared-global":
		if n := c.countAttributedSG(); n > 0 { // SG-ATTR-SYNC
			d.cb = strconv.Itoa(n)
		} else {
			d.cb = "0"                                                                                                                                                                                                     // SG-ZERO-UNVERIFIABLE
			warn("sync-state: WARN: %s: shared-global focus has no attributed block ids (no B<n> in ## Covered blocks or ## Iteration history) — seeding covered_blocks=0; add B<n> ids to make this verifiable.\n", base) // SG-ZERO-WARN
		}
	case pfx.Value != "":
		d.cb = strconv.Itoa(c.blockFileCount(pfx.Value))
	case ranged:
		d.cb = strconv.Itoa(c.rangeBlockCount(rng)) // RANGE-SYNC-COUNT
	default:
		d.cb = strconv.Itoa(c.blockFileCount(""))
	}
	// ROOT-CORPUS-WIDE: the un-suffixed root of a multi-focus corpus with no prefix or range is counted corpus-wide.
	corpusWide := false
	if base == "RESEARCH-STATE.md" && pfx.Value == "" && !ranged && scope != "shared-global" {
		all, _ := kit.ListStateFiles(c.abs(c.target))
		corpusWide = len(all) > 1
	}

	io, _ := c.countInvestigable()
	d.io = strconv.Itoa(io)
	d.bo = strconv.Itoa(blocked)
	d.def = strings.TrimRight(c.countDeferred(), "\n")
	ipb, _ := c.inplaceBlocked()
	// requires_execution_open prefers the backlog-derived count and falls back to the prose and the old envelope.
	if dreq := c.countRequiresExecution(); dreq > 0 {
		d.req = strconv.Itoa(dreq)
	} else {
		prev, _ := c.envGet("requires_execution_open")
		d.req = pick(c.reqProse(), prev)
	}
	cov := c.covRatioOf()
	covNum, _, _ := strings.Cut(cov, "/")
	cmKG := cov[strings.LastIndex(cov, "/")+1:]
	dkgTotal := c.countAllKnownGaps() + atoiOrZero(d.def)
	unc := c.countUncountedRows()
	declKG, _ := c.envGet("known_gaps")
	declGC, _ := c.envGet("gaps_closed")
	plain := 0
	for _, r := range splitLines(rows) {
		if r != "" && !strings.HasPrefix(r, "INVALID_PRIORITY") {
			plain++
		}
	}
	if unc > 0 {
		warn("sync-state: WARN: %s: %d backlog row(s) are NOT counted (undeclared tier / malformed row / table without a Priority header) — known_gaps and gaps_closed are LOWER bounds, verify against the prose.\n", base, unc)
	}
	// KG-LOWER-BOUND (#1307): rows excluded for an undeclared tier make the derived total a lower bound.
	lowerBound := false
	declKGv, declKGok := intOf(declKG)
	if declKGok && declKGv >= int64(dkgTotal) {
		switch {
		case unc > 0:
			lowerBound = true
			warn("sync-state: WARN: %s: keeping the declared known_gaps=%s (derived %d is below it); gaps_closed = max(declared, derived).\n", base, declKG, dkgTotal)
			if declKGv > int64(dkgTotal+unc) { // KG-LB-UPPER (#1350)
				warn("sync-state: WARN: %s: declared known_gaps=%s exceeds what the parser can count (derived %d + %d uncounted) — NOT rewritten; it may include gaps tracked outside the backlog table (prose, other headings) — verify by hand.\n", base, declKG, dkgTotal, unc)
			}
		case cmKG == "" && plain+atoiOrZero(d.def) == 0: // B1-NO-UPPER (#1350)
			lowerBound = true
			warn("sync-state: WARN: %s: the backlog has only closed-class rows and there is no Coverage metric N/M — derived known_gaps=%d is not evidence the declared total shrank; keeping the declared known_gaps/gaps_closed.\n", base, dkgTotal)
		}
	}
	open := func() int { return io + atoiOrZero(d.req) + blocked + atoiOrZero(d.def) + ipb }
	cmNum, cmIsInt := intOf(orDefault(cmKG, "0"))
	switch {
	case lowerBound: // KG-LB-KEEP: the declared total, and gaps_closed = max(declared, derived)
		d.kg = declKG
		c.warnInplaceBlocked(base, ipb) // INPLACE-BLOCKED-WARN
		derivedGC := max(dkgTotal-open(), 0)
		gc := declGC
		if _, ok := intOf(gc); !ok {
			gc = "0"
		}
		if gv, _ := intOf(gc); int64(derivedGC) > gv {
			gc = strconv.Itoa(derivedGC)
		}
		if gv, _ := intOf(gc); gv > declKGv {
			gc = d.kg
		}
		d.gc = gc
	case cmIsInt && int64(dkgTotal) > cmNum: // KG-BACKLOG-GATE
		d.kg = strconv.Itoa(dkgTotal) // KG-BACKLOG-EXCEEDS
		gc := dkgTotal - open()       // KG-BACKLOG-GC, INPLACE-GC-SUBTRACT
		c.warnInplaceBlocked(base, ipb)
		d.gc = strconv.Itoa(gc)
		if gc < 0 { // GC-CLAMP (kit #983): open buckets can overlap; keep the declared value, 0 when none
			if c.onlyHas("gaps_closed") {
				warn("sync-state: WARN: %s: derived gaps_closed=%d is negative (known_gaps %d < open buckets io+req+bo+def+in-place-blocked = %d; a row is probably counted in two buckets) — clamp: NOT written, keeping the declared value (0 when none); reconcile the backlog by hand.\n", base, gc, dkgTotal, open())
			}
			d.gc = pick("", declGC) // GC-CLAMP-KEEP
		}
		warn("WARN: Coverage prose denominator is stale (coverage metric %s/%s, backlog has %d known gaps) — update Coverage metric to %s/%s\n", covNum, orDefault(cmKG, "?"), dkgTotal, d.gc, d.kg)
	default:
		d.kg = pick(cmKG, declKG)
		d.gc = pick(covNum, declGC)
	}
	c.keepDeclared(&d)

	// undocumented_findings: absent, valid or unparseable are three different cases, never one silent 0.
	rawUF, _ := c.envGet("undocumented_findings")
	if rawUF == "" {
		rawUF = c.envProbe("undocumented_findings") // UF-SYNC-PROBE: the no-space and indented forms
	}
	switch {
	case rawUF == "":
		d.uf = "0"
	default:
		d.uf = rawUF
		if strings.Trim(rawUF, "0123456789") != "" {
			warn("sync-state: WARN: %s: undocumented_findings=%s is not a non-negative integer; value NOT replaced with 0 — fix manually and re-run --sync-state.\n", base, rawUF)
		}
	}

	// declared-vs-derived reconciliation (kit #911): only meaningful when a fence already exists.
	ufOmit, cwKept := false, ""
	if hasEnvOpen(text) {
		changed := ""
		for _, name := range counterOrder {
			nv := d.field(name)
			ov, have := c.envRaw(name)
			if name == "undocumented_findings" && !have {
				ufOmit = true // UF-NO-INVENT
				continue
			}
			if c.opts.onlySet && have && !c.onlyHas(name) {
				*nv = ov // ONLY-KEEP-DECLARED
			}
			if name == "covered_blocks" && corpusWide && have && !c.opts.onlySet {
				cwKept, *nv = *nv, ov // CW-KEEP-DECLARED
			}
			if !have {
				ov = "(absent)"
			}
			if ov != *nv {
				changed += fmt.Sprintf("sync-state: CHANGED %s %s: %s -> %s\n", base, name, ov, *nv)
			}
		}
		fmt.Fprint(c.s.Out, changed)
	}
	if corpusWide && c.onlyHas("covered_blocks") { // ROOT-CORPUS-WIDE-WARN
		if cwKept != "" {
			warn("sync-state: WARN: %s: covered_blocks would be %s, the CORPUS-WIDE block count (no block prefix or B<a>–B<b> range for the root focus in FOCUSES.md), not this focus's number — KEPT the declared %s; name covered_blocks in --only to write it.\n", base, cwKept, d.cb)
		} else {
			warn("sync-state: WARN: %s: covered_blocks=%s written is the CORPUS-WIDE block count (no block prefix or B<a>–B<b> range for the root focus in FOCUSES.md) — not scoped to this focus; verify it.\n", base, d.cb)
		}
	}

	if err := c.rewrite(text, renderEnvelope(&d, ufOmit, extra)); err != nil {
		warn("sync-state: ERROR: %s: rewriting the envelope failed (%v) — file NOT modified.\n", c.state, err)
		return 1
	}
	fmt.Fprintf(c.s.Out, "sync-state: wrote %s\n", c.state)
	uf := d.uf
	if ufOmit {
		uf = "-"
	}
	fmt.Fprintf(c.s.Out, "sync-state: %s → covered_blocks=%s gaps_closed=%s known_gaps=%s investigable_open=%s requires_execution_open=%s blocked_open=%s deferred_open=%s undocumented_findings=%s\n",
		base, d.cb, d.gc, d.kg, d.io, d.req, d.bo, d.def, uf)
	return 0
}

// keepDeclared is DECLARED-KEEP (#1637): gaps_closed and known_gaps are declared-only figures (read from prose, not
// disk-validated). A declared integer ABOVE the derived value is kept and the advisory names both, because the
// derivation cannot tell a truthful +1 from a stale over-count. If the kept pair would leave gaps_closed above
// known_gaps, neither declared value is kept. --only is the explicit opt-in to write the derived value.
func (c *ctx) keepDeclared(d *derived) {
	if c.opts.onlySet {
		return
	}
	keepGC, keepKG, advisory := d.gc, d.kg, ""
	for _, name := range []string{"gaps_closed", "known_gaps"} {
		decl, _ := c.envGet(name)
		dv, ok := intOf(decl)
		if !ok {
			continue
		}
		der := d.gc
		if name == "known_gaps" {
			der = d.kg
		}
		if dv2, _ := intOf(der); dv <= dv2 { // declared <= derived: the derivation is evidence of an undercount
			continue
		}
		if name == "gaps_closed" {
			keepGC = decl
		} else {
			keepKG = decl
		}
		advisory += fmt.Sprintf("sync-state: DECLARED %s=%s (derived %s) — kept; verify the declared value or correct it by hand\n", name, decl, der)
	}
	gcv, _ := intOf(keepGC)
	kgv, _ := intOf(keepKG)
	if gcv > kgv && (keepGC != d.gc || keepKG != d.kg) { // DECLARED-PAIR-CHECK
		gc, _ := c.envGet("gaps_closed")
		kg, _ := c.envGet("known_gaps")
		fmt.Fprintf(c.s.Out, "sync-state: DECLARED gaps_closed=%s known_gaps=%s inconsistent with derived %s/%s — derived pair written; correct the declaration by hand\n", gc, kg, d.gc, d.kg)
		return
	}
	fmt.Fprint(c.s.Out, advisory) // DECLARED-KEEP-ADVISORY
	d.gc, d.kg = keepGC, keepKG
}

// envProbe is the whitespace-tolerant probe of the envelope for `key:` (indented and no-space forms alike): the
// text after the key on the first line that has it, leading blanks dropped.
func (c *ctx) envProbe(key string) string {
	for _, line := range envLines(c.stateText()) {
		if rest, ok := strings.CutPrefix(strings.TrimLeft(line, cSpace), key+":"); ok {
			return strings.TrimLeft(rest, cSpace)
		}
	}
	return ""
}

// carriedLines is the generalized preamble carry-forward: every envelope line whose key is not one of the owned
// counters, normalized (leading blanks stripped, one space after the colon, trailing blanks stripped), joined by
// newlines. Empty when there is no fence yet.
func (c *ctx) carriedLines(text string) string {
	if !hasEnvOpen(text) {
		return ""
	}
	var out []string
	for _, line := range envLines(text) {
		key, val, ok := strings.Cut(strings.TrimLeft(line, cSpace), ":")
		if !ok || key == "schema" || slices.Contains(counterOrder, key) {
			continue
		}
		out = append(out, key+": "+strings.Trim(val, cSpace))
	}
	return strings.Join(out, "\n")
}

// hasEnvOpen is `grep -q '<!-- research-state.v1 -->'`: some LINE carries the opening marker.
func hasEnvOpen(text string) bool {
	for _, l := range splitLines(text) {
		if envOpen.MatchString(l) {
			return true
		}
	}
	return false
}

// blockFileCount is `find "$(dirname "$state")" -maxdepth 1 -type f -name '*.md' | block_file_filter [prefix] | wc -l`.
func (c *ctx) blockFileCount(prefix string) int {
	dir := dirname(c.state)
	ents, err := os.ReadDir(c.abs(dir))
	if err != nil {
		return 0
	}
	var lines []string
	for _, e := range ents {
		// find -type f -name '*.md': the .md test is the filter's own (`\.md$`), so only the file type is checked here.
		if e.Type().IsRegular() {
			lines = append(lines, strings.TrimSuffix(dir, "/")+"/"+e.Name())
		}
	}
	re, unclosed := grepERE(prefix)
	out, err := kit.FilterBlockFiles(lines, false, re)
	if errors.Is(err, kit.ErrBadPattern) && unclosed { // grep's own complaint, on the script's stderr
		fmt.Fprintln(c.s.Err, `grep: Unmatched ( or \(`)
	}
	return len(out)
}

// grepERE adapts a prefix to Go's POSIX syntax where GNU grep -E differs for the faults a slug can carry: a lone
// `)` is a literal in GNU ERE (core/kit DEFERRED.md F8 rejects it), so it is escaped. unclosed reports an unmatched
// `(`, which both reject; grep's own wording for it is reproduced by the caller.
func grepERE(re string) (adapted string, unclosed bool) {
	var b strings.Builder
	depth := 0
	for i := 0; i < len(re); i++ {
		switch re[i] {
		case '\\':
			if i+1 < len(re) {
				b.WriteByte(re[i])
				i++
			}
		case '(':
			depth++
		case ')':
			if depth == 0 {
				b.WriteByte('\\')
			} else {
				depth--
			}
		}
		b.WriteByte(re[i])
	}
	return b.String(), depth > 0
}

// rangeBlockCount is focus_range_block_count: the distinct block numbers inside the root's range that no other
// FOCUSES.md row claims. A directory that cannot be scanned counts 0, as the awk over an empty stream does.
func (c *ctx) rangeBlockCount(r kit.FocusRange) int {
	s, err := kit.ScanFocusRange(c.abs(dirname(c.state)), r.Lo, r.Hi, c.state)
	if err != nil {
		return 0
	}
	return s.Count
}

// renderEnvelope is render_envelope.
func renderEnvelope(d *derived, ufOmit bool, extra string) string {
	var b strings.Builder
	b.WriteString("<!-- research-state.v1 -->\nschema: research-state.v1\n")
	for _, name := range counterOrder[:7] {
		fmt.Fprintf(&b, "%s: %s\n", name, *d.field(name))
	}
	if !ufOmit { // UF-NO-INVENT: never seed a manually-maintained 0 into an existing fence
		fmt.Fprintf(&b, "undocumented_findings: %s\n", d.uf)
	}
	if extra != "" {
		b.WriteString(extra + "\n")
	}
	b.WriteString("<!-- /research-state.v1 -->")
	return b.String()
}

// rewrite replaces the envelope in the file at c.state, or inserts it after the intro blockquote (appends it at
// the end when there is none), through a temp file in the same directory and a rename: atomic on one filesystem.
// The temp file is created 0600 and the rename keeps that mode, exactly as mktemp and mv do in the script. The
// replacement text goes through awk -v's escape processing first, as it does there.
func (c *ctx) rewrite(text, envelope string) error {
	repl := awkVEscapes(envelope)
	var b strings.Builder
	if hasEnvOpen(text) { // the fence EXISTS: replace only between the markers
		skip := false
		for _, line := range splitLines(text) {
			switch {
			case envOpen.MatchString(line):
				b.WriteString(repl + "\n")
				skip = true
			case skip && envClose.MatchString(line):
				skip = false
			case skip:
			default:
				b.WriteString(line + "\n")
			}
		}
	} else { // the fence is ABSENT: after the first contiguous run of `>` lines, else at the end
		done, inQuote := false, false
		for _, line := range splitLines(text) {
			if !done {
				if strings.HasPrefix(line, ">") {
					inQuote = true
				} else if inQuote {
					b.WriteString(repl + "\n\n")
					done = true
				}
			}
			b.WriteString(line + "\n")
		}
		if !done {
			b.WriteString("\n" + repl + "\n")
		}
	}
	tmp, err := os.CreateTemp(c.abs(dirname(c.state)), ".rsdd-sync.*")
	if err != nil {
		return err
	}
	_, err = tmp.WriteString(b.String())
	if cerr := tmp.Close(); err == nil {
		err = cerr
	}
	if err == nil {
		err = os.Rename(tmp.Name(), c.abs(c.state))
	}
	if err != nil {
		_ = os.Remove(tmp.Name())
	}
	return err
}

// awkVEscapes is the escape processing gawk applies to a `-v name=value` assignment: \a \b \f \n \r \t \v, \\ \" \/,
// one to three octal digits, \x and up to two hex digits; any other escaped character stands for itself and a
// lone trailing backslash is dropped.
func awkVEscapes(s string) string {
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		if s[i] != '\\' {
			b.WriteByte(s[i])
			continue
		}
		i++
		if i == len(s) {
			break
		}
		switch e := s[i]; {
		case strings.IndexByte("abfnrtv", e) >= 0:
			b.WriteByte("\a\b\f\n\r\t\v"[strings.IndexByte("abfnrtv", e)])
		case e >= '0' && e <= '7':
			v := 0
			for n := 0; n < 3 && i < len(s) && s[i] >= '0' && s[i] <= '7'; n++ {
				v = v*8 + int(s[i]-'0')
				i++
			}
			i--
			b.WriteByte(byte(v))
		case e == 'x' && i+1 < len(s) && isHex(s[i+1]):
			v := 0
			for n := 0; n < 2 && i+1 < len(s) && isHex(s[i+1]); n++ {
				i++
				v = v*16 + hexVal(s[i])
			}
			b.WriteByte(byte(v))
		case e == '\n': // a backslash-newline is a line continuation: both vanish
		default:
			b.WriteByte(e)
		}
	}
	return b.String()
}

func isHex(b byte) bool { return isDigit(b) || b >= 'a' && b <= 'f' || b >= 'A' && b <= 'F' }

func hexVal(b byte) int {
	switch {
	case isDigit(b):
		return int(b - '0')
	case b >= 'a':
		return int(b-'a') + 10
	}
	return int(b-'A') + 10
}

// intOf is a bash integer operand: digits only, within int64 (a longer one makes `[` fail).
func intOf(s string) (int64, bool) {
	if s == "" || strings.Trim(s, "0123456789") != "" {
		return 0, false
	}
	n, err := strconv.ParseInt(s, 10, 64)
	return n, err == nil
}

// atoiOrZero is `${v:-0}` in arithmetic for a value that is always an integer or empty.
func atoiOrZero(s string) int {
	n, _ := intOf(s)
	return int(n)
}

// orDefault is `${v:-d}`.
func orDefault(v, d string) string {
	if v == "" {
		return d
	}
	return v
}
