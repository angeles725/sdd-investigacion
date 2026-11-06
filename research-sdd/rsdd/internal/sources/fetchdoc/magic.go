package fetchdoc

import (
	"bytes"
	"io"
	"os"
)

// hasPDFMagic reports a file that starts with "%PDF-" (file(1)'s own rule for a PDF), within the first KiB as
// the PDF specification allows.
func hasPDFMagic(path string) bool {
	f, err := os.Open(path)
	if err != nil {
		return false
	}
	defer f.Close()
	buf := make([]byte, 1024)
	n, _ := io.ReadFull(f, buf)
	return bytes.Contains(buf[:n], []byte("%PDF-"))
}
