package bog

import (
	"fmt"
	"reflect"
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/niagara/bogtest"
)

func lines(xml string) []string { return SplitLines(xml) }

// rows renders the components in handle-map order as "handle|path|type|module".
func rows(s *Structure) []string {
	out := []string{}
	for _, c := range s.Components() {
		out = append(out, fmt.Sprintf("%s|%s|%s|%s", c.Handle, c.Path, c.Type, c.Module))
	}
	return out
}

func TestParseComponentTree(t *testing.T) {
	tests := []struct {
		name string
		xml  string
		want []string
	}{
		{"valid station paths, types and module lookup", bogtest.ValidXML, []string{
			"1|Station|b:Station|baja", "2|Station/Services|b:ServiceContainer|baja", "3|Station/Logic|c:BooleanWritable|control"}},
		{"self-closing components with a handle are recorded", bogtest.SelfClosingXML, []string{
			"1|Station|b:Station|baja", "2|Station/A|b:Container|baja", "3|Station/A/Leaf1|b:Folder|baja",
			"4|Station/A/Leaf2|b:Folder|baja", "5|Station/A/Container2|b:Container|baja",
			"6|Station/A/Container2/Leaf3|b:Folder|baja", "7|Station/B|b:Container|baja"}},
		{"a closing </a> pops the action frame, not the enclosing component", bogtest.NestedAXML, []string{
			"1|Station|b:Station|baja", "2|Station/A|b:Container|baja", "3|Station/B|b:Container|baja"}},
		{"empty graph has no components", bogtest.EmptyXML, []string{}},
		{"prefix declared after use gives an empty module", "<p n='A' h='1' t='x:T'/>\n<p n='B' h='2' t='y:T' m='x=late'/>\n<p n='C' h='3' t='x:T'/>",
			[]string{"1|A|x:T|", "2|B|y:T|", "3|C|x:T|late"}},
		{"type without a colon has no prefix", "<p n='A' h='1' t='Plain'/>", []string{"1|A|Plain|"}},
		{"double-quoted attributes", `<p n="A" h="1" t="b:X" m="b=baja"/>`, []string{"1|A|b:X|baja"}},
		{"single quotes win over double quotes in the same tag", `<p n='A' n="B" h='1' t='b:X'/>`, []string{"1|A|b:X|"}},
		{"an attribute name embedded in a longer name is not matched", "<p xn='Z' n='A' h='1' t='b:X'/>", []string{"1|A|b:X|"}},
		{"a non-ASCII letter before the attribute name is a word character", "<p én='Z' n='A' h='1' t='b:X'/>", []string{"1|A|b:X|"}},
		{"empty handle is a handle", "<p n='A' h='' t='b:X'/>", []string{"|A|b:X|"}},
		{"duplicate handle keeps its first position and takes the last value", "<p n='A' h='1' t='b:X'/>\n<p n='B' h='2' t='b:X'/>\n<p n='C' h='1' t='b:Y'/>",
			[]string{"1|C|b:Y|", "2|B|b:X|"}},
		{"element without a handle is skipped but nests the path", "<p n='Slots'>\n<p n='K' h='5' t='b:X'/>\n</p>", []string{"5|Slots/K|b:X|"}},
		{"component under a slot keeps the slot in its path", "<p n='S' h='1' t='b:S'>\n<p n='Slot'>\n<p n='In' h='2' t='b:X'/>\n</p>\n</p>", []string{"1|S|b:S|", "2|S/Slot/In|b:X|"}},
		{"unicode tag names are one tag, not a p tag", "<pé n='A' h='1' t='b:X'/>", []string{}},
		{"unbalanced closing tags do not panic", "</p></p></a>\n<p n='A' h='1' t='b:X'/>", []string{"1|A|b:X|"}},
		{"two tags on one line", "<p n='A' h='1' t='b:X'><p n='B' h='2' t='b:X'/></p>", []string{"1|A|b:X|", "2|A/B|b:X|"}},
		{"blank and whitespace-only lines are skipped", "\n   \n<p n='A' h='1' t='b:X'/>\n　\n", []string{"1|A|b:X|"}},
		{"an action element with a body is balanced", "<p n='S' h='1' t='b:S'>\n<a n='go'>\n</a>\n<p n='K' h='2' t='b:X'/>\n</p>", []string{"1|S|b:S|", "2|S/K|b:X|"}},
		{"a self-closing action does not push a frame", "<p n='S' h='1' t='b:S'>\n<a n='go'/>\n<p n='K' h='2' t='b:X'/>\n</p>", []string{"1|S|b:S|", "2|S/K|b:X|"}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := rows(Parse(lines(tt.xml)))
			if !reflect.DeepEqual(got, tt.want) {
				t.Errorf("components = %q, want %q", got, tt.want)
			}
		})
	}
}

func TestParsePrefixes(t *testing.T) {
	s := Parse(lines(bogtest.ValidXML))
	want := map[string]string{"b": "baja", "c": "control"}
	if !reflect.DeepEqual(s.Prefixes, want) {
		t.Errorf("prefixes = %v, want %v", s.Prefixes, want)
	}
	s = Parse(lines("<p n='A' h='1' t='b:X' m='b=baja novalue c=a=b'/>"))
	want = map[string]string{"b": "baja", "c": "a=b"}
	if !reflect.DeepEqual(s.Prefixes, want) {
		t.Errorf("prefixes with odd tokens = %v, want %v", s.Prefixes, want)
	}
}

func TestParseLinks(t *testing.T) {
	s := Parse(lines(bogtest.ValidXML))
	if len(s.Links) != 1 {
		t.Fatalf("links = %d, want 1", len(s.Links))
	}
	lk := s.Links[0]
	if lk.Name != "Link" || lk.ContainerPath != "Station/Logic" || deref(lk.ContainerHandle) != "3" {
		t.Errorf("link container/name = %+v", lk)
	}
	if deref(lk.SrcHandle) != "2" || deref(lk.SrcSlot) != "out" || deref(lk.TgtSlot) != "in10" {
		t.Errorf("link ends = %q %q %q", deref(lk.SrcHandle), deref(lk.SrcSlot), deref(lk.TgtSlot))
	}
	if c, ok := s.Lookup("2"); !ok || c.Path != "Station/Services" {
		t.Errorf("Lookup(2) = %v, %v", c, ok)
	}
	if _, ok := s.Lookup("nope"); ok {
		t.Error("Lookup of an unknown handle must report absent")
	}
}

func deref(p *string) string {
	if p == nil {
		return "<nil>"
	}
	return *p
}

func TestParseLinkEdgeCases(t *testing.T) {
	const head = "<p n='C' h='1' t='b:X'>\n"
	tests := []struct {
		name         string
		body         string
		src, sl, tsl string
	}{
		{"empty source handle is kept (a falsy but present value)", "<p n='L' t='b:Link'>\n<p n='sourceOrd' v='h:'/>\n</p>", "", "<nil>", "<nil>"},
		{"a non-h: source ord is ignored", "<p n='L' t='b:Link'>\n<p n='sourceOrd' v='slot:Foo'/>\n</p>", "<nil>", "<nil>", "<nil>"},
		{"an h: that is not at the start of the source ord is ignored", "<p n='L' t='b:Link'>\n<p n='sourceOrd' v='xh:5'/>\n</p>", "<nil>", "<nil>", "<nil>"},
		{"empty slot values are ignored", "<p n='L' t='b:Link'>\n<p n='sourceSlotName' v=''/>\n<p n='targetSlotName' v='t'/>\n</p>", "<nil>", "<nil>", "t"},
		{"the last duplicate wins", "<p n='L' t='b:Link'>\n<p n='sourceSlotName' v='a'/>\n<p n='sourceSlotName' v='b'/>\n</p>", "<nil>", "b", "<nil>"},
		{"unrelated fields inside a link are ignored", "<p n='L' t='b:Link'>\n<p n='enabled' v='true'/>\n</p>", "<nil>", "<nil>", "<nil>"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			s := Parse(lines(head + tt.body + "\n</p>"))
			if len(s.Links) != 1 {
				t.Fatalf("links = %d, want 1", len(s.Links))
			}
			lk := s.Links[0]
			if deref(lk.SrcHandle) != tt.src || deref(lk.SrcSlot) != tt.sl || deref(lk.TgtSlot) != tt.tsl {
				t.Errorf("link = src %q slot %q tgt %q, want %q %q %q", deref(lk.SrcHandle), deref(lk.SrcSlot), deref(lk.TgtSlot), tt.src, tt.sl, tt.tsl)
			}
		})
	}
}

func TestParseLinkWithoutContainerAndSelfClosingLink(t *testing.T) {
	s := Parse(lines("<p n='L' t='b:Link'>\n<p n='sourceSlotName' v='a'/>\n</p>"))
	if len(s.Links) != 1 || s.Links[0].ContainerHandle != nil || s.Links[0].ContainerPath != "" {
		t.Fatalf("link outside any component = %+v", s.Links)
	}
	s = Parse(lines("<p n='C' h='1' t='b:X'>\n<p n='L' t='b:Link'/>\n</p>"))
	if len(s.Links) != 0 {
		t.Errorf("a self-closing b:Link has no body and must not open a link, got %d", len(s.Links))
	}
}

func TestParseNeverCapturesSlotValues(t *testing.T) {
	s := Parse(lines(bogtest.ValidXML))
	dump := fmt.Sprintf("%+v %+v", s.Components()[0], s.Links)
	for _, c := range s.Components() {
		dump += fmt.Sprintf("%+v", *c)
	}
	if strings.Contains(dump, "PLAINSECRET") {
		t.Error("a slot value leaked into the parsed structure")
	}
}

func TestParsePrefixesSplitOnAnyWhitespace(t *testing.T) {
	s := Parse(lines("<p n='A' h='1' t='b:X' m='a=1\tb=2   c=3\u3000d=4\u00a0e=5'/>"))
	want := map[string]string{"a": "1", "b": "2", "c": "3", "d": "4", "e": "5"}
	if !reflect.DeepEqual(s.Prefixes, want) {
		t.Errorf("prefixes = %v, want %v", s.Prefixes, want)
	}
}

func TestAttrExported(t *testing.T) {
	tests := []struct {
		text, name, want string
		ok               bool
	}{
		{"<p n='A' h=\"1\">", "n", "A", true},
		{"<p n='A' h=\"1\">", "h", "1", true},
		{"<p xn='Z'>", "n", "", false},
		{"<p n='unterminated", "n", "", false},
		{"<p n=\"it's\">", "n", "it's", true},
		{"<p n=''>", "n", "", true},
	}
	for _, tt := range tests {
		got, ok := Attr(tt.text, tt.name)
		if got != tt.want || ok != tt.ok {
			t.Errorf("Attr(%q, %q) = %q, %v; want %q, %v", tt.text, tt.name, got, ok, tt.want, tt.ok)
		}
	}
}
