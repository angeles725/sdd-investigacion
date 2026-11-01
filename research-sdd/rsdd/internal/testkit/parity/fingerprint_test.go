package parity

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"
)

// A file of exactly maxHashSize bytes is still content-hashed: rewriting one
// byte with size and mtime kept the same changes the fingerprint.
func TestFingerprintHashesAtTheSizeLimit(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "edge")
	b := make([]byte, maxHashSize)
	if err := os.WriteFile(p, b, 0o644); err != nil {
		t.Fatal(err)
	}
	mt := time.Unix(1700000000, 0)
	if err := os.Chtimes(p, mt, mt); err != nil {
		t.Fatal(err)
	}
	before, err := Fingerprint(dir)
	if err != nil {
		t.Fatal(err)
	}
	b[len(b)/2] = 1
	if err := os.WriteFile(p, b, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(p, mt, mt); err != nil {
		t.Fatal(err)
	}
	after, err := Fingerprint(dir)
	if err != nil {
		t.Fatal(err)
	}
	if reflect.DeepEqual(before, after) {
		t.Fatal("a same-size, same-mtime content change at maxHashSize was not detected")
	}
}
