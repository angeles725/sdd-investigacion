package consumers

import (
	"fmt"
	"io"
	"strconv"
)

// writeTable prints one row per class of reportClasses. A count that is zero is a word that says why: a class
// with no file at all is `no files`, a class whose files were all binary or not regular is `none read`, a class
// that was read and names no script is `no-match`.
func writeTable(w io.Writer, sn scanned) {
	fmt.Fprintf(w, rowFormat, rowHeadClass, rowHeadFiles, rowHeadWith, rowHeadPairs, rowHeadRefs, rowHeadSelf)
	for _, c := range reportClasses {
		fmt.Fprintf(w, rowFormat, append([]any{c}, cells(sn.total[c], sn.stats(c))...)...)
	}
}

func cells(total int, st classStats) []any {
	if total == 0 {
		return []any{wordNoFiles, wordNA, wordNA, wordNA, wordNA}
	}
	if st.files == 0 {
		return []any{wordNoneRead, wordNA, wordNA, wordNA, wordNA}
	}
	self := wordNone
	if st.selfOnly > 0 {
		self = strconv.Itoa(st.selfOnly)
	}
	if st.refs == 0 {
		return []any{strconv.Itoa(st.files), wordNoMatch, wordNoMatch, wordNoMatch, self}
	}
	return []any{strconv.Itoa(st.files), strconv.Itoa(st.withRef), strconv.Itoa(st.pairs), strconv.Itoa(st.refs), self}
}

// writeUnclassified names every unclassified file that names a script, with its reference count.
func writeUnclassified(w io.Writer, sn scanned) {
	if sn.total[classUnclassified] == 0 {
		fmt.Fprint(w, unclassifiedNoFile)
		return
	}
	hits := sn.referencing(classUnclassified)
	if len(hits) == 0 {
		fmt.Fprint(w, unclassifiedNoRef)
		return
	}
	fmt.Fprint(w, unclassifiedHead)
	for _, r := range hits {
		fmt.Fprintf(w, unclassifiedLine, r.path, r.total())
	}
}

// writeNotRead says what was listed and not read, and why.
func writeNotRead(w io.Writer, sn scanned, listed int) {
	fmt.Fprintf(w, notReadLine, sn.fixtures, sn.goModule, sn.binary, sn.notRegular, len(sn.results), listed)
}
