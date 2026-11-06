// Package ciworkflow reads the `paths:` filter of one event of a GitHub workflow file. It exists for the guard
// tests that keep a filter from being narrowed without a test going red (kit issue #2737).
//
// It is not a YAML parser. It recognises the block form the kit's workflows use (`on:` at column 0, one key per
// event, `paths:` followed by `- entry` lines) and the flow form `paths: [a, b]`; any other shape is reported as
// Unrecognised, never as an empty list.
//
// It looks at `paths` and `paths-ignore` only. It does not read `branches` / `branches-ignore`, the `types:` of an
// event or a job-level `if:` condition, so a pass here says nothing about those.
//
// internal/gate has its own scanner (pfScanWorkflow): a byte-parity port of the merge gate's awk that answers
// "would this check be skipped for this pull request" and reads the pull_request event only. This reader answers
// a different question (which entries does an event list) for any event, so the two are kept apart.
package ciworkflow

import "strings"

// State says what the reader found for the event.
type State int

const (
	Found        State = iota // the event has a paths list; the entries are returned
	NoEvent                   // `on:` has no such event
	NoPaths                   // the event has neither `paths:` nor `paths-ignore:` (it runs on every change)
	Ignores                   // the event carries `paths-ignore:` (it excludes changes; the entries are not read)
	Unrecognised              // no block-form `on:`, a flow-form event, or a `paths:` value this reader does not understand
)

func (s State) String() string {
	return [...]string{"found", "no such event", "no paths filter", "paths-ignore filter", "unrecognised form"}[s]
}

// EventPaths returns the `paths:` entries of event in the workflow source src.
func EventPaths(src, event string) ([]string, State) {
	on, ok := child(significant(strings.Split(src, "\n")), "on")
	if !ok || on.inline != "" {
		return nil, Unrecognised
	}
	ev, ok := child(on.body, event)
	if !ok {
		return nil, NoEvent
	}
	if ev.inline != "" {
		return nil, Unrecognised // `push: {paths: [...]}`: a filter may hide in the flow mapping
	}
	if _, ok := child(ev.body, "paths-ignore"); ok {
		return nil, Ignores
	}
	paths, ok := child(ev.body, "paths")
	if !ok {
		return nil, NoPaths
	}
	if paths.inline != "" {
		return flowList(paths.inline)
	}
	var out []string
	for _, l := range paths.body {
		item, ok := strings.CutPrefix(strings.TrimSpace(l), "- ")
		if !ok {
			return nil, Unrecognised
		}
		out = append(out, unquote(item))
	}
	if len(out) == 0 {
		return nil, Unrecognised
	}
	return out, Found
}

// Missing returns the entries of want that have is lacking, in want's order.
func Missing(have, want []string) []string {
	var out []string
	for _, w := range want {
		found := false
		for _, h := range have {
			found = found || h == w
		}
		if !found {
			out = append(out, w)
		}
	}
	return out
}

type node struct {
	inline string   // the text after "key:" on the key's own line
	body   []string // the significant lines nested under the key
}

// child finds `key:` among the shallowest keys of lines and returns what is nested under it.
func child(lines []string, key string) (node, bool) {
	if len(lines) == 0 {
		return node{}, false
	}
	top := indent(lines[0])
	for i, l := range lines {
		if indent(l) != top {
			continue
		}
		rest, ok := strings.CutPrefix(strings.TrimSpace(l), key+":")
		if !ok {
			continue
		}
		n := node{inline: strings.TrimSpace(rest)}
		for _, b := range lines[i+1:] {
			if indent(b) <= top && !strings.HasPrefix(strings.TrimSpace(b), "- ") {
				break // the next key at this level or above; a list item may sit at the key's own indent
			}
			n.body = append(n.body, b)
		}
		return n, true
	}
	return node{}, false
}

// significant drops blank lines and whole-line comments, and cuts a trailing ` # comment`.
func significant(lines []string) []string {
	var out []string
	for _, l := range lines {
		l, _, _ = strings.Cut(l, " #")
		if t := strings.TrimSpace(l); t != "" && !strings.HasPrefix(t, "#") {
			out = append(out, strings.TrimRight(l, " \t\r"))
		}
	}
	return out
}

func indent(l string) int { return len(l) - len(strings.TrimLeft(l, " ")) }

func flowList(s string) ([]string, State) {
	inner, ok := strings.CutPrefix(s, "[")
	inner, ok2 := strings.CutSuffix(inner, "]")
	if !ok || !ok2 || strings.TrimSpace(inner) == "" {
		return nil, Unrecognised
	}
	var out []string
	for _, e := range strings.Split(inner, ",") {
		out = append(out, unquote(strings.TrimSpace(e)))
	}
	return out, Found
}

func unquote(s string) string {
	s = strings.TrimSpace(s)
	for _, q := range []string{`"`, `'`} {
		if inner, ok := strings.CutPrefix(s, q); ok {
			if inner, ok = strings.CutSuffix(inner, q); ok {
				return inner
			}
		}
	}
	return s
}
