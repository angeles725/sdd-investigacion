// Package cishard is `rsdd maint ci-shard`, the pure half of the Go CI shards (kit issue #2753, slice 8.2a): it never
// runs `go test`. `plan` splits a package list across N shards with the rule of `run-all.sh --shard I/N`, and
// `manifest` turns the `go test -json` stream of one shard into the manifest `shard-join.sh` reads.
//
// Exit codes: 0 ok, 1 operational failure or finding, 2 usage. Stdout carries the data, stderr the typed notes.
package cishard

import (
	_ "embed"
	"fmt"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

//go:embed help.txt
var help string

// Exit codes of this module.
const (
	exitOK       = 0
	exitFindings = 1
	exitUsage    = 2
)

// usage prints the optional message, then the help text, on stderr and returns the usage exit code.
func usage(s cli.Stdio, msg string) int {
	if msg != "" {
		fmt.Fprintf(s.Err, "ci-shard: %s\n", msg)
	}
	fmt.Fprint(s.Err, help)
	return exitUsage
}

// Run is `rsdd maint ci-shard`.
func Run(args []string, s cli.Stdio) int {
	if len(args) == 0 {
		return usage(s, "a subcommand is required (plan or manifest)")
	}
	switch args[0] {
	case "plan":
		return runPlan(args[1:], s)
	case "manifest":
		return runManifest(args[1:], s)
	case "-h", "--help", "help":
		fmt.Fprint(s.Out, help)
		return exitOK
	}
	return usage(s, "unknown subcommand "+args[0])
}
