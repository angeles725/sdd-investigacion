package hookenv

import (
	"fmt"
	"strings"
	"unicode/utf8"
)

// FailureCap bounds the WHOLE additionalContext of a SessionStart hook that could not run (kit issue #2631): the
// header, the kept output lines and the dropped-lines note together. A hook that could not run may not print more
// than its share of the session budget, and every registered hook can fail at once (a broken rsdd binary fails all
// of them), so the share is derived from the budget, not chosen:
//
//   - claude runs each hook as its own process and nobody trims the sum: N hooks x FailureCap must stay under the
//     8,000-character budget (openspec/specs/kit-session-cost/spec.md).
//   - pi joins the hooks itself (install/pi/research-sdd-hooks.ts, collectStartup) and cuts every hook's text to a
//     head-kept slice when their total passes 7,500 minus its header and a 300 margin, which would drop exactly the
//     tail this cap keeps. FailureCap stays below the largest value that never triggers that cut.
//
// TestFailureCapFitsEveryConsumer derives both bounds from the registered hooks in .claude/settings.json and the pi
// extension's own constants, so a ninth hook or a smaller pi budget turns it red instead of silently overflowing.
const FailureCap = 800

// Width is the size a consumer sees: UTF-16 code units, which is what pi measures (JavaScript .length) and never less
// than the characters claude counts. An invalid byte counts as one unit, as the U+FFFD jq writes in its place.
func Width(s string) int {
	n := 0
	for _, r := range s {
		n++
		if r > 0xFFFF {
			n++
		}
	}
	return n
}

// FailureContext is the additionalContext of a hook that could not run: header, a newline and out, exactly as the
// hooks built it before (byte-identical) whenever that fits in FailureCap. Otherwise it keeps the header, the first
// non-empty line of out (a typed reason is often printed first), a note naming how many lines were dropped and the
// command that prints them all (rerun), and as many whole lines from the end of out as still fit (the error is
// usually last). A trailing newline of out ends its last line; it is not a line of its own. Output too wide to keep
// even one line whole is cut on rune boundaries, and the note says so.
func FailureContext(header, out, rerun string) string {
	whole := header + "\n" + out
	if Width(whole) <= FailureCap {
		return whole
	}
	lines := strings.Split(strings.TrimSuffix(out, "\n"), "\n")
	first := 0
	for first < len(lines)-1 && strings.TrimSpace(lines[first]) == "" {
		first++
	}
	// The note's width is reserved for the largest count it can carry, so the exact note always fits.
	room := FailureCap - Width(header) - 1 - Width(lines[first]) - 1 - Width(droppedNote(len(lines), rerun))
	if room < 0 {
		return cutRunes(header, out, rerun)
	}
	tail := len(lines) // the first kept tail line
	for tail-1 > first && Width(lines[tail-1])+1 <= room {
		tail--
		room -= Width(lines[tail]) + 1
	}
	kept := []string{header, lines[first]}
	if dropped := tail - first - 1; dropped > 0 {
		kept = append(kept, droppedNote(dropped, rerun))
	}
	return strings.Join(append(kept, lines[tail:]...), "\n")
}

func droppedNote(n int, rerun string) string {
	return fmt.Sprintf("… %d line(s) dropped to fit the SessionStart budget — run `%s` for the full output", n, rerun)
}

// cutRunes keeps the header and as many leading runes of out as fit beside a note that says the output was cut.
func cutRunes(header, out, rerun string) string {
	total := Width(out)
	note := fmt.Sprintf("… output cut to %d of %d characters to fit the SessionStart budget — run `%s` for the full output", total, total, rerun)
	room := FailureCap - Width(header) - 1 - 1 - Width(note)
	kept, used := 0, 0
	for i, r := range out {
		w := 1
		if r > 0xFFFF {
			w = 2
		}
		if used+w > room {
			break
		}
		used += w
		_, size := utf8.DecodeRuneInString(out[i:])
		kept = i + size
	}
	note = fmt.Sprintf("… output cut to %d of %d characters to fit the SessionStart budget — run `%s` for the full output", used, total, rerun)
	return header + "\n" + out[:kept] + "\n" + note
}
