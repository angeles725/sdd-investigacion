package toolcatalog

import (
	"strconv"
	"strings"
)

// The case tables are shared by the differential test (default build: the frozen bash scripts) and the golden test
// (both builds: the recorded answers), so the two cannot drift apart.

// runCase is one command run on a kit directory: the check, or with hook set the SessionStart hook, with args
// handed to it after the directory.
type runCase struct {
	name  string
	files map[string]string
	hook  bool
	args  []string
}

func files(installed, registry string) map[string]string {
	return map[string]string{"INSTALLED-TOOLS.md": installed, "tool-registry.md": registry}
}

// checkCases are the hand-written cases of the check: every state, every report line, every extraction form.
func checkCases() []runCase {
	many := []string{"first-tool", "second-tool", "middle-gap", "fourth-tool", "last-tool"}
	return []runCase{
		{name: "absent: INSTALLED-TOOLS.md", files: map[string]string{"tool-registry.md": regHead}},
		{name: "absent: tool-registry.md", files: map[string]string{"INSTALLED-TOOLS.md": logOf("widget")}},
		{name: "absent: both inputs", files: map[string]string{}},
		{name: "absent: INSTALLED-TOOLS.md is a directory", files: map[string]string{"INSTALLED-TOOLS.md/": "", "tool-registry.md": regHead}},
		{name: "absent: tool-registry.md is a directory", files: map[string]string{"INSTALLED-TOOLS.md": logOf("widget"), "tool-registry.md/": ""}},
		{name: "empty-input: header and separator only", files: files(logHead, regHead)},
		{name: "empty-input: zero-byte log", files: files("", regHead)},
		{name: "empty-input: pipe rows that are only separators and headers", files: files("| Tool | How |\n|---|---|\n| :--- | ---: |\n| TOOL | x |\n| tool |\n|-\n", regHead)},
		{name: "no-match: every tool cataloged", files: files(logOf("alpha", "beta"), regOf("alpha direct", "beta direct"))},
		{name: "drift: one tool", files: files(logOf("typst"), regHead)},
		{name: "drift: only the first of five", files: files(logOf(many...), regOf("second-tool", "middle-gap", "fourth-tool", "last-tool"))},
		{name: "drift: only the middle of five", files: files(logOf(many...), regOf("first-tool", "second-tool", "fourth-tool", "last-tool"))},
		{name: "drift: only the last of five", files: files(logOf(many...), regOf("first-tool", "second-tool", "middle-gap", "fourth-tool"))},
		{name: "drift: all of five", files: files(logOf(many...), regHead)},
		{name: "tool cataloged only in the Tool paths table", files: files(logOf("markitdown"), regHead+"\n## Tool paths (verified)\n\n| Tool | Path |\n|---|---|\n| markitdown | ~/.local/bin/markitdown |\n")},
		{name: "cataloged on the first line only", files: files(logOf("alpha"), "alpha is here\n"+regHead)},
		{name: "cataloged on the last line without a newline", files: files(logOf("alpha"), regHead+"see alpha")},
		{name: "registry empty", files: files(logOf("alpha"), "")},
		{name: "form 2 headings: first, middle and last", files: files("## aa (x) — 2026\n\nprose\n\n## bb (y) — 2026\n\n## cc (z) — 2026\n", regOf("aa direct", "cc direct"))},
		{name: "form 2 headings: all cataloged", files: files("## aa (x)\n## bb (y)\n", regOf("aa", "bb"))},
		{name: "form 1 and form 2 together, form 1 first", files: files("## section-gap (manual) — 2026-07-02\n"+logOf("table-tool", "table-gap")+"\n## section-ok (manual)\n", regOf("table-tool", "section-ok"))},
		{name: "heading shapes", files: files("## a(b) c (d)\n## foo bar (x)\n##foo (x)\n### deep (x)\n## \ttabbed (x)\n##  two  spaces   (x)\n## nodesc\n## trailing (\n", regHead)},
		{name: "heading with CRLF", files: files("## crlf-tool (x)\r\n", regHead)},
		{name: "duplicates in form 1", files: files(logOf("blutter", "blutter-build", "blutter"), regHead)},
		{name: "duplicate across the forms", files: files(logOf("dup")+"## dup (again)\n", regHead)},
		{name: "duplicates are case-sensitive", files: files(logOf("Tool-A", "tool-a", "TOOL-A"), regHead)},
		{name: "duplicate heading", files: files("## h (x)\n## h (y)\n## i (z)\n## h (w)\n", regHead)},
		{name: "last log row without a trailing newline", files: files(logHead+"| only-tool | `brew` | installed | kit | 2026-01-01T00:00:00Z | n/a |", regHead)},
		{name: "last heading without a trailing newline", files: files("## lone (x)", regHead)},
		{name: "last row of several without a trailing newline", files: files(strings.TrimSuffix(logOf("one", "two", "three"), "\n"), regOf("one", "two"))},
		{name: "case-insensitive match", files: files(logOf("vineflower", "cfr", "PROCYON"), regOf("Vineflower direct", "CFR", "Procyon"))},
		{name: "whole word: cfr against cfrx", files: files(logOf("cfr"), regOf("cfrx decompiler"))},
		{name: "whole word: cfr against xcfr", files: files(logOf("cfr"), regOf("xcfr"))},
		{name: "whole word: underscore and digit are word characters", files: files(logOf("cfr", "tool"), regOf("cfr_ and _cfr", "cfr2 tool9 9tool"))},
		{name: "whole word: punctuation is a boundary", files: files(logOf("cfr", "ghidra", "radare2"), regOf("(cfr)", "ghidra, then ghidra.", "radare2/r2 and cfr-x"))},
		{name: "whole word: a later occurrence matches after an earlier miss", files: files(logOf("cfr"), regOf("xcfr cfrx cfr"))},
		{name: "whole word: line edges", files: files(logOf("edge"), "edge\n"+regHead)},
		{name: "whole word: the match may sit on a non-table line", files: files(logOf("capa"), regHead+"long capacity build note\n")},
		{name: "alias token carries the match", files: files(logOf("kaitai-struct-compiler"), regOf("ksc 0.11 (alias: kaitai-struct-compiler) direct"))},
		{name: "alias token absent", files: files(logOf("kaitai-struct-compiler"), regOf("ksc 0.11 direct"))},
		{name: "names with dot and hyphen", files: files(logOf("js.beautify", "a-b.c-d", "xz-utils", ".net", "net."), regOf("js.beautify", "a-b.c-d", "xz utils", "dotnet .net", "net."))},
		{name: "dot is not a wildcard", files: files(logOf("a.b"), regOf("aXb"))},
		{name: "fixed-string metacharacters", files: files(logOf("c++", "[x]", "a\\b", "*", "o'brien", "a$b"), regOf("c++ and [x]", "a\\b", "o'brien"))},
		{name: "name with inner spaces", files: files(logOf("my tool", "my  tool"), regOf("my tool"))},
		{name: "name starting with a hyphen", files: files(logOf("-dash"), regOf("see -dash here"))},
		{name: "cell hygiene: empty and short rows", files: files("| | x |\n||y|\n| onlyname\n|   spaced   |\n|\t|x|\n|\ttab\t| z |\n|\n", regHead)},
		{name: "cell hygiene: CRLF log", files: files(strings.ReplaceAll(logOf("crlf-a", "crlf-b"), "\n", "\r\n"), regOf("crlf-a"))},
		{name: "cell hygiene: CRLF registry", files: files(logOf("crlf-a"), strings.ReplaceAll(regOf("crlf-a"), "\n", "\r\n"))},
		{name: "rows not starting with a pipe are not log rows", files: files(" | indented | x |\nplain | text |\n"+logOf("real"), regHead)},
		{name: "unicode: case and boundary", files: files(logOf("Éclair", "naïve", "ΣΊΣΥΦΟΣ", "café"), regOf("éclair", "naïvex", "σίσυφος", "caféx café"))},
		{name: "unicode: boundary next to a non-letter", files: files(logOf("tool"), regOf("tool—x", "x—tool", "tool·"))},
		{name: "unicode: combining mark and kelvin sign", files: files(logOf("kit", "e"), regOf("Kit", "é"))},
		{name: "unicode: spaces around a cell", files: files("| em-space |x|\n| nbsp |x|\n", regHead)},
		{name: "invalid UTF-8 in the registry", files: files(logOf("ok", "later", "after"), regOf("ok")+"\xff\xfe junk later\nafter\n")},
		{name: "many tools, half uncataloged", files: files(logOf(strings.Fields("t01 t02 t03 t04 t05 t06 t07 t08 t09 t10 t11 t12 t13 t14 t15 t16 t17 t18 t19 t20")...), regOf(strings.Fields("t02 t04 t06 t08 t10 t12 t14 t16 t18 t20")...))},
	}
}

// hookCases run the SessionStart hook over a real kit directory: every state it can reach through the real check.
func hookCases() []runCase {
	long := strings.Fields("alpha-tool bravo-tool charlie-tool delta-tool echo-tool foxtrot-tool golf-tool hotel-tool india-tool juliet-tool")
	return []runCase{
		{name: "hook clean sentinel", hook: true, files: files(logOf("alpha", "beta"), regOf("alpha", "beta"))},
		{name: "hook clean sentinel, one tool", hook: true, files: files(logOf("alpha"), regOf("alpha"))},
		{name: "hook empty-input is silent", hook: true, files: files(logHead, regHead)},
		{name: "hook absent log could not run", hook: true, files: map[string]string{"tool-registry.md": regHead}},
		{name: "hook absent registry could not run", hook: true, files: map[string]string{"INSTALLED-TOOLS.md": logOf("a")}},
		{name: "hook drift one tool, compact", hook: true, files: files(logOf("typst", "ok"), regOf("ok"))},
		{name: "hook drift one tool, full", hook: true, files: files(logOf("typst", "ok"), regOf("ok")), args: []string{"--full"}},
		{name: "hook drift ten tools, compact", hook: true, files: files(logOf(long...), regHead)},
		{name: "hook drift ten tools, full", hook: true, files: files(logOf(long...), regHead), args: []string{"--full"}},
		{name: "hook drift names with comma and apostrophe", hook: true, files: files(logOf("a,b", "o'brien", "plain"), regHead)},
		{name: "hook drift names with comma and apostrophe, full", hook: true, files: files(logOf("a,b", "o'brien", "plain"), regHead), args: []string{"--full"}},
		{name: "hook drift from a heading", hook: true, files: files("## h-tool (x)\n"+logOf("t-tool"), regHead)},
		{name: "hook drift first, middle and last", hook: true, files: files(logOf("one", "two", "three", "four", "five"), regOf("two", "four"))},
	}
}

// stubCase is a canned output of the check (what the hook would read) and its exit code: the states the real check
// never produces, and the long ones.
type stubCase struct {
	name string
	out  string
	rc   int
	full bool
}

func summary(logged, cataloged, missing string) string {
	return "Summary: " + logged + " distinct tool(s) logged in INSTALLED-TOOLS.md · " + cataloged + " cataloged · " + missing + " not cataloged."
}

func warn(tool string) string {
	return "WARN  installed-but-not-cataloged: '" + tool + "' is logged in INSTALLED-TOOLS.md but has no entry in tool-registry.md — add a capability row."
}

// padWarn is a WARN line (not a not-cataloged one) whose multi-byte character c starts at byte offset at (0-based).
func padWarn(at int, c string) string {
	return "WARN  x" + strings.Repeat("a", at-len("WARN  x")) + c + "tail"
}

func stubCases() []stubCase {
	cs := []stubCase{
		{name: "stub clean sentinel", out: summary("5", "5", "0")},
		{name: "stub clean, logged count missing", out: "Summary: abc · 0 not cataloged."},
		{name: "stub clean, no not-cataloged count at all", out: "Summary: 3 distinct tool(s) logged."},
		{name: "stub two Summary lines", out: summary("5", "5", "0") + "\n" + summary("7", "7", "0")},
		{name: "stub drift one tool", out: warn("typst") + "\n\n" + summary("3", "2", "1")},
		{name: "stub drift, compact and full", out: warn("typst") + "\n" + warn("bkcrack") + "\n\n" + summary("4", "2", "2"), full: true},
		{name: "stub drift keeps another WARN line", out: warn("typst") + "\nWARN  something else entirely\n\n" + summary("3", "2", "1")},
		{name: "stub drift, another WARN line only", out: "WARN  something else entirely\n\n" + summary("3", "2", "1")},
		{name: "stub drift, WARN lines without a Summary tool name", out: "WARN  installed-but-not-cataloged: no quote here\n" + summary("3", "2", "1")},
		{name: "stub drift, name with a comma", out: warn("a,b") + "\n" + warn("c") + "\n" + summary("3", "1", "2")},
		{name: "stub drift, name with a comma, full", out: warn("a,b") + "\n" + summary("3", "1", "2"), full: true},
		{name: "stub drift, empty name", out: warn("") + "\n" + summary("3", "2", "1")},
		{name: "stub drift, the Summary leaves counts unparseable", out: warn("typst") + "\nSummary: broken"},
		{name: "stub drift, a prose line starting with WARN", out: "WARNING: not a catalog line\n" + summary("1", "0", "1")},
		{name: "stub rc 1 could not run", out: "verify-tool-catalog: ERROR — cannot find /x/INSTALLED-TOOLS.md (absent-input)", rc: 1},
		{name: "stub rc 2", out: "boom", rc: 2},
		{name: "stub rc 127 with empty output", out: "", rc: 127},
		{name: "stub rc 1 with a long output", out: strings.Repeat("line of failure output that is long enough to matter\n", 40) + "the last line is the cause", rc: 1},
		{name: "stub rc 1 with one long line", out: strings.Repeat("x", 3000), rc: 1},
		{name: "stub rc 1 with non-ASCII output", out: strings.Repeat("é€😀 ", 400), rc: 1},
		{name: "stub missing Summary", out: "some unexpected garbage with no Summary line"},
		{name: "stub missing Summary, empty output", out: ""},
		{name: "stub missing Summary with a long output", out: strings.Repeat("garbage line number n\n", 90) + "the last garbage line", rc: 0},
		{name: "stub empty-input sentence is silent", out: "verify-tool-catalog: INSTALLED-TOOLS.md has no tool log rows (empty-input) — nothing to reconcile."},
		{name: "stub EMPTY-INPUT uppercase is silent", out: "EMPTY-INPUT"},
		{name: "stub the no-log-rows phrase alone is silent", out: "There were No Tool Log Rows today"},
		{name: "stub empty-input phrase but a Summary exists", out: "empty-input\n" + summary("2", "2", "0")},
		{name: "stub Summary must start the line", out: "  " + summary("2", "2", "0")},
	}
	// The 160-byte cut of another WARN line: a character that straddles byte 160 at every offset, a character that
	// ends exactly at byte 160, and one that starts right after it.
	for _, c := range []struct{ tag, ch string }{{"2-byte", "é"}, {"3-byte", "€"}, {"4-byte", "😀"}} {
		for at := 160 - len(c.ch) - 1; at <= 161; at++ {
			cs = append(cs, stubCase{
				name: "stub cut at 160: " + c.tag + " char starting at byte " + strconv.Itoa(at),
				out:  padWarn(at, c.ch) + "\n" + warn("t") + "\n" + summary("2", "1", "1"),
			})
		}
	}
	return append(cs,
		stubCase{name: "stub cut at 160: ASCII line of exactly 160 bytes", out: "WARN  " + strings.Repeat("b", 154) + "\n" + summary("1", "0", "1")},
		stubCase{name: "stub cut at 160: ASCII line of 161 bytes", out: "WARN  " + strings.Repeat("b", 155) + "\n" + warn("z") + "\n" + summary("2", "1", "1")},
		stubCase{name: "stub cut at 160: full keeps the long line", out: padWarn(158, "€") + "\n" + warn("t") + "\n" + summary("2", "1", "1"), full: true},
	)
}
