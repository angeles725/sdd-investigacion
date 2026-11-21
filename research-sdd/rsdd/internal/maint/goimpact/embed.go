package goimpact

import (
	"go/ast"
	"path"
	"strconv"
	"strings"
)

// recoverEmbeds collects the //go:embed patterns of the non-test files of one package.
func recoverEmbeds(pkg *Package, files []*ast.File) {
	for _, f := range files {
		for _, g := range f.Comments {
			for _, c := range g.List {
				if rest, ok := strings.CutPrefix(c.Text, "//go:embed "); ok {
					pkg.Embeds = append(pkg.Embeds, splitPatterns(rest)...)
				}
			}
		}
	}
}

// splitPatterns splits a //go:embed argument list: space-separated, each pattern optionally "quoted" or `quoted`.
func splitPatterns(s string) []string {
	var out []string
	for s = strings.TrimSpace(s); s != ""; s = strings.TrimSpace(s) {
		end := strings.IndexAny(s, " \t")
		if q := s[0]; q == '"' || q == '`' {
			end = strings.IndexByte(s[1:], q) + 2
			if end < 2 {
				end = len(s)
			}
		}
		if end < 0 {
			end = len(s)
		}
		tok := s[:end]
		if u, err := strconv.Unquote(tok); err == nil {
			tok = u
		}
		out = append(out, tok)
		s = s[end:]
	}
	return out
}

// EmbedOwner returns the package dir whose //go:embed patterns name the module-relative file rel, or "" (the
// root package owns "" too, so a miss is reported by ok).
func (m *Module) EmbedOwner(rel string) (string, bool) {
	for dir := path.Dir(rel); ; dir = path.Dir(dir) {
		d := dir
		if d == "." {
			d = ""
		}
		if p := m.Pkgs[d]; p != nil && p.embeds(strings.TrimPrefix(strings.TrimPrefix(rel, d), "/")) {
			return d, true
		}
		if d == "" {
			return "", false
		}
	}
}

// embeds reports whether a pattern matches r (relative to the package dir), either the file or one of its
// directories: embedding a directory embeds the files below it.
func (p *Package) embeds(r string) bool {
	for _, pat := range p.Embeds {
		pat = strings.TrimPrefix(pat, "all:")
		for cur := r; cur != "." && cur != ""; cur = path.Dir(cur) {
			if ok, _ := path.Match(pat, cur); ok {
				return true
			}
		}
	}
	return false
}
