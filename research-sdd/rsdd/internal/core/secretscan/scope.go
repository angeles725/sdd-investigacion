package secretscan

import "strings"

// File scope: authored Markdown plus high-risk config files, the surfaces a researcher writes a credential onto.
// Vendored and decompiled trees are the object of study (or third-party code), where scanning is all false positives.

// excludedDirs are directory names whose subtree is out of scope wherever they appear.
var excludedDirs = map[string]bool{
	".git": true, "node_modules": true, ".venv": true, "venv": true,
	"decompiled": true, "vineflower": true, "procyon": true, "cfr": true, "jadx": true,
}

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

// dirExcluded reports whether any component of the slash-separated directory path is an excluded name.
func dirExcluded(dir string) bool {
	for _, c := range strings.Split(dir, "/") {
		if excludedDirs[c] {
			return true
		}
	}
	return false
}

// pathInScope is the scope test of a whole relative path (a committed blob path or a listed entry).
func pathInScope(rel string) bool {
	i := strings.LastIndexByte(rel, '/') // -1: no directory part, so dir is "" and base is the whole path
	dir, base := rel[:max(i, 0)], rel[i+1:]
	return nameInScope(base) && !dirExcluded(dir)
}
