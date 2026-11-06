package hookenv

import (
	"fmt"
	"strings"
)

// FailureCap bounds the WHOLE additionalContext of a SessionStart hook that could not run (kit issue #2631): the
// header, the kept output lines and the note together. A hook that could not run may not print more than its share
// of the session budget, and every registered hook can fail at once (a broken rsdd binary fails all of them), so the
// share is derived from the budget, not chosen:
//
//   - claude runs each hook as its own process and nobody trims the sum: N hooks x FailureCap must stay under the
//     8,000-character budget (openspec/specs/kit-session-cost/spec.md).
//   - pi joins the hooks itself (install/pi/research-sdd-hooks.ts, collectStartup) and cuts every hook's text to a
//     head-kept slice when their total passes 7,500 minus its header and a 300 margin, which would drop exactly the
//     tail this cap keeps. FailureCap stays below the largest value that never triggers that cut.
//
// One registered hook, verify-tool-catalog-hook.sh, is still bash and prints its whole output (kit issue #2749):
// until its port, the worst case holds for the other hooks only, and TestEveryRegisteredHookIsCappedOrNamedDebt
// names it.
//
// TestFailureCapFitsEveryConsumer derives both bounds from the registered hooks in .claude/settings.json and the pi
// extension's own constants, so a ninth hook or a smaller pi budget turns it red instead of silently overflowing.
const FailureCap = 800

// Width is the size a consumer sees: UTF-16 code units, which is what pi measures (JavaScript .length) and never less
// than the characters claude counts. An invalid byte counts as one unit, as the U+FFFD jq writes in its place.
func Width(s string) int {
	n := 0
	for _, r := range s {
		n += units(r)
	}
	return n
}

// units is the UTF-16 width of r: 2 above the Basic Multilingual Plane (a surrogate pair), else 1.
func units(r rune) int {
	if r > 0xFFFF {
		return 2
	}
	return 1
}

// FailureContext is the additionalContext of a hook that could not run: header, a newline and out, exactly as the
// hooks built it before (byte-identical) whenever that fits in FailureCap. Otherwise it is, one per line:
//
//   - the header;
//   - the first non-empty line of out (a typed reason is often printed first), clipped to half the room;
//   - a note with the exact number of lines dropped and lines clipped, naming the command that prints the whole
//     output (rerun);
//   - the last line of out, clipped to what is left, and before it as many whole lines from the end as still fit
//     (the error is usually last).
//
// A clipped first line keeps its leading runes and ends in "…"; a clipped last line starts with "…" and keeps its
// trailing runes, where the cause of a failure is usually printed. Lines before the first non-empty one are counted
// as dropped. A trailing newline of out ends its last line; it is not a
// line of its own. A header too wide to leave room for the note is itself clipped to FailureCap.
func FailureContext(header, out, rerun string) string {
	whole := header + "\n" + out
	if Width(whole) <= FailureCap {
		return whole
	}
	lines := strings.Split(strings.TrimSuffix(out, "\n"), "\n")
	last := len(lines) - 1
	first := 0
	for first < last && strings.TrimSpace(lines[first]) == "" {
		first++
	}
	// The note is reserved at the widest counts it can carry, so the exact note always fits.
	room := FailureCap - Width(header) - Width(failureNote(len(lines), len(lines), rerun)) - 2
	if room < 2 {
		return clip(header, FailureCap)
	}
	share := room
	if first < last {
		share = room / 2 // the last line is always shown: the first may take at most half
	}
	head := clip(lines[first], share)
	room -= Width(head)
	var tail []string
	for i := last; i > first; i-- {
		l := lines[i]
		if i == last {
			l = clipTail(l, room-1)
		}
		if Width(l)+1 > room {
			break
		}
		tail = append([]string{l}, tail...)
		room -= Width(l) + 1
	}
	cut := 0
	if head != lines[first] {
		cut++
	}
	if len(tail) > 0 && tail[len(tail)-1] != lines[last] {
		cut++
	}
	kept := []string{header, head, failureNote(last-len(tail), cut, rerun)}
	return strings.Join(append(kept, tail...), "\n")
}

func failureNote(dropped, cut int, rerun string) string {
	return fmt.Sprintf("… %d line(s) dropped, %d line(s) clipped to fit the SessionStart budget — run `%s` for the full output",
		dropped, cut, rerun)
}

// clip returns s when it is at most w units wide, else its leading runes and "…", w units at most.
func clip(s string, w int) string {
	if Width(s) <= w {
		return s
	}
	used := 0
	for i, r := range s {
		if used+units(r) > w-1 {
			return s[:i] + "…"
		}
		used += units(r)
	}
	return s
}

// clipTail returns s when it is at most w units wide, else "…" and its trailing runes, w units at most.
func clipTail(s string, w int) string {
	if Width(s) <= w {
		return s
	}
	r := []rune(s)
	used, i := 0, len(r)
	for used+units(r[i-1]) <= w-1 { // s is wider than w, so the loop stops before i reaches 0
		used += units(r[i-1])
		i--
	}
	return "…" + string(r[i:])
}
