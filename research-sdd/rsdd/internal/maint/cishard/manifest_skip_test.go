package cishard

import "testing"

// Guard-to-test table (manifest*.go, the all-skipped rule): a package whose final package-level action is pass, with at
// least one top-level test skip (a Test with no '/') and no top-level test pass or fail, is SKIP.
// rule fires -> TestAllSkippedPackageIsSkip; one passing test keeps PASS -> TestOnePassingTestKeepsPass; subtests are not
// top-level -> TestSubtestsAreNotTopLevel; a top-level fail blocks the rule -> TestTopLevelFailBlocksTheRule; the row still
// counts as SKIP in the exit rule -> TestAllSkippedRowCountsAsSkip; the recorded stream -> TestRecordedAllSkipIsSkip.

func TestAllSkippedPackageIsSkip(t *testing.T) {
	// first, middle and last planned package, and a single one
	allSkip := func(p string) string {
		return ev("start", p, "") + ev("skip", p, "T1") + ev("skip", p, "T2") + ev("pass", p, "")
	}
	ok := func(p string) string { return ev("pass", p, "T") + ev("pass", p, "") }
	for pos := 0; pos < 3; pos++ {
		var planned, stream, want string
		for i := 0; i < 3; i++ {
			p := "p" + string(rune('0'+i))
			planned += p + "\n"
			row := "PASS"
			if i == pos {
				stream += allSkip(p)
				row = "SKIP"
			} else {
				stream += ok(p)
			}
			want += p + " " + row + "\n"
		}
		r := manifestRun(t, planned, stream, "1/1", "0")
		if r.rc != 0 || r.out != "# shard 1/1 suites=3 exit=0\n"+want {
			t.Errorf("pos %d: %+v", pos, r)
		}
	}
	if r := manifestRun(t, "only\n", allSkip("only"), "1/1", "0"); r.rc != 0 || r.out != "# shard 1/1 suites=1 exit=0\nonly SKIP\n" || !has(r.err, "Go tests skipped: 2 — [only: 2]\n") {
		t.Errorf("single: %+v", r)
	}
}

func TestOnePassingTestKeepsPass(t *testing.T) {
	stream := ev("skip", "a", "T1") + ev("pass", "a", "T2") + ev("pass", "a", "")
	r := manifestRun(t, "a\n", stream, "1/1", "0")
	if r.rc != 0 || r.out != "# shard 1/1 suites=1 exit=0\na PASS\n" || !has(r.err, "Go tests skipped: 1 — [a: 1]\n") {
		t.Errorf("%+v", r)
	}
}

func TestSubtestsAreNotTopLevel(t *testing.T) {
	// only a subtest skipped: no top-level skip, so the package is PASS
	only := ev("pass", "a", "T/sub") + ev("skip", "a", "T/other") + ev("pass", "a", "")
	if r := manifestRun(t, "a\n", only, "1/1", "0"); !has(r.out, "a PASS\n") {
		t.Errorf("subtest skip only: %+v", r)
	}
	// a top-level skip beside a passing SUBTEST of another test: the subtest is not a top-level pass, so SKIP
	sub := ev("skip", "a", "T1") + ev("pass", "a", "T2/sub") + ev("pass", "a", "")
	if r := manifestRun(t, "a\n", sub, "1/1", "0"); !has(r.out, "a SKIP\n") {
		t.Errorf("top-level skip and a passing subtest: %+v", r)
	}
}

func TestTopLevelFailBlocksTheRule(t *testing.T) {
	stream := ev("skip", "a", "T1") + ev("fail", "a", "T2") + ev("pass", "a", "")
	if r := manifestRun(t, "a\n", stream, "1/1", "0"); !has(r.out, "a PASS\n") {
		t.Errorf("%+v", r)
	}
}

func TestAllSkippedRowCountsAsSkip(t *testing.T) {
	stream := ev("skip", "a", "T1") + ev("pass", "a", "") + ev("pass", "b", "T") + ev("pass", "b", "")
	r := manifestRun(t, "a\nb\n", stream, "1/1", "2")
	if r.rc != 1 || r.out != "# shard 1/1 suites=2 exit=2\na SKIP\nb PASS\n" ||
		!has(r.err, "ci-shard: FINDING — exit-nonzero-no-fail: --exit 2 but no row is FAIL (1 PASS, 1 SKIP)\n") {
		t.Errorf("%+v", r)
	}
}

func TestRecordedAllSkipIsSkip(t *testing.T) {
	r := manifestRun(t, fixturePrefix+"allskip\n", fixture(t, "allskip"), "1/1", "0")
	if r.rc != 0 || r.out != "# shard 1/1 suites=1 exit=0\n"+fixturePrefix+"allskip SKIP\n" {
		t.Errorf("%+v", r)
	}
	p := manifestRun(t, fixturePrefix+"passes\n", fixture(t, "passes"), "1/1", "0")
	if p.rc != 0 || p.out != "# shard 1/1 suites=1 exit=0\n"+fixturePrefix+"passes PASS\n" {
		t.Errorf("%+v", p)
	}
}
