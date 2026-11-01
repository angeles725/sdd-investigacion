package hook

import (
	"encoding/json"
	"math/rand/v2"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"unicode/utf8"
)

const (
	nl   = "\n"
	pdir = `$CLAUDE_PROJECT_DIR/.claude/hooks`
	// the long reason of a command the report refuses to analyse
	reasonChain = "bare command name with arguments, a prefix or a command chain (cd ...; a path command after an operator): not analysed"
	reasonIOpt  = "interpreter followed by an option: a payload or an option argument could be taken for the script"
	reasonIRel  = "relative script path for an interpreter (resolved against the launch directory)"
	reasonVar   = "unresolved variable, glob or substitution in the command path"
	reasonEnv   = "env with options or assignments, or without a command"
)

// head60 is the first 60 characters of cmd with tabs read as blanks (the bash `${cmd:0:60}` in a UTF-8 locale).
func head60(cmd string) string {
	r := []rune(cmd)
	if len(r) > 60 {
		r = r[:60]
	}
	return strings.ReplaceAll(string(r), "\t", " ")
}

func unv(cmd, reason string) string { return "unverifiable\t" + head60(cmd) + "\t" + reason + nl }

// execCase is shared by the table test and the differential test.
type execCase struct {
	name     string
	cmd      string // the only Stop command of the settings, unless settings is given
	settings string // raw settings.json
	absent   bool   // no settings.json at all
	noHome   bool   // HOME empty
	want     string // @T@ is the target, @H@ its HOME
	skipRoot bool
	setup    func(t *testing.T, target string)
}

// execFixture builds the target the table runs against: hooks/ok-exec (+x), hooks/noexec (644), a directory
// hooks/dir-noexec, home/h/noexec (644) and a dangling and a live symlink.
func execFixture(t *testing.T, r string) (target, home string) {
	t.Helper()
	target = filepath.Join(r, "lt")
	home = filepath.Join(target, "home")
	mkdirs(t, filepath.Join(home, "h"))
	writeFile(t, filepath.Join(home, "h", "noexec"), "#!/usr/bin/env bash\nexit 0\n")
	if err := os.Chmod(filepath.Join(home, "h", "noexec"), 0o644); err != nil {
		t.Fatal(err)
	}
	execHooks(t, target)
	return target, home
}

// execHooks makes <target>/.claude/hooks with an executable, a non-executable, a directory and two symlinks.
func execHooks(t *testing.T, target string) {
	t.Helper()
	hooks := filepath.Join(target, ".claude", "hooks")
	mkdirs(t, filepath.Join(hooks, "dir-noexec"))
	for f, m := range map[string]os.FileMode{filepath.Join(hooks, "ok-exec"): 0o755, filepath.Join(hooks, "noexec"): 0o644} {
		writeFile(t, f, "#!/usr/bin/env bash\nexit 0\n")
		if err := os.Chmod(f, m); err != nil {
			t.Fatal(err)
		}
	}
	symlink(t, filepath.Join(hooks, "gone"), filepath.Join(hooks, "dangling"))
	symlink(t, filepath.Join(hooks, "noexec"), filepath.Join(hooks, "link-noexec"))
}

func stopSettings(t *testing.T, cmd string) string {
	t.Helper()
	b, err := json.Marshal(map[string]any{"hooks": map[string]any{"Stop": []any{map[string]any{"hooks": []any{map[string]any{"type": "command", "command": cmd}}}}}})
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func execCases() []execCase {
	ne := "not-executable\t@T@/.claude/hooks/noexec\tStop" + nl
	mi := "missing\t@T@/.claude/hooks/absent\tStop" + nl
	hne := "not-executable\t@H@/h/noexec\tStop" + nl
	c := []execCase{
		// asserted shapes
		{name: "L1 glued operator ok-exec;echo", cmd: pdir + "/ok-exec;echo ok"},
		{name: "L1 glued operator &&", cmd: pdir + "/ok-exec&&true"},
		{name: "L1 glued operator |", cmd: pdir + "/ok-exec|tee log"},
		{name: "L1 glued operator >", cmd: pdir + "/ok-exec>/dev/null"},
		{name: "L1 operator after a non-executable", cmd: pdir + "/noexec;echo ok", want: ne},
		{name: "L1 operator after a missing path", cmd: pdir + "/absent;echo", want: mi},
		{name: "L2 NAME=value prefix", cmd: "FOO=bar " + pdir + "/absent", want: mi},
		{name: "L2 two NAME=value prefixes", cmd: "A=1 B=2 " + pdir + "/noexec", want: ne},
		{name: "L2 NAME with a dash is not an assignment", cmd: "A-B=1 " + pdir + "/noexec", want: unv("A-B=1 "+pdir+"/noexec", reasonChain)},
		{name: "L3 exec", cmd: "exec " + pdir + "/noexec", want: ne},
		{name: "L3 nohup", cmd: "nohup " + pdir + "/absent", want: mi},
		{name: "L3 command", cmd: "command " + pdir + "/noexec", want: ne},
		{name: "L4 exec with an option", cmd: "exec -a x " + pdir + "/noexec", want: unv("exec -a x "+pdir+"/noexec", "exec followed by an option")},
		{name: "L4 nohup alone", cmd: "nohup", want: unv("nohup", "no command word after the prefix")},
		{name: "L5 timeout 5", cmd: "timeout 5 " + pdir + "/noexec", want: ne},
		{name: "L5 timeout 30s", cmd: "timeout 30s " + pdir + "/absent", want: mi},
		{name: "L5 timeout 2h", cmd: "timeout 2h " + pdir + "/absent", want: mi},
		{name: "L5 timeout 1d is not a duration", cmd: "timeout 1d " + pdir + "/absent", want: unv("timeout 1d "+pdir+"/absent", "timeout with options or a duration that is not N[smh]")},
		{name: "L6 timeout with options", cmd: "timeout -s KILL 5 " + pdir + "/absent", want: unv("timeout -s KILL 5 "+pdir+"/absent", "timeout with options or a duration that is not N[smh]")},
		{name: "L6 timeout 5.5", cmd: "timeout 5.5 " + pdir + "/absent", want: unv("timeout 5.5 "+pdir+"/absent", "timeout with options or a duration that is not N[smh]")},
		{name: "L6 timeout alone", cmd: "timeout", want: unv("timeout", "timeout with options or a duration that is not N[smh]")},
		{name: "L7 bash of a missing script", cmd: "bash " + pdir + "/absent", want: mi},
		{name: "L7 bash of a non-executable script needs only existence", cmd: "bash " + pdir + "/noexec"},
		{name: "L7 /bin/sh", cmd: "/bin/sh " + pdir + "/noexec"},
		{name: "L7 python3 with trailing arguments", cmd: "python3 " + pdir + "/noexec --flag"},
		{name: "L7 env bash", cmd: "env bash " + pdir + "/noexec"},
		{name: "L7 /usr/bin/env perl missing", cmd: "/usr/bin/env perl " + pdir + "/absent", want: mi},
		{name: "L7 node and zsh", cmd: "node " + pdir + "/absent", want: mi},
		{name: "L8 bash -lc", cmd: "bash -lc 'python3 /x/hook.py'", want: unv("bash -lc 'python3 /x/hook.py'", reasonIOpt)},
		{name: "L8 bash -ec", cmd: "bash -ec x", want: unv("bash -ec x", reasonIOpt)},
		{name: "L8 perl -le", cmd: "perl -le x", want: unv("perl -le x", reasonIOpt)},
		{name: "L8 node --eval", cmd: "node --eval x", want: unv("node --eval x", reasonIOpt)},
		{name: "L8 bash -x script", cmd: "bash -x " + pdir + "/noexec", want: unv("bash -x "+pdir+"/noexec", reasonIOpt)},
		{name: "L8 interpreter alone", cmd: "bash", want: unv("bash", "interpreter without a script argument")},
		{name: "L9 bash run.sh", cmd: "bash run.sh", want: unv("bash run.sh", reasonIRel)},
		{name: "L9 sh .claude/hooks/noexec", cmd: "sh .claude/hooks/noexec", want: unv("sh .claude/hooks/noexec", reasonIRel)},
		{name: "L9 perl ./hook.pl", cmd: "perl ./hook.pl", want: unv("perl ./hook.pl", reasonIRel)},
		{name: "L10 quoted interpreter", cmd: `"/usr/bin/python3" "` + pdir + `/x.py"`, want: unv(`"/usr/bin/python3" "`+pdir+`/x.py"`, "quoted interpreter word")},
		{name: "L11 env -C", cmd: "env -C /opt/h ./hook.sh", want: unv("env -C /opt/h ./hook.sh", reasonEnv)},
		{name: "L11 env FOO=1", cmd: "env FOO=1 " + pdir + "/noexec", want: unv("env FOO=1 "+pdir+"/noexec", reasonEnv)},
		{name: "L11 env path", cmd: "env " + pdir + "/noexec", want: unv("env "+pdir+"/noexec", "env form that does not run an interpreter script")},
		{name: "L11 env alone", cmd: "env", want: unv("env", reasonEnv)},
		{name: "L12 nice", cmd: "nice -n 5 " + pdir + "/noexec", want: unv("nice -n 5 "+pdir+"/noexec", reasonChain)},
		{name: "L13 cd chain", cmd: `cd "$CLAUDE_PROJECT_DIR" && ./missing.sh`, want: unv(`cd "$CLAUDE_PROJECT_DIR" && ./missing.sh`, reasonChain)},
		{name: "L13 true; ./x.sh", cmd: "true; ./x.sh", want: unv("true; ./x.sh", reasonChain)},
		{name: "L13 jq -r .x", cmd: "jq -r .x", want: unv("jq -r .x", reasonChain)},
		{name: "L13 bare name followed by an operator", cmd: "true && x", want: unv("true && x", reasonChain)},
		{name: "L14 bare name alone is silent", cmd: "true"},
		{name: "L14 bare name alone with a lot of blanks", cmd: "   \t true   "},
		{name: "L15 backslash", cmd: pdir + `/ok\ exec`, want: unv(pdir+`/ok\ exec`, "backslash escape in the command")},
		{name: "L15 unterminated quote", cmd: `"` + pdir + "/ok-exec", want: unv(`"`+pdir+"/ok-exec", "unterminated quote in the command")},
		{name: "L15 unterminated single quote", cmd: "'" + pdir + "/ok-exec", want: unv("'"+pdir+"/ok-exec", "unterminated quote in the command")},
		{name: "L15 operator first", cmd: ";x", want: unv(";x", "no command word before the first shell operator")},
		{name: "L15 only blanks is silent", cmd: " \t "},
		{name: "L15 empty command is silent", cmd: ""},
		{name: "L16 unset variable", cmd: "$UNSETVAR/x", want: unv("$UNSETVAR/x", reasonVar)},
		{name: "L16 glob", cmd: pdir + "/*.sh", want: unv(pdir+"/*.sh", reasonVar)},
		{name: "L16 question mark", cmd: pdir + "/n?exec", want: unv(pdir+"/n?exec", reasonVar)},
		{name: "L16 bracket", cmd: pdir + "/n[o]exec", want: unv(pdir+"/n[o]exec", reasonVar)},
		{name: "L16 backtick", cmd: "`x`/y", want: unv("`x`/y", reasonVar)},
		{name: "L17 single-quoted $", cmd: "'$HOME/h/noexec'", want: unv("'$HOME/h/noexec'", "single-quoted word: the shell would not expand it")},
		{name: "L17 single-quoted ~", cmd: "'~/h/noexec'", want: unv("'~/h/noexec'", "single-quoted word: the shell would not expand it")},
		{name: "L17 single-quoted path with a variable", cmd: "'" + pdir + "/x'", want: unv("'"+pdir+"/x'", "single-quoted word: the shell would not expand it")},
		{name: "L17 single-quoted plain path", cmd: "'/nonexistent-rsdd/x'", want: "missing\t/nonexistent-rsdd/x\tStop" + nl},
		{name: "L18 ~ in double quotes", cmd: `"~/h/noexec"`, want: unv(`"~/h/noexec"`, "~ inside double quotes: the shell would not expand it")},
		{name: "L19 ${HOME}", cmd: "${HOME}/h/noexec", want: hne},
		{name: "L19 $HOME", cmd: "$HOME/h/noexec", want: hne},
		{name: "L19 ~/", cmd: "~/h/noexec", want: hne},
		{name: "L19 interpreter with $HOME", cmd: "bash $HOME/h/absent", want: "missing\t@H@/h/absent\tStop" + nl},
		{name: "L19 HOME empty: $HOME stays unresolved", cmd: "$HOME/h/noexec", noHome: true, want: unv("$HOME/h/noexec", reasonVar)},
		{name: "L19 HOME empty: ${HOME} stays unresolved", cmd: "${HOME}/h/noexec", noHome: true, want: unv("${HOME}/h/noexec", reasonVar)},
		{name: "L19 HOME empty: ~/ cannot be expanded", cmd: "~/h/noexec", noHome: true, want: unv("~/h/noexec", "~ form that cannot be expanded here")},
		{name: "L19 ~user", cmd: "~root/x", want: unv("~root/x", "~ form that cannot be expanded here")},
		{name: "L20 a directory is skipped", cmd: pdir + "/dir-noexec"},
		{name: "L21 quoted $CLAUDE_PROJECT_DIR", cmd: `"$CLAUDE_PROJECT_DIR"/.claude/hooks/noexec`, want: ne},
		{name: "L21 quoted ${CLAUDE_PROJECT_DIR} path", cmd: `"${CLAUDE_PROJECT_DIR}/.claude/hooks/noexec"`, want: ne},
		{name: "L21 braces", cmd: "${CLAUDE_PROJECT_DIR}/.claude/hooks/noexec", want: ne},
		{name: "L22 relative path is taken from the target", cmd: ".claude/hooks/noexec", want: ne},
		{name: "L22 ./ relative path", cmd: "./.claude/hooks/absent", want: "missing\t@T@/./.claude/hooks/absent\tStop" + nl},
		{name: "L22 absolute path", cmd: "/nonexistent-rsdd/x", want: "missing\t/nonexistent-rsdd/x\tStop" + nl},
		{name: "L23 dangling symlink is missing", cmd: pdir + "/dangling", want: "missing\t@T@/.claude/hooks/dangling\tStop" + nl},
		{name: "L23 symlink to a non-executable", cmd: pdir + "/link-noexec", want: "not-executable\t@T@/.claude/hooks/link-noexec\tStop" + nl},
		{name: "L24 an executable script is fine", cmd: pdir + "/ok-exec arg1 arg2"},
		{name: "L25 tab inside the command separates words", cmd: pdir + "/ok-exec\targ"},
		{name: "L26 long head is cut to 60 characters", cmd: "nice -n 5 " + strings.Repeat("x", 80), want: unv("nice -n 5 "+strings.Repeat("x", 80), reasonChain)},
		{name: "L26 head of exactly 60 characters", cmd: "nice " + strings.Repeat("y", 55), want: unv("nice "+strings.Repeat("y", 55), reasonChain)},
		{name: "L26 head cut counts characters, not bytes", cmd: "nice " + strings.Repeat("é", 70), want: unv("nice "+strings.Repeat("é", 70), reasonChain)},
		{name: "L26 head with a tab in it", cmd: "nice\t-n\t5\t" + strings.Repeat("z", 70), want: unv("nice\t-n\t5\t"+strings.Repeat("z", 70), reasonChain)},
		{name: "L27 leading blanks are stripped before the head", cmd: " \t nice -n 5", want: unv("nice -n 5", reasonChain)},
		{name: "L27 leading unicode space is stripped like [:space:]", cmd: "\u3000nice x", want: unv("nice x", reasonChain)},
		{name: "L27 NBSP is not a [:space:]", cmd: "\u00a0nice x", want: unv("\u00a0nice x", reasonChain)},
		{name: "L27 vertical tab and form feed are blanks of [:space:] but not word separators", cmd: "\v\fnice x", want: unv("nice x", reasonChain)},
		{name: "L28 a prefix with no command word", cmd: "FOO=bar", want: unv("FOO=bar", "no command word after the prefix")},
		{name: "L28 exec with an assignment after it", cmd: "exec FOO=1 " + pdir + "/noexec", want: ne},
		{name: "L28 timeout then env", cmd: "timeout 5 env bash " + pdir + "/absent", want: mi},
		{name: "L28 interpreter name with a path prefix and quotes inside", cmd: `/usr/bin/"bash" x`, want: unv(`/usr/bin/"bash" x`, "quoted interpreter word")},
	}
	// structure of settings.json
	c = append(c,
		[]execCase{
			{name: "S1 no settings.json prints nothing", absent: true},
			{name: "S2 statusLine and mcpServers commands are not hooks", settings: `{"statusLine":{"type":"command","command":"$CLAUDE_PROJECT_DIR/.claude/hooks/absent"},"mcpServers":{"x":{"command":"/nonexistent/server"}},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"$CLAUDE_PROJECT_DIR/.claude/hooks/ok-exec"}]}]}}`},
			{name: "S3 the event name rides along", settings: `{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"$CLAUDE_PROJECT_DIR/.claude/hooks/absent"}]}]}}`, want: "missing\t@T@/.claude/hooks/absent\tPreToolUse" + nl},
			{name: "S4 a value on the next line", settings: "{\n \"hooks\": {\"Stop\": [{\"hooks\": [{\"type\": \"command\",\n  \"command\":\n   \"$CLAUDE_PROJECT_DIR/.claude/hooks/noexec\"}]}]}}\n", want: ne},
			{name: "S5 invalid JSON", settings: "{ not json", want: "unverifiable\t@T@/.claude/settings.json\tsettings.json is not valid JSON (or jq failed)" + nl},
			{name: "S5 truncated JSON", settings: `{"hooks":{"Stop":[`, want: "unverifiable\t@T@/.claude/settings.json\tsettings.json is not valid JSON (or jq failed)" + nl},
			{name: "S5 trailing garbage", settings: `{"hooks":{}} x`, want: "unverifiable\t@T@/.claude/settings.json\tsettings.json is not valid JSON (or jq failed)" + nl},
			{name: "S5 trailing comma", settings: `{"hooks":{},}`, want: "unverifiable\t@T@/.claude/settings.json\tsettings.json is not valid JSON (or jq failed)" + nl},
			{name: "S6 empty file prints nothing", settings: ""},
			{name: "S6 blanks only print nothing", settings: " \n\t "},
			{name: "S7 top-level array", settings: `[{"hooks":{"Stop":[{"hooks":[{"command":"/nope"}]}]}}]`},
			{name: "S7 top-level string", settings: `"x"`},
			{name: "S7 top-level null", settings: `null`},
			{name: "S7 hooks is an array", settings: `{"hooks":[{"hooks":[{"command":"/nope"}]}]}`},
			{name: "S7 hooks is null", settings: `{"hooks":null}`},
			{name: "S7 hooks is a string", settings: `{"hooks":"x"}`},
			{name: "S7 hooks is false", settings: `{"hooks":false}`},
			{name: "S7 event value is an object", settings: `{"hooks":{"Stop":{"hooks":[{"command":"/nope"}]}}}`},
			{name: "S7 matcher group is a string", settings: `{"hooks":{"Stop":["x",{"hooks":[{"command":"/nope-a"}]}]}}`, want: "missing\t/nope-a\tStop" + nl},
			{name: "S7 inner hooks is an object", settings: `{"hooks":{"Stop":[{"hooks":{"command":"/nope"}}]}}`},
			{name: "S7 hook entry is a string", settings: `{"hooks":{"Stop":[{"hooks":["/nope"]}]}}`},
			{name: "S7 command is a number", settings: `{"hooks":{"Stop":[{"hooks":[{"command":5},{"command":null},{"command":["/nope"]},{"command":"/nope-b"}]}]}}`, want: "missing\t/nope-b\tStop" + nl},
			{name: "S8 order: events in document order, then commands", settings: `{"hooks":{"Stop":[{"hooks":[{"command":"/n/a"},{"command":"/n/b"}]},{"hooks":[{"command":"/n/c"}]}],"Alpha":[{"hooks":[{"command":"/n/d"}]}]}}`,
				want: "missing\t/n/a\tStop" + nl + "missing\t/n/b\tStop" + nl + "missing\t/n/c\tStop" + nl + "missing\t/n/d\tAlpha" + nl},
			{name: "S8 duplicate event keys: first position, last value", settings: `{"hooks":{"Stop":[{"hooks":[{"command":"/n/old"}]}],"Other":[{"hooks":[{"command":"/n/o"}]}],"Stop":[{"hooks":[{"command":"/n/new"}]}]}}`,
				want: "missing\t/n/new\tStop" + nl + "missing\t/n/o\tOther" + nl},
			{name: "S8 duplicate hooks keys: the last wins", settings: `{"hooks":{"A":[{"hooks":[{"command":"/n/x"}]}]},"hooks":{"B":[{"hooks":[{"command":"/n/y"}]}]}}`, want: "missing\t/n/y\tB" + nl},
			{name: "S9 a newline in the command reads as a blank", settings: `{"hooks":{"Stop":[{"hooks":[{"command":"nice\nx"}]}]}}`, want: unv("nice x", reasonChain)},
			{name: "S9 escaped quote and unicode escapes", settings: `{"hooks":{"Stop":[{"hooks":[{"command":"\"/n/é x\""}]}]}}`, want: "missing\t/n/é x\tStop" + nl},
			{name: "S9 an event key holding a tab", settings: `{"hooks":{"A\tB":[{"hooks":[{"command":"/n/t"}]}]}}`, want: unv("B\t/n/t", reasonChain)},
			{name: "S10 UTF-8 BOM before the document", settings: "\ufeff" + `{"hooks":{"Stop":[{"hooks":[{"command":"/n/bom"}]}]}}`, want: "missing\t/n/bom\tStop" + nl},
			{name: "S11 two top-level documents are both read", settings: `{"hooks":{"A":[{"hooks":[{"command":"/n/1"}]}]}} {"hooks":{"B":[{"hooks":[{"command":"/n/2"}]}]}}`,
				want: "missing\t/n/1\tA" + nl + "missing\t/n/2\tB" + nl},
			{name: "S14 a raw newline inside a string is invalid", settings: "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"command\":\"/n/a\nb\"}]}]}}", want: "unverifiable\t@T@/.claude/settings.json\tsettings.json is not valid JSON (or jq failed)" + nl},
			{name: "S14 a huge number is fine", settings: `{"x":1e999,"hooks":{"Stop":[{"hooks":[{"command":"/n/big"}]}]}}`, want: "missing\t/n/big\tStop" + nl},
			{name: "S14 lone surrogate escape", settings: `{"hooks":{"Stop":[{"hooks":[{"command":"/n/\ud800x"}]}]}}`, want: "unverifiable\t@T@/.claude/settings.json\tsettings.json is not valid JSON (or jq failed)" + nl},
			{name: "S14 lone low surrogate is replaced", settings: `{"hooks":{"Stop":[{"hooks":[{"command":"/n/\udc00x"}]}]}}`, want: "missing\t/n/\ufffdx\tStop" + nl},
			{name: "S14 a surrogate pair is one character", settings: `{"hooks":{"Stop":[{"hooks":[{"command":"/n/\ud83d\ude00x"}]}]}}`, want: "missing\t/n/\U0001F600x\tStop" + nl},
			{name: "S14 an escaped backslash before u is no escape", settings: `{"hooks":{"Stop":[{"hooks":[{"command":"/n/\\ud800x"}]}]}}`, want: unv(`/n/\ud800x`, "backslash escape in the command")},
			{name: "S14 NUL escape is dropped", settings: `{"hooks":{"Stop":[{"hooks":[{"command":"/n/a\u0000b"}]}]}}`, want: "missing\t/n/ab\tStop" + nl},
			{name: "S12 settings.json is a directory", setup: func(t *testing.T, target string) {
				_ = os.Remove(filepath.Join(target, ".claude", "settings.json"))
				mkdirs(t, filepath.Join(target, ".claude", "settings.json"))
			}, settings: "-", want: "unverifiable\t@T@/.claude/settings.json\tsettings.json is not a readable file" + nl},
			{name: "S12 settings.json is a dangling symlink", setup: func(t *testing.T, target string) {
				_ = os.Remove(filepath.Join(target, ".claude", "settings.json"))
				symlink(t, filepath.Join(target, "nowhere"), filepath.Join(target, ".claude", "settings.json"))
			}, settings: "-", want: "unverifiable\t@T@/.claude/settings.json\tsettings.json is not a readable file" + nl},
			{name: "S12 settings.json is a symlink to a good file", setup: func(t *testing.T, target string) {
				_ = os.Remove(filepath.Join(target, ".claude", "settings.json"))
				writeFile(t, filepath.Join(target, "real.json"), `{"hooks":{"Stop":[{"hooks":[{"command":"/n/sl"}]}]}}`)
				symlink(t, filepath.Join(target, "real.json"), filepath.Join(target, ".claude", "settings.json"))
			}, settings: "-", want: "missing\t/n/sl\tStop" + nl},
			{name: "S13 unreadable settings.json", skipRoot: true, setup: func(t *testing.T, target string) {
				if err := os.Chmod(filepath.Join(target, ".claude", "settings.json"), 0o000); err != nil {
					t.Fatal(err)
				}
			}, cmd: pdir + "/noexec", want: "unverifiable\t@T@/.claude/settings.json\tsettings.json is not a readable file" + nl},
		}...)
	return c
}

// prepare writes the case's settings under target and returns the home it runs with.
func (tt execCase) prepare(t *testing.T, r string) (target, home string) {
	target, home = execFixture(t, r)
	settings := filepath.Join(target, ".claude", "settings.json")
	switch {
	case tt.absent:
	case tt.settings == "-":
		writeFile(t, settings, "{}")
	case tt.settings != "" || tt.cmd == "" && strings.HasPrefix(tt.name, "S"):
		writeFile(t, settings, tt.settings)
	default:
		writeFile(t, settings, stopSettings(t, tt.cmd))
	}
	if tt.setup != nil {
		tt.setup(t, target)
	}
	if tt.noHome {
		home = ""
	}
	return target, home
}

func (tt execCase) wantFor(target string) string {
	return strings.NewReplacer("@T@", target, "@H@", filepath.Join(target, "home")).Replace(tt.want)
}

func goExec(t *testing.T, e Env, target string) string {
	t.Helper()
	return within(t, func() string { return FormatFindings(WiredExecReport(e, target)) })
}

func TestWiredExecReport(t *testing.T) {
	for _, tt := range execCases() {
		t.Run(tt.name, func(t *testing.T) {
			if tt.skipRoot && os.Geteuid() == 0 {
				t.Skip("running as root: permission bits are bypassed")
			}
			r, _ := sandbox(t)
			target, home := tt.prepare(t, r)
			e := envOf(r, map[string]string{envHome: home})
			if got, want := goExec(t, e, target), tt.wantFor(target); got != want {
				t.Errorf("report = %q, want %q", got, want)
			}
		})
	}
}

func TestDifferentialWiredExecFixtures(t *testing.T) {
	for _, tt := range execCases() {
		t.Run(tt.name, func(t *testing.T) {
			if tt.skipRoot && os.Geteuid() == 0 {
				t.Skip("running as root: permission bits are bypassed")
			}
			r, _ := sandbox(t)
			target, home := tt.prepare(t, r)
			e := envOf(r, map[string]string{envHome: home})
			want := legacyAsk(t, r, map[string]string{envHome: home, "LC_ALL": "C.utf8"}, "exec", target)
			if got := goExec(t, e, target); len(want) != 1 || got != want[0] {
				t.Errorf("report = %q, bash says %q", got, want)
			}
		})
	}
}

// A relative target is anchored at the cwd for every file test, but the findings print it as spelled.
func TestWiredExecRelativeTarget(t *testing.T) {
	r, _ := sandbox(t)
	writeFile(t, filepath.Join(r, "p", ".claude", "hooks", "noexec"), "")
	wireSettings(t, filepath.Join(r, "p"), stopSettings(t, ".claude/hooks/noexec"))
	if err := os.Chmod(filepath.Join(r, "p", ".claude", "hooks", "noexec"), 0o644); err != nil {
		t.Fatal(err)
	}
	e := envOf(r, nil)
	got := goExec(t, e, "p")
	want := "not-executable\tp/.claude/hooks/noexec\tStop" + nl
	if got != want {
		t.Errorf("report = %q, want %q", got, want)
	}
	legacy := legacyAsk(t, r, map[string]string{"LC_ALL": "C.utf8"}, "exec", "p")
	if len(legacy) != 1 || legacy[0] != got {
		t.Errorf("bash says %q, Go says %q", legacy, got)
	}
	// a missing settings.json under a relative target prints nothing
	if got := goExec(t, e, "nothing-here"); got != "" {
		t.Errorf("absent settings printed %q", got)
	}
}

func TestFindingString(t *testing.T) {
	f := Finding{Kind: FindingMissing, Subject: "/a/b", Detail: "Stop"}
	if got := f.String(); got != "missing\t/a/b\tStop" {
		t.Errorf("String() = %q", got)
	}
	if FindingNotExecutable != "not-executable" || FindingMissing != "missing" || FindingUnverifiable != "unverifiable" {
		t.Errorf("kind tokens drifted: %q %q %q", FindingNotExecutable, FindingMissing, FindingUnverifiable)
	}
	if got := FormatFindings(nil); got != "" {
		t.Errorf("FormatFindings(nil) = %q", got)
	}
}

func TestSplitCommand(t *testing.T) {
	for _, tt := range []struct {
		in    string
		words []string
		op    bool
		err   string
	}{
		{in: "", words: nil},
		{in: "a b\tc", words: []string{"a", "b", "c"}},
		{in: "  a   b  ", words: []string{"a", "b"}},
		{in: `"a b" c`, words: []string{`"a b"`, "c"}},
		{in: `a"b c"d e`, words: []string{`a"b c"d`, "e"}},
		{in: `'a;b' c`, words: []string{`'a;b'`, "c"}},
		{in: `"" x`, words: []string{`""`, "x"}},
		{in: "a;b", words: []string{"a"}, op: true},
		{in: "a && b", words: []string{"a"}, op: true},
		{in: "a|b", words: []string{"a"}, op: true},
		{in: "a>b", words: []string{"a"}, op: true},
		{in: "a<b", words: []string{"a"}, op: true},
		{in: "a(b", words: []string{"a"}, op: true},
		{in: "a)b", words: []string{"a"}, op: true},
		{in: "a&b", words: []string{"a"}, op: true},
		{in: ";a", op: true},
		{in: "a b;", words: []string{"a", "b"}, op: true},
		{in: `a\b`, err: "backslash escape in the command"},
		{in: `"a\"b"`, err: "unterminated quote in the command"}, // a backslash inside quotes is a plain character
		{in: `"abc`, err: "unterminated quote in the command"},
		{in: `a 'b`, err: "unterminated quote in the command"},
	} {
		words, op, err := splitCommand(tt.in)
		if err != tt.err || op != tt.op || strings.Join(words, "\x00") != strings.Join(tt.words, "\x00") || len(words) != len(tt.words) {
			t.Errorf("splitCommand(%q) = (%q, %v, %q), want (%q, %v, %q)", tt.in, words, op, err, tt.words, tt.op, tt.err)
		}
	}
}

func TestHeadOfCommand(t *testing.T) {
	long := strings.Repeat("é", 70)
	if got := headOf(long); utf8.RuneCountInString(got) != 60 || !utf8.ValidString(got) {
		t.Errorf("headOf(70 é) has %d characters", utf8.RuneCountInString(got))
	}
	if got := headOf("a\tb"); got != "a b" {
		t.Errorf("tab not blanked: %q", got)
	}
	if got := headOf(strings.Repeat("x", 60)); got != strings.Repeat("x", 60) {
		t.Errorf("60 characters must stay whole: %q", got)
	}
	// an invalid byte counts as one character and is kept as is
	if got := headOf(strings.Repeat("\xff", 61)); got != strings.Repeat("\xff", 60) {
		t.Errorf("invalid bytes: %q", got)
	}
}

func TestDifferentialWiredExecFuzz(t *testing.T) {
	rng := rand.New(rand.NewPCG(7, 8))
	words := []string{
		pdir + "/ok-exec", pdir + "/noexec", pdir + "/absent", "$HOME/h/noexec", "~/h/noexec", "${HOME}/h/noexec", "bash", "sh", "python3", "node",
		"env", "exec", "nohup", "command", "timeout", "5", "30s", "1d", "-c", "-lc", "-x", "FOO=bar", "A=1", "cd", "&&", ";", "|", ">", "true", "nice",
		`"`, `'`, `\`, "*", "?", "[x]", "$X", "`z`", "/nonexistent/x", "./rel", "rel/x", ".claude/hooks/noexec", "~root/x", `"~/h/noexec"`, `'$HOME/h/noexec'`,
		`"` + pdir + `/noexec"`, "é", "\t", "$CLAUDE_PROJECT_DIR/ok-exec", "${CLAUDE_PROJECT_DIR}/.claude/hooks/noexec", "/usr/bin/env",
	}
	events := []string{"Stop", "PreToolUse", "SessionStart", "A\\tB"}
	const n = 400
	r, _ := sandbox(t)
	_, home := execFixture(t, r)
	dirs := make([]string, n)
	contents := make([]string, n)
	for i := range dirs {
		dirs[i] = filepath.Join(r, "fz", itoa(i))
		execHooks(t, dirs[i])
		var groups []string
		for k := 1 + rng.IntN(3); k > 0; k-- {
			var ws []string
			for m := 1 + rng.IntN(6); m > 0; m-- {
				ws = append(ws, pick(rng, words))
			}
			b, _ := json.Marshal(strings.Join(ws, pick(rng, []string{" ", " ", " ", "  ", "\t"})))
			groups = append(groups, `"`+pick(rng, events)+`":[{"hooks":[{"command":`+string(b)+`}]}]`)
		}
		contents[i] = `{"hooks":{` + strings.Join(groups, ",") + `}}`
		wireSettings(t, dirs[i], contents[i])
	}
	env := map[string]string{envHome: home}
	e := envOf(r, env)
	legacy := map[string]string{envHome: env[envHome], "LC_ALL": "C.utf8"}
	want := legacyAsk(t, r, legacy, "exec", dirs...)
	if len(want) != n {
		t.Fatalf("driver answered %d of %d", len(want), n)
	}
	kinds := map[string]int{}
	for i, d := range dirs {
		got := goExec(t, e, d)
		for _, line := range strings.Split(got, nl) {
			if k, _, ok := strings.Cut(line, "\t"); ok {
				kinds[k]++
			}
		}
		if got != want[i] {
			t.Errorf("fixture %s: report = %q, bash says %q", contents[i], got, want[i])
		}
	}
	for _, k := range []string{FindingMissing, FindingUnverifiable, FindingNotExecutable} {
		if kinds[k] == 0 {
			t.Errorf("the generator never produced %q: %v", k, kinds)
		}
	}
}

func TestDifferentialWiredExecJSONFuzz(t *testing.T) {
	rng := rand.New(rand.NewPCG(9, 10))
	pool := []string{"{", "}", "[", "]", `"hooks"`, `"Stop"`, `"command"`, `"/n/x"`, `"nice"`, ":", ",", " ", "\n", "null", "true", "5", `"a b"`, `"x`, `\`, "\ufeff"}
	const n = 500
	r, _ := sandbox(t)
	dirs := make([]string, n)
	contents := make([]string, n)
	for i := range dirs {
		dirs[i] = filepath.Join(r, "jz", itoa(i))
		var b strings.Builder
		for k := 4 + rng.IntN(16); k > 0; k-- {
			b.WriteString(pick(rng, pool))
		}
		contents[i] = b.String()
		if i%3 == 0 { // a skeleton that is often valid, with noise appended or inserted
			contents[i] = `{"hooks":{"Stop":[{"hooks":[{"command":"/n/x"}` + pick(rng, pool) + `]}]}}`
		}
		wireSettings(t, dirs[i], contents[i])
	}
	e := envOf(r, nil)
	want := legacyAsk(t, r, map[string]string{"LC_ALL": "C.utf8"}, "exec", dirs...)
	if len(want) != n {
		t.Fatalf("driver answered %d of %d", len(want), n)
	}
	valid := 0
	for i, d := range dirs {
		got := goExec(t, e, d)
		if !strings.Contains(got, "not valid JSON") {
			valid++
		}
		if got != want[i] {
			t.Errorf("settings %q: report = %q, bash says %q", contents[i], got, want[i])
		}
	}
	if valid == 0 || valid == n {
		t.Errorf("the generator exercised too little: %d of %d valid", valid, n)
	}
}

func itoa(i int) string {
	if i == 0 {
		return "0"
	}
	var b []byte
	for ; i > 0; i /= 10 {
		b = append([]byte{byte('0' + i%10)}, b...)
	}
	return string(b)
}

// KNOWN DIVERGENCE (kit issue #2357): jq also reads the non-standard literals NaN and Infinity; encoding/json does not,
// so such a document reads as "not valid JSON" here. That is loud (one unverifiable finding), never a silent pass.
func TestWiredExecNaNReadsAsInvalidJSON(t *testing.T) {
	r, e := sandbox(t)
	target, _ := execFixture(t, r)
	wireSettings(t, target, `{"x":NaN,"hooks":{"Stop":[{"hooks":[{"command":"/n/nan"}]}]}}`)
	got := goExec(t, e, target)
	if want := "unverifiable\t" + target + "/.claude/settings.json\tsettings.json is not valid JSON (or jq failed)\n"; got != want {
		t.Errorf("report = %q, want %q", got, want)
	}
}
