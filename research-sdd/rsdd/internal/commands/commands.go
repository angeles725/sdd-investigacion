// Package commands is the registry: it concatenates the version command and
// every domain's Commands into Table. It is the only package allowed to import
// domains. A porting unit adds its command to its own domain's Commands var and
// never edits this file.
package commands

import (
	"fmt"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/adapter"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/adversarial"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/bacnet"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/budget"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/corpus"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/corroborate"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/decompile"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/exec"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/extract"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/formats"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/gate"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/hook"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/install"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/lint"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/maint"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/niagara"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/plan"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/retro"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/serial"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/status"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/sweep"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/verify"
)

// namedSet is one source of commands, named for collision messages.
type namedSet struct {
	name string
	cmds []cli.Command
}

// assemble concatenates the sets and refuses any collision across them, naming
// both owning domains for a duplicate (group, name); cli.Validate then rejects a
// group that shares its name with an ungrouped command. Nothing is silently shadowed.
func assemble(sets []namedSet) ([]cli.Command, error) {
	var out []cli.Command
	owner := map[[2]string]string{}
	for _, s := range sets {
		for _, c := range s.cmds {
			key := [2]string{c.Group, c.Name}
			if prev, dup := owner[key]; dup {
				return nil, fmt.Errorf("duplicate command %q in domains %q and %q", cmdLabel(c), prev, s.name)
			}
			owner[key] = s.name
			out = append(out, c)
		}
	}
	if err := cli.Validate(out); err != nil {
		return nil, err
	}
	return out, nil
}

func cmdLabel(c cli.Command) string {
	if c.Group == "" {
		return c.Name
	}
	return c.Group + " " + c.Name
}

// Table is the full command table consumed by cli.Run: version plus every
// domain's Commands. A broken table is a programming error and fails at start-up.
var Table = mustAssemble()

func mustAssemble() []cli.Command {
	t, err := assemble([]namedSet{
		{"commands", []cli.Command{versionCommand}},
		{"adapter", adapter.Commands},
		{"adversarial", adversarial.Commands},
		{"bacnet", bacnet.Commands},
		{"budget", budget.Commands},
		{"corpus", corpus.Commands},
		{"corroborate", corroborate.Commands},
		{"decompile", decompile.Commands},
		{"exec", exec.Commands},
		{"extract", extract.Commands},
		{"formats", formats.Commands},
		{"gate", gate.Commands},
		{"hook", hook.Commands},
		{"install", install.Commands},
		{"lint", lint.Commands},
		{"maint", maint.Commands},
		{"niagara", niagara.Commands},
		{"plan", plan.Commands},
		{"retro", retro.Commands},
		{"serial", serial.Commands},
		{"status", status.Commands},
		{"sweep", sweep.Commands},
		{"verify", verify.Commands},
	})
	if err != nil {
		panic("rsdd: invalid command table: " + err.Error())
	}
	return t
}

// Main is the Table-bound entry point (the golden kit's `main`).
func Main(args []string, s cli.Stdio) int { return cli.Run(Table, args, s) }
