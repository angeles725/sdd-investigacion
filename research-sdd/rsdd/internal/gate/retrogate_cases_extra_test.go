package gate

import (
	"fmt"
	"os"
	"strings"
	"testing"
	"time"
)

func init() {
	rgCases = append(rgCases,
		rgCase{id: "SEEDABLE-shapes", // which retros under the target reach the seeder (T-SEEDABLE-1..7, end to end)
			setup: func(w *rgWorld) []rgRun {
				x := seedWorld(w, "printf '%s\\n' \"$*\" >> \"$SEED_LOG\"\necho 'summary: created=0 skipped-duplicate=0'\n")
				for name, body := range map[string]string{
					"a-shipped.md":        "<!-- review-status: applied · abc1234 · shipped: row 1 -->\n# Retro\n",
					"b-dismissed.md":      "<!-- review-status: dismissed -->\n# Retro\n",
					"c-applied-h1.md":     "# Retro\n\n<!-- review-status: applied -->\n",
					"d-late-dismissed.md": "# Retro\n\n## Next\n\n<!-- review-status: dismissed -->\n",
					"e-nomarker.md":       "# Retro\nbody\n",
					"f-late-applied.md":   "# Retro\n\n## Next\n\n<!-- review-status: applied -->\n",
					"g-no-newline.md":     "# Retro\n\n## Next\n<!-- review-status: dismissed -->",
					"h-excluded.md":       "<!-- kit-retro: exclude -->\n# Not a kit retro\n",
					"INDEX-retros.md":     "# index\n",
					"notes.txt":           "x\n",
				} {
					// older than the session start: they are never "the newest retro", only seeding candidates
					w.touch(w.write0(x.target+"/retros/"+name, body), "202609040000")
				}
				return one(x)
			},
			check: func(t *testing.T, rs []*rgRes) {
				got := map[string]bool{}
				for _, l := range rs[0].seeded {
					got[l[strings.LastIndex(l, "/")+1:]] = true
				}
				want := map[string]bool{"a-shipped.md --apply": true, "e-nomarker.md --apply": true, rgSeedRetro + " --apply": true}
				if fmt.Sprint(got) != fmt.Sprint(want) {
					t.Errorf("seeded %v, want %v", got, want)
				}
				for _, late := range []string{"d-late-dismissed.md", "f-late-applied.md", "g-no-newline.md"} {
					has(t, late, rs[0].err, "retro-gate: WARN: out-of-scope-marker: "+late+" — a review-status marker exists but sits outside the leading-block scope; refusing to seed (kit issue #1099)\n")
				}
				has(t, "count", rs[0].err, "ran=3 ")
			}},
		rgCase{id: "degraded-ties", // equal mtimes: the first retro in directory order wins, as find printed them
			setup: func(w *rgWorld) []rgRun {
				d := w.root + "/t"
				w.touch(w.write0(d+"/niagara-block1.md", "# b\n"), "202609051000")
				for _, n := range []string{"r1", "r2", "r3", "r4", "r5", "r6"} {
					w.touch(w.retro(d, "2026-09-05-"+n+".md", n < "r4"), "202609051200")
				}
				return one(gate(d, "nosess"))
			},
			check: func(t *testing.T, rs []*rgRes) {
				has(t, "stderr", rs[0].err, "retro=2026-09-05-r")
			}},
		rgCase{id: "retro-depth", // the degraded find stops at depth 4; the session-sha scan is unbounded
			setup: func(w *rgWorld) []rgRun {
				d := w.std("t", "s")
				w.touch(w.retro(d+"/a/b/c/d/e", "2026-09-05-deep.md", true), "202609051200")
				e := w.root + "/e"
				w.touch(w.write0(e+"/niagara-block1.md", "# b\n"), "202609051000")
				w.touch(w.retro(e+"/a/b/c/d/e", "2026-09-05-deep.md", true), "202609051200")
				return []rgRun{gate(d, "s"), gate(e, "nosess")}
			},
			check: func(t *testing.T, rs []*rgRes) {
				if rs[0].out != "" {
					t.Errorf("an untracked deep retro qualifies under a session sha: %q", rs[0].out)
				}
				wantBlocked(t, rs[1:])
			}},
	)
}

// TestRetroUntrackedScanDoesNotFork pins #2168: the scan over `git ls-files --others` (ignored files included) used
// to fork a grep and a basename per path, which took over 300 s on a large corpus. Twenty thousand untracked paths
// must be scanned in well under the seconds a fork per path would need, with the same retros qualifying.
func TestRetroUntrackedScanDoesNotFork(t *testing.T) {
	if testing.Short() {
		t.Skip("builds a large tree")
	}
	w := newRGWorld(t, false)
	d := w.std("t", "s")
	for i := 0; i < 20000; i++ {
		p := fmt.Sprintf("%s/data/d%d/f%d.txt", d, i%200, i)
		if i%200 == 0 {
			must(t, os.MkdirAll(fmt.Sprintf("%s/data/d%d", d, i%200), 0o755))
		}
		if err := os.WriteFile(p, nil, 0o644); err != nil {
			must(t, os.MkdirAll(fmt.Sprintf("%s/data/d%d", d, i%200), 0o755))
			must(t, os.WriteFile(p, nil, 0o644))
		}
	}
	w.touch(w.retro(d, "2026-09-05-new.md", true), "202609051200")
	start := time.Now()
	r := w.runGo(gate(d, "s"))
	took := time.Since(start)
	if r.out != "" || !strings.Contains(r.err, "branch=retro-conforming retro=2026-09-05-new.md") {
		t.Errorf("verdict changed: out=%q err=%s", r.out, r.err)
	}
	if took > 15*time.Second {
		t.Errorf("scanning 20000 untracked paths took %v: a process per path again?", took)
	}
}
