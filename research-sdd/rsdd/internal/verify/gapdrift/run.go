package gapdrift

import (
	"fmt"
	"os"
	"strconv"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/fsview"
)

const usageLine = "usage: check-gap-drift.sh <target-dir> [--state <file>] [--threshold <pct>] [--all]"

// Run is `rsdd verify gap-drift <target-dir> [--state <file>] [--threshold <pct>] [--all]`.
//
// Exit: 0 no drift suspected, 1 drift or unparsed rows (findings only), 2 every operational failure. The report is
// check-gap-drift.sh's; the differences, all by design, are listed in the package doc and
// tool-registry.d/check-gap-drift.md.
func Run(args []string, s cli.Stdio) int {
	res, err := runArgs(args, s)
	if err != nil {
		if e, ok := err.(*Error); ok && e.Kind == ErrUsage {
			fmt.Fprintln(s.Err, usageLine)
		} else {
			fmt.Fprintln(s.Err, err)
		}
		return cli.ExitUsage
	}
	res.Render(s.Out)
	return res.ExitCode()
}

func runArgs(args []string, s cli.Stdio) (Result, error) {
	view := fsview.View{Cwd: s.Cwd}
	target := ""
	if len(args) > 0 {
		target = args[0]
	}
	if target == "" || !view.IsDir(target) {
		return Result{}, &Error{Kind: ErrUsage}
	}
	state, threshold, all := "", DefaultThreshold, false
	thresholdArg, thresholdSet := "", false
	for rest := args[1:]; len(rest) > 0; {
		switch rest[0] {
		case "--state":
			if len(rest) < 2 || rest[1] == "" {
				return Result{}, &Error{Kind: ErrUsage}
			}
			state, rest = rest[1], rest[2:]
		case "--threshold":
			if len(rest) < 2 {
				return Result{}, &Error{Kind: ErrUsage}
			}
			thresholdArg, thresholdSet, rest = rest[1], true, rest[2:]
		case "--all":
			all, rest = true, rest[1:]
		default:
			return Result{}, &Error{Kind: ErrUsage}
		}
	}
	if thresholdSet {
		n, ok := parseThreshold(thresholdArg)
		if !ok {
			return Result{}, &Error{Kind: ErrThreshold, Msg: "check-gap-drift: --threshold must be an integer percent 0-100 (got '" + thresholdArg + "')"}
		}
		threshold = n
	}
	if state == "" {
		state = target + "/RESEARCH-STATE.md"
	}
	unreadable := &Error{Kind: ErrStateUnreadable, Msg: "check-gap-drift: cannot read state file " + state}
	if !view.IsFile(state) || !view.Readable(state) {
		return Result{}, unreadable
	}
	corpus, err := OpenCorpus(s.Cwd, target)
	if err != nil {
		return Result{}, err
	}
	src, rerr := os.ReadFile(view.At(state))
	if rerr != nil {
		unreadable.Err = rerr
		return Result{}, unreadable
	}
	return corpus.Check(string(src), state, Options{Threshold: threshold, All: all})
}

// parseThreshold reads an integer percent 0-100 in decimal; a leading zero is not octal.
func parseThreshold(v string) (int, bool) {
	if v == "" || strings.Trim(v, "0123456789") != "" {
		return 0, false
	}
	trimmed := strings.TrimLeft(v, "0")
	if trimmed == "" {
		return 0, true
	}
	n, err := strconv.Atoi(trimmed)
	if err != nil || n > 100 {
		return 0, false
	}
	return n, true
}
