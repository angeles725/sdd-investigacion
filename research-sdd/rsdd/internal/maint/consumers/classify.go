package consumers

import "strings"

// classify is the class of a repository path: the first rule of classRules that holds.
func classify(path string, live map[string]bool) string {
	for _, r := range classRules {
		if r.holds(path, live) {
			return r.class
		}
	}
	return classUnclassified
}

func (r classRule) holds(path string, live map[string]bool) bool {
	if r.kind == byPrefix {
		return pathPrefix.holds(path, r.value)
	}
	if r.kind == byDir {
		return dirSegment.holds(path, r.value)
	}
	if r.kind == byNameContains {
		return nameContains.holds(path, r.value)
	}
	if r.kind == byLiveScript {
		return live[path]
	}
	return strings.HasSuffix(path, r.value) && strings.HasPrefix(path, r.under)
}
