package goimpact

import (
	"fmt"
	"path"
	"strings"
)

// Blind returns the file's Go blind-spot class, or "" when it is none. A file is a blind spot when it has an
// unresolved class unplaceable, C or D mention (the first found in that order names the class), or when it is
// empty-reach. A declared exemption is never a blind spot.
func (f BashFile) Blind() string {
	if f.Exempt != "" {
		return ""
	}
	for _, class := range []string{ClassUnplaceable, ClassC, ClassD} {
		for _, m := range f.Mentions {
			if m.Class == class && !m.Resolved {
				return class
			}
		}
	}
	if f.Empty {
		return ClassEmptyReach
	}
	return ""
}

// markEmptyReach flags the files that mention the binary in code yet reach no command: no parsed call and no
// named shim. A shim is the basename of a bash file that has a parsed edge; a file that only exports RSDD_BIN
// for the shims it runs keeps that mapping and stays out.
func markEmptyReach(files []BashFile) {
	var shims []string
	for _, f := range files {
		if len(f.Calls) != 0 {
			shims = append(shims, path.Base(f.Path))
		}
	}
	for i := range files {
		f := &files[i]
		if len(f.Mentions) == 0 || len(f.Calls) != 0 || f.Blind() != "" {
			continue
		}
		f.Empty = !namesAny(f.Text, shims, path.Base(f.Path))
	}
}

// nameChars are the bytes that continue a file name: a shim name only counts when it stands alone.
const nameChars = "_-.0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"

// namesAny reports whether text holds, as a whole name (not inside a longer one), any of names other than self.
func namesAny(text string, names []string, self string) bool {
	words := map[string]bool{}
	for _, w := range strings.FieldsFunc(text, func(r rune) bool { return !strings.ContainsRune(nameChars, r) }) {
		words[w] = true
	}
	for _, n := range names {
		if n != self && words[n] {
			return true
		}
	}
	return false
}

// Counts are the per-class totals over every scanned bash file: mentions for A to unplaceable, files for the
// last two. A zero here is a measured zero, not a scan that saw nothing.
type Counts struct{ A, B, C, D, Unplaceable, Empty, Files int }

// CountClasses totals the mentions by class, the empty-reach files and the blind-spot files.
func CountClasses(files []BashFile) Counts {
	var c Counts
	for _, f := range files {
		for _, m := range f.Mentions {
			switch m.Class {
			case ClassA:
				c.A++
			case ClassB:
				c.B++
			case ClassC:
				c.C++
			case ClassD:
				c.D++
			case ClassUnplaceable:
				c.Unplaceable++
			}
		}
		if f.Empty {
			c.Empty++
		}
		if f.Blind() != "" {
			c.Files++
		}
	}
	return c
}

// Line is the aggregate CLASSES output line.
func (c Counts) Line() string {
	return fmt.Sprintf("CLASSES\tA=%d\tB=%d\tC=%d\tD=%d\tunplaceable=%d\tempty-reach=%d\tblindspot-files=%d",
		c.A, c.B, c.C, c.D, c.Unplaceable, c.Empty, c.Files)
}
