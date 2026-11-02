package hookwiring

import (
	"os"
	"regexp"
	"strings"
	"unicode/utf8"
)

// The kinds of finding WiredExecReport can return.
const (
	FindingNotExecutable = "not-executable" // a script run DIRECTLY exists and lacks +x (the hook exits 126)
	FindingMissing       = "missing"        // the script path names no file
	FindingUnverifiable  = "unverifiable"   // not one of the asserted shapes, or settings.json could not be read
)

// Finding is one line of the wired-hook report. The line reads Kind<TAB>Subject<TAB>Detail:
//
//	not-executable  Subject the script path, Detail the event
//	missing         Subject the script path, Detail the event
//	unverifiable    Subject the first 60 characters of the command (or the settings path), Detail the reason
type Finding struct{ Kind, Subject, Detail string }

// String is the finding as the bash report printed it, without the newline.
func (f Finding) String() string { return f.Kind + "\t" + f.Subject + "\t" + f.Detail }

// FormatFindings is the report as the bash function printed it: one finding per line, nothing when there are none.
func FormatFindings(fs []Finding) string {
	var b strings.Builder
	for _, f := range fs {
		b.WriteString(f.String() + "\n")
	}
	return b.String()
}

func unverifiable(subject, reason string) Finding {
	return Finding{FindingUnverifiable, subject, reason}
}

// WiredExecReport is the port of hook_wired_exec_report (kit issue #2141): for every command wired under the
// top-level "hooks" key of <target>/.claude/settings.json (any event; statusLine and mcpServers commands are not
// hooks) it reports whether the script it runs exists and, when it is run directly, has the execute bit. A command
// that is not one of the asserted shapes is reported as unverifiable with a typed reason, never skipped silently: a
// bare command name that is the ENTIRE command (`true`) is the only silent shape. An absent settings.json reports
// nothing; an unreadable or invalid one is one unverifiable finding. It never touches the target.
//
// Shapes asserted (the first simple command, after expanding ${CLAUDE_PROJECT_DIR} / $CLAUDE_PROJECT_DIR to the
// target, $HOME / ${HOME} and an unquoted leading ~/ to HOME when it is set, and removing matching quotes):
//
//  1. `<path> [args...]` with a `/` in the first word: must exist AND be executable (relative: from the target);
//  2. option-free prefixes `exec|nohup|command <path>`, `timeout <N[smh]> <path>`, `NAME=value... <path>`: as 1;
//  3. `bash|sh|zsh|python|python3|node|perl <abs-path> [args...]`, also via `env <interp>`, with no option right
//     after the interpreter: must exist only.
//
// Deviation from the shell original: settings.json is always parsed natively, so the bash fallback for a machine
// without jq (a text match over every "command" key plus one unverifiable note) has no counterpart.
func WiredExecReport(e Env, target string) []Finding {
	settings := target + "/.claude/settings.json" // printed as spelled; the file tests are anchored at the cwd
	path := anchor(e, settings)
	st, serr := os.Stat(path)
	if serr != nil {
		if li, lerr := os.Lstat(path); lerr != nil || li.Mode()&os.ModeSymlink == 0 {
			return nil // absent
		}
	}
	if serr != nil || !st.Mode().IsRegular() || !accessOK(path, accR) {
		return []Finding{unverifiable(settings, "settings.json is not a readable file")}
	}
	const invalid = "settings.json is not valid JSON (or jq failed)"
	data, err := e.readFile(path)
	if err != nil {
		return []Finding{unverifiable(settings, invalid)}
	}
	entries, err := wiredCommands(data)
	if err != nil {
		return []Finding{unverifiable(settings, invalid)}
	}
	var out []Finding
	for _, line := range entryLines(entries) {
		ev, cmd := line, line // ${line%%$'\t'*} and ${line#*$'\t'} when there is no tab
		if before, after, found := strings.Cut(line, "\t"); found {
			ev, cmd = before, after
		}
		out = append(out, checkCommand(e, target, ev, cmd)...)
	}
	return out
}

var (
	durationRe   = regexp.MustCompile(`^[0-9]+[smh]?$`)
	interpreters = map[string]bool{"bash": true, "sh": true, "zsh": true, "python": true, "python3": true, "node": true, "perl": true}
)

// isSpaceClass is `[[:space:]]` of a glibc UTF-8 locale.
func isSpaceClass(r rune) bool {
	switch {
	case r >= '\t' && r <= '\r', r == ' ', r == 0x1680, r >= 0x2000 && r <= 0x2006, r >= 0x2008 && r <= 0x200a,
		r == 0x2028, r == 0x2029, r == 0x205f, r == 0x3000:
		return true
	}
	return false
}

func trimLeadingSpace(s string) string {
	for {
		// An empty s and an invalid byte both decode to U+FFFD, which is not a space, so the loop ends on them.
		r, n := utf8.DecodeRuneInString(s)
		if !isSpaceClass(r) {
			return s
		}
		s = s[n:]
	}
}

// headOf is the first 60 characters of cmd with tabs read as blanks, what the report quotes of a command it could
// not analyse. A byte that is not valid UTF-8 counts as one character, like bash in a UTF-8 locale.
func headOf(cmd string) string {
	i := 0
	for n := 0; n < 60; n++ { // past the end DecodeRuneInString consumes nothing
		_, w := utf8.DecodeRuneInString(cmd[i:])
		i += w
	}
	return strings.ReplaceAll(cmd[:i], "\t", " ")
}

func baseName(s string) string { return s[strings.LastIndexByte(s, '/')+1:] } // ${s##*/}

// isNameVal reports whether w matches `[A-Za-z_]*=*`, and, if so, whether the part before the first = is a valid
// variable name. The shell breaks out of the prefix loop for a match with a bad name.
func isNameVal(w string) (matches, valid bool) {
	if w == "" || !(w[0] == '_' || w[0] >= 'a' && w[0] <= 'z' || w[0] >= 'A' && w[0] <= 'Z') {
		return false, false
	}
	name, _, found := strings.Cut(w, "=")
	if !found {
		return false, false
	}
	for i := 0; i < len(name); i++ {
		c := name[i]
		if !(c == '_' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9') {
			return true, false
		}
	}
	return true, true
}

// checkCommand is the port of _hw_check_command: the findings for ONE wired command.
func checkCommand(e Env, target, ev, cmd string) []Finding {
	cmd = trimLeadingSpace(cmd)
	if cmd == "" {
		return nil
	}
	head := headOf(cmd)
	unv := func(reason string) []Finding { return []Finding{unverifiable(head, reason)} }
	words, op, serr := splitCommand(cmd)
	if serr != "" {
		return unv(serr)
	}
	n := len(words)
	if n == 0 {
		return unv("no command word before the first shell operator") // HW-NOWORD
	}
	word := func(i int) string {
		if i < n {
			return words[i]
		}
		return ""
	}
	i := 0
prefixes: // option-free prefixes only
	for i < n {
		w := words[i]
		if matches, valid := isNameVal(w); matches { // HW-NAMEVAL
			if !valid {
				break prefixes
			}
			i++
			continue
		}
		switch w {
		case "exec", "nohup", "command": // HW-WRAP-EXEC
			i++
			if strings.HasPrefix(word(i), "-") {
				return unv(w + " followed by an option")
			}
		case "timeout": // HW-WRAP-TIMEOUT
			if !durationRe.MatchString(word(i + 1)) {
				return unv("timeout with options or a duration that is not N[smh]")
			}
			i += 2
		default:
			break prefixes
		}
	}
	if i >= n {
		return unv("no command word after the prefix")
	}
	cw := words[i]
	viaEnv := false
	if baseName(cw) == "env" { // HW-ENV
		i++
		cw = word(i)
		viaEnv = true
		if cw == "" || strings.HasPrefix(cw, "-") || strings.Contains(cw, "=") {
			return unv("env with options or assignments, or without a command")
		}
	}
	var arg string
	interp := false
	if interpreters[baseName(strings.NewReplacer(`"`, "", `'`, "").Replace(cw))] {
		if strings.ContainsAny(cw, `"'`) { // HW-QUOTED-INTERP
			return unv("quoted interpreter word")
		}
		d := word(i + 1)
		switch {
		case d == "":
			return unv("interpreter without a script argument")
		case strings.HasPrefix(d, "-"): // HW-INTERP-OPT
			return unv("interpreter followed by an option: a payload or an option argument could be taken for the script")
		}
		interp, arg = true, d // HW-INTERP
	} else {
		if viaEnv {
			return unv("env form that does not run an interpreter script")
		}
		arg = cw
	}
	raw := arg
	switch {
	case strings.Contains(raw, "'"): // HW-SQUOTE
		if strings.ContainsAny(raw, "$~") {
			return unv("single-quoted word: the shell would not expand it")
		}
	case strings.HasPrefix(raw, `"~`): // HW-DQ-TILDE
		return unv("~ inside double quotes: the shell would not expand it")
	}
	arg = strings.NewReplacer(`"`, "", `'`, "").Replace(raw)
	home := e.getenv(envHome)
	switch {
	case strings.HasPrefix(arg, "${CLAUDE_PROJECT_DIR}/"):
		arg = target + "/" + strings.TrimPrefix(arg, "${CLAUDE_PROJECT_DIR}/")
	case strings.HasPrefix(arg, "$CLAUDE_PROJECT_DIR/"):
		arg = target + "/" + strings.TrimPrefix(arg, "$CLAUDE_PROJECT_DIR/")
	case strings.HasPrefix(arg, "${HOME}/"): // HW-HOME-BRACE
		if home != "" {
			arg = home + "/" + strings.TrimPrefix(arg, "${HOME}/")
		}
	case strings.HasPrefix(arg, "$HOME/"): // HW-HOME-PLAIN
		if home != "" {
			arg = home + "/" + strings.TrimPrefix(arg, "$HOME/")
		}
	case strings.HasPrefix(arg, "~/"): // HW-HOME-TILDE
		if home != "" {
			arg = home + "/" + strings.TrimPrefix(arg, "~/")
		}
	}
	switch {
	case strings.ContainsAny(arg, "$`*?["): // HW-VARGLOB
		return unv("unresolved variable, glob or substitution in the command path")
	case strings.HasPrefix(arg, "~"):
		return unv("~ form that cannot be expanded here")
	}
	if interp {
		if !strings.HasPrefix(arg, "/") { // HW-INTERP-ABS
			return unv("relative script path for an interpreter (resolved against the launch directory)")
		}
	} else {
		if !strings.Contains(arg, "/") {
			if n == 1 && i == 0 && !op { // HW-BARE-ALONE: `true` alone makes no claim
				return nil
			}
			return unv("bare command name with arguments, a prefix or a command chain (cd ...; a path command after an operator): not analysed") // HW-CHAIN
		}
		if !strings.HasPrefix(arg, "/") {
			arg = target + "/" + arg
		}
	}
	abs := anchor(e, arg)
	st, err := os.Stat(abs)
	switch {
	case err == nil && st.IsDir(): // HW-DIRSKIP
		return nil
	case err == nil:
		if !interp && !accessOK(abs, accX) { // WIRED-EXEC-BIT-TEST
			return []Finding{{FindingNotExecutable, arg, ev}}
		}
		return nil
	}
	return []Finding{{FindingMissing, arg, ev}} // absent, or a dangling symlink
}
