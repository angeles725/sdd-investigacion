package gate

import "strings"

// Argument parsing of `rsdd gate merge`.

const mergeUsageLine = "usage: merge-gate.sh --cwd <dir> --base-ref <ref> [--head <sha>] [--pr <PR#> | --merge <PR#>] [--required-checks <a,b,...>] [--no-closure-evidence]"

// mergeDefaultRequired is the comma-separated list of checks required when neither --required-checks nor
// MERGE_GATE_REQUIRED_CHECKS is given. TestDefaultRequiredChecksAreRealJobs reads it, so the default cannot name a
// check that no workflow job produces.
const mergeDefaultRequired = "shellcheck,toolbelt-tests"

// environLookup is `${KEY+x}` / `$KEY` over environ: the last entry wins.
func environLookup(environ []string, key string) (string, bool) {
	for i := len(environ) - 1; i >= 0; i-- {
		if v, ok := strings.CutPrefix(environ[i], key+"="); ok {
			return v, true
		}
	}
	return "", false
}

// allDigits is the negation of `*[!0-9]*` for a non-empty string.
func allDigits(s string) bool { return strings.Trim(s, "0123456789") == "" }

// parseArgs reads the flags as the bash loop does: a flag that needs a value takes the next word whatever it
// looks like, the last occurrence wins, and --merge sets the PR number and the merge flag together.
func (g *mergeGate) parseArgs(args []string) (code int, ok bool) {
	g.required = mergeDefaultRequired
	if v, set := environLookup(g.s.Environ(), "MERGE_GATE_REQUIRED_CHECKS"); set { // set-but-empty = opt-out
		g.required = v
	}
	value := func(i int) (string, bool) {
		if i+1 >= len(args) {
			return "", false
		}
		return args[i+1], true
	}
	for i := 0; i < len(args); {
		switch args[i] {
		case "--pr", "--cwd", "--base-ref", "--head", "--merge", "--required-checks":
			why := map[string]string{
				"--pr":              "--pr needs a PR number",
				"--cwd":             "--cwd needs a value",
				"--base-ref":        "--base-ref needs a value",
				"--head":            "--head needs a value",
				"--merge":           "--merge needs a PR number",
				"--required-checks": `--required-checks needs a value (use "" to opt out)`,
			}[args[i]]
			v, has := value(i)
			if !has {
				return g.usage(why), false
			}
			switch args[i] {
			case "--pr":
				g.pr = v
			case "--cwd":
				g.cwd = v
			case "--base-ref":
				g.base = v
			case "--head":
				g.wantHead = v
			case "--merge":
				g.pr, g.doMerge = v, true
			case "--required-checks":
				g.required = v
			}
			i += 2
		case "--no-closure-evidence":
			g.noEvidence = true
			i++
		default:
			return g.usage("unknown argument: " + args[i]), false
		}
	}
	if g.cwd == "" {
		return g.usage("--cwd is required"), false
	}
	if g.base == "" {
		return g.usage("--base-ref is required"), false
	}
	if g.pr != "" && !allDigits(g.pr) {
		return g.usage("--pr/--merge needs a numeric PR number, got: " + g.pr), false
	}
	return 0, true
}
