// Package srcregistry is the SOURCES.md registry of a research target: the rows of its markdown table, how a new
// row is inserted, how an archived file's row is retargeted, and the sha256 / identity helpers of a preserved
// document. It is the core-tier home of what `rsdd sources fetch-doc` writes and what the verify-sources port
// reads, so neither re-implements the table grammar (a second parser would drift from the writer).
//
// The grammar is the one the legacy fetch-doc.sh awk used: a table row is a line whose first non-space character
// is "|"; the cells are the "|"-separated fields (field 2 = File ... field 7 = Citing blocks), trimmed of spaces
// and tabs only; the FIRST contiguous run of rows (blank lines tolerated inside it) is the registry table.
//
// Exported API (the verify-sources port calls these in process):
//
//	ParseRows, Row.IsHeader, Row.IsSeparator   read the rows of a SOURCES.md
//	HasRow, FormatRow, SafeCell                query and render rows
//	InsertRow, RetargetFile                    pure edits of a document
//	Append, Retarget                           the same edits on SOURCES.md of a sources directory
//	SHA256Hex, FileSHA256, Identity            document identity: bare hex sha256 of bytes / a file, and fsx.Identity
package srcregistry

import "strings"

// Header is the document a new SOURCES.md starts with.
const Header = "# External sources preserved\n\n| File | Type | Origin (URL) | Date (UTC) | sha256 | Citing blocks |\n|---|---|---|---|---|---|\n"

// Row is one table row. Line is its 1-based line number in the document.
type Row struct {
	Line                                  int
	File, Type, Origin, Date, SHA, Citing string
}

// ParseRows returns every table row of md, header and separator rows included (see IsHeader, IsSeparator).
func ParseRows(md []byte) []Row {
	var rows []Row
	for i, l := range splitLines(md) {
		if !isRow(l) {
			continue
		}
		c := cells(l)
		rows = append(rows, Row{Line: i + 1, File: c[1], Type: c[2], Origin: c[3], Date: c[4], SHA: c[5], Citing: c[6]})
	}
	return rows
}

// IsHeader reports the column-title row.
func (r Row) IsHeader() bool { return r.File == "File" }

// IsSeparator reports the |---|---| row.
func (r Row) IsSeparator() bool {
	return r.File != "" && strings.Trim(r.File, "-: ") == ""
}

// FormatRow renders the row fetch-doc registers (the Citing cell starts empty).
func FormatRow(file, kind, origin, date, sha string) string {
	return "| " + file + " | " + kind + " | " + origin + " | " + date + " | " + sha + " | |"
}

// SafeCell makes a value safe for one cell: a literal "|" becomes %7C so the row keeps its column count.
func SafeCell(s string) string { return strings.ReplaceAll(s, "|", "%7C") }

// HasRow reports whether a row has File cell file and, when sha is not empty, sha256 cell sha.
func HasRow(md []byte, file, sha string) bool {
	for _, r := range ParseRows(md) {
		if r.File == file && (sha == "" || r.SHA == sha) {
			return true
		}
	}
	return false
}

// InsertRow returns md with row placed right after the last line of the first table (appended when there is none).
// The first table is the first run of rows; blank lines inside it are tolerated, any other line closes it.
func InsertRow(md []byte, row string) []byte {
	ls := splitLines(md)
	last, intable, closed := -1, false, false
	for i, l := range ls {
		switch {
		case isRow(l):
			if !closed {
				intable, last = true, i
			}
		case strings.TrimLeft(l, spaceChars) != "":
			if intable {
				closed = true
			}
		}
	}
	if last < 0 {
		last = len(ls) - 1
	}
	out := make([]string, 0, len(ls)+1)
	out = append(out, ls[:last+1]...)
	out = append(out, row)
	out = append(out, ls[last+1:]...)
	return joinLines(out)
}

// RetargetFile rewrites the File cell of every row whose File cell is oldFile AND whose sha256 cell is sha to
// newFile; others counts the rows for oldFile that carry another sha and were left untouched.
func RetargetFile(md []byte, oldFile, newFile, sha string) (out []byte, others int) {
	ls := splitLines(md)
	for i, l := range ls {
		if !isRow(l) {
			continue
		}
		c := cells(l)
		if c[1] != oldFile {
			continue
		}
		if c[5] != sha {
			others++
			continue
		}
		parts := strings.Split(l, "|")
		parts[1] = " " + newFile + " "
		ls[i] = strings.Join(parts, "|")
	}
	return joinLines(ls), others
}
