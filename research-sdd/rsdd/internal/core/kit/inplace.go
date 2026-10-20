package kit

import (
	"regexp"
	"strings"
)

const posixSpace = " \t\n\v\f\r"

// InplaceGapID is inplace_gap_id: the normalised leading ID token of a gap cell or bullet (`**` and a trailing
// `.` or `:` stripped, upcased), or "" when the text has none. ID-shaped means [A-Za-z0-9][A-Za-z0-9.-]* holding
// a digit or at most 3 characters: a plain word such as `Builders` is never an ID.
func InplaceGapID(text string) string {
	t := strings.TrimLeft(text, posixSpace)
	t = strings.TrimPrefix(t, "**")
	if i := strings.IndexAny(t, posixSpace); i >= 0 {
		t = t[:i]
	}
	t = strings.TrimSuffix(t, "**")
	if len(t) > 0 && (t[len(t)-1] == '.' || t[len(t)-1] == ':') {
		t = t[:len(t)-1]
	}
	if t == "" || strings.Trim(t, "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.-") != "" {
		return ""
	}
	if c := t[0]; c == '.' || c == '-' {
		return ""
	}
	if !strings.ContainsAny(t, "0123456789") && len(t) > 3 {
		return ""
	}
	return strings.ToUpper(t)
}

var (
	reNeedsBullet = regexp.MustCompile(`(?i)^[ \t\n\v\f\r]*-[ \t\n\v\f\r].*needs:`)
	reBulletHead  = regexp.MustCompile(`^[ \t\n\v\f\r]*-[ \t\n\v\f\r]*`)
	reDashNeeds   = regexp.MustCompile(`(?i)[ \t\n\v\f\r]*[-–—]+[ \t\n\v\f\r]*needs:.*$`)
	reNeeds       = regexp.MustCompile(`(?i)[ \t\n\v\f\r]*needs:.*$`)
)

func cutAt(re *regexp.Regexp, s string) string {
	if loc := re.FindStringIndex(s); loc != nil {
		return s[:loc[0]]
	}
	return s
}

// readTab3 is `IFS=$'\t' read -r _ gap st`: tab is IFS whitespace, so leading tabs are dropped and a run of tabs
// is ONE separator (an empty first cell shifts the others left: finding F10). The last variable takes the rest
// with trailing tabs removed.
func readTab3(line string) (a, b, c string) {
	s := strings.TrimLeft(line, "\t")
	cut := func() string {
		i := strings.IndexByte(s, '\t')
		if i < 0 {
			f := s
			s = ""
			return f
		}
		f := s[:i]
		s = strings.TrimLeft(s[i:], "\t")
		return f
	}
	a = cut()
	b = cut()
	c = strings.TrimRight(s, "\t")
	return a, b, c
}

// InplaceBlockedCount is inplace_blocked_count: the number of OPEN backlog rows whose leading status token is the
// in-place blocked form (`blocked`, `blocked:`, `blocked,` or `blocked-on-*`) that blocked_open does not already
// count. rows is the backlog_rows stream ("priority<TAB>gap<TAB>status", status already lowercased). Closed rows
// (a struck gap, ~~ or a check mark in the status) are skipped, and a row also listed under the Blocked-gaps body
// is counted once (by exact name or by gap ID), but only a bullet that carries `needs:` may suppress a row.
// A final row without a trailing newline is counted (bash drops it: finding F9).
func InplaceBlockedCount(blockedBody, rows string) int {
	names := map[string]bool{}
	ids := map[string]bool{}
	for _, l := range strings.Split(blockedBody, "\n") {
		if !reNeedsBullet.MatchString(l) {
			continue
		}
		n := reBulletHead.ReplaceAllString(l, "")
		n = cutAt(reNeeds, cutAt(reDashNeeds, n))
		n = strings.Trim(n, posixSpace)
		names[n] = true
		if id := InplaceGapID(n); id != "" {
			ids[id] = true
		}
	}
	count := 0
	for _, line := range strings.Split(rows, "\n") {
		if line == "" {
			continue
		}
		_, gap, st := readTab3(line)
		if gap == "" || strings.Contains(gap, "~~") || strings.Contains(st, "~~") || strings.Contains(st, "✅") {
			continue
		}
		lead := strings.TrimPrefix(st, "**")
		lead = strings.Replace(lead, "**", "", 1)
		tok, _, _ := strings.Cut(lead, " ")
		if !(tok == "blocked" || tok == "blocked:" || tok == "blocked," || strings.HasPrefix(tok, "blocked-on-")) {
			continue
		}
		if names[gap] {
			continue
		}
		if id := InplaceGapID(gap); id != "" && ids[id] {
			continue
		}
		count++
	}
	return count
}
