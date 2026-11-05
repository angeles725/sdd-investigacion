package sizecheck

import (
	"fmt"
	"io"
	"strings"
)

// jesc is the JSON string body: backslash, quote, \t \n \r escaped; any other control byte becomes `?`.
func jesc(s string) string {
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		switch c := s[i]; {
		case c == '\\':
			b.WriteString(`\\`)
		case c == '"':
			b.WriteString(`\"`)
		case c == '\t':
			b.WriteString(`\t`)
		case c == '\n':
			b.WriteString(`\n`)
		case c == '\r':
			b.WriteString(`\r`)
		case c < 0x20 || c == 0x7f:
			b.WriteByte('?')
		default:
			b.WriteByte(c)
		}
	}
	return b.String()
}

// list writes `[a,b,c]` with each item rendered by f.
func list(w io.Writer, n int, f func(i int) string) {
	fmt.Fprint(w, "[")
	for i := 0; i < n; i++ {
		if i > 0 {
			fmt.Fprint(w, ",")
		}
		fmt.Fprint(w, f(i))
	}
	fmt.Fprint(w, "]")
}

func quoted(s string) string { return `"` + jesc(s) + `"` }

// writeJSON is the machine report: one line, the fields in a fixed order.
func writeJSON(w io.Writer, r result) {
	t, o := r.t, r.o
	fmt.Fprintf(w, `{"state":"%s","base":%s,"head":%s,"budget":%d,"hard_limit":%d,"strict":%t,`, r.state, quoted(o.base), quoted(o.head), o.budget, o.hard, o.strict)
	fmt.Fprintf(w, `"authored":%d,"added":%d,"deleted":%d,"excluded_lines":%d,"excluded_files":%d,`, t.authored, t.adds, t.dels, t.exLines, t.exFiles)
	fmt.Fprint(w, `"files":`)
	list(w, len(t.files), func(i int) string {
		f := t.files[i]
		return fmt.Sprintf(`{"path":%s,"added":%d,"deleted":%d,"lines":%d}`, quoted(f.path), f.add, f.del, f.lines)
	})
	fmt.Fprint(w, `,"excluded":`)
	list(w, len(t.excluded), func(i int) string {
		return fmt.Sprintf(`{"path":%s,"lines":%d}`, quoted(t.excluded[i].path), t.excluded[i].lines)
	})
	fmt.Fprint(w, `,"unmeasured":`)
	list(w, len(t.unmeasured), func(i int) string { return quoted(t.unmeasured[i]) })
	fmt.Fprint(w, `,"renames":`)
	list(w, len(t.renames), func(i int) string { return quoted(t.renames[i]) })
	fmt.Fprint(w, `,"hotspots":`)
	list(w, len(r.hot), func(i int) string {
		h := r.hot[i]
		return fmt.Sprintf(`{"path":%s,"lines":%d,"percent_of_total":%d,"pattern_share_percent":%d,"pattern":%s}`, quoted(h.path), h.lines, h.pct, h.share, quoted(h.pattern))
	})
	fmt.Fprint(w, `,"hotspots_unchecked":`)
	list(w, len(r.unchecked), func(i int) string { return quoted(r.unchecked[i]) })
	fmt.Fprint(w, `,"split":`)
	list(w, len(r.chunks), func(i int) string {
		c := r.chunks[i]
		var b strings.Builder
		fmt.Fprintf(&b, `{"chunk":%d,"lines":%d,"note":%s,"files":`, c.idx, c.lines, quoted(c.note))
		list(&b, len(c.files), func(j int) string { return quoted(c.files[j].path) })
		b.WriteString("}")
		return b.String()
	})
	fmt.Fprintln(w, "}")
}
