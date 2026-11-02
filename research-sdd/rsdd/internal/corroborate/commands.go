// Package corroborate owns the rsdd commands for corroboration tools (one subpackage per tool).
// See docs/adding-a-command.md.
package corroborate

import (
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/corroborate/capa"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/corroborate/classfile"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/corroborate/fidelity"
)

// Commands is this domain's contribution to the command table. A unit adds
// its entries here and never edits internal/commands.
var Commands = []cli.Command{
	{Name: "classfile", Group: "corroborate", Summary: "One CLASSFILE line (major, LocalVariableTable, re-sugar risk) read from a .class or .jar", Run: classfile.Run},
	{Name: "java-fidelity", Group: "corroborate", Summary: "measure what the Java decompilation pipeline preserves (javac, decompile, recompile, javap)", Run: fidelity.Run},
	{Name: "capa", Group: "corroborate", Summary: "offline capa capability inventory of a PE/ELF/.NET binary (bubblewrap)", Run: capa.Run},
}
