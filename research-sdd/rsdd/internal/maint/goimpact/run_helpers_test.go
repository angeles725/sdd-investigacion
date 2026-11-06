package goimpact_test

import (
	"bytes"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/maint/goimpact"
)

type result struct {
	out, err string
	rc       int
}

func run(args ...string) result {
	var o, e bytes.Buffer
	rc := goimpact.Run(args, cli.Stdio{Out: &o, Err: &e, Env: func(string) string { return "" }})
	return result{o.String(), e.String(), rc}
}

// lines splits stdout into trimmed lines.
func (r result) lines() []string {
	if r.out == "" {
		return nil
	}
	return strings.Split(strings.TrimSuffix(r.out, "\n"), "\n")
}
