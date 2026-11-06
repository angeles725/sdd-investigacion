package consumers

import (
	"fmt"
	"io"
	"strings"
)

// writeHeader prints what was read and the script list with its exclusions: the proof that the run looked.
func writeHeader(w io.Writer, l listing, sc scriptSet) {
	fmt.Fprintf(w, reportRepository, l.top)
	fmt.Fprintf(w, reportKit, l.top)
	fmt.Fprintf(w, reportFiles, len(l.files))
	fmt.Fprintf(w, reportScripts, len(sc.paths), sc.extSummary())
	if len(sc.ambiguous) == 0 {
		fmt.Fprint(w, reportNoAmbig)
	} else {
		fmt.Fprintf(w, reportAmbiguous, len(sc.ambiguous), strings.Join(sc.ambiguous, ", "))
	}
	fmt.Fprintf(w, reportExcluded, sc.excludedSummary())
}

// writeFooter prints the Go classes line and the limits, on every run.
func writeFooter(w io.Writer) {
	fmt.Fprint(w, reportGoClasses)
	fmt.Fprint(w, reportLimitsHead)
	for _, l := range limits {
		fmt.Fprintf(w, "  %s\n", l)
	}
}
