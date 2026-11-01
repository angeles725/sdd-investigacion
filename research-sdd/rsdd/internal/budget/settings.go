package budget

import (
	"bytes"
	"os"
	"strings"
)

// Hook discovery: which SessionStart command hooks of <target>/.claude/settings.json (ONLY that file) run for each session source.

// sessionSources are the five Claude Code SessionStart sources, in report order.
var sessionSources = []string{"startup", "resume", "clear", "compact", "fork"}

// selector is the jq program that picks, for one source, the SessionStart command hooks whose matcher selects it, by Claude
// Code's documented "Matcher patterns" rule ("*", "" or absent = every source; letters/digits/_/-/space/,/| = an exact string
// or a list of exact strings; anything else = a regular expression tested unanchored). It is the script's program verbatim and
// still runs under jq: the regex path is jq's Oniguruma engine, and an invalid pattern surfaces as jq's own error text.
// Records come out NUL-delimited, <command> \x01 <timeout-or-empty>, because a command may contain newlines.
const selector = `def mm($m; $s):
       if ($m == "" or $m == "*") then true
       elif ($m | test("^[A-Za-z0-9_ ,|-]+$")) then ($m | split("[|,]"; null) | map(gsub("^\\s+|\\s+$"; "") == $s) | any)
       else ($s | test($m)) end;
     [.hooks.SessionStart[]? | select(mm((.matcher // "" | tostring); $src))
      | .hooks[]? | select(.type == "command" and (.command | type) == "string")
      | [.command, ((.timeout // "") | tostring)]] | .[] | .[0] + "\u0001" + .[1] + "\u0000"`

// hookRec is one selected hook: the command and its declared timeout text ("" when absent).
type hookRec struct{ cmd, decl string }

// isRegular is `[ -f path ]`.
func isRegular(path string) bool {
	fi, err := os.Stat(path)
	return err == nil && fi.Mode().IsRegular()
}

// isDir is `[ -d path ]`.
func isDir(path string) bool {
	fi, err := os.Stat(path)
	return err == nil && fi.IsDir()
}

// isJSONObject is `jq -e 'type == "object"' settings`.
func (e env) isJSONObject(jq, settings string) bool {
	return e.cmd(jq, "-e", `type == "object"`, settings).Run() == nil
}

// selectHooks runs the selector for one source. On failure it returns jq's first stderr line (the script's message).
func (e env) selectHooks(jq, settings, src string) (recs []hookRec, failure string, ok bool) {
	c := e.cmd(jq, "-j", "--arg", "src", src, selector, settings)
	var stdout, stderr bytes.Buffer
	c.Stdout, c.Stderr = &stdout, &stderr
	if err := c.Run(); err != nil {
		l, _, _ := strings.Cut(stderr.String(), "\n")
		return nil, l, false
	}
	data := stdout.Bytes()
	for len(data) > 0 {
		i := bytes.IndexByte(data, 0)
		if i < 0 { // no closing NUL: bash's `read -d ''` drops the unterminated tail
			break
		}
		cmd, decl, _ := strings.Cut(string(data[:i]), "\x01")
		recs = append(recs, hookRec{cmd, decl})
		data = data[i+1:]
	}
	return recs, "", true
}
