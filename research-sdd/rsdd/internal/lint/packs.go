package lint

// Port of the pack machinery of lint_block.py (kit #1365 item 1): the rule registry, the pack loader, clauses(),
// make_claim_rule() and excerpt(). The four packs live in jvm.go, multiversion.go, nativebinary.go and childgap.go.
//
// The packs were Python modules exec'd against lint_block.py as their API; they are compiled in now, so the loader's
// source-level failure states (missing directory, syntax error, build() that raises or returns nothing) cannot occur
// and are gone with the directory. What stays typed: an invalid or unknown name, an empty list, an id that is not
// reserved or is already active, and a rule that crashes at run time.
//
// Go's regexp has no lookarounds and its `\b \w \s \d` are ASCII-only, while Python's are Unicode-aware. Every
// assertion in the packs is rewritten as code or as a CONSUMING construct (a regex alternative that also eats the
// neighbouring rune), which is exact for the existence tests the packs use; each rewrite is documented where it is
// used and pinned by lookaround_test.go against the frozen Python.

import (
	"errors"
	"fmt"
	"regexp"
	"sort"
	"strings"
)

const (
	// nonWord is `\W` and lb / rb are `\b` before / after a word rune, written as consuming alternatives:
	// `\bfoo\b` is lb+`foo`+rb. Both eat the neighbouring rune, so they are only used where a match's extent beyond
	// its own tokens is never needed (every existence test).
	nonWord = `[^` + wordClass + `]`
	lb      = `(?:^|` + nonWord + `)`
	rb      = `(?:$|` + nonWord + `)`
	// nonWordNL is a non-word rune that is also not a newline: the one rune that closes a `\b` on either side of a
	// `.{0,n}` gap (`.` never matches \n).
	nonWordNL = `[^` + wordClass + `\n]`
)

// gap is `\b.{0,n}\b` between a token that ends with a word rune and one that starts with a word rune. A zero-length
// gap can never hold the two boundaries, so the gap is 1..n runes whose first and last runes are non-word (the same
// rune when n == 1): nonWordNL(?:.{0,n-2}nonWordNL)?.
func gap(n int) string { return nonWordNL + fmt.Sprintf(`(?:.{0,%d}`, n-2) + nonWordNL + `)?` }

// reCI compiles p case-insensitively with Python's extra folds: under re.IGNORECASE the ASCII letter `i` also matches
// U+0130 and U+0131 (Go folds k to U+212A and s to U+017F, like Python, but not these two). The pattern is the
// lookaround-free Go dialect plus this rule: letters inside a character class are not supported (panics at init).
func reCI(p string) *regexp.Regexp { return regexp.MustCompile("(?i)" + foldI(p)) }

func foldI(p string) string {
	var b strings.Builder
	inClass := false
	for i := 0; i < len(p); i++ {
		c := p[i]
		switch {
		case c == '\\' && i+1 < len(p):
			b.WriteByte(c)
			i++
			b.WriteByte(p[i])
			switch {
			case strings.IndexByte("xpP", p[i]) >= 0 && i+1 < len(p) && p[i+1] == '{': // \x{..} \p{..}
				j := strings.IndexByte(p[i:], '}')
				b.WriteString(p[i+1 : i+j+1])
				i += j
			case p[i] == 'x' && i+2 < len(p): // \xHH
				b.WriteString(p[i+1 : i+3])
				i += 2
			}
		case !inClass && c == '(' && i+1 < len(p) && p[i+1] == '?': // a group flag: (?: (?i: (?i)
			j := i + 2
			for j < len(p) && p[j] != ':' && p[j] != ')' {
				j++
			}
			b.WriteString(p[i : j+1])
			i = j
		case !inClass && c == '[':
			inClass = true
			b.WriteByte(c)
		case inClass && c == ']':
			inClass = false
			b.WriteByte(c)
		case inClass && (c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z'):
			panic("foldI: a letter inside a character class is not supported: " + p)
		case !inClass && (c == 'i' || c == 'I'):
			b.WriteString(`[iI\x{130}\x{131}]`)
		default:
			b.WriteByte(c)
		}
	}
	return b.String()
}

// pyLower is str.lower() for the text the packs lower-case: U+0130 lowers to "i" + U+0307 (full mapping), where Go's
// unicode.ToLower gives a plain "i".
func pyLower(s string) string {
	return strings.ToLower(strings.ReplaceAll(s, "\u0130", "i\u0307"))
}

// ---- unit helpers ---------------------------------------------------------------------------------------------

func claimKind(k string) bool { return k == "para" || k == "item" || k == "row" || k == "heading" }

// bump adds n to a pack counter, registering the key (so a SUMMARY prints `<key>=0` once the rule has run).
func (d *doc) bump(key string, n int) { d.cov.pack[key] += n }

// ---- clauses --------------------------------------------------------------------------------------------------

// CLAUSE_SPLIT_RE `(?<=[a-z0-9)`\]])[.;!?]\s+(?=[A-Z0-9`*\[(])`: both lookarounds look at ASCII runes only.
func clauseBefore(c byte) bool {
	return c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == ')' || c == '`' || c == ']'
}

func clauseAfter(c byte) bool {
	return c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '`' || c == '*' || c == '[' || c == '('
}

// clauseSplit is CLAUSE_SPLIT_RE.split(text): the punctuation and the whitespace after it are consumed, the two
// lookarounds are explicit looks at the byte before and the rune after the (maximal) whitespace run.
func clauseSplit(text string) []string {
	var parts []string
	start := 0
	for i := 0; i < len(text); {
		c := text[i]
		if (c == '.' || c == ';' || c == '!' || c == '?') && i > 0 && clauseBefore(text[i-1]) {
			j := skipSpace(text, i+1)
			if j > i+1 && j < len(text) && clauseAfter(text[j]) {
				parts = append(parts, text[start:i])
				start, i = j, j
				continue
			}
		}
		i++
	}
	return append(parts, text[start:])
}

// clauses is lint_block.clauses(): the claims of a unit, trimmed, empty ones dropped; the whole text when none is left.
func clauses(text string) []string {
	var out []string
	for _, c := range clauseSplit(text) {
		if s := pyStrip(c); s != "" {
			out = append(out, s)
		}
	}
	if len(out) == 0 {
		return []string{text}
	}
	return out
}

// ---- rule factory ---------------------------------------------------------------------------------------------

type ruleFn func(*doc) []finding

// claimRule is make_claim_rule(): a clause that makes a claim and carries no clearing evidence is a finding, at most
// one per unit; every claim clause seen is counted in `r<N>_triggers`; quotedSkip skips a unit made only of `>` lines
// that matches it, counted in `r<N>_quoted_skipped` (registered even at 0).
func claimRule(id string, isClaim, isCleared func(string) bool, message string, quotedSkip func(string) bool) ruleFn {
	qkey := strings.ToLower(id) + "_quoted_skipped"
	covkey := strings.ToLower(id) + "_triggers"
	return func(d *doc) []finding {
		var out []finding
		if quotedSkip != nil {
			d.bump(qkey, 0)
		}
		for _, u := range d.units {
			if !claimKind(u.kind) {
				continue
			}
			for _, c := range clauses(u.text) {
				if !isClaim(c) {
					continue
				}
				if quotedSkip != nil && u.quoted && quotedSkip(u.text) {
					d.bump(qkey, 1)
					continue
				}
				d.bump(covkey, 1)
				if isCleared(c) || d.waived(id, u) {
					continue
				}
				out = append(out, finding{u.line, id, message + ": " + pyExcerpt(c, 100)})
				break
			}
		}
		return out
	}
}

// ---- registry and loader --------------------------------------------------------------------------------------

type packRule struct {
	id string
	fn ruleFn
}

// packBuilders are the compiled-in packs, by name (the old `lint-block-packs/NAME.py`).
var packBuilders = map[string]func() []packRule{
	"child-gap":     childGapRules,
	"jvm":           jvmRules,
	"multi-version": multiVersionRules,
	"native-binary": nativeBinaryRules,
}

func packNames() []string {
	var out []string
	for n := range packBuilders {
		out = append(out, n)
	}
	sort.Strings(out)
	return out
}

// linter is one run's rule set: the core R3 and R6, then the rules of the loaded packs in load order (Python kept
// this in module globals; a Go run owns it, so concurrent runs cannot see each other's packs).
type linter struct {
	rules  []packRule
	ids    []string
	loaded []string
	packed []string // ids registered by packs, in load order
}

func newLinter() *linter {
	return &linter{
		rules: []packRule{{"R3", ruleR3}, {"R6", ruleR6}},
		ids:   []string{"R3", "R6"},
	}
}

var packNameRE = regexp.MustCompile(`^[a-z0-9][a-z0-9-]*$`)

// loadPacks is load_packs: idempotent per name; the first failure aborts and nothing is linted.
func (lt *linter) loadPacks(names []string) error {
	for _, name := range names {
		// Python's `$` also matches before one trailing newline: such a name passes the shape check and then
		// fails the lookup, like any unknown name.
		if !packNameRE.MatchString(strings.TrimSuffix(name, "\n")) {
			return fmt.Errorf("invalid pack name %s (lower-case letters, digits and '-' only)", pyRepr(name))
		}
		if inList(lt.loaded, name) {
			continue
		}
		build, ok := packBuilders[name]
		if !ok {
			return fmt.Errorf("unknown pack %s (available: %s)", name, strings.Join(packNames(), ", "))
		}
		if err := lt.register(name, build()); err != nil {
			return err
		}
	}
	return nil
}

// register validates and appends one pack's rules (the checks load_packs ran on build()'s result).
func (lt *linter) register(name string, rules []packRule) error {
	if len(rules) == 0 {
		return errors.New("pack " + name + " registered no rules")
	}
	for _, r := range rules {
		if inList(lt.ids, r.id) {
			return fmt.Errorf("pack %s: rule %s is already active", name, r.id)
		}
		if !inList(reservedPackRuleIDs, r.id) {
			return fmt.Errorf("pack %s: %s is not a reserved pack rule id (%s)", name, r.id, strings.Join(reservedPackRuleIDs, ", "))
		}
		lt.rules = append(lt.rules, r)
		lt.ids = append(lt.ids, r.id)
		lt.packed = append(lt.packed, r.id)
	}
	lt.loaded = append(lt.loaded, name)
	return nil
}
