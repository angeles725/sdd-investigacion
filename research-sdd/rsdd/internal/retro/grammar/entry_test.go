package grammar

import (
	"reflect"
	"testing"
)

func TestEntryRows(t *testing.T) {
	src := "## Proposed kit deltas\n" +
		"### D1 — Add the thing (high)\n**Priority**: MEDIUM — fires\n**Where in kit**: lib/a.sh  \n**Evidence**: seen 3x\n" +
		"**Evidence**: second\n**Target**: ignored, first wins\n" +
		"### D2. — Fix: (new, priority: Low)\n**Priority:** 1\n**Kit file** : x\n" +
		"### D3: —\n**Priority** low, maybe\n**Priority evidence**: q\n" +
		"### **D4** — bold id\n**Priority**: HIGH\n" +
		"### D5 no dash\n**Priority**: HIGH\n" +
		"### d6_x — t (low-risk change) (Medium)\n" +
		"## Other\n### D7 — outside the section\n"
	want := []Row{
		{ID: "D1", Change: "Add the thing (high)", Target: "lib/a.sh", Evidence: "seen 3x", Priority: "MEDIUM"},
		{ID: "D2", Change: "Fix: (new, priority: Low)", Target: "x", Priority: "Low"},
		{ID: "D3", Change: "D3", Evidence: "q", Priority: "low"},
		{ID: "d6_x", Change: "t (low-risk change) (Medium)", Priority: "Medium"},
	}
	got := EntryRows(Parse("r.md", src))
	if !reflect.DeepEqual(got, want) {
		t.Errorf("EntryRows:\n got %+v\nwant %+v", got, want)
	}
	if ids := EntryIDs(Parse("r.md", src)); !reflect.DeepEqual(ids, []string{"D1", "D2", "D3", "d6_x"}) {
		t.Errorf("EntryIDs = %q", ids)
	}
	if got[0].Line() != "D1\x1fAdd the thing (high)\x1flib/a.sh\x1fseen 3x\x1f\x1fMEDIUM\n" {
		t.Errorf("Line = %q", got[0].Line())
	}
}

func TestHeadingPriority(t *testing.T) {
	for h, want := range map[string]string{
		"### D1 — x (low)": "low", "### D1 — x (New, Priority: HIGH)": "HIGH", "### D1 — x (low-risk change)": "",
		"### D1 — x (medium confidence) (high)": "high", "### D1 — x (new)": "", "### D1 — x (high": "",
		"### D1 — x ((high)": "", "### D1 — x (low; high)": "low", "### D1 — x ( , )": "", "no parens": "",
	} {
		if got := headingPriority(h); got != want {
			t.Errorf("headingPriority(%q) = %q, want %q", h, got, want)
		}
	}
}

func TestEntryWarn(t *testing.T) {
	d := Parse("dir/r.md", "## Proposed kit deltas\n### D1 — a\n### **D2** — b\n### [D3] — c\n")
	want := "WARN: r.md: only 1 of 3 '### … —' entries have a usable ID token (a '**D1**' or '[D1]' token is not trackable) — count by hand\n"
	if got := EntryWarn(d); got != want {
		t.Errorf("EntryWarn = %q", got)
	}
	for _, src := range []string{"## Proposed kit deltas\n### D1 — a\n", "## Proposed kit deltas\n| a |\n| b |\n", ""} {
		if got := EntryWarn(Parse("r.md", src)); got != "" {
			t.Errorf("EntryWarn(%q) = %q, want none", src, got)
		}
	}
}
