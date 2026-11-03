package verifyretro

import (
	"bytes"
	"context"
	"errors"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// These tests need no bash: they pin each decision of the port at its boundary, next to the golden replay.

func TestAsciiLowerFoldsExactlyAToZ(t *testing.T) {
	for in, want := range map[string]string{
		"AZaz": "azaz", "@[`{": "@[`{", "ABCDEFGHIJKLMNOPQRSTUVWXYZ": "abcdefghijklmnopqrstuvwxyz",
		"Kİ": "Kİ", // Kelvin sign and dotted capital I stay as they are
	} {
		if got := asciiLower(in); got != want {
			t.Errorf("asciiLower(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestLeadingBlock(t *testing.T) {
	for _, c := range []struct {
		name string
		raw  []string
		want []string
	}{
		{"empty file", nil, nil},
		{"comments and blanks", []string{"<!-- a -->", "", "  \t", " <!-- b -->", "x", "<!-- c -->"}, []string{"<!-- a -->", " <!-- b -->"}},
		{"first line is text", []string{"x", "<!-- a -->"}, nil},
		{"a bare comment opener counts", []string{"<!--"}, []string{"<!--"}},
		{"a near-miss opener ends the block", []string{"<!- a -->", "<!-- b -->"}, nil},
		{"CR-only line is blank", []string{"\r", "<!-- a -->"}, []string{"<!-- a -->"}},
		{"BOM is not stripped", []string{"\xef\xbb\xbf<!-- a -->"}, nil},
	} {
		if got := leadingBlock(c.raw); !reflect.DeepEqual(got, c.want) {
			t.Errorf("%s: leadingBlock = %q, want %q", c.name, got, c.want)
		}
	}
}

func TestStatusOf(t *testing.T) {
	for _, c := range []struct {
		name string
		lead []string
		want string
	}{
		{"none", nil, ""},
		{"word", []string{"<!-- review-status: Pending -->"}, "pending"},
		{"first line wins", []string{"<!-- review-status: applied -->", "<!-- review-status: pending -->"}, "applied"},
		{"first match on a line wins", []string{"<!-- review-status: applied --><!-- review-status: pending -->"}, "applied"},
		{"a line without a letter word is skipped", []string{"<!-- review-status: 1 -->", "<!-- review-status: dismissed -->"}, "dismissed"},
		{"the word stops at the first non-letter", []string{"<!-- review-status: a-b -->"}, "a"},
		{"no space needed", []string{"<!--review-status:z-->"}, "z"},
		{"tab and space before the word", []string{"<!-- review-status: \t x"}, "x"},
	} {
		if got := statusOf(c.lead); got != c.want {
			t.Errorf("%s: statusOf = %q, want %q", c.name, got, c.want)
		}
	}
}

func TestExcluded(t *testing.T) {
	for line, want := range map[string]bool{
		"<!-- kit-retro: exclude -->":          true,
		"  <!-- KIT-RETRO:EXCLUDE-->":          true,
		"<!-- kit-retro: exclude --> trailing": true,
		"x <!-- kit-retro: exclude -->":        false,
		"<!-- kit-retro: exclude":              false,
		"<!-- kit-retro: include -->":          false,
		"<!-- Kit-retro: exclude -->":          false,
		"<!-- retro: exclude -->":              false,
	} {
		if got := excluded([]string{line}); got != want {
			t.Errorf("excluded(%q) = %v, want %v", line, got, want)
		}
	}
	if excluded(nil) {
		t.Error("an empty block excludes nothing")
	}
	if !excluded([]string{"<!-- a -->", "<!-- kit-retro: exclude -->"}) {
		t.Error("the opt-out may sit on any line of the block")
	}
}

func TestAnyPrefixAndMention(t *testing.T) {
	raw := []string{"x", "# Retro — y", " # Retro - z"}
	if !anyPrefix(raw, "# Retro —") || anyPrefix(raw, "# Retro -") || anyPrefix(nil, "#") {
		t.Error("anyPrefix must match line starts only, over every line")
	}
	if !mentionsNoNewDeltas([]string{"a", "x NO New DELTAS y"}) || mentionsNoNewDeltas([]string{"no new", "deltas"}) || mentionsNoNewDeltas(nil) {
		t.Error("mentionsNoNewDeltas must fold ASCII case inside a line, never across lines")
	}
}

func TestRunOperationalAndUsage(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := Run(ctx, Options{Args: []string{"x.md"}}); !errors.Is(err, context.Canceled) {
		t.Errorf("a cancelled context must be an operational error, got %v", err)
	}
	for _, args := range [][]string{nil, {}, {"a.md", "b.md"}} {
		rep, err := Run(context.Background(), Options{Args: args})
		if err != nil || rep.State != StateUsage {
			t.Errorf("args %q: state %v, err %v; want StateUsage", args, rep.State, err)
		}
	}
}

func TestRunStatesAreDistinct(t *testing.T) {
	dir := t.TempDir()
	mustWrite(t, filepath.Join(dir, "ok.md"), cConform)
	mustWrite(t, filepath.Join(dir, "bad.md"), "nothing\n")
	mustWrite(t, filepath.Join(dir, "skip.md"), "<!-- kit-retro: exclude -->\n")
	mustWrite(t, filepath.Join(dir, "notes.txt"), cConform)
	mustMkdir(t, filepath.Join(dir, "d.md"))
	for arg, want := range map[string]State{
		"ok.md": StateConforming, "bad.md": StateNonConforming, "skip.md": StateExcluded,
		"notes.txt": StateNotMarkdown, "gone.md": StateAbsent, "gone.txt": StateAbsent, "d.md": StateAbsent, "": StateAbsent,
	} {
		rep, err := Run(context.Background(), Options{Args: []string{arg}, Cwd: dir})
		if err != nil || rep.State != want || rep.Arg != arg {
			t.Errorf("%q: state %v arg %q err %v; want state %v", arg, rep.State, rep.Arg, err, want)
		}
	}
	// An absolute argument ignores Cwd; a relative one needs it.
	if rep, _ := Run(context.Background(), Options{Args: []string{filepath.Join(dir, "ok.md")}, Cwd: "/nonexistent"}); rep.State != StateConforming {
		t.Errorf("absolute path with a bogus Cwd: state %v", rep.State)
	}
}

func TestFindingsOrderAndFailCounting(t *testing.T) {
	// marker, title, delta: the script's order; a WARN alone must not fail the retro.
	rep, _ := Run(context.Background(), Options{Args: []string{"x.md"}, Cwd: writeDir(t, "x.md", "# Retro - t\n\n"+cTable)})
	var classes []string
	for _, f := range rep.Findings {
		classes = append(classes, f.Level+":"+f.Class)
	}
	if want := []string{"FAIL:marker-missing", "WARN:header-punctuation"}; !reflect.DeepEqual(classes, want) || rep.State != StateNonConforming {
		t.Errorf("findings %v state %v, want %v NonConforming", classes, rep.State, want)
	}
	rep, _ = Run(context.Background(), Options{Args: []string{"x.md"}, Cwd: writeDir(t, "x.md", cMark+"# Retro - t\n\n"+cTable)})
	if len(rep.Findings) != 1 || rep.State != StateConforming {
		t.Errorf("a lone WARN must conform: %+v", rep)
	}
	rep, _ = Run(context.Background(), Options{Args: []string{"x.md"}, Cwd: writeDir(t, "x.md", "no\n")})
	classes = nil
	for _, f := range rep.Findings {
		classes = append(classes, f.Class)
	}
	if want := []string{"marker-missing", "header-missing", "absent-section"}; !reflect.DeepEqual(classes, want) {
		t.Errorf("classes %v, want %v", classes, want)
	}
}

func writeDir(t *testing.T, name, content string) string {
	t.Helper()
	dir := t.TempDir()
	mustWrite(t, filepath.Join(dir, name), content)
	return dir
}

func TestRenderEachState(t *testing.T) {
	for _, c := range []struct {
		name     string
		rep      Report
		rc       int
		out, err string
	}{
		{"usage", Report{State: StateUsage}, 2, "", "Usage: verify-retro.sh <retro.md>\n  exit 0 = conforming, exit 1 = non-conforming, exit 2 = bad args\n"},
		{"absent", Report{State: StateAbsent, Arg: "a b.md"}, 2, "", "ERROR: file not found (absent-input): a b.md\n"},
		{"not markdown", Report{State: StateNotMarkdown, Arg: "a.txt"}, 2, "", "ERROR: argument must be a .md file: a.txt\n"},
		{"unreadable", Report{State: StateUnreadable, Arg: "a.md"}, 2, "", "ERROR: file not readable (absent-input): a.md\n"},
		{"excluded", Report{State: StateExcluded}, 0, "OK: kit-retro: exclude — declared non-kit retro, conforming/skipped\n", ""},
		{"conforming", Report{State: StateConforming}, 0, "OK: conforming\n", ""},
		{"conforming with a warning and a fence line", Report{State: StateConforming, FenceWarning: "WARN: f\n", Findings: []Finding{{"WARN", "c", "t %s", []string{"  l1", "  l2"}}}}, 0,
			"WARN [c]: t %s\n  l1\n  l2\nOK: conforming\n", "WARN: f\n"},
		{"non conforming has no OK line", Report{State: StateNonConforming, Findings: []Finding{{"FAIL", "c", "t", nil}}}, 1, "FAIL [c]: t\n", ""},
	} {
		var so, se bytes.Buffer
		if rc := c.rep.Render(&so, &se); rc != c.rc || so.String() != c.out || se.String() != c.err {
			t.Errorf("%s: rc %d out %q err %q; want rc %d out %q err %q", c.name, rc, so.String(), se.String(), c.rc, c.out, c.err)
		}
	}
}

func TestCommandWiring(t *testing.T) {
	if Command.Group != "retro" || Command.Name != "verify" || Command.Run == nil || Command.Summary == "" {
		t.Errorf("registry entry: %+v", Command)
	}
	dir := writeDir(t, "r.md", cConform)
	var so, se bytes.Buffer
	rc := cli.Run([]cli.Command{Command}, []string{"retro", "verify", "r.md"}, cli.Stdio{Out: &so, Err: &se, Cwd: dir})
	if rc != 0 || so.String() != "OK: conforming\n" || se.Len() != 0 {
		t.Errorf("rc %d out %q err %q", rc, so.String(), se.String())
	}
	// Arguments after the command name are the script's arguments: --help is a missing file, not the help text.
	so.Reset()
	se.Reset()
	rc = cli.Run([]cli.Command{Command}, []string{"retro", "verify", "--help"}, cli.Stdio{Out: &so, Err: &se, Cwd: dir})
	if rc != 2 || !strings.HasPrefix(se.String(), "ERROR: file not found (absent-input): --help") {
		t.Errorf("rc %d err %q", rc, se.String())
	}
}

func TestRunCommandReportsAnOperationalError(t *testing.T) {
	// Run only fails on a cancelled context, which RunCommand never passes; the path stays covered by Run's test.
	var so, se bytes.Buffer
	if rc := RunCommand(nil, cli.Stdio{Out: &so, Err: &se}); rc != 2 || !strings.HasPrefix(se.String(), "Usage: verify-retro.sh") {
		t.Errorf("rc %d err %q", rc, se.String())
	}
}
