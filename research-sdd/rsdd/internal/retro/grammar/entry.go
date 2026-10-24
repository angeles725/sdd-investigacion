package grammar

import (
	"fmt"
	"path/filepath"
	"regexp"
	"strings"
)

// The delta-ENTRY form (sweep-retros form 2, METHODOLOGY §18, kit issue #1332): under the canonical section a
// `### <id> — title` heading is one delta and its `**Label**: value` lines (same line only) are its fields, up to
// the next `##`/`###` heading. The id is the first token before the dash minus trailing `.`/`:`; an entry whose
// token is not [A-Za-z0-9][A-Za-z0-9_-]* (`**D1**`, `[D1]`) yields no row (EntryWarn surfaces it).

var (
	reEntryID   = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_-]*$`)
	reBoldLabel = regexp.MustCompile(`^\*\*[^*]+\*\*`)
	reLabelLead = regexp.MustCompile(`^[[:space:]]*:?[[:space:]]*`)
	reTarget    = regexp.MustCompile(`^(where in kit|kit file|target)`)
)

// Row is one delta record in the column order of a canonical table row, so every form feeds the same seeder loop.
type Row struct{ ID, Change, Target, Evidence, Type, Priority string }

// Line renders the bash record: the six fields joined by \037, newline-terminated.
func (r Row) Line() string {
	return strings.Join([]string{r.ID, r.Change, r.Target, r.Evidence, r.Type, r.Priority}, "\x1f") + "\n"
}

// EntryRows is retro_grammar_entry_rows. Target is the first `**Where in kit**`/`**Kit file…**`/`**Target…**`
// value, Evidence the first `**…evidence…**` value, Priority the letters of the first word of the first
// `**Priority…**` value; with no usable body priority the heading's parenthetical priority is used.
func EntryRows(d *Doc) []Row {
	var out []Row
	var cur Row
	have, inSec, headPrio := false, false, ""
	flush := func() {
		if cur.Priority == "" {
			cur.Priority = headPrio // RETRO_GRAMMAR_HEADING_PRIORITY fallback: the body **Priority** always wins
		}
		if have {
			out = append(out, cur)
		}
		have = false
	}
	for _, line := range d.Lines {
		low := lower(line)
		switch {
		case isCanonical(low):
			flush()
			inSec = true
		case isH2(line):
			flush()
			inSec = false
		case inSec && isH3(line):
			flush()
			if id, title, ok := entryHeading(line); ok {
				cur, have, headPrio = Row{ID: id, Change: title}, true, headingPriority(line)
			}
		case inSec && have:
			entryField(&cur, line)
		}
	}
	flush()
	return out
}

// entryHeading splits `### <id> — <title>`; ok is false without a dash or with an unusable id. An empty title
// becomes the id.
func entryHeading(line string) (id, title string, ok bool) {
	t := trimLeftSpace(line[3:])
	head, title, found := strings.Cut(t, "—")
	if !found {
		return "", "", false
	}
	title = trimSpace(title)
	id = strings.TrimRight(firstField(head), ".:")
	if !reEntryID.MatchString(id) {
		return "", "", false
	}
	if title == "" {
		title = id
	}
	return id, title, true
}

// entryField applies one `**Label** value` line to r; the first value of each field wins.
func entryField(r *Row, line string) {
	m := reBoldLabel.FindString(line)
	if m == "" {
		return
	}
	name := strings.TrimRight(lower(m[2:len(m)-2]), ":."+spaceSet)
	rest := trimRightSpace(reLabelLead.ReplaceAllString(line[len(m):], ""))
	switch {
	case strings.HasPrefix(name, "priority") && r.Priority == "":
		r.Priority = asciiLetters(firstField(rest))
	case reTarget.MatchString(name) && r.Target == "":
		r.Target = rest
	case strings.Contains(name, "evidence") && r.Evidence == "":
		r.Evidence = rest
	}
}

// headingPriority is heading_prio: the level of the first parenthetical made ONLY of the words new, priority,
// high, medium, low (any case; separated by commas, semicolons, colons or blanks) that carries a level, as
// written. `(low-risk change)` and `(medium confidence)` carry other words: ignored. A bare `(low)` IS a priority.
func headingPriority(h string) string {
	rest := h
	for {
		_, after, ok := strings.Cut(rest, "(")
		if !ok {
			return ""
		}
		inner, tail, closed := strings.Cut(after, ")")
		if !closed {
			return ""
		}
		rest = tail
		level, pure := "", true
		for _, tok := range strings.FieldsFunc(inner, isPrioritySep) {
			switch lower(tok) {
			case "high", "medium", "low":
				if level == "" {
					level = tok
				}
			case "new", "priority":
			default:
				pure = false
			}
		}
		if pure && level != "" {
			return level
		}
	}
}

func isPrioritySep(r rune) bool {
	return r == ',' || r == ';' || r == ':' || (r < 0x80 && isSpace(byte(r)))
}

// EntryIDs is retro_grammar_entry_ids: the ID column of EntryRows.
func EntryIDs(d *Doc) []string {
	rows := EntryRows(d)
	ids := make([]string, len(rows))
	for i, r := range rows {
		ids[i] = r.ID
	}
	return ids
}

// EntryWarn is retro_grammar_entry_warn (#1332 N6): one WARN line when Delta counts more form-2 entries than
// EntryRows yields ids for (a `### **D1** —` entry is counted but cannot be tracked or seeded), else "".
func EntryWarn(d *Doc) string {
	info := Delta(d)
	if info.Form != FormEntries {
		return ""
	}
	n := len(EntryRows(d))
	if n >= info.Count {
		return ""
	}
	return fmt.Sprintf("WARN: %s: only %d of %d '### … —' entries have a usable ID token (a '**D1**' or '[D1]' "+
		"token is not trackable) — count by hand\n", filepath.Base(d.Path), n, info.Count)
}
