package issuesdue

import (
	"path/filepath"
	"slices"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/retrogrammar"
)

// Sink receives the typed states of a read, in the order the legacy script wrote them. Every func is required.
type Sink struct {
	// Note is a stderr line (printf-style), without its newline.
	Note func(format string, args ...any)
	// Degrade is a "degraded: ..." line: the audit could not reach a verdict (rc 1 of the command). It is also a note.
	Degrade func(format string, args ...any)
	// Fail is an operational stop that is neither a verdict nor a "degraded:" (absent-input, no registered target).
	// It is also a note.
	Fail func(format string, args ...any)
	// OutOfScope is the "out-of-scope-marker: ..." corpus finding (rc 0, nothing classified). It is also a note.
	OutOfScope func(line string)
}

// Retro is a retro read for the due computation: its review-status and its row ids.
type Retro struct {
	Doc *retrogrammar.Doc
	// Path is the absolute retro path, Base its file name and Target the registered target name of the signature.
	Path, Base, Target string
	// Marker is the leading-block review-status line and Status its status word.
	Marker, Status string
	// Partial marks a PARTIAL marker; Shipped are the row ids its shipped: list expands to.
	Partial bool
	Shipped []string
	// AllIDs are the ids of every row, in the order of the legacy script; OpenIDs the rows still open.
	AllIDs, OpenIDs []string

	foundSec bool
}

// Read is the retro half of audit_retro: it reads the retro once and classifies its rows as open or not under the
// review-status. false stops the audit with its line already given to sink; true means OpenIDs is the due candidate
// list (empty when the status closes every row). Messages and their order are the legacy script's.
func Read(path, target string, sink Sink) (*Retro, bool) {
	a := &Retro{Path: path, Base: filepath.Base(path), Target: target}
	// `[ ! -r ]`: an existing but unreadable retro is not an empty one (every parse would see nothing). Read
	// fails on an unreadable file (os.ReadFile), so its error is that check.
	doc, rerr := retrogrammar.Read(path)
	if rerr != nil {
		sink.Degrade("degraded: retro not readable: %s — cannot audit, no verdict", path)
		return nil, false
	}
	a.Doc = doc
	a.Marker = retrogrammar.MarkerScopeLine(doc)
	// A marker outside the leading-block scope is a corpus FINDING (kit issue #1099/#1125): nothing is
	// classified, and the run does not fail.
	if a.Marker == "" && retrogrammar.MarkerOutOfScope(doc) {
		sink.OutOfScope("out-of-scope-marker: a review-status marker exists but sits outside the leading-block scope in " + a.Base +
			" — refusing to classify (kit issue #1099); move the marker into the leading block")
		return nil, false
	}
	a.Status = retrogrammar.StatusFromMarkerLine(a.Marker)
	if retrogrammar.MarkerIsPartial(a.Marker) {
		a.Partial = true
		if raw := retrogrammar.ShippedRaw(a.Marker); raw != "" {
			ids, err := retrogrammar.ShippedIDs(raw)
			if err != nil {
				sink.Degrade("degraded: the review-status marker of %s lists a shipped: range too large to expand (%s)", a.Base, err.Error())
				return nil, false
			}
			a.Shipped = ids
		}
	}
	if !a.classifySection(sink) {
		return nil, false
	}
	hasOpen := a.openRows(sink)
	if !a.collectIDs(sink) {
		return nil, false
	}
	if hasOpen {
		a.buildOpenIDs(sink)
	}
	return a, true
}

// Prefixes are the signature prefixes an issue of this retro can carry: the registered target name and, for an
// issue created before #1286, the legacy <path basename> (skipped when it equals the registered name or is a
// structural directory), exactly as the seeder's dedup does (kit issue #1304 item 2).
func (a *Retro) Prefixes() []string {
	out := []string{a.Target + "/retros/" + a.Base}
	legacy := filepath.Base(filepath.Dir(filepath.Dir(a.Path)))
	switch legacy {
	case "corpus", "retros", "", a.Target:
	default:
		out = append(out, legacy+"/retros/"+a.Base)
	}
	return out
}

// Untracked are the open rows no issue tracks: the ids of OpenIDs that issueIDs (IssueRowIDs of the open-issue
// bodies) does not carry, in row order. A row listed here may still have shipped through an issue since closed as
// completed; telling that apart is the caller's, who holds the closed issues.
func (a *Retro) Untracked(issueIDs []string) []string {
	var out []string
	for _, id := range a.OpenIDs {
		if !slices.Contains(issueIDs, id) {
			out = append(out, id)
		}
	}
	return out
}
