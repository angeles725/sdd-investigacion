package floss

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"math"
	"math/big"
	"sort"
	"strconv"
	"unicode/utf8"
)

// categories are the string categories `floss -j` emits, in canonical order.
var categories = []string{"static_strings", "stack_strings", "tight_strings", "decoded_strings"}

// invCaps are the two inventory caps. The int64 values drive the logic (a larger Python int behaves as
// "never fires" here too); the texts are what the limitations and the evidence print, so a cap above int64 is
// reported exactly as given.
type invCaps struct {
	MaxStrings, MaxStringLen         int64
	MaxStringsText, MaxStringLenText string
}

func newInvCaps(maxStrings, maxStringLen int64) invCaps {
	return invCaps{maxStrings, maxStringLen, strconv.FormatInt(maxStrings, 10), strconv.FormatInt(maxStringLen, 10)}
}

// newInvCapsText builds the caps from decimal texts of any magnitude.
func newInvCapsText(maxStrings, maxStringLen string) invCaps {
	return invCaps{clampInt(maxStrings), clampInt(maxStringLen), maxStrings, maxStringLen}
}

func clampInt(text string) int64 {
	n, ok := new(big.Int).SetString(text, 10)
	switch {
	case !ok || !n.IsInt64():
		if ok && n.Sign() < 0 {
			return math.MinInt64
		}
		return math.MaxInt64
	}
	return n.Int64()
}

// shapeError is a floss document whose structure the Python script would have crashed on or handled in a way
// this port does not reproduce (see buildInventory).
type shapeError struct{ msg string }

func (e *shapeError) Error() string { return e.msg }

func shapeErr(format string, v ...any) error {
	return &shapeError{"unsupported floss JSON shape: " + fmt.Sprintf(format, v...)}
}

type rawString struct {
	offset   json.Number
	rank     *big.Rat
	value    string
	encoding any
}

// buildInventory is _build_inventory: the bounded string inventory of a parsed floss document (nil = floss
// printed nothing) and the limitations the caps that fired add.
//
// Caps: the total number of sampled strings (when the budget is spent and one more string is waiting, no
// further string is sampled and truncated is set) and the length of each value in code points (longer values
// are cut and truncated is set). Strings are sorted by (offset, value) inside each category, so the same
// binary, floss version and caps give the same output.
//
// Accepted shape: an object whose "strings" member is an object whose categories are arrays of objects with
// an optional string "string", an optional numeric "offset" and any "encoding". Anything else is a
// *shapeError (the Python script crashes with a traceback on most of it; the port refuses explicitly).
func buildInventory(floss any, c invCaps) (map[string]any, []string, error) {
	var block map[string]any
	if floss != nil {
		root, ok := floss.(map[string]any)
		if !ok {
			return nil, nil, shapeErr("top level is %s, not an object", jsonKind(floss))
		}
		if raw, present := root["strings"]; present {
			if block, ok = raw.(map[string]any); !ok {
				return nil, nil, shapeErr(`"strings" is %s, not an object`, jsonKind(raw))
			}
		}
	}
	remaining := c.MaxStrings
	stringCapHit, lengthCapHit := false, false
	inv := map[string]any{}
	totalCount, totalSampled := 0, 0
	for _, cat := range categories {
		entries, err := categoryEntries(block, cat)
		if err != nil {
			return nil, nil, err
		}
		sort.SliceStable(entries, func(i, j int) bool {
			if k := entries[i].rank.Cmp(entries[j].rank); k != 0 {
				return k < 0
			}
			return entries[i].value < entries[j].value
		})
		sampled := []map[string]any{}
		for _, e := range entries {
			if stringCapHit || remaining <= 0 {
				stringCapHit = true
				break
			}
			val := e.value
			if int64(utf8.RuneCountInString(val)) > c.MaxStringLen {
				val = string([]rune(val)[:c.MaxStringLen])
				lengthCapHit = true
			}
			sum := sha256.Sum256([]byte(val))
			sampled = append(sampled, map[string]any{
				"encoding": e.encoding,
				"offset":   e.offset,
				"sha256":   "sha256:" + hex.EncodeToString(sum[:]),
				"value":    val,
			})
			remaining--
		}
		inv[cat] = map[string]any{"count": len(entries), "sampled": len(sampled), "strings": sampled, "truncated": len(entries) > len(sampled)}
		totalCount += len(entries)
		totalSampled += len(sampled)
	}
	inv["total_count"], inv["total_sampled"] = totalCount, totalSampled
	inv["truncated"] = stringCapHit || lengthCapHit
	var limitations []string
	if stringCapHit {
		limitations = append(limitations, "inventory truncated: string cap "+c.MaxStringsText+" reached")
	}
	if lengthCapHit {
		limitations = append(limitations, "inventory truncated: string-length cap "+c.MaxStringLenText+" reached")
	}
	return inv, limitations, nil
}

// categoryEntries reads one category of the strings block (an absent category is empty).
func categoryEntries(block map[string]any, cat string) ([]rawString, error) {
	raw, present := block[cat]
	if !present {
		return nil, nil
	}
	list, ok := raw.([]any)
	if !ok {
		return nil, shapeErr("%s is %s, not an array", cat, jsonKind(raw))
	}
	out := make([]rawString, 0, len(list))
	for i, item := range list {
		obj, ok := item.(map[string]any)
		if !ok {
			return nil, shapeErr("%s[%d] is %s, not an object", cat, i, jsonKind(item))
		}
		e := rawString{offset: json.Number("0"), rank: new(big.Rat)}
		if v, present := obj["string"]; present {
			if e.value, ok = v.(string); !ok {
				return nil, shapeErr(`%s[%d]."string" is %s, not a string`, cat, i, jsonKind(v))
			}
		}
		if v, present := obj["offset"]; present {
			n, ok := v.(json.Number)
			if !ok {
				return nil, shapeErr(`%s[%d]."offset" is %s, not a number`, cat, i, jsonKind(v))
			}
			rank, ok := numberRank(n)
			if !ok {
				return nil, shapeErr(`%s[%d]."offset" is not a finite number`, cat, i)
			}
			e.offset, e.rank = n, rank
		}
		e.encoding = obj["encoding"]
		out = append(out, e)
	}
	return out, nil
}

// numberRank is the exact value Python compares: an int as itself, a float after rounding to a double.
func numberRank(n json.Number) (*big.Rat, bool) {
	if i, ok := new(big.Int).SetString(string(n), 10); ok {
		return new(big.Rat).SetInt(i), true
	}
	f, err := strconv.ParseFloat(string(n), 64)
	if err != nil || math.IsInf(f, 0) || math.IsNaN(f) {
		return nil, false
	}
	return new(big.Rat).SetFloat64(f), true
}

func jsonKind(v any) string {
	switch v.(type) {
	case nil:
		return "null"
	case bool:
		return "a boolean"
	case string:
		return "a string"
	case json.Number, float64:
		return "a number"
	case []any:
		return "an array"
	case map[string]any:
		return "an object"
	}
	return fmt.Sprintf("%T", v)
}
