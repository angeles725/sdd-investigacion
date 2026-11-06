package budget

import (
	"bufio"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strconv"
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/kitroot"
)

// The gate of kit issue #2756: the mixed worst case of the repo's registered SessionStart hooks stays under the
// budget. It is calibrated on a FROZEN fixture of per-hook normal sizes (testdata/session-normal-2026-11-06.txt),
// never on a live run, so a hook added later that pushes the mixed case over budget fails here, and a hook added
// without a reading fails the registration check below.
const normalFixture = "testdata/session-normal-2026-11-06.txt"

// readFixture returns the fixture's hooks in file order.
func readFixture(t *testing.T, path string) (names []string, chars map[string]int) {
	t.Helper()
	f, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	chars = map[string]int{}
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		l := strings.TrimSpace(sc.Text())
		if l == "" || strings.HasPrefix(l, "#") {
			continue
		}
		fs := strings.Fields(l)
		n, err := strconv.Atoi(fs[len(fs)-1])
		if len(fs) != 2 || err != nil {
			t.Fatalf("%s: bad line %q (want '<hook> <chars>')", path, l)
		}
		names, chars[fs[0]] = append(names, fs[0]), n
	}
	return names, chars
}

// registered returns, per source, the SessionStart hooks the repo's .claude/settings.json registers. The settings
// file is the one live file this test reads, through RSDD_TEST_RESEARCH_SDD (its parent holds .claude/).
func registered(t *testing.T) map[string][]string {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(filepath.Dir(kitroot.Dir(t)), ".claude", "settings.json"))
	if err != nil {
		t.Fatal(err)
	}
	doc, ok := parseSettings(data)
	if !ok {
		t.Fatal("settings.json is not a JSON object")
	}
	out := map[string][]string{}
	for _, src := range sources {
		stream, err := selectHooks(doc, src)
		if err != nil {
			t.Fatal(err)
		}
		for _, r := range splitRecords(stream) {
			out[src] = append(out[src], hookName(r.cmd))
		}
	}
	return out
}

// drift names the hooks registered without a reading (unmeasured) and the readings of hooks no longer registered (stale).
func drift(fixture, reg []string) (unmeasured, stale []string) {
	in := func(s []string, v string) bool {
		for _, x := range s {
			if x == v {
				return true
			}
		}
		return false
	}
	for _, r := range reg {
		if !in(fixture, r) {
			unmeasured = append(unmeasured, r)
		}
	}
	for _, f := range fixture {
		if !in(reg, f) {
			stale = append(stale, f)
		}
	}
	return unmeasured, stale
}

func TestDriftBothDirections(t *testing.T) {
	if u, s := drift([]string{"a", "b"}, []string{"a", "b"}); len(u)+len(s) != 0 {
		t.Errorf("equal sets: unmeasured %v stale %v", u, s)
	}
	if u, s := drift([]string{"a"}, []string{"a", "new"}); len(u) != 1 || u[0] != "new" || len(s) != 0 {
		t.Errorf("a registered hook with no reading must be unmeasured: %v %v", u, s)
	}
	if u, s := drift([]string{"a", "gone"}, []string{"a"}); len(s) != 1 || s[0] != "gone" || len(u) != 0 {
		t.Errorf("a reading of a hook no longer registered must be stale: %v %v", u, s)
	}
}

func TestMixedGateOnFrozenFixture(t *testing.T) {
	names, chars := readFixture(t, normalFixture)
	reg := registered(t)
	if len(names) == 0 || len(reg) == 0 {
		t.Fatalf("zero coverage: %d hooks in the fixture, %d sources registered (a gate that counted nothing proves nothing)", len(names), len(reg))
	}
	worst, worstSrc, nreg := 0, "", 0
	var all []string
	for _, src := range sources {
		hooks := reg[src]
		if len(hooks) == 0 {
			continue
		}
		var rs []reading
		for _, n := range hooks {
			rs = append(rs, reading{name: n, chars: chars[n]})
			if !slices.Contains(all, n) {
				all = append(all, n)
			}
		}
		if _, total := mixedSourceLine(src, rs); total > worst {
			worst, worstSrc = total, src
		}
	}
	nreg = len(all)
	normal := 0
	for _, c := range chars {
		normal += c
	}
	t.Logf("counted: %d hooks in the fixture, %d registered, normal total %d, mixed worst %d (source %s)", len(names), nreg, normal, worst, worstSrc)
	unmeasured, stale := drift(names, all)
	sort.Strings(unmeasured)
	if len(unmeasured) > 0 {
		t.Errorf("settings.json registers SessionStart hooks the fixture has no reading for: %v (measure them, add them to %s, re-date it)", unmeasured, normalFixture)
	}
	if len(stale) > 0 {
		t.Errorf("the fixture has readings for hooks settings.json no longer registers: %v (remove them from %s, re-date it)", stale, normalFixture)
	}
	if worst >= sessionCap {
		t.Errorf("mixed worst case %d chars is not under the %d budget", worst, sessionCap)
	}
	// 2028 + 1155 + six hooks at the 800 cap: the corrected arithmetic of #2756, pinned on the frozen reading.
	if want := 2028 + 1155 + 6*800; worst != want {
		t.Errorf("mixed worst %d, want %d on the frozen fixture", worst, want)
	}
}
