package fetchdoc

import (
	"fmt"
	"strings"
)

// Usage lines, from the legacy script header (the script name is part of the output contract).
const (
	usageGeneral = "usage: fetch-doc.sh [--replace] doc|web|ocr ..."
	usageDoc     = "usage: fetch-doc.sh doc <url> <target-dir> [datasheets|manuals] [name]"
	usageWeb     = "usage: fetch-doc.sh web <url> <target-dir>"
	usageOCR     = "usage: fetch-doc.sh ocr <pdf>"
)

// Exit codes of the contract: 1 failure, 2 usage, 3 missing dependency, 4 destination exists, 5 symlinked
// destination (4 and 5 are the place package's).
const (
	exitFailure = 1
	exitUsage   = 2
	exitMissing = 3
)

// request is the parsed command line. --replace may appear anywhere and is removed; every other word is
// positional (a word that looks like an option is still a positional: an unknown MODE is exit 2).
type request struct {
	replace bool
	mode    string
	pos     []string
}

func parse(args []string) request {
	var r request
	var rest []string
	for _, a := range args {
		if a == "--replace" {
			r.replace = true
		} else {
			rest = append(rest, a)
		}
	}
	if len(rest) > 0 {
		r.mode, r.pos = rest[0], rest[1:]
	}
	return r
}

// usageError is the exit-2 message: a reason, then the usage line of the mode.
func (x *exe) usageError(usage, format string, a ...any) int {
	fmt.Fprintf(x.d.Err, "fetch-doc: "+format+"\n%s\n", append(a, usage)...)
	return exitUsage
}

// arg is positional argument i, or "" when absent (an empty word counts as absent, as `${n:?}` and `${n:-}` do).
func (r request) arg(i int) string {
	if i < len(r.pos) {
		return r.pos[i]
	}
	return ""
}

// badChars reports why s cannot be part of a SOURCES.md cell or a file name: a "|" would shift the row's
// columns, a control character (newline included) would split the row.
func badChars(s string) string {
	for _, c := range s {
		switch {
		case c == '|':
			return `a "|" would shift the SOURCES.md columns`
		case c < 0x20 || c == 0x7f:
			return "control characters are not allowed"
		}
	}
	return ""
}

// checkURL refuses what cannot be a URL argument: an option-looking word (curl would read it as a flag, e.g.
// --config) and control characters.
func checkURL(url string) string {
	if strings.HasPrefix(url, "-") {
		return "a URL must not start with \"-\" (curl would read it as an option)"
	}
	for _, c := range url {
		if c < 0x20 || c == 0x7f {
			return "control characters are not allowed in a URL"
		}
	}
	return ""
}

// checkSub refuses a sub-directory that could leave TARGET/sources or break the registry: absolute, a ".."
// segment, or characters from badChars. Nested names ("datasheets/vendor") stay allowed.
func checkSub(sub string) string {
	if strings.HasPrefix(sub, "/") {
		return "the sub-directory must be relative to TARGET/sources"
	}
	for _, seg := range strings.Split(sub, "/") {
		if seg == ".." {
			return `the sub-directory must not contain ".."`
		}
	}
	return badChars(sub)
}

// checkName refuses a file name that is not one plain name: empty, ".", "..", or holding a "/".
func checkName(name string) string {
	switch {
	case name == "" || name == "." || name == "..":
		return fmt.Sprintf("%q is not a usable file name; give one as the last argument", name)
	case strings.Contains(name, "/"):
		return "the file name must not contain \"/\""
	}
	return badChars(name)
}

// baseName is basename(1) of the URL without its query string: trailing slashes dropped, then the text after the
// last slash.
func baseName(url string) string {
	if i := strings.Index(url, "?"); i >= 0 {
		url = url[:i]
	}
	url = strings.TrimRight(url, "/")
	if i := strings.LastIndex(url, "/"); i >= 0 {
		url = url[i+1:]
	}
	return url
}
