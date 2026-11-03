// Package adapter owns the rsdd commands for analysis adapters. The library they run lives in
// internal/core/adapter, so every domain can use it (kit issue #2421).
package adapter

import (
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	coreadapter "github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/adapter"
)

// Commands is this domain's contribution to the command table. A unit adds
// its entries here and never edits internal/commands.
var Commands = []cli.Command{
	{
		Name:    "manifest",
		Group:   "adapter",
		Summary: "create, validate or verify an analysis-manifest.v1 document",
		Run:     coreadapter.ManifestRun,
	},
}
