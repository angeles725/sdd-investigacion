package issuesdue

import (
	"fmt"
	"reflect"
	"strings"
	"testing"
)

func TestPrefixesAddTheLegacyDirectoryNameOnlyWhenItDiffers(t *testing.T) {
	for _, c := range []struct {
		name, path, target string
		want               []string
	}{
		{"registered target directory", "/rh/tgt/retros/r.md", "tgt", []string{"tgt/retros/r.md"}},
		{"a directory name that differs from the target", "/rh/sub/retros/r.md", "tgt", []string{"tgt/retros/r.md", "sub/retros/r.md"}},
		{"corpus is structural", "/rh/corpus/retros/r.md", "tgt", []string{"tgt/retros/r.md"}},
		{"retros is structural", "/rh/retros/retros/r.md", "tgt", []string{"tgt/retros/r.md"}},
	} {
		got := (&Retro{Path: c.path, Base: "r.md", Target: c.target}).Prefixes()
		if !reflect.DeepEqual(got, c.want) {
			t.Errorf("%s: Prefixes = %v, want %v", c.name, got, c.want)
		}
	}
}

func TestUntrackedKeepsRowOrderAndDuplicates(t *testing.T) {
	a := &Retro{OpenIDs: []string{"D3", "D1", "D2", "D3"}}
	if got, want := a.Untracked([]string{"D1", "D9"}), []string{"D3", "D2", "D3"}; !reflect.DeepEqual(got, want) {
		t.Errorf("Untracked = %v, want %v", got, want)
	}
	if got := a.Untracked([]string{"D3", "D1", "D2"}); got != nil {
		t.Errorf("Untracked of a fully tracked retro = %v, want nil", got)
	}
	if got := (&Retro{}).Untracked(nil); got != nil {
		t.Errorf("Untracked of a retro without open rows = %v, want nil", got)
	}
}

func TestNormalizeIsTheCommandSubstitutionOfACacheFile(t *testing.T) {
	for in, want := range map[string]string{"": "", "\n\n": "", "a\n\n": "a", "a\x00b\n": "ab", "\na": "\na", " a \n": " a "} {
		if got := Normalize(in); got != want {
			t.Errorf("Normalize(%q) = %q, want %q", in, got, want)
		}
	}
}

// Read gives every typed state to the sink, in order, and stops exactly where the legacy audit stopped.
func TestReadStopsAndNotes(t *testing.T) {
	for _, c := range []struct {
		name, retro string
		ok          bool
		open        []string
		noteHas     string
	}{
		{"open rows", tPending + tHead + tRows("D1", "D2"), true, []string{"D1", "D2"}, ""},
		{"an unrecognised status opens every row and says so", "<!-- review-status: odd -->\n# r\n\n" + tHead + tRows("D1"), true, []string{"D1"}, "WARN: unrecognised review-status 'odd' in r.md — treating all rows as open"},
		{"an id outside the signature alphabet", tPending + tHead + tRows("D@3", "D1"), true, []string{"D1"}, "row D@3 of r.md has a character outside [A-Za-z0-9_-] in its id (id-not-signature-safe)"},
		{"no delta section", "# r\n", false, nil, "empty-input: no delta section found in "},
		{"a section with no rows", tPending + "## Proposed kit deltas\n\nnothing to propose\n", false, nil, "unclassifiable: delta section found but contains neither row-table rows"},
	} {
		t.Run(c.name, func(t *testing.T) {
			b := newBox(t, "retros/r.md", c.retro, "")
			var notes []string
			add := func(f string, a ...any) { notes = append(notes, strings.TrimSpace(fmt.Sprintf(f, a...))) }
			r, ok := Read(b.retro, "tgt", Sink{Note: add, Degrade: add, Fail: add, OutOfScope: func(l string) { add("%s", l) }})
			if ok != c.ok {
				t.Fatalf("ok = %v, want %v (notes %q)", ok, c.ok, notes)
			}
			if ok && !reflect.DeepEqual(r.OpenIDs, c.open) {
				t.Errorf("OpenIDs = %v, want %v", r.OpenIDs, c.open)
			}
			if c.noteHas != "" && !strings.Contains(strings.Join(notes, "\n"), c.noteHas) {
				t.Errorf("notes %q lack %q", notes, c.noteHas)
			}
			if c.noteHas == "" && len(notes) != 0 {
				t.Errorf("unexpected notes %q", notes)
			}
		})
	}
}
