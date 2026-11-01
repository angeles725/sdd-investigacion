package formats

import (
	"crypto/sha256"
	"encoding/hex"
	"path/filepath"
	"testing"
)

// abs makes a package-relative testdata path absolute: a command resolves relative paths against Stdio.Cwd.
func abs(t *testing.T, p string) string {
	t.Helper()
	a, err := filepath.Abs(p)
	if err != nil {
		t.Fatal(err)
	}
	return a
}

func sha256Hex(b []byte) string {
	h := sha256.Sum256(b)
	return hex.EncodeToString(h[:])
}

// obj and arr read a decoded JSON value without panicking, so a missing document fails an assertion
// with a message instead of crashing the whole test binary.
func obj(v any) map[string]any {
	m, _ := v.(map[string]any)
	if m == nil {
		m = map[string]any{}
	}
	return m
}

func arr(v any) []any {
	a, _ := v.([]any)
	return a
}
