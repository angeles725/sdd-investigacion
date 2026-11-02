package hook

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

// st wraps one raw JSON-string body as the only Stop command of a settings file.
func st(cmd string) string {
	return `{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"` + cmd + `"}]}]}}`
}

// scriptCase is shared by the table test and the differential test.
type scriptCase struct {
	name     string
	home     string // value of $HOME seen by the predicate ("" = empty)
	want     string
	skipRoot bool
	// setup builds the fixture under r and returns the target dir.
	setup func(t *testing.T, r string) string
}

// withSettings creates dir r/name (with the files in touch) and writes settings built by mk.
func withSettings(name string, touch []string, mk func(d string) string) func(t *testing.T, r string) string {
	return func(t *testing.T, r string) string {
		d := filepath.Join(r, name)
		mkdirs(t, d)
		for _, f := range touch {
			writeFile(t, filepath.Join(d, f), "")
		}
		wireSettings(t, d, mk(d))
		return d
	}
}

func fixed(s string) func(string) string { return func(string) string { return s } }

func scriptCases() []scriptCase {
	const hk = ".claude/hooks/retro-gate-stop.sh"
	// the home fixture of case 25: $HOME/hk/retro-gate-stop.sh exists, $HOME/gone/... does not
	homeFx := func(t *testing.T, r string) string {
		writeFile(t, filepath.Join(r, "home", "hk", "retro-gate-stop.sh"), "")
		return filepath.Join(r, "home")
	}
	withHome := func(name, cmd string) func(t *testing.T, r string) string {
		return func(t *testing.T, r string) string {
			homeFx(t, r)
			return withSettings(name, nil, fixed(st(cmd)))(t, r)
		}
	}
	return []scriptCase{
		{name: "24a absolute command, script exists -> present", want: ScriptPresent,
			setup: withSettings("t24a", []string{hk}, func(d string) string { return st(d + "/" + hk) })},
		{name: "24b absolute command, script deleted -> missing", want: ScriptMissing,
			setup: withSettings("t24b", nil, func(d string) string { return st(d + "/" + hk) })},
		{name: "24c $CLAUDE_PROJECT_DIR resolved against the target, exists -> present", want: ScriptPresent,
			setup: withSettings("t24c", []string{hk}, fixed(st(`$CLAUDE_PROJECT_DIR/`+hk)))},
		{name: "24d $CLAUDE_PROJECT_DIR, script absent -> missing", want: ScriptMissing,
			setup: withSettings("t24d", nil, fixed(st(`$CLAUDE_PROJECT_DIR/`+hk)))},
		{name: "24e interpreter prefix + escaped-quoted $CLAUDE_PROJECT_DIR + args, exists -> present", want: ScriptPresent,
			setup: withSettings("t24e", []string{hk}, fixed(st(`bash \"$CLAUDE_PROJECT_DIR\"/`+hk+` --flag`)))},
		{name: "24f same shape, script absent -> missing", want: ScriptMissing,
			setup: withSettings("t24f", nil, fixed(st(`bash \"$CLAUDE_PROJECT_DIR\"/`+hk+` --flag`)))},
		{name: "24g bare command name -> unverifiable", want: ScriptUnverifiable,
			setup: withSettings("t24g", nil, fixed(st(`retro-gate-stop.sh`)))},
		{name: "24h unresolvable variable -> unverifiable", want: ScriptUnverifiable,
			setup: withSettings("t24h", nil, fixed(st(`$SOME_UNKNOWN_VAR/retro-gate-stop.sh`)))},
		{name: "24i two registrations, one exists -> present", want: ScriptPresent,
			setup: withSettings("t24i", []string{"real-retro-gate-b.sh"}, func(d string) string {
				return `{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/nope/retro-gate-a.sh"},{"type":"command","command":"` + d + `/real-retro-gate-b.sh"}]}]}}`
			})},
		{name: "24j retro-gate only under SessionStart -> no-entry", want: ScriptNoEntry,
			setup: withSettings("t24j", nil, fixed(`{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"/nope/retro-gate-a.sh"}]}],"Stop":[{"hooks":[{"type":"command","command":"/x/other.sh"}]}]}}`))},
		{name: "24k no settings.json -> no-entry", want: ScriptNoEntry,
			setup: func(t *testing.T, r string) string { d := filepath.Join(r, "t24k"); mkdirs(t, d); return d }},
		{name: "24l unreadable settings.json -> no-entry", want: ScriptNoEntry, skipRoot: true,
			setup: func(t *testing.T, r string) string {
				d := withSettings("t24l", nil, func(d string) string { return st(d + "/gone/retro-gate-stop.sh") })(t, r)
				if err := os.Chmod(filepath.Join(d, ".claude", "settings.json"), 0); err != nil {
					t.Fatal(err)
				}
				return d
			}},
		{name: "24n relative path with a slash resolves against the target -> present", want: ScriptPresent,
			setup: func(t *testing.T, r string) string {
				d := filepath.Join(r, "t24n", "rel")
				writeFile(t, filepath.Join(d, "sub", "retro-gate-stop.sh"), "")
				wireSettings(t, d, st(`sub/retro-gate-stop.sh`))
				return d
			}},
		{name: "25a ${CLAUDE_PROJECT_DIR}/p, exists -> present", want: ScriptPresent,
			setup: withSettings("t25a", []string{hk}, fixed(st(`${CLAUDE_PROJECT_DIR}/`+hk)))},
		{name: "25b ${CLAUDE_PROJECT_DIR}/p, absent -> missing", want: ScriptMissing,
			setup: withSettings("t25b", nil, fixed(st(`${CLAUDE_PROJECT_DIR}/`+hk)))},
		{name: "25c $HOME/p, HOME set, exists -> present", want: ScriptPresent, home: "HOME", setup: withHome("t25c", `$HOME/hk/retro-gate-stop.sh`)},
		{name: "25d ${HOME}/p, exists -> present", want: ScriptPresent, home: "HOME", setup: withHome("t25d", `${HOME}/hk/retro-gate-stop.sh`)},
		{name: "25e ~/p, exists -> present", want: ScriptPresent, home: "HOME", setup: withHome("t25e", `~/hk/retro-gate-stop.sh`)},
		{name: "25f $HOME/p, absent -> missing", want: ScriptMissing, home: "HOME", setup: withHome("t25f", `$HOME/gone/retro-gate-stop.sh`)},
		{name: "25g ${HOME}/p, absent -> missing", want: ScriptMissing, home: "HOME", setup: withHome("t25g", `${HOME}/gone/retro-gate-stop.sh`)},
		{name: "25h ~/p, absent -> missing", want: ScriptMissing, home: "HOME", setup: withHome("t25h", `~/gone/retro-gate-stop.sh`)},
		{name: "25i $HOME/p with HOME empty -> unverifiable", want: ScriptUnverifiable, setup: withHome("t25i", `$HOME/hk/retro-gate-stop.sh`)},
		{name: "25j ~/p with HOME empty -> unverifiable", want: ScriptUnverifiable, setup: withHome("t25j", `~/hk/retro-gate-stop.sh`)},
		{name: "25k ~user/p -> unverifiable", want: ScriptUnverifiable, home: "HOME", setup: withHome("t25k", `~someone/hk/retro-gate-stop.sh`)},
		{name: "25l variable not at the start of the word -> unverifiable", want: ScriptUnverifiable,
			setup: withSettings("t25l", nil, fixed(st(`--dir=$CLAUDE_PROJECT_DIR/retro-gate-stop.sh`)))},
		{name: "25m quoted path containing a space, exists -> present", want: ScriptPresent,
			setup: withSettings("t25m", []string{"my tools/retro-gate-stop.sh"}, func(d string) string { return st(`bash \"` + d + `/my tools/retro-gate-stop.sh\" --x`) })},
		{name: "25n quoted path containing a space, absent -> missing", want: ScriptMissing,
			setup: withSettings("t25n", nil, func(d string) string { return st(`bash \"` + d + `/my gone/retro-gate-stop.sh\" --x`) })},
		{name: "25o unterminated quote -> unverifiable", want: ScriptUnverifiable,
			setup: withSettings("t25o", nil, func(d string) string { return st(`bash \"` + d + `/my tools/retro-gate-stop.sh --x`) })},
		{name: "25p unquoted space splits the word -> unverifiable", want: ScriptUnverifiable,
			setup: withSettings("t25p", nil, func(d string) string { return st(`bash ` + d + `/my tools/retro-gate-stop.sh`) })},
		{name: "25q relative path after a cd -> unverifiable", want: ScriptUnverifiable,
			setup: withSettings("t25q", nil, fixed(st(`cd sub && ./retro-gate-stop.sh`)))},
		{name: "25r same relative path without cd -> joined to the target -> missing", want: ScriptMissing,
			setup: withSettings("t25r", nil, fixed(st(`./retro-gate-stop.sh`)))},
		{name: "25r' a cd anywhere in the command makes even a first-slot relative path unverifiable", want: ScriptUnverifiable,
			setup: withSettings("t25r2", nil, fixed(st(`./retro-gate-stop.sh && cd sub`)))},
		{name: "25s one missing + one unresolvable -> unverifiable", want: ScriptUnverifiable,
			setup: withSettings("t25s", nil, fixed(`{"hooks":{"Stop":[{"hooks":[{"command":"/nope/retro-gate-a.sh"},{"command":"retro-gate-b"}]}]}}`))},
		{name: "25t one unresolvable + one present -> present", want: ScriptPresent,
			setup: withSettings("t25t", []string{"ok-retro-gate.sh"}, func(d string) string {
				return `{"hooks":{"Stop":[{"hooks":[{"command":"retro-gate-b"},{"command":"` + d + `/ok-retro-gate.sh"}]}]}}`
			})},
		{name: "25u every entry firmly absent -> missing", want: ScriptMissing,
			setup: withSettings("t25u", nil, fixed(`{"hooks":{"Stop":[{"hooks":[{"command":"/nope/retro-gate-a.sh"},{"command":"/nope2/retro-gate-b.sh"}]}]}}`))},
		{name: "26a word after bash -c is a re-parsed payload -> unverifiable", want: ScriptUnverifiable,
			setup: withSettings("t26a", nil, fixed(st(`bash -c \"/nope/retro-gate-stop.sh && echo ok\"`)))},
		{name: "26a' word after sh -lc -> unverifiable", want: ScriptUnverifiable,
			setup: withSettings("t26a2", nil, fixed(st(`sh -lc /nope/retro-gate-stop.sh`)))},
		{name: "26a'' -c AFTER the script is an ordinary argument -> missing", want: ScriptMissing,
			setup: withSettings("t26a3", nil, fixed(st(`bash /nope/retro-gate-stop.sh -c`)))},
		{name: "26b option word --cfg=/x/retro-gate.json -> unverifiable", want: ScriptUnverifiable,
			setup: withSettings("t26b", nil, fixed(st(`tool --cfg=/nope/retro-gate.json`)))},
		{name: "26c ':' before the first '/' (C:/x) -> unverifiable", want: ScriptUnverifiable,
			setup: withSettings("t26c", nil, fixed(st(`C:/nope/retro-gate-stop.sh`)))},
		{name: "26d ~/p inside double quotes is not expanded -> unverifiable", want: ScriptUnverifiable, home: "HOME", setup: withHome("t26d", `bash \"~/hk/retro-gate-stop.sh\"`)},
		{name: "26e unterminated quote in entry 1 leaves no stale result for entry 2 -> unverifiable", want: ScriptUnverifiable, home: "HOME",
			setup: func(t *testing.T, r string) string {
				homeFx(t, r)
				return withSettings("t26e", nil, func(string) string {
					return `{"hooks":{"Stop":[{"hooks":[{"command":"` + filepath.Join(r, "home") + `/hk/retro-gate-stop.sh \"unterminated"},{"command":"/nope/retro-gate-b.sh"}]}]}}`
				})(t, r)
			}},
		{name: "single-quoted $ is not expanded -> unverifiable", want: ScriptUnverifiable,
			setup: withSettings("tsq", nil, fixed(st(`bash '$CLAUDE_PROJECT_DIR/retro-gate-stop.sh'`)))},
		{name: "relative word past the second slot -> unverifiable", want: ScriptUnverifiable,
			setup: withSettings("tw3", nil, fixed(st(`env FOO=1 sub/retro-gate-stop.sh`)))},
		{name: "glob character in the path -> unverifiable", want: ScriptUnverifiable,
			setup: withSettings("tglob", nil, fixed(st(`/tmp/*/retro-gate-stop.sh`)))},
		{name: "escaped quote at the start of the string is not an end quote", want: ScriptMissing,
			setup: withSettings("tesc", nil, fixed(st(`/nope/retro-gate-stop.sh \"x\"`)))},
		{name: "empty settings.json -> no-entry", want: ScriptNoEntry,
			setup: withSettings("tempty", nil, fixed(""))},
		{name: "settings.json is a directory -> no-entry (awk reads no record)", want: ScriptNoEntry,
			setup: func(t *testing.T, r string) string {
				d := filepath.Join(r, "tdir")
				mkdirs(t, filepath.Join(d, ".claude", "settings.json"))
				return d
			}},
		{name: "script path is a directory -> missing (getline fails on a directory)", want: ScriptMissing,
			setup: func(t *testing.T, r string) string {
				d := filepath.Join(r, "tdirscript")
				mkdirs(t, filepath.Join(d, "retro-gate-dir"))
				wireSettings(t, d, st(d+"/retro-gate-dir"))
				return d
			}},
		// Mutation-teeth cases (#2356): each pins one boundary of the string scanner.
		{name: "script with content (non-empty first read) -> present", want: ScriptPresent,
			setup: func(t *testing.T, r string) string {
				d := filepath.Join(r, "tcontent")
				writeFile(t, filepath.Join(d, "retro-gate-stop.sh"), "#!/bin/sh\nexit 0\n")
				wireSettings(t, d, st(d+"/retro-gate-stop.sh"))
				return d
			}},
		{name: "command string opens at column 1 of its line -> missing", want: ScriptMissing,
			setup: withSettings("tq1", nil, fixed("{\"hooks\":{\"Stop\":[\n\"/nope/retro-gate-stop.sh\",\n\"x\"]}}"))},
		{name: "command string closes on the last column of its line -> missing", want: ScriptMissing,
			setup: withSettings("tqlast", nil, fixed("{\"hooks\":{\"Stop\":[{\n  \"command\": \"/nope/retro-gate-stop.sh\"\n}]}}"))},
		{name: "closing quote after an even run of backslashes is a real quote -> missing", want: ScriptMissing,
			setup: withSettings("tbs2", nil, fixed(st(`/nope/retro-gate-stop.sh a\\`)))},
		{name: "closing quote after an odd run of backslashes is escaped -> unverifiable", want: ScriptUnverifiable,
			setup: withSettings("tbs3", nil, fixed(`{"hooks":{"Stop":[{"command":"/nope/retro-gate-stop.sh a\\\" b"}]}}`))},
		{name: "colon as the very first character of the word -> unverifiable", want: ScriptUnverifiable,
			setup: withSettings("tcolon0", nil, fixed(st(`:/nope/retro-gate-stop.sh`)))},
		{name: "JSON string never closes -> unverifiable", want: ScriptUnverifiable,
			setup: withSettings("tnoclose", nil, fixed(`{"hooks":{"Stop":[{"command":"/nope/retro-gate-stop.sh`))},
		{name: "retro-gate with no opening quote on its line -> unverifiable", want: ScriptUnverifiable,
			setup: withSettings("tnoopen", nil, fixed("{\"hooks\":{\"Stop\":[\nretro-gate-stop.sh\n]}}"))},
		{name: "brackets inside a command string do not close the Stop block -> present", want: ScriptPresent,
			setup: withSettings("tbrk", []string{"ok-retro-gate.sh"}, fixed(`{"hooks":{"Stop":[{"hooks":[{"command":"/nope/retro-gate-a.sh }}"},{"command":"$CLAUDE_PROJECT_DIR/ok-retro-gate.sh"}]}]}}`))},
		{name: "text right after the closing quote is still scanned (closes Stop) -> missing", want: ScriptMissing,
			setup: withSettings("tafter", []string{"ok-retro-gate.sh"}, fixed(`{"hooks":{"Stop":[{"command":"/nope/retro-gate-a.sh"}],"X":[{"command":"$CLAUDE_PROJECT_DIR/ok-retro-gate.sh"}]}}`))},
	}
}

func homeOf(r, mark string) string {
	if mark == "" {
		return ""
	}
	return filepath.Join(r, "home")
}

func TestScriptState(t *testing.T) {
	for _, tt := range scriptCases() {
		t.Run(tt.name, func(t *testing.T) {
			if tt.skipRoot && os.Geteuid() == 0 {
				t.Skip("running as root: permission bits are bypassed")
			}
			r, _ := sandbox(t)
			target := tt.setup(t, r)
			e := envOf(r, map[string]string{envHome: homeOf(r, tt.home)})
			if got := within(t, func() string { return ScriptState(e, target) }); got != tt.want {
				t.Errorf("ScriptState(%q) = %q, want %q", target, got, tt.want)
			}
		})
	}
}

func TestScriptStateReadFailureIsDegraded(t *testing.T) {
	// 24m: the bash predicate reports degraded when awk cannot run or fails; here a read that fails.
	r, e := sandbox(t)
	d := withSettings("rf", nil, func(d string) string { return st(d + "/retro-gate-stop.sh") })(t, r)
	e.ReadFile = func(string) ([]byte, error) { return nil, errors.New("boom") }
	if got := ScriptState(e, d); got != ScriptDegraded {
		t.Errorf("ScriptState with a failing read = %q, want %q", got, ScriptDegraded)
	}
}

func TestScriptStateRelativeTarget(t *testing.T) {
	r, _ := sandbox(t)
	writeFile(t, filepath.Join(r, "proj", "sub", "retro-gate-stop.sh"), "")
	wireSettings(t, filepath.Join(r, "proj"), st(`sub/retro-gate-stop.sh`))
	e := envOf(r, nil)
	if got := ScriptState(e, "proj"); got != ScriptPresent {
		t.Errorf("relative target: ScriptState = %q, want %q", got, ScriptPresent)
	}
}
