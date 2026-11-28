package reviewslices

import "fmt"

const (
	usage = "usage: plan-review-slices.sh [--cwd DIR] [--base-ref REF] [--max-lines N]"

	defaultBase = "origin/main"
	defaultMax  = "400"
	maxInt64    = "9223372036854775807"
)

// options is what the command line said.
type options struct {
	cwd, base string
	max       int64
}

// parse reads the command line as the script's loop did: options in any order, the last of a repeated one wins, the
// first fault ends the parse. A non-empty message is the refusal to print (exit 2).
func parse(args []string) (options, string) {
	cwd, base, max := ".", defaultBase, defaultMax
	for len(args) > 0 {
		if len(args) < 2 {
			return options{}, usage
		}
		switch args[0] {
		case "--cwd":
			cwd = args[1]
		case "--base-ref":
			base = args[1]
		case "--max-lines":
			max = args[1]
		default:
			return options{}, usage
		}
		args = args[2:]
	}
	n, msg := maxLines(max)
	return options{cwd: cwd, base: base, max: n}, msg
}

// maxLines validates --max-lines: a positive integer. Intended divergence: the script accepted a value above int64
// and then compared it with `[ -gt ]`, which fails ("integer expression expected"), so no commit was ever
// UNSPLITTABLE, no two commits ever shared a slice and the plan printed max=9223372036854775807 with exit 0 — a wrong
// plan. Such a value is refused here.
func maxLines(v string) (int64, string) {
	if !positive(v) {
		return 0, fmt.Sprintf("plan-review-slices: --max-lines must be a positive integer (got '%s')", v)
	}
	n, ok := count(v)
	if !ok {
		return 0, fmt.Sprintf("plan-review-slices: --max-lines must be a positive integer no larger than %s (got '%s')", maxInt64, v)
	}
	return n, ""
}
