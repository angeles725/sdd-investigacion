package verify

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"regexp"
	"sort"
	"strings"
)

// Port of the P8 section of verify-state.sh (kit issue #991): hook scripts that still carry template
// placeholders. The inspected set is the union of the hook commands of .claude/settings.json and
// .claude/settings.local.json and every file or symlink directly under .claude/hooks/. Everything is read
// through the target root's containment check; nothing a command string names is ever executed.
//
// Differences from the bash, by design: the settings are parsed in process (the bash shells out to jq, so its
// "jq not found" degraded report cannot occur) and the command strings are tokenised in process (the bash
// pipes them through xargs); realpath is always "present" (the bash degrades to a textual walk without it).

// hookSet runs the scan once per target and writes its report lines to w.
func hookSet(w io.Writer, fsx fsView, target string) {
	hroot := target
	if !fsx.isDir(hroot+"/.claude") && fsx.isDir(dirname(hroot)+"/.claude") {
		hroot = dirname(hroot)
	}
	rootOK := true
	if canon, ok := fsx.canonDir(hroot); ok {
		hroot = canon
	} else {
		rootOK = false
		fmt.Fprintf(w, "   degraded   hook-set: cannot canonicalize target root (%s) — every candidate hook is refused, never read\n", hroot)
	}
	hdir := hroot + "/.claude/hooks"

	var combined []string // safe, in-root, existing file paths (pre-dedup)
	var srcReport []string
	anySeen, anyRejected := false, false

	for _, pair := range [][2]string{{hroot + "/.claude/settings.json", "settings.json"}, {hroot + "/.claude/settings.local.json", "settings.local.json"}} {
		spath, label := pair[0], pair[1]
		if !fsx.isFile(spath) {
			continue
		}
		anySeen = true
		raw, err := fsx.read(spath)
		if err != nil {
			fmt.Fprintf(w, "   unreadable   hook-set: %s at %s is not readable — cannot derive its hook commands\n", label, hroot)
			anyRejected = true
			continue
		}
		cmds, err := settingsCommands(raw)
		if err != nil {
			fmt.Fprintf(w, "   malformed   hook-set: %s at %s is not valid JSON — cannot derive its hook commands\n", label, hroot)
			anyRejected = true
			continue
		}
		if cmds == "" {
			continue
		}
		srcN := 0
		for _, cmd := range strings.Split(cmds, "\n") {
			if cmd == "" {
				continue
			}
			tok := firstPathToken(cmd)
			resolved := ""
			if tok != "" {
				resolved = resolveHookPath(tok, hroot)
			}
			if resolved == "" || !fsx.isFile(resolved) {
				fmt.Fprintf(w, "   WARN   hook-set: %s hook command could not be resolved to a script file (inspected: %s): %s\n", label, hroot, cmd)
				anyRejected = true
				continue
			}
			if !rootOK {
				fmt.Fprintf(w, "   WARN   hook-set: %s hook command refused — target root could not be canonicalized (inspected: %s): %s\n", label, hroot, resolved)
				anyRejected = true
				continue
			}
			res := rootCheck(fsx, resolved, hroot)
			if res.ok {
				combined = append(combined, res.path)
				srcN++
				continue
			}
			anyRejected = true
			if res.reason == "out-of-root" {
				fmt.Fprintf(w, "   WARN   hook-set: %s hook command resolves outside the target root (inspected: %s) — refusing to read it (out-of-root): %s\n", label, hroot, res.detail)
			} else {
				fmt.Fprintf(w, "   WARN   hook-set: %s hook command's path could not be safely verified without realpath (contains '..' or crosses a symlink) — refusing to read it (degraded): %s\n", label, res.detail)
			}
		}
		if srcN > 0 {
			srcReport = append(srcReport, fmt.Sprintf("%s: %d file(s)", label, srcN))
		}
	}

	if fsx.isDir(hdir) {
		anySeen = true
		if !fsx.readable(hdir) {
			fmt.Fprintf(w, "   unreadable   hook-placeholder: .claude/hooks/ at %s is not readable — cannot inspect\n", hroot)
			anyRejected = true
		} else {
			hooksN := 0
			for _, hf := range fsx.listHooks(hdir) {
				if !rootOK {
					fmt.Fprintf(w, "   WARN   hook-set: .claude/hooks/ entry refused — target root could not be canonicalized (inspected: %s): %s\n", hroot, hf)
					anyRejected = true
					continue
				}
				res := rootCheck(fsx, hf, hroot)
				if res.ok {
					if fsx.isFile(res.path) {
						combined = append(combined, res.path)
						hooksN++
					} else if fsx.isSymlink(hf) {
						fmt.Fprintf(w, "   WARN   hook-set: .claude/hooks/ entry is a dangling or non-file symlink: %s\n", hf)
						anyRejected = true
					}
					continue
				}
				anyRejected = true
				if res.reason == "out-of-root" {
					fmt.Fprintf(w, "   WARN   hook-set: .claude/hooks/ entry resolves outside the target root (inspected: %s) — refusing to read it (out-of-root): %s\n", hroot, res.detail)
				} else {
					fmt.Fprintf(w, "   WARN   hook-set: .claude/hooks/ entry's path could not be safely verified without realpath (contains '..' or crosses a symlink) — refusing to read it (degraded): %s\n", res.detail)
				}
			}
			if hooksN > 0 {
				srcReport = append(srcReport, fmt.Sprintf(".claude/hooks/*: %d file(s)", hooksN))
			}
		}
	}

	files := uniqueSorted(combined)
	dupes := len(combined) - len(files)
	switch {
	case len(files) > 0:
		fmt.Fprintf(w, "   INFO   hook-set: inspected %d hook file(s) — %s (%d duplicate(s) removed; root: %s)\n", len(files), strings.Join(srcReport, "; "), dupes, hroot)
	case !anySeen:
		fmt.Fprintf(w, "   INFO   hook-placeholder: .claude/hooks/ not found and no settings.json/settings.local.json present (inspected: %s) — no installed hooks to inspect\n", hroot)
	case anyRejected:
		fmt.Fprintf(w, "   INFO   hook-placeholder: found-but-none-inspectable — every candidate hook was unresolved, out-of-root, degraded, unreadable, malformed, or a dangling/non-file symlink (see the report above); none could be inspected (inspected: %s)\n", hroot)
	default:
		fmt.Fprintf(w, "   INFO   hook-placeholder: no hooks found (empty) across .claude/settings.json, settings.local.json, and .claude/hooks/ (inspected: %s) — no installed hooks to inspect\n", hroot)
	}

	for _, f := range files {
		if f == "" {
			continue
		}
		body, err := fsx.read(f)
		if err != nil {
			fmt.Fprintf(w, "   unreadable   hook-placeholder: %s is not readable — cannot inspect for placeholders\n", basename(f))
			continue
		}
		if nums, phs := placeholders(string(body)); len(nums) > 0 {
			fmt.Fprintf(w, "   WARN   hook-placeholder: %s line(s) %s still has unreplaced placeholder(s): %s — adapt this hook for the target before use (inspected: %s)\n", basename(f), strings.Join(nums, ","), strings.Join(phs, " "), hroot)
		}
	}
}

var rePlaceholder = regexp.MustCompile(`<SUBJECT>|<KIT>|<TARGET>|<prefix>|<path to binaries/decompiled output/source code of the system under study>`)

// placeholders is the P8-HOOK-PLACEHOLDER-GREP: the numbers of the non-comment lines that carry an unreplaced
// template placeholder, and the distinct placeholders found on them (sorted).
func placeholders(body string) (lineNums, found []string) {
	seen := map[string]bool{}
	for i, l := range recordLines(body) {
		if !rePlaceholder.MatchString(l) {
			continue
		}
		if strings.HasPrefix(strings.TrimLeft(l, wsClass), "#") {
			continue
		}
		lineNums = append(lineNums, fmt.Sprint(i+1))
		for _, m := range rePlaceholder.FindAllString(l, -1) {
			seen[m] = true
		}
	}
	for m := range seen {
		found = append(found, m)
	}
	sort.Strings(found)
	return lineNums, found
}

func uniqueSorted(xs []string) []string {
	var out []string
	for _, x := range xs {
		if x != "" {
			out = append(out, x)
		}
	}
	sort.Strings(out)
	w := 0
	for i, x := range out {
		if i == 0 || x != out[w-1] {
			out[w] = x
			w++
		}
	}
	return out[:w]
}

// resolveHookPath is _p8_resolve_hook_path: $CLAUDE_PROJECT_DIR/... and ${CLAUDE_PROJECT_DIR}/... map onto the
// root, an absolute path is kept, anything else is relative to the root.
func resolveHookPath(tok, hroot string) string {
	if rest, ok := strings.CutPrefix(tok, "$CLAUDE_PROJECT_DIR/"); ok {
		return hroot + "/" + rest
	}
	if rest, ok := strings.CutPrefix(tok, "${CLAUDE_PROJECT_DIR}/"); ok {
		return hroot + "/" + rest
	}
	if strings.HasPrefix(tok, "/") {
		return tok
	}
	return hroot + "/" + tok
}

var interpreters = map[string]bool{"bash": true, "sh": true, "dash": true, "zsh": true, "ksh": true, "env": true, "python": true, "python2": true, "python3": true, "node": true, "nodejs": true, "ruby": true, "perl": true, "pwsh": true}

// firstPathToken is _p8_first_path_token: the first token of the command that looks like a script path,
// skipping flags and a leading interpreter or env wrapper. "" when there is none.
func firstPathToken(cmd string) string {
	for _, chunk := range xargsTokens(cmd) {
		for _, tok := range strings.Split(chunk, "\n") { // printf '%s\n' output read line by line
			if tok == "" || strings.HasPrefix(tok, "-") || interpreters[tok] {
				continue
			}
			if looksLikePath(tok) {
				return tok
			}
		}
	}
	return ""
}

func looksLikePath(tok string) bool {
	if strings.Contains(tok, "/") {
		return true
	}
	for _, ext := range []string{".sh", ".py", ".rb", ".js", ".pl", ".ps1"} {
		if strings.HasSuffix(tok, ext) {
			return true
		}
	}
	return false
}

// xargsTokens tokenises s the way GNU `xargs -n1` does without -0: blanks and newlines separate arguments,
// single and double quotes group (a newline inside them is an error), a backslash outside quotes takes the next
// character literally and a backslash inside quotes is literal. An unmatched quote ends the tokenisation: the
// arguments completed before it were already handed to the command, the one in progress is lost.
func xargsTokens(s string) []string {
	var toks []string
	var cur []byte
	have := false
	const (
		norm = iota
		single
		double
		back
	)
	st := norm
	flush := func() {
		if have {
			toks = append(toks, string(cur))
		}
		cur, have = nil, false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch st {
		case norm:
			switch c {
			case ' ', '\t', '\n':
				flush()
			case '\'':
				st, have = single, true
			case '"':
				st, have = double, true
			case '\\':
				st, have = back, true
			default:
				cur, have = append(cur, c), true
			}
		case single, double:
			q := byte('\'')
			if st == double {
				q = '"'
			}
			switch c {
			case q:
				st = norm
			case '\n':
				return toks // unmatched quote
			default:
				cur = append(cur, c)
			}
		case back:
			cur = append(cur, c)
			st = norm
		}
	}
	if st == single || st == double {
		return toks
	}
	flush()
	return toks
}

// settingsCommands is `jq -r '(.hooks // {}) | [.. | objects | .command? // empty] | .[]'`: every truthy
// "command" member of every object under .hooks, in document order (duplicate keys keep the last value in the
// first slot), strings raw and other values as JSON, one per line. An error (invalid JSON, or a document whose
// top level is neither an object nor null) is the "malformed" state.
func settingsCommands(raw []byte) (string, error) {
	raw = bytes.TrimPrefix(raw, []byte("\xef\xbb\xbf"))
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	var out []string
	for {
		v, err := readJSON(dec, true)
		if errors.Is(err, io.EOF) {
			break // clean end between top-level values (mid-value ends are io.ErrUnexpectedEOF)
		}
		if err != nil {
			return "", err
		}
		obj, isObj := v.(*jobject)
		switch {
		case v == nil:
			continue
		case !isObj:
			return "", errors.New("cannot index with \"hooks\"")
		}
		hooks := obj.get("hooks")
		if hooks == nil || hooks == false {
			continue
		}
		walkCommands(hooks, &out)
	}
	return cmdSubst(strings.Join(out, "\n")), nil
}

type jobject struct {
	keys []string
	vals map[string]any
}

func (o *jobject) set(k string, v any) {
	if _, dup := o.vals[k]; !dup {
		o.keys = append(o.keys, k)
	}
	o.vals[k] = v
}

func (o *jobject) get(k string) any { return o.vals[k] }

// readJSON reads one value from dec: *jobject, []any, string, json.Number, bool or nil. Only a top-level read may
// meet a clean io.EOF; at any depth below, the end of input is io.ErrUnexpectedEOF.
func readJSON(dec *json.Decoder, top bool) (any, error) {
	t, err := dec.Token()
	if err != nil {
		if !top && errors.Is(err, io.EOF) {
			err = io.ErrUnexpectedEOF
		}
		return nil, err
	}
	tok := func() (json.Token, error) {
		t, err := dec.Token()
		if errors.Is(err, io.EOF) {
			err = io.ErrUnexpectedEOF
		}
		return t, err
	}
	switch d := t.(type) {
	case json.Delim:
		if d == '{' {
			o := &jobject{vals: map[string]any{}}
			for dec.More() {
				kt, err := dec.Token()
				if err != nil {
					return nil, err
				}
				k, _ := kt.(string)
				v, err := readJSON(dec, false)
				if err != nil {
					return nil, err
				}
				o.set(k, v)
			}
			if _, err := tok(); err != nil {
				return nil, err
			}
			return o, nil
		}
		arr := []any{}
		for dec.More() {
			v, err := readJSON(dec, false)
			if err != nil {
				return nil, err
			}
			arr = append(arr, v)
		}
		if _, err := tok(); err != nil {
			return nil, err
		}
		return arr, nil
	default:
		return t, nil
	}
}

// walkCommands is `.. | objects | .command? // empty`: pre-order over objects and arrays.
func walkCommands(v any, out *[]string) {
	switch x := v.(type) {
	case *jobject:
		if c := x.get("command"); c != nil && c != false {
			*out = append(*out, jqRaw(c))
		}
		for _, k := range x.keys {
			walkCommands(x.vals[k], out)
		}
	case []any:
		for _, e := range x {
			walkCommands(e, out)
		}
	}
}

// jqRaw is how `jq -r` prints a value: a string raw, anything else as JSON.
func jqRaw(v any) string {
	if s, ok := v.(string); ok {
		return s
	}
	var b strings.Builder
	jqPretty(&b, v, 0)
	return b.String()
}

func jqPretty(b *strings.Builder, v any, depth int) {
	pad := strings.Repeat("  ", depth+1)
	switch x := v.(type) {
	case nil:
		b.WriteString("null")
	case bool:
		fmt.Fprint(b, x)
	case json.Number:
		b.WriteString(decNumberString(x.String()))
	case string:
		jqQuote(b, x)
	case []any:
		if len(x) == 0 {
			b.WriteString("[]")
			return
		}
		b.WriteString("[\n")
		for i, e := range x {
			b.WriteString(pad)
			jqPretty(b, e, depth+1)
			if i < len(x)-1 {
				b.WriteString(",")
			}
			b.WriteString("\n")
		}
		b.WriteString(strings.Repeat("  ", depth) + "]")
	case *jobject:
		if len(x.keys) == 0 {
			b.WriteString("{}")
			return
		}
		b.WriteString("{\n")
		for i, k := range x.keys {
			b.WriteString(pad)
			jqQuote(b, k)
			b.WriteString(": ")
			jqPretty(b, x.vals[k], depth+1)
			if i < len(x.keys)-1 {
				b.WriteString(",")
			}
			b.WriteString("\n")
		}
		b.WriteString(strings.Repeat("  ", depth) + "}")
	}
}

// jqQuote writes s as a JSON string the way jq prints it: short escapes for the usual controls, \u00XX for the
// rest (and DEL), everything else raw (including <, > and &).
func jqQuote(b *strings.Builder, s string) {
	b.WriteByte('"')
	for _, r := range s { // invalid UTF-8 becomes U+FFFD, as jq reads it
		switch {
		case r == '"':
			b.WriteString(`\"`)
		case r == '\\':
			b.WriteString(`\\`)
		case r == '\n':
			b.WriteString(`\n`)
		case r == '\r':
			b.WriteString(`\r`)
		case r == '\t':
			b.WriteString(`\t`)
		case r == '\b':
			b.WriteString(`\b`)
		case r == '\f':
			b.WriteString(`\f`)
		case r < 0x20 || r == 0x7f:
			fmt.Fprintf(b, `\u%04x`, r)
		default:
			b.WriteRune(r)
		}
	}
	b.WriteByte('"')
}

// decNumberString is the to-scientific-string form jq 1.7+ prints for a number literal it has not computed
// with (1.0 stays 1.0, 1e2 becomes 1E+2, 1e-2 becomes 0.01).
func decNumberString(lit string) string {
	neg := strings.HasPrefix(lit, "-")
	lit = strings.TrimPrefix(lit, "-")
	mant, exps, hasExp := strings.Cut(strings.ToLower(lit), "e")
	exp := 0
	if hasExp {
		fmt.Sscanf(exps, "%d", &exp)
	}
	intPart, frac, _ := strings.Cut(mant, ".")
	exp -= len(frac)
	coef := strings.TrimLeft(intPart+frac, "0")
	if coef == "" {
		coef = "0"
	}
	adj := exp + len(coef) - 1
	var out string
	switch {
	case exp == 0:
		out = coef
	case exp < 0 && adj >= -6:
		if len(coef) <= -exp {
			out = "0." + strings.Repeat("0", -exp-len(coef)) + coef
		} else {
			out = coef[:len(coef)+exp] + "." + coef[len(coef)+exp:]
		}
	default:
		out = coef[:1]
		if len(coef) > 1 {
			out += "." + coef[1:]
		}
		out += fmt.Sprintf("E%+d", adj)
	}
	if neg {
		out = "-" + out
	}
	return out
}

// rootResult is the outcome of _p8_root_check.
type rootResult struct {
	ok             bool
	path           string // the safe path to use when ok
	reason, detail string // "out-of-root" or "degraded", and the path to name
}

// rootCheck is _p8_root_check with realpath present: the candidate is canonicalised (realpath, falling back to
// the path as given when it cannot be) and must sit under the canonical root. A path with a newline is refused
// before anything else.
func rootCheck(fsx fsView, path, hrootReal string) rootResult {
	if strings.Contains(path, "\n") {
		return rootResult{reason: "degraded", detail: path}
	}
	real, ok := fsx.realpath(path)
	if !ok {
		real = path
	}
	if strings.HasPrefix(real, hrootReal+"/") {
		return rootResult{ok: true, path: real}
	}
	return rootResult{reason: "out-of-root", detail: real}
}
