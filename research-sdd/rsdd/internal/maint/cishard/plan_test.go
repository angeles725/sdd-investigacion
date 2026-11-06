package cishard

import (
	"fmt"
	"reflect"
	"sort"
	"strings"
	"testing"
)

// Guard-to-test table (plan.go): --shard grammar -> TestShardGrammar; usage errors -> TestPlanUsage; the weighted
// plan and its notes -> TestPlanWeighted; every DEGRADED reason -> TestPlanDegraded; INVALID -> TestPlanInvalidDurations;
// the three input states -> TestPlanInputStates; EMPTY SHARD -> TestPlanEmptyShard; the cover through the command ->
// TestPlanCoverThroughTheCommand; nothing on stdout when it fails -> every table asserts out == "".

const fourPkgs = "a\nb\nc\nd\n"

func TestShardGrammar(t *testing.T) {
	for _, bad := range []string{"", "2", "0/2", "3/2", "1/0", "1/33", "a/b", "1/2/3", "-1/2", "1/-2", " 1/2", "1/2 ", "1/1000"} {
		r := runIn(t, t.TempDir(), str(fourPkgs), "plan", "--shard", bad)
		if r.rc != 2 || r.out != "" || !has(r.err, "usage:") {
			t.Errorf("--shard %q: %+v", bad, r)
		}
	}
	for _, ok := range []string{"1/1", "1/32", "32/32", "01/02", "2/2"} {
		r := runIn(t, t.TempDir(), str(fourPkgs), "plan", "--shard", ok)
		if r.rc == 2 {
			t.Errorf("--shard %q refused: %+v", ok, r)
		}
	}
}

func TestPlanUsage(t *testing.T) {
	d := t.TempDir()
	for _, args := range [][]string{
		{},
		{"nope"},
		{"plan"},
		{"plan", "--shard"},
		{"plan", "--shard", "1/2", "--bogus"},
		{"plan", "--shard", "1/2", "extra"},
		{"plan", "--shard", "1/2", "--durations"},
		{"manifest"},
	} {
		r := runIn(t, d, str(fourPkgs), args...)
		if r.rc != 2 || r.out != "" || !has(r.err, "usage:") {
			t.Errorf("%v: %+v", args, r)
		}
	}
	if r := runIn(t, d, nil, "--help"); r.rc != 0 || !has(r.out, "usage: rsdd maint ci-shard plan") {
		t.Errorf("help: %+v", r)
	}
}

func TestPlanWeighted(t *testing.T) {
	d := t.TempDir()
	dur := writeFile(t, d, "dur.txt", "# seconds\na 10\nb 7\nc 6\nd 5\ngone 4\n")
	one := runIn(t, d, str(fourPkgs), "plan", "--shard", "1/2", "--durations", dur)
	two := runIn(t, d, str(fourPkgs), "plan", "--shard", "2/2", "--durations", dur)
	if one.rc != 0 || one.out != "a\nd\n" || two.rc != 0 || two.out != "b\nc\n" {
		t.Fatalf("%+v %+v", one, two)
	}
	// a relative --durations is relative to the working directory of the command
	if rel := runIn(t, d, str(fourPkgs), "plan", "--shard", "1/2", "--durations", "dur.txt"); rel.out != one.out || has(rel.err, "DEGRADED") {
		t.Errorf("relative path: %+v", rel)
	}
	for _, want := range []string{
		"ci-shard: shard 1/2 — 2 of 4 packages\n",
		"ci-shard: balance — duration-weighted, predicted 15 s for this shard (all 2 shards: min 13 s, max 15 s)\n",
		"ci-shard: stale duration entries 1 — [gone]\n",
	} {
		if !has(one.err, want) {
			t.Errorf("stderr lacks %q: %q", want, one.err)
		}
	}
	if has(one.err, "DEGRADED") || has(one.err, "weighted 6 s") {
		t.Errorf("unexpected notes: %q", one.err)
	}
}

func TestPlanNamesTheUnlistedAtSixSeconds(t *testing.T) {
	d := t.TempDir()
	dur := writeFile(t, d, "dur.txt", "a 11\n")
	r := runIn(t, d, str(fourPkgs), "plan", "--shard", "1/2", "--durations", dur)
	if r.rc != 0 || r.out != "a\nd\n" {
		t.Fatalf("%+v", r)
	}
	if !has(r.err, "ci-shard: durations — 3 of 4 planned package(s) not in the durations file, weighted 6 s each: b, c, d\n") ||
		!has(r.err, "predicted 17 s for this shard (all 2 shards: min 12 s, max 17 s)") {
		t.Errorf("%q", r.err)
	}
}

func TestPlanDegraded(t *testing.T) {
	d := t.TempDir()
	empty := writeFile(t, d, "empty.txt", "")
	comments := writeFile(t, d, "comments.txt", "# nothing\n\n")
	stale := writeFile(t, d, "stale.txt", "gone 5\n")
	for _, c := range []struct {
		name   string
		args   []string
		reason string
	}{
		{"no flag", nil, "no --durations file given"},
		{"absent file", []string{"--durations", d + "/missing.txt"}, "durations file absent"},
		{"a directory", []string{"--durations", d}, "durations file unreadable"},
		{"zero bytes", []string{"--durations", empty}, "durations file lists no package"},
		{"comments only", []string{"--durations", comments}, "durations file lists no package"},
		{"only stale entries", []string{"--durations", stale}, "durations file lists no planned package"},
		{"relative to the cwd", []string{"--durations", "missing.txt"}, "durations file absent"},
	} {
		args := append([]string{"plan", "--shard", "2/3"}, c.args...)
		r := runIn(t, d, str(fourPkgs), args...)
		// position mod N of the sorted list: index 1 of 4 with N=3 is shard 2 -> b; index 4 would be d? no: 1, 4 -> b only
		if r.rc != 0 || r.out != "b\n" {
			t.Errorf("%s: %+v", c.name, r)
		}
		want := "ci-shard: DEGRADED — " + c.reason + "; assigning round-robin by name (still a disjoint, complete cover)\n"
		// a degraded run predicted nothing: no balance line and no "weighted 6 s" note for every package
		if !has(r.err, want) || has(r.err, "balance") || has(r.err, "weighted 6 s") {
			t.Errorf("%s: stderr %q", c.name, r.err)
		}
	}
	// the round-robin plan of shard 1/3 holds positions 0 and 3
	r := runIn(t, d, str(fourPkgs), "plan", "--shard", "1/3")
	if r.out != "a\nd\n" {
		t.Errorf("%+v", r)
	}
}

func TestPlanInvalidDurations(t *testing.T) {
	d := t.TempDir()
	dur := writeFile(t, d, "dur.txt", "a x\nb 3\nc\n")
	r := runIn(t, d, str(fourPkgs), "plan", "--shard", "1/2", "--durations", dur)
	if r.rc != 1 || r.out != "" {
		t.Fatalf("%+v", r)
	}
	for _, want := range []string{
		"ci-shard: INVALID — " + dur + " line 1: \"a\" has seconds \"x\"",
		"ci-shard: INVALID — " + dur + " line 3: \"c\" has no seconds\n",
		"ci-shard: durations file has 2 invalid line(s); nothing planned\n",
	} {
		if !has(r.err, want) {
			t.Errorf("stderr lacks %q: %q", want, r.err)
		}
	}
}

func TestPlanInputStates(t *testing.T) {
	d := t.TempDir()
	for _, c := range []struct {
		name  string
		stdin *string
		want  string
	}{
		{"absent", nil, "ci-shard: absent-input — "},
		{"empty", str(""), "ci-shard: empty-input — "},
		{"no match", str("\n  \n"), "ci-shard: no-match — "},
		{"duplicate", str("a\nb\na\n"), "ci-shard: INVALID — package list line 3: \"a\" is listed twice (first at line 1)\n"},
		{"inner blank", str("a b\n"), "ci-shard: INVALID — package list line 1: \"a b\" holds whitespace\n"},
	} {
		r := runIn(t, d, c.stdin, "plan", "--shard", "1/2")
		if r.rc != 1 || r.out != "" || !has(r.err, c.want) {
			t.Errorf("%s: %+v", c.name, r)
		}
	}
}

func TestPlanEmptyShard(t *testing.T) {
	d := t.TempDir()
	dur := writeFile(t, d, "dur.txt", "a 5\nb 5\n")
	for _, args := range [][]string{{"--durations", dur}, {}} {
		r := runIn(t, d, str("a\nb\n"), append([]string{"plan", "--shard", "3/3"}, args...)...)
		if r.rc != 1 || r.out != "" || !has(r.err, "ci-shard: EMPTY SHARD — 3/3 selected 0 of 2 packages (N exceeds the package count); nothing to run, so this shard is not a pass\n") {
			t.Errorf("%v: %+v", args, r)
		}
	}
	// the last non-empty shard is not empty
	if r := runIn(t, d, str("a\nb\n"), "plan", "--shard", "2/3", "--durations", dur); r.rc != 0 || r.out != "b\n" {
		t.Errorf("%+v", r)
	}
}

func TestPlanInputWithoutFinalNewlineAndSingle(t *testing.T) {
	d := t.TempDir()
	if r := runIn(t, d, str("only/one"), "plan", "--shard", "1/1"); r.rc != 0 || r.out != "only/one\n" {
		t.Errorf("%+v", r)
	}
	if r := runIn(t, d, str("z\ny\nx"), "plan", "--shard", "1/1"); r.rc != 0 || r.out != "x\ny\nz\n" {
		t.Errorf("%+v", r)
	}
}

func TestPlanCoverThroughTheCommand(t *testing.T) {
	d := t.TempDir()
	var pkgs []string
	var dur strings.Builder
	for i := 0; i < 11; i++ {
		p := fmt.Sprintf("m/p%02d", i)
		pkgs = append(pkgs, p)
		if i%4 != 0 {
			fmt.Fprintf(&dur, "%s %d\n", p, 1+(i*5)%17)
		}
	}
	durFile := writeFile(t, d, "dur.txt", dur.String())
	in := strings.Join(pkgs, "\n")
	for _, withDur := range []bool{true, false} {
		for n := 1; n <= maxShards; n++ {
			var union []string
			for i := 1; i <= n; i++ {
				args := []string{"plan", "--shard", fmt.Sprintf("%d/%d", i, n)}
				if withDur {
					args = append(args, "--durations", durFile)
				}
				r := runIn(t, d, str(in), args...)
				switch r.rc {
				case 0:
					union = append(union, lines(r.out)...)
				case 1:
					// only a shard past the package count may be empty
					if r.out != "" || !has(r.err, "EMPTY SHARD") || n <= len(pkgs) || i <= len(pkgs) {
						t.Errorf("N=%d I=%d dur=%v: %+v", n, i, withDur, r)
					}
				default:
					t.Fatalf("N=%d I=%d: %+v", n, i, r)
				}
			}
			sort.Strings(union)
			if !reflect.DeepEqual(union, pkgs) {
				t.Errorf("N=%d dur=%v: union %v", n, withDur, union)
			}
		}
	}
}
