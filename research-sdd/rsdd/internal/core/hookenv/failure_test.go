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

var reNote = regexp.MustCompile("^… ([0-9]+) line\\(s\\) dropped, ([0-9]+) line\\(s\\) clipped to fit the SessionStart budget — run `rsdd sweep retros` for the full output$")

// line returns a line of exactly w units.
func line(tag string, w int) string { return tag + strings.Repeat("x", w-len(tag)) }

func lines(n, w int) []string {
	ls := make([]string, n)
	for i := range ls {
		ls[i] = line(fmt.Sprintf("L%d-", i), w)
	}
	return ls
}

// capped is a parsed capped context.
type capped struct {
	head             string
	dropped, clipped int
	tail             []string
}

// parse checks the invariants every capped result keeps, independently of how the code chose its lines, and returns
// the parts. It does not recompute the selection rule: the edge tests below pin that with exact expectations.
func parse(t *testing.T, out, got string) capped {
	t.Helper()
	if w := Width(got); w > FailureCap {
		t.Fatalf("width %d > cap %d", w, FailureCap)
	}
	parts := strings.Split(got, "\n")
	if len(parts) < 3 || parts[0] != hdr {
		t.Fatalf("not header + head + note: %q", parts)
	}
	m := reNote.FindStringSubmatch(parts[2])
	if m == nil {
		t.Fatalf("no note on line 3: %q", parts[2])
	}
	c := capped{head: parts[1], tail: parts[3:]}
	c.dropped, _ = strconv.Atoi(m[1])
	c.clipped, _ = strconv.Atoi(m[2])
	in := strings.Split(strings.TrimSuffix(out, "\n"), "\n")
	if shown := 1 + len(c.tail); c.dropped != len(in)-shown {
		t.Fatalf("the note says %d dropped; %d of %d lines are not shown", c.dropped, len(in)-shown, len(in))
	}
	clipped := 0
	for i, l := range c.tail { // the tail is contiguous and ends at the last line, which alone may be clipped
		want := in[len(in)-len(c.tail)+i]
		if l != want {
			if i != len(c.tail)-1 || !strings.HasPrefix(l, "…") || !strings.HasSuffix(want, strings.TrimPrefix(l, "…")) {
				t.Fatalf("tail line %d is %q, want %q or its clipped end", i, l, want)
			}
			clipped++
		}
	}
	if strings.HasSuffix(c.head, "…") && !strings.Contains(out, strings.TrimSuffix(c.head, "…")) {
		t.Fatalf("clipped head %q is not a prefix of an output line", c.head)
	} else if !strings.HasSuffix(c.head, "…") && !strings.Contains("\n"+out+"\n", "\n"+c.head+"\n") {
		t.Fatalf("head %q is not an output line", c.head)
	}
	if strings.HasSuffix(c.head, "…") {
		clipped++
	}
	if c.clipped != clipped {
		t.Fatalf("the note says %d clipped, %d lines are clipped", c.clipped, clipped)
	}
	return c
}

// roomFor is the room the tail starts with after a head of width h (the code reserves the note at its widest).
func roomFor(nLines, h int) int {
	return FailureCap - Width(hdr) - Width(failureNote(nLines, nLines, rerun)) - 2 - h
}

func TestFailureContextShortOutputIsByteIdentical(t *testing.T) {
	for _, out := range []string{"", "one line", "a\nb\n", "\n\n", "   "} {
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
	if got := FailureContext(hdr, out, rerun); got == hdr+"\n"+out {
		t.Fatal("one unit over the cap was not cut")
	} else {
		parse(t, out, got)
	}
}

// A tail line that fits with zero slack is kept; one unit wider and it is dropped (pins every <= / < in the loop).
func TestFailureContextTailBoundaryIsExact(t *testing.T) {
	const n = 4 // head, filler, probe, last
	room := roomFor(n, 100)
	last := line("last", 60)
	for _, extra := range []int{0, 1} {
		w := room - (len(last) + 1) - 1 + extra // the probe and its newline exactly fill the room when extra == 0
		out := strings.Join([]string{line("head", 100), line("filler", 300), line("probe", w), last}, "\n")
		c := parse(t, out, FailureContext(hdr, out, rerun))
		if want := []string{line("probe", w), last}; extra == 0 && strings.Join(c.tail, "\n") != strings.Join(want, "\n") {
			t.Errorf("an exactly fitting line was dropped: tail %q", c.tail)
		}
		if extra == 1 && (len(c.tail) != 1 || c.dropped != 2) {
			t.Errorf("a line one unit too wide was kept: tail %q, dropped %d", c.tail, c.dropped)
		}
	}
}

func TestFailureContextDroppedCountEdges(t *testing.T) {
	t.Run("zero-dropped-last-clipped", func(t *testing.T) {
		out := "start\n" + strings.Repeat("b", 900) + " error: real cause"
		c := parse(t, out, FailureContext(hdr, out, rerun))
		if c.head != "start" || c.dropped != 0 || c.clipped != 1 || !strings.HasSuffix(c.tail[0], " error: real cause") {
			t.Fatalf("%+v", c)
		}
	})
	t.Run("one-dropped", func(t *testing.T) {
		ls := lines(5, 145) // three tail lines fit after the head, the fourth does not
		out := strings.Join(ls, "\n")
		c := parse(t, out, FailureContext(hdr, out, rerun))
		if c.dropped != 1 || c.head != ls[0] || len(c.tail) != 3 {
			t.Fatalf("%+v", c)
		}
	})
	t.Run("all-but-head-and-last", func(t *testing.T) {
		ls := append([]string{"first"}, lines(5, 700)...) // the last line fits only clipped
		out := strings.Join(ls, "\n")
		c := parse(t, out, FailureContext(hdr, out, rerun))
		if c.dropped != 4 || len(c.tail) != 1 || c.clipped != 1 {
			t.Fatalf("%+v", c)
		}
	})
	t.Run("trailing-newline-is-not-a-line", func(t *testing.T) {
		out := strings.Join(lines(30, 60), "\n")
		a, b := FailureContext(hdr, out, rerun), FailureContext(hdr, out+"\n", rerun)
		if a != b {
			t.Fatalf("a trailing newline changed the result:\n%s\n---\n%s", a, b)
		}
		parse(t, out+"\n", b)
	})
}

// The first non-empty line and the last line both survive whatever sits between them, at first/middle/last widths.
func TestFailureContextKeepsTheReasonAtEitherEnd(t *testing.T) {
	top, bottom := "rsdd: internal-error: cannot read TARGETS.md", "sweep-retros: degraded: TARGETS.md unreadable"
	for _, mid := range [][]string{lines(40, 60), lines(3, 900), {strings.Repeat("y", 2000)}} {
		out := "\n \n\t\n" + top + "\n" + strings.Join(mid, "\n") + "\n" + bottom
		got := FailureContext(hdr, out, rerun)
		c := parse(t, out, got)
		if c.head != top || len(c.tail) == 0 || c.tail[len(c.tail)-1] != bottom {
			t.Errorf("head %q, tail %q", c.head, c.tail)
		}
	}
	// A first line too wide to keep whole is clipped from its end, and the last line still shows.
	out := strings.Repeat("a", 900) + "\nerror: real cause"
	c := parse(t, out, FailureContext(hdr, out, rerun))
	if !strings.HasSuffix(c.head, "…") || Width(c.head) > roomFor(2, 0)/2 || c.tail[0] != "error: real cause" {
		t.Errorf("%+v", c)
	}
}

func TestFailureContextOneLongLineIsClipped(t *testing.T) {
	out := strings.Repeat("é", 3*FailureCap) // no newline at all; 2 bytes per rune
	got := FailureContext(hdr, out, rerun)
	c := parse(t, out, got)
	if c.dropped != 0 || c.clipped != 1 || len(c.tail) != 0 || strings.Trim(strings.TrimSuffix(c.head, "…"), "é") != "" {
		t.Fatalf("%+v", c)
	}
	if want := roomFor(1, 0); Width(c.head) != want {
		t.Errorf("the clip wastes room: head %d units, room %d", Width(c.head), want)
	}
}

func TestFailureContextBlankLinesAreCounted(t *testing.T) {
	out := strings.Repeat("\n", 1000) // 1000 empty lines
	c := parse(t, out, FailureContext(hdr, out, rerun))
	if c.head != "" || c.dropped != 999 {
		t.Fatalf("%+v", c)
	}
	out = strings.Repeat(" \t\n", 400) + "reason"
	if c := parse(t, out, FailureContext(hdr, out, rerun)); c.head != "reason" || c.dropped != 400 {
		t.Fatalf("whitespace-only lines are not blank: %+v", c)
	}
}

func TestFailureContextHugeHeaderIsClipped(t *testing.T) {
	h := strings.Repeat("h", 2*FailureCap)
	for _, out := range []string{"", "x"} {
		if got := FailureContext(h, out, rerun); Width(got) > FailureCap || !strings.HasPrefix(got, "hhh") {
			t.Errorf("out %q: width %d", out, Width(got))
		}
	}
}

func TestFailureContextInvalidUTF8AndWideRunes(t *testing.T) {
	if Width("\uffff") != 1 || Width("\U00010000") != 2 || clip("\U00010000\U00010000", 3) != "\U00010000…" ||
		clipTail("\U00010000\U00010000", 3) != "…\U00010000" || clipTail("abc", 3) != "abc" || clip("abc", 3) != "abc" {
		t.Fatal("the BMP boundary or an exact fit is miscounted")
	}
	if Width("a\xffb") != 3 || Width("😀") != 2 || Width("é") != 1 {
		t.Fatalf("Width: %d %d %d", Width("a\xffb"), Width("😀"), Width("é"))
	}
	if clip("😀😀", 2) != "…" || clipTail("😀😀", 3) != "…😀" || clip("ab", 2) != "ab" || clipTail("abc", 2) != "…c" {
		t.Fatalf("clip: %q %q %q %q", clip("😀😀", 2), clipTail("😀😀", 3), clip("ab", 2), clipTail("abc", 2))
	}
	for _, out := range []string{strings.Repeat("\xff", 2*FailureCap), strings.Repeat("😀", FailureCap), strings.Repeat("ab\xff\n", FailureCap)} {
		if got := FailureContext(hdr, out, rerun); Width(got) > FailureCap { // must not panic either
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
			switch rng.Intn(10) {
			case 0: // an empty line
			case 1:
				ls[j] = "  "
			default:
				ls[j] = line(fmt.Sprintf("%d:", j), 3+rng.Intn(rng.Intn(4)*300+60))
			}
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
		c := parse(t, out, got)
		// The last non-blank line always shows: in the tail, or as the head when no other line precedes it.
		if lastLine := ls[n-1]; strings.TrimSpace(lastLine) != "" && len(c.tail) == 0 &&
			c.head != lastLine && !strings.HasPrefix(lastLine, strings.TrimSuffix(c.head, "…")) {
			t.Fatalf("case %d: the last line was dropped: %+v", i, c)
		}
	}
}

// The smallest room that still keeps the note (2: one unit of head and its newline) keeps it; one less clips the header.
func TestFailureContextRoomBoundary(t *testing.T) {
	note := Width(failureNote(2, 2, rerun))
	for _, room := range []int{2, 1} {
		h := strings.Repeat("h", FailureCap-note-2-room)
		got := FailureContext(h, "first\n"+strings.Repeat("s", 300), rerun) // too wide to pass whole
		if hasNote := strings.Contains(got, "line(s) dropped"); hasNote != (room == 2) || Width(got) > FailureCap {
			t.Errorf("room %d: note %v, width %d:\n%s", room, hasNote, Width(got), got)
		}
	}
}
