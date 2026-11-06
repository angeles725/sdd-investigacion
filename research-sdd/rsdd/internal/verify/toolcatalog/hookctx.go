package toolcatalog

import (
	"fmt"
	"regexp"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/hookenv"
)

var (
	reNotCataloged = regexp.MustCompile(`([0-9]+) not cataloged`)
	reLogged       = regexp.MustCompile(`Summary: ([0-9]+)`)
)

// hookContext is the additionalContext for the output of one run of the check (trailing newlines stripped) and its
// exit code, and whether anything is to be said at all.
func hookContext(out string, rc int, full bool) (ctx string, emit bool) {
	if rc != 0 { // the guard could not run: surface it rather than pass silently
		return hookenv.FailureContext(fmt.Sprintf(hookCouldNotRunFmt, rc), out, hookRerun), true
	}
	summary := linesWith(out, func(l string) bool { return strings.HasPrefix(l, "Summary:") })
	// ANTI-SILENT-ZERO: a run that exited 0 but printed no Summary line is a broken instrument, not a clean one.
	if summary == "" {
		if low := strings.ToLower(out); strings.Contains(low, "empty-input") || strings.Contains(low, "no tool log rows") {
			return "", false // the legitimate empty-input state: nothing to reconcile
		}
		return hookenv.FailureContext(hookNoSummary, out, hookRerun), true
	}
	missing := strings.Join(numbers(summary, reNotCataloged), "\n")
	if missing == "" || missing == "0" { // every logged tool is cataloged: declare it, never stay silent
		logged := strings.Join(numbers(summary, reLogged), "\n")
		if logged == "" {
			logged = "?"
		}
		return fmt.Sprintf(hookCleanFmt, logged), true
	}
	warns := linesWith(out, func(l string) bool { return strings.HasPrefix(l, "WARN") })
	if !full {
		warns = compactWarns(warns)
	}
	detail := warns + "\n" + summary + "\n" + hookFullList
	if warns == "" {
		detail = summary + "\n" + hookFullList
	}
	return hookDriftHeader + "\n" + detail, true
}

// linesWith is the lines of out that satisfy keep, joined by newlines (what `grep` printed).
func linesWith(out string, keep func(string) bool) string {
	var got []string
	for _, l := range strings.Split(out, "\n") {
		if keep(l) {
			got = append(got, l)
		}
	}
	return strings.Join(got, "\n")
}

// numbers is, for every match of re in the lines of text, its captured number (`grep -o` of the phrase, then of the
// number in it).
func numbers(text string, re *regexp.Regexp) []string {
	var got []string
	for _, l := range strings.Split(text, "\n") {
		for _, m := range re.FindAllStringSubmatch(l, -1) {
			got = append(got, m[1])
		}
	}
	return got
}
