package consumers

import "strings"

// predKind is one way a rule looks at a path. The rule tables (scriptdata.go) are data; this is
// the one place that decides whether a path satisfies a rule.
type predKind int

const (
	nameContains predKind = iota // the base name contains the value
	dirSegment                   // a directory of the path (not the file name) is named the value
	pathPrefix                   // the path starts with the value
)

func (k predKind) holds(path, value string) bool {
	if k == nameContains {
		return strings.Contains(baseName(path), value)
	}
	if k == dirSegment {
		dirs := strings.Split(path, "/")
		for _, d := range dirs[:len(dirs)-1] {
			if d == value {
				return true
			}
		}
		return false
	}
	return strings.HasPrefix(path, value)
}

// baseName is the last segment of a slash-separated path.
func baseName(path string) string {
	return path[strings.LastIndexByte(path, '/')+1:]
}
