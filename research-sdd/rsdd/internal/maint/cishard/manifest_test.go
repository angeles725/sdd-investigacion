package cishard

import (
	"fmt"
	"strings"
	"testing"
)

// Guard-to-test table (manifest*.go): header and rows -> TestManifestAllPass; planned order and the edges ->
// TestManifestPositions; a missing final event -> TestManifestNoFinalEvent; package-level skip -> TestManifestSkipRow;
// empty stream -> TestManifestEmptyStream; no readable event -> TestManifestNoEvents; unplanned package ->
// TestManifestUnplannedPackage; exit and rows disagreeing -> TestManifestExitAndRows; unknown actions ->
// TestManifestUnknownActions; test-level skips -> TestManifestCountsTestSkips; malformed lines ->
// TestManifestMalformedLines; absent/empty/invalid inputs -> TestManifestInputStates; usage -> TestManifestUsage.

// ev is one go test -json event line.
func ev(action, pkg, test string) string {
	if test == "" {
		return fmt.Sprintf(`{"Action":%q,"Package":%q}`+"\n", action, pkg)
	}
	return fmt.Sprintf(`{"Action":%q,"Package":%q,"Test":%q}`+"\n", action, pkg, test)
}

// manifestRun writes the planned file and runs the manifest command.
func manifestRun(t *testing.T, planned, stream string, shard string, rc string) result {
	t.Helper()
	d := t.TempDir()
	p := writeFile(t, d, "planned.txt", planned)
	return runIn(t, d, str(stream), "manifest", "--shard", shard, "--exit", rc, "--planned", p)
}

func TestManifestAllPass(t *testing.T) {
	stream := ev("start", "a", "") + ev("pass", "a", "") + ev("start", "b", "") + ev("pass", "b", "")
	r := manifestRun(t, "a\nb\n", stream, "1/2", "0")
	if r.rc != 0 || r.out != "# shard 1/2 suites=2 exit=0\na PASS\nb PASS\n" {
		t.Fatalf("%+v", r)
	}
	for _, want := range []string{"Go tests skipped: 0 — []\n", "unknown actions: 0 — []\n"} {
		if !has(r.err, want) {
			t.Errorf("stderr lacks %q: %q", want, r.err)
		}
	}
	if has(r.err, "FINDING") {
		t.Errorf("unexpected finding: %q", r.err)
	}
}

func TestManifestPositions(t *testing.T) {
	// the failing package in first, middle and last position of the planned list; rows keep the planned order
	for pos := 0; pos < 3; pos++ {
		var planned, stream string
		var want []string
		for i := 0; i < 3; i++ {
			p := fmt.Sprintf("p%d", i)
			planned += p + "\n"
			act, row := "pass", "PASS"
			if i == pos {
				act, row = "fail", "FAIL"
			}
			stream += ev(act, p, "")
			want = append(want, p+" "+row)
		}
		r := manifestRun(t, planned, stream, "1/1", "1")
		if r.rc != 0 || r.out != "# shard 1/1 suites=3 exit=1\n"+strings.Join(want, "\n")+"\n" {
			t.Errorf("pos %d: %+v", pos, r)
		}
	}
	// a single planned package, and a planned file without a final newline
	r := manifestRun(t, "only", ev("pass", "only", ""), "2/2", "0")
	if r.rc != 0 || r.out != "# shard 2/2 suites=1 exit=0\nonly PASS\n" {
		t.Errorf("%+v", r)
	}
}

func TestManifestNoFinalEvent(t *testing.T) {
	// b started and ran a test but never reached a package-level pass/fail: it is FAIL, whatever the exit said
	stream := ev("pass", "a", "") + ev("start", "b", "") + ev("run", "b", "TestX") + ev("pass", "b", "TestX")
	// a missing final event is a finding (the command exits 1) even when the exit already explains a failure
	r := manifestRun(t, "a\nb\n", stream, "1/1", "1")
	if r.rc != 1 || r.out != "# shard 1/1 suites=2 exit=1\na PASS\nb FAIL\n" || !has(r.err, "ci-shard: FINDING — no-final-event: b has no final package-level event; recorded FAIL\n") {
		t.Errorf("%+v", r)
	}
	// a test-level pass is not a package-level pass
	if r := manifestRun(t, "b\n", ev("pass", "b", "TestX"), "1/1", "1"); !has(r.out, "b FAIL") {
		t.Errorf("%+v", r)
	}
	// with --exit 0 the same stream disagrees with the exit
	r = manifestRun(t, "a\nb\n", stream, "1/1", "0")
	if r.rc != 1 || !has(r.err, "ci-shard: FINDING — exit-0-with-fail: --exit 0 but 1 row(s) are FAIL — [b]\n") {
		t.Errorf("%+v", r)
	}
}

// Rule (coordinator ruling): any finding with --exit 0 writes the header with exit=1, so the join fails from the manifest
// alone; a non-zero --exit is written as given; report-only lines never change the header.
func TestManifestRaisesTheHeaderOnAnyFinding(t *testing.T) {
	const raised = "ci-shard: header exit raised to 1 because of findings: "
	// the finding (a package with no final event) in the first, middle and last planned package
	for pos := 0; pos < 3; pos++ {
		var planned, stream string
		var rows []string
		for i := 0; i < 3; i++ {
			p := fmt.Sprintf("p%d", i)
			planned += p + "\n"
			row := "PASS"
			if i == pos {
				stream += ev("start", p, "")
				row = "FAIL"
			} else {
				stream += ev("pass", p, "")
			}
			rows = append(rows, p+" "+row)
		}
		body := strings.Join(rows, "\n") + "\n"
		r := manifestRun(t, planned, stream, "1/1", "0")
		if r.rc != 1 || r.out != "# shard 1/1 suites=3 exit=1\n"+body || !has(r.err, raised+"no-final-event, exit-0-with-fail\n") {
			t.Errorf("pos %d, --exit 0: %+v", pos, r)
		}
		// a non-zero exit is written as given and not overwritten, and nothing is raised
		r = manifestRun(t, planned, stream, "1/1", "7")
		if r.rc != 1 || r.out != "# shard 1/1 suites=3 exit=7\n"+body || has(r.err, "raised") {
			t.Errorf("pos %d, --exit 7: %+v", pos, r)
		}
	}
	// a single planned package with an unplanned one in the stream
	one := ev("pass", "a", "") + ev("pass", "x/extra", "")
	if r := manifestRun(t, "a\n", one, "1/1", "0"); r.out != "# shard 1/1 suites=1 exit=1\na PASS\n" || !has(r.err, raised+"unplanned-package\n") {
		t.Errorf("single: %+v", r)
	}
	if r := manifestRun(t, "a\n", one, "1/1", "3"); r.out != "# shard 1/1 suites=1 exit=3\na PASS\n" || has(r.err, "raised") {
		t.Errorf("single, --exit 3: %+v", r)
	}
	// no finding: nothing is raised
	if r := manifestRun(t, "a\n", ev("pass", "a", ""), "1/1", "0"); r.out != "# shard 1/1 suites=1 exit=0\na PASS\n" || has(r.err, "raised") {
		t.Errorf("clean: %+v", r)
	}
}

func TestManifestSkipRow(t *testing.T) {
	r := manifestRun(t, "a\nb\n", ev("skip", "a", "")+ev("pass", "b", ""), "1/1", "0")
	if r.rc != 0 || r.out != "# shard 1/1 suites=2 exit=0\na SKIP\nb PASS\n" {
		t.Errorf("%+v", r)
	}
}

func TestManifestLastFinalEventWins(t *testing.T) {
	r := manifestRun(t, "a\n", ev("pass", "a", "")+ev("fail", "a", ""), "1/1", "1")
	if !has(r.out, "a FAIL") {
		t.Errorf("%+v", r)
	}
}

func TestManifestEmptyStream(t *testing.T) {
	for _, rc := range []struct{ in, header string }{{"0", "exit=1"}, {"1", "exit=1"}, {"5", "exit=5"}} {
		r := manifestRun(t, "a\nb\n", "", "1/2", rc.in)
		want := "# shard 1/2 suites=2 " + rc.header + "\na FAIL\nb FAIL\n"
		if r.rc != 1 || r.out != want || !has(r.err, "ci-shard: FINDING — empty-input: the go test -json stream has no bytes; every planned package is recorded FAIL and exit is forced non-zero\n") {
			t.Errorf("--exit %s: %+v", rc.in, r)
		}
	}
}

func TestManifestNoEvents(t *testing.T) {
	// bytes but nothing readable: not the same state as zero bytes, and also exit=1
	r := manifestRun(t, "a\n", "this is not json\n", "1/1", "0")
	if r.rc != 1 || r.out != "# shard 1/1 suites=1 exit=1\na FAIL\n" ||
		!has(r.err, "FINDING — no-events: the go test -json stream holds no readable event (1 malformed line(s)); every planned package is recorded FAIL and exit is forced non-zero\n") {
		t.Errorf("%+v", r)
	}
	if has(r.err, "empty-input") {
		t.Errorf("zero bytes and no events were not told apart: %q", r.err)
	}
}

func TestManifestUnplannedPackage(t *testing.T) {
	stream := ev("pass", "a", "") + ev("pass", "x/extra", "") + ev("fail", "y/extra", "TestQ")
	r := manifestRun(t, "a\n", stream, "1/1", "0")
	if r.rc != 1 || r.out != "# shard 1/1 suites=1 exit=1\na PASS\n" {
		t.Fatalf("%+v", r)
	}
	// two findings of one kind name the kind once
	if !has(r.err, "ci-shard: header exit raised to 1 because of findings: unplanned-package\n") {
		t.Errorf("%q", r.err)
	}
	for _, want := range []string{"ci-shard: FINDING — unplanned-package: x/extra is in the stream but not in the plan\n", "ci-shard: FINDING — unplanned-package: y/extra is in the stream but not in the plan\n"} {
		if !has(r.err, want) {
			t.Errorf("stderr lacks %q: %q", want, r.err)
		}
	}
}

func TestManifestExitAndRows(t *testing.T) {
	pass := ev("pass", "a", "") + ev("pass", "b", "")
	mixed := ev("pass", "a", "") + ev("fail", "b", "")
	skip := ev("pass", "a", "") + ev("skip", "b", "")
	for _, c := range []struct {
		name, stream, rc, finding, header string
	}{
		{"exit 0 with a FAIL row", mixed, "0", "exit-0-with-fail: --exit 0 but 1 row(s) are FAIL — [b]", "1"},
		{"non-zero exit with every row PASS", pass, "2", "exit-nonzero-no-fail: --exit 2 but no row is FAIL (2 PASS, 0 SKIP)", "2"},
		{"non-zero exit with PASS and SKIP rows", skip, "2", "exit-nonzero-no-fail: --exit 2 but no row is FAIL (1 PASS, 1 SKIP)", "2"},
		{"agree: exit 0, all PASS", pass, "0", "", "0"},
		{"agree: exit 0, PASS and SKIP", skip, "0", "", "0"},
		{"agree: non-zero exit, a FAIL row", mixed, "1", "", "1"},
	} {
		r := manifestRun(t, "a\nb\n", c.stream, "1/1", c.rc)
		if c.finding == "" {
			if r.rc != 0 || has(r.err, "FINDING") || !has(r.out, "exit="+c.header+"\n") {
				t.Errorf("%s: %+v", c.name, r)
			}
			continue
		}
		if r.rc != 1 || !has(r.err, "ci-shard: FINDING — "+c.finding+"\n") || !has(r.out, "# shard 1/1 suites=2 exit="+c.header+"\n") {
			t.Errorf("%s: %+v", c.name, r)
		}
	}
}

func TestManifestUnknownActions(t *testing.T) {
	stream := ev("pass", "a", "") + ev("weird", "a", "TestW") + ev("weird", "a", "") + ev("other", "a", "") +
		`{"Package":"a"}` + "\n" + ev("attr", "a", "TestA") + ev("bench", "a", "BenchmarkB") + ev("pause", "a", "T") + ev("cont", "a", "T")
	r := manifestRun(t, "a\n", stream, "1/1", "0")
	// report-only lines never change the header
	if r.rc != 0 || !has(r.out, "exit=0\n") || has(r.err, "raised") || !has(r.err, "unknown actions: 4 — [(none), other, weird]\n") {
		t.Errorf("%+v", r)
	}
	// every action go test -json documents is known
	known := ""
	for _, a := range []string{"start", "run", "pause", "cont", "pass", "fail", "skip", "output", "bench", "attr", "build-output", "build-fail"} {
		known += ev(a, "a", "")
	}
	if r := manifestRun(t, "a\n", known+ev("pass", "a", ""), "1/1", "0"); !has(r.err, "unknown actions: 0 — []\n") {
		t.Errorf("%q", r.err)
	}
}

func TestManifestCountsTestSkips(t *testing.T) {
	stream := ev("skip", "b", "T1") + ev("skip", "a", "T1") + ev("skip", "a", "T2") + ev("pass", "a", "T3") + ev("pass", "a", "") + ev("pass", "b", "") + ev("skip", "a", "T1/sub")
	r := manifestRun(t, "a\nb\n", stream, "1/1", "0")
	// a has a passing test beside its skips (PASS, still counted); b skipped its only test (SKIP)
	if r.rc != 0 || !has(r.err, "Go tests skipped: 4 — [a: 3, b: 1]\n") || !has(r.out, "a PASS\nb SKIP\n") {
		t.Errorf("%+v", r)
	}
}

func TestManifestMalformedLines(t *testing.T) {
	stream := ev("pass", "a", "") + "{truncated\n" + "\n" + ev("pass", "b", "")
	r := manifestRun(t, "a\nb\n", stream, "1/1", "0")
	if r.rc != 1 || r.out != "# shard 1/1 suites=2 exit=1\na PASS\nb PASS\n" || !has(r.err, "ci-shard: header exit raised to 1 because of findings: malformed-lines\n") || !has(r.err, "ci-shard: FINDING — malformed-lines: 1 line(s) of the stream are not JSON events\n") {
		t.Errorf("%+v", r)
	}
	// a stream without a final newline keeps its last event
	if r := manifestRun(t, "a\n", strings.TrimSuffix(ev("pass", "a", ""), "\n"), "1/1", "0"); r.rc != 0 || !has(r.out, "a PASS") {
		t.Errorf("%+v", r)
	}
}

func TestManifestInputStates(t *testing.T) {
	d := t.TempDir()
	good := writeFile(t, d, "planned.txt", "a\n")
	for _, c := range []struct {
		name    string
		stdin   *string
		planned string
		want    string
	}{
		{"absent stdin", nil, good, "ci-shard: absent-input — the go test -json stream on stdin could not be read"},
		{"absent planned file", str(ev("pass", "a", "")), d + "/missing.txt", "ci-shard: absent-input — planned list "},
		{"empty planned file", str(ev("pass", "a", "")), writeFile(t, d, "e.txt", ""), "ci-shard: empty-input — planned list: the list has no bytes"},
		{"blank planned file", str(ev("pass", "a", "")), writeFile(t, d, "b.txt", "\n\n"), "ci-shard: no-match — planned list: "},
		{"duplicate planned package", str(ev("pass", "a", "")), writeFile(t, d, "dup.txt", "a\na\n"), "ci-shard: INVALID — planned list line 2: \"a\" is listed twice (first at line 1)"},
	} {
		r := runIn(t, d, c.stdin, "manifest", "--shard", "1/1", "--exit", "0", "--planned", c.planned)
		if r.rc != 1 || r.out != "" || !has(r.err, c.want) {
			t.Errorf("%s: %+v", c.name, r)
		}
	}
}

func TestManifestUsage(t *testing.T) {
	d := t.TempDir()
	p := writeFile(t, d, "p.txt", "a\n")
	for _, args := range [][]string{
		{"manifest"},
		{"manifest", "--shard", "1/2", "--exit", "0"},
		{"manifest", "--shard", "1/2", "--planned", p},
		{"manifest", "--exit", "0", "--planned", p},
		{"manifest", "--shard", "3/2", "--exit", "0", "--planned", p},
		{"manifest", "--shard", "1/2", "--exit", "x", "--planned", p},
		{"manifest", "--shard", "1/2", "--exit", "-1", "--planned", p},
		{"manifest", "--shard", "1/2", "--exit", "1000", "--planned", p},
		{"manifest", "--shard", "1/2", "--exit", "256", "--planned", p},
		{"manifest", "--shard", "1/2", "--exit", "", "--planned", p},
		{"manifest", "--shard", "1/2", "--exit", "0", "--planned", p, "extra"},
		{"manifest", "--shard", "1/2", "--exit", "0", "--planned", p, "--bogus"},
	} {
		r := runIn(t, d, str(ev("pass", "a", "")), args...)
		if r.rc != 2 || r.out != "" || !has(r.err, "usage:") {
			t.Errorf("%v: %+v", args, r)
		}
	}
	// a relative --planned is relative to the working directory
	if r := runIn(t, d, str(ev("pass", "a", "")), "manifest", "--shard", "1/1", "--exit", "0", "--planned", "p.txt"); r.rc != 0 {
		t.Errorf("%+v", r)
	}
	// 0 and 255 are valid exit codes
	for _, rc := range []string{"0", "255"} {
		if r := runIn(t, d, str(ev("pass", "a", "")), "manifest", "--shard", "1/1", "--exit", rc, "--planned", p); r.rc == 2 {
			t.Errorf("--exit %s refused: %+v", rc, r)
		}
	}
}
