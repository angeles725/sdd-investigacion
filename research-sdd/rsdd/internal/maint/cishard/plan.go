package cishard

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"io/fs"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// planArgs is what the plan command line said.
type planArgs struct {
	spec      shardSpec
	durations string
}

// parsePlanArgs reads --shard I/N [--durations FILE]; the error text is the usage message.
func parsePlanArgs(args []string) (planArgs, error) {
	f := flag.NewFlagSet("plan", flag.ContinueOnError)
	f.SetOutput(io.Discard)
	shard := f.String("shard", "", "")
	dur := f.String("durations", "", "")
	if err := f.Parse(args); err != nil {
		return planArgs{}, err
	}
	if f.NArg() > 0 {
		return planArgs{}, fmt.Errorf("unexpected argument %q", f.Arg(0))
	}
	spec, err := parseShard(*shard)
	if err != nil {
		return planArgs{}, err
	}
	return planArgs{spec: spec, durations: *dur}, nil
}

// loadDurations reads the durations file. It returns the parsed file, or a degraded reason when there is no usable
// weight: no file named, an absent or unreadable one, or one that lists no planned package. An invalid line is not
// degraded, it is refused by the caller.
func loadDurations(s cli.Stdio, path string, known map[string]bool) (durations, string) {
	if path == "" {
		return durations{}, "no --durations file given"
	}
	data, err := readPath(s, path)
	if errors.Is(err, fs.ErrNotExist) {
		return durations{}, "durations file absent"
	}
	if err != nil {
		return durations{}, "durations file unreadable"
	}
	d := parseDurations(data, known)
	if len(d.invalid) == 0 && len(d.weights) == 0 {
		if len(d.stale) == 0 {
			return d, "durations file lists no package"
		}
		return d, "durations file lists no planned package"
	}
	return d, ""
}

// runPlan is `rsdd maint ci-shard plan`.
func runPlan(args []string, s cli.Stdio) int {
	a, err := parsePlanArgs(args)
	if err != nil {
		return usage(s, err.Error())
	}
	in, err := readStdin(s)
	if err != nil {
		fmt.Fprintf(s.Err, "ci-shard: absent-input — the package list on stdin could not be read: %v\n", err)
		return exitFindings
	}
	pkgs, issue := parsePackages(in)
	if issue != nil {
		return refuseList(s, "package list", issue)
	}
	known := make(map[string]bool, len(pkgs))
	for _, p := range pkgs {
		known[p] = true
	}
	d, degraded := loadDurations(s, a.durations, known)
	if len(d.invalid) > 0 {
		for _, line := range d.invalid {
			fmt.Fprintf(s.Err, "ci-shard: INVALID — %s %s\n", a.durations, line)
		}
		fmt.Fprintf(s.Err, "ci-shard: durations file has %d invalid line(s); nothing planned\n", len(d.invalid))
		return exitFindings
	}
	share, loads, unlisted := choose(pkgs, d.weights, degraded, a.spec)
	noteAssignment(s.Err, a.spec, len(pkgs), len(share), loads, unlisted, d.stale, degraded)
	if len(share) == 0 {
		fmt.Fprintf(s.Err, "ci-shard: EMPTY SHARD — %d/%d selected 0 of %d packages (N exceeds the package count); nothing to run, so this shard is not a pass\n", a.spec.i, a.spec.n, len(pkgs))
		return exitFindings
	}
	fmt.Fprintln(s.Out, strings.Join(share, "\n"))
	return exitOK
}

// refuseList prints the typed state of a list (what names it: "package list", "planned list") that cannot be used.
func refuseList(s cli.Stdio, what string, issue *listIssue) int {
	if issue.state == "invalid" {
		fmt.Fprintf(s.Err, "ci-shard: INVALID — %s %s\n", what, issue.detail)
	} else {
		fmt.Fprintf(s.Err, "ci-shard: %s — %s: %s; nothing was written, an empty result is never a pass\n", issue.state, what, issue.detail)
	}
	return exitFindings
}

// choose returns this shard's packages, the predicted loads of every shard and the packages that took the default
// weight. A degraded run has no weight at all, so every package weighs the default and the greedy rule reduces to
// position mod N of the sorted list (pinned by TestWithoutWeightsIsPositionModN); it reports no loads and no unlisted
// packages, because nothing was predicted.
func choose(pkgs []string, weights map[string]int, degraded string, spec shardSpec) (share []string, loads []int, unlisted []string) {
	a := assign(pkgs, weights, spec.n)
	if degraded != "" {
		return a.shares[spec.i-1], nil, nil
	}
	return a.shares[spec.i-1], a.loads, a.unlisted
}
