package native

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"math/big"
	"sort"
)

// functionKeys are the radare2 `aflj` record keys kept in the evidence, in no particular order (the encoder sorts).
var functionKeys = []string{"name", "offset", "size", "nargs", "nbbs", "type"}

var errInvalidFunctions = errors.New("invalid-functions-json")

// parseFunctions turns the `aflj` output into the evidence records: only the whitelisted keys of each object
// are kept (values untouched, numbers exact), non-object items are dropped, and the list is sorted by
// (offset, name) with a missing offset read as 0 and a missing name as "". Anything that is not one JSON array,
// or whose offset is not a number or name not a string, is errInvalidFunctions.
func parseFunctions(raw []byte) ([]map[string]any, error) {
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	var doc any
	if err := dec.Decode(&doc); err != nil {
		return nil, errInvalidFunctions
	}
	if _, err := dec.Token(); err != io.EOF {
		return nil, errInvalidFunctions
	}
	list, ok := doc.([]any)
	if !ok {
		return nil, errInvalidFunctions
	}
	type record struct {
		fields map[string]any
		offset *big.Rat
		name   string
	}
	var records []record
	for _, item := range list {
		obj, ok := item.(map[string]any)
		if !ok {
			continue
		}
		r := record{fields: map[string]any{}, offset: new(big.Rat)}
		for _, k := range functionKeys {
			if v, present := obj[k]; present {
				r.fields[k] = v
			}
		}
		if v, present := obj["offset"]; present {
			n, isNum := v.(json.Number)
			if !isNum {
				return nil, errInvalidFunctions
			}
			if _, ok := r.offset.SetString(n.String()); !ok {
				return nil, errInvalidFunctions
			}
		}
		if v, present := obj["name"]; present {
			if r.name, ok = v.(string); !ok {
				return nil, errInvalidFunctions
			}
		}
		records = append(records, r)
	}
	sort.SliceStable(records, func(i, j int) bool {
		if c := records[i].offset.Cmp(records[j].offset); c != 0 {
			return c < 0
		}
		return records[i].name < records[j].name
	})
	out := make([]map[string]any, len(records))
	for i, r := range records {
		out[i] = r.fields
	}
	return out, nil
}
