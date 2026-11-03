package verify

import (
	"bytes"
	"fmt"
	"regexp"
	"strings"
	"unicode/utf8"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/hookenv"
)

// Port of research-sdd/toolbelt/verify-registry-hook.sh, the SessionStart wrapper of verify registry:
//
//	rsdd verify registry-hook [--full] [--kit <kit-root>]
//
// It runs the registry check in process and prints the SessionStart envelope whose additionalContext is a header
// and the check's stdout+stderr. By default the output is COMPACT (kit issue #1816, SessionStart output budget):
// every WARN-class signal stays visible and only its verbosity shrinks (see compactRegistry); --full passes the
// report through unchanged. Like the script it always exits 0: a hook never fails the session, and a registry
// check that could not run (exit other than 0) is announced under its own header, never swallowed.
//
// Declared differences, each pinned by a test:
//
//   - The registry check runs in process, not through $here/verify-registry.sh; the shim passes the kit root
//     (--kit) because a binary cannot see the shim's location.
//   - The envelope is always JSON (as for kit-clean-hook): the script printed plain text when jq was missing.
//   - Lengths follow the locale as gawk does (characters under a UTF-8 LC_ALL/LC_CTYPE/LANG, bytes otherwise);
//     mawk always counts bytes, so on a machine whose awk is mawk the script and this port can differ in a
//     UTF-8 locale. The incomplete UTF-8 sequence a byte cut leaves before "..." is dropped as the script's sed does.

const (
	hdrRegistryOK      = "Research-SDD registry check (TARGETS.md vs reality):"
	hdrRegistryCouldNo = "Research-SDD registry check could not run (exit %d — check TARGETS.md and lib/ helper):"

	compactMaxWarn = 6
	compactWarnMax = 100
	compactInfoMax = 230
	compactHeadMax = 110
)

var reWarnPriority = regexp.MustCompile(`^WARN: |kit repo is NOT in its own|master cell is [0-9]+ chars|corpus layout not resolvable|is not accessible|PARTIAL`)

// RunRegistryHook is the `verify registry-hook` command.
func RunRegistryHook(args []string, s cli.Stdio) int {
	full := false
	var regArgs []string
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--full":
			full = true
		case "--kit":
			if i+1 < len(args) {
				i++
				regArgs = []string{"--kit", args[i]}
			}
		}
	}
	var buf bytes.Buffer // one writer for both streams, so the order is the script's `2>&1`
	sc := s
	sc.Out, sc.Err = &buf, &buf
	rc := hookenv.Guard(&buf, func() int { return RunRegistry(regArgs, sc) })
	out := strings.TrimRight(buf.String(), "\n")
	if rc != 0 {
		hookenv.WriteSessionStart(s.Out, fmt.Sprintf(hdrRegistryCouldNo, rc)+"\n"+out)
		return cli.ExitOK
	}
	if !full {
		out = compactRegistry(out, localeCounts(s.Env))
	}
	hookenv.WriteSessionStart(s.Out, hdrRegistryOK+"\n"+out)
	return cli.ExitOK
}

// awkChars is what awk's length() and substr() count: characters (gawk in a UTF-8 locale) when true, bytes
// (the C locale, mawk) when false, the same rule as the registry's row-hygiene lint (registry.awkLength).
type awkChars bool

func (c awkChars) length(s string) int {
	if c {
		return utf8.RuneCountInString(s)
	}
	return len(s)
}

// cut is awk's trunc(): a line longer than n becomes its first n-3 units and "...".
func (c awkChars) cut(s string, n int) string {
	if c.length(s) <= n {
		return s
	}
	if !c {
		return s[:n-3] + "..."
	}
	return string([]rune(s)[:n-3]) + "..."
}

// localeCounts reports whether the effective locale (LC_ALL, else LC_CTYPE, else LANG) is UTF-8.
func localeCounts(env func(string) string) awkChars {
	loc := strings.ToLower(orDefault(env("LC_ALL"), orDefault(env("LC_CTYPE"), env("LANG"))))
	return awkChars(strings.Contains(loc, "utf-8") || strings.Contains(loc, "utf8"))
}

// keepTail shortens a long INFO line: a bounded head (it carries the count) and the WHOLE last sentence (the
// remediation hint), dropping only the middle (the example-path list).
func keepTail(s string, u awkChars) string {
	if u.length(s) <= compactInfoMax {
		return s
	}
	p, rest := 0, s
	for {
		i := strings.Index(rest, ". ")
		if i < 0 {
			break
		}
		p += i + 2
		rest = rest[i+2:]
	}
	if p == 0 {
		return u.cut(s, compactInfoMax)
	}
	return u.cut(s, compactHeadMax) + " " + s[p:]
}

// compactRegistry is the awk filter of the script plus its sed `_utf8_trim`. Anti-silent-zero: nothing is
// dropped without a count. WARN lines past the cap are counted, per-row INFO lines are counted, the Summary line
// (which carries every drift/absent/unresolvable count) passes whole, and a line the filter does not recognise
// passes unchanged rather than vanishing.
func compactRegistry(out string, u awkChars) string {
	var b strings.Builder
	var pri, oth []string
	totalWarn, rowInfo := 0, 0
	for _, line := range strings.Split(out, "\n") {
		switch {
		case strings.HasPrefix(line, "WARN"):
			totalWarn++
			if reWarnPriority.MatchString(line) {
				pri = append(pri, line)
			} else {
				oth = append(oth, line)
			}
		case strings.HasPrefix(line, "INFO  "):
			rowInfo++
		case strings.HasPrefix(line, "INFO:"):
			b.WriteString(keepTail(line, u) + "\n")
		case strings.HasPrefix(line, "For each "):
		case strings.Trim(line, " \t\v\f\r") == "": // awk's [[:space:]]* (the C locale's space class)
		default:
			b.WriteString(line + "\n")
		}
	}
	shown := 0
	for _, w := range append(pri, oth...) {
		if shown >= compactMaxWarn {
			break
		}
		b.WriteString(u.cut(w, compactWarnMax) + "\n")
		shown++
	}
	if totalWarn > compactMaxWarn {
		fmt.Fprintf(&b, "WARN: +%d more WARN line(s) omitted (%d total)\n", totalWarn-compactMaxWarn, totalWarn)
	}
	if rowInfo > 0 {
		fmt.Fprintf(&b, "INFO: %d per-row INFO line(s) omitted\n", rowInfo)
	}
	b.WriteString("Full detail: toolbelt/verify-registry.sh (or this hook with --full).\n")
	lines := strings.Split(strings.TrimRight(b.String(), "\n"), "\n")
	for i, l := range lines {
		lines[i] = utf8Trim(l)
	}
	return strings.TrimRight(strings.Join(lines, "\n"), "\n")
}

// utf8Trim is `LC_ALL=C sed -E 's/([\xC0-\xDF]|[\xE0-\xEF][\x80-\xBF]?|[\xF0-\xF7][\x80-\xBF]{0,2})(\.\.\.|$)/\2/g'`:
// an INCOMPLETE UTF-8 sequence right before "..." or the end of the line is dropped, so a byte cut never hands
// invalid UTF-8 to the envelope. A complete sequence has more continuation bytes than the pattern allows and
// stays.
func utf8Trim(l string) string {
	var b strings.Builder
	for i := 0; i < len(l); {
		c := l[i]
		maxCont := -1
		switch {
		case c >= 0xC0 && c <= 0xDF:
			maxCont = 0
		case c >= 0xE0 && c <= 0xEF:
			maxCont = 1
		case c >= 0xF0 && c <= 0xF7:
			maxCont = 2
		}
		if maxCont >= 0 {
			j := i + 1
			for j < len(l) && l[j] >= 0x80 && l[j] <= 0xBF {
				j++
			}
			if j-(i+1) <= maxCont {
				if j == len(l) {
					i = j
					continue
				}
				if strings.HasPrefix(l[j:], "...") {
					b.WriteString("...")
					i = j + 3
					continue
				}
			}
		}
		b.WriteByte(c)
		i++
	}
	return b.String()
}
