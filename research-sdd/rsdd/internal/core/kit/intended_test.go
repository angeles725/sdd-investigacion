package kit

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"sync"
	"testing"
)

// testdata/intended.json declares the ONLY differential cases where Go may differ from bash (#2291: silent zeros are
// never replicated). expectSame enforces, for every case routed through it:
//
//	(a) a divergence is allowed only for a case named in the file;
//	(b) a listed case that no longer diverges is an error (a stale entry);
//	(c) every other case stays byte-identical.
//
// TestDifferentialIntendedDivergences additionally fails an entry that no executed case ever used.
type intendedFile struct {
	Version  int `json:"version"`
	Intended []struct {
		Case   string `json:"case"`
		Reason string `json:"reason"`
	} `json:"intended"`
}

var (
	intendedMu sync.Mutex
	intendedOK map[string]bool
	exercised  = map[string]string{} // case -> "ran" | "skipped"
)

func intendedSet(t *testing.T) map[string]bool {
	t.Helper()
	intendedMu.Lock()
	defer intendedMu.Unlock()
	if intendedOK != nil {
		return intendedOK
	}
	b, err := os.ReadFile(filepath.Join("testdata", "intended.json"))
	if err != nil {
		t.Fatalf("testdata/intended.json must exist (an absent registry is not an empty one): %v", err)
	}
	var f intendedFile
	dec := json.NewDecoder(bytes.NewReader(b))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&f); err != nil || f.Version != 1 {
		t.Fatalf("intended.json: version=%d err=%v", f.Version, err)
	}
	m := map[string]bool{}
	for _, e := range f.Intended {
		if e.Case == "" || e.Reason != "legacy silent zero, #2291" || m[e.Case] {
			t.Fatalf("intended.json: bad or duplicate entry %+v", e)
		}
		m[e.Case] = true
	}
	intendedOK = m
	return m
}

func markCase(name, state string) {
	intendedMu.Lock()
	exercised[name] = state
	intendedMu.Unlock()
}

// expectSame compares a canonical rendering of the Go and bash results of one named differential case.
func expectSame(t *testing.T, name, goGot, bashGot string) {
	t.Helper()
	listed := intendedSet(t)[name]
	markCase(name, "ran")
	switch same := goGot == bashGot; {
	case listed && same:
		t.Errorf("%s: stale intended.json entry, Go and bash no longer diverge (%q)", name, goGot)
	case !listed && !same:
		t.Errorf("%s: unlisted divergence\n go=%q\nbash=%q", name, goGot, bashGot)
	}
}

func TestDifferentialIntendedDivergences(t *testing.T) {
	// F2: an unreadable (mode 000) TARGETS.md. Bash: rc 0 and an empty list. Go: a typed error (rc 1).
	if os.Geteuid() == 0 {
		markCase("unreadable-targets-file", "skipped")
		t.Log("unreadable-targets-file skipped: running as root, chmod 000 stays readable (NOT a pass)")
	} else {
		p := write(t, filepath.Join(t.TempDir(), "locked.md"), "| `/x` |\n")
		if err := os.Chmod(p, 0); err != nil {
			t.Fatal(err)
		}
		b := bashDriver(t, bashEnv("", "/h"), "", "tpall", p)
		_, err := ReadTargets(p)
		expectSame(t, "unreadable-targets-file", render(RC(err), ""), render(b.rc, b.stdout))
	}
	// F6: list_state_files on a directory that does not exist. Bash: rc 0, nothing. Go: ErrAbsentInput (rc 1).
	missing := filepath.Join(t.TempDir(), "nope")
	b := bashDriver(t, bashEnv("", "/h"), "", "liststate", missing)
	got, err := ListStateFiles(missing)
	rc := 0
	if err != nil {
		rc = 1
	}
	expectSame(t, "list-state-files-absent-dir", render(rc, lines(got)), render(b.rc, b.stdout))

	for name := range intendedSet(t) {
		intendedMu.Lock()
		st := exercised[name]
		intendedMu.Unlock()
		if st == "" {
			t.Errorf("intended.json lists %q but no executed differential case uses it", name)
		}
	}
}

func render(rc int, out string) string { return "rc=" + string(rune('0'+rc)) + " out=" + out }
