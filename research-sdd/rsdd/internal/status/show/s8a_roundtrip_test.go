//go:build unix && !nodiff

package show

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// The S8a round trip: `rsdd status show --sync-state` writes an envelope and `rsdd verify state` must accept (or
// keep rejecting) what was written. The bash suites asserted this against tools/verify-state.sh; the Go side runs
// the BUILT binary end to end (s4Stage builds ./cmd/rsdd once per test binary into a directory outside the worktree,
// or uses $RSDD_BIN), because this package must not import internal/verify (a domain never imports a domain).
// Case ids name the bash case: <suite line> and the bash label.

type rtFile struct{ rel, body string }

type rtRun struct {
	focus string // "" runs the target directly; otherwise `--focus <focus>`
	dir   string // the directory handed to status show, relative to the world
}

type rtCase struct {
	id     string
	files  []rtFile
	late   []rtFile // created after the first sync (the scope guard refuses a second state file)
	syncs  []rtRun
	verify string                                 // the directory verify-state checks, relative to the world
	check  func(t *testing.T, w rtWorld, vs rtVS) // extra assertions on top of "verify exits 0 without FAIL"
	wantRC int                                    // the verify-state exit code the bash case expected
}

type rtVS struct {
	out string
	rc  int
}

type rtWorld struct{ root string }

func (w rtWorld) env(t *testing.T, rel, key string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(w.root, rel))
	if err != nil {
		t.Fatal(err)
	}
	in := false
	for _, l := range strings.Split(string(b), "\n") {
		switch {
		case strings.Contains(l, "<!-- research-state.v1 -->"):
			in = true
		case strings.Contains(l, "<!-- /research-state.v1 -->"):
			in = false
		case in && strings.HasPrefix(l, key+":"):
			return strings.TrimSpace(strings.TrimPrefix(l, key+":"))
		}
	}
	return ""
}

func rtExec(t *testing.T, dir string, args ...string) (string, string, int) {
	t.Helper()
	cmd := exec.Command(s4Bin, args...)
	cmd.Dir = dir
	cmd.Env = append(os.Environ(), "RSDD_STATUS_NO_CLEAN_CHECK=1")
	var o, e bytes.Buffer
	cmd.Stdout, cmd.Stderr = &o, &e
	rc := 0
	if err := cmd.Run(); err != nil {
		ee, ok := err.(*exec.ExitError)
		if !ok {
			t.Fatalf("%v", err)
		}
		rc = ee.ExitCode()
	}
	return o.String(), e.String(), rc
}

func rtBuild(t *testing.T, fs []rtFile) rtWorld {
	t.Helper()
	w := rtWorld{t.TempDir()}
	rtAdd(t, w, fs)
	return w
}

func rtAdd(t *testing.T, w rtWorld, fs []rtFile) {
	t.Helper()
	root := w.root
	for _, f := range fs {
		p := filepath.Join(root, f.rel)
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(f.body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
}

func envBlock(lines ...string) string {
	return "<!-- research-state.v1 -->\nschema: research-state.v1\n" + strings.Join(lines, "\n") + "\n<!-- /research-state.v1 -->\n"
}

func bareState(name, rows, stop string) string {
	return "# " + name + "\n> intro\n## Gap-backlog (prioritized)\n| Priority | Gap | Artifact type / source | Status |\n|---|---|---|---|\n" + rows +
		"## Blocked gaps\n## Stop control\n- **Open gaps — read-only investigable**: " + stop + "\n"
}

const sgHead = "gaps_closed: 0\nknown_gaps: 0\ninvestigable_open: 0\nrequires_execution_open: 0\nblocked_open: 0\ndeferred_open: 0\nundocumented_findings: 0\nblock_scope: shared-global\n"

func sgState(title, cb, covered string) string {
	return "# " + title + "\n> intro\n<!-- research-state.v1 -->\nschema: research-state.v1\ncovered_blocks: " + cb + "\n" + sgHead +
		"<!-- /research-state.v1 -->\n" + covered + "\n## Gap-backlog (prioritized)\n| P | G | t | S |\n|---|---|---|---|\n\n## Blocked gaps\n## Stop control\n- **Open gaps — read-only investigable**: 0\n"
}

func rtBlocks(prefix string, n int) []rtFile {
	var fs []rtFile
	for i := 1; i <= n; i++ {
		fs = append(fs, rtFile{fmt.Sprintf("%s%d.md", prefix, i), "x\n"})
	}
	return fs
}

func rtCases() []rtCase {
	var cs []rtCase
	cs = append(cs, rtCase{
		id:    "L617-sync-seeds-a-contract-valid-envelope",
		files: []rtFile{{"RESEARCH-STATE.md", "# T — Research State\n\n> intro blockquote\n\n## Coverage\n- **Coverage metric**: 4 / 9 closed\n\n## Gap-backlog\n| P | G | t | S |\n|-|-|-|-|\n| high | open one | web | pending |\n| medium | blocked one | web | pending |\n\n## Blocked gaps\n- blocked one — needs: hardware\n\n## Stop control\n- **Open gaps — read-only investigable**: 1\n- **Open gaps — requires-execution**: 2\n"}},
		syncs: []rtRun{{}}, verify: ".",
		check: func(t *testing.T, w rtWorld, _ rtVS) {
			if got := w.env(t, "RESEARCH-STATE.md", "investigable_open"); got != "1" {
				t.Errorf("investigable_open = %q, want 1 (blocked gap excluded)", got)
			}
		},
	})
	alpha := bareState("Alpha — Research State", "| high | a1 | web | pending |\n| high | a2 | web | pending |\n", "2")
	beta := bareState("Beta — Research State", "| high | b1 | doc | done |\n", "0")
	cs = append(cs, rtCase{
		id:    "L679-multi-focus-both-seeded-per-focus-investigable-open",
		files: []rtFile{{"RESEARCH-STATE-alpha.md", alpha}, {"RESEARCH-STATE-beta.md", beta}},
		syncs: []rtRun{{focus: "alpha"}, {focus: "beta"}}, verify: ".",
		check: func(t *testing.T, w rtWorld, _ rtVS) {
			if a, b := w.env(t, "RESEARCH-STATE-alpha.md", "investigable_open"), w.env(t, "RESEARCH-STATE-beta.md", "investigable_open"); a != "2" || b != "0" {
				t.Errorf("investigable_open alpha=%s beta=%s, want 2 and 0", a, b)
			}
			for _, f := range []string{"RESEARCH-STATE-alpha.md", "RESEARCH-STATE-beta.md"} {
				b, _ := os.ReadFile(filepath.Join(w.root, f))
				if n := strings.Count(string(b), "<!-- research-state.v1 -->"); n != 1 {
					t.Errorf("%s holds %d fences, want 1", f, n)
				}
			}
		},
	})
	cs = append(cs, rtCase{
		id:    "L717-per-dir-covered-blocks-root-2-subdir-focus-1",
		files: append([]rtFile{{"RESEARCH-STATE.md", "# root\n> x\n## Gap-backlog\n## Blocked gaps\n## Stop control\n- **Open gaps — read-only investigable**: 0\n"}}, rtBlocks("proj-block", 2)...),
		late:  []rtFile{{"legacy/RESEARCH-STATE-legacy.md", "# legacy\n> x\n## Gap-backlog\n## Blocked gaps\n## Stop control\n- **Open gaps — read-only investigable**: 0\n"}, {"legacy/legacy-block1.md", "x\n"}},
		syncs: []rtRun{{dir: "."}, {dir: "legacy"}}, verify: ".",
		check: func(t *testing.T, w rtWorld, _ rtVS) {
			if r, l := w.env(t, "RESEARCH-STATE.md", "covered_blocks"), w.env(t, "legacy/RESEARCH-STATE-legacy.md", "covered_blocks"); r != "2" || l != "1" {
				t.Errorf("covered_blocks root=%s legacy=%s, want 2 and 1", r, l)
			}
		},
	})
	cs = append(cs, rtCase{
		id:    "L749-backlog-anchored-envelope-passes-verify-state",
		files: []rtFile{{"RESEARCH-STATE.md", "# T — Research State\n\n> intro\n\n## Coverage\n- **Coverage metric**: 40 / 40 closed\n\n## Gap-backlog (prioritized)\n| Priority | Gap | type | Status |\n|---|---|---|---|\n| high | G41 — equipment LOD | prototype build | requires-execution → §19 (not read-only; needs a build + re-measure) |\n\n## Blocked gaps\n\n## Stop control\n- **Open gaps — read-only investigable**: 0\n- **Open gaps — requires-execution**: 0\n"}},
		syncs: []rtRun{{}}, verify: ".",
		check: func(t *testing.T, w rtWorld, _ rtVS) {
			if got := w.env(t, "RESEARCH-STATE.md", "requires_execution_open"); got != "1" {
				t.Errorf("requires_execution_open = %q, want 1 (stale prose 0 overridden)", got)
			}
		},
	})
	cs = append(cs, rtCase{
		id: "L793-B5-MF1-per-focus-covered-blocks-verify-passes",
		files: append(append(rtBlocks("alpha-block", 2), rtBlocks("beta-block", 3)...),
			rtFile{"RESEARCH-STATE-alpha.md", bareState("Alpha", "", "0")}, rtFile{"RESEARCH-STATE-beta.md", bareState("Beta", "", "0")}),
		syncs: []rtRun{{focus: "alpha"}, {focus: "beta"}}, verify: ".",
		check: func(t *testing.T, w rtWorld, _ rtVS) {
			if a, b := w.env(t, "RESEARCH-STATE-alpha.md", "covered_blocks"), w.env(t, "RESEARCH-STATE-beta.md", "covered_blocks"); a != "2" || b != "3" {
				t.Errorf("covered_blocks alpha=%s beta=%s, want 2 and 3 (not the combined 5)", a, b)
			}
		},
	})
	cs = append(cs, rtCase{
		id:    "L1035-sync-bs-e2e-unverifiable-info-and-exit-0",
		files: append(rtBlocks("niagara-bloque", 3), rtFile{"RESEARCH-STATE-chihuahua.md", sgState("C", "3", "")}),
		syncs: []rtRun{{}}, verify: ".",
		check: func(t *testing.T, w rtWorld, vs rtVS) {
			if got := w.env(t, "RESEARCH-STATE-chihuahua.md", "covered_blocks"); got != "0" {
				t.Errorf("covered_blocks = %q, want 0 (unverifiable)", got)
			}
			if !strings.Contains(vs.out, "covered_blocks=0/") {
				t.Errorf("verify-state envelope line lacks covered_blocks=0/<ondisk>:\n%s", vs.out)
			}
			if !regexp.MustCompile(`(?m)^ +INFO +covered_blocks unverifiable under shared-global: no attributed block ids listed`).MatchString(vs.out) {
				t.Errorf("verify-state lacks the scoped unverifiable INFO line:\n%s", vs.out)
			}
		},
	})
	attr := func(id string, cb, covered string, n int, wantCB string) rtCase {
		return rtCase{
			id:    id,
			files: append(rtBlocks("focus-bloque", n), rtFile{"RESEARCH-STATE-focus.md", sgState("T"+id, cb, covered)}),
			syncs: []rtRun{{}}, verify: ".",
			check: func(t *testing.T, w rtWorld, vs rtVS) {
				if got := w.env(t, "RESEARCH-STATE-focus.md", "covered_blocks"); got != wantCB {
					t.Errorf("covered_blocks = %q, want %s (attributed ids, not the corpus-wide file count)", got, wantCB)
				}
				if !regexp.MustCompile(`envelope +: covered_blocks=` + wantCB + `/`).MatchString(vs.out) {
					t.Errorf("no positive evidence: envelope line lacks covered_blocks=%s/:\n%s", wantCB, vs.out)
				}
				if !regexp.MustCompile(`(?m)^ +ok +envelope validated`).MatchString(vs.out) {
					t.Errorf("no 'ok envelope validated' line:\n%s", vs.out)
				}
				if regexp.MustCompile(`INFO +covered_blocks unverifiable`).MatchString(vs.out) {
					t.Errorf("an attributed run printed the unverifiable INFO:\n%s", vs.out)
				}
			},
		}
	}
	cs = append(cs,
		attr("L1084-T905-SG-ATTR-two-attributed-of-five", "99", "\n## Covered blocks\nB1, B2\n", 5, "2"),
		attr("L1740-T530-shared-global-three-attributed-of-five", "3", "\n## Covered blocks\nB1, B2, B3\n", 5, "3"),
	)
	cs = append(cs, rtCase{
		id: "L1127-T56-refused-sync-verify-state-still-fails",
		files: []rtFile{{"RESEARCH-STATE.md", "# T — Research State\n\n" +
			envBlock("covered_blocks: 0", "gaps_closed: 0", "known_gaps: 1", "investigable_open: 1", "requires_execution_open: 0", "blocked_open: 0") +
			"\n## Gap-backlog (prioritized)\n\n| Priority | Gap | Artifact type / source | Status |\n|---|---|---|---|\n| critical | firmware parsing | web | pending |\n\n## Blocked gaps\n- none\n\n## Stop control\n- **Open gaps — read-only investigable**: 1\n"}},
		syncs: []rtRun{{}}, verify: ".", wantRC: 1,
		check: func(t *testing.T, w rtWorld, vs rtVS) {
			if !strings.Contains(vs.out, "FAIL") {
				t.Errorf("verify-state exit %d without a FAIL line:\n%s", vs.rc, vs.out)
			}
			if got := w.env(t, "RESEARCH-STATE.md", "investigable_open"); got != "1" {
				t.Errorf("investigable_open = %q, want 1 (the refused sync must not launder it)", got)
			}
		},
	})
	return cs
}

func TestRoundTripSyncStateVerifyState(t *testing.T) {
	s4Stage(t)
	for _, c := range rtCases() {
		t.Run(c.id, func(t *testing.T) {
			w := rtBuild(t, c.files)
			for i, r := range c.syncs {
				if i == 1 {
					rtAdd(t, w, c.late)
				}
				dir := filepath.Join(w.root, r.dir)
				args := []string{"status", "show", dir, "--sync-state"}
				if r.focus != "" {
					args = append(args, "--focus", r.focus)
				}
				rtExec(t, w.root, args...)
			}
			o, e, rc := rtExec(t, w.root, "verify", "state", filepath.Join(w.root, c.verify))
			vs := rtVS{o + e, rc}
			if rc != c.wantRC {
				t.Errorf("verify state exit %d, want %d:\n%s", rc, c.wantRC, vs.out)
			}
			if c.wantRC == 0 && strings.Contains(vs.out, "FAIL") {
				t.Errorf("verify state FAILs what --sync-state just wrote:\n%s", vs.out)
			}
			c.check(t, w, vs)
		})
	}
}

// The verify-state-inplace-blocked round trip (suite case 6.n): a fresh --sync-state, then verify-state, must not
// report a stale denominator for the three in-place blocked shapes.
func TestRoundTripInPlaceBlocked(t *testing.T) {
	s4Stage(t)
	const (
		pend    = "| high | live gap | web | pending |"
		done    = "| low | done gap | web | ✅ covered |"
		b1      = "| medium | blk-first | web | blocked (requires-hardware) |"
		b2      = "| low | blk-mid | web | blocked-on-tool: needs a decompiler |"
		b3      = "| low | blk-last | web | blocked |"
		bstruck = "| low | ~~blk-struck~~ | web | blocked (requires-x) |"
		bclosed = "| low | blk-closed | web | blocked ✅ closed |"
	)
	for name, rows := range map[string][]string{
		"rt1-single":            {pend, done, b1},
		"rt2-first-middle-last": {b1, pend, b2, done, b3},
		"rt3-struck-and-closed": {pend, bstruck, bclosed, done},
	} {
		t.Run(name, func(t *testing.T) {
			body := "# T — Research State\n\n<!-- research-state.v1 -->\nschema: research-state.v1\ncovered_blocks: 0\ngaps_closed: 0\nknown_gaps: 0\ninvestigable_open: 0\nrequires_execution_open: 0\nblocked_open: 0\ndeferred_open: 0\n<!-- /research-state.v1 -->\n\n## Gap-backlog (prioritized)\n\n| Priority | Gap | Artifact type / source | Status |\n|---|---|---|---|\n" +
				strings.Join(rows, "\n") + "\n\n## Stop control\n\n"
			w := rtBuild(t, []rtFile{{"RESEARCH-STATE.md", body}})
			rtExec(t, w.root, "status", "show", w.root, "--sync-state")
			o, e, _ := rtExec(t, w.root, "verify", "state", w.root)
			if out := o + e; regexp.MustCompile(`WARN.*sum of declared counters.*stale denominator`).MatchString(out) {
				t.Errorf("verify-state disagrees with a fresh --sync-state:\n%s", out)
			}
		})
	}
}
