package verify

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"unicode/utf8"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kit"
)

// Port of research-sdd/toolbelt/verify-registry.sh (units U2.7a/b; U2.7c is the hook-wiring part).
//
//	rsdd verify registry [--kit <kit-root>] [--json]
//
// It reconciles the master registry (<kit>/TARGETS.md) against the corpora on disk: every row's claimed block
// count, retro count and maturity fields, hook claims, row hygiene and the kit's own registration. WARN-only and
// READ-ONLY (propose-never-apply): findings never change the exit code. Exit 0 report (even with findings), 1
// operational failure (TARGETS.md missing, no usable path, every registered directory absent in the default
// mode), 2 usage. The report text and --json envelope are byte-identical to the script's.
//
// The sections that need lib/hook-wiring.sh (hook claims, the wired-hook execute bit) and
// verify-session-budget.sh run through registryHooks (productionHooks: core/hookwiring in process, the
// session-budget meter through SessionBudgetRunner). A run that had to skip any of them says so on stderr
// (`degraded: ... skipped`): a skipped check is never a clean one.
//
// Differences, by design:
//
//   - The script finds its kit from its own location; a binary cannot, so the shim passes --kit. Without it the
//     kit is resolved like the portable hooks do (core/kit ResolveKitScript).
//   - --json needs no jq here, so the script's `degraded: jq not found` (exit 3) states do not exist.
//   - No sourced helper can be missing or fail to define a function, so those exit-1 guards do not exist.
//   - A message field that contains the unit separator U+001F is carried intact; the script's jq round trip
//     would split it into extra fields.
//   - RSDD_REGISTRY_TOL that is not an integer never reports drift (the script's `[` prints a shell error and
//     reads the comparison as false); RSDD_ROW_MAXLEN compares numerically when it is a number and as text when
//     not, as awk does. Counts above int64 clamp instead of wrapping.
//   - Word splitting and globbing of target paths (`for p in $paths`) is reproduced as whitespace splitting only;
//     a path with a glob metacharacter is not expanded.
//   - The length of a cell in the row-hygiene lint is counted the way gawk counts it: characters under a UTF-8
//     locale (LC_ALL, LC_CTYPE, LANG), bytes otherwise; another awk (mawk counts bytes always) may differ.

const (
	registryUsage  = "usage: verify-registry.sh [--json]\n"
	envelopeSchema = "research-sdd.verify-registry/v1"
)

var (
	reClaimed     = regexp.MustCompile(`(?i)[0-9]+[[:space:]]*(md|blocks)\b`)
	reDigits      = regexp.MustCompile(`[0-9]+`)
	reRetroClaim  = regexp.MustCompile(`(?i)[0-9]+[[:space:]]+retros?`)
	reRowToken    = regexp.MustCompile("`(/|\\$(\\{RESEARCH_HOME\\}|RESEARCH_HOME)/)[^`]+`")
	reRowNum      = regexp.MustCompile(`^[[:space:]]*\|[[:space:]]*[0-9]+[[:space:]]*\|`)
	reParen       = regexp.MustCompile(`\([^)]+\)`)
	reNC          = regexp.MustCompile(`/ nc[ /;)|]`)
	reMasterRow   = regexp.MustCompile(`^\|[[:space:]]*[0-9]+[[:space:]]*\|`)
	reCatTotal    = regexp.MustCompile(`(?i)total`)
	reCatBlocks   = regexp.MustCompile(`(?i)[0-9]+[[:space:]]*(bloques?|blocks?)`)
	rePipeLine    = regexp.MustCompile(`^[[:space:]]*\|`)
	reSepLine     = regexp.MustCompile(`^[[:space:]]*\|[[:space:]]*-`)
	reUnclassName = regexp.MustCompile(`(?i)/(block|bloque)[_-]?[0-9]`)
	reHookYes     = regexp.MustCompile(`(?i)^hook[[:space:]]+yes([^a-zA-Z0-9]|$)`)
	reHookNo      = regexp.MustCompile(`(?i)^hook[[:space:]]+no([^a-zA-Z0-9]|$)`)
	reHookFileYes = regexp.MustCompile(`(?i)^hook[[:space:]]+file[[:space:]]+yes([^a-zA-Z0-9]|$)`)
	reAggChars    = regexp.MustCompile(`^aggregate: ([0-9]*) chars.*`)
	reNumber      = regexp.MustCompile(`^[ \t]*[-+]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][-+]?[0-9]+)?[ \t]*$`)

	// The documented maturity-field schema (TARGETS.md legend), one anchored pattern per known form.
	reTokBlocks = regexp.MustCompile(`(?i)^[0-9]+[[:space:]]+(md|blocks?)[[:space:]]*(@[0-9]{4}-[0-9]{2}-[0-9]{2}([[:space:]]*,[[:space:]]*ACTIVE)?)?$`)
	reTokFocus  = regexp.MustCompile(`(?i)^[0-9]+[[:space:]]+focus(es)?$`)
	reTokRuns   = regexp.MustCompile(`(?i)^[0-9]+[[:space:]]+runs?$`)
	reTokRetros = regexp.MustCompile(`(?i)^[0-9]+[[:space:]]+retros?([[:space:]]+\+.*)?$`)
	reTokGaps   = regexp.MustCompile(`(?i)^[0-9]+-of-[0-9]+[[:space:]]+gaps?$`)
	reTokGit    = regexp.MustCompile(`^git[[:space:]]+(yes|no)$`)
	reTokRemote = regexp.MustCompile(`^remote[[:space:]]+(yes|no)$`)
	reTokHook   = regexp.MustCompile(`^hook[[:space:]]`)
)

// RunRegistry is `rsdd verify registry`.
func RunRegistry(args []string, s cli.Stdio) int {
	r := &registry{s: s, hooks: newRegistryHooks(s)}
	kitFlag := ""
	for i := 0; i < len(args); i++ {
		switch a := args[i]; a {
		case "--json":
			r.json = true
		case "--kit":
			if i+1 >= len(args) {
				fmt.Fprintf(s.Err, "verify-registry: --kit needs a directory\n%s", registryUsage)
				return cli.ExitUsage
			}
			i++
			kitFlag = args[i]
		default:
			fmt.Fprintf(s.Err, "verify-registry: unknown argument: %s\n%s", a, registryUsage)
			return cli.ExitUsage
		}
	}
	rc := r.run(kitFlag)
	if r.skipped > 0 {
		fmt.Fprintf(s.Err, "verify-registry: degraded: %d hook-wiring/session-budget check(s) skipped; the session-budget meter is not wired into this build, so this report is INCOMPLETE\n", r.skipped)
	}
	return rc
}

type registry struct {
	s     cli.Stdio
	hooks registryHooks
	json  bool

	kitRoot, toolbelt string
	tol               string
	skipped           int // checks the hooks could not run

	human strings.Builder // the report; printed unless --json mutes it
	items []regItem

	checked, drift, retroDrift, unresolved, attention, absentPaths int
	dirReached                                                     bool
	skippedCount, ntargets, rowlint                                int
}

func (r *registry) env(k string) string { return r.s.Env(k) }

// finding prints the human line `SEV  text` and records it for --json (_vr_finding).
func (r *registry) finding(kind, sev, target, text string) {
	r.human.WriteString(sev + "  " + text + "\n")
	r.items = append(r.items, regItem{kind, sev, target, text})
}

func (r *registry) record(kind, sev, target, text string) {
	r.items = append(r.items, regItem{kind, sev, target, text})
}

func (r *registry) say(format string, a ...any) { fmt.Fprintf(&r.human, format, a...) }

func (r *registry) counts() regCounts {
	return regCounts{r.ntargets, r.absentPaths, r.skippedCount, r.checked, r.drift, r.retroDrift, r.unresolved, r.rowlint, r.attention}
}

// flush prints the human report (default mode) or the envelope (--json) on stdout.
func (r *registry) flush(allAbsent bool) {
	if r.json {
		io.WriteString(r.s.Out, registryEnvelope(allAbsent, r.counts(), r.items)) //nolint:errcheck
		return
	}
	io.WriteString(r.s.Out, r.human.String()) //nolint:errcheck
}

func (r *registry) resolveKit(flag string) (string, bool) {
	root := flag
	if root == "" {
		p, warns, err := kit.ResolveKitScript("toolbelt/verify-registry.sh", r.env)
		for _, w := range warns {
			fmt.Fprintln(r.s.Err, w)
		}
		if err != nil {
			fmt.Fprintf(r.s.Err, "verify-registry: cannot resolve the kit: %v\n", err)
			return "", false
		}
		root = filepath.Dir(filepath.Dir(p))
	}
	if !filepath.IsAbs(root) {
		root = filepath.Join(r.s.Cwd, root)
	}
	if phys, err := filepath.EvalSymlinks(root); err == nil {
		root = phys
	}
	return root, true
}

func (r *registry) run(kitFlag string) int {
	var ok bool
	if r.kitRoot, ok = r.resolveKit(kitFlag); !ok {
		return cli.ExitOperational
	}
	r.toolbelt = r.kitRoot + "/toolbelt"
	if t, ok := r.hooks.(toolbeltSetter); ok {
		t.setToolbelt(r.toolbelt)
	}
	targetsMD := r.kitRoot + "/TARGETS.md"
	if !isFileOS(targetsMD) {
		fmt.Fprintf(r.s.Err, "verify-registry: cannot find %s\n", targetsMD)
		return cli.ExitOperational
	}
	r.tol = r.env("RSDD_REGISTRY_TOL")
	if r.tol == "" {
		r.tol = "2"
	}
	src, _ := kit.ReadTargets(targetsMD) // unreadable reads as empty, as the script's `grep 2>/dev/null` does
	tlines := kit.SplitLines(src)
	pairs := kit.PairsAll(src, r.env)

	var pathLines, skippedLines []string
	for _, p := range pairs {
		if strings.Contains(p.Expanded, "...") {
			skippedLines = append(skippedLines, p.Expanded)
		} else {
			pathLines = append(pathLines, p.Expanded)
		}
	}
	for _, p := range pathLines {
		if p != "" {
			r.ntargets++
		}
	}
	if len(pathLines) == 0 {
		fmt.Fprintf(r.s.Err, "verify-registry: ERROR — no usable target paths in %s\n", targetsMD)
		fmt.Fprintf(r.s.Err, "verify-registry: check TARGETS.md has backtick-wrapped absolute or $RESEARCH_HOME/... paths\n")
		if r.json {
			return cli.ExitOperational
		}
		return cli.ExitOK
	}
	var skippedNames []string
	for _, sk := range strings.Fields(strings.Join(skippedLines, "\n")) {
		r.skippedCount++
		skippedNames = append(skippedNames, bashBasename(sk))
	}

	var absentRowIDs []string
	var absentNames []string
	for _, p := range strings.Fields(strings.Join(pathLines, "\n")) {
		r.target(p, pairs, tlines, &absentRowIDs, &absentNames)
	}

	if !r.dirReached {
		fmt.Fprintf(r.s.Err, "verify-registry: ERROR — no registered corpus path exists as a directory on disk.\n")
		fmt.Fprintf(r.s.Err, "verify-registry: Check RESEARCH_HOME (%s) and that corpora exist at the registered paths.\n", orDefault(r.env("RESEARCH_HOME"), "(unset)"))
		if r.json {
			r.flush(true)
			return cli.ExitOK
		}
		r.flush(false)
		return cli.ExitOperational
	}

	r.rowHygiene(src)
	r.kitSelfRegistration(pairs)
	r.summary(absentNames, skippedNames)
	r.flush(false)
	return cli.ExitOK
}

func orDefault(v, d string) string {
	if v == "" {
		return d
	}
	return v
}

// leadingInt parses the digit string the way `10#$n` does, clamping instead of wrapping on overflow.
func leadingInt(digits string) int {
	n, err := strconv.ParseInt(digits, 10, 64)
	if err != nil {
		return int(^uint(0) >> 1)
	}
	return int(n)
}

func absDiff(a, b int) int { return max(a-b, b-a) }

// drifts is `[ "$d" -gt "$tol" ]` after the shell's integer test: a tol that is not an integer is false.
func (r *registry) drifts(d int) bool { return r.gtTol(d) }

// gtTol is `[ "$x" -gt "$tol" ]` and leTol is `[ "$x" -le "$tol" ]`; both are false when tol is not an integer.
func (r *registry) gtTol(x int) bool {
	t, err := strconv.ParseInt(strings.TrimSpace(r.tol), 10, 64)
	return err == nil && int64(x) > t
}

func (r *registry) leTol(x int) bool {
	t, err := strconv.ParseInt(strings.TrimSpace(r.tol), 10, 64)
	return err == nil && int64(x) <= t
}

func trimSpace(s string) string { return strings.Trim(s, " \t\n\v\f\r") }

// hookTokens is the maturity cell split on '/' with each token trimmed (`tr '/' '\n' | sed -E 's/^\s+//; s/\s+$//'`).
func hookTokens(inner string) []string {
	toks := strings.Split(inner, "/")
	for i, t := range toks {
		toks[i] = trimSpace(t)
	}
	return toks
}

func firstMatch(toks []string, re *regexp.Regexp) string {
	for _, t := range toks {
		if re.MatchString(t) {
			return t
		}
	}
	return ""
}

// target reconciles one registered path (the body of the script's main loop).
func (r *registry) target(p string, pairs []kit.Pair, tlines []string, absentRowIDs, absentNames *[]string) {
	rawP := ""
	for _, pr := range pairs {
		if pr.Expanded == p {
			rawP = pr.Raw
			break
		}
	}
	if rawP == "" {
		rawP = p
	}
	needle := "`" + rawP + "`"
	row := ""
	for _, l := range tlines {
		if strings.Contains(l, needle) {
			row = l
			break
		}
	}
	claimed := ""
	if m := reClaimed.FindString(row); m != "" {
		claimed = reDigits.FindString(m)
	}
	name := bashBasename(p)

	if !isDirOS(p) { // ABSENT-PATHS-CHECK
		rowAnyDir := false
		rh := orDefault(r.env("RESEARCH_HOME"), r.env("HOME"))
		for _, m := range reRowToken.FindAllString(row, -1) {
			for _, rt := range strings.Fields(strings.ReplaceAll(m, "`", "")) {
				exp := strings.Replace(rt, "$RESEARCH_HOME", rh, 1)
				exp = strings.Replace(exp, "${RESEARCH_HOME}", rh, 1)
				if isDirOS(exp) {
					rowAnyDir = true
					break
				}
			}
			if rowAnyDir {
				break
			}
		}
		if !rowAnyDir {
			key := p
			if m := reRowNum.FindString(row); m != "" {
				key = reDigits.FindString(m)
			}
			dup := false
			for _, k := range *absentRowIDs {
				if k == key {
					dup = true
				}
			}
			if !dup {
				r.absentPaths++
				r.record("absent-target", "INFO", p, "registered target absent on disk — NOT checked")
				*absentRowIDs = append(*absentRowIDs, key)
				if len(*absentNames) < 3 {
					*absentNames = append(*absentNames, needle)
				}
			}
		}
		return
	}
	r.dirReached = true

	inner := reParen.FindString(row)
	inner = strings.TrimPrefix(inner, "(")
	inner = strings.TrimSuffix(inner, ")")

	if inner != "" {
		for _, tok := range strings.Split(inner, "/") {
			tok = trimSpace(tok)
			if tok == "" || maturityTokenKnown(tok) {
				continue
			}
			r.finding("nonconform-field", "WARN", name, name+" — maturity field not in schema: '"+tok+"'; check the legend for valid forms or update the legend (propose-never-apply).")
			r.unresolved++
		}
	}

	r.sessionBudget(p, name)
	nlEmitted := r.hookClaims(p, name, inner)
	r.wiredExec(p, name, nlEmitted)

	if reNC.MatchString(row) { // NC-EXEMPT-CHECK
		r.checked++
		if st, _ := kit.ResolveStateFile(p, kit.ResolveOptions{}); st != "" && isFileOS(st) {
			r.finding("nc-contradiction", "WARN", name, name+" — row carries the nc flag but a RESEARCH-STATE.md was found at "+st+"; remove nc if this is a real corpus target.")
			r.unresolved++
			return
		}
		real := len(listMarkdown(p))
		if claimed == "" {
			r.finding("nc-no-count", "WARN", name, fmt.Sprintf("%s — non-corpus (nc) target has no claimed 'N md' count in TARGETS.md row (real root-level: %d); add the count.", name, real))
			r.unresolved++
		} else if d := absDiff(leadingInt(claimed), real); r.drifts(d) {
			r.finding("count-drift", "WARN", name, fmt.Sprintf("%s — TARGETS.md row claims %s md but the non-corpus target has %d real .md file(s) at root (drift %d > tol %s) — refresh the row.", name, claimed, real, d, r.tol))
			r.drift++
		}
		return
	}

	if !kit.CorpusMarkerPresent(p, p+"/corpus") { // REGISTERED-PATH-MARKER-CHECK
		r.finding("no-corpus-marker", "WARN", name, name+" — registered path has no corpus marker (no INDEX.md/CATALOG.md/RESEARCH-STATE*.md at "+p+" or "+p+"/corpus); the row may be pointing at a container directory rather than the corpus root — verify against research-sdd-init.sh's --wire marker check (propose-never-apply).")
		r.attention++
	}

	state, _ := kit.ResolveStateFile(p, kit.ResolveOptions{})
	if state == "" || !isFileOS(state) {
		r.finding("corpus-unresolvable", "WARN", p, p+" — corpus layout not resolvable (no RESEARCH-STATE*.md under target); cannot recount blocks.")
		r.unresolved++
		return
	}
	corpus := bashDirname(state)
	mdFiles := listMarkdown(corpus)
	real := countBlocks(mdFiles, false)

	discWasZero := false
	catAuthority := ""
	gen, catMD := corpus+"/tools/gen-catalog.py", corpus+"/CATALOG.md"
	if isFileOS(gen) && isFileOS(catMD) {
		real, catAuthority, discWasZero = r.catalog(name, catMD, real)
	}

	r.checked++

	retroClaimed := ""
	if m := reRetroClaim.FindString(inner); m != "" {
		retroClaimed = reDigits.FindString(m)
	}
	if retroClaimed != "" {
		retrosDir := p + "/retros"
		if isDirOS(retrosDir) && !accessRX(retrosDir) { // RETRO-UNREADABLE-CHECK
			r.finding("retros-unreadable", "WARN", name, name+" — retros/ at "+retrosDir+" is not accessible (permission error); retro count cannot be verified — check filesystem permissions.")
			r.attention++
		} else {
			n := 0
			for _, f := range retroEntries(p, true) {
				if !retroIsExcluded(f) {
					n++
				}
			}
			if n != leadingInt(retroClaimed) {
				r.finding("retro-drift", "WARN", name, fmt.Sprintf("%s — row claims %s retro(s) but %d non-excluded retro(s) found (maxdepth 4) — refresh the 'N retros' field (propose-never-apply).", name, retroClaimed, n))
				r.retroDrift++
			}
		}
	}

	if claimed == "" {
		r.finding("no-claimed-count", "WARN", name, fmt.Sprintf("%s — no claimed '<N> md' count in its TARGETS.md row (real: %d blocks); add the count so it can be reconciled.", name, real))
		r.unresolved++
		return
	}

	if d := absDiff(leadingInt(claimed), real); r.drifts(d) {
		r.finding("count-drift", "WARN", name, fmt.Sprintf("%s — TARGETS.md row claims %s md but the corpus has %d real block file(s)%s (drift %d > tol %s) — refresh the row (propose-never-apply; not auto-edited).", name, claimed, real, catAuthority, d, r.tol))
		r.drift++
	}

	unclassifiable := 0
	if (real == 0 || discWasZero) && catAuthority == "" {
		var cand []string
		for _, f := range mdFiles {
			if reUnclassName.MatchString(f) {
				cand = append(cand, f)
			}
		}
		unclassifiable = countBlocks(cand, true)
		if unclassifiable > 0 {
			r.finding("unclassifiable-blocks", "WARN", name, fmt.Sprintf("%s — %d unclassifiable candidate block file(s): names contain 'block'/'bloque' but do not match the canonical discriminator (<prefix>-(block|bloque)<N>.md); the block counter returns 0 — rename to make them visible to drift and §18 checks.", name, unclassifiable))
			r.attention++
		}
	}

	if r.gtTol(real) || unclassifiable > 0 {
		hasKitRetro := false
		for _, f := range retroEntries(p, false) {
			if !retroIsExcluded(f) {
				hasKitRetro = true
				break
			}
		}
		if !hasKitRetro {
			eff, noun := real, "block(s) on disk"
			if real == 0 && unclassifiable > 0 {
				eff, noun = unclassifiable, "candidate block file(s) (unclassifiable) on disk"
			}
			r.finding("no-retros-wired", "INFO", name, fmt.Sprintf("%s — %d %s but no retros/*.md reachable under the target (§18 feedback not wired).", name, eff, noun))
		}
	}
}

// countBlocks is `<paths> | block_file_filter [-v] | wc -l`.
func countBlocks(paths []string, invert bool) int {
	out, err := kit.FilterBlockFiles(paths, invert, "")
	if err != nil {
		return 0 // no input and no match are both a count of zero here, as `wc -l` reads them
	}
	return len(out)
}

func maturityTokenKnown(tok string) bool {
	for _, re := range []*regexp.Regexp{reTokBlocks, reTokFocus, reTokRuns, reTokRetros, reTokGaps, reTokGit, reTokRemote, reTokHook} {
		if re.MatchString(tok) {
			return true
		}
	}
	return tok == "nc" || tok == "unregistered" || tok == "registered-no-sessions"
}

// catalog is the LOCAL-GENERATOR AUTHORITY block: a target with its own gen-catalog.py reconciles against its
// CATALOG.md total when that header is self-consistent. It returns the count to use, the annotation for the
// drift line and whether the discriminator-zero case fired.
func (r *registry) catalog(name, catMD string, disc int) (real int, authority string, discZero bool) {
	b, _ := os.ReadFile(catMD)
	lines := kit.SplitLines(string(b))
	catTotal := ""
	for _, l := range lines {
		if reCatTotal.MatchString(l) {
			if d := reDigits.FindString(l); d != "" {
				catTotal = d
				break
			}
		}
	}
	if catTotal == "" {
		for _, l := range lines {
			if m := reCatBlocks.FindString(l); m != "" {
				catTotal = reDigits.FindString(m)
				break
			}
		}
	}
	if catTotal == "" {
		r.finding("catalog-unparseable", "WARN", name, fmt.Sprintf("%s — CATALOG.md present (gen-catalog.py registered) but no parseable total found; freshness undeterminable; using discriminator count (%d).", name, disc))
		r.attention++
		return disc, "", false
	}
	pipes, seps := 0, 0
	for _, l := range lines {
		if rePipeLine.MatchString(l) {
			pipes++
		}
		if reSepLine.MatchString(l) {
			seps++
		}
	}
	rows := max(pipes-seps-1, 0)
	if catTotal != strconv.Itoa(rows) { // string comparison, as `[ "$a" != "$b" ]`
		r.finding("catalog-stale-header", "WARN", name, fmt.Sprintf("%s — CATALOG.md header total %s ≠ its own %d block rows (stale header); using disk discriminator %d — regenerate CATALOG.md.", name, catTotal, rows, disc))
		r.attention++
		return disc, "", false
	}
	total := leadingInt(catTotal)
	diff := absDiff(total, disc)
	switch {
	case r.leTol(diff):
		authority = fmt.Sprintf(" (CATALOG.md total via local gen-catalog.py; disk-consistent: discriminator=%d)", disc)
	case disc == 0 && total > 0:
		r.finding("catalog-disc-zero", "WARN", name, fmt.Sprintf("%s — discriminator found 0 classifiable blocks; CATALOG.md claims %s; possible causes: non-canonical block naming (discriminator requires <prefix>-(block|bloque)<N>.md) or stale CATALOG — verify before trusting this count.", name, catTotal))
		r.attention++
		discZero = true
	default:
		r.finding("catalog-stale", "WARN", name, fmt.Sprintf("%s — CATALOG.md total %s vs on-disk discriminator %d (diff %d > tol %s); CATALOG may be stale — regenerate and recheck before trusting this count.", name, catTotal, disc, diff, r.tol))
		r.attention++
		authority = fmt.Sprintf(" (CATALOG.md total via local gen-catalog.py; catalog-disk diff=%d — verify freshness)", diff)
	}
	return total, authority, discZero
}

// rowHygiene is the master-table ROW HYGIENE lint: the first cell longer than RSDD_ROW_MAXLEN (default 200) of
// each master row (a line whose first cell is the numeric '#' column) is reported. Only newline-terminated
// lines are read, as `while read` drops an unterminated last one.
func (r *registry) rowHygiene(src string) {
	rowMax := orDefault(r.env("RSDD_ROW_MAXLEN"), "200")
	lines := strings.Split(src, "\n")
	lines = lines[:len(lines)-1] // Split never returns an empty slice; the fragment after the last newline is not a terminated line
	for _, line := range lines {
		if !reMasterRow.MatchString(line) {
			continue
		}
		fields := strings.Split(line, "|")
		rname := ""
		if len(fields) >= 3 {
			rname = strings.Trim(fields[2], " ")
		}
		for i := 1; i < len(fields); i++ { // awk fields 2..NF
			c := strings.Trim(fields[i], " ")
			if rlen := r.awkLength(c); cellLonger(rlen, rowMax) {
				if rname == "" {
					rname = "?"
				}
				r.finding("oversized-row", "WARN", rname, fmt.Sprintf("TARGETS row %s master cell is %d chars (> %s) — collapse to one line; narrative belongs in the detail section.", rname, rlen, rowMax))
				r.rowlint++
				break
			}
		}
	}
}

// awkLength is awk's length(): characters under a UTF-8 locale, bytes otherwise (gawk). The locale is the first
// non-empty of LC_ALL, LC_CTYPE and LANG, as setlocale reads it.
func (r *registry) awkLength(c string) int {
	loc := orDefault(r.env("LC_ALL"), orDefault(r.env("LC_CTYPE"), r.env("LANG")))
	if l := strings.ToLower(loc); strings.Contains(l, "utf-8") || strings.Contains(l, "utf8") {
		return utf8.RuneCountInString(c)
	}
	return len(c)
}

// cellLonger is awk's `length(c) > max` with max from -v: numeric when max looks like a number, else a string
// comparison of the length's text.
func cellLonger(n int, max string) bool {
	if reNumber.MatchString(max) {
		f, err := strconv.ParseFloat(trimSpace(max), 64)
		return err == nil && float64(n) > f
	}
	return strings.Compare(strconv.Itoa(n), max) == 1
}

// kitSelfRegistration warns when the kit repo itself is absent from TARGETS.md (kit-sup #6).
func (r *registry) kitSelfRegistration(pairs []kit.Pair) {
	parent := bashDirname(r.kitRoot)
	for _, p := range pairs {
		if p.Expanded == r.kitRoot || p.Expanded == parent {
			return
		}
	}
	b := bashBasename(r.kitRoot)
	r.finding("kit-not-registered", "WARN", b, b+" — kit repo is NOT in its own TARGETS.md; fleet instruments cannot supervise it. Add a row with the kit's path (kit-sup #6 gate).")
	r.attention++
}

func (r *registry) summary(absentNames, skippedNames []string) {
	r.say("\n")
	r.say("Summary: reconciled %d target(s) · %d absent target(s) · %d count drift(s) · %d retro drift(s) · %d unresolvable · %d oversized row(s) · %d attention.\n",
		r.checked, r.absentPaths, r.drift, r.retroDrift, r.unresolved, r.rowlint, r.attention)
	if r.absentPaths > 0 {
		names := strings.Join(absentNames, ", ")
		if extra := r.absentPaths - len(absentNames); extra > 0 {
			names += fmt.Sprintf(" ...and %d more", extra)
		}
		r.say("INFO: %d registered target(s) absent on disk — NOT checked: %s. Verify RESEARCH_HOME (%s) and that corpora exist at the registered paths.\n",
			r.absentPaths, names, orDefault(r.env("RESEARCH_HOME"), r.env("HOME")))
	}
	if r.skippedCount > 0 {
		r.say("WARN: %d target(s) skipped — truncated/unresolvable path in TARGETS.md; this reconcile is PARTIAL: %s\n", r.skippedCount, strings.Join(skippedNames, ", "))
	}
	if r.drift == 0 && r.retroDrift == 0 && r.unresolved == 0 && r.rowlint == 0 && r.attention == 0 && r.skippedCount == 0 && r.absentPaths == 0 {
		r.say("Registry consistent with reality (within tolerance %s).\n", r.tol)
		return
	}
	if r.drift > 0 {
		r.say("For each count drift: recount the corpus and refresh that target's 'N md' in $KIT/TARGETS.md by hand (WARN-only; never auto-edited).\n")
	}
	if r.retroDrift > 0 {
		r.say("For each retro drift: recount non-excluded retros and refresh the 'N retros' field in $KIT/TARGETS.md by hand (WARN-only; never auto-edited).\n")
	}
}
