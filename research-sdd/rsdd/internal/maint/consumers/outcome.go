package consumers

import (
	"io"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// outcome is a run that ends before the report: what it prints and its exit code.
type outcome struct {
	out, err string
	rc       int
}

func (o outcome) emit(s cli.Stdio) int {
	io.WriteString(s.Out, o.out)
	io.WriteString(s.Err, o.err)
	return o.rc
}

func degraded(why string) *outcome {
	return &outcome{out: stateDegradedOut, err: why, rc: cli.ExitDegraded}
}
