// Package corpus owns the rsdd commands for corpus tooling (init, archive, state-update, append-row, census, profile, coverage, ensure-remote, catalog).
// It is a stub until a porting unit fills it; see docs/adding-a-command.md.
package corpus

import (
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/corpus/catalog"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/corpus/ensureremote"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/corpus/migratebacklogs"
)

// Commands is this domain's contribution to the command table. A unit adds
// its entries here and never edits internal/commands.
var Commands = []cli.Command{
	{Name: "archive", Group: "corpus", Summary: archiveSummary, Run: archiveRun, PlainExit3: true}, // exit 3 = REFUSED
	{Name: "catalog", Group: "corpus", Summary: "regenerate <corpus-root>/CATALOG.md from the corpus block files (<prefix>-block|bloque<N>[-suffix].md)", Run: catalog.Run},
	{Name: "migrate-backlogs", Group: "corpus", Summary: migratebacklogs.Summary, Run: migratebacklogs.RunCommand},
	{Name: "ensure-remote", Group: "corpus", Summary: "create a PRIVATE-by-construction GitHub remote for a corpus and push it", Run: ensureremote.Run, PlainExit3: true}, // 3 = no consent (bash contract), not degraded
}
