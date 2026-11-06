//go:build unix && !nodiff

package show

import "testing"

// The S7 differential: the campaign queue block and the document-cycle outline against the frozen script (the S6
// assembly with the campaign and document-cycle excerpts in place, see SOURCE.txt). Same worlds, fakes and
// rendering as S6; the clock is the script's own hook (_RSDD_NOW_EPOCH).
func TestDifferentialS7(t *testing.T) { differentialDefault(t, s7Scenarios(), goldenS7) }
