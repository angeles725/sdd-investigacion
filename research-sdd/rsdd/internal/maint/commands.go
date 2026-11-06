// Package maint owns the rsdd commands for kit-only maintenance tooling.
// See docs/adding-a-command.md.
package maint

import (
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/maint/gate"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/maint/prpipeline"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/maint/sizecheck"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/maint/waitmerge"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/maint/writercheck"
)

// Commands is this domain's contribution to the command table. A unit adds
// its entries here and never edits internal/commands.
var Commands = []cli.Command{
	{Name: "rdd-start", Group: "maint", Summary: "assess the committed range and start the native review (explicit consent)", Run: RddStart},
	{Name: "gate", Group: "maint", Summary: "run ONE serial full gate under a flock, log it and echo its summary (kit-gate)", Run: gate.Run},
	{Name: "wait-merge", Group: "maint", Summary: "wait for a PR's CI, run the merge gate and confirm it merged (kit-wait-merge)", Run: waitmerge.Run},
	{Name: "pr-pipeline", Group: "maint", Summary: "restack, push, review, gate and merge one PR (kit-pr-pipeline)", Run: prpipeline.New(RddStart, RddDrive)},
	{Name: "size-check", Group: "maint", Summary: "measure the authored lines of a PR range against the review budget (kit-size-check)", Run: sizecheck.Run, PlainExit3: true},
	{Name: "writer-check", Group: "maint", Summary: "check a writer's diff for required suites, bound teeth logs and name-based kills (kit-writer-check)", Run: writercheck.Run},
	{Name: "rdd-drive", Group: "maint", Summary: "follow the provider-issued review transitions to acknowledgement", Run: RddDrive},
}
