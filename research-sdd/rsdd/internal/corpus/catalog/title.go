package catalog

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"
	"unicode/utf8"
)

// blockTitle returns the title of a block file: the capture of titleRE on the first line that starts with "# ",
// else that line without the marker and trimmed, else "(untitled)". Lines end at \n, \r or \r\n, as in Python's
// text mode. A line that is not valid UTF-8 fails the read.
func blockTitle(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	r := bufio.NewReader(f)
	for {
		line, more, err := readLine(r)
		if err != nil {
			return "", fmt.Errorf("%s: %w", path, err)
		}
		if strings.HasPrefix(line, "# ") {
			if m := titleRE.FindStringSubmatch(line); m != nil {
				return m[1], nil
			}
			return strings.TrimFunc(line[2:], isPySpace), nil
		}
		if !more {
			return "(untitled)", nil
		}
	}
}

var errInvalidUTF8 = errors.New("file is not valid UTF-8")

// readLine reads one line without its terminator. more is false when the line was the last one (end of file).
func readLine(r *bufio.Reader) (line string, more bool, err error) {
	var buf []byte
	for {
		c, err := r.ReadByte()
		if err == io.EOF {
			return finish(buf, false)
		}
		if err != nil {
			return "", false, err
		}
		if c == '\r' {
			if next, perr := r.Peek(1); perr == nil && next[0] == '\n' {
				_, _ = r.ReadByte()
			}
			c = '\n'
		}
		if c == '\n' {
			return finish(buf, true)
		}
		buf = append(buf, c)
	}
}

func finish(buf []byte, more bool) (string, bool, error) {
	if !utf8.Valid(buf) {
		return "", false, errInvalidUTF8
	}
	return string(buf), more, nil
}
