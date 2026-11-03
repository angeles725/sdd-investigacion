package stageissues

import (
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/kitroot"
)

// allCases is the scenario table shared by the differential and the golden test. The groups live in cases_*.go.
func allCases() []dcase {
	var all []dcase
	for _, g := range [][]dcase{casesInput(), casesStatus(), casesForms(), casesTitles(), casesRepo(), casesApply(), casesOccurrence(), casesTracker(), casesScrub(), casesCounter(), casesJSON(), casesScrubMore()} {
		all = append(all, g...)
	}
	sort.SliceStable(all, func(i, j int) bool { return all[i].name < all[j].name })
	return all
}

var utf8Once struct {
	sync.Once
	ok bool
}

// resolve skips a case whose locale this host's bash does not provide (a bash that silently falls back to the C
// locale would make the legacy side count bytes where the case asks for characters).
func (c dcase) resolve(t *testing.T) dcase {
	t.Helper()
	if c.locale == "C.UTF-8" {
		utf8Once.Do(func() {
			bash, err := exec.LookPath("bash")
			if err != nil {
				return
			}
			cmd := exec.Command(bash, "-c", "x=$(printf '\\303\\251'); echo ${#x}")
			cmd.Env = []string{"LC_ALL=C.UTF-8"}
			out, _ := cmd.Output()
			utf8Once.ok = strings.TrimSpace(string(out)) == "1"
		})
		if !utf8Once.ok {
			t.Skip("the C.UTF-8 locale is not available to bash on this host")
		}
	}
	return c
}

// ---------------------------------------------------------------------------------------------- builders

const (
	tblHdr  = "| # | Proposed change | Target (file) | Evidence | Type | Priority |\n|---|---|---|---|---|---|\n"
	pending = "<!-- review-status: pending -->"
	applied = "<!-- review-status: applied · abc123 -->"
)

// doc builds a retro like the old suite's mk_retro: marker line (omitted when empty), H1, the canonical heading
// and the standard table with the given rows.
func doc(marker string, rows ...string) string {
	var b strings.Builder
	if marker != "" {
		b.WriteString(marker + "\n")
	}
	b.WriteString("# retro\n\n## Proposed kit deltas\n\n" + tblHdr)
	for _, r := range rows {
		b.WriteString(r + "\n")
	}
	return b.String()
}

func row(id, change, target, evidence, typ, prio string) string {
	return "| " + strings.Join([]string{id, change, target, evidence, typ, prio}, " | ") + " |"
}

// dry is a default dry-run case over a retro text.
func dry(name, retro string) dcase { return dcase{name: name, retro: retro} }

// withArgs / withEnv / withStub return a modified copy.
func (c dcase) withArgs(a ...string) dcase { c.args = a; return c }

func (c dcase) withEnv(kv ...string) dcase {
	m := map[string]string{}
	for k, v := range c.env {
		m[k] = v
	}
	for i := 0; i+1 < len(kv); i += 2 {
		m[kv[i]] = kv[i+1]
	}
	c.env = m
	return c
}

// fixtureDir holds the retro fixtures the old suite and its sibling suites share.
var fixtureDir = kitroot.Must() + "/toolbelt/tests/fixtures/stage-retro-issues"

func fixture(t testing.TB, name string) string {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(fixtureDir, name))
	if err != nil {
		t.Fatalf("fixture %s: %v (a moved fixture dir must update fixtureDir, not skip)", name, err)
	}
	return string(data)
}
