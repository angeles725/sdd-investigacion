package parity

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// fakeScript stands in for BOTH a legacy kit script and the rsdd binary: its
// behaviour is chosen by its arguments, so the self-tests never touch the real
// kit scripts.
const fakeScript = `#!/bin/sh
code=0
for a in "$@"; do
  case "$a" in
    out=*) printf '%s' "${a#out=}" ;;
    err=*) printf '%s' "${a#err=}" >&2 ;;
    exit=*) code="${a#exit=}" ;;
    touch=*) printf 'x' >> "${a#touch=}" ;;
    sleep=*) sleep "${a#sleep=}" ;;
    exists=*) if [ -e "${a#exists=}" ]; then printf 'yes'; else printf 'no'; fi ;;
    catf=*) cat "${a#catf=}" ;;
    env=*) eval "printf '%s' \"\${${a#env=}}\"" ;;
    put=*) v="${a#put=}"; printf '%s' "${v#*|}" > "${v%%|*}" ;;
    chmod=*) v="${a#chmod=}"; chmod "${v%%|*}" "${v#*|}" ;;
    ln=*) v="${a#ln=}"; ln -s "${v%%|*}" "${v#*|}" ;;
    rm=*) rm -rf "${a#rm=}" ;;
    rl=*) readlink "${a#rl=}" ;;
    ctx) pwd; printf '%s\n%s\n' "$HOME" "$TMPDIR" ;;
    cat) cat ;;
  esac
done
exit "$code"
`

// rig is a fake legacy kit + fake binary + work dir + spec dir.
type rig struct {
	t      *testing.T
	root   string // legacy kit root
	bin    string
	work   string
	specs  string
	runner *Runner
}

func needSh(t *testing.T) {
	t.Helper()
	if _, err := exec.LookPath("sh"); err != nil {
		t.Skip("sh not available: the parity self-tests drive fake shell scripts")
	}
}

func newRig(t *testing.T) *rig {
	t.Helper()
	needSh(t)
	base := t.TempDir()
	r := &rig{t: t, root: filepath.Join(base, "kit"), bin: filepath.Join(base, "rsdd-fake"), work: filepath.Join(base, "work"), specs: filepath.Join(base, "specs")}
	for _, d := range []string{filepath.Join(r.root, "toolbelt"), r.work, r.specs} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	for _, p := range []string{filepath.Join(r.root, "toolbelt", "fake.sh"), r.bin} {
		if err := os.WriteFile(p, []byte(fakeScript), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	rn, err := NewRunner(Config{LegacyRoot: r.root, Bin: r.bin, Work: r.work, Timeout: 10 * time.Second})
	if err != nil {
		t.Fatal(err)
	}
	r.runner = rn
	return r
}

// addCase writes a case dir. legacy and rsdd are the fake's arguments.
func (r *rig) addCase(name string, legacy, rsdd []string, corpus bool, files map[string]string) {
	r.t.Helper()
	spec := map[string]any{
		"legacy": append([]string{"toolbelt/fake.sh"}, legacy...),
		"rsdd":   rsdd,
	}
	if corpus {
		spec["corpus"] = true
	}
	b, err := json.Marshal(spec)
	if err != nil {
		r.t.Fatal(err)
	}
	r.addRaw(name, string(b), files)
}

func (r *rig) addRaw(name, specJSON string, files map[string]string) {
	r.t.Helper()
	dir := filepath.Join(r.specs, name)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		r.t.Fatal(err)
	}
	if specJSON != "" {
		files["spec.json"] = specJSON
	}
	for rel, body := range files {
		p := filepath.Join(dir, rel)
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			r.t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
			r.t.Fatal(err)
		}
	}
}

func (r *rig) load() []Case {
	r.t.Helper()
	cases, err := LoadCases(r.specs)
	if err != nil {
		r.t.Fatal(err)
	}
	return cases
}

// run adds one case and runs it once, with no corpus.
func (r *rig) run(legacy, rsdd []string, files map[string]string) (Result, Case) {
	r.t.Helper()
	if files == nil {
		files = map[string]string{}
	}
	r.addCase("c", legacy, rsdd, false, files)
	c := r.load()[0]
	return r.runner.RunCase(c, ""), c
}

func firstProblems(t *testing.T, rep Report) []Problem {
	t.Helper()
	if len(rep.Results) == 0 {
		t.Fatalf("report has no results: %s", rep.Summary())
	}
	return rep.Results[0].Problems
}

func lastProblems(t *testing.T, rep Report) []Problem {
	t.Helper()
	if len(rep.Results) == 0 {
		t.Fatalf("report has no results: %s", rep.Summary())
	}
	return rep.Results[len(rep.Results)-1].Problems
}

func hasKind(probs []Problem, kind string) bool {
	for _, p := range probs {
		if p.Kind == kind {
			return true
		}
	}
	return false
}

func joined(probs []Problem) string {
	var s []string
	for _, p := range probs {
		s = append(s, p.String())
	}
	return strings.Join(s, "\n")
}
