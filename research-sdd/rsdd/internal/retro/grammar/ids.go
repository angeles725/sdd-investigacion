package grammar

import (
	"regexp"
	"sort"
	"strings"
)

// Delta-id rules shared by every parser of table rows and `## Delta <ID> —` headings (_RG_AWK_ID_FN, kit issues
// #1934 #1938). The bash consumers (stage-retro-issues.sh, reconcile-issues.sh) embed the same awk functions.

var reDeltaIDShape = regexp.MustCompile(`^[A-Z][A-Z0-9]*(-[A-Z0-9]+)?$`)

// DeltaID is rg_delta_id: a delta id written in capitals, one capital letter (`A`) or at most 8 capitals/digits
// carrying a digit or one hyphen (`R1`, `SO2`, `SPKI-A`). A bare word (`ID`, `DELTA`, `TOTAL`) is not an id.
func DeltaID(tok string) bool {
	if !reDeltaIDShape.MatchString(tok) || len(tok) > 8 {
		return false
	}
	return len(tok) == 1 || strings.ContainsAny(tok, "0123456789-")
}

// TableIDSkip is rg_table_id_skip: the first cell of a table row is separator debris or a header word, not a row
// id. A cell carrying a digit (`1`, `D1`, `B12`) is never skipped; a capitalised id (DeltaID) neither.
func TableIDSkip(rid string) bool { return isDebris(rid) || (headerWord(rid) && !DeltaID(rid)) }

// isDebris is a separator cell: only `-` and `:`.
func isDebris(rid string) bool { return rid != "" && onlyBytes(rid, "-:") }

// headerWord is awk `rid ~ /^[[:alpha:]#][^0-9]*$/ && rid !~ /^[A-Z][0-9]/`: a letter or `#` first and no digit
// anywhere. The second bash clause can never be false once the first holds (no digit at all), so it is dead and
// not ported (doc.go, finding F1).
func headerWord(rid string) bool {
	return rid != "" && (isASCIIAlpha(rid[0]) || rid[0] == '#') && !strings.ContainsAny(rid, "0123456789")
}

// IDSignatureSafe is retro_grammar_id_signature_safe (#2135): a non-empty id of [A-Za-z0-9_-] only, the
// characters the `Source retro: <retro> · <id>` signature round-trips.
func IDSignatureSafe(id string) bool {
	return id != "" && onlyBytes(id, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
}

// DupIDs is retro_grammar_dup_ids (`LC_ALL=C sort | uniq -d`): each id occurring more than once, once, in
// bytewise order. A numbered list restarts at 1, so two lists in one retro collide here.
func DupIDs(ids []string) []string {
	s := append([]string(nil), ids...)
	sort.Strings(s)
	var out []string
	for i := 1; i < len(s); i++ {
		if s[i] == s[i-1] && (len(out) == 0 || out[len(out)-1] != s[i]) {
			out = append(out, s[i])
		}
	}
	return out
}

func isASCIIAlpha(c byte) bool { c |= 0x20; return 'a' <= c && c <= 'z' }

// onlyBytes reports whether every byte of s is in the ASCII set (true for an empty s). An ASCII cutset makes
// strings.Trim a byte operation: a non-ASCII byte is never in the set.
func onlyBytes(s, set string) bool { return strings.Trim(s, set) == "" }
