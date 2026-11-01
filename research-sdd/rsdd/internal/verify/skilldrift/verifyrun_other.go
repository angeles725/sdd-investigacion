//go:build !unix

package skilldrift

import (
	"bytes"
	"context"
	"errors"
	"os/exec"
	"time"
)

// verifyOutcome and runVerify without process groups (no unix): the bound stops the command itself, not its descendants.

type verifyOutcome struct {
	out      string
	rc       int
	timedOut bool
	noTemp   bool
}

func runVerify(e envView, vcmd, dir string, vt int) verifyOutcome {
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(vt)*time.Second)
	defer cancel()
	var buf bytes.Buffer
	c := exec.CommandContext(ctx, vcmd, "--verify")
	c.Env, c.Dir, c.Stdout, c.Stderr = e.environ(), dir, &buf, &buf
	c.WaitDelay = time.Second
	err := c.Run()
	res := verifyOutcome{out: trimNL(buf.String()), noTemp: true}
	var ee *exec.ExitError
	switch {
	case ctx.Err() != nil:
		res.timedOut, res.rc = true, 124
	case errors.As(err, &ee):
		res.rc = ee.ExitCode()
	case err != nil:
		res.rc = 127
	}
	return res
}
