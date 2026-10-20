// Package envelope renders the research-sdd.<instrument>/v1 JSON envelope of json-envelope.v1.md.
//
// One renderer replaces the four hand-rolled jq builders. Field order is part of the contract with the
// shell instruments, so objects are ordered slices, not maps.
package envelope

import (
	"bytes"
	"errors"
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"unicode/utf8"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/state"
)

// Field is one key of an ordered object.
type Field struct {
	Key   string
	Value any
}

// Object is a JSON object whose keys keep their slice order.
type Object []Field

// Envelope is one instrument result.
type Envelope struct {
	// Schema is "research-sdd.<instrument>/v1".
	Schema string
	// State is one of the five envelope states.
	State state.State
	// Reason is the one-sentence cause; it must be empty (JSON null) when State is OK and non-empty otherwise.
	Reason string
	// Counts holds the instrument's integer counters, in the order they are rendered.
	Counts Object
	// Items are the findings, each starting with a "kind" field. Non-empty if and only if State is OK.
	Items []Object
}

var schemaSyntax = regexp.MustCompile(`^research-sdd\.[a-z0-9][a-z0-9-]*/v[0-9]+$`)

// Validate checks the invariants of json-envelope.v1.md: a well-formed schema id, a valid state, a null
// reason exactly for OK, integer counters, items that each lead with a string "kind", and items non-empty
// if and only if the state is OK.
func (e Envelope) Validate() error {
	if !schemaSyntax.MatchString(e.Schema) {
		return fmt.Errorf("envelope: schema %q is not research-sdd.<instrument>/v<N>", e.Schema)
	}
	if _, err := e.State.ExitCode(); err != nil {
		return fmt.Errorf("envelope: %w", err)
	}
	if e.State == state.OK {
		if e.Reason != "" {
			return errors.New("envelope: reason must be null when state is ok")
		}
		if len(e.Items) == 0 {
			return errors.New("envelope: state ok requires at least one item")
		}
	} else {
		if e.Reason == "" {
			return fmt.Errorf("envelope: state %s requires a reason", e.State)
		}
		if len(e.Items) != 0 {
			return fmt.Errorf("envelope: state %s must have no items (a finding is never hidden behind another state)", e.State)
		}
	}
	if err := checkKeys(e.Counts, "counts"); err != nil {
		return err
	}
	for _, f := range e.Counts {
		switch f.Value.(type) {
		case int, int64:
		default:
			return fmt.Errorf("envelope: counts.%s is %T, want an integer", f.Key, f.Value)
		}
	}
	for i, it := range e.Items {
		if err := checkKeys(it, fmt.Sprintf("items[%d]", i)); err != nil {
			return err
		}
		if kind, ok := lookup(it, "kind").(string); !ok || kind == "" {
			return fmt.Errorf("envelope: items[%d] lacks a non-empty string kind", i)
		}
	}
	return nil
}

func lookup(o Object, key string) any {
	for _, f := range o {
		if f.Key == key {
			return f.Value
		}
	}
	return nil
}

func checkKeys(o Object, where string) error {
	seen := make(map[string]bool, len(o))
	for _, f := range o {
		if f.Key == "" {
			return fmt.Errorf("envelope: %s has an empty key", where)
		}
		if seen[f.Key] {
			return fmt.Errorf("envelope: %s has duplicate key %q", where, f.Key)
		}
		seen[f.Key] = true
	}
	return nil
}

// Pretty renders the envelope the way the shell instruments' jq builders print it: two-space indent,
// keys in the order schema, state, counts, reason, items, and a trailing newline.
func (e Envelope) Pretty() ([]byte, error) {
	return e.render(true, []string{"schema", "state", "counts", "reason", "items"})
}

// Compact renders the single-line form the instruments print by hand when jq is unavailable: keys in the
// order schema, state, reason, counts, items, and a trailing newline.
func (e Envelope) Compact() ([]byte, error) {
	return e.render(false, []string{"schema", "state", "reason", "counts", "items"})
}

func (e Envelope) render(pretty bool, order []string) ([]byte, error) {
	if err := e.Validate(); err != nil {
		return nil, err
	}
	var reason any
	if e.Reason != "" {
		reason = e.Reason
	}
	items := make([]any, len(e.Items))
	for i, it := range e.Items {
		items[i] = it
	}
	fields := map[string]any{"schema": e.Schema, "state": e.State.String(), "counts": e.Counts, "reason": reason, "items": items}
	top := make(Object, 0, len(order))
	for _, k := range order {
		top = append(top, Field{k, fields[k]})
	}
	w := writer{pretty: pretty}
	if err := w.value(top, 0); err != nil {
		return nil, err
	}
	w.buf.WriteByte('\n')
	return w.buf.Bytes(), nil
}

// ExitCode is the --json process exit code for the envelope's state (0, or 3 for degraded).
func (e Envelope) ExitCode() (int, error) { return e.State.ExitCode() }

// Degraded builds the envelope of an instrument that could not run to completion.
func Degraded(schema, reason string) Envelope {
	return Envelope{Schema: schema, State: state.Degraded, Reason: reason}
}

// writer prints JSON like jq: member order preserved, "{}" and "[]" for empty containers, only the
// characters below U+0020, DEL, quote and backslash escaped, everything else (including <, > and &) raw.
type writer struct {
	pretty bool
	buf    bytes.Buffer
}

func (w *writer) nl(depth int) {
	if w.pretty {
		w.buf.WriteByte('\n')
		w.buf.WriteString(strings.Repeat("  ", depth))
	}
}

func (w *writer) value(v any, depth int) error {
	switch x := v.(type) {
	case nil:
		w.buf.WriteString("null")
	case bool:
		w.buf.WriteString(strconv.FormatBool(x))
	case int:
		w.buf.WriteString(strconv.Itoa(x))
	case int64:
		w.buf.WriteString(strconv.FormatInt(x, 10))
	case string:
		return w.str(x)
	case Object:
		return w.object(x, depth)
	case []Object:
		return w.list(len(x), depth, func(i int) any { return x[i] })
	case []any:
		return w.list(len(x), depth, func(i int) any { return x[i] })
	case []string:
		return w.list(len(x), depth, func(i int) any { return x[i] })
	default:
		return fmt.Errorf("envelope: unsupported value of type %T", v)
	}
	return nil
}

func (w *writer) list(n, depth int, at func(int) any) error {
	if n == 0 {
		w.buf.WriteString("[]")
		return nil
	}
	w.buf.WriteByte('[')
	for i := 0; i < n; i++ {
		if i > 0 {
			w.buf.WriteByte(',')
		}
		w.nl(depth + 1)
		if err := w.value(at(i), depth+1); err != nil {
			return err
		}
	}
	w.nl(depth)
	w.buf.WriteByte(']')
	return nil
}

func (w *writer) object(o Object, depth int) error {
	if len(o) == 0 {
		w.buf.WriteString("{}")
		return nil
	}
	w.buf.WriteByte('{')
	for i, f := range o {
		if i > 0 {
			w.buf.WriteByte(',')
		}
		w.nl(depth + 1)
		if err := w.str(f.Key); err != nil {
			return err
		}
		w.buf.WriteByte(':')
		if w.pretty {
			w.buf.WriteByte(' ')
		}
		if err := w.value(f.Value, depth+1); err != nil {
			return err
		}
	}
	w.nl(depth)
	w.buf.WriteByte('}')
	return nil
}

func (w *writer) str(s string) error {
	if !utf8.ValidString(s) {
		return fmt.Errorf("envelope: string %q is not valid UTF-8", s)
	}
	w.buf.WriteByte('"')
	for _, r := range s {
		switch {
		case r == '"':
			w.buf.WriteString(`\"`)
		case r == '\\':
			w.buf.WriteString(`\\`)
		case r == '\n':
			w.buf.WriteString(`\n`)
		case r == '\t':
			w.buf.WriteString(`\t`)
		case r == '\r':
			w.buf.WriteString(`\r`)
		case r == '\b':
			w.buf.WriteString(`\b`)
		case r == '\f':
			w.buf.WriteString(`\f`)
		case r < 0x20 || r == 0x7f:
			fmt.Fprintf(&w.buf, `\u%04x`, r)
		default:
			w.buf.WriteRune(r)
		}
	}
	w.buf.WriteByte('"')
	return nil
}
