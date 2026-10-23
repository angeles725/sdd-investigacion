package kit

import (
	"sort"
	"strings"
	"testing"
)

// FuzzDerive checks invariants on arbitrary input (no panic, sorted, unique, tokens come from table rows, no
// backtick survives). Byte parity with bash is the differential tests' job; running bash per fuzz input is too slow.
func FuzzDerive(f *testing.F) {
	for _, s := range targetCorpus {
		f.Add(s)
	}
	f.Add("| `/a`")
	f.Add("\v| `$RESEARCH_HOME/x` `${RESEARCH_HOME}/y`\n`/prose`")
	f.Fuzz(func(t *testing.T, src string) {
		pairs, reading := Derive(src, envOf(map[string]string{"RESEARCH_HOME": "/rh/", "HOME": "/h"}))
		lines := make([]string, len(pairs))
		for i, p := range pairs {
			lines[i] = p.Line()
			if strings.Contains(p.Raw, "`") || strings.Contains(p.Expanded, "`") {
				t.Fatalf("backtick survived: %+v", p)
			}
			if !strings.Contains(src, "`"+p.Raw+"`") {
				t.Fatalf("token %q not present in the source", p.Raw)
			}
		}
		if !sort.StringsAreSorted(lines) {
			t.Fatalf("not sorted: %q", lines)
		}
		for i := 1; i < len(lines); i++ {
			if lines[i] == lines[i-1] {
				t.Fatalf("duplicate: %q", lines[i])
			}
		}
		if (reading == ReadTokens) != (len(pairs) > 0) || (src == "") != (reading == ReadEmptyInput) {
			t.Fatalf("reading %v inconsistent with %d pairs for %q", reading, len(pairs), src)
		}
	})
}
