// Package corroborate owns the rsdd commands for corroboration tools (one subpackage per tool).
// See docs/adding-a-command.md.
package corroborate

import (
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/corroborate/fidelity"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/corroborate/kaitai"
)

// Commands is this domain's contribution to the command table. A unit adds
// its entries here and never edits internal/commands.
var Commands = []cli.Command{
	{Name: "java-fidelity", Group: "corroborate", Summary: "measure what the Java decompilation pipeline preserves (javac, decompile, recompile, javap)", Run: fidelity.Run},
	{Name: "kaitai", Group: "corroborate", Summary: "parse a binary with a Kaitai Struct .ksy in network-denied sandboxes (kaitai-evidence.v1)", Run: kaitai.Run},
}
