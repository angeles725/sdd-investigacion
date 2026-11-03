package verify

import (
	"io"
	"os"
)

// File helpers of verify-block: `[ -e ]`, the one line counter (VB-LINECOUNT) and a readability probe.

// exists is `[ -e p ]`, symlinks followed.
func (v fsView) exists(p string) bool {
	_, err := v.Stat(p)
	return err == nil
}

// vbLines is _vb_lines FILE [END]: the number of awk records of the file (an unterminated last line counts, CR is
// not a terminator), reading no further than line END when END > 0 (then END is printed once the file reaches it).
// ok is false where the counter fails (an unreadable file): a typed DEGRADED for the caller, never a verdict.
func (v fsView) vbLines(p string, end int64) (n int64, ok bool) {
	f, err := os.Open(v.At(p))
	if err != nil {
		return 0, false
	}
	defer f.Close()
	buf := make([]byte, 64*1024)
	var last byte = '\n'
	for {
		m, err := f.Read(buf)
		for _, c := range buf[:m] {
			if last == '\n' {
				n++ // a new record begins
				if end > 0 && n >= end {
					return n, true
				}
			}
			last = c
		}
		if err == io.EOF {
			return n, true
		}
		if err != nil {
			return 0, false
		}
	}
}

// readableFile is the `[ -r p ]` half of an absolute extern cite: the file can be opened for reading.
func (v fsView) readableFile(p string) bool { return v.Readable(p) }
