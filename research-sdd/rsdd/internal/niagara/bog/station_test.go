package bog

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/niagara/bogtest"
)

// Handle.SHA256 is the evidence hash of the whole file, whatever part of it a tool reads.
func TestHandleSHA256CoversTheWholeFile(t *testing.T) {
	for name, content := range map[string][]byte{
		"empty": nil, "small": []byte("<a/>"), "past one read chunk": []byte(strings.Repeat("x", 3*65536+7)),
	} {
		t.Run(name, func(t *testing.T) {
			p := filepath.Join(t.TempDir(), "f.bog")
			if err := os.WriteFile(p, content, 0o600); err != nil {
				t.Fatal(err)
			}
			h, err := Open(p)
			if err != nil {
				t.Fatal(err)
			}
			defer h.Close()
			if _, err := h.Head(3); err != nil { // a partial read first: the digest must not depend on the offset
				t.Fatal(err)
			}
			got, err := h.SHA256()
			sum := sha256.Sum256(content)
			if err != nil || got != hex.EncodeToString(sum[:]) {
				t.Errorf("SHA256 = %q, %v; want %x", got, err, sum)
			}
		})
	}
}

// Zip.ExtractFile gives the answer Extract gives for the same bytes.
func TestZipExtractFileMatchesExtract(t *testing.T) {
	cases := map[string][]byte{
		"file.xml":     bogtest.Bog("<a>é</a>"),
		"suffix match": bogtest.Zip(bogtest.Entry{Name: "dir/file.xml", Data: []byte("<b/>")}),
		"exact beats suffix": bogtest.Zip(bogtest.Entry{Name: "a/file.xml", Data: []byte("<no/>")},
			bogtest.Entry{Name: "file.xml", Data: []byte("<yes/>")}),
		"no file.xml":  bogtest.Zip(bogtest.Entry{Name: "other.xml", Data: []byte("<c/>")}),
		"over the cap": bogtest.Bomb(64),
		"corrupt":      bogtest.CorruptDeflate(),
		"crc":          bogtest.CRCMismatch(),
		"encrypted":    bogtest.Encrypted(),
		"method 99":    bogtest.Method99(),
	}
	for name, data := range cases {
		t.Run(name, func(t *testing.T) {
			z, err := OpenZip(data)
			if err != nil {
				t.Fatal(err)
			}
			got := z.ExtractFile(64)
			want := Extract(data, 64)
			if got != want {
				t.Errorf("ExtractFile = %+v, Extract = %+v", got, want)
			}
		})
	}
}
