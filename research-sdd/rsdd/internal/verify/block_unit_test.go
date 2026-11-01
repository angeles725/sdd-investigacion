//go:build unix

package verify

import (
	"os"
	"os/exec"
	"sort"
	"strings"
	"testing"
)

// Unit tests of the verify-block helpers: the extension lists, the shell-compatible primitives (checked
// against the real dirname and basename), and the guards the case table cannot reach by output alone.

// TestBlockExts pins the invariants tests/fixtures/verify-block/exts-invariants.sh used to check on the text of
// the script (kit #1721/#1742): no duplicate extension, vbTLDs is a subset of vbFileExts, every TLD of a frozen
// list of common TLDs that is also an extension is in vbTLDs, and the set equals the expected set (a dedupe
// removes only duplicates and adds nothing).
func TestBlockExts(t *testing.T) {
	seen := map[string]bool{}
	for _, e := range vbFileExts {
		if seen[e] {
			t.Errorf("duplicate extension %q", e)
		}
		seen[e] = true
	}
	if len(vbFileExts) < 50 {
		t.Fatalf("only %d extensions read: the list is not the real one", len(vbFileExts))
	}
	tlds := map[string]bool{}
	for _, e := range vbTLDs {
		tlds[e] = true
		if !seen[e] {
			t.Errorf("TLD %q is not an extension: vbTLDs holds only the overlap", e)
		}
	}
	overlap := 0
	for _, e := range strings.Fields("com net org io dev app ai co me tv cc pl md rs sh sc ml tf so us uk de fr es it nl ru ch") {
		if seen[e] {
			overlap++
			if !tlds[e] {
				t.Errorf("TLD %q is an extension but missing from vbTLDs", e)
			}
		}
	}
	if overlap < 1 {
		t.Fatal("no frozen TLD is an extension: the check read nothing")
	}
	raw, err := os.ReadFile("testdata/block/exts-expected-set.txt")
	if err != nil {
		t.Fatal(err)
	}
	want := strings.Fields(string(raw))
	got := append([]string(nil), vbFileExts...)
	sort.Strings(got)
	sort.Strings(want)
	if strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Errorf("the extension set differs from testdata/block/exts-expected-set.txt (intentional change? update the fixture)")
	}
}

func TestBlockRegexpsCompile(t *testing.T) {
	vbAllMu.Lock()
	all := append([]*vbRE(nil), vbAll...)
	vbAllMu.Unlock()
	if len(all) < 30 {
		t.Fatalf("only %d registered patterns", len(all))
	}
	for _, re := range all {
		if re.get() == nil {
			t.Errorf("pattern %q did not compile", re.src)
		}
	}
}

// TestBlockDirnameBasename compares the helpers with the real dirname(1) and basename(1).
func TestBlockDirnameBasename(t *testing.T) {
	for _, p := range []string{
		"a", "a/b", "a//b", "/a", "/", "//", "//a", "a/", "a//", "a/b/", "./a", "../a/b", "a/./b", "/a/b/c.md", "a b/c d", "", "///", "a/b//", "x.md", "dir/x.md",
	} {
		if p == "" {
			continue // the script never calls either on an empty path
		}
		if got, want := dirnameSh(p), realTool(t, "dirname", p); got != want {
			t.Errorf("dirname(%q) = %q, want %q", p, got, want)
		}
		if got, want := basenameSh(p), realTool(t, "basename", p); got != want {
			t.Errorf("basename(%q) = %q, want %q", p, got, want)
		}
	}
}

func realTool(t *testing.T, tool, arg string) string {
	t.Helper()
	out, err := exec.Command(tool, "--", arg).Output()
	if err != nil {
		t.Fatalf("%s %q: %v", tool, arg, err)
	}
	return strings.TrimSuffix(string(out), "\n")
}

func TestBlockShellInt(t *testing.T) {
	for _, c := range []struct {
		in string
		n  int64
		ok bool
	}{
		{"0", 0, true}, {"007", 7, true}, {"123", 123, true}, {"9223372036854775807", 1<<63 - 1, true},
		{"9223372036854775808", 0, false}, {"99999999999999999999", 0, false}, {"", 0, false}, {"1x", 0, false}, {"-1", 0, false},
	} {
		if n, ok := shellInt(c.in); n != c.n || ok != c.ok {
			t.Errorf("shellInt(%q) = %d, %v; want %d, %v", c.in, n, ok, c.n, c.ok)
		}
	}
	if !numLE("2", "2") || numLE("3", "2") || numLE("1", "x") || !numGT("3", "2") || numGT("2", "2") || numGT("x", "1") || !numEQ("00", "0") || numEQ("1", "2") || numEQ("", "0") {
		t.Error("numeric tests misbehave")
	}
}

func TestBlockCutBytes(t *testing.T) {
	if cutBytes("abc", 5) != "abc" || cutBytes("abcdef", 3) != "abc" || cutBytes("abc", 3) != "abc" {
		t.Error("cutBytes")
	}
	// GNU cut counts bytes: a two-byte character split in the middle stays split
	if got := cutBytes("éé", 3); got != "é\xc3" {
		t.Errorf("cutBytes splits a character: got %q", got)
	}
}

func TestBlockParseBlockName(t *testing.T) {
	for _, c := range []struct {
		in     string
		prefix string
		num    int64
		ok     bool
	}{
		{"kit-block5.md", "kit-", 5, true}, {"block5.md", "", 5, true}, {"x-bloque12-slug_a-b.md", "x-", 12, true},
		{"a-block-block7.md", "a-block-", 7, true}, {"x-block1-block2.md", "x-block1-", 2, true}, {"kit-block009.md", "kit-", 9, true},
		{"kit-block5x.md", "", 0, false}, {"kit-block.md", "", 0, false}, {"kit-block5.txt", "", 0, false}, {"Block5.md", "", 0, false},
		{"kit-block5-é.md", "kit-", 5, true}, {"kit-block5-.md", "", 0, false},
	} {
		p, n, ok := parseBlockName(c.in)
		if p != c.prefix || n != c.num || ok != c.ok {
			t.Errorf("parseBlockName(%q) = %q, %d, %v; want %q, %d, %v", c.in, p, n, ok, c.prefix, c.num, c.ok)
		}
	}
}

func TestBlockVbLinesCap(t *testing.T) {
	for _, c := range []struct {
		in   string
		end  int64
		want int64
	}{
		{"", 0, 0}, {"a", 0, 1}, {"a\n", 0, 1}, {"a\nb", 0, 2}, {"a\nb\n", 0, 2}, {"a\nb\nc\n", 2, 2}, {"a\nb\nc", 3, 3}, {"a\nb", 5, 2}, {"\n\n\n", 0, 3},
	} {
		got, err := vbCountLines(strings.NewReader(c.in), c.end)
		if err != nil || got != c.want {
			t.Errorf("vbCountLines(%q, %d) = %d, %v; want %d", c.in, c.end, got, err, c.want)
		}
	}
}
