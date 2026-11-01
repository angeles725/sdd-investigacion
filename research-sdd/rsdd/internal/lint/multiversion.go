package lint

// Port of lint-block-packs/multi-version.py: R8, an "N5-only / new in N5 / absent from N4" claim about a software
// surface with no 4.15 / PowerB baseline token in the same clause. The judgement is positional (negation, question and
// "whether" scopes), so the regexes with lookarounds became small scanners over the clause.

import (
	"strings"
	"unicode/utf8"
)

var (
	r8TriggerRE  = reCI(`N5-only|new in N5|added in N5|introduced in N5|absent from N4`)
	r8BaselineRE = reCI(`(?:^|[^\p{Nd}.])4\.15(?:$|[^\p{Nd}])|PowerB`) // (?<![\d.])4\.15(?!\d)|PowerB
	r8SurfaceRE  = reCI(alt(
		`\.jar`+rb, `\.class`+rb, lb+`jars?`+rb, lb+`class(?:es)?`+rb, lb+`modules?`+rb, lb+`packages?`+rb, lb+`features?`+rb, lb+`API`+rb,
	))
	// R8_NEGATION_RE's negation words; the `\b` before, the `(?!\s+(?:only|...)\b)` after "not" and the anchored tail
	// `\s+(?:\w+\s+){0,2}$` are code (r8Negation).
	r8NegWordRE = reCI(`not|never|isn't|aren't|wasn't|weren't`)
	r8NotOnlyRE = reCI(`^(?:only|just|merely|simply|solely)` + rb)
	r8WhetherRE = reCI(`whether`)
	r8OrNotRE   = reCI(`^` + ws + `+or` + ws + `+not` + rb) // the (?!\s+or\s+not\b) lookahead, applied to the tail
	// R8_QUESTION_OPEN_RE `^\s*(?:(?:\d+\.|[-*])\s+)?(?:is|are|was|were|does|did)\b`.
	r8QuestionOpenRE = reCI(`^` + ws + `*(?:(?:\p{Nd}+\.|[-*])` + ws + `+)?(?:is|are|was|were|does|did)` + rb)
	// The `,(?=\s*(?:isn't it|...)\s*\?)` lookahead of R8_QUESTION_END_RE, applied to the text after the comma.
	r8TagQuestionRE = reCI(`^` + ws + `*(?:isn't it|aren't they|doesn't it|don't they|right|no)` + ws + `*\?`)
)

func r8Baseline(c string) bool     { return r8BaselineRE.MatchString(c) }
func r8Surface(c string) bool      { return r8SurfaceRE.MatchString(c) }
func r8QuestionOpen(s string) bool { return r8QuestionOpenRE.MatchString(s) }

// r8Negation is R8_NEGATION_RE.search(before): a negation word (not at a word boundary; "not" not followed by
// only / just / merely / simply / solely) then whitespace, up to two words each followed by whitespace, then the end.
func r8Negation(s string) bool {
	for _, loc := range r8NegWordRE.FindAllStringIndex(s, -1) {
		if wordBefore(s, loc[0]) {
			continue
		}
		p := skipSpace(s, loc[1])
		if p == loc[1] {
			continue // `\s+` needs at least one
		}
		if strings.EqualFold(s[loc[0]:loc[1]], "not") && r8NotOnlyRE.MatchString(s[p:]) {
			continue
		}
		for g := 0; ; g++ {
			if p == len(s) {
				return true
			}
			if g == 2 {
				break
			}
			q := p
			for q < len(s) {
				r, n := utf8.DecodeRuneInString(s[q:])
				if !isPyWord(r) {
					break
				}
				q += n
			}
			if q == p {
				break
			}
			r := skipSpace(s, q)
			if r == q {
				break
			}
			p = r
		}
	}
	return false
}

// r8Whether is R8_WHETHER_RE.search(before): `\bwhether\b` not followed by `\s+or\s+not\b` ("whether or not" defers
// nothing).
func r8Whether(s string) bool {
	for _, loc := range r8WhetherRE.FindAllStringIndex(s, -1) {
		if wordBefore(s, loc[0]) || wordAfter(s, loc[1]) || r8OrNotRE.MatchString(s[loc[1]:]) {
			continue
		}
		return true
	}
	return false
}

type r8Span struct {
	start, end int
	question   bool
}

// r8Spans is spans_of(clause, end_re): the clause cut at every boundary of R8_SENTENCE_END_RE (`\?|[;.!](?=\s)`) or,
// with fine, R8_QUESTION_END_RE (`\?|[;.!](?=\s)|[()]|,(?=<tag question>)`). A boundary is one ASCII rune; a span
// records whether it ended at a `?`. The last span runs to the end and is never a question.
func r8Spans(clause string, fine bool) []r8Span {
	var spans []r8Span
	start := 0
	for i := 0; i < len(clause); i++ {
		hit := false
		switch c := clause[i]; c {
		case '?':
			hit = true
		case ';', '.', '!':
			hit = spaceAt(clause, i+1)
		case '(', ')':
			hit = fine
		case ',':
			hit = fine && r8TagQuestionRE.MatchString(clause[i+1:])
		}
		if hit {
			spans = append(spans, r8Span{start, i, clause[i] == '?'})
			start = i + 1
		}
	}
	return append(spans, r8Span{start, len(clause), false})
}

// spaceAt is the lookahead `(?=\s)` at byte i.
func spaceAt(s string, i int) bool {
	r, n := utf8.DecodeRuneInString(s[i:])
	return n > 0 && isPySpace(r)
}

// spanAt is span_at: the first span with start <= pos < max(end, start+1).
func spanAt(spans []r8Span, pos int) (r8Span, bool) {
	for _, s := range spans {
		if s.start <= pos && pos < max(s.end, s.start+1) {
			return s, true
		}
	}
	return r8Span{}, false
}

// isR8Claim: some trigger sits in a sentence that is not a question and whose part before the trigger (after the last
// comma) is neither a "whether" clause nor negated.
func isR8Claim(c string) bool {
	if !r8Surface(c) {
		return false
	}
	sentences, fine := r8Spans(c, false), r8Spans(c, true)
	for _, t := range r8TriggerRE.FindAllStringIndex(c, -1) {
		sent, ok1 := spanAt(sentences, t[0])
		part, ok2 := spanAt(fine, t[0])
		if !ok1 || !ok2 {
			continue
		}
		if part.question || r8QuestionOpen(c[sent.start:sent.end]) {
			continue
		}
		before := c[sent.start:t[0]]
		before = before[strings.LastIndex(before, ",")+1:]
		if !r8Whether(before) && !r8Negation(before) {
			return true
		}
	}
	return false
}

func multiVersionRules() []packRule {
	return []packRule{{"R8", claimRule("R8", isR8Claim, r8Baseline,
		"N5-only/baseline claim without a 4.15 baseline check", nil)}}
}
