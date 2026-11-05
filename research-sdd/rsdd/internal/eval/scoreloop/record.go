package scoreloop

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"time"
)

// This file reads a transcript the way the legacy jq pipeline did: the JSONL file is a stream of concatenated JSON
// values (not necessarily one per line); a record without a truthy .timestamp or .type is skipped; a value of an
// unexpected shape (a non-object record, a string .message, a non-object .origin on a user turn) is a parse failure
// of the whole transcript, never a silent skip.

var errShape = errors.New("transcript record has an unexpected shape")

var utf8BOM = []byte{0xEF, 0xBB, 0xBF}

// decodeValues reads every JSON value of data, in file order.
func decodeValues(data []byte) ([]any, error) {
	dec := json.NewDecoder(bytes.NewReader(bytes.TrimPrefix(data, utf8BOM)))
	var vals []any
	for {
		var v any
		err := dec.Decode(&v)
		if errors.Is(err, io.EOF) {
			return vals, nil
		}
		if err != nil {
			return nil, err
		}
		vals = append(vals, v)
	}
}

// truthy is jq's truthiness: everything except null and false.
func truthy(v any) bool {
	b, isBool := v.(bool)
	return v != nil && (!isBool || b)
}

// row is one scored transcript record.
type row struct {
	when     time.Time
	ts       string
	typ      string
	operator bool
	compact  bool
	para     string // last paragraph of the record's text
}

// verdict is a record's operator/compaction classification as computed by a jq override.
type verdict struct{ operator, compact bool }

// buildRows turns the values into rows sorted by instant (stable: equal instants keep file order). override, when
// non-nil, replaces the built-in operator and compaction tests; a record it has no entry for is skipped.
func buildRows(vals []any, override map[int]verdict) ([]row, error) {
	var rows []row
	for i, v := range vals {
		if v == nil {
			continue
		}
		obj, ok := v.(map[string]any)
		if !ok {
			return nil, errShape
		}
		if !truthy(obj["timestamp"]) || !truthy(obj["type"]) {
			continue
		}
		var vd verdict
		if override != nil {
			if vd, ok = override[i]; !ok {
				continue
			}
		} else {
			var err error
			if vd, err = builtinVerdict(obj); err != nil {
				return nil, err
			}
		}
		para, err := lastParagraphOf(obj)
		if err != nil {
			return nil, err
		}
		ts, isStr := obj["timestamp"].(string)
		if !isStr || ts == "" {
			continue
		}
		when, ok := parseTimestamp(ts)
		if !ok {
			continue
		}
		typ, _ := obj["type"].(string)
		rows = append(rows, row{when: when, ts: ts, typ: typ, operator: vd.operator, compact: vd.compact, para: para})
	}
	sortRows(rows)
	return rows, nil
}

// anyOrigin reports whether some record carries a non-null .origin, scanning in file order.
func anyOrigin(vals []any) bool {
	for _, v := range vals {
		if obj, ok := v.(map[string]any); ok && obj["origin"] != nil {
			return true
		}
	}
	return false
}
