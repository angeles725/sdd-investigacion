package migratebacklogs

import (
	"strconv"
	"strings"
)

// contextLines is the context of `diff -u`.
const contextLines = 3

const noNewline = "\\ No newline at end of file\n"

// block is a run of consecutive positions where the proposal differs from the source: positions [from, to) of
// the old file are replaced by the same positions of the new one (a position past either end is a pure
// deletion or addition).
type block struct{ from, to int }

// unifiedDiff renders the `diff -u --label a/<rel> --label b/<rel>` text for the proposal, "" when there is
// none. The transforms rewrite lines in place and append a tail, so lines pair up by position; that pairing is
// the edit script, and its hunks are the ones GNU diff prints.
func unifiedDiff(rel string, oldL, newL []line) string {
	n, m := len(oldL), len(newL)
	var blocks []block
	for i := 0; i < max(n, m); i++ {
		if i < n && i < m && oldL[i].text() == newL[i].text() {
			continue
		}
		if k := len(blocks) - 1; k >= 0 && blocks[k].to == i {
			blocks[k].to++
		} else {
			blocks = append(blocks, block{i, i + 1})
		}
	}
	if len(blocks) == 0 {
		return ""
	}
	var sb strings.Builder
	sb.WriteString("--- a/" + rel + "\n+++ b/" + rel + "\n")
	for lo := 0; lo < len(blocks); {
		hi := lo
		for hi+1 < len(blocks) && blocks[hi+1].from-blocks[hi].to <= 2*contextLines {
			hi++
		}
		writeHunk(&sb, oldL, newL, blocks[lo:hi+1])
		lo = hi + 1
	}
	return sb.String()
}

// writeHunk prints the hunk made of the given neighbouring blocks with its context.
func writeHunk(sb *strings.Builder, oldL, newL []line, blocks []block) {
	n, m := len(oldL), len(newL)
	start := max(0, blocks[0].from-contextLines)
	end := min(max(n, m), blocks[len(blocks)-1].to+contextLines)
	var body strings.Builder
	oldCount, newCount := 0, 0
	emit := func(prefix string, l line) {
		body.WriteString(prefix + l.text())
		if l.eol == "" {
			body.WriteString("\n" + noNewline)
		}
	}
	b := 0
	for i := start; i < end; {
		for b < len(blocks) && blocks[b].to <= i {
			b++
		}
		if b < len(blocks) && blocks[b].from <= i {
			bl := blocks[b]
			for j := i; j < min(bl.to, n); j++ {
				emit("-", oldL[j])
				oldCount++
			}
			for j := i; j < min(bl.to, m); j++ {
				emit("+", newL[j])
				newCount++
			}
			i = bl.to
			continue
		}
		emit(" ", oldL[i])
		oldCount++
		newCount++
		i++
	}
	sb.WriteString("@@ -" + hunkRange(start, oldCount) + " +" + hunkRange(start, newCount) + " @@\n")
	sb.WriteString(body.String())
}

// hunkRange is GNU diff's `start,count`: the count is dropped when it is 1, and an empty range starts at the
// line before it.
func hunkRange(start, count int) string {
	switch count {
	case 0:
		return strconv.Itoa(start) + ",0"
	case 1:
		return strconv.Itoa(start + 1)
	}
	return strconv.Itoa(start+1) + "," + strconv.Itoa(count)
}
