package reviewslices

import (
	"fmt"
	"io"
	"math"
	"strconv"
	"strings"
)

// commit is one measured commit of the walk: its 12-character sha, the abbreviated first parent ("ROOT" for a root
// commit), its authored changed lines and its binary files.
type commit struct {
	short, base string
	lines, bin  int64
}

// slice is the accumulator of one reviewable slice.
type slice struct {
	first, last, base string
	commits           int
	lines, bin        int64
	unsplittable      bool
}

// planner is the greedy grouper. It prints each slice the moment it is closed, as the script did, so a measurement
// that fails later leaves the slices before it on stdout, exactly as the script's stdout was.
type planner struct {
	max  int64
	out  io.Writer
	cur  slice
	open bool
	// totals of the closed slices
	slices, commits int
	lines, bin      int64
}

// add places one commit: over the budget it is its own UNSPLITTABLE slice (never cut), otherwise it joins the open
// slice when the total stays within max (<=: a slice may hold exactly max lines), otherwise it opens a new one.
func (p *planner) add(c commit) {
	start := slice{first: c.short, last: c.short, base: c.base, commits: 1, lines: c.lines, bin: c.bin}
	if c.lines > p.max {
		p.close()
		start.unsplittable = true
		p.cur, p.open = start, true
		p.close()
		return
	}
	if p.open && p.cur.lines+c.lines <= p.max {
		p.cur.last = c.short
		p.cur.commits++
		p.cur.lines += c.lines
		p.cur.bin += c.bin
		return
	}
	p.close()
	p.cur, p.open = start, true
}

// close prints the open slice, if any, and counts it.
func (p *planner) close() {
	if !p.open {
		return
	}
	s := p.cur
	p.open = false
	p.slices++
	p.commits += s.commits
	p.lines += s.lines
	p.bin += s.bin
	tag := ""
	if s.unsplittable {
		tag = "UNSPLITTABLE "
	}
	fmt.Fprintf(p.out, "SLICE %d %s..%s commits=%d %slines=%d%s base=%s\n", p.slices, s.first, s.last, s.commits, tag, s.lines, binaryField(s.bin), s.base)
}

// finish closes the last slice and prints the plan line.
func (p *planner) finish() {
	p.close()
	fmt.Fprintf(p.out, "PLAN: %d slice(s) commits=%d lines=%d max=%d%s\n", p.slices, p.commits, p.lines, p.max, binaryField(p.bin))
}

// binaryField is ` binary=<n>`, present only when binary files were seen (they have no line count).
func binaryField(n int64) string {
	if n > 0 {
		return " binary=" + strconv.FormatInt(n, 10)
	}
	return ""
}

// parseNumstat reads `git diff --numstat` the way the script's awk did: tab-separated records of at least three
// fields; `-` `-` is a binary file, two counts add up to the authored lines, a blank record is skipped and anything
// else is malformed (ok=false), never a zero. A count git cannot print (beyond int64) is malformed too.
func parseNumstat(text string) (lines, bin int64, ok bool) {
	for _, rec := range strings.Split(text, "\n") {
		if rec == "" {
			continue
		}
		f := strings.Split(rec, "\t")
		if len(f) >= 3 && f[0] == "-" && f[1] == "-" {
			bin++
			continue
		}
		a, aok := count(f[0])
		var b int64
		bok := false
		if len(f) >= 3 {
			b, bok = count(f[1])
		}
		if len(f) < 3 || !aok || !bok || a > math.MaxInt64-b || lines > math.MaxInt64-(a+b) {
			return 0, 0, false
		}
		lines += a + b
	}
	return lines, bin, true
}

// count is a field of only ASCII digits (the awk's /^[0-9]+$/), read as base 10.
func count(s string) (int64, bool) {
	if s == "" || strings.Trim(s, "0123456789") != "" {
		return 0, false
	}
	n, err := strconv.ParseInt(s, 10, 64)
	return n, err == nil
}

// positive is the script's `^[1-9][0-9]*$`: no sign, no leading zero, no space, no trailing newline.
func positive(s string) bool {
	return s != "" && s[0] != '0' && strings.Trim(s, "0123456789") == ""
}
