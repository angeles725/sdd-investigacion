package java

import (
	"os"
	"sort"
	"strings"
	"unicode"
)

// The pure derivations of the report: what javap and jdeps printed, which expected classes the decompilers
// covered, and how the three decompilers' outputs compare.

// pySpace is str.isspace for one rune: Unicode white space plus the C0 separators \x1c-\x1f.
func pySpace(r rune) bool { return unicode.IsSpace(r) || (r >= 0x1c && r <= 0x1f) }

// splitLines is str.splitlines(): \n, \r, \r\n, \v, \f, \x1c-\x1e, \x85,   and   end a line; no
// trailing empty line.
func splitLines(s string) []string {
	var lines []string
	rs := []rune(s)
	var cur []rune
	for i := 0; i < len(rs); i++ {
		r := rs[i]
		switch r {
		case '\n', '\v', '\f', 0x1c, 0x1d, 0x1e, 0x85, 0x2028, 0x2029:
		case '\r':
			if i+1 < len(rs) && rs[i+1] == '\n' {
				i++
			}
		default:
			cur = append(cur, r)
			continue
		}
		lines = append(lines, string(cur))
		cur = cur[:0]
	}
	if len(cur) > 0 {
		lines = append(lines, string(cur))
	}
	return lines
}

// readText is Path.read_text(errors="replace"): invalid UTF-8 becomes U+FFFD.
func readText(path string) (string, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return "", osFailure(err, path)
	}
	return strings.ToValidUTF8(string(b), "�"), nil
}

func sortedSet(items []string) []string {
	seen := map[string]bool{}
	out := []string{}
	for _, it := range items {
		if !seen[it] {
			seen[it] = true
			out = append(out, it)
		}
	}
	sort.Strings(out)
	return out
}

// signatures is signatures(): the sorted distinct javap lines that end a member declaration with ";" or start a
// descriptor.
func signatures(path string) ([]string, error) {
	text, err := readText(path)
	if err != nil {
		return nil, err
	}
	var keep []string
	for _, line := range splitLines(text) {
		line = strings.TrimFunc(line, pySpace)
		if strings.HasSuffix(line, ";") || strings.HasPrefix(line, "descriptor:") {
			keep = append(keep, line)
		}
	}
	return sortedSet(keep), nil
}

// dependencyLines is dependency_lines(): the sorted distinct non-empty jdeps lines.
func dependencyLines(path string) ([]string, error) {
	text, err := readText(path)
	if err != nil {
		return nil, err
	}
	var keep []string
	for _, line := range splitLines(text) {
		if line = strings.TrimFunc(line, pySpace); line != "" {
			keep = append(keep, line)
		}
	}
	return sortedSet(keep), nil
}

// coverage is coverage(): which expected classes a decompiler produced a .java file for (an inner class counts
// through its outermost class).
func coverage(expected []string, inventory []outputRecord) map[string]any {
	sources := map[string]bool{}
	for _, it := range inventory {
		if strings.HasSuffix(it.path, ".java") {
			sources[strings.ReplaceAll(strings.TrimSuffix(it.path, ".java"), "/", ".")] = true
		}
	}
	covered, missing := []string{}, []string{}
	for _, class := range expected {
		outer, _, _ := strings.Cut(class, "$")
		if sources[class] || sources[outer] {
			covered = append(covered, class)
		} else {
			missing = append(missing, class)
		}
	}
	sort.Strings(covered)
	sort.Strings(missing)
	return map[string]any{"covered": covered, "missing": missing, "covered_count": len(covered), "expected_count": len(expected)}
}

// engineOrder is the decompilers in the order comparisons pair them.
var engineOrder = []string{"vineflower", "cfr", "procyon"}

// comparisons is comparisons(): for each pair of decompilers, which output paths they share, with and without
// the same hash, and which only one of them wrote.
func comparisons(engines map[string][]outputRecord) []map[string]any {
	var names []string
	for _, n := range engineOrder {
		if _, ok := engines[n]; ok {
			names = append(names, n)
		}
	}
	results := []map[string]any{}
	for i, left := range names {
		for _, right := range names[i+1:] {
			a, b := hashes(engines[left]), hashes(engines[right])
			common, same, different := []string{}, []string{}, []string{}
			for p := range a {
				if _, ok := b[p]; ok {
					common = append(common, p)
				}
			}
			sort.Strings(common)
			for _, p := range common {
				if a[p] == b[p] {
					same = append(same, p)
				} else {
					different = append(different, p)
				}
			}
			results = append(results, map[string]any{
				"engines": []string{left, right}, "common_paths": common,
				"same_hash_paths": same, "different_hash_paths": different,
				"only_left": only(a, b), "only_right": only(b, a),
			})
		}
	}
	return results
}

func hashes(records []outputRecord) map[string]string {
	m := map[string]string{}
	for _, r := range records {
		m[r.path] = r.sha256
	}
	return m
}

// only is sorted(set(a) - set(b)).
func only(a, b map[string]string) []string {
	out := []string{}
	for p := range a {
		if _, ok := b[p]; !ok {
			out = append(out, p)
		}
	}
	sort.Strings(out)
	return out
}

// disagreements keeps the comparisons in which the decompilers differ.
func disagreements(all []map[string]any) []map[string]any {
	out := []map[string]any{}
	for _, c := range all {
		if len(c["different_hash_paths"].([]string)) > 0 || len(c["only_left"].([]string)) > 0 || len(c["only_right"].([]string)) > 0 {
			out = append(out, c)
		}
	}
	return out
}
