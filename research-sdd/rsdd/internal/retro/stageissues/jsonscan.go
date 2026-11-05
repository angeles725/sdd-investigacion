package stageissues

import (
	"errors"
	"strconv"
	"strings"
)

// errJSONScan is the awk `exit 3`: the reply could not be read to the end (an unterminated string, unbalanced
// brackets). The caller counts it as a failed lookup, never as "no match".
var errJSONScan = errors.New("stageissues: unparseable gh json reply")

// scanMode selects what jsonIssueScan reports.
type scanMode int

const (
	// scanSig: keep the issues whose BODY holds needle (a signature) as a whole line; reply `[{"state":"…"},…]` + total.
	scanSig scanMode = iota
	// scanSigs: one `<number> <STATE>` line per such issue + total (the unclassifiable-tracker lookup).
	scanSigs
	// scanOcc: line 1 = the space-separated numbers of the OPEN issues whose title EQUALS needle, then total.
	scanOcc
)

// jsonIssueScan is _json_issue_scan: the ONE reader of every `gh issue list --json …` reply. It is a small JSON
// tokenizer (strings, escapes, brace depth) written to match the bash awk byte for byte, quirks included: only
// body/state/title strings and the number digits of each depth-2 object are captured, and a `\uXXXX` escape
// decodes to its ASCII character, `·` for U+00B7 and `?` for anything else (a documented limit). A quoted
// `"state":"OPEN"` or `},{` INSIDE a body can never be mistaken for structure.
func jsonIssueScan(mode scanMode, needle, reply string) (string, error) {
	s := reply + "\n"
	n := len(s)
	var (
		depth, nout, nocc, total int
		vmode                    bool
		key, body, state, title  string
		num                      string
		out, occout, sigout      strings.Builder
	)
	processObject := func() {
		if mode == scanOcc {
			total++
			if state == "OPEN" && title == needle && isDigits(num) {
				if nocc > 0 {
					occout.WriteByte(' ')
				}
				nocc++
				occout.WriteString(num)
			}
			return
		}
		hit := false
		for _, ln := range strings.Split(body, "\n") {
			if strings.TrimRight(ln, " \t\r") == needle {
				hit = true
				break
			}
		}
		total++
		if hit && mode == scanSigs {
			sigout.WriteString(num + " " + state + "\n")
			return
		}
		if hit {
			if nout > 0 {
				out.WriteByte(',')
			}
			nout++
			out.WriteString(`{"state":"` + state + `"}`)
		}
	}
	for i := 0; i < n; {
		c := s[i]
		if c == '"' {
			var str strings.Builder
			i++
			closed := false
			for i < n {
				c = s[i]
				if c == '\\' {
					// s always ends in the "\n" appended above, so a backslash is never the last byte.
					e := s[i+1]
					switch {
					case e == 'n':
						str.WriteByte('\n')
					case e == 'r':
						str.WriteByte('\r')
					case e == 't':
						str.WriteByte('\t')
					case e == 'b':
						str.WriteByte('\b')
					case e == 'f':
						str.WriteByte('\f')
					case e == 'u':
						end := min(i+6, n)
						start := min(i+2, n)
						switch cp := hexval(s[start:end]); {
						case cp >= 0 && cp < 128:
							str.WriteByte(byte(cp))
						case cp == 183:
							str.WriteString("·")
						default:
							str.WriteByte('?')
						}
						i += 4
					default:
						str.WriteByte(e)
					}
					i += 2
					continue
				}
				if c == '"' {
					closed = true
					break
				}
				str.WriteByte(c)
				i++
			}
			if !closed {
				return "", errJSONScan
			}
			i++
			if depth == 2 {
				if vmode {
					switch key {
					case "body":
						body = str.String()
					case "state":
						state = str.String()
					case "title":
						title = str.String()
					}
					vmode = false
				} else {
					key = str.String()
				}
			}
			continue
		}
		if depth == 2 && vmode && c >= '0' && c <= '9' { // a bare number value (the issue number)
			j := i
			for s[j] >= '0' && s[j] <= '9' { // s ends in "\n", so the run always stops before n
				j++
			}
			if key == "number" {
				num = s[i:j]
			}
			i, vmode = j, false
			continue
		}
		switch {
		case c == '{' || c == '[':
			depth++
			if c == '{' && depth == 2 {
				body, state, title, num, key, vmode = "", "", "", "", "", false
			}
		case c == '}' || c == ']':
			if c == '}' && depth == 2 {
				processObject()
			}
			depth--
			if depth < 0 {
				return "", errJSONScan
			}
		case c == ':' && depth == 2:
			vmode = true
		case c == ',' && depth == 2:
			vmode = false
		}
		i++
	}
	if depth != 0 {
		return "", errJSONScan
	}
	tot := "total=" + strconv.Itoa(total) + "\n"
	switch mode {
	case scanOcc:
		return occout.String() + "\n" + tot, nil
	case scanSigs:
		return sigout.String() + tot, nil
	}
	return "[" + out.String() + "]\n" + tot, nil
}

func isDigits(s string) bool {
	if s == "" {
		return false
	}
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return false
		}
	}
	return true
}

// hexval is the awk helper: the value of the hex digits of h (a short h, even an empty one, is read as far as it
// goes), -1 on a non-hex character.
func hexval(h string) int {
	v := 0
	for k := 0; k < len(h); k++ {
		c := h[k]
		var d int
		switch {
		case c >= '0' && c <= '9':
			d = int(c - '0')
		case c >= 'a' && c <= 'f':
			d = int(c-'a') + 10
		case c >= 'A' && c <= 'F':
			d = int(c-'A') + 10
		default:
			return -1
		}
		v = v*16 + d
	}
	return v
}
