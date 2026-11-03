package ghidra

import (
	"bytes"
	"encoding/json"
	"math/big"
	"os"
	"unicode/utf8"
)

// sentinel is a placeholder value that must never be accepted as evidence: an output file holding exactly these bytes
// was seeded and never written by the exporter.
const sentinel = "RSDD-SENTINEL"

// kinds are the evidence lists the exporter emits, in report order.
var kinds = []string{"functions", "symbols", "imports", "exports", "strings", "references"}

// capNames are the exporter's seven numeric arguments in argv order; the last is the per-string length cap.
var capNames = []string{"functions", "symbols", "imports", "exports", "strings", "references", "string_chars"}

// caps returns the effective caps by name: functions, symbols, imports and exports share --max-functions.
func (c config) caps() map[string]int {
	return map[string]int{"functions": c.maxFunctions, "symbols": c.maxFunctions, "imports": c.maxFunctions,
		"exports": c.maxFunctions, "strings": c.maxStrings, "references": c.maxReferences, "string_chars": c.maxStringChars}
}

type fieldType int

const (
	typeString fieldType = iota
	typeBool
)

// recordFields are the exact keys and value types of one record per kind.
var recordFields = map[string]map[string]fieldType{
	"functions":  {"address": typeString, "name": typeString, "external": typeBool, "thunk": typeBool},
	"symbols":    {"address": typeString, "name": typeString, "type": typeString, "external": typeBool},
	"imports":    {"address": typeString, "name": typeString, "type": typeString, "external": typeBool},
	"exports":    {"address": typeString, "name": typeString, "type": typeString, "external": typeBool},
	"strings":    {"address": typeString, "value": typeString, "value_truncated": typeBool},
	"references": {"from": typeString, "to": typeString, "type": typeString},
}

var (
	programFields = []string{"name", "format", "language", "compiler", "image_base", "md5"}
	topFields     = []string{"schema", "status", "program", "analysis", "functions", "symbols", "imports", "exports",
		"strings", "references", "counts", "caps", "truncation", "string_values_truncated", "warnings", "errors", "limitations"}
)

// validateCurated checks the exporter's curated JSON against the caps this run asked for and the contract in
// toolbelt/ghidra-curated-evidence.v1.md. It returns the document's status ("complete" or "partial") and no
// errors, or an empty status and exactly one typed error:
//
//	missing-curated-output   nothing was written
//	unsafe-curated-output    a symlink (removed) or a non-regular file
//	curated-output-cap       larger than maxBytes (the file is cut to maxBytes)
//	unchanged-sentinel       still the placeholder
//	malformed-curated-output anything else: bad UTF-8/JSON, wrong shape or types, caps that are not this run's,
//	                         counts or truncation flags that contradict the lists, a status that contradicts them
func validateCurated(path string, caps map[string]int, maxBytes int64) (string, []string) {
	fi, err := os.Stat(path)
	if err != nil {
		return "", []string{"missing-curated-output"}
	}
	if lfi, lerr := os.Lstat(path); lerr == nil && lfi.Mode()&os.ModeSymlink != 0 {
		_ = os.Remove(path)
		return "", []string{"unsafe-curated-output"}
	}
	if !fi.Mode().IsRegular() {
		return "", []string{"unsafe-curated-output"}
	}
	if fi.Size() > maxBytes {
		_ = os.Truncate(path, maxBytes)
		return "", []string{"curated-output-cap"}
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return "", []string{"malformed-curated-output"}
	}
	if string(raw) == sentinel {
		return "", []string{"unchanged-sentinel"}
	}
	if status, ok := curatedStatus(raw, caps); ok {
		return status, nil
	}
	return "", []string{"malformed-curated-output"}
}

// curatedStatus decodes raw (one JSON object at offset 0 followed by exactly one newline) and validates it.
func curatedStatus(raw []byte, caps map[string]int) (string, bool) {
	if !utf8.Valid(raw) || len(raw) == 0 || raw[0] != '{' {
		return "", false
	}
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	var v map[string]any
	if err := dec.Decode(&v); err != nil || string(raw[dec.InputOffset():]) != "\n" {
		return "", false
	}
	return checkDocument(v, caps)
}

func checkDocument(v map[string]any, caps map[string]int) (string, bool) {
	if !exactKeys(v, topFields) || v["schema"] != "ghidra-curated-evidence.v1" {
		return "", false
	}
	status, _ := v["status"].(string)
	if status != "complete" && status != "partial" {
		return "", false
	}
	if !capsEqual(v["caps"], caps) {
		return "", false
	}
	program, ok := v["program"].(map[string]any)
	if !ok || !exactKeys(program, programFields) {
		return "", false
	}
	for _, f := range programFields {
		if _, isStr := program[f].(string); !isStr {
			return "", false
		}
	}
	analysis, ok := v["analysis"].(map[string]any)
	if !ok || !exactKeys(analysis, []string{"timed_out"}) {
		return "", false
	}
	timedOut, ok := analysis["timed_out"].(bool)
	if !ok {
		return "", false
	}
	shortened, ok := asInt(v["string_values_truncated"])
	if !ok || shortened.Sign() < 0 {
		return "", false
	}
	partial := timedOut || shortened.Sign() > 0
	counts, ok1 := v["counts"].(map[string]any)
	truncation, ok2 := v["truncation"].(map[string]any)
	if !ok1 || !ok2 {
		return "", false
	}
	for _, kind := range kinds {
		truncated, ok := checkKind(kind, v[kind], counts[kind], truncation[kind], caps)
		if !ok {
			return "", false
		}
		partial = partial || truncated
	}
	if (status == "partial") != partial {
		return "", false
	}
	for _, d := range []string{"warnings", "errors", "limitations"} {
		list, ok := v[d].([]any)
		if !ok {
			return "", false
		}
		for _, item := range list {
			if _, isStr := item.(string); !isStr {
				return "", false
			}
		}
	}
	return status, true
}

// checkKind validates one kind's list, its counts entry and its truncation flag; it returns the flag.
func checkKind(kind string, itemsV, countV, truncV any, caps map[string]int) (truncated, ok bool) {
	items, isList := itemsV.([]any)
	count, isMap := countV.(map[string]any)
	truncated, isBool := truncV.(bool)
	if !isList || !isMap || !isBool || len(items) > caps[kind] || !exactKeys(count, []string{"emitted", "observed", "exact"}) {
		return false, false
	}
	emitted, ok := asInt(count["emitted"])
	if !ok || emitted.Cmp(big.NewInt(int64(len(items)))) != 0 {
		return false, false
	}
	observed, ok := asInt(count["observed"])
	if !ok || observed.Cmp(big.NewInt(int64(len(items)))) < 0 || observed.Cmp(big.NewInt(int64(caps[kind])+1)) > 0 {
		return false, false
	}
	exact, isBool := count["exact"].(bool)
	if !isBool || exact == truncated || (exact && observed.Cmp(big.NewInt(int64(len(items)))) != 0) {
		return false, false
	}
	fields := recordFields[kind]
	for _, item := range items {
		record, isMap := item.(map[string]any)
		if !isMap || len(record) != len(fields) {
			return false, false
		}
		for key, want := range fields {
			val, present := record[key]
			if !present || !typeOK(val, want) {
				return false, false
			}
		}
		if kind == "strings" && utf8.RuneCountInString(record["value"].(string)) > caps["string_chars"] {
			return false, false
		}
	}
	return truncated, true
}

func typeOK(v any, t fieldType) bool {
	if t == typeBool {
		_, ok := v.(bool)
		return ok
	}
	_, ok := v.(string)
	return ok
}

// exactKeys reports whether m has exactly the given keys.
func exactKeys(m map[string]any, keys []string) bool {
	if len(m) != len(keys) {
		return false
	}
	for _, k := range keys {
		if _, ok := m[k]; !ok {
			return false
		}
	}
	return true
}

// asInt is `type(x) is int` for a decoded JSON number: an integer literal (no fraction, no exponent).
func asInt(v any) (*big.Int, bool) {
	n, ok := v.(json.Number)
	if !ok {
		return nil, false
	}
	i, ok := new(big.Int).SetString(n.String(), 10)
	return i, ok
}

// capsEqual is `value["caps"] == caps` with every value an int.
func capsEqual(v any, caps map[string]int) bool {
	m, ok := v.(map[string]any)
	if !ok || len(m) != len(caps) {
		return false
	}
	for name, want := range caps {
		got, ok := asInt(m[name])
		if !ok || got.Cmp(big.NewInt(int64(want))) != 0 {
			return false
		}
	}
	return true
}
