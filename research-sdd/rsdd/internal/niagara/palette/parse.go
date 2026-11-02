package palette

import (
	"bytes"
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"strings"
	"unicode"
	"unicode/utf8"
)

// pyDecode is bytes.decode("utf-8", errors="replace"): each maximal ill-formed subpart becomes one U+FFFD,
// which differs from Go's per-byte RuneError handling for truncated multi-byte sequences.
func pyDecode(b []byte) string {
	if utf8.Valid(b) {
		return string(b)
	}
	var sb strings.Builder
	for i := 0; i < len(b); {
		if b[i] < utf8.RuneSelf {
			sb.WriteByte(b[i])
			i++
			continue
		}
		if r, n := utf8.DecodeRune(b[i:]); r != utf8.RuneError || n > 1 {
			sb.Write(b[i : i+n])
			i += n
			continue
		}
		sb.WriteRune(utf8.RuneError)
		i += invalidSpan(b[i:])
	}
	return sb.String()
}

// invalidSpan is the length of the maximal prefix of b that could start a UTF-8 sequence (at least 1).
func invalidSpan(b []byte) int {
	lo, hi := byte(0x80), byte(0xBF)
	need := 0
	switch c := b[0]; {
	case c >= 0xC2 && c <= 0xDF:
		need = 1
	case c == 0xE0:
		need, lo = 2, 0xA0
	case c >= 0xE1 && c <= 0xEF:
		need = 2
		if c == 0xED {
			hi = 0x9F
		}
	case c == 0xF0:
		need, lo = 3, 0x90
	case c >= 0xF1 && c <= 0xF3:
		need = 3
	case c == 0xF4:
		need, hi = 3, 0x8F
	default:
		return 1
	}
	n := 1
	for ; n <= need && n < len(b); n++ {
		if b[n] < lo || b[n] > hi {
			break
		}
		lo, hi = 0x80, 0xBF
	}
	return n
}

// pyDecodeSig is decode("utf-8-sig", errors="replace"): one leading BOM is dropped.
func pyDecodeSig(b []byte) string {
	return pyDecode(bytes.TrimPrefix(b, []byte{0xEF, 0xBB, 0xBF}))
}

// pySpace is str.isspace: unicode.IsSpace plus the ASCII separators FS, GS, RS, US.
func pySpace(r rune) bool { return unicode.IsSpace(r) || (r >= 0x1c && r <= 0x1f) }

// pySplitLines is str.splitlines() without keepends.
func pySplitLines(s string) []string {
	var out []string
	start := 0
	for i := 0; i < len(s); {
		r, n := utf8.DecodeRuneInString(s[i:])
		switch r {
		case '\n', '\v', '\f', 0x1c, 0x1d, 0x1e, 0x85, 0x2028, 0x2029:
			out = append(out, s[start:i])
			i += n
			start = i
		case '\r':
			out = append(out, s[start:i])
			i += n
			if i < len(s) && s[i] == '\n' {
				i++
			}
			start = i
		default:
			i += n
		}
	}
	if start < len(s) {
		out = append(out, s[start:])
	}
	return out
}

// parseLexicon counts valid key=value lines and the keys that occur more than once. Only key names are kept;
// the value is never read past the first '=' (secrets discipline).
func parseLexicon(text string) (int, map[string]any) {
	counts := map[string]int{}
	examined := 0
	for _, line := range pySplitLines(text) {
		stripped := strings.TrimFunc(line, pySpace)
		if stripped == "" || strings.HasPrefix(stripped, "#") {
			continue
		}
		key, _, found := strings.Cut(stripped, "=")
		if !found {
			continue
		}
		key = strings.TrimFunc(key, pySpace)
		if key == "" {
			continue
		}
		examined++
		counts[key]++
	}
	dups := map[string]any{}
	for k, v := range counts {
		if v > 1 {
			dups[k] = v
		}
	}
	return examined, dups
}

// node is one parsed XML element, holding only what the consumers read.
type node struct {
	name     string
	attrs    map[string]string
	children []*node
}

// parseXML builds the element tree of text with the well-formedness checks an expat-backed parser applies
// and Go's token decoder does not: exactly one root, nothing but whitespace outside it, no duplicate
// attributes. A namespaced name never matches the plain tag names the consumers look for, as in ElementTree.
func parseXML(text string) (*node, error) {
	text = strings.TrimPrefix(text, "\xEF\xBB\xBF")
	d := xml.NewDecoder(strings.NewReader(text))
	d.CharsetReader = func(_ string, in io.Reader) (io.Reader, error) { return in, nil }
	var root *node
	var stack []*node
	for {
		tok, err := d.Token()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return nil, xmlErr(err)
		}
		switch t := tok.(type) {
		case xml.StartElement:
			if len(stack) == 0 && root != nil {
				return nil, errors.New("junk after document element")
			}
			n := &node{name: t.Name.Local, attrs: map[string]string{}}
			if t.Name.Space != "" {
				n.name = "{" + t.Name.Space + "}" + t.Name.Local
			}
			seen := map[xml.Name]bool{}
			for _, a := range t.Attr {
				if seen[a.Name] {
					return nil, errors.New("duplicate attribute")
				}
				seen[a.Name] = true
				if a.Name.Space == "" {
					n.attrs[a.Name.Local] = a.Value
				}
			}
			if len(stack) == 0 {
				root = n
			} else {
				p := stack[len(stack)-1]
				p.children = append(p.children, n)
			}
			stack = append(stack, n)
		case xml.EndElement:
			stack = stack[:len(stack)-1]
		case xml.CharData:
			if len(stack) == 0 && len(bytes.TrimSpace(t)) > 0 {
				return nil, errors.New("syntax error")
			}
		}
	}
	if root == nil {
		return nil, errors.New("no element found")
	}
	return root, nil
}

func xmlErr(err error) error {
	var se *xml.SyntaxError
	if errors.As(err, &se) {
		return fmt.Errorf("%s: line %d", se.Msg, se.Line)
	}
	return err
}

func (n *node) iter(name string, visit func(*node)) {
	if n.name == name {
		visit(n)
	}
	for _, c := range n.children {
		c.iter(name, visit)
	}
}

// parsePalette counts every <p> with at least one of the n/t/m attributes (the root container included).
func parsePalette(text string) (int, error) {
	if text == "" {
		return 0, nil
	}
	root, err := parseXML(text)
	if err != nil {
		return 0, fmt.Errorf("XML parse error: %w", err)
	}
	count := 0
	root.iter("p", func(p *node) {
		for _, a := range []string{"n", "t", "m"} {
			if _, ok := p.attrs[a]; ok {
				count++
				return
			}
		}
	})
	return count, nil
}

// parseAgents lists the <agent> registrations of every <type> in a module.xml text.
func parseAgents(text string) ([]any, error) {
	agents := []any{}
	if text == "" {
		return agents, nil
	}
	root, err := parseXML(text)
	if err != nil {
		return nil, fmt.Errorf("module.xml parse error: %w", err)
	}
	root.iter("type", func(t *node) {
		for _, a := range t.children {
			if a.name != "agent" {
				continue
			}
			on := []any{}
			for _, c := range a.children {
				if c.name == "on" {
					on = append(on, c.attrs["type"])
				}
			}
			agents = append(agents, map[string]any{
				"on_types":   on,
				"type_class": t.attrs["class"],
				"type_name":  t.attrs["name"],
			})
		}
	})
	return agents, nil
}
