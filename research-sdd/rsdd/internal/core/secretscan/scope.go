package secretscan

import "strings"

// File scope: authored Markdown plus high-risk config files, the surfaces a researcher writes a credential onto.
// Vendored and decompiled trees are the object of study (or third-party code), where scanning is all false positives.

// excludedDirs are the vendored/decompiled directory names whose subtree is out of scope wherever they appear. The
// working-tree walk and --files-from additionally never enter `.git` (see gitDir); a committed path can hold a
// `.git` component (a hand-built tree), and the legacy history scan scanned it, so the committed rule does not
// exclude it.
var excludedDirs = map[string]bool{
	"node_modules": true, ".venv": true, "venv": true,
	"decompiled": true, "vineflower": true, "procyon": true, "cfr": true, "jadx": true,
}

const gitDir = ".git"

// nameInScope reports whether a file with this base name is scanned: *.md, *.env, .env*, *.conf, *.ini,
// *.properties, *.cfg, config.* and credentials.
func nameInScope(name string) bool {
	switch {
	case strings.HasSuffix(name, ".md"), strings.HasSuffix(name, ".env"), strings.HasPrefix(name, ".env"),
		strings.HasSuffix(name, ".conf"), strings.HasSuffix(name, ".ini"), strings.HasSuffix(name, ".properties"),
		strings.HasSuffix(name, ".cfg"), strings.HasPrefix(name, "config."), name == "credentials":
		return true
	}
	return false
}

// dirExcluded reports whether any component of the slash-separated directory path is an excluded name (and, when
// skipGit, `.git`).
func dirExcluded(dir string, skipGit bool) bool {
	for _, c := range strings.Split(dir, "/") {
		if excludedDirs[c] || skipGit && c == gitDir {
			return true
		}
	}
	return false
}

// splitPath splits rel into its directory part ("" when there is none) and its base name.
func splitPath(rel string) (dir, base string) {
	i := strings.LastIndexByte(rel, '/') // -1: no directory part, so dir is "" and base is the whole path
	return rel[:max(i, 0)], rel[i+1:]
}

// pathInScope is the scope test of a --files-from entry: the base name decides what is scanned (the legacy
// `case` over the base name), and `.git` and the vendored names exclude by directory component.
func pathInScope(rel string) bool {
	dir, base := splitPath(rel)
	return nameInScope(base) && !dirExcluded(dir, true)
}

// committedInScope is the scope test of a committed blob path. The legacy history scan matched regexes over the
// whole path: `(^|/)config\.` puts a file under ANY `config.`-prefixed component in scope, not only a file named
// so, and `.git` is not an excluded component. Every other rule (suffixes, `.env*`, `credentials`) is a base-name
// rule in both, so nameInScope answers it.
func committedInScope(rel string) bool {
	dir, base := splitPath(rel)
	return (nameInScope(base) || hasConfigComponent(dir)) && !dirExcluded(dir, false)
}

// hasConfigComponent reports whether a component of the directory path starts with `config.`.
func hasConfigComponent(dir string) bool {
	for _, c := range strings.Split(dir, "/") {
		if strings.HasPrefix(c, "config.") {
			return true
		}
	}
	return false
}
