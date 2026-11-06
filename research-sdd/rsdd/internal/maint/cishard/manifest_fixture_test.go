package cishard

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Guard-to-test table: the recorded `go test -json` streams of testdata/gotestjson pin what Go reports for each shape of
// package, so the manifest writer is judged against real output and not against an assumption (spec S5):
// build failure and crashed test binary -> package-level `fail`; all tests skipped -> package-level `pass`.
// The README beside them records the Go version and the command that produced them.

const fixturePrefix = "example.com/fx/"

func fixture(t *testing.T, name string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("testdata", "gotestjson", name+".json"))
	if err != nil || len(b) == 0 {
		t.Fatalf("fixture %s: %v (%d bytes)", name, err, len(b))
	}
	return string(b)
}

func TestRecordedPackageLevelActions(t *testing.T) {
	for _, c := range []struct{ name, final string }{
		{"buildfail", "fail"}, // a package that does not build: no test event, the package-level fail carries FailedBuild
		{"crash", "fail"},     // a test binary that exits 3 in TestMain: no test event, a package-level fail
		{"failing", "fail"},   // a failing test
		{"passes", "pass"},
		{"allskip", "pass"}, // every test skipped is still a package-level pass: only the test-level skips tell
	} {
		st := readStream([]byte(fixture(t, c.name)))
		if got := st.final[fixturePrefix+c.name]; got != c.final {
			t.Errorf("%s: final action %q, want %q", c.name, got, c.final)
		}
		if st.malformed != 0 || len(st.unknown) != 0 {
			t.Errorf("%s: malformed %d unknown %v (a documented action was not recognised)", c.name, st.malformed, st.unknown)
		}
	}
}

func TestRecordedBuildFailureCarriesImportPathEventsOnly(t *testing.T) {
	// the build-output / build-fail events name the package by ImportPath and have no Package: they are not a package
	// of the stream, so they cannot read as an unplanned package
	st := readStream([]byte(fixture(t, "buildfail")))
	if len(st.seen) != 1 || !st.seen[fixturePrefix+"buildfail"] {
		t.Errorf("seen %v", st.seen)
	}
	if !strings.Contains(fixture(t, "buildfail"), `"Action":"build-fail"`) {
		t.Errorf("the recorded stream no longer holds a build-fail event")
	}
}

func TestRecordedStreamsThroughTheCommand(t *testing.T) {
	all := []string{"allskip", "buildfail", "crash", "failing", "passes"}
	var planned string
	for _, n := range all {
		planned += fixturePrefix + n + "\n"
	}
	// one invocation for the five packages (the recorded all.json), --exit as make saw it
	r := manifestRun(t, planned, fixture(t, "all"), "1/1", "1")
	want := "# shard 1/1 suites=5 exit=1\n" +
		fixturePrefix + "allskip PASS\n" + fixturePrefix + "buildfail FAIL\n" + fixturePrefix + "crash FAIL\n" +
		fixturePrefix + "failing FAIL\n" + fixturePrefix + "passes PASS\n"
	if r.rc != 0 || r.out != want {
		t.Fatalf("%+v", r)
	}
	if !has(r.err, "Go tests skipped: 2 — ["+fixturePrefix+"allskip: 2]\n") || !has(r.err, "unknown actions: 0 — []\n") {
		t.Errorf("stderr %q", r.err)
	}
	// the same five, run one package per invocation, give the same row for the same package
	for _, n := range all {
		one := manifestRun(t, fixturePrefix+n+"\n", fixture(t, n), "1/1", "1")
		if !strings.Contains(want, strings.TrimPrefix(one.out, "# shard 1/1 suites=1 exit=1\n")) {
			t.Errorf("%s: %+v", n, one)
		}
	}
}

func TestRecordedFixturesNameTheirToolchain(t *testing.T) {
	b, err := os.ReadFile(filepath.Join("testdata", "gotestjson", "README.md"))
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"go version go1.", "go test -json -count=1", "TestMain", "undefinedSymbol"} {
		if !strings.Contains(string(b), want) {
			t.Errorf("README lacks %q", want)
		}
	}
}
