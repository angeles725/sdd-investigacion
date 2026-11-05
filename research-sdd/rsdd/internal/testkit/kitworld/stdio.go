package kitworld

import (
	"bytes"
	"strings"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// Stdio is the cli.Stdio of a run in this world: its environment is exactly Env(extra...), its working directory cwd,
// its stdout and stderr fresh buffers.
func (w *World) Stdio(cwd string, extra ...string) (cli.Stdio, *bytes.Buffer, *bytes.Buffer) {
	env := w.Env(extra...)
	get := func(k string) string {
		v := ""
		for _, kv := range env {
			if s, ok := strings.CutPrefix(kv, k+"="); ok {
				v = s
			}
		}
		return v
	}
	var o, e bytes.Buffer
	return cli.Stdio{In: strings.NewReader(""), Out: &o, Err: &e, Env: get, Environ: func() []string { return env },
		Clock: time.Now, Cwd: cwd}, &o, &e
}
