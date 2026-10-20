// Package commands is the registry: one entry per `rsdd [<group>] <command>`.
package commands

import "github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"

// Table is the full command table consumed by cli.Run.
var Table = []cli.Command{}
