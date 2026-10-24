package grammar

import "testing"

const hon = "No new deltas; nothing to add."

func TestHasHonesty(t *testing.T) {
	canon := "## Proposed kit deltas\n"
	for _, c := range []struct {
		name, src string
		want      bool
	}{
		{"pure canonical honesty", canon + "\n" + hon + "\n", true},
		{"honesty plus prose", canon + hon + "\nmore prose\n", false},
		{"empty canonical, honest verdict", canon + "\n## 2. Honest verdict\n- **" + hon + "**\n", true},
		{"no canonical, honest verdict", "## Honest verdict\n" + hon + "\n", true},
		{"honest verdicts is not the heading", "## Honest verdicts\n" + hon + "\n", false},
		{"data rows block", canon + "| ID | C |\n|---|---|\n| D1 | x |\n" + hon + "\n", false},
		{"header and separator only", canon + "| ID | C |\n|---|---|\n" + hon + "\n", true},
		{"canonical prose blocks HV", canon + "prose\n## Honest verdict\n" + hon + "\n", false},
		{"nothing at all", "# Retro\nprose\n", false},
		{"veto H2 delta heading", canon + hon + "\n## Delta x\n", false},
		{"veto H2 id heading", canon + hon + "\n## D1 thing\n", false},
		{"no veto for H2 numeric", "## 6. Proposed kit deltas\n" + hon + "\n## 7. Other\n", true},
		{"veto H3 proposed outside", "### Proposed y\n" + canon + hon + "\n", false},
		{"veto H1 digit", "# 1 top\n" + canon + hon + "\n", false},
		{"veto H1 id", "# D1\n" + canon + hon + "\n", false},
		{"no veto for H3 numeric", "### 1. Fast loop\n" + canon + hon + "\n", true},
		{"H3 inside canonical is body", canon + "### D1 — x\n" + hon + "\n", false},
		{"clean lead block is exempt", canon + "> guidance prose\n>\n\n" + hon + "\n", true},
		{"dirty lead block fails", canon + "> guidance\n> - a delta\n" + hon + "\n", false},
		{"nbsp bullet is dirty", canon + ">  - a delta\n" + hon + "\n", false},
		{"em-dash continuation is clean", canon + "> — see below\n" + hon + "\n", true},
		{"dirty lead block alone", canon + "> 1. delta\n", false},
		{"clean lead block alone falls to HV", canon + "> guidance\n## Honest verdict\n" + hon + "\n", true},
		{"blockquoted honesty ends the lead block", canon + "> " + hon + "\n", true},
		{"trailing text is not honesty", canon + hon + " extra\n", false},
		{"emphasis variants", canon + "_no new deltas — the kit already covers this run._\n__" + hon + "__\n", true},
	} {
		if got := HasHonesty(Parse("r.md", c.src)); got != c.want {
			t.Errorf("%s: HasHonesty = %v, want %v", c.name, got, c.want)
		}
	}
}

func TestHonestyLine(t *testing.T) {
	for line, want := range map[string]bool{
		hon: true, "  * > " + hon: true, "**" + hon + "**  ": true, "_" + hon + "_": true, "__" + hon: true,
		"NO NEW DELTAS; THE KIT ALREADY COVERS THIS RUN.": true, "no new deltas — nothing to add.": true,
		"no new deltas; nothing to add": false, "x " + hon: false, "": false, "_": false, "__": false,
	} {
		if got := isHonesty(line); got != want {
			t.Errorf("isHonesty(%q) = %v, want %v", line, got, want)
		}
	}
}

func TestDirtyMarker(t *testing.T) {
	for line, want := range map[string]bool{
		"> - x": true, "> * x": true, ">+ x": true, "> **bold**": false, "> ###### h": true, "> ####### h": false,
		"> #h": false, "> | t": true, "> 12. x": true, "> 3)": true, "> 3.x": false, "> a) x": true, "> ab) x": false,
		"> • x": true, "> – x": false, "> [ ] x": true, "> [X]": true, "> [y] x": false, "> > > - x": true, "> plain": false,
		">   - x": true,
	} {
		if got := isDirtyMarker(line); got != want {
			t.Errorf("isDirtyMarker(%q) = %v, want %v", line, got, want)
		}
	}
}
