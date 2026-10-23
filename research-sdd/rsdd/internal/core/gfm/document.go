package gfm

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"strings"
)

// State separates the three outcomes a reader must never conflate (kit CLAUDE.md section 7). The fourth,
// absent input, is an error: ReadFile returns ErrAbsentInput.
type State int

const (
	// StateEmptyInput: the source holds zero bytes.
	StateEmptyInput State = iota
	// StateNoTables: the source has content but no table row (no-match).
	StateNoTables
	// StateTables: at least one table.
	StateTables
)

func (s State) String() string {
	switch s {
	case StateEmptyInput:
		return "empty-input"
	case StateNoTables:
		return "no-tables"
	case StateTables:
		return "tables"
	}
	return fmt.Sprintf("State(%d)", int(s))
}

// ErrAbsentInput is returned (wrapped) by ReadFile when the file does not exist.
var ErrAbsentInput = errors.New("gfm: absent input")

// Table is a run of consecutive row lines. When the second line is a delimiter row the first is the Header and
// the delimiter is kept apart in Separator; otherwise Header and Separator are nil and every line is in Rows.
// A later delimiter row inside Rows keeps Sep == true so callers can skip it.
type Table struct {
	Header    *Row
	Separator *Row
	Rows      []Row
}

// Document is a parsed source.
type Document struct {
	State  State
	Lines  int // number of lines in the source
	Tables []Table
}

// Parse reads src with the default options (leading-pipe rows).
func Parse(src string) Document { return ParseWith(src, Options{}) }

// ParseWith groups the rows of src into tables.
func ParseWith(src string, opt Options) Document {
	d := Document{Lines: strings.Count(src, "\n")}
	if len(src) > 0 && !strings.HasSuffix(src, "\n") {
		d.Lines++
	}
	if len(src) == 0 {
		d.State = StateEmptyInput
		return d
	}
	var block []Row
	flush := func() {
		if len(block) == 0 {
			return
		}
		var t Table
		if len(block) >= 2 && !block[0].Sep && block[1].Sep {
			h, s := block[0], block[1]
			t.Header, t.Separator, t.Rows = &h, &s, block[2:]
		} else {
			t.Rows = block
		}
		d.Tables = append(d.Tables, t)
		block = nil
	}
	for r := range Rows(src, opt) {
		if n := len(block); n > 0 && block[n-1].Line+1 != r.Line {
			flush()
		}
		block = append(block, r)
	}
	flush()
	d.State = StateNoTables
	if len(d.Tables) > 0 {
		d.State = StateTables
	}
	return d
}

// ReadFile parses a file with the default options. A missing file returns an error wrapping ErrAbsentInput;
// an empty file returns a Document in StateEmptyInput and a nil error.
func ReadFile(path string) (Document, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return Document{}, fmt.Errorf("%w: %w", ErrAbsentInput, err)
		}
		return Document{}, fmt.Errorf("gfm: read %s: %w", path, err)
	}
	return Parse(string(b)), nil
}
