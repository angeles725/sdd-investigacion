package lint

// Port of lint-block-packs/jvm.py: R1 (syntax adoption), R5 (permission dispatch) and R7 (constant inlining).
// Vocabulary and messages are the Python's; the lookarounds / Unicode `\b` are rewritten as documented per regex.

import (
	"strings"
	"unicode"
	"unicode/utf8"
)

const wcls = wordClass // inside a character class

func alt(parts ...string) string { return strings.Join(parts, "|") }

var (
	r1FeatureRE = reCI(alt(
		`pattern-`+ws+`*match(?:ing)?`, `instanceof`+ws+`+pattern`, `JEP`+ws+`*394`, `switch`+ws+`+expression`,
		`arrow`+ws+`+switch`, `text`+ws+`+block`, `record`+ws+`+pattern`,
		lb+`records?`+ws+`*/`+ws+`*sealed`+rb, "`var`", lb+`var`+ws+`+(?:keyword|declarations?|inference)`+rb,
		`local[`+wsClass+`-]+variable`+ws+`+type`+ws+`+inference`,
		lb+`sealed`+ws+`+(?:classes|class|interfaces|interface|hierarch[`+wcls+`]*|types?)`+rb,
		`enhanced`+ws+`+for`, `for-each`, lb+`lambda`+rb,
	))
	r1VerbRE = reCI(alt(
		lb+`(?:uses?|adopts?|adopted|adoption|rewrites?|rewritten|replaces?|replaced|modernized)`+rb,
		`migrated to`, `converted to`, `N5 now`, `new in N5`, `Java[`+wsClass+`-]21[`+wsClass+`-]?style`,
	))
	// A decompiler (CFR, Vineflower, Procyon) is deliberately NOT evidence: it resugars (see jvm.py).
	r1EvidenceRE = reCI(alt(
		lb+`(?:javap|typeSwitch|SwitchBootstraps|LambdaMetafactory|PermittedSubclasses|docSource|bytecode|LocalVariableTable)`+rb,
		`Record attribute`, `extends`+ws+`+java\.lang\.Record`, `class-file attribute`,
	))

	r5ConsequenceRE = reCI(alt(
		`fail-open`, `fails?`+ws+`+open`, lb+`no-op`+rb, lb+`bypass(?:es|ed)?`+rb, lb+`ungated`+rb,
		`drops?`+ws+`+cx`+rb, `null`+ws+`+Context`, `getPermissions\(null\)`,
	))
	// R5_ACCESS_CTX_RE, case-sensitive. Its `(?<!\[)\bBlock\b(?!\s*\d)` alternative is code (blockCitation).
	r5AccessCtxRE = newLazyRE(alt(
		lb+`polic(?:y|ies)`+rb, lb+`Bypass`+ws+`+actions?`+rb, lb+`action:`,
		lb+`(?:Access|Allow|Include|Exclude|Require)`+rb, lb+`Service`+ws+`+Auth`+rb,
	))
	// The `(?=\s+(?:policy|policies|action|rule)s?\b)` lookahead of the code-span form, applied to the text after it.
	r5ActionTailRE = newLazyRE(`^` + ws + `+(?:policy|policies|action|rule)s?` + rb)

	r5PermCtxCI = reCI(alt(
		lb+`permissions?`+rb, `getPermissions`, lb+`security`+rb, lb+`credentials?`+rb, lb+`o?auth\p{Nd}?`+rb, lb+`authn`+rb,
		lb+`authz`+rb, lb+`(?:un|de)?(?:authenticat|authoriz|authoris)`, lb+`null[`+wsClass+`-]+context`+rb,
	))
	// `Context` and `cx` are case-sensitive: lower-case "context" is ordinary English (see jvm.py).
	r5PermCtxCS = newLazyRE(lb + `Context` + rb + `|` + lb + `cx` + rb)

	// R5_CLEARED_RE `(?:dispatch|cited-absence):\s*(?!<placeholder>(?!\w))(?=\S*[A-Za-z0-9]{3,})\S{3,}`: after the
	// token the whitespace is maximal (a shorter run leaves a space where both lookaheads need a non-space), and the
	// two lookaheads and the body are all about the one non-space run that starts there.
	r5ClearedTokenRE       = reCI(`(?:dispatch|cited-absence):`)
	r5ClearedPlaceholderRE = reCI(`^(?:todo|tbd|tba|tbc|xxx|n/?a|none|nil|null|unknown|unresolved|pending|unclear|missing|fixme|wip|\?+)` + rb)
	// [A-Za-z0-9]{3,} under re.IGNORECASE also takes U+0130, U+0131, U+017F and U+212A.
	r5Alnum3RE = newLazyRE(`[A-Za-z0-9\x{130}\x{131}\x{17f}\x{212a}]{3,}`)

	r5GapRefRE = reCI(alt(
		`^`+ws+`*Gap`+rb, lb+`G\p{Nd}+`+ws+`*:`, lb+`B\p{Nd}+-G\p{Nd}+`+rb, lb+`gap`+ws+`+G\p{Nd}+`, lb+`see`+ws+`+block`+rb,
		`\[Block`+ws+`*\p{Nd}+\]`, lb+`block\p{Nd}+\.md`+rb,
	))

	// R7: `\bX\b.{0,n}\bY\b` is lb X gap(n) Y rb (see gap in packs.go); a token followed by `\w*\b` needs no rb of its
	// own because the gap's first rune is non-word.
	r7TriggerRE = reCI(alt(
		lb+`(?:dead|unused|unreferenced)`+ws+`+constants?`+rb,
		lb+`constants?`+gap(15)+`(?:is|are)`+gap(15)+`(?:dead|unused|unreferenced)`+rb,
		lb+`shadow[`+wcls+`]*`+gap(40)+`literal`+rb,
		lb+`literal`+gap(40)+`shadow[`+wcls+`]*`+rb,
		lb+`duplicat[`+wcls+`]*`+nonWordNL+`.{0,24}(?:its own`+ws+`+)?constants?`+rb,
		lb+`constants?`+gap(25)+`duplicat[`+wcls+`]*`+rb,
		lb+`hardcod[`+wcls+`]*`+gap(80)+`instead of`+gap(40)+`constant`+rb,
	))
	r7EvidenceRE = reCI(alt(
		`compile-time constant`, `JLS`+ws+`*4\.12\.4`, `JLS`+ws+`*13\.1`, lb+`ldc`+rb, lb+`docSource`+rb,
		lb+`inlin[`+wcls+`]*`+nonWordNL+`.{0,24}(?:constant|compiler|javac|javap|bytecode)`,
		`(?:constant|compiler|javac|javap|bytecode)(?:.{0,24}`+nonWordNL+`)inlin[`+wcls+`]*`+rb,
	))
)

func jvmR1Feature(c string) bool  { return r1FeatureRE.MatchString(c) }
func jvmR1Verb(c string) bool     { return r1VerbRE.MatchString(c) }
func jvmR1Evidence(c string) bool { return r1EvidenceRE.MatchString(c) }
func jvmR5GapRef(t string) bool   { return r5GapRefRE.MatchString(t) }
func jvmR7Trigger(c string) bool  { return r7TriggerRE.MatchString(c) }
func jvmR7Evidence(c string) bool { return r7EvidenceRE.MatchString(c) }

// blockCitation is `(?<!\[)\bBlock\b(?!\s*\d)`: the word Block, not after `[`, not glued to word runes, and not
// followed (after optional whitespace) by a digit, which would make it a kit block citation.
func blockCitation(c string) bool {
	for off := 0; ; {
		i := strings.Index(c[off:], "Block")
		if i < 0 {
			return false
		}
		i += off
		end := i + len("Block")
		if r, n := utf8.DecodeLastRuneInString(c[:i]); !(n > 0 && (isPyWord(r) || r == '[')) && !wordAfter(c, end) {
			if r, n := utf8.DecodeRuneInString(c[skipSpace(c, end):]); !(n > 0 && unicode.Is(unicode.Nd, r)) {
				return true
			}
		}
		off = i + 1
	}
}

func jvmAccessCtx(c string) bool { return r5AccessCtxRE.MatchString(c) || blockCitation(c) }

// jvmAccessScrub is the first half of r5_consequence: in a clause with Access-policy wording, the capitalised bare
// `Bypass` and a code-span `bypass` directly followed by policy / action / rule are replaced by a \x00 sentinel (so
// neighbouring words cannot join). R5_ACCESS_ACTION_RE `\bBypass\b|`bypass`(?=\s+(?:policy|policies|action|rule)s?\b)`
// is scanned left to right like re.sub: the lookahead is a look at the text after the code span.
func jvmAccessScrub(c string) string {
	if !jvmAccessCtx(c) {
		return c
	}
	var b strings.Builder
	for i := 0; i < len(c); {
		switch {
		case strings.HasPrefix(c[i:], "Bypass") && !wordBefore(c, i) && !wordAfter(c, i+len("Bypass")):
			b.WriteByte(0)
			i += len("Bypass")
		case strings.HasPrefix(c[i:], "`bypass`") && r5ActionTailRE.MatchString(c[i+len("`bypass`"):]):
			b.WriteByte(0)
			i += len("`bypass`")
		default:
			_, n := utf8.DecodeRuneInString(c[i:])
			b.WriteString(c[i : i+n])
			i += n
		}
	}
	return b.String()
}

func jvmR5Consequence(c string) bool { return r5ConsequenceRE.MatchString(jvmAccessScrub(c)) }

func jvmR5PermContext(c string) bool { return r5PermCtxCI.MatchString(c) || r5PermCtxCS.MatchString(c) }

func jvmR5Cleared(c string) bool {
	for _, loc := range r5ClearedTokenRE.FindAllStringIndex(c, -1) {
		q := skipSpace(c, loc[1])
		if r5ClearedPlaceholderRE.MatchString(c[q:]) {
			continue
		}
		end := q
		for end < len(c) {
			r, n := utf8.DecodeRuneInString(c[end:])
			if isPySpace(r) {
				break
			}
			end += n
		}
		if r5Alnum3RE.MatchString(c[q:end]) { // three alnum runes also satisfy \S{3,}
			return true
		}
	}
	return false
}

func jvmRules() []packRule {
	return []packRule{
		{"R1", claimRule("R1", func(c string) bool { return jvmR1Feature(c) && jvmR1Verb(c) }, jvmR1Evidence,
			"syntax-adoption claim without bytecode/docSource evidence", nil)},
		{"R5", claimRule("R5", func(c string) bool { return jvmR5Consequence(c) && jvmR5PermContext(c) }, jvmR5Cleared,
			"permission consequence claim without a resolved dispatch: target", jvmR5GapRef)},
		{"R7", claimRule("R7", jvmR7Trigger, jvmR7Evidence, "constant-inlining claim without bytecode/docSource evidence", nil)},
	}
}
