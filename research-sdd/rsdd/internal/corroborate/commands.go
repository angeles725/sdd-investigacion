// Package corroborate owns the rsdd commands for corroboration tools (one subpackage per tool).
// See docs/adding-a-command.md.
package corroborate

import (
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/corroborate/classfile"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/corroborate/decompile"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/corroborate/fidelity"
)

// Commands is this domain's contribution to the command table. A unit adds
// its entries here and never edits internal/commands.
var Commands = []cli.Command{
	{Name: "classfile", Group: "corroborate", Summary: "One CLASSFILE line (major, LocalVariableTable, re-sugar risk) read from a .class or .jar", Run: classfile.Run},
	{Name: "decompile", Group: "corroborate", Summary: "Decompile a Java .jar or .class to source: Vineflower, falling back to CFR or Procyon per unit (typed OK / DEGRADED / PARTIAL)", Run: decompile.Run},
	{Name: "java-fidelity", Group: "corroborate", Summary: "measure what the Java decompilation pipeline preserves (javac, decompile, recompile, javap)", Run: fidelity.Run},
}
