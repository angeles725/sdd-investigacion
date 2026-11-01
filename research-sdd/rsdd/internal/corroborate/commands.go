// Package corroborate owns the rsdd commands for corroboration tools (one subpackage per tool).
// It is a stub until a porting unit fills it; see docs/adding-a-command.md.
package corroborate

import (
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/corroborate/classfile"
)

// Commands is this domain's contribution to the command table. A unit adds
// its entries here and never edits internal/commands.
var Commands = []cli.Command{
	{Name: "classfile", Group: "corroborate", Summary: "One CLASSFILE line (major, LocalVariableTable, re-sugar risk) read from a .class or .jar", Run: classfile.Run},
}
