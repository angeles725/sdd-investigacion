package hook

import (
	"io"
	"os"
	"regexp"
	"strings"
)

var (
	hasCdRe   = regexp.MustCompile(`(^|[ \t;&|(])cd[ \t]`)
	shellCRe  = regexp.MustCompile(`^-[a-zA-Z]*c$`)
	resultOK  = "ok"
	resultMis = "miss"
	resultUnv = "unver"
)

// scriptScan is the state of the awk program behind hook_stop_script_state_var.
// Positions passed around are 1-based like awk's, so the arithmetic below can be
// compared line by line with the original.
type scriptScan struct {
	tgt, home string
	sawEntry  bool // only ever compared with zero in the awk original
	ok        int
	unver     int
}

func at(s string, k int) byte { return s[k-1] }

// escAt reports whether the character at 1-based k is preceded by an odd run of backslashes.
func escAt(s string, k int) bool {
	b := 0
	for k > 1 && at(s, k-1) == '\\' {
		b++
		k--
	}
	return b%2 == 1
}

func pfx(s, pat string) bool { return strings.HasPrefix(s, pat+"/") }

// canOpen is awk's `(getline ln < path) >= 0`: the file opens and its first read does not fail.
// A directory fails (gawk reports -1 for it).
func canOpen(path string) bool {
	f, err := os.Open(path)
	if err != nil {
		return false
	}
	defer f.Close()
	if st, err := f.Stat(); err != nil || st.IsDir() {
		return false
	}
	var one [1]byte
	if _, err := f.Read(one[:]); err != nil && err != io.EOF {
		return false
	}
	return true
}

// resolve classifies one word of the command that mentions retro-gate: "ok" (the script can be
// opened), "miss" (resolved unambiguously to a path that cannot) or "unver" (could not be resolved).
// "miss" is a firm claim, emitted only when the path was resolved unambiguously.
func (sc *scriptScan) resolve(w string, hascd bool, widx int, prev string) string {
	tok := w
	if strings.Contains(tok, "'") && strings.ContainsAny(tok, "$~") {
		return resultUnv // single-quoted: the shell would not expand it
	}
	if shellCRe.MatchString(prev) {
		return resultUnv // a shell -c payload: the shell re-parses it
	}
	tok = strings.NewReplacer(`"`, "", `'`, "").Replace(tok)
	if strings.HasPrefix(tok, "-") {
		return resultUnv // an option (--cfg=/x/retro-gate.json), not a script path
	}
	if strings.Contains(w, `"`) && strings.HasPrefix(tok, "~") {
		return resultUnv // no tilde expansion inside double quotes
	}
	switch {
	case pfx(tok, "${CLAUDE_PROJECT_DIR}"):
		tok = sc.tgt + tok[len("${CLAUDE_PROJECT_DIR}"):]
	case pfx(tok, "$CLAUDE_PROJECT_DIR"):
		tok = sc.tgt + tok[len("$CLAUDE_PROJECT_DIR"):]
	case sc.home != "" && pfx(tok, "${HOME}"):
		tok = sc.home + tok[len("${HOME}"):]
	case sc.home != "" && pfx(tok, "$HOME"):
		tok = sc.home + tok[len("$HOME"):]
	case sc.home != "" && strings.HasPrefix(tok, "~/"):
		tok = sc.home + tok[1:]
	}
	slash := strings.IndexByte(tok, '/')
	if strings.ContainsAny(tok, "$`*?\\") || strings.HasPrefix(tok, "~") || slash < 0 {
		return resultUnv
	}
	if strings.ContainsRune(tok[:slash], ':') {
		return resultUnv // scheme or drive prefix (C:/x), not a local path
	}
	if !strings.HasPrefix(tok, "/") {
		if hascd {
			return resultUnv // relative to a directory the command itself changed
		}
		if widx > 2 {
			return resultUnv // a relative word past the command/interpreter slots may be a fragment or an argument
		}
		tok = sc.tgt + "/" + tok
	}
	if canOpen(tok) {
		return resultOK
	}
	return resultMis
}

// check classifies every retro-gate word of the JSON string that contains the 1-based pos. It
// returns the 1-based index of the closing quote (so the scanner can skip the string), or 0.
func (sc *scriptScan) check(line string, pos int) int {
	s := 0
	for k := pos; k >= 1; k-- { // at pos is the 'r' of retro-gate, never a quote
		if at(line, k) == '"' && !escAt(line, k) {
			s = k
			break
		}
	}
	e := 0
	for k := pos + 10; k <= len(line); k++ {
		if at(line, k) == '"' && !escAt(line, k) {
			e = k
			break
		}
	}
	sc.sawEntry = true
	if s == 0 || e == 0 {
		sc.unver++
		return 0
	}
	cmd := strings.ReplaceAll(line[s:e-1], `\"`, `"`)
	hascd := hasCdRe.MatchString(cmd)
	// quote-aware split: whitespace inside a quoted span does not end a word
	n := len(cmd)
	var res []string
	var q byte
	w, prev := "", ""
	widx := 0
	for k := 1; k <= n+1; k++ {
		c := byte(' ')
		if k <= n {
			c = at(cmd, k)
		}
		if q == 0 && (c == ' ' || c == '\t') {
			if w != "" {
				widx++
			}
			if w != "" && strings.Contains(w, "retro-gate") {
				res = append(res, sc.resolve(w, hascd, widx, prev))
			}
			if w != "" {
				prev = w
			}
			w = ""
			continue
		}
		if q == 0 && (c == '"' || c == '\'') {
			q = c
		} else if q != 0 && c == q {
			q = 0
		}
		w += string(c)
	}
	if q != 0 { // unterminated quote: the command could not be split reliably
		sc.unver++
		return e
	}
	// res is never empty here: "retro-gate" contains no whitespace, so it sits whole inside one word
	// and the final flush above resolves it (an unterminated quote returned earlier).
	for _, r := range res {
		switch r {
		case resultOK:
			sc.ok++
		case resultMis:
			// firmly absent: only a verdict with no ok and no unver is "missing", so nothing to count
		default:
			sc.unver++
		}
	}
	return e
}

// ScriptState is the port of hook_stop_script_state_var: does a Stop-scoped retro-gate command
// of <target>/.claude/settings.json name a script that exists?
//
//	present       at least one such command names a script that can be opened
//	missing       every such command resolved unambiguously to a path that cannot be opened
//	unverifiable  nothing was confirmed present and at least one command could not be resolved
//	no-entry      settings.json is absent or unreadable, or its Stop block has no retro-gate command
//	degraded      the settings.json read failed: the measurement is invalid, not a zero
//
// Resolved forms are only those documented in lib/hook-wiring.sh; every other shape is
// unverifiable. One deliberate difference from the awk it replaces: the target and $HOME reach
// awk through `-v`, which interprets backslash escapes, so a path containing a backslash was
// silently altered there; here it is taken as written.
func ScriptState(e Env, target string) string {
	settings := settingsOf(e, target)
	if !exists(settings) || !readable(settings) {
		return ScriptNoEntry
	}
	data, err := readSettings(e, settings)
	if err != nil {
		return ScriptDegraded
	}
	sc := &scriptScan{tgt: AbsPath(e.Cwd, target), home: e.getenv(envHome)}
	walkStop(data, func(line string, i int) int {
		if end := sc.check(line, i+1); end != 0 { // a closing quote lies past the word
			return end - 1
		}
		return i
	})
	switch {
	case !sc.sawEntry:
		return ScriptNoEntry
	case sc.ok > 0:
		return ScriptPresent
	case sc.unver > 0:
		return ScriptUnverifiable
	default:
		return ScriptMissing
	}
}
