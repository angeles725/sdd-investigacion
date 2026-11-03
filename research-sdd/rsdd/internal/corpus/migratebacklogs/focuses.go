package migratebacklogs

import (
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/gfm"
)

const reasonUnknownFocusStatus = "unknown-focus-status"

// registryHeader reports the Status column of a header row and whether the table is the focus registry: a
// Status/Estado column AND a focus/slug/name column. It is the one definition both the transform and the
// document-focus lookup use, so they cannot drift. With several Status columns the last one wins.
func registryHeader(cells []string) (status int, ok bool) {
	status = -1
	hasFocus := false
	for i, c := range cells {
		switch b := lower(bare(c)); b {
		case "status", "estado":
			status = i
		case "focus", "slug", "foco", "name", "nombre":
			hasFocus = true
		}
	}
	return status, status >= 0 && hasFocus
}

var knownFocusStatus = map[string]bool{
	"active": true, "paused": true, "stopped": true, "planned": true, "bootstrapping": true, "reopened": true, "document": true,
}

// leadingWord is the first run of letters and hyphens of s (after the bold, backtick and bracket decoration).
func leadingWord(s string) string { return wordRun(strings.TrimLeft(s, "*`[ ")) }

// migrateFocuses rewrites the Status cell of the FOCUSES.md registry table: `closed` becomes `stopped` and
// `reabierto` becomes `reopened`, decoration kept. Every other table of the file is left alone.
func migrateFocuses(lines []line) ([]line, []manualItem) {
	var manual []manualItem
	out := make([]line, 0, len(lines))
	inTable, registry, statusCol := false, false, -1
	for i, l := range lines {
		r, isRow := parseRow(l.body)
		if !isRow {
			inTable, registry = false, false
			out = append(out, l)
			continue
		}
		if !inTable {
			inTable = true
			statusCol, registry = registryHeader(r.cells)
			out = append(out, l)
			continue
		}
		if !registry || isSepFirst(r.firstCell()) || len(r.cells) <= statusCol {
			out = append(out, l)
			continue
		}
		s := trim(r.cells[statusCol])
		tok := leadingWord(s)
		switch lt := lower(tok); {
		case lt == "closed" || lt == "reabierto":
			word := "stopped"
			if lt == "reabierto" {
				word = "reopened"
			}
			at := strings.Index(s, tok)
			r.set(statusCol, s[:at]+word+s[at+len(tok):])
			l.body = r.String()
		case !knownFocusStatus[lt]:
			manual = append(manual, manualItem{reasonUnknownFocusStatus, i + 1})
		}
		out = append(out, l)
	}
	return out, manual
}

// isDocumentFocus reports whether the FOCUSES.md source src registers label as a document-mode focus: a row of
// the registry whose focus cell is the label (or any other cell is RESEARCH-STATE-<label>.md) and whose status
// starts with the word `document`. The match is exact, never a substring.
func isDocumentFocus(src, label string) bool {
	inTable, registry, statusCol := false, false, -1
	for _, l := range splitLines(src) {
		cells, ok := gfm.SplitRow(l.body, gfm.Options{})
		if !ok {
			inTable, registry = false, false
			continue
		}
		for i := range cells {
			cells[i] = gfm.Unescape(cells[i])
		}
		if !inTable {
			inTable = true
			statusCol, registry = registryHeader(cells)
			continue
		}
		if !registry || len(cells) <= statusCol || blankOrDelimiter(cells[0]) {
			continue
		}
		hit := bare(cells[0]) == label
		for _, c := range cells[1:] {
			hit = hit || bare(c) == "RESEARCH-STATE-"+label+".md"
		}
		if hit && lower(wordRun(bare(cells[statusCol]))) == "document" {
			return true
		}
	}
	return false
}

// blankOrDelimiter is the legacy test of a first cell made only of blanks, colons and hyphens (`^[ \t:-]+$`).
func blankOrDelimiter(c string) bool {
	return c != "" && strings.Trim(c, " \t:-") == ""
}

// wordRun is the leading run of letters and hyphens of s.
func wordRun(s string) string {
	n := 0
	for n < len(s) && (s[n] == '-' || s[n] >= 'a' && s[n] <= 'z' || s[n] >= 'A' && s[n] <= 'Z') {
		n++
	}
	return s[:n]
}
