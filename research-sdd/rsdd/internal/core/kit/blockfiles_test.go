package kit

import (
	"errors"
	"reflect"
	"testing"
)

// Ports of toolbelt/tests/block-files.test.sh, filter half (kit issue U11).

type filterCase struct {
	label   string
	invert  bool
	prefix  string
	in      []string
	want    []string
	wantErr error
}

// filterCases is shared with the differential test.
var filterCases = []filterCase{
	{"1 canonical block1", false, "", []string{"/corpus/tema3-block1.md"}, []string{"/corpus/tema3-block1.md"}, nil},
	{"2 canonical bloque12", false, "", []string{"/corpus/prefix-bloque12.md"}, []string{"/corpus/prefix-bloque12.md"}, nil},
	{"3 suffix", false, "", []string{"/corpus/ab-block3-foo-bar.md"}, []string{"/corpus/ab-block3-foo-bar.md"}, nil},
	{"4 decoy blocked-notes", false, "", []string{"/corpus/blocked-notes.md"}, nil, ErrNoMatch},
	{"5 decoy block12 without prefix (TOOTH-2)", false, "", []string{"/corpus/block12.md"}, nil, ErrNoMatch},
	{"6 single-char prefix", false, "", []string{"/corpus/x-bloque3.md"}, []string{"/corpus/x-bloque3.md"}, nil},
	{"6b no prefix-dash", false, "", []string{"/corpus/bloque3.md"}, nil, ErrNoMatch},
	{"7 nested retros (TOOTH-1)", false, "", []string{"/corpus/retros/subfocus-block5.md"}, []string{"/corpus/retros/subfocus-block5.md"}, nil},
	{"8 bare filename", false, "", []string{"prefix-block7.md"}, []string{"prefix-block7.md"}, nil},
	{"5a prefix keeps its focus", false, "tema3-", []string{"/corpus/tema3-block1.md", "/corpus/tema4-block2.md"}, []string{"/corpus/tema3-block1.md"}, nil},
	{"5b prefix keeps its focus", false, "tema4-", []string{"/corpus/tema3-block1.md", "/corpus/tema4-block2.md"}, []string{"/corpus/tema4-block2.md"}, nil},
	{"6a -v", true, "", []string{"/corpus/blocked-notes.md", "/corpus/tema3-block1.md"}, []string{"/corpus/blocked-notes.md"}, nil},
	{"-v all canonical", true, "", []string{"/c/a-block1.md"}, nil, ErrNoMatch},
	{"empty input", false, "", nil, nil, ErrEmptyInput},
	{"empty line", false, "", []string{""}, nil, ErrNoMatch},
	{"-v empty line passes", true, "", []string{""}, []string{""}, nil},
	{"a block number is required", false, "", []string{"/c/a-block.md", "/c/a-bloque-x.md"}, nil, ErrNoMatch},
	{"suffix must follow a dash", false, "", []string{"/c/a-block1x.md"}, nil, ErrNoMatch},
	{"suffix charset", false, "", []string{"/c/a-block1-a.b.md", "/c/a-block1-é.md", "/c/a-block1-a_b-C9.md"}, []string{"/c/a-block1-a_b-C9.md"}, nil},
	{"anchored at the end", false, "", []string{"/c/a-block1.md.bak", "/c/a-block1.md\r"}, nil, ErrNoMatch},
	{"block in a directory name only", false, "", []string{"/c/a-block1.md/x"}, nil, ErrNoMatch},
	{"prefix is a regex (dot)", false, "t.", []string{"/c/tXblock1.md", "/c/t-block1.md", "/c/tblock1.md"}, []string{"/c/tXblock1.md", "/c/t-block1.md"}, nil},
	{"prefix anchored after slash", false, "a-", []string{"/c/ba-block1.md", "/c/a-block1.md"}, []string{"/c/a-block1.md"}, nil},
	{"prefix alternation is unescaped", false, "x|y", []string{"/c/y-not-block.md", "/c/yblock2.md"}, []string{"/c/yblock2.md"}, nil},
	{"invalid prefix regex", false, "(", []string{"/c/a-block1.md"}, nil, ErrBadPattern},
	{"invalid prefix regex -v", true, "(", []string{"/c/a-block1.md"}, nil, ErrBadPattern},
	{"repeat of the anchor group", false, "+", []string{"/c/a-block1.md", "/c/+block1.md"}, nil, ErrNoMatch},
	{"invalid character class", false, "[[:foo:]]", []string{"/c/a-block1.md"}, nil, ErrBadPattern},
	{"open bracket swallows the tail into a class", false, "[", []string{"/c/a-block1.md", "/c/[block1.md"}, []string{"/c/[block1.md"}, nil},
	{"non-UTF-8 prefix byte", false, "", []string{"/c/\xff-block1.md"}, []string{"/c/\xff-block1.md"}, nil},
}

func TestFilterBlockFiles(t *testing.T) {
	for _, c := range filterCases {
		t.Run(c.label, func(t *testing.T) {
			got, err := FilterBlockFiles(c.in, c.invert, c.prefix)
			if !errors.Is(err, c.wantErr) || (c.wantErr == nil) != (err == nil) {
				t.Fatalf("err = %v, want %v", err, c.wantErr)
			}
			if !reflect.DeepEqual(got, c.want) {
				t.Fatalf("got %q, want %q", got, c.want)
			}
		})
	}
}

func TestFilterBlockFilesRC(t *testing.T) {
	for err, want := range map[error]int{nil: 0, ErrNoMatch: 1, ErrEmptyInput: 1, ErrBadPattern: 2} {
		if RC(err) != want {
			t.Errorf("RC(%v) = %d, want %d", err, RC(err), want)
		}
	}
}

func TestSplitLines(t *testing.T) {
	for in, want := range map[string][]string{
		"":         nil,
		"\n":       {""},
		"a":        {"a"},
		"a\n":      {"a"},
		"a\nb":     {"a", "b"},
		"a\n\nb\n": {"a", "", "b"},
	} {
		if got := SplitLines(in); !reflect.DeepEqual(got, want) {
			t.Errorf("SplitLines(%q) = %q, want %q", in, got, want)
		}
	}
}
