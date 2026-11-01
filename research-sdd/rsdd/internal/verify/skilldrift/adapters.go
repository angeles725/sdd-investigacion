package skilldrift

import (
	"bytes"
	"errors"
	"io"
	"os/exec"
	"strings"
)

// The exec seam over install/adapters.sh (kit issue #2365). adapters.sh is not ported: its table and its functions stay bash, and
// every query below is one `bash -c` that sources it exactly the way verify-skill-drift.sh does (`set -uo pipefail` first, so the
// sourced file runs under the same options) and calls ONE function. One process per query keeps each answer, its stderr and its
// exit code those of the script's own `$(rsdd_field ...)`.

const seamPrelude = `set -uo pipefail; . "$1" 2>/dev/null; shift; `

// adapters evaluates the functions of one adapters.sh.
type adapters struct {
	bash string   // the bash binary
	file string   // the adapters.sh path
	env  []string // the environment of every query: the caller's
	dir  string   // working directory of every query
}

// seamAnswer is the outcome of one query: stdout with the trailing newlines of a command substitution removed, the stderr of
// the function (which the script lets through), and the function's exit code (127 when bash itself cannot be started).
type seamAnswer struct {
	out    string
	stderr string
	rc     int
}

func (a adapters) call(script string, args ...string) seamAnswer {
	var out, errb bytes.Buffer
	c := exec.Command(a.bash, append([]string{"-c", seamPrelude + script, "bash", a.file}, args...)...)
	c.Env, c.Dir, c.Stdout, c.Stderr = a.env, a.dir, &out, &errb
	rc := 0
	if err := c.Run(); err != nil {
		var ee *exec.ExitError
		if errors.As(err, &ee) {
			rc = ee.ExitCode()
		} else {
			rc = 127
		}
	}
	return seamAnswer{strings.TrimRight(out.String(), "\n"), errb.String(), rc}
}

// loaded is what sourcing adapters.sh defines that the commands need.
type loaded struct {
	harnesses  []string // RESEARCH_SDD_HARNESSES, word-split like `for h in $RESEARCH_SDD_HARNESSES`
	defined    bool     // RESEARCH_SDD_HARNESSES is set
	hasProfile bool     // rsdd_resolve_profile and rsdd_valid_profile both exist (kit issue #993 WU2)
	stderr     string   // what sourcing printed
}

// load sources adapters.sh once. Unlike the per-query calls it keeps the file's own stderr, because the script prints it once.
func (a adapters) load() loaded {
	var out, errb bytes.Buffer
	const script = `set -uo pipefail; . "$1"
if [ "${RESEARCH_SDD_HARNESSES+x}" ]; then printf 'set\0%s\0' "$RESEARCH_SDD_HARNESSES"; else printf 'unset\0\0'; fi
if declare -F rsdd_resolve_profile >/dev/null 2>&1 && declare -F rsdd_valid_profile >/dev/null 2>&1; then printf 'profile\0'; else printf 'noprofile\0'; fi`
	c := exec.Command(a.bash, "-c", script, "bash", a.file)
	c.Env, c.Dir, c.Stdout, c.Stderr = a.env, a.dir, &out, &errb
	_ = c.Run() // the script ignores a failing source and goes on; so does this
	parts := strings.Split(out.String(), "\x00")
	l := loaded{stderr: errb.String()}
	if len(parts) >= 3 {
		l.defined = parts[0] == "set"
		l.harnesses = strings.Fields(parts[1])
		l.hasProfile = parts[2] == "profile"
	}
	return l
}

// field is `rsdd_field <harness> <field> <home>`.
func (a adapters) field(errw io.Writer, harness, field, home string) seamAnswer {
	r := a.call(`rsdd_field "$@"`, harness, field, home)
	io.WriteString(errw, r.stderr) //nolint:errcheck // diagnostics
	return r
}

// resolveProfile is `rsdd_resolve_profile <harness> <flag>`: "<profile>:<source>".
func (a adapters) resolveProfile(errw io.Writer, harness, flag string) seamAnswer {
	r := a.call(`rsdd_resolve_profile "$@"`, harness, flag)
	io.WriteString(errw, r.stderr) //nolint:errcheck // diagnostics
	return r
}

// validProfile is `rsdd_valid_profile <profile> <kit>`.
func (a adapters) validProfile(profile, kit string) bool {
	return a.call(`rsdd_valid_profile "$@"`, profile, kit).rc == 0
}
