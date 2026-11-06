package goimpact

import (
	_ "embed"
	"errors"
	"flag"
	"fmt"
	"io"
	"path/filepath"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

//go:embed help.txt
var help string

const tool = "go-impact"

// exitDegraded is the usage and unreadable-module exit.
const exitDegraded = 2

// Run is `rsdd maint go-impact [--repo DIR] [--wide N] FILE...`.
func Run(args []string, s cli.Stdio) int {
	fs := flag.NewFlagSet("rsdd maint go-impact", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	repo := fs.String("repo", "", "repository root (default: the working directory)")
	wide := fs.Int("wide", DefaultWide, "FULL when a closure reaches more than N distinct bash files")
	if err := fs.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			fmt.Fprint(s.Out, help)
			return cli.ExitOK
		}
		fmt.Fprint(s.Err, help)
		return degrade(s, err.Error())
	}
	files := fs.Args()
	switch {
	case len(files) == 0:
		fmt.Fprint(s.Err, help)
		return degrade(s, "no changed files given")
	case *wide < 1:
		return degrade(s, "--wide must be at least 1")
	}
	root := *repo
	if root == "" {
		root = s.Cwd
	}
	if root == "" {
		return degrade(s, "no --repo and no working directory")
	}
	if !filepath.IsAbs(root) && s.Cwd != "" {
		root = filepath.Join(s.Cwd, root)
	}
	m, err := Load(root)
	if err != nil {
		return degrade(s, err.Error())
	}
	known := map[Command]bool{}
	for _, c := range m.AllCommands() {
		known[c] = true
	}
	bash, err := ScanBash(root, func(c Command) bool { return known[c] })
	if err != nil {
		return degrade(s, err.Error())
	}
	a := NewAnalysis(m, bash, *wide)
	var out strings.Builder
	for _, f := range files {
		for _, l := range a.Classify(f) {
			out.WriteString(l + "\n")
		}
	}
	out.WriteString(a.Summary() + "\n")
	fmt.Fprint(s.Out, out.String())
	return cli.ExitOK
}

func degrade(s cli.Stdio, why string) int {
	fmt.Fprintf(s.Err, "degraded: %s: %s\n", tool, why)
	return exitDegraded
}
