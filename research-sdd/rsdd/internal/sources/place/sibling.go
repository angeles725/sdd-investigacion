package place

import "strings"

// sibling is the File cell of the archived copy: vname in the same directory as rel.
func sibling(rel, vname string) string {
	if i := strings.LastIndex(rel, "/"); i >= 0 {
		return rel[:i] + "/" + vname
	}
	return vname
}
