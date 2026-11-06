package consumers

import "testing"

func pairsFixture(t *testing.T) *fixture {
	t.Helper()
	f := newFixture(t)
	f.files(map[string]string{
		"research-sdd/toolbelt/a.sh": "b.sh\n",
		"research-sdd/toolbelt/b.sh": "a.sh b.sh\n",
		"research-sdd/toolbelt/c.sh": "nothing\n",
		"docs/z.md":                  "b.sh a.sh a.sh gone.sh\n",
		"docs/y.md":                  "b.sh\n",
		".github/w.yml":              "a.sh\n",
	})
	f.commit()
	return f
}

func TestRefsPrintsOneSortedLinePerPair(t *testing.T) {
	got := pairsFixture(t).run("--refs")
	const want = "CI workflows\t.github/w.yml\ta.sh\t1\n" +
		"doctrine and registries\tdocs/y.md\tb.sh\t1\n" +
		"doctrine and registries\tdocs/z.md\ta.sh\t2\n" +
		"doctrine and registries\tdocs/z.md\tb.sh\t1\n" +
		"scripts\tresearch-sdd/toolbelt/a.sh\tb.sh\t1\n" +
		"scripts\tresearch-sdd/toolbelt/b.sh\ta.sh\t1\n"
	if got != (ran{want, "", 0}) {
		t.Fatalf("got %+v", got)
	}
}

func TestRefsWithNothingToPrintSaysSo(t *testing.T) {
	f := newFixture(t)
	f.write("research-sdd/toolbelt/a.sh", "x\n")
	f.commit()
	want := ran{"", "consumers: no-match: no file names a live script\n", 0}
	if got := f.run("--refs"); got != want {
		t.Fatalf("got %+v", got)
	}
}

func TestScriptRestrictsTheReport(t *testing.T) {
	f := pairsFixture(t)
	got := f.run("--script", "a.sh")
	if got.rc != 0 || got.err != "" {
		t.Fatalf("rc %d, err %q", got.rc, got.err)
	}
	if l := line(got.out, "script: "); l != "script: a.sh (live)" {
		t.Fatalf("%q", l)
	}
	for class, want := range map[string]string{rowDocs: "2 1 1 2 none", rowCI: "1 1 1 1 none", rowScripts: "3 1 1 1 none"} {
		if r := row(got.out, class); r != want {
			t.Fatalf("row %q = %q, want %q", class, r, want)
		}
	}
	if l := line(got.out, "scripts: "); l != "scripts: 3 (sh 3)" {
		t.Fatalf("the script list is not restricted: %q", l)
	}
}

func TestScriptThatIsLiveButNamedByNothing(t *testing.T) {
	got := pairsFixture(t).run("--script", "c.sh")
	if l := line(got.out, "script: "); l != "script: c.sh (live)" {
		t.Fatalf("%q", l)
	}
	if r := row(got.out, rowDocs); r != "2 no-match no-match no-match none" {
		t.Fatalf("%q", r)
	}
}

func TestScriptThatIsNotLiveIsStillSearched(t *testing.T) {
	got := pairsFixture(t).run("--script", "gone.sh")
	if l := line(got.out, "script: "); got.rc != 0 || l != "script: gone.sh (not live)" {
		t.Fatalf("rc %d, %q", got.rc, l)
	}
	if r := row(got.out, rowDocs); r != "2 1 1 1 none" {
		t.Fatalf("%q", r)
	}
}

func TestScriptWithRefsRestrictsPairs(t *testing.T) {
	f := pairsFixture(t)
	want := ran{"CI workflows\t.github/w.yml\ta.sh\t1\ndoctrine and registries\tdocs/z.md\ta.sh\t2\nscripts\tresearch-sdd/toolbelt/b.sh\ta.sh\t1\n", "", 0}
	if got := f.run("--refs", "--script", "a.sh"); got != want {
		t.Fatalf("got %+v", got)
	}
	want = ran{"doctrine and registries\tdocs/z.md\tgone.sh\t1\n", "consumers: script gone.sh is not live\n", 0}
	if got := f.run("--refs", "--script", "gone.sh"); got != want {
		t.Fatalf("got %+v", got)
	}
	want = ran{"", "consumers: no-match: no file names c.sh\n", 0}
	if got := f.run("--script", "c.sh", "--refs"); got != want {
		t.Fatalf("got %+v", got)
	}
}
