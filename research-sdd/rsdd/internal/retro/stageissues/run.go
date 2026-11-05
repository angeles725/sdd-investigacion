// Package stageissues is the Go port of toolbelt/stage-retro-issues.sh (`rsdd retro stage-issues`, kit issue
// #2435): propose (or create with --apply) GitHub issues for the OPEN kit deltas of ONE §18 retro file.
//
// Usage: rsdd retro stage-issues [--toolbelt DIR] <retro.md> [--apply]
//
//	Default:  dry-run, print the planned issues (title, labels, body) to stdout. Offline: no gh call.
//	--apply:  `gh issue create` per open delta, with the dedup, occurrence-comment and read-back machinery.
//
// An OPEN delta is one whose review-status is pending/none/absent, OR whose retro carries a PARTIAL applied marker
// and the row's ID is neither shipped nor dismissed. propose-never-apply is the DEFAULT.
//
// The bash script this replaces is the shim toolbelt/stage-retro-issues.sh, which passes `--toolbelt <its own
// directory>` before the user's arguments: the script's directory fixed the kit root (TARGETS.md, the git remote
// that names the kit issue repo), and the Go command has no script directory of its own. Everything after that
// pair is the legacy argument list, so `$1` stays the retro and `--apply` may sit anywhere. Run directly, the
// toolbelt is found with the kit resolution (core/kit ResolveKitScript).
//
// Exit codes (unchanged): 0 dry-run success, or --apply with 0 create failures; 1 absent-input, degraded (gh
// missing or unauthenticated, an unresolved kit issue repo under --apply, a bad STAGE_RETRO_ISSUES_LIST_LIMIT,
// an unusable TARGETS.md); 2 --apply finished with one or more failed rows; 3 --apply finished with no failed row
// but a row whose mutation outcome is UNKNOWN (kit issue #1705): the write may have happened and is unproven,
// and is never retried.
//
// Intended divergences from the bash (each pinned by a test; the frozen legacy script is the oracle):
//   - No awk/grep/sed/iconv/cut probe: the Go port uses none of them, so their absence is no longer degraded.
//   - The scrub and the grammar run in-process. A scrub that "fails" or returns a non-numeric count cannot happen,
//     so those refusals are unreachable; the refusal for a scrub that alters the signature line stays.
//   - A shipped-id range the grammar refuses (ErrRangeTooLarge) is a typed degraded exit instead of bash's
//     unbounded loop.
//   - rsdd's cli adds a generic `DEGRADED:` stderr line to every exit-3 run (its degraded contract); the bash
//     printed none. Exit 3 here means an unknown mutation outcome, not a degraded state.
//   - Character counting (title length, the 100-character head cut) follows the caller's locale as bash's
//     ${#var} does: characters under a UTF-8 LC_ALL/LC_CTYPE/LANG, bytes otherwise. Every awk program runs as
//     bytes (LC_ALL=C), as the grammar package does.
package stageissues

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"unicode/utf8"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kit"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/retrogrammar"
)

// Command is the registry entry of `rsdd retro stage-issues`.
var Command = cli.Command{
	Name:    "stage-issues",
	Group:   "retro",
	Summary: "propose (or with --apply create) GitHub issues for the open deltas of one retro",
	Run:     Run,
}

// Run is the command.
func Run(args []string, s cli.Stdio) int {
	a := &app{s: s}
	env := s.Environment()
	a.exec = osExec(env, s.Cwd, s.Env("PATH"))
	a.have = func(name string) bool { _, ok := lookPath(s.Env("PATH"), name); return ok }
	return a.main(args)
}

// app is one run's state: the shell script's globals.
type app struct {
	s    cli.Stdio
	exec execFn
	have func(string) bool

	apply bool
	utf8  bool

	retro, retroBase       string
	toolbelt, kitRoot      string
	targetsMD              string
	targetName, targetDir  string
	legacyTargetName       string
	targetRegistered       bool
	repo                   string
	listLimit              string
	listLimitN             int64
	doc                    *retrogrammar.Doc
	markerLine             string
	isPartial              bool
	shipped                []string
	open, skippedShipped   int
	skippedDismissed       int
	skippedWrongKit        int
	skippedDedup, created  int
	failed, summaryUnknown int
	unclassifiable         int
	mutUnknown             int
	mutConfirmed           int
	mutNoWrite             int
	occCommented           int
	occPresent             int

	uncN, uncSec int
	uncRecs      []uncRec

	labelReady   bool
	recheckState string

	occState, occReply, occMsg string
	occNums                    []string

	occRowConfirmed, occRowFailed, occRowUnknown, occRowUnknownCounted bool
}

// exitNow is the shell's `exit N`, raised from anywhere in the run and caught by main.
type exitNow int

func (a *app) exit(code int) { panic(exitNow(code)) }

func (a *app) env(k string) string { return a.s.Env(k) }

func (a *app) outf(format string, args ...any)  { fmt.Fprintf(a.s.Out, format, args...) }
func (a *app) errf(format string, args ...any)  { fmt.Fprintf(a.s.Err, format, args...) }
func (a *app) warnf(format string, args ...any) { a.errf(format, args...) }

// localeUTF8 is whether bash's ${#var} counts characters: LC_ALL, else LC_CTYPE, else LANG names a UTF-8 codeset.
func localeUTF8(getenv func(string) string) bool {
	for _, k := range []string{"LC_ALL", "LC_CTYPE", "LANG"} {
		if v := getenv(k); v != "" {
			v = lowerASCII(v)
			return strings.Contains(v, "utf-8") || strings.Contains(v, "utf8")
		}
	}
	return false
}

func (a *app) charLen(s string) int {
	if !a.utf8 {
		return len(s)
	}
	n := 0
	for i := 0; i < len(s); n++ {
		_, w := utf8.DecodeRuneInString(s[i:])
		i += w
	}
	return n
}

// cutChars is ${s:0:n}: the first n characters (bytes under a non-UTF-8 locale).
func (a *app) cutChars(s string, n int) string {
	if !a.utf8 {
		return s[:min(n, len(s))]
	}
	c := 0
	for i := range s { // i is the start of each character; an invalid byte is one character, as in a UTF-8 shell
		if c == n {
			return s[:i]
		}
		c++
	}
	return s
}

func (a *app) main(args []string) (rc int) {
	defer func() {
		if r := recover(); r != nil {
			if e, ok := r.(exitNow); ok {
				rc = int(e)
				return
			}
			panic(r)
		}
	}()
	a.utf8 = localeUTF8(a.env)
	// The shim's own directory, injected as the first pair.
	if len(args) >= 2 && args[0] == "--toolbelt" {
		a.toolbelt, args = args[1], args[2:]
	} else {
		p, warns, err := kit.ResolveKitScript("toolbelt/stage-retro-issues.sh", a.env)
		for _, w := range warns {
			a.errf("%s\n", w)
		}
		if err != nil {
			a.errf("stage-retro-issues: cannot find the kit toolbelt: %v\n", err)
			return 1
		}
		a.toolbelt = filepath.Dir(p)
	}
	retro := ""
	if len(args) > 0 {
		retro = args[0]
	}
	for _, x := range args {
		if x == "--apply" {
			a.apply = true
		}
	}
	// §7 degraded probe: --apply needs gh, authenticated.
	if a.apply {
		if !a.hasCommand("gh") {
			a.errf("degraded: gh not found on PATH — install gh CLI before using --apply\n")
			return 1
		}
		if r := a.exec("gh", []string{"auth", "status"}, false); r.RC != 0 {
			a.errf("degraded: gh is not authenticated — run 'gh auth login' before using --apply\n")
			return 1
		}
	}
	if code, done := a.openRetro(retro); done {
		return code
	}
	if code, done := a.resolveKit(); done {
		return code
	}
	if code, done := a.resolveTarget(); done {
		return code
	}
	return a.stage()
}

// openRetro validates the retro path (absent-input / unreadable) and makes it absolute, logically like
// `$(cd "$(dirname "$retro")" && pwd)/$(basename "$retro")`.
func (a *app) openRetro(retro string) (int, bool) {
	if retro == "" || !isRegular(retro, a.s.Cwd) {
		shown := retro
		if shown == "" {
			shown = "<no path given>"
		}
		a.errf("absent-input: retro not found: %s\n", shown)
		return 1, true
	}
	abs := retro
	if !filepath.IsAbs(abs) {
		abs = filepath.Join(a.s.Cwd, abs)
	}
	f, err := os.Open(abs)
	if err != nil {
		a.errf("degraded: retro not readable: %s\n", retro)
		return 1, true
	}
	_ = f.Close()
	dir := filepath.Dir(retro)
	if !filepath.IsAbs(dir) {
		dir = filepath.Join(a.s.Cwd, dir)
	}
	a.retro = filepath.Clean(dir) + "/" + filepath.Base(retro)
	a.retroBase = filepath.Base(a.retro)
	return 0, false
}

func isRegular(p, cwd string) bool {
	if !filepath.IsAbs(p) {
		p = filepath.Join(cwd, p)
	}
	st, err := os.Stat(p)
	return err == nil && st.Mode().IsRegular()
}

// resolveKit fixes the kit root (two directories above the toolbelt, physically) and resolves the kit issue repo.
func (a *app) resolveKit() (int, bool) {
	tb := a.toolbelt
	if !filepath.IsAbs(tb) {
		tb = filepath.Join(a.s.Cwd, tb)
	}
	if r, err := filepath.EvalSymlinks(tb); err == nil {
		tb = r
	}
	a.kitRoot = filepath.Dir(filepath.Dir(tb))
	a.targetsMD = a.kitRoot + "/research-sdd/TARGETS.md"
	res := a.resolveRepo()
	a.repo = res.Repo
	reason := res.reason(a.kitRoot)
	if a.apply && a.repo == "" {
		a.errf("degraded: cannot resolve kit issue repo (%s) — set RESEARCH_SDD_ISSUE_REPO=<owner>/<name>, or configure a git remote 'origin' at %s — refusing to create issues against an unresolved/foreign repo\n", reason, a.kitRoot)
		return 1, true
	}
	if !a.apply {
		if a.repo != "" {
			a.outf("kit-issue-repo: %s\n", a.repo)
		} else {
			a.outf("kit-issue-repo: unresolved (%s)\n", reason)
		}
	}
	// Every dedup `gh issue list` carries an explicit --limit (gh's own default of 30 silently truncated a busy
	// repo); a reply that FILLS it is a typed failure, never "no match".
	a.listLimit = a.env("STAGE_RETRO_ISSUES_LIST_LIMIT")
	if a.listLimit == "" {
		a.listLimit = "1000"
	}
	if a.listLimit == "" || strings.Trim(a.listLimit, "0123456789") != "" || a.listLimit == "0" {
		a.errf("degraded: STAGE_RETRO_ISSUES_LIST_LIMIT must be a positive integer (got '%s')\n", a.listLimit)
		return 1, true
	}
	n, err := strconv.ParseInt(a.listLimit, 10, 64)
	if err != nil {
		n = 1<<63 - 1 // bash `[ -ge ]` on an out-of-range limit errors, i.e. is never true
	}
	a.listLimitN = n
	return 0, false
}

// resolveTarget derives the target NAME (what the `target:<name>` labels are named after) from the retro's
// directory hierarchy (kit issues #1169, #1287): the NEAREST registered ancestor, else the legacy basename guess.
func (a *app) resolveTarget() (int, bool) {
	retroDir := filepath.Dir(a.retro)
	a.targetDir = filepath.Dir(retroDir) // legacy flat-layout guess (fallback + legacy dedup signature)
	res, err := kit.NameForRetro(a.targetsMD, a.retro, a.s.Cwd, a.env)
	for _, w := range res.Warnings {
		a.errf("%s\n", w)
	}
	a.targetName, a.targetRegistered = res.Name, true
	switch {
	case err == nil:
	case kit.RC(err) == 2: // kit.ErrNoAncestor
		a.targetName = filepath.Base(a.targetDir)
		// A structural directory name is never a registered target label: fail up front rather than plan issues
		// whose `target:<name>` label cannot exist (anti-silent-zero).
		if a.targetName == "corpus" || a.targetName == "retros" {
			a.errf("stage-retro-issues: cannot resolve target for '%s' — no ancestor directory is registered in %s (basename '%s' is a structural directory, not a target)\n", a.retro, a.targetsMD, a.targetName)
			return 1, true
		}
		a.targetRegistered = false
		a.errf("WARN: target directory '%s' not found in %s — using basename '%s'\n", a.targetDir, a.targetsMD, a.targetName)
	default:
		a.errf("%s\n", err.Error())
		a.errf("stage-retro-issues: cannot resolve target for '%s' — operational failure reading %s (see message above)\n", a.retro, a.targetsMD)
		return 1, true
	}
	// Pre-#1286 issues carry the legacy `<path basename>/retros/<file>` signature; remember it so the --apply dedup
	// can search it too when the registered name differs from the basename (#1287). A structural old name
	// (<t>/corpus/retros -> `corpus`) never matched a real signature, so it is treated as "no legacy name".
	a.legacyTargetName = filepath.Base(a.targetDir)
	if a.legacyTargetName == "corpus" || a.legacyTargetName == "retros" {
		a.legacyTargetName = a.targetName
	}
	return 0, false
}
