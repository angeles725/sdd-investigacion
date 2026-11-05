package kitmaint

import (
	"strconv"
	"strings"
)

// AllDigits is the negation of `*[!0-9]*`: true for "" too, so callers test emptiness themselves.
func AllDigits(s string) bool { return strings.Trim(s, "0123456789") == "" }

// IsHex is true for a non-empty string of hex digits.
func IsHex(s string) bool { return s != "" && strings.Trim(s, "0123456789abcdefABCDEF") == "" }

// IntOr is the bound of `[ n -lt $VAR ]` and the factor of `$(( ${VAR:-def} * n ))`: "" takes def, a value that is
// not an integer reads as 0 (the loop bound fails at once, the sleep is none).
func IntOr(v string, def int) int {
	if v == "" {
		return def
	}
	n, err := strconv.Atoi(strings.TrimSpace(v))
	if err != nil {
		return 0
	}
	return n
}
