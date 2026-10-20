// Package envelope renders the research-sdd.<instrument>/v1 JSON envelope of json-envelope.v1.md.
//
// One renderer replaces the per-instrument envelope builders of verify-registry.sh, sweep-retros.sh,
// retro-gate.sh and resume-state.sh. Member order is part of the output the shell instruments print, so
// objects are ordered slices, not maps, and the position of "reason" relative to "counts" is an explicit
// KeyOrder the caller must choose: the instruments disagree (retro-gate.sh and resume-state.sh print reason
// first, as the contract table does; sweep-retros.sh and verify-registry.sh print counts first), and there
// is deliberately no default.
//
// Two rules of the contract are applied while rendering, and nothing else is repaired: the block reason of
// a retro-gate verdict item has its invalid UTF-8 replaced with U+FFFD exactly like jq does (the contract
// says so); invalid UTF-8 anywhere else is an error.
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

// KeyOrder is the position of "reason" relative to "counts" in the rendered envelope. The instruments
// disagree, so the caller must name the order of the instrument it ports; there is no default.
type KeyOrder int

// The two orders in use. The zero value is invalid.
const (
	OrderInvalid KeyOrder = iota
	// ReasonBeforeCounts renders schema, state, reason, counts, items: the contract table, retro-gate.sh,
	// resume-state.sh and every hand-built degraded line.
	ReasonBeforeCounts
	// CountsBeforeReason renders schema, state, counts, reason, items: the jq builders of sweep-retros.sh
	// and verify-registry.sh.
	CountsBeforeReason
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
	if err := checkObject(e.Counts, "counts"); err != nil {
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
		where := fmt.Sprintf("items[%d]", i)
		if len(it) == 0 || it[0].Key != "kind" {
			return fmt.Errorf("envelope: %s must lead with its kind field", where)
		}
		if kind, ok := it[0].Value.(string); !ok || kind == "" {
			return fmt.Errorf("envelope: %s kind must be a non-empty string", where)
		}
		if err := checkObject(it, where); err != nil {
			return err
		}
	}
	return nil
}

// checkObject rejects empty and duplicate keys in o and in every object nested anywhere below it.
func checkObject(o Object, where string) error {
	seen := make(map[string]bool, len(o))
	for _, f := range o {
		if f.Key == "" {
			return fmt.Errorf("envelope: %s has an empty key", where)
		}
		if seen[f.Key] {
			return fmt.Errorf("envelope: %s has duplicate key %q", where, f.Key)
		}
		seen[f.Key] = true
		if err := checkValue(f.Value, where+"."+f.Key); err != nil {
			return err
		}
	}
	return nil
}

func checkValue(v any, where string) error {
	switch x := v.(type) {
	case Object:
		return checkObject(x, where)
	case []Object:
		for i, o := range x {
			if err := checkObject(o, fmt.Sprintf("%s[%d]", where, i)); err != nil {
				return err
			}
		}
	case []any:
		for i, e := range x {
			if err := checkValue(e, fmt.Sprintf("%s[%d]", where, i)); err != nil {
				return err
			}
		}
	}
	return nil
}

// sanitizeVerdict applies the one repair the contract specifies: for a retro-gate verdict item (kind
// "verdict"), invalid UTF-8 in the block reason becomes U+FFFD, as jq does when the instrument builds it.
// The input item is not modified.
func sanitizeVerdict(it Object) Object {
	if len(it) == 0 || it[0].Value != "verdict" {
		return it
	}
	out := make(Object, len(it))
	copy(out, it)
	for i, f := range out {
		if s, ok := f.Value.(string); ok && f.Key == "reason" {
			out[i].Value = jqValidUTF8(s)
		}
	}
	return out
}

// jqValidUTF8 replaces invalid UTF-8 with U+FFFD the way jq's decoder does: a stray continuation byte, an
// invalid lead byte (0x80-0xC1, 0xF5-0xFF) and each byte of such a run count one replacement; a lead byte
// followed by too few continuation bytes counts one for the truncated prefix; a complete but invalid
// sequence (overlong, surrogate, above U+10FFFF) counts one for the whole sequence.
func jqValidUTF8(s string) string {
	if utf8.ValidString(s) {
		return s
	}
	var b strings.Builder
	for i := 0; i < len(s); {
		c := s[i]
		if c < utf8.RuneSelf {
			b.WriteByte(c)
			i++
			continue
		}
		var need int
		switch {
		case c >= 0xC2 && c <= 0xDF:
			need = 2
		case c >= 0xE0 && c <= 0xEF:
			need = 3
		case c >= 0xF0 && c <= 0xF4:
			need = 4
		default:
			b.WriteRune(utf8.RuneError)
			i++
			continue
		}
		n := 1
		for n < need && i+n < len(s) && s[i+n]&0xC0 == 0x80 {
			n++
		}
		if n == need && utf8.ValidString(s[i:i+n]) {
			b.WriteString(s[i : i+n])
		} else {
			b.WriteRune(utf8.RuneError)
		}
		i += n
	}
	return b.String()
}

// Pretty renders the envelope the way the shell instruments' jq builders print it: two-space indent,
// members in the given order, and a trailing newline.
func (e Envelope) Pretty(order KeyOrder) ([]byte, error) { return e.render(true, order) }

// Compact renders the single-line form the instruments print by hand when jq is unavailable, with members
// in the given order and a trailing newline.
func (e Envelope) Compact(order KeyOrder) ([]byte, error) { return e.render(false, order) }

func (o KeyOrder) members() ([]string, error) {
	switch o {
	case ReasonBeforeCounts:
		return []string{"schema", "state", "reason", "counts", "items"}, nil
	case CountsBeforeReason:
		return []string{"schema", "state", "counts", "reason", "items"}, nil
	}
	return nil, fmt.Errorf("envelope: invalid key order %d (choose ReasonBeforeCounts or CountsBeforeReason)", int(o))
}

func (e Envelope) render(pretty bool, ko KeyOrder) ([]byte, error) {
	order, err := ko.members()
	if err != nil {
		return nil, err
	}
	if err := e.Validate(); err != nil {
		return nil, err
	}
	var reason any
	if e.Reason != "" {
		reason = e.Reason
	}
	items := make([]any, len(e.Items))
	for i, it := range e.Items {
		items[i] = sanitizeVerdict(it)
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
