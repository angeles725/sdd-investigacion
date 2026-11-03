package verifyretro

import (
	"context"
	"errors"
	"fmt"
	"regexp"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/retrogrammar"
)

// State is the verdict class of one run. The classes are distinct on purpose (CLAUDE.md §7): absent input is
// never a conformance failure, and a conformance failure is never a usage error.
type State int

// The states, in the order the script decides them.
const (
	// StateConforming: no FAIL finding (WARN findings may exist); exit 0.
	StateConforming State = iota
	// StateExcluded: no review-status marker and a `<!-- kit-retro: exclude -->` opt-out; exit 0.
	StateExcluded
	// StateNonConforming: one or more FAIL findings; exit 1.
	StateNonConforming
	// StateUsage: not exactly one argument; exit 2.
	StateUsage
	// StateAbsent: the argument is not a regular file (absent-input); exit 2.
	StateAbsent
	// StateNotMarkdown: the argument is a file but not *.md; exit 2.
	StateNotMarkdown
	// StateUnreadable: the file exists but cannot be read (absent-input); exit 2.
	StateUnreadable
)

// Options configure one run.
type Options struct {
	// Args are the command-line arguments after the command name: exactly one, the retro.
	Args []string
	// Cwd resolves a relative retro. "" leaves the path to the process working directory. The caller passes
	// its cli.Stdio working directory (archtest forbids os.Getwd outside cli/stdio.go).
	Cwd string
	// Read loads the retro; nil means retrogrammar.Read. It is the seam that lets a test reach the unreadable
	// branch (exit 2) without chmod, which root ignores.
	Read func(path string) (*retrogrammar.Doc, error)
}

// Finding is one conformance line: a FAIL (counts against the retro) or a WARN, with its fix lines.
type Finding struct {
	Level string // "FAIL" or "WARN"
	Class string // the bracketed class, e.g. marker-missing
	Text  string // the text after `: `
	Fix   []string
}

// Report is what a run decided. Render turns it into the script's exact bytes.
type Report struct {
	State State
	// Arg is the retro argument as given (the messages quote it).
	Arg      string
	Findings []Finding
	// FenceWarning is the stderr line for an unclosed code fence, "" when there is none.
	FenceWarning string
}

// Run checks one retro. The error is operational only (a cancelled context); every outcome the script can
// produce, absent input and bad arguments included, is a Report.
func Run(ctx context.Context, o Options) (Report, error) {
	if err := ctx.Err(); err != nil {
		return Report{}, fmt.Errorf("verifyretro: %w", err)
	}
	if len(o.Args) != 1 {
		return Report{State: StateUsage}, nil
	}
	arg := o.Args[0]
	rep := Report{Arg: arg}
	path := arg
	if o.Cwd != "" && !strings.HasPrefix(arg, "/") {
		path = o.Cwd + "/" + arg // concatenated, never Clean'd: "link/../x" must resolve as the kernel does
	}
	// The script tests -f, then the .md suffix, then -r: so a non-.md file that cannot be read is still "not a .md".
	read := o.Read
	if read == nil {
		read = retrogrammar.Read
	}
	d, err := read(path)
	switch {
	case errors.Is(err, retrogrammar.ErrAbsentInput):
		rep.State = StateAbsent
		return rep, nil
	case !strings.HasSuffix(arg, ".md"):
		rep.State = StateNotMarkdown
		return rep, nil
	case err != nil:
		rep.State = StateUnreadable
		return rep, nil
	}
	d.Path = arg // the fence warning quotes the path as the caller wrote it
	check(&rep, d)
	return rep, nil
}

// check runs the three conformance checks in the script's order; every defect is reported before the verdict.
func check(rep *Report, d *retrogrammar.Doc) {
	failures := 0
	fail := func(f Finding) {
		rep.Findings = append(rep.Findings, f)
		if f.Level == "FAIL" {
			failures++
		}
	}

	// (a) review-status marker, read from the leading comment block.
	lead := leadingBlock(d.Raw)
	switch status := statusOf(lead); status {
	case "pending", "applied", "dismissed":
	case "":
		if excluded(lead) {
			rep.State = StateExcluded
			return
		}
		fail(Finding{"FAIL", "marker-missing", "no review-status marker found in leading comment block", fixMarker("add at the very top of the file:")})
	default:
		fail(Finding{"FAIL", "marker-missing", fmt.Sprintf(`unrecognised review-status "%s" (expected: pending | applied | dismissed)`, status), fixMarker("change to:")})
	}

	// (c) title line. The em-dash form wins; the ASCII-hyphen form only warns.
	switch {
	case anyPrefix(d.Raw, "# Retro —"):
	case anyPrefix(d.Raw, "# Retro -"):
		fail(Finding{"WARN", "header-punctuation", `title line found but uses ASCII hyphen "-"; the canonical separator is em-dash "—"`, []string{
			"  fix: change the separator to an em-dash:",
			"       # Retro — <TARGET> · <FOCUS> · <DATE> · Research-SDD self-retrospective",
		}})
	default:
		fail(Finding{"FAIL", "header-missing", `no "# Retro —" title line found`, []string{
			"  fix: add as the first heading:",
			"       # Retro — <TARGET> · <FOCUS> · <DATE> · Research-SDD self-retrospective",
		}})
	}

	// (b) delta section, the §7 four-class check. The first read of the delta grammar speaks about an unclosed fence.
	info := retrogrammar.Delta(d)
	rep.FenceWarning = d.FenceWarning()
	honesty := retrogrammar.HasHonesty(d)
	switch {
	case info.Found:
		if info.DeprHeading != "" {
			fail(Finding{"WARN", "deprecated-heading", `deprecated delta heading — migrate to "## Proposed kit deltas" per §18`, nil})
		}
		// Only the table form counts as conforming rows: entries (### …) and an empty heading both mean none.
		if info.Form != retrogrammar.FormTable && !honesty {
			text := "delta heading present but zero table rows and no §18 honesty line"
			if mentionsNoNewDeltas(d.Raw) {
				text = "delta heading present but zero table rows; §18 honesty line found but section impure (dirty structural marker in lead block, or forbidden heading outside canonical section)"
			}
			fail(Finding{"FAIL", "empty-section", text, []string{
				"  fix: add at least one data row to the delta table:",
				"       | 1 | <change> | <target file · §/section> | <evidence> | <type> | <priority> |",
				"  or state the §18 honesty clause under ## Honest verdict:",
				"       no new deltas; the kit already covers this run.",
			}})
		}
	case info.UnrecFound:
		fail(Finding{"FAIL", "unrecognised-heading", "delta section uses unrecognised heading: " + info.UnrecHeading, []string{
			"  fix: rename the heading to the canonical form:",
			"       ## Proposed kit deltas",
		}})
		if info.UnrecData == 0 && !honesty {
			fail(Finding{"FAIL", "zero-rows", "unrecognised delta section also has zero table rows", []string{
				"  fix: rename the heading AND add a canonical table:",
				"       ## Proposed kit deltas",
				"       | # | Proposed change | Target (file · §/section) | Evidence | Type | Priority |",
				"       |---|---|---|---|---|---|",
				"       | 1 | <change> | <target> | <evidence> | <type> | <priority> |",
			}})
		}
	case honesty:
	default:
		fail(Finding{"FAIL", "absent-section", `no delta section — no canonical "## Proposed kit deltas" heading and no §18 honesty line`, []string{
			"  fix: add a delta section with a table under a canonical heading:",
			"       ## Proposed kit deltas",
			"       | # | Proposed change | Target (file · §/section) | Evidence | Type | Priority |",
			"       |---|---|---|---|---|---|",
			"       | 1 | <change> | <target> | <evidence> | <type> | <priority> |",
			"  or state the §18 honesty clause under ## Honest verdict:",
			"       no new deltas; the kit already covers this run.",
		}})
	}

	rep.State = StateConforming
	if failures > 0 {
		rep.State = StateNonConforming
	}
}

func fixMarker(lead string) []string {
	return []string{"  fix: " + lead, "       <!-- review-status: pending -->"}
}

// spaceSet is the C-locale [[:space:]].
const spaceSet = " \t\n\v\f\r"

var (
	// reStatus is the grep -oiE of the status marker, run on a lower-cased line.
	reStatus = regexp.MustCompile(`<!--[[:space:]]*review-status:[[:space:]]*[a-z]+`)
	// reExclude is the grep -qiE of the opt-out: anchored at the start of the line, NOT at its end.
	reExclude = regexp.MustCompile(`^[[:space:]]*<!--[[:space:]]*kit-retro:[[:space:]]*exclude[[:space:]]*-->`)
)

// leadingBlock is the script's awk: the consecutive lines that open an HTML comment, blank lines skipped,
// stopping at the first other line. The lines are NOT BOM-stripped (see the package comment).
func leadingBlock(raw []string) []string {
	var out []string
	for _, l := range raw {
		t := strings.TrimLeft(l, spaceSet)
		switch {
		case strings.HasPrefix(t, "<!--"):
			out = append(out, l)
		case t == "":
		default:
			return out
		}
	}
	return out
}

// statusOf is the grep | head -1 | sed | tr chain: the lower-cased word of the first review-status marker, "" when
// no line of the block carries one (a marker without a letter word counts as none).
func statusOf(lead []string) string {
	for _, l := range lead {
		if m := reStatus.FindString(asciiLower(l)); m != "" {
			_, word, _ := strings.Cut(m, ":")
			return strings.TrimLeft(word, spaceSet)
		}
	}
	return ""
}

func excluded(lead []string) bool {
	for _, l := range lead {
		if reExclude.MatchString(asciiLower(l)) {
			return true
		}
	}
	return false
}

func anyPrefix(raw []string, prefix string) bool {
	for _, l := range raw {
		if strings.HasPrefix(l, prefix) {
			return true
		}
	}
	return false
}

// mentionsNoNewDeltas is `grep -qi 'no new deltas'` over the whole file.
func mentionsNoNewDeltas(raw []string) bool {
	for _, l := range raw {
		if strings.Contains(asciiLower(l), "no new deltas") {
			return true
		}
	}
	return false
}

// asciiLower folds A-Z only, like grep -i and tr 'A-Z' 'a-z' under LC_ALL=C: strings.ToLower would also fold
// non-ASCII runes (U+212A KELVIN SIGN becomes "k").
func asciiLower(s string) string {
	return strings.Map(func(r rune) rune {
		if r >= 'A' && r <= 'Z' {
			return r + 'a' - 'A'
		}
		return r
	}, s)
}
