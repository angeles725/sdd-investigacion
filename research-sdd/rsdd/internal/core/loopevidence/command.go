package loopevidence

import (
	"regexp"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/shellx"
)

// runsStatus reports whether a shell command line RUNS the status instrument as a loop step: some simple command
// whose program is research-sdd-status.sh or `rsdd status`, behind any env assignments and the usual wrappers, with
// --next or --emit-token among its arguments. Mentioning the script (grep, cat, echo, a commit message) is not
// running it. With a target, a run whose absolute-path arguments all name other corpora is another target's loop.
func runsStatus(cmd, target string) bool { return runsStatusAt(cmd, target, 0) }

const maxShellDepth = 3 // bash -c 'bash -c ...' nesting that is still followed

var reAssign = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*=`)

func runsStatusAt(cmd, target string, depth int) bool {
	for _, seg := range commandSegments(cmd) {
		if segmentRunsStatus(seg, target, depth) {
			return true
		}
	}
	return false
}

// commandSegments splits a command line into the word lists of its simple commands: quotes are removed, a
// backslash takes the next byte literally, and an unquoted ; & | ( ) or newline ends the command.
func commandSegments(s string) [][]string {
	var segs [][]string
	var words []string
	var w []byte
	has := false
	endWord := func() {
		if has {
			words = append(words, string(w))
		}
		w, has = nil, false
	}
	endSeg := func() {
		endWord()
		if len(words) > 0 {
			segs = append(segs, words)
		}
		words = nil
	}
	var q byte
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case q != 0:
			if c == q {
				q = 0
			} else if c == '\\' && q == '"' && i+1 < len(s) {
				i++
				w = append(w, s[i])
			} else {
				w = append(w, c)
			}
		case c == '\'' || c == '"':
			q, has = c, true
		case c == '\\' && i+1 < len(s):
			i++
			w, has = append(w, s[i]), true
		case strings.IndexByte(" \t", c) >= 0:
			endWord()
		case strings.IndexByte(";&|()\n", c) >= 0:
			endSeg()
		default:
			w, has = append(w, c), true
		}
	}
	endSeg()
	return segs
}

var shells = map[string]bool{"bash": true, "sh": true, "zsh": true, "dash": true}

// wrappers run the next word as a command; timeout also takes a duration, kit-run.sh the script path.
var wrappers = map[string]bool{"env": true, "command": true, "exec": true, "time": true, "nohup": true, "nice": true, "timeout": true, "kit-run.sh": true}

func segmentRunsStatus(words []string, target string, depth int) bool {
	for len(words) > 0 && reAssign.MatchString(words[0]) {
		words = words[1:]
	}
	for len(words) > 0 {
		base := shellx.BaseName(words[0])
		switch {
		case wrappers[base]:
			words = skipOptions(words[1:], base == "timeout")
		case shells[base]:
			rest := words[1:]
			for len(rest) > 0 && strings.HasPrefix(rest[0], "-") {
				if isCommandFlag(rest[0]) && len(rest) > 1 { // bash -c '<command line>'
					return depth < maxShellDepth && runsStatusAt(rest[1], target, depth+1)
				}
				rest = rest[1:]
			}
			words = rest // bash <script> <args...>: the script is the program
		default:
			return statusArgs(base, words, target)
		}
		for len(words) > 0 && reAssign.MatchString(words[0]) {
			words = words[1:]
		}
	}
	return false
}

// isCommandFlag: -c, or a cluster of short options ending in c (-lc, -ec).
func isCommandFlag(w string) bool {
	return len(w) >= 2 && w[0] == '-' && w[1] != '-' && strings.HasSuffix(w, "c") && strings.Trim(w[1:], "abcdefhilmnpstuvxBCEHPT") == ""
}

// skipOptions drops the option words of a wrapper (and timeout's duration), stopping at the wrapped command.
func skipOptions(words []string, duration bool) []string {
	for len(words) > 0 && (strings.HasPrefix(words[0], "-") || reAssign.MatchString(words[0])) {
		words = words[1:]
	}
	if duration && len(words) > 0 {
		words = words[1:]
	}
	return words
}

// statusArgs decides on the program word and its arguments: the instrument, a loop-step flag, a related target.
func statusArgs(base string, words []string, target string) bool {
	var args []string
	switch {
	case base == "research-sdd-status.sh":
		args = words[1:]
	case base == "rsdd" && len(words) > 1 && words[1] == "status":
		args = words[2:]
	default:
		return false
	}
	loopStep := false
	var dirs []string
	for _, a := range args {
		switch {
		case a == "--next" || a == "--emit-token":
			loopStep = true
		case strings.HasPrefix(a, "/"):
			dirs = append(dirs, a)
		}
	}
	if !loopStep {
		return false
	}
	if target == "" || len(dirs) == 0 { // no absolute directory named: relative or a variable, which cannot be told apart
		return true
	}
	for _, d := range dirs {
		if related(d, target) {
			return true
		}
	}
	return false
}
