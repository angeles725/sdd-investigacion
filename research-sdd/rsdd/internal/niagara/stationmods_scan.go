package niagara

import (
	"fmt"
	"os"
	"sort"
	"strings"
	"unicode/utf8"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/niagara/bog"
)

// This file holds what station_modules.py learns from its two inputs: the module aliases and type references a
// station names, and the module parts an install provides. The legacy tool finds both with regular expressions
// over Unicode text; the scanners below reproduce those expressions' matches exactly, including where Python's \b
// and \s differ from RE2's (a non-ASCII letter is a word character, the C0 separators are whitespace).

func isQuote(b byte) bool { return b == '"' || b == '\'' }

// wordBefore reports whether the character ending s[:i] is a word character, so that \b does not hold at i
// before a word character.
func wordBefore(s string, i int) bool {
	if i <= 0 {
		return false
	}
	r, _ := utf8.DecodeLastRuneInString(s[:i])
	return bog.IsWord(r)
}

// wordAt reports whether the character starting at s[i] is a word character.
func wordAt(s string, i int) bool {
	if i >= len(s) {
		return false
	}
	r, _ := utf8.DecodeRuneInString(s[i:])
	return bog.IsWord(r)
}

// parseStationRefs is _parse_station_refs over the lines of a decoded bog: it returns, for every module the
// station names, the sorted unique type names it references, and the number of t="alias:Type" references whose
// alias no m="alias=module" declaration defined.
//
// A later declaration of an alias replaces an earlier one, an alias that maps to an empty module name is
// falsy (its references count as unresolved), and a module appears in the result once any alias still points
// at it, even with no type.
func parseStationRefs(lines []string) (moduleTypes map[string][]string, unresolved int) {
	text := strings.Join(lines, "\n")
	aliases := map[string]string{}

	// m="a=mod b=baja" or m='a=mod b=baja': \bm=["']([^"']+)["']
	for i := 0; i+1 < len(text); {
		if text[i] != 'm' || text[i+1] != '=' || wordBefore(text, i) || i+2 >= len(text) || !isQuote(text[i+2]) {
			i++
			continue
		}
		k := i + 3
		for k < len(text) && !isQuote(text[k]) {
			k++
		}
		if k == i+3 || k >= len(text) {
			i++
			continue
		}
		for _, part := range bog.Fields(text[i+3 : k]) {
			if alias, mod, ok := strings.Cut(part, "="); ok {
				aliases[alias] = mod
			}
		}
		i = k + 1
	}

	types := map[string]map[string]bool{}
	// t="alias:TypeName": \bt=["']([^\s"'=:]+):([A-Za-z0-9_]+)["']
	for i := 0; i+1 < len(text); {
		alias, typeName, end, ok := typeRef(text, i)
		if !ok {
			i++
			continue
		}
		if mod := aliases[alias]; mod != "" {
			if types[mod] == nil {
				types[mod] = map[string]bool{}
			}
			types[mod][typeName] = true
		} else {
			unresolved++
		}
		i = end
	}

	// every module an alias still names appears, with or without types
	for _, mod := range aliases {
		if types[mod] == nil {
			types[mod] = map[string]bool{}
		}
	}
	moduleTypes = make(map[string][]string, len(types))
	for mod, set := range types {
		names := make([]string, 0, len(set))
		for n := range set {
			names = append(names, n)
		}
		sort.Strings(names)
		moduleTypes[mod] = names
	}
	return moduleTypes, unresolved
}

// typeRef matches one t="alias:Type" reference starting at text[i], returning where it ends.
func typeRef(text string, i int) (alias, typeName string, end int, ok bool) {
	if text[i] != 't' || text[i+1] != '=' || wordBefore(text, i) || i+2 >= len(text) || !isQuote(text[i+2]) {
		return "", "", 0, false
	}
	start := i + 3
	k := start
	for k < len(text) {
		r, size := utf8.DecodeRuneInString(text[k:])
		if bog.IsSpace(r) || r == '"' || r == '\'' || r == '=' || r == ':' {
			break
		}
		k += size
	}
	if k == start || k >= len(text) || text[k] != ':' {
		return "", "", 0, false
	}
	alias = text[start:k]
	k++
	nameStart := k
	for k < len(text) && (text[k] == '_' || text[k] >= '0' && text[k] <= '9' || text[k] >= 'a' && text[k] <= 'z' || text[k] >= 'A' && text[k] <= 'Z') {
		k++
	}
	if k == nameStart || k >= len(text) || !isQuote(text[k]) {
		return "", "", 0, false
	}
	return alias, text[nameStart:k], k + 1, true
}

// attrValue is _ga_xml: the value of the first name="..." (either quote) that starts at a word boundary, or "".
func attrValue(attrs, name string) string {
	needle := name + "="
	for from := 0; from <= len(attrs); {
		i := strings.Index(attrs[from:], needle)
		if i < 0 {
			return ""
		}
		i += from
		if j := i + len(needle); !wordBefore(attrs, i) && j < len(attrs) && isQuote(attrs[j]) {
			k := j + 1
			for k < len(attrs) && !isQuote(attrs[k]) {
				k++
			}
			if k < len(attrs) {
				return attrs[j+1 : k]
			}
		}
		from = i + 1
	}
	return ""
}

// parseModuleXML reads the module part out of META-INF/module.xml: the part name and module name of the first
// <module element, and every <type name="..."/>. ok is false when there is no <module element. Versions, vendor
// strings and dependencies are never read (the evidence never carries them).
func parseModuleXML(xml string) (part, moduleName string, types map[string]bool, ok bool) {
	root := -1
	for from := 0; from < len(xml); {
		i := strings.Index(xml[from:], "<module")
		if i < 0 {
			break
		}
		i += from
		if !wordAt(xml, i+len("<module")) {
			root = i + len("<module")
			break
		}
		from = i + 1
	}
	if root < 0 {
		return "", "", nil, false
	}
	attrs := xml[root:]
	if end := strings.IndexByte(attrs, '>'); end >= 0 {
		attrs = attrs[:end]
	}
	return attrValue(attrs, "name"), attrValue(attrs, "moduleName"), typeNames(xml), true
}

// typeNames is set(re.findall(r'<type\b[^>]*\bname=["\']([^"\']*)["\']', xml)). The greedy [^>]* settles on the
// last name= inside the tag that has a quoted value, and that value may run past the tag's closing '>'.
func typeNames(xml string) map[string]bool {
	out := map[string]bool{}
	for from := 0; from < len(xml); {
		i := strings.Index(xml[from:], "<type")
		if i < 0 {
			break
		}
		i += from
		start := i + len("<type")
		if wordAt(xml, start) {
			from = i + 1
			continue
		}
		end := len(xml)
		if e := strings.IndexByte(xml[start:], '>'); e >= 0 {
			end = start + e
		}
		matchEnd := -1
		for p := end; p >= start; p-- {
			if !strings.HasPrefix(xml[p:], "name=") || wordBefore(xml, p) {
				continue
			}
			q := p + len("name=")
			if q >= len(xml) || !isQuote(xml[q]) {
				continue
			}
			k := q + 1
			for k < len(xml) && !isQuote(xml[k]) {
				k++
			}
			if k < len(xml) {
				out[xml[q+1:k]] = true
				matchEnd = k + 1
				break
			}
		}
		if matchEnd < 0 {
			from = i + 1
			continue
		}
		from = matchEnd
	}
	return out
}

// installPart is what the install index keeps of one module JAR.
type installPart struct {
	moduleName string
	types      map[string]bool
}

// installIndex is the outcome of _index_install.
type installIndex struct {
	parts     map[string]installPart
	scanned   int
	total     int
	truncated bool
	oversized int
	// err is set when modules/ could not be indexed at all; every other field is then zero, and the caller must
	// not read an empty index as an empty install.
	err string
}

// pySortKey orders names the way sorted() orders os.listdir() strings: by code point, with each byte that is not
// valid UTF-8 standing for the lone surrogate U+DC00+byte that surrogateescape gives it.
func pySortKey(s string) []rune {
	var key []rune
	for i := 0; i < len(s); {
		r, size := utf8.DecodeRuneInString(s[i:])
		if r == utf8.RuneError && size == 1 {
			key = append(key, 0xDC00+rune(s[i]))
		} else {
			key = append(key, r)
		}
		i += size
	}
	return key
}

func lessRunes(a, b []rune) bool {
	for i := 0; i < len(a) && i < len(b); i++ {
		if a[i] != b[i] {
			return a[i] < b[i]
		}
	}
	return len(a) < len(b)
}

// indexInstall is _index_install: it walks root/modules and indexes the module parts its JARs declare. It reads
// at most maxJars JARs; the cap is reported in the result, never silently applied.
func indexInstall(cwd, root string) installIndex {
	modulesDir := pjoin(root, "modules")
	fail := func(format string, args ...any) installIndex {
		return installIndex{err: fmt.Sprintf(format, args...)}
	}
	if !insideRoot(cwd, root, modulesDir) {
		return fail("modules/ dir resolves outside install root (symlink escape): %s", bog.PyReprPath(modulesDir))
	}
	fi, err := os.Lstat(modulesDir)
	if err != nil {
		if os.IsNotExist(err) {
			return fail("modules/ directory not found in install root: %s", bog.PyReprPath(modulesDir))
		}
		return fail("modules/ directory inaccessible: %s: %s", bog.StrError(err), bog.PyReprPath(modulesDir))
	}
	if fi.Mode()&os.ModeSymlink != 0 {
		return fail("modules/ is a symbolic link (rejected): %s", bog.PyReprPath(modulesDir))
	}
	if !fi.IsDir() {
		return fail("modules/ is not a directory: %s", bog.PyReprPath(modulesDir))
	}
	dir, err := os.Open(modulesDir)
	var names []string
	if err == nil {
		names, err = dir.Readdirnames(-1)
		dir.Close()
	}
	if err != nil {
		return fail("modules/ directory unreadable: %s: %s", bog.StrError(err), bog.PyReprPath(modulesDir))
	}
	sort.Slice(names, func(i, j int) bool { return lessRunes(pySortKey(names[i]), pySortKey(names[j])) })

	idx := installIndex{parts: map[string]installPart{}}
	var jars []string
	for _, n := range names {
		if strings.HasSuffix(n, ".jar") {
			jars = append(jars, n)
		}
	}
	idx.total = len(jars)
	for _, name := range jars {
		if idx.scanned >= maxJars {
			idx.truncated = true
			break
		}
		path := pjoin(modulesDir, name)
		if !insideRoot(cwd, root, path) {
			continue
		}
		li, err := os.Lstat(path)
		if err != nil || li.Mode()&os.ModeSymlink != 0 || !li.Mode().IsRegular() {
			continue
		}
		part, module, types, status := readModuleXML(path)
		idx.scanned++
		switch status {
		case moduleOversized:
			idx.oversized++
		case moduleOK:
			if part != "" {
				idx.parts[part] = installPart{moduleName: module, types: types}
			}
		}
	}
	return idx
}

type moduleStatus int

const (
	moduleNone moduleStatus = iota // absent, unreadable or not a module descriptor
	moduleOversized
	moduleOK
)

// readModuleXML is _read_module_xml: META-INF/module.xml of a JAR, read under the 64 KiB cap. An entry over the
// cap is reported as such, so the caller can count the skip.
func readModuleXML(path string) (part, module string, types map[string]bool, status moduleStatus) {
	h, err := bog.Open(path)
	if err != nil {
		return "", "", nil, moduleNone
	}
	defer h.Close()
	z, err := h.Zip()
	if err != nil {
		return "", "", nil, moduleNone
	}
	body, truncated, err := z.ReadMember("META-INF/module.xml", maxModuleXML)
	if err != nil {
		return "", "", nil, moduleNone
	}
	if truncated {
		return "", "", nil, moduleOversized
	}
	part, module, types, ok := parseModuleXML(bog.DecodeReplace(body))
	if !ok {
		return "", "", nil, moduleNone
	}
	return part, module, types, moduleOK
}
