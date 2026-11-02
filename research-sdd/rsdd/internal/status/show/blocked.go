package show

import (
	"fmt"
	"os"
	"strings"
)

// blockedHeadings are the three section headings blocked_rows_body concatenates, in order (lib/blocked-rows.sh).
var blockedHeadings = []string{"## Blocked gaps", "## Non-investigable gaps", "## Blocked /"}

// sectionBody is blocked_rows_section: the lines after every line that STARTS with heading, up to the next `## `
// line (the heading line itself is not part of the body). No regex: the heading is a literal prefix.
func sectionBody(text, heading string) string {
	var b strings.Builder
	in := false
	for _, line := range splitLines(text) {
		switch {
		case strings.HasPrefix(line, heading):
			in = true
		case strings.HasPrefix(line, "## "):
			in = false
		case in:
			b.WriteString(line)
			b.WriteByte('\n')
		}
	}
	return b.String()
}

// splitLines is awk's record split: a final line without a newline is a record, an empty text has none.
func splitLines(text string) []string {
	if text == "" {
		return nil
	}
	return strings.Split(strings.TrimSuffix(text, "\n"), "\n")
}

// blockedBody is blocked_rows_body: the three sections one after the other.
func blockedBody(text string) string {
	var b strings.Builder
	for _, h := range blockedHeadings {
		b.WriteString(sectionBody(text, h))
	}
	return b.String()
}

// blockedNames is blocked_names: one trimmed name per bullet line of the blocked sections, with the
// `[ — ]needs: ...` tail removed, matched case-blind on needs:. Empty names are dropped. Under LC_ALL=C the
// dash bracket [-–—] is the byte set '-' and 0xE2 0x80 0x93 0x94.
func blockedNames(body string) []string {
	var out []string
	for _, line := range splitLines(body) {
		rest := strings.TrimLeft(line, cSpace)
		if !strings.HasPrefix(rest, "-") {
			continue
		}
		name := strings.TrimLeft(rest[1:], cSpace)
		if k := strings.Index(lowerASCII(name), "needs:"); k >= 0 {
			name = trimDashBytes(strings.TrimRight(name[:k], cSpace))
		}
		if name = strings.Trim(name, cSpace); name != "" {
			out = append(out, name)
		}
	}
	return out
}

// trimDashBytes drops a trailing run of the bytes of the C-locale bracket [-–—]: '-' and 0xE2 0x80 0x93 0x94.
// It works on bytes on purpose (strings.TrimRight would read the cutset as UTF-8). With the first needs: at k,
// the script's two seds keep exactly s[:k] without its trailing blanks and that run, because a later, dashed
// needs: cut by the first sed is cut earlier by the second.
func trimDashBytes(s string) string {
	w := len(s)
	for w > 0 && strings.IndexByte("-\xe2\x80\x93\x94", s[w-1]) >= 0 {
		w--
	}
	return s[:w]
}

// lowerASCII lower-cases the ASCII letters only, byte for byte (the C locale of sed's I flag), so indexes into
// the result are indexes into s.
func lowerASCII(s string) string {
	b := []byte(s)
	for i, c := range b {
		if c >= 'A' && c <= 'Z' {
			b[i] = c + 'a' - 'A'
		}
	}
	return string(b)
}

// isBlocked is is_blocked: 0 the gap is blocked, 1 it is not, 2 the blocked status is UNKNOWN (the state file
// could not be read, a degraded derivation: callers fail closed). The typed line goes to stderr.
func (c *ctx) isBlocked(gap string) int {
	raw, err := os.ReadFile(c.abs(c.state))
	if err != nil { // IS-BLOCKED-DEGRADED: an unreadable blocked section must not read as "nothing is blocked"
		fmt.Fprintf(c.s.Err, "research-sdd-status: blocked sections could not be extracted (rc 3 on %s) — blocked status UNKNOWN (degraded derivation; callers fail closed)\n", c.state)
		return 2
	}
	names := blockedNames(blockedBody(string(raw)))
	if len(names) == 0 { // `while read` over the here-string of an empty list sees one empty line
		names = []string{""}
	}
	for _, n := range names {
		if n == gap {
			return 0
		}
	}
	return 1
}
