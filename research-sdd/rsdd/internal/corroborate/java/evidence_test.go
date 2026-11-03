package java

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestSplitLinesFollowsPythonStrSplitlines(t *testing.T) {
	cases := []struct {
		in   string
		want []string
	}{
		{"", nil},
		{"a", []string{"a"}},
		{"a\n", []string{"a"}},
		{"a\n\nb", []string{"a", "", "b"}},
		{"a\r\nb\rc\nd", []string{"a", "b", "c", "d"}},
		{"a\vb\fc\x1cd\x1de\x1ef", []string{"a", "b", "c", "d", "e", "f"}},
		{"a\u0085b c d", []string{"a", "b", "c", "d"}},
		{"a\x1fb", []string{"a\x1fb"}}, // \x1f is white space for strip(), not a line break
		{"\n", []string{""}},
		{"\r\n\r\n", []string{"", ""}},
	}
	for _, c := range cases {
		if got := splitLines(c.in); !reflect.DeepEqual(got, c.want) {
			t.Errorf("splitLines(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestPySpaceIncludesTheSeparatorsUnicodeAlsoCounts(t *testing.T) {
	for _, r := range []rune{' ', '\t', '\n', '\v', '\f', '\r', 0x1c, 0x1d, 0x1e, 0x1f, 0x85, 0xa0, 0x2003, 0x3000} {
		if !pySpace(r) {
			t.Errorf("%U must be white space", r)
		}
	}
	for _, r := range []rune{'a', '0', ';', 0x200b} {
		if pySpace(r) {
			t.Errorf("%U must not be white space", r)
		}
	}
}

func TestSignaturesKeepSemicolonLinesAndDescriptorsSortedDistinct(t *testing.T) {
	p := filepath.Join(t.TempDir(), "javap.txt")
	body := "public final class fixture.App {\n  public static void main(java.lang.String[]);\n    descriptor: ([Ljava/lang/String;)V\n" +
		"  public static void main(java.lang.String[]);\n\t   z;  \n  not a signature\n}\n"
	if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	got, err := signatures(p)
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"descriptor: ([Ljava/lang/String;)V", "public static void main(java.lang.String[]);", "z;"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("signatures = %q, want %q", got, want)
	}
}

func TestDependencyLinesAreSortedDistinctAndNonEmpty(t *testing.T) {
	p := filepath.Join(t.TempDir(), "jdeps.txt")
	if err := os.WriteFile(p, []byte("b -> x\n\n  a -> y  \nb -> x\n\xff\xfe bad bytes\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	got, err := dependencyLines(p)
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"a -> y", "b -> x", "� bad bytes"}
	// invalid UTF-8 is replaced, as read_text(errors="replace") does, before the line is split and stripped
	if len(got) != 3 || got[0] != want[0] || got[1] != want[1] || got[2] != "� bad bytes" {
		t.Fatalf("dependencyLines = %q", got)
	}
	if _, err := dependencyLines(filepath.Join(t.TempDir(), "absent")); err == nil {
		t.Error("a missing file is an error, not an empty list")
	}
}

func TestCoverageCountsInnerClassesThroughTheirOutermostSource(t *testing.T) {
	inv := []outputRecord{{path: "p/A.java"}, {path: "p/B.txt"}, {path: "q/C.java"}}
	got := coverage([]string{"p.A", "p.A$Inner", "p.B", "q.C$1$2", "r.D"}, inv)
	if !reflect.DeepEqual(got["covered"], []string{"p.A", "p.A$Inner", "q.C$1$2"}) ||
		!reflect.DeepEqual(got["missing"], []string{"p.B", "r.D"}) || got["covered_count"] != 3 || got["expected_count"] != 5 {
		t.Fatalf("coverage = %v", got)
	}
	empty := coverage([]string{}, nil)
	if empty["covered"] == nil || empty["missing"] == nil || empty["covered_count"] != 0 {
		t.Errorf("empty coverage = %v", empty)
	}
}

func TestComparisonsPairDecompilersInFixedOrder(t *testing.T) {
	engines := map[string][]outputRecord{
		"procyon":    {{path: "a", sha256: "1"}, {path: "p", sha256: "9"}},
		"vineflower": {{path: "a", sha256: "1"}, {path: "b", sha256: "2"}, {path: "v", sha256: "3"}},
		"cfr":        {{path: "a", sha256: "1"}, {path: "b", sha256: "X"}},
	}
	got := comparisons(engines)
	if len(got) != 3 {
		t.Fatalf("%d comparisons", len(got))
	}
	order := [][]string{{"vineflower", "cfr"}, {"vineflower", "procyon"}, {"cfr", "procyon"}}
	for i, c := range got {
		if !reflect.DeepEqual(c["engines"], order[i]) {
			t.Errorf("pair %d = %v, want %v", i, c["engines"], order[i])
		}
	}
	vc := got[0]
	if !reflect.DeepEqual(vc["common_paths"], []string{"a", "b"}) || !reflect.DeepEqual(vc["same_hash_paths"], []string{"a"}) ||
		!reflect.DeepEqual(vc["different_hash_paths"], []string{"b"}) || !reflect.DeepEqual(vc["only_left"], []string{"v"}) ||
		!reflect.DeepEqual(vc["only_right"], []string{}) {
		t.Errorf("vineflower/cfr = %v", vc)
	}
	d := disagreements(got)
	if len(d) != 3 {
		t.Errorf("every pair here disagrees, got %d", len(d))
	}
	agree := disagreements(comparisons(map[string][]outputRecord{
		"vineflower": {{path: "a", sha256: "1"}}, "cfr": {{path: "a", sha256: "1"}}, "procyon": {{path: "a", sha256: "1"}}}))
	if len(agree) != 0 || agree == nil {
		t.Errorf("full agreement must yield an empty, non-null list: %v", agree)
	}
}

func TestComparisonsSkipAnEngineThatIsAbsent(t *testing.T) {
	got := comparisons(map[string][]outputRecord{"vineflower": nil, "procyon": nil})
	if len(got) != 1 || !reflect.DeepEqual(got[0]["engines"], []string{"vineflower", "procyon"}) {
		t.Fatalf("comparisons = %v", got)
	}
}
