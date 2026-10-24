package grammar

import "testing"

const bom = "\xef\xbb\xbf"

func TestStatusFromMarkerLine(t *testing.T) {
	for line, want := range map[string]string{
		"x <!--review-status:ApPlied-x": "applied", "<!-- review-status: pending · 2026 -->": "pending",
		"review-status: applied": "", "": "", "<!-- review-status: 123 -->": "",
		"<!-- review-status: a <!-- review-status: b": "a", "<!--\treview-status:\tDISMISSED": "dismissed",
	} {
		if got := StatusFromMarkerLine(line); got != want {
			t.Errorf("StatusFromMarkerLine(%q) = %q, want %q", line, got, want)
		}
	}
}

func TestReviewStatus(t *testing.T) {
	for src, want := range map[string]string{
		"<!-- review-status: Applied · x -->\n# T\n":                     "applied",
		bom + "<!-- review-status: pending -->\n":                        "pending",
		"# T\n<!-- review-status: applied -->\n":                         "",
		"\n  <!-- other -->\n<!-- REVIEW-STATUS:Dismissed -->\n":         "dismissed",
		"    <!-- review-status: applied -->\n":                          "applied",
		"text\n<!-- review-status: applied -->\n":                        "",
		"<!-- a --> review-status: x\n<!-- review-status: pending -->\n": "pending",
		"": "",
	} {
		if got := ReviewStatus(Parse("r.md", src)); got != want {
			t.Errorf("ReviewStatus(%q) = %q, want %q", src, got, want)
		}
	}
}

func TestMarkerScopeLine(t *testing.T) {
	m := "<!-- review-status: applied · x -->"
	for src, want := range map[string]string{
		"# Title\n\n" + m + "\n":                      m,
		bom + "# Title\n" + m + "\n":                  m,
		"# T\n## H\n" + m + "\n":                      "",
		"    " + m + "\n":                             "",
		"   " + m + "\n":                              "   " + m,
		"\t" + m + "\n":                               "",
		"#\n" + m + "\n":                              m,
		"  #x\n" + m + "\n":                           m,
		"## H2\n" + m + "\n":                          "",
		"<!-- a -->\n<!-- Review-Status: y -->\n" + m: "<!-- Review-Status: y -->",
		"\n\n# late H1\n" + m + "\n":                  "",
	} {
		if got := MarkerScopeLine(Parse("r.md", src)); got != want {
			t.Errorf("MarkerScopeLine(%q) = %q, want %q", src, got, want)
		}
	}
}

func TestLeadingBlockFlags(t *testing.T) {
	for _, c := range []struct {
		src                    string
		excluded, waived, bare bool
	}{
		{"<!-- kit-retro: exclude -->\n", true, false, false},
		{"<!-- KIT-RETRO:EXCLUDE   -->  \n", true, false, false},
		{"<!-- kit-retro: exclude please -->\n", false, false, false},
		{"# T\n<!-- kit-retro: exclude -->\n", false, false, false},
		{bom + "<!-- kit-retro: exclude -->\n", true, false, false},
		{"\t<!-- kit-retro: exclude -->\n", true, false, false},
		{"<!-- kit-retro: exclude -->\n<!-- retro-waived: 2026-01-01 · reason -->\n", true, true, false},
		{"<!-- retro-waived: -->\n", false, false, false},
		{"<!-- retro-waived: >x -->\n", false, false, false},
		{"<!-- retro-waived: a > b -->\n", false, false, false},
		{"review-status: applied\n", false, false, true},
		{bom + "  Review-Status: x\n", false, false, true},
		{"<!-- review-status: x -->\n", false, false, false},
		{"1\n2\n3\n4\n5\n6\n7\n8\n9\nreview-status: x\n", false, false, true},
		{"1\n2\n3\n4\n5\n6\n7\n8\n9\n10\nreview-status: x\n", false, false, false},
	} {
		d := Parse("r.md", c.src)
		if got := [3]bool{IsExcluded(d), IsWaived(d), HasBareMarker(d)}; got != [3]bool{c.excluded, c.waived, c.bare} {
			t.Errorf("%q: excluded/waived/bare = %v, want %v", c.src, got, [3]bool{c.excluded, c.waived, c.bare})
		}
	}
}
