package capa

// The bounded capability inventory built from capa's JSON, and the O_NOFOLLOW-safe reader of the file it
// arrives in. Reports COUNTS and a BOUNDED, sorted capability list - never raw disassembly or match trees.

import (
	"cmp"
	"encoding/json"
	"fmt"
	"io"
	"math/big"
	"os"
	"slices"
	"unicode/utf8"
)

// readStdoutJSON reads capa's stdout file with lstat + O_NOFOLLOW and parses it with json.loads
// semantics. It returns (value, "") on success, (nil, "") for an empty file and (nil, message) for
// malformed JSON, which is an explicit error and never an empty inventory. A symlink, a non-regular
// file or a file that changes while being read is a *fail.
func readStdoutJSON(path string) (any, string, error) {
	fi, err := os.Lstat(path)
	if err != nil {
		return nil, "", failf("cannot stat capa stdout: %s", path)
	}
	if fi.Mode()&os.ModeSymlink != 0 {
		return nil, "", failf("symlink detected at capa output path: %s", path)
	}
	if !fi.Mode().IsRegular() {
		return nil, "", failf("capa stdout is not a regular file: %s", path)
	}
	if fi.Size() == 0 {
		return nil, "", nil
	}
	f, err := openNoFollow(path)
	if err != nil {
		return nil, "", failf("cannot open capa stdout (symlink?): %s", path)
	}
	defer f.Close()
	before, err := f.Stat()
	if err != nil {
		return nil, "", &fail{osErrorText(err, path)}
	}
	// one byte more than lstat saw, so a file that grew is noticed by the identity check below
	raw, err := io.ReadAll(io.LimitReader(f, fi.Size()+1))
	if err != nil {
		return nil, "", &fail{osErrorText(err, path)}
	}
	after, err := f.Stat()
	if err != nil {
		return nil, "", &fail{osErrorText(err, path)}
	}
	if !sameFile(before, after) {
		return nil, "", failf("capa stdout changed while reading (TOCTOU)")
	}
	return parseCapaOutput(raw)
}

// parseCapaOutput is the part of the reader after the bytes are in memory: an empty document is
// (nil, ""), malformed JSON is (nil, message) and anything the legacy tool would die on is a *crash.
func parseCapaOutput(raw []byte) (any, string, error) {
	if len(raw) == 0 {
		return nil, "", nil
	}
	v, jerr := decodeJSON(raw)
	if jerr != nil {
		if je, ok := jerr.(*jsonError); ok {
			return nil, "malformed JSON in capa stdout: " + je.msg, nil
		}
		return nil, "", jerr
	}
	return v, "", nil
}

// sameFile compares (dev, ino, size, mtime_ns), the identity the legacy reader checks before and after:
// os.SameFile is the (dev, ino) test and ModTime carries the nanoseconds.
func sameFile(a, b os.FileInfo) bool {
	return os.SameFile(a, b) && a.Size() == b.Size() && a.ModTime().Equal(b.ModTime())
}

// pyTypeName is type(v).__name__ of a decoded JSON value.
func pyTypeName(v any) string {
	switch v.(type) {
	case nil:
		return "NoneType"
	case bool:
		return "bool"
	case string:
		return "str"
	case json.Number:
		return "int"
	case float64:
		return "float"
	case []any:
		return "list"
	}
	return "dict"
}

// pyTruthy is bool(v) of a decoded JSON value.
func pyTruthy(v any) bool {
	switch x := v.(type) {
	case nil:
		return false
	case bool:
		return x
	case string:
		return x != ""
	case json.Number:
		return string(x) != "0"
	case float64:
		return x != 0
	case []any:
		return len(x) > 0
	case map[string]any:
		return len(x) > 0
	}
	return true
}

// pyLen is len(v); ok is false for a type without a length (a TypeError in Python).
func pyLen(v any) (int, bool) {
	switch x := v.(type) {
	case string:
		return utf8.RuneCountInString(x), true
	case []any:
		return len(x), true
	case map[string]any:
		return len(x), true
	}
	return 0, false
}

// idList is [entry["id"] for entry in meta.get(key, []) if entry.get("id")]. A value that is not a
// list of objects raises in Python (iterating a non-iterable, calling .get on a non-object): a crash.
func idList(meta map[string]any, key string) ([]any, error) {
	out := []any{}
	raw, present := meta[key]
	if !present {
		return out, nil
	}
	switch list := raw.(type) {
	case []any:
		for _, e := range list {
			entry, ok := e.(map[string]any)
			if !ok {
				return nil, &crash{fmt.Sprintf("AttributeError: '%s' object has no attribute 'get'", pyTypeName(e))}
			}
			if pyTruthy(entry["id"]) {
				out = append(out, entry["id"])
			}
		}
	case map[string]any:
		if len(list) > 0 { // iterating a dict yields its str keys, which have no .get
			return nil, &crash{"AttributeError: 'str' object has no attribute 'get'"}
		}
	case string:
		if list != "" {
			return nil, &crash{"AttributeError: 'str' object has no attribute 'get'"}
		}
	default:
		return nil, &crash{fmt.Sprintf("TypeError: '%s' object is not iterable", pyTypeName(raw))}
	}
	return out, nil
}

// inventory is the bounded capability inventory before the caller adds tool metadata.
type inventory struct {
	totalCount, totalSampled int
	truncated                bool
	items                    []map[string]any
}

// buildInventory builds the bounded inventory from parsed capa JSON and returns the extra limitations. A
// nil value, a missing or empty "rules" and an unusable "rules" are all an empty inventory (the last also
// records schema drift); the cap is maxCapabilities and a hit is reported, never silent.
func buildInventory(capaJSON any, maxCapabilities *big.Int) (inventory, []string, error) {
	empty := inventory{items: []map[string]any{}}
	if capaJSON == nil {
		return empty, nil, nil
	}
	root, ok := capaJSON.(map[string]any)
	if !ok {
		return empty, nil, &crash{fmt.Sprintf("AttributeError: '%s' object has no attribute 'get'", pyTypeName(capaJSON))}
	}
	rawRules, present := root["rules"]
	if !present {
		return empty, nil, nil
	}
	rules, ok := rawRules.(map[string]any)
	if !ok {
		return empty, []string{fmt.Sprintf("capa JSON 'rules' is not a dict (schema drift): '%s'", pyTypeName(rawRules))}, nil
	}
	if len(rules) == 0 {
		return empty, nil, nil
	}
	type row struct {
		name      string
		namespace any
		item      map[string]any
	}
	rows := make([]row, 0, len(rules))
	for name, rawBody := range rules {
		body, ok := rawBody.(map[string]any)
		if !ok {
			return empty, nil, &crash{fmt.Sprintf("AttributeError: '%s' object has no attribute 'get'", pyTypeName(rawBody))}
		}
		var meta map[string]any = map[string]any{}
		if m, present := body["meta"]; present {
			if meta, ok = m.(map[string]any); !ok {
				return empty, nil, &crash{fmt.Sprintf("AttributeError: '%s' object has no attribute 'get'", pyTypeName(m))}
			}
		}
		var matches any = []any{}
		if m, present := body["matches"]; present {
			matches = m
		}
		count, ok := pyLen(matches)
		if !ok {
			return empty, nil, &crash{fmt.Sprintf("TypeError: object of type '%s' has no len()", pyTypeName(matches))}
		}
		attack, err := idList(meta, "attack")
		if err != nil {
			return empty, nil, err
		}
		mbc, err := idList(meta, "mbc")
		if err != nil {
			return empty, nil, err
		}
		var namespace any = ""
		if ns, present := meta["namespace"]; present {
			namespace = ns
		}
		rows = append(rows, row{name: name, namespace: namespace, item: map[string]any{
			"attack_ids": attack, "match_count": count, "mbc_ids": mbc, "name": name, "namespace": namespace,
		}})
	}
	total := len(rows)
	var sortErr error
	slices.SortStableFunc(rows, func(a, b row) int {
		as, aok := a.namespace.(string)
		bs, bok := b.namespace.(string)
		switch {
		case aok && bok:
			if c := cmp.Compare(as, bs); c != 0 {
				return c
			}
		case !aok && !bok && fmt.Sprint(a.namespace) == fmt.Sprint(b.namespace):
		default:
			sortErr = &crash{"TypeError: '<' not supported between namespaces of different types"}
		}
		return cmp.Compare(a.name, b.name)
	})
	if sortErr != nil {
		return empty, nil, sortErr
	}
	limit := total
	if maxCapabilities.IsInt64() {
		limit = int(min(maxCapabilities.Int64(), int64(total)))
	}
	capHit := maxCapabilities.Cmp(big.NewInt(int64(total))) < 0
	inv := inventory{totalCount: total, totalSampled: limit, truncated: capHit, items: make([]map[string]any, limit)}
	for i := 0; i < limit; i++ {
		inv.items[i] = rows[i].item
	}
	var extra []string
	if capHit {
		extra = append(extra, fmt.Sprintf("inventory truncated: capability cap %s reached (total_count=%d)", maxCapabilities.String(), total))
	}
	return inv, extra, nil
}
