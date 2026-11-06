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

// lines splits stdout into lines, without the trailing CLASSES aggregate (see summary).
func (r result) lines() []string {
	var out []string
	for _, l := range strings.Split(strings.TrimSuffix(r.out, "\n"), "\n") {
		if l != "" && !strings.HasPrefix(l, "CLASSES\t") {
			out = append(out, l)
		}
	}
	return out
}

// summary is the CLASSES line, or "".
func (r result) summary() string {
	for _, l := range strings.Split(r.out, "\n") {
		if strings.HasPrefix(l, "CLASSES\t") {
			return l
		}
	}
	return ""
}
