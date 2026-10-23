// Command rsdd-srchash prints the source hash of a directory: the value the
// Makefile stamps into rsdd (`rsdd version --source-hash`) via -ldflags.
package main

import (
	"fmt"
	"os"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/commands"
)

func main() {
	s, err := cli.OSStdio()
	if err != nil {
		fmt.Fprintf(os.Stderr, "rsdd-srchash: %v\n", err)
		os.Exit(cli.ExitOperational)
	}
	os.Exit(commands.SourceHashMain(os.Args[1:], s))
}
