package flakehunt

import "fmt"

const usageLine = "usage: kit-flake-hunt.sh [--repo DIR] [--runs K] [--load N] [--load-timeout S] [--suite-timeout S] [--suites FILE | --suite PATH ...] [--tier core|all] [--prove-teeth] [--out DIR] [--evidence-url URL] [--file-issues[=apply]]"

// Issue-filing modes of --file-issues.
const (
	fileNone  = ""
	fileDry   = "dry"
	fileApply = "apply"
)

// options is what the command line said: values stay raw text until validate judges them (the bash kept them as
// strings too, and an empty --load or --load-timeout means "not given").
type options struct {
	repo, runs, load, loadTimeout, suiteTimeout string
	suitesFile, tier, out, evidence, fileMode   string
	suiteArgs                                   []string
	prove, help                                 bool
}

// stop is a run that ends early: the exit code and the text for stderr (newline included).
type stop struct {
	code int
	msg  string
}

// die is the typed degraded state of the bash tool (`degraded: kit-flake-hunt: <why>`, exit 2).
func die(format string, a ...any) *stop {
	return &stop{2, "degraded: kit-flake-hunt: " + fmt.Sprintf(format, a...) + "\n"}
}

// bad is a refused command line or value (`kit-flake-hunt: <why>`, exit 2).
func bad(format string, a ...any) *stop {
	return &stop{2, "kit-flake-hunt: " + fmt.Sprintf(format, a...) + "\n"}
}

// parse reads the arguments in order, as the bash `case` loop did: the last occurrence of a valued flag wins, -h ends
// the scan at once, a flag that lacks its value prints the usage line, and an unknown word is refused.
func parse(args []string) (options, *stop) {
	o := options{runs: "3", suiteTimeout: "900", tier: "all"}
	valued := map[string]*string{
		"--repo": &o.repo, "--runs": &o.runs, "--load": &o.load, "--load-timeout": &o.loadTimeout,
		"--suite-timeout": &o.suiteTimeout, "--suites": &o.suitesFile, "--tier": &o.tier, "--out": &o.out,
		"--evidence-url": &o.evidence,
	}
	for i := 0; i < len(args); {
		a := args[i]
		if dst, ok := valued[a]; ok {
			if i+1 >= len(args) {
				return o, &stop{2, usageLine + "\n"}
			}
			*dst = args[i+1]
			i += 2
			continue
		}
		switch a {
		case "--suite":
			if i+1 >= len(args) {
				return o, &stop{2, usageLine + "\n"}
			}
			o.suiteArgs = append(o.suiteArgs, args[i+1])
			i += 2
			continue
		case "--prove-teeth":
			o.prove = true
		case "--file-issues":
			o.fileMode = fileDry
		case "--file-issues=apply":
			o.fileMode = fileApply
		case "-h", "--help":
			o.help = true
			return o, nil
		default:
			return o, &stop{2, fmt.Sprintf("kit-flake-hunt: unknown argument: %s\n%s\n", a, usageLine)}
		}
		i++
	}
	return o, nil
}
