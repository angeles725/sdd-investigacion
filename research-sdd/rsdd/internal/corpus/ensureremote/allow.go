package ensureremote

import "strings"

// The Layer 4c allow list (kit issue #1943): `<target>/.research-sdd/secret-files.conf`, one `allow <path-glob>`
// per line, `#` comments and blank lines ignored.

const (
	allowRel = ".research-sdd/secret-files.conf"
	// globOnly is the set tr -d removes before the blanket test: a glob made only of these has no literal character.
	globOnly = "[]!()@+|*?/."
)

// allowEntry is one accepted `allow <glob>` line and its 1-based line number.
type allowEntry struct {
	glob string
	line int
}

// isBlank is the default IFS of `read`, minus the newline that already split the lines.
func isBlank(c byte) bool { return c == ' ' || c == '\t' }

// fields3 is `read -r a b c`: the first two blank-separated words and the rest of the line, with the blanks
// around the rest trimmed.
func fields3(l string) (kw, g, extra string) {
	i := 0
	word := func() string {
		for i < len(l) && isBlank(l[i]) {
			i++
		}
		j := i
		for j < len(l) && !isBlank(l[j]) {
			j++
		}
		w := l[i:j]
		i = j
		return w
	}
	kw = word()
	g = word()
	for i < len(l) && isBlank(l[i]) {
		i++
	}
	extra = strings.TrimRight(l[i:], " \t")
	return
}

// parseAllow reads the list. A malformed line stops the parse: badLine is its number and why the reason. Rules,
// none silent: a blanket glob (only `*`, `?`, `/`, `.` and operator characters), an absolute path or a `..`
// component is malformed, and so are bracket classes and extglob operators (a glob may only use `*` and `?`).
func parseAllow(data []byte) (entries []allowEntry, badLine int, why string) {
	s := string(data)
	if s == "" {
		return nil, 0, ""
	}
	s = strings.TrimSuffix(s, "\n")
	for n, l := range strings.Split(s, "\n") {
		ln := n + 1
		l = strings.TrimSuffix(l, "\r")
		kw, g, extra := fields3(l)
		if kw == "" || strings.HasPrefix(kw, "#") {
			continue
		}
		switch {
		case kw != "allow":
			why = "unknown directive '" + kw + "'"
		case g == "":
			why = "'allow' needs a path glob"
		case extra != "":
			why = "exactly one path glob per line (got extra text)"
		case strings.ContainsAny(g, "[]"):
			why = "bracket class in '" + g + "' (a glob may only use '*' and '?')"
		case hasExtglob(g):
			why = "extglob operator in '" + g + "' (a glob may only use '*' and '?')"
		case strings.Trim(g, globOnly) == "":
			why = "blanket glob '" + g + "' (needs at least one literal character)"
		default:
			if strings.HasPrefix(g, "/") {
				why = "absolute path '" + g + "' (use a path relative to the corpus root)"
			}
			if strings.Contains("/"+g+"/", "/../") {
				why = "'..' component in '" + g + "'"
			}
		}
		if why != "" {
			return nil, ln, why
		}
		entries = append(entries, allowEntry{glob: g, line: ln})
	}
	return entries, 0, ""
}

func hasExtglob(g string) bool {
	for _, op := range []string{"!(", "@(", "+(", "*(", "?("} {
		if strings.Contains(g, op) {
			return true
		}
	}
	return false
}

// globMatch is `[[ $p == $glob ]]` for a glob that holds only `*` (any run, `/` included), `?` (any one
// character, `/` included) and backslash escapes.
func globMatch(glob, p string) bool {
	g, s := 0, 0
	star, mark := -1, 0
	for s < len(p) {
		switch {
		case g < len(glob) && glob[g] == '*':
			star, mark = g, s
			g++
		case g < len(glob) && glob[g] == '?':
			g++
			s++
		case g < len(glob) && globLit(glob, g) == p[s]:
			g += litWidth(glob, g)
			s++
		case star >= 0:
			g = star + 1
			mark++
			s = mark
		default:
			return false
		}
	}
	for g < len(glob) && glob[g] == '*' {
		g++
	}
	return g == len(glob)
}

// globLit is the literal byte at glob[g]: the escaped one after a backslash, a lone trailing backslash included.
func globLit(glob string, g int) byte {
	if glob[g] == '\\' && g+1 < len(glob) {
		return glob[g+1]
	}
	return glob[g]
}

func litWidth(glob string, g int) int {
	if glob[g] == '\\' && g+1 < len(glob) {
		return 2
	}
	return 1
}
