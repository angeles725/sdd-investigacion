//go:build unix && !nodiff

package show

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
)

// The S2 differential: the frozen excerpts of research-sdd-status.sh (testdata/legacy, see SOURCE.txt) are sourced
// into one bash process per scenario, over the LIVE lib/blocked-rows.sh and lib/focus-prefix.sh, and every op of the
// scenario runs in its own subshell. The outputs must equal the Go port's and are the golden of the replay test.

var s2Frozen = []struct{ file, sha string }{
	{"status-section.sh", "f8147b3058c98ef4c3a681bd17118c3bd28c78fb05728171c2c2648c0ba4295e"},
	{"status-blocked.sh", blockedSHA},
	{"status-scan.sh", "0ecc9f372f6887c5ba761f8cb1be8467e655ca5e39a16cf03d01e5d05773b243"},
	{"status-counters.sh", "f99d0a0f98bf3933deb4330fd033e632d5589c633c8b1a4a4243232a1aededaa"},
	{"status-focuses.sh", "96fdab930a06add9a5b4a16bb8f6ae06c5f698b79ad89b8751175a328512b1eb"},
}

// s2Harness sources the live libraries and the frozen excerpts, defines the two authored helpers (the in-place
// pipeline of --sync-state and a double cached read), then runs each op line in a subshell.
const s2Harness = `set -uo pipefail
state="$1"; opsf="$2"; outd="$3"
target="$(dirname "$state")"; corpus="$target"
. "$LIBDIR/blocked-rows.sh"
. "$LIBDIR/focus-prefix.sh"
blocked_body() { blocked_rows_body "$state"; }
for f in $FROZEN; do . "$f"; done
__inplace() { backlog_rows 2>/dev/null | inplace_blocked_count "$(blocked_body)"; }
__into_twice() { local v w; _read_focuses_tok_into v "$1" "$2"; _read_focuses_tok_into w "$1" "$2"; printf 'v=%s w=%s\n' "$v" "$w"; }
i=0
while IFS= read -r line; do
  ( eval "$line" ) >"$outd/$i.out" 2>"$outd/$i.err" </dev/null
  echo $? >"$outd/$i.rc"
  i=$((i+1))
done <"$opsf"
`

var (
	s2Once   sync.Once
	s2Dir    string
	s2Script string
	s2Files  []string
	s2Err    error
)

func s2Stage(t testing.TB) {
	t.Helper()
	s2Once.Do(func() {
		s2Dir, s2Err = os.MkdirTemp("", "status-show-s2-")
		if s2Err != nil {
			return
		}
		for _, f := range s2Frozen {
			b := readFrozen(t, f.file, f.sha)
			p := filepath.Join(s2Dir, f.file)
			if s2Err = os.WriteFile(p, b, 0o644); s2Err != nil {
				return
			}
			s2Files = append(s2Files, p)
		}
		s2Script = filepath.Join(s2Dir, "harness.sh")
		s2Err = os.WriteFile(s2Script, []byte(s2Harness), 0o644)
	})
	if s2Err != nil {
		t.Fatalf("staging the S2 oracle: %v", s2Err)
	}
}

func runS2Bash(t testing.TB, sc s2Scenario, root string) []outcome {
	t.Helper()
	s2Stage(t)
	work := t.TempDir()
	var lines []string
	for _, op := range sc.ops {
		lines = append(lines, op.line(root))
	}
	opsf := filepath.Join(work, "ops")
	must(t, os.WriteFile(opsf, []byte(strings.Join(lines, "\n")+"\n"), 0o644))
	outd := filepath.Join(work, "out")
	must(t, os.MkdirAll(outd, 0o755))
	lib, err := filepath.Abs(liveLib)
	must(t, err)
	cmd := exec.Command("bash", s2Script, filepath.Join(root, stateRel), opsf, outd)
	cmd.Dir = root
	cmd.Env = bashEnv(root, map[string]string{"LIBDIR": lib, "FROZEN": strings.Join(s2Files, " ")})
	var e bytes.Buffer
	cmd.Stderr = &e
	if err := cmd.Run(); err != nil {
		t.Fatalf("harness: %v\n%s", err, e.String())
	}
	var res []outcome
	for i := range sc.ops {
		rd := func(ext string) string {
			b, err := os.ReadFile(filepath.Join(outd, strconv.Itoa(i)+ext))
			must(t, err)
			return string(b)
		}
		rc, err := strconv.Atoi(strings.TrimSpace(rd(".rc")))
		must(t, err)
		res = append(res, outcome{rc, rd(".out"), dropAwk(rd(".err"))})
	}
	return res
}

func TestDifferentialS2(t *testing.T) {
	var mu sync.Mutex
	sections := map[string]string{}
	t.Run("scenarios", func(t *testing.T) {
		for _, sc := range s2Scenarios() {
			t.Run(sc.name, func(t *testing.T) {
				t.Parallel() // the frozen script runs concurrently; the Go side swaps no seam here
				if sc.unreadable && os.Geteuid() == 0 {
					t.Skip("mode-000 files are readable by root")
				}
				root := sc.build(t)
				goOuts := runGoOps(t, sc, root)
				bashOuts := runS2Bash(t, sc, root)
				for i, op := range sc.ops {
					if goOuts[i] != bashOuts[i] {
						t.Errorf("op %s differs from the frozen script\ngo   rc=%d\nstdout:\n%s\nstderr:\n%s\nbash rc=%d\nstdout:\n%s\nstderr:\n%s",
							op.line(root), goOuts[i].rc, goOuts[i].out, goOuts[i].err, bashOuts[i].rc, bashOuts[i].out, bashOuts[i].err)
					}
				}
				mu.Lock()
				sections[sc.name] = renderS2(sc, bashOuts, root)
				mu.Unlock()
			})
		}
	})
	if t.Failed() && !*update {
		return
	}
	for _, sc := range s2Scenarios() {
		if _, ok := sections[sc.name]; !ok && !*update {
			if old, ok := parseGoldenIfPresent(t, goldenS2)[sc.name]; ok {
				sections[sc.name] = old
			}
		}
	}
	checkGolden(t, goldenS2, sections)
}
