package srcregistry

import (
	"os"
	"path/filepath"
	"testing"
)

// FileSHA256 streams the file itself, so it needs no platform file identity (fsx.Identity is Linux-only).
func TestFileSHA256StreamsLargeAndEmptyFilesAndRefusesNonRegular(t *testing.T) {
	d := t.TempDir()
	big := make([]byte, 3<<20+17)
	for i := range big {
		big[i] = byte(i * 7)
	}
	for name, body := range map[string][]byte{"big": big, "empty": nil} {
		p := filepath.Join(d, name)
		if err := os.WriteFile(p, body, 0o644); err != nil {
			t.Fatal(err)
		}
		if got, err := FileSHA256(p); err != nil || got != SHA256Hex(body) {
			t.Errorf("%s: %q, %v", name, got, err)
		}
	}
	if _, err := FileSHA256(d); err == nil {
		t.Error("a directory was hashed")
	}
	if _, err := FileSHA256(filepath.Join(d, "big", "no")); err == nil {
		t.Error("a path under a file was hashed")
	}
}
