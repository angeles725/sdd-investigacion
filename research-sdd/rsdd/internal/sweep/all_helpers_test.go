package sweep

import (
	"bytes"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// runAll runs `rsdd sweep all --kit <kit> <args>` in process, through the command table.
func (w *world) runAll(args ...string) result {
	w.t.Helper()
	var o, e bytes.Buffer
	rc := cli.Run(Commands, append([]string{"sweep", "all", "--kit", w.kit}, args...), w.stdio(&o, &e))
	return result{o.String(), e.String(), rc}
}
