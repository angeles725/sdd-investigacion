package stageissues

import (
	"regexp"
	"strings"
)

// The pre-mutation privacy scrub (kit issue #1707): a Go port of lib/scrub-issue-text.sh (retired with kit issue #2717;
// the frozen copy under testdata/legacy/lib is the differential oracle), kept inside this package because only
// stage-issues uses it. Every title, body and comment is scrubbed BEFORE the first gh call. Redaction classes, each
// replacement counting once: bare credential tokens, Authorization/Bearer credentials, credential-named
// KEY=VALUE assignments, emails, absolute home paths.
//
// The bash is a POSIX awk program run per line under mawk/gawk. Its regexes are POSIX leftmost-longest, so they
// are compiled with regexp.CompilePOSIX; every character class is a byte class (the kit pins LC_ALL=C).

var (
	reCredToken = regexp.MustCompilePOSIX(`(gh[pousr]_[A-Za-z0-9]+|github_pat_[A-Za-z0-9_]+|sk-[A-Za-z0-9_-]{9}[A-Za-z0-9_-]+|AKIA[A-Z0-9]{16})`)
	reAuthKW    = regexp.MustCompilePOSIX(`(authorization:[ \t]*(bearer|token)|bearer)[ \t]+`)
	reAuthTok   = regexp.MustCompilePOSIX(`^[A-Za-z0-9._~+/=-]{16}[A-Za-z0-9._~+/=-]*`)
	reAssign    = regexp.MustCompilePOSIX(`[A-Za-z_][A-Za-z0-9_]*=`)
	reEmail     = regexp.MustCompilePOSIX(`[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+[.][A-Za-z][A-Za-z]+`)
	reValue     = regexp.MustCompilePOSIX("^[^[:space:]`\"'),;]*")
	// A home-rooted absolute path; the tail after the user dir is part of the token.
	rePath = regexp.MustCompilePOSIX("(/home/[^/[:space:]]+|/Users/[^/[:space:]]+|/mnt/[a-z]/Users/[^/[:space:]]+|[A-Za-z]:\\\\Users\\\\[^\\\\[:space:]]+)([/\\\\][^\\][:space:]`\"'),;>]*)?|/root/[^\\][:space:]`\"'),;>]*")
)

var credNames = []string{"SECRET", "TOKEN", "PASSWORD", "PASSWD", "CREDENTIAL", "APIKEY", "API_KEY", "PRIVATE_KEY", "ACCESS_KEY", "AUTH", "COOKIE", "BEARER", "SESSION"}

func upperASCII(s string) string {
	b := []byte(s)
	for i, c := range b {
		if c >= 'a' && c <= 'z' {
			b[i] = c - 32
		}
	}
	return string(b)
}

func isAlnum(c byte) bool {
	return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9'
}

// credentialName is the awk key test: AUTHOR is not AUTH (a byline), AUTHORIZATION is.
func credentialName(key string) bool {
	u := upperASCII(key)
	u = strings.ReplaceAll(u, "AUTHORIZ", "AUTH_Z")
	u = strings.ReplaceAll(u, "AUTHOR", "")
	for _, n := range credNames {
		if strings.Contains(u, n) {
			return true
		}
	}
	return false
}

// scrubText is `printf '%s\n' text | scrub_issue_text` inside `$(...)` (trailing newlines dropped) plus the
// count scrub_issue_text_count prints for the same input.
func scrubText(text string) (string, int) {
	lines := strings.Split(text+"\n", "\n")
	lines = lines[:len(lines)-1]
	count := 0
	for i, l := range lines {
		lines[i] = scrubLine(l, &count)
	}
	return trimNL(strings.Join(lines, "\n")), count
}

func scrubLine(line string, count *int) string {
	out := ""
	// 1) bare credential-shaped tokens (a word-internal hit is not a token).
	for {
		loc := reCredToken.FindStringIndex(line)
		if loc == nil {
			break
		}
		if loc[0] > 0 && (isAlnum(line[loc[0]-1]) || line[loc[0]-1] == '_') {
			out += line[:loc[0]+1]
			line = line[loc[0]+1:]
			continue
		}
		out += line[:loc[0]] + "<redacted>"
		line = line[loc[1]:]
		*count++
	}
	line, out = out+line, ""
	// 1b) Authorization-header credentials: `Authorization: Bearer|token <tok>` and a standalone `Bearer <tok>`,
	// case-insensitive, the token at least 16 token characters. Header form only, not `key: value` prose.
	low := lowerASCII(line)
	for {
		loc := reAuthKW.FindStringIndex(low)
		if loc == nil {
			break
		}
		end := loc[1]
		if (loc[0] == 0 || !(isAlnum(low[loc[0]-1]) || low[loc[0]-1] == '_')) && reAuthTok.MatchString(line[end:]) {
			tl := reAuthTok.FindStringIndex(line[end:])
			out += line[:end] + "<redacted>"
			end += tl[1]
			*count++
		} else {
			out += line[:end]
		}
		line, low = line[end:], low[end:]
	}
	line, out = out+line, ""
	// 2) credential-named assignment KEY=VALUE, KEY="VALUE", KEY='VALUE', KEY=`VALUE`, any case; the value is
	// redacted INSIDE its quotes (the quotes stay). An unterminated quote redacts to the end of the line.
	for {
		loc := reAssign.FindStringIndex(line)
		if loc == nil {
			break
		}
		key := line[loc[0] : loc[1]-1]
		out += line[:loc[1]]
		line = line[loc[1]:]
		if !credentialName(key) {
			continue
		}
		if line != "" && (line[0] == '"' || line[0] == '\'' || line[0] == '`') {
			q := line[:1]
			e := strings.Index(line[1:], q) + 1 // awk index(): 1-based, 0 when absent
			var v, rest string
			if e == 0 {
				v, rest = line, ""
			} else {
				v, rest = line[1:e], line[e+1:]
			}
			if v == "" || v == "<redacted>" {
				continue
			}
			out += q + "<redacted>"
			if e != 0 {
				out += q
			}
			line = rest
			*count++
			continue
		}
		v := reValue.FindString(line)
		if v == "" || v == "<redacted>" {
			continue
		}
		out += "<redacted>"
		line = line[len(v):]
		*count++
	}
	line, out = out+line, ""
	// 3) emails.
	for {
		loc := reEmail.FindStringIndex(line)
		if loc == nil {
			break
		}
		out += line[:loc[0]] + "<email>"
		line = line[loc[1]:]
		*count++
	}
	line, out = out+line, ""
	// 4) absolute home paths, after a boundary: a home-rooted path is redacted unless the character right before
	// it is a URL/path-segment character (the middle of a longer path or URL); a rejected candidate never hides a
	// later real path.
	for {
		start, end, ok := boundaryPath(line)
		if !ok {
			break
		}
		out += line[:start] + "<path>"
		line = line[end:]
		*count++
	}
	return out + line
}

// boundaryPath is awk bmatch(): the first path match that starts the line or follows a non-segment character.
func boundaryPath(s string) (int, int, bool) {
	off := 0
	rest := s
	for {
		loc := rePath.FindStringIndex(rest)
		if loc == nil {
			return 0, 0, false
		}
		start := loc[0] + off
		if start == 0 || !segmentChar(s[start-1]) {
			return start, loc[1] + off, true
		}
		off += loc[0] + 1
		rest = rest[loc[0]+1:]
	}
}

func segmentChar(c byte) bool {
	return isAlnum(c) || c == '.' || c == '_' || c == '~' || c == '%' || c == '/' || c == '-'
}
