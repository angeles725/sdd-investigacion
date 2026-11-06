package archtest

import (
	"os"
	"testing"
)

const hdr = "# header\n# rule\n\n"

func update(t *testing.T, files map[string]string, debt string) (changed bool, got string) {
	t.Helper()
	root, dp := tree(t, files, debt)
	changed, err := UpdateDebt(root, dp)
	if err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile(dp)
	if err != nil {
		t.Fatal(err)
	}
	return changed, string(b)
}

func TestUpdateLowersShrunkFileKeepingCommentsAndOrder(t *testing.T) {
	debt := hdr + debtLine("a.go", 300, "legacy") + "# mid\n" + debtLine("b.go", 280, "accepted")
	changed, got := update(t, map[string]string{"a.go": gen(250), "b.go": gen(280)}, debt)
	want := hdr + "a.go 250 legacy " + reason + "\n# mid\n" + debtLine("b.go", 280, "accepted")
	if !changed || got != want {
		t.Errorf("changed=%v got:\n%q\nwant:\n%q", changed, got, want)
	}
}

func TestUpdateDeletesLinesAtOrBelowSoftLimitAndNonProduction(t *testing.T) {
	debt := hdr + debtLine("a.go", 300, "legacy") + debtLine("b.go", 300, "legacy") + debtLine("gone.go", 300, "legacy") + debtLine("z.go", 300, "legacy")
	changed, got := update(t, map[string]string{"a.go": gen(200), "b.go": gen(201), "z.go": gen(300)}, debt)
	want := hdr + "b.go 201 legacy " + reason + "\n" + debtLine("z.go", 300, "legacy")
	if !changed || got != want {
		t.Errorf("got %q want %q", got, want)
	}
}

func TestUpdateNeverRaisesAndNeverAdds(t *testing.T) {
	debt := hdr + debtLine("a.go", 300, "legacy")
	changed, got := update(t, map[string]string{"a.go": gen(350), "new.go": gen(500)}, debt)
	if changed || got != debt {
		t.Errorf("changed=%v got %q, want the file untouched", changed, got)
	}
}

func TestUpdateWithoutTrailingNewlineKeepsBytes(t *testing.T) {
	debt := debtLine("a.go", 300, "legacy") + "# last, no newline"
	changed, got := update(t, map[string]string{"a.go": gen(260)}, debt)
	want := "a.go 260 legacy " + reason + "\n# last, no newline"
	if !changed || got != want {
		t.Errorf("got %q want %q", got, want)
	}
}

func TestUpdateKeepsMalformedLines(t *testing.T) {
	debt := "broken line\n" + debtLine("a.go", 300, "legacy")
	changed, got := update(t, map[string]string{"a.go": gen(300)}, debt)
	if changed || got != debt {
		t.Errorf("changed=%v got %q", changed, got)
	}
}

func TestUpdateWritesNothingWhenUnchangedAndKeepsMode(t *testing.T) {
	root, dp := tree(t, map[string]string{"a.go": gen(300)}, debtLine("a.go", 300, "legacy"))
	if err := os.Chmod(dp, 0o600); err != nil {
		t.Fatal(err)
	}
	before, _ := os.Stat(dp)
	if changed, err := UpdateDebt(root, dp); err != nil || changed {
		t.Fatalf("changed=%v err=%v", changed, err)
	}
	after, _ := os.Stat(dp)
	if !after.ModTime().Equal(before.ModTime()) {
		t.Error("an unchanged debt file must not be rewritten")
	}
	if err := os.WriteFile(dp, []byte(debtLine("a.go", 400, "legacy")), 0o600); err != nil {
		t.Fatal(err)
	}
	if changed, err := UpdateDebt(root, dp); err != nil || !changed {
		t.Fatalf("changed=%v err=%v", changed, err)
	}
	if st, _ := os.Stat(dp); st.Mode().Perm() != 0o600 {
		t.Errorf("mode = %v, want 0600", st.Mode().Perm())
	}
	if ents, _ := os.ReadDir(root); len(ents) != 2 {
		t.Errorf("temp file left behind: %v", ents)
	}
}

func TestUpdateErrorsOnEmptyTreeAndAbsentDebt(t *testing.T) {
	root, dp := tree(t, map[string]string{"a_test.go": gen(1)}, "")
	if _, err := UpdateDebt(root, dp); err == nil {
		t.Error("zero production files must be an error")
	}
	root, dp = tree(t, map[string]string{"a.go": gen(1)}, "")
	os.Remove(dp)
	if _, err := UpdateDebt(root, dp); err == nil {
		t.Error("absent debt file must be an error")
	}
}

func TestUpdateIfRequestedWritesOnlyWhenTheVariableIsOne(t *testing.T) {
	files := map[string]string{"a.go": gen(250)}
	stale := debtLine("a.go", 300, "legacy")
	for _, v := range []string{"", "0", "true", "11"} {
		root, dp := tree(t, files, stale)
		changed, err := UpdateDebtIfRequested(v, root, dp)
		got, _ := os.ReadFile(dp)
		if err != nil || changed || string(got) != stale {
			t.Errorf("%s=%q: changed=%v err=%v file=%q, want the file untouched", UpdateEnv, v, changed, err, got)
		}
	}
	root, dp := tree(t, files, stale)
	changed, err := UpdateDebtIfRequested("1", root, dp)
	got, _ := os.ReadFile(dp)
	if want := debtLine("a.go", 250, "legacy"); err != nil || !changed || string(got) != want {
		t.Errorf("%s=1: changed=%v err=%v file=%q, want %q", UpdateEnv, changed, err, got, want)
	}
}
