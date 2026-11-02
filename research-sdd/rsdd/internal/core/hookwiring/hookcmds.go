package hookwiring

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"strconv"
	"strings"
)

// jnode is just enough of a JSON value to walk settings.json the way the jq filter of hook_wired_exec_report did.
// Objects keep their keys in document order; a duplicate key keeps its first position and its last value, as jq does.
type jnode struct {
	kind byte // 'o' object, 'a' array, 's' string, 'x' anything else
	keys []string
	vals map[string]*jnode
	arr  []*jnode
	str  string
}

// parseJNode reads one value; running out of input inside it is an error, never a clean end.
func parseJNode(dec *json.Decoder) (*jnode, error) {
	tok, err := dec.Token()
	if err != nil {
		if errors.Is(err, io.EOF) {
			err = io.ErrUnexpectedEOF
		}
		return nil, err
	}
	return buildJNode(dec, tok)
}

func buildJNode(dec *json.Decoder, tok json.Token) (*jnode, error) {
	switch t := tok.(type) {
	case json.Delim:
		if t == '{' {
			n := &jnode{kind: 'o', vals: map[string]*jnode{}}
			for dec.More() {
				kt, err := dec.Token()
				if err != nil {
					return nil, err
				}
				key, _ := kt.(string)
				v, err := parseJNode(dec)
				if err != nil {
					return nil, err
				}
				if _, seen := n.vals[key]; !seen {
					n.keys = append(n.keys, key)
				}
				n.vals[key] = v
			}
			if _, err := dec.Token(); err != nil { // the closing brace
				return nil, err
			}
			return n, nil
		}
		n := &jnode{kind: 'a'}
		for dec.More() {
			v, err := parseJNode(dec)
			if err != nil {
				return nil, err
			}
			n.arr = append(n.arr, v)
		}
		if _, err := dec.Token(); err != nil { // the closing bracket
			return nil, err
		}
		return n, nil
	case string:
		return &jnode{kind: 's', str: t}, nil
	}
	return &jnode{kind: 'x'}, nil
}

// hookEntry is one command wired under the top-level "hooks" key.
type hookEntry struct{ event, command string }

var errBadJSON = errors.New("invalid JSON")

// wiredCommands lists, in document order, every command string of settings.json found at
// .hooks.<event>[].hooks[].command (any event). statusLine and mcpServers commands are not hooks and are not read.
// It is the Go side of
//
//	(.hooks? // {}) | objects | to_entries[] | .key as $e | .value | arrays | .[] | objects | .hooks | arrays | .[]
//	| objects | .command | strings
//
// A document that is not valid JSON is an error; an empty one holds no entries. A UTF-8 byte order mark is skipped
// and several top-level documents are all read, like jq.
func wiredCommands(data []byte) ([]hookEntry, error) {
	data = bytes.TrimPrefix(data, []byte("\xef\xbb\xbf"))
	if loneHighSurrogate(data) {
		return nil, errBadJSON
	}
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.UseNumber()
	var out []hookEntry
	for {
		tok, err := dec.Token()
		if errors.Is(err, io.EOF) { // the clean end: between two top-level values
			return out, nil
		}
		if err != nil {
			return nil, errBadJSON
		}
		doc, err := buildJNode(dec, tok)
		if err != nil {
			return nil, errBadJSON
		}
		if doc.kind != 'o' {
			continue
		}
		hooks := doc.vals["hooks"]
		if hooks == nil || hooks.kind != 'o' {
			continue
		}
		for _, event := range hooks.keys {
			groups := hooks.vals[event]
			if groups.kind != 'a' {
				continue
			}
			for _, g := range groups.arr {
				if g.kind != 'o' {
					continue
				}
				inner := g.vals["hooks"]
				if inner == nil || inner.kind != 'a' {
					continue
				}
				for _, h := range inner.arr {
					if h.kind != 'o' {
						continue
					}
					if c := h.vals["command"]; c != nil && c.kind == 's' {
						out = append(out, hookEntry{event, c.str})
					}
				}
			}
		}
	}
}

// entryLines renders the entries as the bash report saw them: one `event<TAB>command` line each, a newline of the
// command read as a blank (so one command is one line), NUL bytes dropped by the command substitution, and the
// blank lines skipped by the reading loop. An event name holding a newline therefore splits into two lines.
func entryLines(entries []hookEntry) []string {
	var b strings.Builder
	for _, en := range entries {
		b.WriteString(en.event + "\t" + strings.ReplaceAll(en.command, "\n", " ") + "\n")
	}
	text := strings.TrimRight(strings.ReplaceAll(b.String(), "\x00", ""), "\n")
	var lines []string
	for _, l := range strings.Split(text, "\n") {
		if l != "" {
			lines = append(lines, l)
		}
	}
	return lines
}

// splitCommand is the port of _hw_split_cmd: the quote-aware words of the FIRST simple command of s. The word
// list ends at the first unquoted ; & | < > ( ) (op is then true). Quotes stay in the words. An unquoted
// backslash or an unterminated quote makes the command unsplittable (err names why).
func splitCommand(s string) (words []string, op bool, err string) {
	var w []byte
	var q byte
	has := false
	for i := 0; i < len(s); i++ {
		c := s[i]
		if q != 0 {
			w = append(w, c)
			has = true
			if c == q {
				q = 0
			}
			continue
		}
		switch c {
		case ' ', '\t':
			if has {
				words = append(words, string(w))
				w, has = nil, false
			}
		case ';', '&', '|', '<', '>', '(', ')': // HW-OPERATOR-STOP
			op = true
			i = len(s)
		case '"', '\'':
			q = c
			w = append(w, c)
			has = true
		case '\\': // HW-BACKSLASH
			return nil, false, "backslash escape in the command"
		default:
			w = append(w, c)
			has = true
		}
	}
	if q != 0 { // HW-UNTERM
		return nil, false, "unterminated quote in the command"
	}
	if has {
		words = append(words, string(w))
	}
	return words, op, ""
}

// loneHighSurrogate reports a \uD800-\uDBFF escape inside a string that is not followed by a \uDC00-\uDFFF escape.
// jq refuses such a document ("Invalid \uXXXX\uXXXX surrogate pair escape") where encoding/json would substitute
// U+FFFD; a lone low surrogate is accepted by both. The scan only runs on input the decoder will also check.
func loneHighSurrogate(data []byte) bool {
	hex4 := func(b []byte) (uint64, bool) {
		u, err := strconv.ParseUint(string(b), 16, 32)
		return u, err == nil
	}
	in := false
	for i := 0; i < len(data); i++ {
		switch c := data[i]; {
		case !in:
			in = c == '"'
		case c == '"':
			in = false
		case c == '\\' && i+6 <= len(data) && data[i+1] == 'u':
			u, ok := hex4(data[i+2 : i+6])
			if !ok || u < 0xd800 || u >= 0xdc00 {
				i += 5
				continue
			}
			if i+12 > len(data) || data[i+6] != '\\' || data[i+7] != 'u' {
				return true
			}
			if l, ok := hex4(data[i+8 : i+12]); !ok || l < 0xdc00 || l >= 0xe000 {
				return true
			}
			i += 11
		case c == '\\':
			i++ // the escaped character
		}
	}
	return false
}
