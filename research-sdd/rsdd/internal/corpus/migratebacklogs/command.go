package migratebacklogs

import "github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"

// Summary is the one-line help of the registry entry.
const Summary = "propose the §8b gap-backlog migration of a corpus as a unified diff per file plus typed MANUAL lines (never edits the target)"

// RunCommand is `rsdd corpus migrate-backlogs <corpus-dir>`, the command behind the shim toolbelt/migrate-backlogs.sh.
func RunCommand(args []string, s cli.Stdio) int {
	return Run(Options{Args: args, Out: s.Out, Err: s.Err})
}
