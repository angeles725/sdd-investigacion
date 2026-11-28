package gate

import (
	"strings"
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
//   - more than pfMaxAlts alternatives are not enumerated and count as possibly anything.
//
// So a name with no literal part and an unknown expression (`${{ matrix.n }}`) could be anything and blocks; a name
// whose literal parts fit chk in order (`shell${{ x }}`, `${{ x }}check` for chk=shellcheck) blocks; the real
// `${{ matrix.shard == 0 && 'rsdd-go-bridge' || format('rsdd-go-bridge ({0}/3)', matrix.shard) }}` can only be
// `rsdd-go-bridge` or `rsdd-go-bridge (*/3)`, which are neither shellcheck nor toolbelt-tests, so it does not block them.
// A job whose name cannot be chk is not a carrier of chk even when its id is chk (its check is not named chk).

// pfMaxAlts bounds the alternatives enumerated for one name; beyond it the name counts as possibly anything.
const pfMaxAlts = 64

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
	for _, a := range alts {
		if a.matches(chk) || (id == chk && a.matches("")) {
			return true
		}
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
