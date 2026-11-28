package gate

import (
	"strings"
	"unicode"
)

// JOB NAME EXPANSION (kit issue #2852). A workflow job whose `name:` holds a `${{ ... }}` expression is named by its
// expansion, which the path-filter reader cannot compute (matrix values, contexts). Giving up on the whole workflow
// for that (the original, still frozen under testdata/legacy) meant that one matrix job, `rsdd-go-bridge` in
// rsdd-go.yml, made every required check "not evaluated" and a docs-only PR unmergeable through the gate.
//
// THE RULE (fail-closed): pfNameCouldBe is true, and the evaluation stays unsupported, when SOME possible expansion
// of the name could equal the required check chk. The expansion is over-approximated as a set of alternatives, each
// a glob of literal parts with unknown gaps (`lit0 * lit1 * ... * litn`, anchored at both ends):
//   - text outside `${{ }}` is literal;
//   - an expression is evaluated by pfExprAlts: a string literal is itself, `format('t {0}', x)` is its template with
//     every `{n}` a gap, `a && b` is falsy(a) or b, `a || b` is truthy(a) or b (GitHub returns the operand it stopped
//     at), a comparison or `!` is the boolean "true"/"false", `( e )` is e, and anything else (a context such as
//     matrix.n, another function, a number) is one fully unknown value `*`;
//   - an expression the scanner cannot delimit or balance (unterminated `${{`, quote or parenthesis, an empty operand)
//     is not understood, so the name is treated as possibly anything;
//   - an alternative that can be empty also stands for the job id (GitHub names a job by its id when the name
//     expands to nothing), so it could be chk when the id is;
//   - more than pfMaxAlts alternatives, or an alternative of more than pfMaxParts parts, are not enumerated and count as
//     possibly anything (the trimmed readings of an alternative are O(parts^2); an earlier recursion was exponential).
//
// THE SCALAR (the rule above judges the decoded text; GitHub decodes the YAML scalar BEFORE it expands the
// expression, and this reader decodes none of it): a templated `name:` is read only as a plain one-line scalar with
// no escapes, or a quoted one whose body has no escape (pfNameScalar). Anything else could be anything, so it voids
// the evaluation for every required check: a double-quoted scalar containing `\` (an escape such as \x63 or \u0063
// can spell any character, even the `${{` itself, so this holds for a name without `${{` too); a single-quoted one
// containing `'` (`''` decodes to one quote); an opening quote without its matching closing quote (or a different one
// closing it, or a ` # ` comment cutting it off); a trailing `\`; a control character, which includes the CR left on a
// name: line by a mixed or CRLF line ending, and U+2028/U+2029; a double quote inside a double-quoted scalar; and a
// continuation line (the next line that is neither blank nor a comment is indented deeper than the `name:` key),
// which YAML folds into the value with a space. Block scalars and empty values stay unsupported as before.
//
// THE REST OF THE JOB (pfJobNameTrust). The reader looks at one line at a time, so a `name:` line at the job-key indent
// is a key only if no value opened earlier in the job swallowed it: in
//
//	shellcheck:
//	  runs-on: "foo
//	  name: bridge-${{ matrix.n }}"
//
// there is no `name` key at all and GitHub names the check `shellcheck`. So a job with a templated `name:` is judged
// "could be anything" (the typed note `job name shape of <job>`, for every required check) when
//   - any line of the job (the job key line included), outside a block scalar's content, leaves a double quote, a single
//     quote or a `[`/`{` open at its end (after dropping a ` #` comment outside quotes), or has a value that starts with
//     a quote that is not closed on the line (pfLineShape; deliberately over-approximate: an apostrophe in a plain
//     scalar counts as an opening quote); this holds wherever the line is, before or after the name line; or
//   - the job has more than one `name:` line at the job-key indent (YAML keeps one; which one is not decided here).
//
// Scoping: only quotes and flow collections can carry a line across the job-key indent (a block scalar's content and a
// plain scalar's continuation lines are indented deeper than the key that holds them, so they cannot hide a key at the
// job-key indent). So the content of a block scalar (`run: |`, `path: >-`, `- |`; a line whose last token is the
// indicator after `key:` or `-`) is skipped, not scanned: shell text with an apostrophe or a `{` there is not a
// hidden value, and the real rsdd-go-bridge job (`run: |` under steps, `${{ ... '[0]' ... }}` expressions, comments
// with apostrophes) stays evaluated. The block scalar ends at the first line at or left of its key's indent.
//
// NOT CLOSED HERE (they exist in the original too, are independent of a templated name, and are tracked in the
// follow-up kit issue): a quoted `"name":` key, a flow-mapping job, `? name`, `name :`, `Name:`, `name: null`/`~` with the
// id fallback, a non-templated name followed by CR, a column-0 or tab-led line inside a multi-line scalar that hides later
// jobs, and a fake non-templated `name:` line inside a multi-line scalar.
//
// SCOPE NOTE (differs from the original): a NON-templated double-quoted name containing a backslash (`"shell\x63heck"`)
// now voids the evaluation for every check, because an escape can spell any character of a check name; the original
// read it literally and went on.
//
// ASSUMPTIONS (GitHub's behaviour could not be verified, so each is decided fail-closed and pinned by a test):
//   - leading and trailing whitespace of an expansion may be trimmed, so `shellcheck ` (or ` shellcheck`) could be
//     the check `shellcheck`: alternatives are compared after trimming their ends (pfEachTrimmed);
//   - a whitespace-only expansion may count as empty, so the job id fallback applies to it;
//   - check names compare case-insensitively (Unicode simple folding, so U+017F also folds to s), and so does the
//     job id against the check name.
//
// So a name with no literal part and an unknown expression (`${{ matrix.n }}`) could be anything and blocks; a name
// whose literal parts fit chk in order (`shell${{ x }}`, `${{ x }}check` for chk=shellcheck) blocks; the real
// `${{ matrix.shard == 0 && 'rsdd-go-bridge' || format('rsdd-go-bridge ({0}/3)', matrix.shard) }}` can only be
// `rsdd-go-bridge` or `rsdd-go-bridge (*/3)`, which are neither shellcheck nor toolbelt-tests, so it does not block them.
// A job whose name cannot be chk is not a carrier of chk even when its id is chk (its check is not named chk).

// pfMaxAlts bounds the alternatives enumerated for one name; beyond it the name counts as possibly anything.
const pfMaxAlts = 64

// pfMaxParts bounds the parts (literal text between unknown gaps) of one alternative that are enumerated; beyond it the
// name counts as possibly anything. The readings of an alternative grow with the square of its parts (pfEachTrimmed).
const pfMaxParts = 32

// pfAlt is one possible expansion: literal parts separated by unknown gaps (one part = exactly that text), and
// whether it can be a truthy / falsy GitHub expression value.
type pfAlt struct {
	parts         []string
	truthy, falsy bool
}

var pfAny = pfAlt{parts: []string{"", ""}, truthy: true, falsy: true}

// matches reports whether some string in the alternative equals s.
func (a pfAlt) matches(s string) bool {
	n := len(a.parts)
	if n == 1 {
		return s == a.parts[0]
	}
	first, last := a.parts[0], a.parts[n-1]
	if len(s) < len(first)+len(last) || !strings.HasPrefix(s, first) || !strings.HasSuffix(s, last) {
		return false
	}
	mid := s[len(first) : len(s)-len(last)]
	for _, p := range a.parts[1 : n-1] {
		i := strings.Index(mid, p)
		if i < 0 {
			return false
		}
		mid = mid[i+len(p):]
	}
	return true
}

// pfNameCouldBe reports whether the templated job name v (the stripped `name:` value, containing `${{`) of job id
// could expand to chk. It answers true whenever it cannot tell.
func pfNameCouldBe(v, id, chk string) bool {
	alts, ok := pfNameAlts(v)
	if !ok {
		return true
	}
	want, idIsChk := pfFold(chk), pfFold(id) == pfFold(chk)
	for _, a := range alts {
		if len(a.parts) > pfMaxParts {
			return true
		}
		if pfEachTrimmed(a, func(t pfAlt) bool { return t.matches(want) || (idIsChk && t.matches("")) }) {
			return true
		}
	}
	return false
}

// pfFold maps every rune to the smallest member of its Unicode simple-folding orbit, so two strings that
// strings.EqualFold equates fold to the same text (strings.ToLower would keep U+017F and U+212A apart).
func pfFold(s string) string {
	return strings.Map(func(r rune) rune {
		m := r
		for f := unicode.SimpleFold(r); f != r; f = unicode.SimpleFold(f) {
			if f < m {
				m = f
			}
		}
		return m
	}, s)
}

// pfEachTrimmed calls yield with each reading of the alternative as it is compared with a check name, until yield
// returns true (then it returns true too): folded, with the whitespace that could end up at either end of the
// expansion removed. A literal part loses its edge whitespace only at the real edge of the string; when the part at an
// edge is blank, the unknown gap next to it may be blank too, which is one more reading with that gap removed (so
// `shell ` + gap is not trimmed to `shell`, but `shell ` + blank gap is). The readings are exactly the pairs (f, b) of
// f blank parts dropped from the front and b from the back, f+b < len(parts): O(k^2) readings for k parts (an earlier
// recursion that dropped from both ends was exponential in k). The parts of a reading are only valid during the call.
func pfEachTrimmed(a pfAlt, yield func(pfAlt) bool) bool {
	n := len(a.parts)
	folded, blank := make([]string, n), make([]bool, n)
	for i, p := range a.parts {
		folded[i] = pfFold(p)
		blank[i] = strings.TrimSpace(folded[i]) == ""
	}
	buf := make([]string, n)
	for f := 0; f < n; f++ {
		if f > 0 && !blank[f-1] {
			break
		}
		for b := 0; f+b < n; b++ {
			if b > 0 && !blank[n-b] {
				break
			}
			t := buf[:n-f-b]
			copy(t, folded[f:n-b])
			t[0] = strings.TrimLeftFunc(t[0], unicode.IsSpace)
			t[len(t)-1] = strings.TrimRightFunc(t[len(t)-1], unicode.IsSpace)
			if yield(pfAlt{parts: t, truthy: a.truthy, falsy: a.falsy}) {
				return true
			}
		}
	}
	return false
}

// pfEscapedName reports whether the raw text after `name:` is a double-quoted scalar with a backslash: its escapes
// can decode to `${{` (or to any character of a check name), so it is judged like a templated one.
func pfEscapedName(rest string) bool {
	t := pfTrimValue(rest)
	return strings.HasPrefix(t, `"`) && strings.Contains(t, `\`)
}

// pfNameScalar is the text of the raw `name:` value (the text after the colon) when it is a plain one-line scalar or
// a quoted one with no escape; false when the reader cannot tell what GitHub decodes it to (see THE SCALAR).
func pfNameScalar(rest string) (string, bool) {
	t := pfTrimValue(rest)
	if t == "" || strings.HasSuffix(t, `\`) {
		return "", false
	}
	for _, r := range t {
		if unicode.IsControl(r) || r == '\u2028' || r == '\u2029' {
			return "", false
		}
	}
	if t[0] != '"' && t[0] != '\'' {
		return t, true
	}
	q := t[0]
	if len(t) < 2 || t[len(t)-1] != q {
		return "", false
	}
	body := t[1 : len(t)-1]
	if strings.IndexByte(body, q) >= 0 || (q == '"' && strings.Contains(body, `\`)) {
		return "", false
	}
	return body, true
}

// pfContinues reports whether the first line of rest that is neither blank nor a comment is indented deeper than
// the name: key at ind spaces, i.e. continues its scalar (a tab counts as indentation, fail-closed).
func pfContinues(rest []string, ind int) bool {
	for _, row := range rest {
		t := strings.TrimLeft(row, " \t")
		if strings.TrimSpace(t) == "" || t[0] == '#' {
			continue
		}
		return len(row)-len(t) > ind
	}
	return false
}

// pfNameAlts splits v at its `${{ }}` expressions: literal text between them, the alternatives of each expression.
func pfNameAlts(v string) ([]pfAlt, bool) {
	alts := []pfAlt{{parts: []string{""}, truthy: true}}
	for v != "" {
		i := strings.Index(v, "${{")
		var next []pfAlt
		if i != 0 {
			lit := v
			if i > 0 {
				lit = v[:i]
			}
			next = []pfAlt{{parts: []string{lit}, truthy: true}}
			v = v[len(lit):]
		} else {
			end := pfExprEnd(v[3:])
			if end < 0 {
				return nil, false
			}
			e, ok := pfExprAlts(v[3 : 3+end])
			if !ok {
				return nil, false
			}
			next = e
			v = v[3+end+2:]
		}
		var cross []pfAlt
		for _, a := range alts {
			for _, b := range next {
				parts := append([]string{}, a.parts[:len(a.parts)-1]...)
				parts = append(parts, a.parts[len(a.parts)-1]+b.parts[0])
				parts = append(parts, b.parts[1:]...)
				cross = append(cross, pfAlt{parts: parts, truthy: true})
			}
		}
		if len(cross) > pfMaxAlts {
			return nil, false
		}
		alts = cross
	}
	return alts, true
}

// pfExprEnd is the offset of the `}}` that closes the expression text s, skipping single-quoted strings; -1 if none.
func pfExprEnd(s string) int {
	inq := false
	for i := 0; i < len(s); i++ {
		switch {
		case s[i] == '\'':
			inq = !inq
		case !inq && strings.HasPrefix(s[i:], "}}"):
			return i
		}
	}
	return -1
}

// pfSplitTop splits s at every top-level occurrence of op (outside single-quoted strings and parentheses). It fails
// on an unbalanced quote or parenthesis and on an empty piece.
func pfSplitTop(s, op string) ([]string, bool) {
	var out []string
	depth, start, inq := 0, 0, false
	for i := 0; i < len(s); i++ {
		switch {
		case s[i] == '\'':
			inq = !inq
		case inq:
		case s[i] == '(':
			depth++
		case s[i] == ')':
			if depth--; depth < 0 {
				return nil, false
			}
		case depth == 0 && strings.HasPrefix(s[i:], op):
			out = append(out, s[start:i])
			start = i + len(op)
			i += len(op) - 1
		}
	}
	if inq || depth != 0 {
		return nil, false
	}
	out = append(out, s[start:])
	for i, p := range out {
		if out[i] = strings.TrimSpace(p); out[i] == "" {
			return nil, false
		}
	}
	return out, true
}

// pfFilter keeps the alternatives that can be truthy (truth=true) or falsy, narrowed to that one reading.
func pfFilter(alts []pfAlt, truth bool) []pfAlt {
	var out []pfAlt
	for _, a := range alts {
		if (truth && a.truthy) || (!truth && a.falsy) {
			out = append(out, pfAlt{parts: a.parts, truthy: truth, falsy: !truth})
		}
	}
	return out
}

// pfExprAlts is the alternatives of one expression body (`a || b`, `a && b`, an operand).
func pfExprAlts(e string) ([]pfAlt, bool) {
	ors, ok := pfSplitTop(e, "||")
	if !ok {
		return nil, false
	}
	var res []pfAlt
	for i, o := range ors {
		ands, ok := pfSplitTop(o, "&&")
		if !ok {
			return nil, false
		}
		var r []pfAlt
		for j, a := range ands {
			v, ok := pfOperandAlts(a)
			if !ok {
				return nil, false
			}
			if j == 0 {
				r = v
			} else {
				r = append(pfFilter(r, false), v...)
			}
		}
		if i == 0 {
			res = r
		} else {
			res = append(pfFilter(res, true), r...)
		}
		if len(res) > pfMaxAlts {
			return nil, false
		}
	}
	return res, true
}

// pfWrapped reports whether s is `<prefix>(...)` with the first `(` closing at the very end of s.
func pfWrapped(s string) (inner string, ok bool) {
	i := strings.IndexByte(s, '(')
	if i < 0 || s[len(s)-1] != ')' {
		return "", false
	}
	depth, inq := 0, false
	for j := i; j < len(s); j++ {
		switch {
		case s[j] == '\'':
			inq = !inq
		case inq:
		case s[j] == '(':
			depth++
		case s[j] == ')':
			if depth--; depth == 0 {
				return s[i+1 : j], j == len(s)-1
			}
		}
	}
	return "", false
}

// pfStringLit decodes a whole single-quoted expression string (`”` is one quote).
func pfStringLit(s string) (string, bool) {
	if len(s) < 2 || s[0] != '\'' || s[len(s)-1] != '\'' {
		return "", false
	}
	body := s[1 : len(s)-1]
	var b strings.Builder
	for i := 0; i < len(body); i++ {
		if body[i] == '\'' {
			if i+1 < len(body) && body[i+1] == '\'' {
				b.WriteByte('\'')
				i++
				continue
			}
			return "", false
		}
		b.WriteByte(body[i])
	}
	return b.String(), true
}

// pfFormat is the alternative of format('template', args...): the template's text with every `{n}` an unknown gap.
func pfFormat(args string) (pfAlt, bool) {
	list, ok := pfSplitTop(args, ",")
	if !ok {
		return pfAlt{}, false
	}
	tpl, ok := pfStringLit(list[0])
	if !ok {
		return pfAlt{}, false
	}
	parts, cur := []string{}, strings.Builder{}
	for i := 0; i < len(tpl); i++ {
		switch {
		case strings.HasPrefix(tpl[i:], "{{"), strings.HasPrefix(tpl[i:], "}}"):
			cur.WriteByte(tpl[i])
			i++
		case tpl[i] == '{':
			j := i + 1
			for j < len(tpl) && tpl[j] >= '0' && tpl[j] <= '9' {
				j++
			}
			if j == i+1 || j >= len(tpl) || tpl[j] != '}' {
				return pfAlt{}, false
			}
			parts = append(parts, cur.String())
			cur.Reset()
			i = j
		default:
			cur.WriteByte(tpl[i])
		}
	}
	parts = append(parts, cur.String())
	empty := true
	for _, p := range parts {
		empty = empty && p == ""
	}
	return pfAlt{parts: parts, truthy: true, falsy: empty}, true
}

// pfCompares reports whether the operand is a boolean-valued comparison or negation at its top level.
func pfCompares(s string) bool {
	if strings.HasPrefix(s, "!") {
		return true
	}
	depth, inq := 0, false
	for i := 0; i < len(s); i++ {
		switch {
		case s[i] == '\'':
			inq = !inq
		case inq:
		case s[i] == '(':
			depth++
		case s[i] == ')':
			depth--
		case depth == 0 && (s[i] == '<' || s[i] == '>' || strings.HasPrefix(s[i:], "==") || strings.HasPrefix(s[i:], "!=")):
			return true
		}
	}
	return false
}

// pfOperandAlts is the alternatives of one operand of && / ||.
func pfOperandAlts(a string) ([]pfAlt, bool) {
	if s, ok := pfStringLit(a); ok {
		return []pfAlt{{parts: []string{s}, truthy: s != "", falsy: s == ""}}, true
	}
	if pfCompares(a) {
		return []pfAlt{{parts: []string{"true"}, truthy: true}, {parts: []string{"false"}, falsy: true}}, true
	}
	if inner, ok := pfWrapped(a); ok {
		fn := strings.TrimSpace(a[:strings.IndexByte(a, '(')])
		switch {
		case fn == "":
			return pfExprAlts(inner)
		case strings.EqualFold(fn, "format"):
			if f, ok := pfFormat(inner); ok {
				return []pfAlt{f}, true
			}
		}
	}
	if _, ok := pfSplitTop(a, ","); !ok {
		return nil, false
	}
	return []pfAlt{pfAny}, true
}

// pfJobNameTrust reports whether the templated name of a job cannot be trusted: it has a templated `name:` line and
// either more than one `name:` line at the job-key indent or a line that leaves a value open (see THE REST OF THE JOB).
func pfJobNameTrust(templated bool, names int, tainted bool) bool {
	return templated && (names > 1 || tainted)
}

// pfLineEnd scans one line (YAML indentation already removed): the index where a ` #` comment starts outside quotes
// (len(s) when there is none), and whether a double quote, a single quote or a `[`/`{` is still open there. Inside
// double quotes a backslash escapes the next character; inside single quotes a doubled quote is one quote.
func pfLineEnd(s string) (cut int, open bool) {
	var q byte
	depth := 0
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case q == '"':
			if c == '\\' {
				i++
			} else if c == '"' {
				q = 0
			}
		case q == '\'':
			if c == '\'' {
				if i+1 < len(s) && s[i+1] == '\'' {
					i++
				} else {
					q = 0
				}
			}
		case c == '"' || c == '\'':
			q = c
		case c == '[' || c == '{':
			depth++
		case (c == ']' || c == '}') && depth > 0:
			depth--
		case c == '#' && (i == 0 || s[i-1] == ' ' || s[i-1] == '\t'):
			return i, depth > 0
		}
	}
	return len(s), q != 0 || depth > 0
}

// pfLineShape classifies one line of a job: open when the line leaves a quote or a flow collection open (the value
// goes on in the next line, where it can hide a key), else block when the line opens a block scalar (its last token
// is `|` or `>` with optional chomping/indentation indicators, right after `key:` or `-` or alone).
func pfLineShape(line string) (open, block bool) {
	cut, open := pfLineEnd(line)
	if open {
		return true, false
	}
	s := line[:cut]
	// a value that starts with a quote and is not closed on the line, whatever an earlier stray quote did to the
	// scan above (`it's: "foo's`): after each `key:` and after leading `-` items
	starts := []int{}
	for rest, off := s, 0; ; {
		t := strings.TrimLeft(rest, " \t")
		if t != "-" && !strings.HasPrefix(t, "- ") {
			break
		}
		off += len(rest) - len(t) + 1
		rest = rest[len(rest)-len(t)+1:]
		starts = append(starts, off)
	}
	for i := 0; i < len(s); i++ {
		if s[i] == ':' && (i+1 == len(s) || s[i+1] == ' ' || s[i+1] == '\t') {
			starts = append(starts, i+1)
		}
	}
	for _, at := range starts {
		v := strings.TrimLeft(s[at:], " \t")
		if v != "" && (v[0] == '"' || v[0] == '\'') {
			if _, o := pfLineEnd(v); o {
				return true, false
			}
		}
	}
	f := strings.FieldsFunc(s, func(r rune) bool { return r == ' ' || r == '\t' })
	if len(f) == 0 || !pfBlockIndicator(f[len(f)-1]) {
		return false, false
	}
	if len(f) == 1 {
		return false, true
	}
	prev := f[len(f)-2]
	return false, prev == "-" || strings.HasSuffix(prev, ":")
}

// pfBlockIndicator is `|` or `>` followed by at most two chomping (`+`/`-`) or indentation (digit) indicators.
func pfBlockIndicator(t string) bool {
	if len(t) == 0 || len(t) > 3 || (t[0] != '|' && t[0] != '>') {
		return false
	}
	for _, c := range t[1:] {
		if c != '+' && c != '-' && (c < '0' || c > '9') {
			return false
		}
	}
	return true
}
