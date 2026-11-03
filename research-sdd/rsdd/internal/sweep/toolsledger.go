package sweep

import (
	"bytes"
	"regexp"
	"strings"
)

// How sweep-tools.sh decides that a tool is RECORDED: a T-row in any retro of the target, or a row of the
// ledger tools/README.md (METHODOLOGY section 10). Both are read through one seam, readFunc, so a test can make
// a file unreadable without root or chmod.

// readFunc reads a whole file; os.ReadFile in production.
type readFunc func(path string) ([]byte, error)

var (
	// reTRow is `grep -E '^\| T[0-9]+'`: a table row that opens with a T-number.
	reTRow = regexp.MustCompile(`^\| T[0-9]+`)
	// reLedgerSeparator is the `grep -vE '^\|[[:space:]]*[-:]+[[:space:]]*\|'` of the ledger: a separator row.
	// Like the script's, it also drops a row whose first cell is only dashes or colons.
	reLedgerSeparator = regexp.MustCompile(`^\|[ \t\n\v\f\r]*[-:]+[ \t\n\v\f\r]*\|`)
)

// ledgerState is the three distinguishable states of tools/README.md (CLAUDE.md section 7); a ledger that
// could not be read is never reported as one that holds nothing.
type ledgerState int

const (
	ledgerNone    ledgerState = iota // no README.md: no ledger entries is the right count
	ledgerNoTable                    // README.md without a table row
	ledgerError                      // README.md that could not be read
	ledgerParsed
)

// isBinary is how grep sees a file with a NUL byte: its matching lines are not printed.
func isBinary(data []byte) bool { return bytes.IndexByte(data, 0) >= 0 }

// matchLines is the lines of data that satisfy keep, in order. A binary file yields none.
func matchLines(data []byte, keep func(line string) bool) []string {
	if isBinary(data) {
		return nil
	}
	var out []string
	for _, l := range strings.Split(string(data), "\n") {
		if keep(l) {
			out = append(out, l)
		}
	}
	return out
}

// retroTRows is the T-rows of one retro.
func retroTRows(data []byte) []string {
	return matchLines(data, reTRow.MatchString)
}

// ledgerRows is the table rows of the ledger: every line that opens with a pipe, separators excepted.
func ledgerRows(data []byte) []string {
	return matchLines(data, func(l string) bool { return strings.HasPrefix(l, "|") && !reLedgerSeparator.MatchString(l) })
}

// inTRows is `grep -qF base <<<"$t_rows"`: the name is a substring of some T-row. The script handed the name to
// grep as an option when it started with a dash; here it is the literal it always meant.
func inTRows(rows []string, base string) bool {
	for _, r := range rows {
		if strings.Contains(r, base) {
			return true
		}
	}
	return false
}

const (
	ledgerBefore = "`|/ "
	ledgerAfter  = "`|/ :"
)

// inLedger is `grep -qE "(^|[`|/ ])base([`|/ :])"` over the ledger rows: the name sits between a cell start or a
// path separator and a cell end, so `envelope.py` does not match inside `gf-envelope.py`. The end of a line
// is not a boundary (the script's pattern needs a character after the name). The script read the name as a
// regex with only the dot escaped; here every character is literal.
func inLedger(rows []string, base string) bool {
	for _, r := range rows {
		for from := 0; ; {
			i := strings.Index(r[from:], base)
			if i < 0 {
				break
			}
			i += from
			end := i + len(base)
			if (i == 0 || strings.IndexByte(ledgerBefore, r[i-1]) >= 0) && end < len(r) && strings.IndexByte(ledgerAfter, r[end]) >= 0 {
				return true
			}
			from = i + 1
		}
	}
	return false
}
