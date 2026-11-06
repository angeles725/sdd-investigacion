package hookenv

import (
	"fmt"
	"math/rand"
	"regexp"
	"strconv"
	"strings"
	"testing"
)

const (
	hdr   = "Research-SDD retro sweep could not run (exit 1 — check TARGETS.md and lib/ helper):"
	rerun = "rsdd sweep retros"
)

var reNote = regexp.MustCompile("^… ([0-9]+) line\\(s\\) dropped to fit the SessionStart budget — run `rsdd sweep retros` for the full output$")

// line returns a line of exactly w units.
func line(tag string, w int) string { return tag + strings.Repeat("x", w-len(tag)) }

// check asserts the invariants every capped result keeps and returns the dropped count its note states (-1: none).
func check(t *testing.T, out, got string) int {
	t.Helper()
	if w := Width(got); w > FailureCap {
		t.Fatalf("width %d > cap %d", w, FailureCap)
	}
	parts := strings.Split(got, "\n")
	if parts[0] != hdr {
		t.Fatalf("the header is not first: %q", parts[0])
	}
	lines := strings.Split(strings.TrimSuffix(out, "\n"), "\n")
	first := 0
	for first < len(lines)-1 && strings.TrimSpace(lines[first]) == "" {
		first++
	}
	if parts[1] != lines[first] {
		t.Fatalf("the first non-empty line %q is not kept, got %q", lines[first], parts[1])
	}
	rest, dropped := parts[2:], -1
	if len(rest) > 0 {
		if m := reNote.FindStringSubmatch(rest[0]); m != nil {
			dropped, _ = strconv.Atoi(m[1])
			rest = rest[1:]
		}
	}
	tail := lines[len(lines)-len(rest):]
	if strings.Join(tail, "\n") != strings.Join(rest, "\n") {
		t.Fatalf("the kept lines are not the tail of the output:\n%q\nvs\n%q", rest, tail)
	}
	if shown := 1 + len(rest); dropped != -1 && dropped != len(lines)-first-shown {
		t.Fatalf("the note says %d dropped, %d lines are missing", dropped, len(lines)-first-shown)
	}
	return dropped
}

func TestFailureContextShortOutputIsByteIdentical(t *testing.T) {
	for _, out := range []string{"", "one line", "a\nb\n", "\n\n"} {
		if got := FailureContext(hdr, out, rerun); got != hdr+"\n"+out {
			t.Errorf("%q: got %q", out, got)
		}
	}
}

func TestFailureContextExactlyTheCapIsUnchanged(t *testing.T) {
	room := FailureCap - Width(hdr) - 1
	out := line("a", 100) + "\n" + line("b", room-101)
	if got := FailureContext(hdr, out, rerun); got != hdr+"\n"+out {
		t.Fatalf("an output that fills the cap exactly was changed: width %d", Width(got))
	}
	out += "y" // one unit over
	got := FailureContext(hdr, out, rerun)
	if got == hdr+"\n"+out {
		t.Fatal("one unit over the cap was not cut")
	}
	check(t, out, got)
}

// Line widths that leave room for exactly k tail lines after the first line and the note.
func shaped(nLines, w int) string {
	ls := make([]string, nLines)
	for i := range ls {
		ls[i] = line(fmt.Sprintf("L%d-", i), w)
	}
	return strings.Join(ls, "\n")
}

func TestFailureContextDroppedCountEdges(t *testing.T) {
	note := Width(droppedNote(99, rerun))
	room := FailureCap - Width(hdr) - 1 - 100 - 1 - note // room for tail lines after a 100-wide first line
	t.Run("one-dropped", func(t *testing.T) {
		// first line + one line that does not fit + two lines that do.
		w := room/2 - 1
		out := line("first", 100) + "\n" + line("gone", w+50) + "\n" + line("t1", w) + "\n" + line("t2", w)
		if d := check(t, out, FailureContext(hdr, out, rerun)); d != 1 {
			t.Fatalf("dropped = %d, want 1", d)
		}
	})
	t.Run("all-but-one", func(t *testing.T) {
		// nothing after the first line fits: every other line is dropped.
		out := line("first", 100) + "\n" + shaped(5, room+1)
		got := FailureContext(hdr, out, rerun)
		if d := check(t, out, got); d != 5 {
			t.Fatalf("dropped = %d, want 5:\n%s", d, got)
		}
	})
	t.Run("trailing-newline-is-not-a-line", func(t *testing.T) {
		out := line("first", 100) + "\n" + shaped(30, 60)
		a, b := FailureContext(hdr, out, rerun), FailureContext(hdr, out+"\n", rerun)
		if a != b {
			t.Fatalf("a trailing newline changed the result:\n%s\n---\n%s", a, b)
		}
		check(t, out+"\n", b)
	})
}

func TestFailureContextKeepsTheReasonAtEitherEnd(t *testing.T) {
	top := "rsdd: internal-error: cannot read TARGETS.md"
	out := "\n" + top + "\n" + shaped(40, 60)
	if got := FailureContext(hdr, out, rerun); !strings.Contains(got, top) {
		t.Errorf("the reason printed first was dropped:\n%s", got)
	}
	bottom := "sweep-retros: degraded: TARGETS.md unreadable"
	out = shaped(40, 60) + "\n" + bottom
	if got := FailureContext(hdr, out, rerun); !strings.HasSuffix(got, "\n"+bottom) {
		t.Errorf("the reason printed last was dropped:\n%s", got)
	}
}

func TestFailureContextOneLongLineIsCutOnRunes(t *testing.T) {
	out := strings.Repeat("é", 3*FailureCap) // no newline at all; 2 bytes per rune
	got := FailureContext(hdr, out, rerun)
	if Width(got) > FailureCap {
		t.Fatalf("width %d > cap", Width(got))
	}
	parts := strings.Split(got, "\n")
	if len(parts) != 3 || parts[0] != hdr || strings.Trim(parts[1], "é") != "" || parts[1] == "" {
		t.Fatalf("shape: %q", parts)
	}
	want := fmt.Sprintf("… output cut to %d of %d characters to fit the SessionStart budget — run `%s` for the full output",
		Width(parts[1]), 3*FailureCap, rerun)
	if parts[2] != want {
		t.Fatalf("note %q, want %q", parts[2], want)
	}
	// The note reserves the digits of the total; the kept count may be shorter, which is the only slack allowed.
	if slack := len(strconv.Itoa(3*FailureCap)) - len(strconv.Itoa(Width(parts[1]))); Width(got) != FailureCap-slack {
		t.Errorf("the cut wastes room: width %d, cap %d, allowed slack %d", Width(got), FailureCap, slack)
	}
}

func TestFailureContextInvalidUTF8AndWideRunes(t *testing.T) {
	if Width("a\xffb") != 3 || Width("😀") != 2 || Width("é") != 1 {
		t.Fatalf("Width: %d %d %d", Width("a\xffb"), Width("😀"), Width("é"))
	}
	for _, out := range []string{strings.Repeat("\xff", 2*FailureCap), strings.Repeat("😀", FailureCap), strings.Repeat("ab\xff\n", FailureCap)} {
		got := FailureContext(hdr, out, rerun) // must not panic
		if Width(got) > FailureCap {
			t.Errorf("width %d > cap for %q…", Width(got), out[:8])
		}
	}
}

func TestFailureContextProperties(t *testing.T) {
	rng := rand.New(rand.NewSource(2631))
	for i := 0; i < 3000; i++ {
		n := 1 + rng.Intn(60)
		ls := make([]string, n)
		for j := range ls {
			if rng.Intn(8) == 0 {
				continue // an empty line
			}
			ls[j] = line(fmt.Sprintf("%d:", j), 3+rng.Intn(180))
		}
		out := strings.Join(ls, "\n")
		if rng.Intn(2) == 0 {
			out += "\n"
		}
		got := FailureContext(hdr, out, rerun)
		if Width(hdr+"\n"+out) <= FailureCap {
			if got != hdr+"\n"+out {
				t.Fatalf("case %d: a fitting output changed", i)
			}
			continue
		}
		if strings.Contains(got, "output cut to") {
			continue // the rune-cut path has its own test
		}
		check(t, out, got)
	}
}
