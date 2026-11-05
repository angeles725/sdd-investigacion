package fetchdoc

import (
	"os"
	"os/signal"
	"syscall"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// Run is `rsdd sources fetch-doc [--replace] doc|web|ocr ...`: download and PRESERVE an external source inside
// TARGET/sources/ with a traceable row in SOURCES.md ("URLs die; evidence does not"). INT and TERM cancel the
// tracked download (and its process group) and exit 130/143; the rest of the contract is Execute's.
func Run(args []string, s cli.Stdio) int {
	sigs := make(chan os.Signal, 2)
	signal.Notify(sigs, syscall.SIGINT, syscall.SIGTERM)
	defer signal.Stop(sigs)
	return Execute(args, ProductionDeps(s, os.Getpid(), sigs))
}
