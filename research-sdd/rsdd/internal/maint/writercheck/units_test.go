package writercheck

import (
	"reflect"
	"strings"
	"testing"
)

func TestBlobOfIsGitsBlobId(t *testing.T) {
	for in, want := range map[string]string{
		"":               "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391", // the empty blob
		"test content\n": "d670460b4b4aece5915caf5c68d12f560a9fe3e4", // git hash-object of this text
	} {
		if got := blobOf(in); got != want {
			t.Errorf("blobOf(%q) = %s, want %s", in, got, want)
		}
	}
}

func TestParseNameStatus(t *testing.T) {
	got := parseNameStatus("M\x00a b.sh\x00R100\x00old.sh\x00new.sh\x00D\x00gone.sh\x00C75\x00src\x00dst\x00A\x00new\x00")
	want := []change{{"M", "a b.sh", ""}, {"R100", "new.sh", "old.sh"}, {"D", "gone.sh", ""}, {"C75", "dst", "src"}, {"A", "new", ""}}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("got %+v\nwant %+v", got, want)
	}
	if got := parseNameStatus(""); len(got) != 0 {
		t.Errorf("an empty diff has no changes: %+v", got)
	}
	if got := parseNameStatus("R100\x00only-one\x00"); len(got) != 0 {
		t.Errorf("a truncated rename record must not be invented: %+v", got)
	}
}

func TestParseAddedReadsHunksByTheirCounts(t *testing.T) {
	diff := strings.Join([]string{
		"diff --git a/x.sh b/x.sh", "--- a/x.sh", "+++ b/x.sh",
		"@@ -2 +2,2 @@", "-old", "+new one", "+new two",
		"@@ -9,0 +10 @@", "+tail",
		"diff --git a/gone.sh b/gone.sh", "--- a/gone.sh", "+++ /dev/null", "@@ -1 +0,0 @@", "-bye", "",
	}, "\n")
	got := parseAdded(diff)
	want := []addedLine{{"x.sh", 2, "new one"}, {"x.sh", 3, "new two"}, {"x.sh", 10, "tail"}}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("got %+v\nwant %+v", got, want)
	}
}

// Intended divergence: an added line whose own text looks like a file header is still an added line of the file it
// sits in (the awk of the bash tool reset the current file at it and mis-attributed every line after it).
func TestAddedLineThatLooksLikeAFileHeader(t *testing.T) {
	diff := "diff --git a/a.sh b/a.sh\n--- a/a.sh\n+++ b/a.sh\n@@ -0,0 +1,2 @@\n+++ b/notes.md\n+pkill -f x\n"
	got := parseAdded(diff)
	want := []addedLine{{"a.sh", 1, "++ b/notes.md"}, {"a.sh", 2, "pkill -f x"}}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("got %+v\nwant %+v", got, want)
	}
}

// Intended divergence: a path with a space (git ends the header with a tab) or a quoted path is read whole.
func TestHeaderPathsWithSpacesAndQuotes(t *testing.T) {
	for in, want := range map[string]string{
		"b/my file.sh\t":            "my file.sh",
		`"b/tab\there.sh"`:          "tab\there.sh",
		`"b/caf\303\251.sh"`:        "café.sh",
		"/dev/null":                 "/dev/null",
		"b/plain.sh":                "plain.sh",
		`"b/unterminated`:           `"b/unterminated`,
		"b/dir with space/x y.py\t": "dir with space/x y.py",
	} {
		if got := headerPath(in); got != want {
			t.Errorf("headerPath(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestHunkCounts(t *testing.T) {
	for in, want := range map[string][3]int{
		"@@ -1 +1 @@":         {1, 1, 1},
		"@@ -3,2 +5,4 @@ ctx": {5, 2, 4},
		"@@ -7,0 +8,0 @@":     {8, 0, 0},
		"@@ nonsense":         {0, 0, 0},
		"@@ -x +y @@":         {0, 1, 1},
	} {
		a, b, c := hunkCounts(in)
		if [3]int{a, b, c} != want {
			t.Errorf("hunkCounts(%q) = %d,%d,%d want %v", in, a, b, c, want)
		}
	}
}

func TestScannedExtensions(t *testing.T) {
	for f, want := range map[string][2]bool{
		"a.sh": {true, false}, "a.bash": {true, false}, "a.py": {true, true}, "a.mjs": {true, true},
		"a.cjs": {true, true}, "a.js": {true, true}, "a.ts": {true, true}, "a.md": {false, false},
		"a.txt": {false, false}, "sh": {false, false}, "a.sh.bak": {false, false},
	} {
		scan, script := scanned(f)
		if [2]bool{scan, script} != want {
			t.Errorf("scanned(%q) = %v,%v want %v", f, scan, script, want)
		}
	}
}

func TestScriptOnlyForms(t *testing.T) {
	if isNameKill(`x = ["pkill", "-f", "y"]`, false) {
		t.Error("the argv-list form is a kill only in python/js/ts")
	}
	if !isNameKill(`x = ["pkill", "-f", "y"]`, true) {
		t.Error("the argv-list form must be a kill in a script")
	}
	if isNameKill(`os.system("pkill x")  # writer-check: allow-name-kill reaper`, true) {
		t.Error("the allow marker must opt a line out")
	}
	if isNameKill(`  // pkill -f x`, true) {
		t.Error("a comment-only line is never scanned")
	}
}

// Intended divergence: leading blanks are ignored, a blank line is skipped, a reason keeps its tabs.
func TestParseWaivers(t *testing.T) {
	text := "# header\n\n   \n  # indented comment\nsuite/a.test.sh why\tnot\n  suite/b.test.sh   spaced reason  \nsuite/c.test.sh\nsuite/a.test.sh second\nsuite/d.test.sh   \n"
	w := parseWaivers(text)
	wantReasons := map[string]string{"suite/a.test.sh": "why\tnot", "suite/b.test.sh": "spaced reason  "}
	if !reflect.DeepEqual(w.reasons, wantReasons) {
		t.Errorf("reasons %q, want %q", w.reasons, wantReasons)
	}
	wantBad := []finding{
		{"bad-waiver", "writer-check-waivers.txt:7", "no reason for suite/c.test.sh"},
		{"bad-waiver", "writer-check-waivers.txt:9", "no reason for suite/d.test.sh"},
	}
	if !reflect.DeepEqual(w.findings, wantBad) {
		t.Errorf("findings %+v, want %+v", w.findings, wantBad)
	}
	if got := parseWaivers(""); len(got.reasons)+len(got.findings) != 0 {
		t.Errorf("an empty list waives nothing: %+v", got)
	}
}

func TestTimeoutSeconds(t *testing.T) {
	for in, want := range map[string]struct {
		n  int64
		ok bool
	}{
		"": {900, true}, "1": {1, true}, "900": {900, true}, "0": {0, false}, "08": {0, false}, "abc": {0, false}, "1x": {0, false},
		"-3": {0, false}, "99999999999999999999": {1 << 31, true},
	} {
		if n, ok := timeoutSeconds(in); n != want.n || ok != want.ok {
			t.Errorf("timeoutSeconds(%q) = %d,%v want %d,%v", in, n, ok, want.n, want.ok)
		}
	}
}

func TestJSONEscape(t *testing.T) {
	if got, want := jsonEscape("a\\b\"c\td\ne"), "a\\\\b\\\"c d\ne"; got != want {
		t.Errorf("jsonEscape = %q, want %q", got, want)
	}
}

func TestCheckLogVerdicts(t *testing.T) {
	const h = "# writer-check: head=abc tree=0123456789012345678901234567890123456789"
	dir := t.TempDir()
	put := func(body string) {
		writeFile(t, dir+"/"+logName("s.test.sh"), body)
	}
	cases := []struct{ name, body, kind, why string }{
		{"valid", h + "\n-- teeth --\n== 3 passed · 0 failed ==\n", "", ""},
		{"other tree", strings.Replace(h, "0123", "9999", 1) + "\n-- teeth --\n== 3 passed · 0 failed ==\n", stale, "changed files differ"},
		{"failed", h + "\n-- teeth --\n== 2 passed · 1 failed ==\n", missing, "summary reports failures: == 2 passed · 1 failed =="},
		{"zero", h + "\n-- teeth --\n== 0 passed · 0 failed ==\n", missing, "summary reports zero passed cases"},
		{"no banner", h + "\n== 3 passed · 0 failed ==\n", missing, "plain run: no teeth banner"},
		{"fail line", h + "\n-- teeth --\n  FAIL  x\n== 3 passed · 0 failed ==\n", missing, "log contains a FAIL line"},
		{"no summary", h + "\n-- teeth --\n", missing, "no summary line"},
		{"no header", "-- teeth --\n== 3 passed · 0 failed ==\n", stale, "no writer-check header"},
	}
	for _, c := range cases {
		put(c.body)
		kind, why := checkLog(dir, "s.test.sh", h)
		if kind != c.kind || !strings.HasPrefix(why, c.why) {
			t.Errorf("%s: got %q %q, want %q %q", c.name, kind, why, c.kind, c.why)
		}
	}
	if kind, why := checkLog(dir, "absent.test.sh", h); kind != missing || why != "no log absent.test.sh.log" {
		t.Errorf("absent log: %q %q", kind, why)
	}
	if kind, why := checkLog("", "s.test.sh", h); kind != missing || why != "no --teeth-log given" {
		t.Errorf("no dir: %q %q", kind, why)
	}
}
