package bog

import (
	"regexp"
	"strings"
	"unicode/utf8"
)

// Comp is one component of the station tree: structure only. Slot values are never stored (secrets discipline:
// a config.bog may hold credentials, so the reader has no field that could carry one).
type Comp struct {
	Name         string
	Handle       string
	Type         string
	Prefix       string
	Module       string
	Path         string
	ParentHandle *string
}

// Link is one b:Link body. The pointer fields distinguish an absent value from an empty one, which the legacy
// output renders differently ("None" for absent).
type Link struct {
	ContainerHandle *string
	ContainerPath   string
	Name            string
	SrcHandle       *string
	SrcSlot         *string
	TgtSlot         *string
}

// Structure is the result of a structure-only parse of Baja XML.
type Structure struct {
	// Prefixes maps a module prefix to its module name, from the m='b=baja c=control' declarations.
	Prefixes map[string]string
	// Links are the b:Link bodies in document order.
	Links []Link

	order  []string
	byHand map[string]*Comp
}

// Components returns the components in the order their handles first appeared. A later element that reuses a
// handle replaces the stored component but keeps the original position (dict assignment semantics).
func (s *Structure) Components() []*Comp {
	out := make([]*Comp, 0, len(s.order))
	for _, h := range s.order {
		out = append(out, s.byHand[h])
	}
	return out
}

// Lookup returns the component recorded for handle.
func (s *Structure) Lookup(handle string) (*Comp, bool) {
	c, ok := s.byHand[handle]
	return c, ok
}

func (s *Structure) record(c *Comp) {
	if _, dup := s.byHand[c.Handle]; !dup {
		s.order = append(s.order, c.Handle)
	}
	s.byHand[c.Handle] = c
}

// tagRE finds one element tag on a line. Python's \w is Unicode-aware, Go's is ASCII-only, so the name class is
// spelled out; the trailing \b of the original pattern is implied by the greedy name class.
var tagRE = regexp.MustCompile(`<(/?)([A-Za-z][\p{L}\p{N}_]*)([^>]*?)(/?)>`)

type frameKind uint8

const (
	frameComp frameKind = iota + 1
	frameLink
	frameAction
	frameOther
)

type frame struct {
	kind frameKind
	path string
	comp *Comp
}

// Parse performs the structure-only parse of Baja XML lines: component paths, types, handles, module prefixes
// and link bodies. It is a line-oriented regex scan, not an XML parser, exactly like the legacy reader, so a tag
// split across lines is not seen. Slot values other than a link's endpoints are never read.
func Parse(lines []string) *Structure {
	st := &Structure{Prefixes: map[string]string{}, byHand: map[string]*Comp{}}
	var stack []frame
	inLink := false
	var link Link

	nearestComp := func() *Comp {
		for i := len(stack) - 1; i >= 0; i-- {
			if stack[i].kind == frameComp {
				return stack[i].comp
			}
		}
		return nil
	}
	top := func() (frame, bool) {
		if len(stack) == 0 {
			return frame{}, false
		}
		return stack[len(stack)-1], true
	}

	for _, raw := range lines {
		line := TrimRightSpace(raw)
		if TrimSpace(line) == "" {
			continue
		}
		for _, m := range tagRE.FindAllStringSubmatch(line, -1) {
			full, closing, tag := m[0], m[1] != "", m[2]
			selfClosing := m[4] != "" || strings.HasSuffix(full, "/>")

			if closing {
				if (tag == "p" || tag == "a") && len(stack) > 0 {
					popped := stack[len(stack)-1]
					stack = stack[:len(stack)-1]
					if popped.kind == frameLink {
						st.Links = append(st.Links, link)
						inLink = false
						link = Link{}
					}
				}
				continue
			}
			if tag == "a" {
				// A non-self-closing <a>...</a> must push a placeholder so </a> pops it and not the enclosing
				// component, which would corrupt the path of every later sibling.
				if !selfClosing {
					p, _ := top()
					stack = append(stack, frame{kind: frameAction, path: p.path})
				}
				continue
			}
			if tag != "p" {
				continue
			}

			n, _ := attr(full, "n")
			h, hasH := attr(full, "h")
			t, _ := attr(full, "t")
			v, hasV := attr(full, "v")
			mAttr, _ := attr(full, "m")

			for _, part := range Fields(mAttr) {
				if k, val, ok := strings.Cut(part, "="); ok {
					st.Prefixes[k] = val
				}
			}

			if inLink {
				if selfClosing {
					switch {
					case n == "sourceOrd" && hasV && strings.HasPrefix(v, "h:"):
						s := v[2:]
						link.SrcHandle = &s
					case n == "sourceSlotName" && hasV && v != "":
						link.SrcSlot = ptr(v)
					case n == "targetSlotName" && hasV && v != "":
						link.TgtSlot = ptr(v)
					}
				}
				continue
			}

			if t == "b:Link" && !selfClosing {
				var cont *string
				var contPath string
				if c := nearestComp(); c != nil {
					cont, contPath = ptr(c.Handle), c.Path
				}
				inLink = true
				link = Link{ContainerHandle: cont, ContainerPath: contPath, Name: n}
				p, _ := top()
				stack = append(stack, frame{kind: frameLink, path: p.path})
				continue
			}

			if hasH {
				// Self-closing components carry a handle too and have no open/close pair, so they are
				// recorded without a stack frame; skipping them silently under-counts components.
				pfx := ""
				if before, _, ok := strings.Cut(t, ":"); ok {
					pfx = before
				}
				p, _ := top()
				var parentH *string
				if pc := nearestComp(); pc != nil {
					parentH = ptr(pc.Handle)
				}
				comp := &Comp{
					Name: n, Handle: h, Type: t, Prefix: pfx, Module: st.Prefixes[pfx],
					Path: strings.TrimLeft(p.path+"/"+n, "/"), ParentHandle: parentH,
				}
				st.record(comp)
				if !selfClosing {
					stack = append(stack, frame{kind: frameComp, path: comp.Path, comp: comp})
				}
				continue
			}

			// Every other element (slots, facets, fallbacks) is skipped, but an open one still nests the path.
			if !selfClosing {
				p, _ := top()
				path := p.path
				if n != "" {
					path = strings.TrimLeft(p.path+"/"+n, "/")
				}
				stack = append(stack, frame{kind: frameOther, path: path})
			}
		}
	}
	return st
}

func ptr(s string) *string { return &s }

// attr reads one attribute from tag text the way the legacy reader does: the first single-quoted occurrence
// wins over any double-quoted one, and the name must start at a word boundary (Unicode word characters).
func attr(text, name string) (string, bool) {
	if v, ok := attrQuoted(text, name, '\''); ok {
		return v, true
	}
	return attrQuoted(text, name, '"')
}

func attrQuoted(text, name string, q byte) (string, bool) {
	needle := name + "=" + string(q)
	for from := 0; from <= len(text); {
		i := strings.Index(text[from:], needle)
		if i < 0 {
			return "", false
		}
		i += from
		if i == 0 || !wordRuneBefore(text, i) {
			rest := text[i+len(needle):]
			if j := strings.IndexByte(rest, q); j >= 0 {
				return rest[:j], true
			}
			return "", false // no closing quote here means none for any later occurrence either
		}
		from = i + 1
	}
	return "", false
}

func wordRuneBefore(s string, i int) bool {
	r, _ := utf8.DecodeLastRuneInString(s[:i])
	return IsWord(r)
}
