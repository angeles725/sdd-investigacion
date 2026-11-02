package kaitai

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"unicode/utf8"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/adapter/helpers"
)

// limitations are the static caveats every evidence document carries (_LIMITATIONS).
var limitations = []string{
	"Kaitai Struct driver operates read-only; the binary is never executed.",
	"Only top-level SEQ_FIELDS are walked; implicit/computed fields and instances are not captured.",
	"Bubblewrap on WSL2 is defense-in-depth, not a hostile-parser security boundary; use a disposable VM for adversarial binaries.",
}

// readDriverJSON is _read_stdout_json: the driver's one JSON object, or the reason there is none.
func readDriverJSON(path string) (map[string]any, string) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, "cannot read driver output: " + err.Error()
	}
	text := strings.TrimSpace(strings.ToValidUTF8(string(raw), "�"))
	if text == "" {
		return nil, "driver produced no output (empty stdout)"
	}
	dec := json.NewDecoder(strings.NewReader(text))
	dec.UseNumber()
	var v any
	if err := dec.Decode(&v); err != nil {
		return nil, "driver output is not valid JSON: " + err.Error()
	}
	if dec.More() {
		return nil, "driver output is not valid JSON: extra data"
	}
	m, ok := v.(map[string]any)
	if !ok {
		return nil, "driver output is not a JSON object: " + pyTypeName(v)
	}
	return m, ""
}

func pyTypeName(v any) string {
	switch v.(type) {
	case nil:
		return "NoneType"
	case bool:
		return "bool"
	case string:
		return "str"
	case []any:
		return "list"
	case json.Number:
		if strings.ContainsAny(v.(json.Number).String(), ".eE") {
			return "float"
		}
		return "int"
	}
	return fmt.Sprintf("%T", v)
}

func truthy(v any) bool {
	switch x := v.(type) {
	case nil:
		return false
	case bool:
		return x
	case string:
		return x != ""
	}
	return true
}

func toInt(v any) int64 {
	if n, ok := v.(json.Number); ok {
		if i, err := n.Int64(); err == nil {
			return i
		}
	}
	return 0
}

// buildLimitationsAndErrors is _build_limitations_and_errors.
func buildLimitationsAndErrors(driver map[string]any, runErrors []string, parseJSONErr string) ([]string, []string, bool) {
	lims := append([]string{}, limitations...)
	errs := append([]string{}, runErrors...)
	trunc, capLims := helpers.RunTruncation(runErrors, "kaitai-driver")
	lims = append(lims, capLims...)
	truncated := trunc
	if parseJSONErr != "" {
		errs = append(errs, "driver-output-error: "+parseJSONErr)
	}
	if driver == nil {
		return lims, errs, truncated
	}
	if pe := driver["parse_error"]; truthy(pe) {
		errs = append(errs, fmt.Sprintf("parse-error: %v", pe))
	}
	if truthy(driver["memory_cap"]) {
		errs = append(errs, "memory-cap")
		lims = append(lims, "kaitai-driver run truncated: memory-cap reached — inventory is incomplete")
		truncated = true
	}
	if truthy(driver["truncated"]) {
		truncated = true
		if truthy(driver["depth_cap"]) {
			lims = append(lims, "structure walk depth cap fired — sub-struct children not included")
		}
		if truthy(driver["value_trunc"]) {
			lims = append(lims, "field value bytes cap fired — large values shown truncated")
		}
		counts, _ := driver["counts"].(map[string]any)
		sampled, total := toInt(counts["sampled"]), toInt(counts["total_fields"])
		if sampled < total {
			lims = append(lims, fmt.Sprintf("field count cap fired — %d of %d fields sampled", sampled, total))
		}
	}
	return lims, errs, truncated
}

// structure builds the evidence "structure" block and the runtime version from the driver result, or the
// failure shape when the driver produced nothing usable.
func structure(driver map[string]any, stem string, truncated bool, parseJSONErr string) (map[string]any, string) {
	if driver == nil {
		pe := parseJSONErr
		if pe == "" {
			pe = "driver produced no output"
		}
		return map[string]any{
			"root_type": nil, "module": stem, "fields": []any{},
			"counts":    map[string]any{"total_fields": 0, "sampled": 0},
			"truncated": true, "parse_error": pe,
		}, "unknown"
	}
	get := func(k string, def any) any {
		if v, ok := driver[k]; ok {
			return v
		}
		return def
	}
	rv := "unknown"
	if v, ok := driver["runtime_version"].(string); ok {
		rv = v
	}
	return map[string]any{
		"root_type": get("root_type", nil), "module": get("module", nil),
		"fields":    get("fields", []any{}),
		"counts":    get("counts", map[string]any{"total_fields": 0, "sampled": 0}),
		"truncated": truncated, "parse_error": get("parse_error", nil),
	}, rv
}

// cut100 is out[:100] on characters.
func cut100(s string) string {
	if utf8.RuneCountInString(s) <= 100 {
		return s
	}
	return string([]rune(s)[:100])
}

func head500(b []byte) string {
	r := []rune(strings.ToValidUTF8(string(b), "�"))
	if len(r) > 500 {
		r = r[:500]
	}
	return string(r)
}
