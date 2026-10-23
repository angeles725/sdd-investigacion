// Package reasons is the typed registry of reason-codes.v1.md.
//
// The table is generated from the markdown contract (go generate), so a code that is not a registry row
// cannot be constructed: Code has no exported fields and its zero value is invalid.
package reasons

//go:generate go run ./gen -md ../../../../toolbelt/reason-codes.v1.md -out table_gen.go

import (
	"errors"
	"fmt"
	"io"
	"strings"
)

// Class is the class column of the registry.
type Class string

// The two registry classes.
const (
	ClassDegraded Class = "degraded"
	ClassInput    Class = "input"
)

// Code identifies one registry row. The zero value is invalid.
type Code struct{ n int }

type entry struct {
	text         string
	class        Class
	emitters     []string
	meaning      string
	continuation string
}

const placeholder = "<v>"

// row returns the table entry of c, or false for the zero or a forged Code.
func (c Code) row() (entry, bool) {
	if c.n < 1 || c.n > len(table) {
		return entry{}, false
	}
	return table[c.n-1], true
}

// Text returns the code column of the row, or "" for the zero Code.
func (c Code) Text() string {
	e, _ := c.row()
	return e.text
}

// Class returns the class column of the row, or "" for the zero Code.
func (c Code) Class() Class {
	e, _ := c.row()
	return e.class
}

// Continuation returns the one runnable next step of the row.
func (c Code) Continuation() string {
	e, _ := c.row()
	return e.continuation
}

// Meaning returns the meaning column of the row.
func (c Code) Meaning() string {
	e, _ := c.row()
	return e.meaning
}

// Emitters returns a copy of the emitter basenames of the row.
func (c Code) Emitters() []string {
	e, _ := c.row()
	return append([]string(nil), e.emitters...)
}

// Placeholders returns how many "<v>" slots the code text carries.
func (c Code) Placeholders() int {
	e, _ := c.row()
	return strings.Count(e.text, placeholder)
}

// All returns every registered code in registry order.
func All() []Code {
	out := make([]Code, len(table))
	for i := range table {
		out[i] = Code{i + 1}
	}
	return out
}

// Lookup finds the code whose text is exactly text.
func Lookup(text string) (Code, bool) {
	for i := range table {
		if table[i].text == text {
			return Code{i + 1}, true
		}
	}
	return Code{}, false
}

// Render returns the degraded line for c with one arg per "<v>" placeholder, in order. A wrong argument
// count, an unregistered or input-class code, or an argument holding a line break is an error: the line is
// never rendered with a missing or surplus value.
func Render(c Code, args ...string) (string, error) {
	e, ok := c.row()
	if !ok {
		return "", errors.New("reasons: unregistered code")
	}
	if e.class != ClassDegraded {
		return "", fmt.Errorf("reasons: %q is an input-class code, not a degraded line", e.text)
	}
	parts := strings.Split(e.text, placeholder)
	if len(args) != len(parts)-1 {
		return "", fmt.Errorf("reasons: %q takes %d argument(s), got %d", e.text, len(parts)-1, len(args))
	}
	var b strings.Builder
	for i, p := range parts {
		b.WriteString(p)
		if i < len(args) {
			if strings.ContainsAny(args[i], "\r\n") {
				return "", fmt.Errorf("reasons: argument %d of %q contains a line break", i+1, e.text)
			}
			b.WriteString(args[i])
		}
	}
	return b.String(), nil
}

// Emit writes the degraded line for c, newline-terminated, to w. Nothing is written on error.
func Emit(w io.Writer, c Code, args ...string) error {
	line, err := Render(c, args...)
	if err != nil {
		return err
	}
	_, err = io.WriteString(w, line+"\n")
	return err
}

// EmitDetail is Emit with free-form detail appended after a single space, for prefix codes such as
// "degraded: retro not readable:" whose emit line continues with a path or message. The detail must be a
// non-empty single line.
func EmitDetail(w io.Writer, c Code, detail string, args ...string) error {
	if detail == "" || strings.ContainsAny(detail, "\r\n") {
		return errors.New("reasons: detail must be a non-empty single line")
	}
	line, err := Render(c, args...)
	if err != nil {
		return err
	}
	_, err = io.WriteString(w, line+" "+detail+"\n")
	return err
}
