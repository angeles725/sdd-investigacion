package kit

import (
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

// Ports of toolbelt/tests/state-files.test.sh (kit issue #1818).

func stateFixture(t *testing.T, rels ...string) string {
	t.Helper()
	root := t.TempDir()
	mkfiles(t, root, rels...)
	return root
}

type stateCase struct {
	label   string
	files   []string
	opt     ResolveOptions
	want    string // relative to the fixture, "" for none
	wantErr error
}

// stateCases is shared with the differential test.
var stateCases = []stateCase{
	{"1 root only", []string{"RESEARCH-STATE.md"}, ResolveOptions{}, "RESEARCH-STATE.md", nil},
	{"2 single focus only", []string{"RESEARCH-STATE-auth.md"}, ResolveOptions{}, "RESEARCH-STATE-auth.md", nil},
	{"3 flat root + focus: ROOT wins", []string{"RESEARCH-STATE-auth.md", "RESEARCH-STATE.md"}, ResolveOptions{}, "RESEARCH-STATE.md", nil},
	{"3b root + 3 focuses (before and after the root alphabetically)", []string{"RESEARCH-STATE-aaa.md", "RESEARCH-STATE-mmm.md", "RESEARCH-STATE.md", "RESEARCH-STATE-zzz.md"}, ResolveOptions{}, "RESEARCH-STATE.md", nil},
	{"4 multi-focus without root: C-first", []string{"RESEARCH-STATE-zeta.md", "RESEARCH-STATE-alpha.md"}, ResolveOptions{}, "RESEARCH-STATE-alpha.md", nil},
	{"5 nested: root beats focus", []string{"corpus/RESEARCH-STATE-arch.md", "corpus/RESEARCH-STATE.md"}, ResolveOptions{}, "corpus/RESEARCH-STATE.md", nil},
	{"6 shallowest wins", []string{"RESEARCH-STATE-top.md", "corpus/RESEARCH-STATE.md"}, ResolveOptions{}, "RESEARCH-STATE-top.md", nil},
	{"7 beyond maxdepth 3 is absent", []string{"a/b/c/RESEARCH-STATE.md"}, ResolveOptions{}, "", ErrStateAbsent},
	{"7b depth 3 is found", []string{"a/b/RESEARCH-STATE.md"}, ResolveOptions{}, "a/b/RESEARCH-STATE.md", nil},
	{"8 no state files", []string{"keep.txt"}, ResolveOptions{}, "", ErrStateAbsent},
	{"9 template alone is absent", []string{"RESEARCH-STATE.template.md"}, ResolveOptions{}, "", ErrStateAbsent},
	{"9b template never wins", []string{"RESEARCH-STATE.template.md", "RESEARCH-STATE-x.md"}, ResolveOptions{}, "RESEARCH-STATE-x.md", nil},
	{"10 .git content excluded", []string{".git/RESEARCH-STATE.md"}, ResolveOptions{}, "", ErrStateAbsent},
	{"11 --focus selects the focus file", []string{"RESEARCH-STATE-auth.md", "RESEARCH-STATE.md"}, ResolveOptions{FocusSet: true, Focus: "auth"}, "RESEARCH-STATE-auth.md", nil},
	{"11b --focus unknown slug", []string{"RESEARCH-STATE-auth.md", "RESEARCH-STATE.md"}, ResolveOptions{FocusSet: true, Focus: "nope"}, "", ErrStateAbsent},
	{"11d --focus ab does not match abc", []string{"RESEARCH-STATE-ab.md", "RESEARCH-STATE-abc.md"}, ResolveOptions{FocusSet: true, Focus: "ab"}, "RESEARCH-STATE-ab.md", nil},
	{"12 empty --focus slug", []string{"RESEARCH-STATE.md"}, ResolveOptions{FocusSet: true}, "", ErrStateUsage},
	{"13 two roots, different dirs: ambiguous + first pick", []string{"a/RESEARCH-STATE.md", "b/RESEARCH-STATE.md"}, ResolveOptions{}, "a/RESEARCH-STATE.md", ErrStateAmbiguous},
	{"14 ambiguity: odd dir LAST", []string{"a/RESEARCH-STATE-x.md", "a/RESEARCH-STATE-y.md", "b/RESEARCH-STATE-z.md"}, ResolveOptions{}, "a/RESEARCH-STATE-x.md", ErrStateAmbiguous},
	{"14b ambiguity: odd dir FIRST", []string{"a/RESEARCH-STATE-a.md", "b/RESEARCH-STATE-b.md", "b/RESEARCH-STATE-c.md"}, ResolveOptions{}, "a/RESEARCH-STATE-a.md", ErrStateAmbiguous},
	{"14c ambiguity: three dirs", []string{"a/RESEARCH-STATE-a.md", "b/RESEARCH-STATE-b.md", "c/RESEARCH-STATE-c.md"}, ResolveOptions{}, "a/RESEARCH-STATE-a.md", ErrStateAmbiguous},
	{"15 different ranks in different dirs are not ambiguous", []string{"a/RESEARCH-STATE.md", "b/RESEARCH-STATE-x.md"}, ResolveOptions{}, "a/RESEARCH-STATE.md", nil},
}

func TestResolveStateFile(t *testing.T) {
	for _, c := range stateCases {
		t.Run(c.label, func(t *testing.T) {
			root := stateFixture(t, c.files...)
			got, err := ResolveStateFile(root, c.opt)
			if !errors.Is(err, c.wantErr) && !(c.wantErr == nil && err == nil) {
				t.Fatalf("err = %v, want %v", err, c.wantErr)
			}
			want := ""
			if c.want != "" {
				want = filepath.Join(root, c.want)
			}
			if got != want {
				t.Fatalf("path = %q, want %q", got, want)
			}
		})
	}
}

func TestResolveStateFileUsageStates(t *testing.T) { // 12b: a missing dir is usage (rc 3), not absent (rc 1)
	if _, err := ResolveStateFile(filepath.Join(t.TempDir(), "nope"), ResolveOptions{}); !errors.Is(err, ErrStateUsage) || RC(err) != 3 {
		t.Errorf("missing dir: %v rc=%d", err, RC(err))
	}
	if _, err := ResolveStateFile("", ResolveOptions{}); !errors.Is(err, ErrStateUsage) {
		t.Errorf("empty dir arg: %v", err)
	}
	f := write(t, filepath.Join(t.TempDir(), "file"), "")
	if _, err := ResolveStateFile(f, ResolveOptions{}); !errors.Is(err, ErrStateUsage) {
		t.Errorf("a file is not a directory: %v", err)
	}
	if RC(ErrStateAbsent) != 1 || RC(ErrStateAmbiguous) != 2 || RC(nil) != 0 {
		t.Errorf("rc map: %d %d %d", RC(ErrStateAbsent), RC(ErrStateAmbiguous), RC(nil))
	}
}

func TestListStateFiles(t *testing.T) {
	root := stateFixture(t, "RESEARCH-STATE.md", "RESEARCH-STATE-b.md", "RESEARCH-STATE.template.md", "x.template.md",
		".git/RESEARCH-STATE-g.md", "corpus/RESEARCH-STATE-a.md", "a/b/RESEARCH-STATE-d3.md", "a/b/c/RESEARCH-STATE-d4.md", "notes.md")
	got, err := ListStateFiles(root)
	if err != nil {
		t.Fatal(err)
	}
	var want []string
	for _, r := range []string{"RESEARCH-STATE-b.md", "RESEARCH-STATE.md", "a/b/RESEARCH-STATE-d3.md", "corpus/RESEARCH-STATE-a.md"} {
		want = append(want, filepath.Join(root, r))
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %q\nwant %q", got, want) // '-' (0x2d) sorts before '.' (0x2e): the focus file precedes the root
	}
}

func TestListStateFilesAbsentEmptyAndNoMatchAreDistinct(t *testing.T) { // section 7
	if _, err := ListStateFiles(filepath.Join(t.TempDir(), "nope")); !errors.Is(err, ErrAbsentInput) {
		t.Errorf("absent dir must be typed (bash returns rc 0 and nothing, finding F6): %v", err)
	}
	if got, err := ListStateFiles(t.TempDir()); err != nil || len(got) != 0 {
		t.Errorf("empty dir: %q %v", got, err)
	}
	if got, err := ListStateFiles(stateFixture(t, "a.md")); err != nil || len(got) != 0 {
		t.Errorf("no match: %q %v", got, err)
	}
}

func TestSymlinkedDirNeedsFollowDir(t *testing.T) { // the -H flag of resolve_state_file
	real := stateFixture(t, "RESEARCH-STATE.md")
	link := filepath.Join(t.TempDir(), "link")
	if err := os.Symlink(real, link); err != nil {
		t.Fatal(err)
	}
	if _, err := ResolveStateFile(link, ResolveOptions{}); !errors.Is(err, ErrStateAbsent) {
		t.Errorf("without -H a symlinked dir is not descended: %v", err)
	}
	got, err := ResolveStateFile(link, ResolveOptions{FollowDir: true})
	if err != nil || got != filepath.Join(link, "RESEARCH-STATE.md") {
		t.Errorf("-H: %q %v", got, err)
	}
}

func TestDirectoriesAndGitAncestorQuirks(t *testing.T) {
	// find has no -type filter: a DIRECTORY named like a state file is listed (bash behaviour, finding F7).
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "RESEARCH-STATE-dir.md"), 0o755); err != nil {
		t.Fatal(err)
	}
	if got, _ := ListStateFiles(root); len(got) != 1 {
		t.Errorf("dir named like a state file: %q", got)
	}
	// `-not -path '*/.git/*'` tests the WHOLE printed path, start included: a corpus living under a .git
	// directory has every result excluded.
	under := stateFixture(t, ".git/corpus/RESEARCH-STATE.md")
	if got, _ := ListStateFiles(filepath.Join(under, ".git", "corpus")); len(got) != 0 {
		t.Errorf("start under .git: %q", got)
	}
}
