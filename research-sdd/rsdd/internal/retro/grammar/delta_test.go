package grammar

import (
	"reflect"
	"testing"
)

func TestDelta(t *testing.T) {
	cases := []struct {
		name, src string
		want      DeltaInfo
	}{
		{"T1 canonical table, 3 data rows",
			"## Proposed kit deltas\n| ID | Change |\n|---|---|\n| D1 | a |\n| D2 | b |\n| D3 | c |\n",
			DeltaInfo{Found: true, Form: FormTable, Count: 3}},
		{"T2 deprecated heading keeps the first deprecated line",
			"## Summary of new deltas x\n| ID | C |\n|--|--|\n| D1 | a |\n| D2 | b |\n## Delta details\n",
			DeltaInfo{Found: true, Form: FormTable, Count: 2, DeprHeading: "## Summary of new deltas x"}},
		{"T3 entries form", "## Proposed delta\n### D1 — a\n### D2 — b\n### D3 no dash\n",
			DeltaInfo{Found: true, Form: FormEntries, Count: 2}},
		{"T4 H2 delta form outside a section", "## Delta W1 — a\n## Delta W2 — b\n## Delta W3 no dash\n",
			DeltaInfo{Form: FormH2Delta, Count: 2, UnrecFound: true, UnrecHeading: "## Delta W1 — a"}},
		{"T5 canonical heading, header row only", "## 6. Proposed kit deltas\n| ID | C |\n|---|---|\n",
			DeltaInfo{Found: true, Form: FormEmpty}},
		{"T6 no section", "# Retro\n\nprose\n", DeltaInfo{Form: FormNone}},
		{"T8 rule 1 unrecognised heading counts its rows",
			"## deltas proposed\n| ID | C |\n|--|--|\n| D1 | a |\n| D2 | b |\n## Other\n| X | y |\n",
			DeltaInfo{Form: FormNone, UnrecFound: true, UnrecData: 2, UnrecHeading: "## deltas proposed"}},
		{"T10 Spanish alias", "## PROPUESTA de deltas al kit\n| a | b |\n|-|-|\n| D1 | x |\n",
			DeltaInfo{Found: true, Form: FormTable, Count: 1}},
		{"T11 rule 2 hyphenated", "## B. Campaign-8 kit-delta backlog\n",
			DeltaInfo{Form: FormNone, UnrecFound: true, UnrecHeading: "## B. Campaign-8 kit-delta backlog"}},
		{"T11b rule 2 negated", "## Things not kit-delta related\n", DeltaInfo{Form: FormNone}},
		{"rule 3 parenthetical", "## Items (kit-delta)\n", DeltaInfo{Form: FormNone, UnrecFound: true, UnrecHeading: "## Items (kit-delta)"}},
		{"T12 rule 4 standalone H3", "### Proposals (propose-never-apply) — x\n",
			DeltaInfo{Form: FormNone, UnrecFound: true, UnrecHeading: "### Proposals (propose-never-apply) — x"}},
		{"T13 H3 proposals inside the section is form 2", "## Proposed kit deltas\n### Proposals — a\n",
			DeltaInfo{Found: true, Form: FormEntries, Count: 1}},
		{"rule 4 fires after the section closed", "## Proposed kit deltas\n## Other\n### Proposal\n",
			DeltaInfo{Found: true, Form: FormEmpty, UnrecFound: true, UnrecHeading: "### Proposal"}},
		{"unrec rules stop once found", "## Delta proposals\n## deltas\n## Delta D1 — x\n",
			DeltaInfo{Found: true, Form: FormEmpty}},
		{"only the first unrec heading opens a section",
			"## deltas a\n## deltas b\n| x |\n| y |\n", DeltaInfo{Form: FormNone, UnrecFound: true, UnrecHeading: "## deltas a"}},
		{"delta details alias never counts as form 3", "## Delta details — x\n",
			DeltaInfo{Found: true, Form: FormEmpty, DeprHeading: "## Delta details — x"}},
		{"separator rows and #### lines", "## Proposed kit deltas\n| a |\n| :-: | \t\n| b |\n#### D1 — x\n",
			DeltaInfo{Found: true, Form: FormTable, Count: 1}},
		{"case folding is ASCII", "## PROPOSED KIT DELTAS\n### D1 — x\n", DeltaInfo{Found: true, Form: FormEntries, Count: 1}},
		{"fenced heading is ignored", "```\n## Proposed kit deltas\n```\n", DeltaInfo{Form: FormNone}},
	}
	for _, c := range cases {
		if got := Delta(Parse("r.md", c.src)); got != c.want {
			t.Errorf("%s:\n got %+v\nwant %+v", c.name, got, c.want)
		}
	}
}

func TestDeltaInfoLine(t *testing.T) {
	for _, c := range []struct {
		in   DeltaInfo
		want string
	}{
		{DeltaInfo{Form: FormNone}, "0:n:0\x01\x010\x010\x01\n"},
		{DeltaInfo{Found: true, Form: FormTable, Count: 3, DeprHeading: "## d", UnrecFound: true, UnrecData: 2, UnrecHeading: "## x"},
			"1:1:3\x01## d\x011\x012\x01## x\n"},
		{DeltaInfo{Form: FormH2Delta, Count: 4}, "0:3:4\x01\x010\x010\x01\n"},
	} {
		if got := c.in.Line(); got != c.want {
			t.Errorf("%+v.Line() = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestCanonicalAndUnrecHeadings(t *testing.T) {
	d := Parse("r.md", "## deltas a\n### Proposals\n## Delta details\n### Proposals\n## Proposed kit deltas\n## x kit delta y\n")
	if h, ok := CanonicalHeading(d); !ok || h != "## Delta details" {
		t.Errorf("CanonicalHeading = %q %v", h, ok)
	}
	want := []string{"## deltas a", "### Proposals", "## x kit delta y"}
	if got := UnrecHeadings(d); !reflect.DeepEqual(got, want) {
		t.Errorf("UnrecHeadings = %q, want %q", got, want)
	}
	if h, ok := CanonicalHeading(Parse("r.md", "## Other\n")); ok || h != "" {
		t.Errorf("no canonical heading: %q %v", h, ok)
	}
}

func TestHeadingShapes(t *testing.T) {
	for line, want := range map[string][2]bool{
		"## a": {true, false}, "##\t": {true, false}, "##": {false, false}, "###": {false, false},
		"### a": {false, true}, "#### a": {false, false}, "##x": {true, false}, "###x": {false, true},
	} {
		if got := [2]bool{isH2(line), isH3(line)}; got != want {
			t.Errorf("%q: isH2/isH3 = %v, want %v", line, got, want)
		}
	}
	if lower("ÀBC\xffZ") != "Àbc\xffz" {
		t.Errorf("lower must fold ASCII only: %q", lower("ÀBC\xffZ"))
	}
}
