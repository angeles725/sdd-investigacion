//go:build !nodiff

package budget

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Differential tests, Claude harness: the frozen script and the Go command print the same stdout and stderr and
// exit with the same code from the same targets and environment. Divergences the package doc declares are NOT
// compared here: they are pinned one by one in divergence_test.go.

func TestDifferentialNoSandboxStates(t *testing.T) {
	sb := newSbx(t)
	env := sb.environ()
	for _, name := range []string{"empty", "absent", "badjson"} {
		t.Run(name, func(t *testing.T) { sb.same(name, env, sb.target(name)) })
	}
	t.Run("usage", func(t *testing.T) {
		for _, args := range [][]string{
			nil, {""}, {sb.root + "/no-such-dir"}, {"--harness"}, {"--harness", "nope", sb.target("empty")},
			{"--harness", "claude"}, {sb.target("empty"), "extra"}, {"--harness", "pi", "--harness", "pi", sb.target("empty")},
		} {
			o := sb.same(fmt.Sprintf("args %q", args), env, args...)
			if o.rc != 2 || o.stdout != "" || !strings.HasPrefix(o.stderr, "usage: verify-session-budget.sh [--harness claude|pi|both] <target-dir>") {
				t.Errorf("args %q: want usage on stderr, rc 2; got rc=%d stdout=%q stderr=%q", args, o.rc, o.stdout, o.stderr)
			}
		}
	})
	t.Run("relative target and symlink are resolved to the physical path", func(t *testing.T) {
		link := filepath.Join(sb.root, "link-to-empty")
		if err := os.Symlink(sb.target("empty"), link); err != nil {
			t.Fatal(err)
		}
		if err := os.Symlink(sb.target("empty"), filepath.Join(sb.cwd, "rel")); err != nil {
			t.Fatal(err)
		}
		o := sb.same("symlink", env, link)
		if !strings.HasPrefix(o.stdout, "verify-session-budget: "+sb.target("empty")+"\n") {
			t.Errorf("target not resolved with pwd -P: %q", o.stdout)
		}
		sb.same("relative", env, "rel")
		sb.same("trailing slash", env, sb.target("empty")+"/")
	})
	t.Run("settings shapes", func(t *testing.T) {
		for name, body := range map[string]string{
			"array": `[1]`, "string": `"x"`, "null": `null`, "empty-file": ``, "garbage": `{"hooks":`,
			"ss-not-array": `{"hooks":{"SessionStart":"x"}}`, "no-hooks-key": `{}`,
			"only-prompt-hooks": `{"hooks":{"SessionStart":[{"hooks":[{"type":"prompt","command":"x"},{"type":"command"},{"type":"command","command":5}]}]}}`,
			"null-entries":      `{"hooks":{"SessionStart":[null,{"matcher":"nope","hooks":null},{"hooks":[null]}]}}`,
		} {
			d := sb.mkTarget("shape-"+name, body, nil)
			sb.same("settings "+name, env, d)
		}
		d := sb.mkTarget("settings-is-dir", "{}", nil)
		_ = os.Remove(filepath.Join(d, ".claude", "settings.json"))
		_ = os.Mkdir(filepath.Join(d, ".claude", "settings.json"), 0o755)
		sb.same("settings is a directory", env, d)
	})
	t.Run("an entry that is not an object degrades the selection (text after the prefix is not compared)", func(t *testing.T) {
		for name, body := range map[string]string{
			"entry-string": `{"hooks":{"SessionStart":["x"]}}`,
			"entry-number": `{"hooks":{"SessionStart":[7]}}`,
			"hook-string":  `{"hooks":{"SessionStart":[{"hooks":["x"]}]}}`,
			"hook-array":   `{"hooks":{"SessionStart":[{"hooks":[[1]]}]}}`,
			"hooks-string": `{"hooks":"x"}`,
			"hooks-array":  `{"hooks":[]}`,
			"bad-regex":    `{"hooks":{"SessionStart":[{"matcher":"(","hooks":[{"type":"command","command":"true"}]}]}}`,
		} {
			d := sb.mkTarget(name, body, nil)
			env := sb.environ()
			l, g := sb.legacy(env, d), sb.golang(env, d)
			const pre = "state: degraded (cannot select SessionStart hooks for source startup: "
			if !strings.Contains(l.stdout, pre) || !strings.Contains(g.stdout, pre) || l.rc != 0 || g.rc != 0 || !strings.HasSuffix(strings.TrimSpace(g.stdout), "); no hook was run") {
				t.Errorf("%s:\nlegacy %q\n    go %q", name, l.stdout, g.stdout)
			}
		}
	})
	t.Run("temp dir cannot be created", func(t *testing.T) {
		d := sb.mkTarget("tmpfail", `{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"true"}]}]}}`, nil)
		// mktemp's own complaint on stderr is not reproduced (declared in the package doc).
		env := sb.environ("TMPDIR=" + sb.root + "/no/such/tmp")
		l, g := sb.legacy(env, d), sb.golang(env, d)
		if l.stdout != g.stdout || l.rc != g.rc || g.stderr != "" || !strings.Contains(g.stdout, "state: degraded (cannot create a temp dir)") {
			t.Errorf("legacy %+v\n    go %+v", l, g)
		}
	})
	t.Run("no bwrap", func(t *testing.T) {
		bin := sb.mkbin("bin-nobwrap", "bwrap")
		o := sb.same("no bwrap", sb.environ("PATH="+bin), sb.target("mixed"))
		if !has(o.stdout, `hook\[1\] chars=n/a status=degraded\(no-sandbox: bwrap not installed\)`) || !has(o.stdout, `state: degraded`) {
			t.Errorf("got %q", o.stdout)
		}
		if _, err := os.Stat(filepath.Join(sb.target("mixed"), ".claude", ".hook-wrote-this")); err == nil {
			t.Error("a hook ran without a sandbox")
		}
	})
	t.Run("no timeout command", func(t *testing.T) {
		bin := sb.mkbin("bin-notimeout", "timeout")
		sb.same("no timeout", sb.environ("PATH="+bin), sb.target("mixed"))
	})
	t.Run("bwrap present but cannot start", func(t *testing.T) {
		bin := sb.mkbin("bin-badbwrap", "bwrap")
		sb.shim(bin, "bwrap", "#!/bin/sh\necho \"bwrap: No permissions to create new namespace\" >&2\nexit 1\n")
		o := sb.same("bad bwrap", sb.environ("PATH="+bin), sb.target("mixed"))
		if !has(o.stdout, `status=degraded\(no-sandbox: bwrap cannot start: bwrap: No permissions`) || has(o.stdout, `degraded\(exit 1\)`) {
			t.Errorf("got %q", o.stdout)
		}
		long := sb.mkbin("bin-longbwrap", "bwrap")
		sb.shim(long, "bwrap", "#!/bin/sh\nprintf '%s\\nsecond line' \""+strings.Repeat("é", 100)+"\" >&2\nexit 1\n")
		sb.same("bwrap message cut to 120 bytes, first line only", sb.environ("PATH="+long), sb.target("mixed"))
	})
}

// Hooks run in a real sandbox from here on.
func TestDifferentialFixtures(t *testing.T) {
	needBwrap(t)
	sb := newSbx(t)
	env := sb.environ()
	for _, name := range []string{"mixed", "over", "sources", "newline", "timeouts", "matchers", "partialmix", "fresh", "utf8"} {
		t.Run(name, func(t *testing.T) { sb.same(name, env, sb.target(name)) })
	}
	for _, name := range []string{"degraded", "capped"} {
		t.Run(name, func(t *testing.T) { sb.same(name, sb.environ("RSDD_BUDGET_HOOK_TIMEOUT=1"), sb.target(name)) })
	}
	t.Run("the target is not modified and hook writes never reach it", func(t *testing.T) {
		before := snapshot(t, sb.target("mixed"))
		sb.golang(env, sb.target("mixed"))
		if after := snapshot(t, sb.target("mixed")); after != before {
			t.Errorf("target changed:\nbefore %s\nafter  %s", before, after)
		}
		for _, p := range []string{".claude/.hook-wrote-this", "stray-root-file"} {
			if _, err := os.Stat(filepath.Join(sb.target("mixed"), p)); err == nil {
				t.Errorf("hook write leaked into the target: %s", p)
			}
		}
	})
	t.Run("an unreadable .claude entry makes the sandbox copy incomplete", func(t *testing.T) {
		if os.Geteuid() == 0 {
			t.Skip("running as root: an unreadable file is readable")
		}
		p := filepath.Join(sb.target("utf8"), ".claude", "unreadable")
		if err := os.WriteFile(p, nil, 0o000); err != nil {
			t.Fatal(err)
		}
		o := sb.same("unreadable entry", env, sb.target("utf8"))
		if !strings.Contains(o.stdout, "status=degraded(incomplete-sandbox-copy") {
			t.Errorf("got %q", o.stdout)
		}
		_ = os.Chmod(p, 0o600)
	})
	t.Run("containment: no write to HOME or /tmp, no network, no agent variables", func(t *testing.T) {
		esc := filepath.Join(os.TempDir(), fmt.Sprintf("rsdd-budget-esc-%d", os.Getpid()))
		defer os.Remove(esc)
		e := sb.environ("RSDD_ESCAPE_TMP="+esc, "SSH_AUTH_SOCK=/tmp/agent.sock", "SSH_AGENT_PID=4242", "DBUS_SESSION_BUS_ADDRESS=unix:path=/x")
		o := sb.same("escape", e, sb.target("escape"))
		if !has(o.stdout, `hook\[1\] chars=23 status=ok`) || !has(o.stdout, `hook\[2\] chars=1 status=ok`) || !has(o.stdout, `hook\[3\] chars=0 status=ok`) {
			t.Errorf("containment numbers wrong: %q", o.stdout)
		}
		for _, p := range []string{esc, filepath.Join(sb.root, "home", "rsdd-budget-escape")} {
			if _, err := os.Stat(p); err == nil {
				t.Errorf("hook wrote outside the sandbox: %s", p)
			}
		}
	})
}

func snapshot(t *testing.T, dir string) string {
	t.Helper()
	var b strings.Builder
	_ = filepath.Walk(dir, func(p string, fi os.FileInfo, err error) error {
		if err != nil {
			return nil
		}
		fmt.Fprintf(&b, "%s %v %d %d\n", p, fi.Mode(), fi.Size(), fi.ModTime().UnixNano())
		return nil
	})
	return b.String()
}

// What a hook may print, and how it is counted. Every case runs as one hook of one target.
func TestDifferentialHookOutputShapes(t *testing.T) {
	needBwrap(t)
	sb := newSbx(t)
	e9 := strings.Repeat("é", 9999)
	hooks := map[string]string{
		"exact10000.sh":   `printf 'x%.0s' $(seq 1 10000)`,
		"over10001.sh":    `printf 'x%.0s' $(seq 1 10001)`,
		"accents10001.sh": `head -c 20002 /dev/zero | tr '\0' 'x' | sed 's/xx/é/g'`,
		"accents9999.sh":  `printf '%s' '` + e9 + `'`,
		"invalid-utf8.sh": `printf 'a\xffb\xc3'`,
		"nul.sh":          `printf 'a\0b'`,
		"bom-crlf.sh":     `printf 'a\r\n\xef\xbb\xbfz'`,
		"empty.sh":        `true`,
		"spaces.sh":       `printf '  \n '`,
		"j-str.sh":        `printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"héllo \\u00e9\\n"}}\n'`,
		"j-both-5000.sh":  `a=$(head -c 5000 /dev/zero | tr '\0' a); printf '{"hookSpecificOutput":{"additionalContext":"%s"},"systemMessage":"%s"}' "$a" "$a"`,
		"j-ctx-10001.sh":  `a=$(head -c 10001 /dev/zero | tr '\0' a); printf '{"hookSpecificOutput":{"additionalContext":"%s"}}' "$a"`,
		"j-msg-10001.sh":  `a=$(head -c 10001 /dev/zero | tr '\0' a); printf '{"systemMessage":"%s"}' "$a"`,
		"j-msg-10000.sh":  `a=$(head -c 10000 /dev/zero | tr '\0' a); printf '{"systemMessage":"%s"}' "$a"`,
		"j-null.sh":       `printf '{"hookSpecificOutput":{"additionalContext":null},"systemMessage":false}'`,
		"j-true.sh":       `printf '{"hookSpecificOutput":{"additionalContext":true}}'`,
		"j-int.sh":        `printf '{"hookSpecificOutput":{"additionalContext":12345}}'`,
		"j-decimal.sh":    `printf '{"systemMessage":3.25}'`,
		"j-array.sh":      `printf '{"hookSpecificOutput":{"additionalContext":[1,"é",{"a":"\\u007f<>&"}]}}'`,
		"j-object.sh":     `printf '{"systemMessage":{"b":"x","a":[ 1 , 2 ]}}'`,
		"j-nul-escape.sh": `printf '{"systemMessage":["\\u0000\\u001f\\"\\\\\\/"]}'`,
		"j-other-keys.sh": `printf '{"decision":"block","reason":"nope"}'`,
		"j-empty-obj.sh":  `printf '{}'`,
		"j-top-array.sh":  `printf '[{"systemMessage":"abc"}]'`,
		"j-top-string.sh": `printf '"hello"'`,
		"j-trailing.sh":   `printf '{"systemMessage":"abc"} trailing'`,
		"j-broken.sh":     `printf '{"systemMessage":"abc"'`,
		"j-nested-hso.sh": `printf '{"hookSpecificOutput":null,"systemMessage":"ab"}'`,
		"fail-partial.sh": `printf 'partial'; exit 3`,
		"exit-255.sh":     `exit 255`,
		"sigkill.sh":      `kill -9 $$`,
		"stderr-only.sh":  `echo oops >&2`,
		"stdin-read.sh":   `cat | head -c 200 | wc -c | tr -d ' \n'`,
		"env-probe.sh":    `printf '%s|%s' "${CLAUDE_PROJECT_DIR##*/}" "$(basename "$TMPDIR")"`,
	}
	var cmds []string
	for n := range hooks {
		cmds = append(cmds, fmt.Sprintf(`{"type":"command","command":"$CLAUDE_PROJECT_DIR/.claude/hooks/%s"}`, n))
	}
	sortStrings(cmds)
	d := sb.mkTarget("shapes", `{"hooks":{"SessionStart":[{"matcher":"startup","hooks":[`+strings.Join(cmds, ",")+`]}]}}`, hooks)
	o := sb.same("hook output shapes", sb.environ(), d)
	for re, why := range map[string]string{
		`exact10000.sh`: "", `chars=10000 status=ok cmd=\$CLAUDE_PROJECT_DIR/.claude/hooks/exact10000`: "10,000 is not truncated",
		`chars=10001 status=TRUNCATED cmd=\$CLAUDE_PROJECT_DIR/.claude/hooks/over10001`:    "10,001 is truncated",
		`chars=10001 status=TRUNCATED cmd=\$CLAUDE_PROJECT_DIR/.claude/hooks/accents10001`: "characters, not bytes",
		`chars=9999 status=ok cmd=\$CLAUDE_PROJECT_DIR/.claude/hooks/accents9999`:          "9,999 accents are 9,999 characters (19,998 bytes)",
		`chars=2 status=ok cmd=\$CLAUDE_PROJECT_DIR/.claude/hooks/invalid-utf8`:            "bytes outside a valid sequence are not counted",
		`chars=10000 status=ok cmd=\$CLAUDE_PROJECT_DIR/.claude/hooks/j-both-5000`:         "additionalContext + systemMessage are added",
		`chars=10001 status=TRUNCATED cmd=\$CLAUDE_PROJECT_DIR/.claude/hooks/j-ctx-10001`:  "one JSON field over the cap",
		`status=degraded\(exit 3\) cmd=\$CLAUDE_PROJECT_DIR/.claude/hooks/fail-partial`:    "a failing hook is never counted",
	} {
		if why != "" && !has(o.stdout, re) {
			t.Errorf("%s: no line /%s/ in\n%s", why, re, o.stdout)
		}
	}
}

func sortStrings(s []string) {
	for i := 1; i < len(s); i++ {
		for j := i; j > 0 && s[j] < s[j-1]; j-- {
			s[j], s[j-1] = s[j-1], s[j]
		}
	}
}

// Matchers, dedupe and the typed per-entry failures.
func TestDifferentialMatchers(t *testing.T) {
	needBwrap(t)
	sb := newSbx(t)
	hook := func(n int) string {
		return fmt.Sprintf(`{"type":"command","command":"printf %%0%dd 0"}`, n)
	}
	var entries []string
	add := func(matcher string, n int) {
		m := ""
		if matcher != "" {
			m = `"matcher":` + matcher + `,`
		}
		entries = append(entries, `{`+m+`"hooks":[`+hook(n)+`]}`)
	}
	add(``, 1)                   // absent: every source
	add(`""`, 2)                 // empty
	add(`"*"`, 3)                // star
	add(`"startup"`, 4)          // exact
	add(`"start"`, 5)            // exact is whole-string: not startup
	add(`"^start"`, 6)           // regex, unanchored
	add(`"resume|compact"`, 7)   // list, pipe
	add(`" clear , fork "`, 8)   // list, comma, spaces
	add(`"startup,"`, 9)         // trailing separator
	add(`",resume"`, 10)         // leading separator
	add(`"compact"`, 11)         // single, last source but one
	add(`"fork"`, 12)            // single, last source
	add(`"(resume|clear)$"`, 13) // regex group
	add(`"up$"`, 14)             // regex suffix
	add(`"^$"`, 15)              // regex matching nothing here
	add(`"Startup"`, 16)         // case differs
	add(`"a.c"`, 17)             // regex dot
	add(`5`, 18)                 // number matcher
	add(`false`, 19)             // false -> ""
	add(`null`, 20)              // null -> ""
	add(`true`, 21)              // "true"
	add(`"start.*|zzz"`, 22)     // regex with alternation
	add(`"[a-z]+"`, 23)          // regex class
	add(`"resume|"`, 24)         // list with an empty alternative
	d := sb.mkTarget("matchers", `{"hooks":{"SessionStart":[`+strings.Join(entries, ",")+`,{"hooks":[`+hook(1)+`,`+hook(1)+`]}]}}`, nil)
	sb.same("matchers", sb.environ(), d)

}

// Declared hook timeouts, as the script's `case` reads them.
func TestDifferentialDeclaredTimeouts(t *testing.T) {
	needBwrap(t)
	sb := newSbx(t)
	var hs []string
	i := 0
	for _, to := range []string{`1`, `"1"`, `0`, `"abc"`, `-3`, `1.5`, `true`, `null`, `[2]`, `""`} {
		i++
		hs = append(hs, fmt.Sprintf(`{"type":"command","command":"sleep 30 # %d","timeout":%s}`, i, to))
	}
	hs = append(hs, `{"type":"command","command":"sleep 30 # none"}`, `{"type":"command","command":"printf ok","timeout":5}`)
	d := sb.mkTarget("timeouts-decl", `{"hooks":{"SessionStart":[{"matcher":"startup","hooks":[`+strings.Join(hs, ",")+`]}]}}`, nil)
	sb.same("declared timeouts", sb.environ("RSDD_BUDGET_HOOK_TIMEOUT=1"), d)
	for _, v := range []string{"", "0", "abc", "-5", "3.5", " 4"} {
		t.Run("RSDD_BUDGET_HOOK_TIMEOUT="+v, func(t *testing.T) {
			d := sb.mkTarget("to-env", `{"hooks":{"SessionStart":[{"matcher":"startup","hooks":[{"type":"command","command":"printf x"}]}]}}`, nil)
			sb.same("env timeout", sb.environ("RSDD_BUDGET_HOOK_TIMEOUT="+v), d)
		})
	}
}

// Containment is asserted in every environment through a recording bwrap: both implementations hand the same
// argument vector to every run.
func TestDifferentialContainmentArgv(t *testing.T) {
	sb := newSbx(t)
	logPath := filepath.Join(sb.root, "shim.log")
	bin := sb.mkbin("bin-shim", "bwrap")
	sb.shim(bin, "bwrap", "#!/bin/sh\nif [ \"$*\" = \"--ro-bind / / true\" ]; then exit 0; fi\ncat >/dev/null\n{ for a in \"$@\"; do printf \"%s\\n\" \"$a\"; done; echo \"--END--\"; } >> \"$RSDD_SHIM_LOG\"\nexit 0\n")
	record := func(run func() observed) (string, observed) {
		_ = os.WriteFile(logPath, nil, 0o644)
		o := run()
		b, _ := os.ReadFile(logPath)
		return workDir.ReplaceAllString(string(b), "tmp.X"), o
	}
	env := sb.environ("PATH="+bin, "RSDD_SHIM_LOG="+logPath)
	for _, name := range []string{"mixed", "sources"} {
		d := sb.target(name)
		wantLog, want := record(func() observed { return sb.legacy(env, d) })
		gotLog, got := record(func() observed { return sb.golang(env, d) })
		if wantLog != gotLog {
			t.Errorf("%s: bwrap argv differs:\n--- legacy\n%s\n--- go\n%s", name, wantLog, gotLog)
		}
		if want != got {
			t.Errorf("%s: output differs: %+v vs %+v", name, want, got)
		}
		if n := strings.Count(gotLog, "--END--"); n == 0 {
			t.Errorf("%s: the shim saw no run: zero runs would fail closed", name)
		}
	}
	// the recorded runs carry the full containment, every one of them
	log, _ := record(func() observed { return sb.golang(env, sb.target("mixed")) })
	runs := strings.Split(strings.TrimSuffix(log, "--END--\n"), "--END--\n")
	if len(runs) != 4 {
		t.Fatalf("want 4 recorded runs (one per hook), got %d", len(runs))
	}
	target := sb.target("mixed")
	for i, r := range runs {
		argv := strings.Split(strings.TrimSuffix(r, "\n"), "\n")
		for _, want := range []string{"--unshare-pid", "--unshare-net", "--unshare-ipc", "--new-session", "--die-with-parent"} {
			if !contains(argv, want) {
				t.Errorf("run %d lacks %s", i+1, want)
			}
		}
		for _, v := range []string{"SSH_AUTH_SOCK", "SSH_AGENT_PID", "GPG_AGENT_INFO", "DBUS_SESSION_BUS_ADDRESS", "XDG_RUNTIME_DIR"} {
			if !seq(argv, "--unsetenv", v) {
				t.Errorf("run %d does not unset %s", i+1, v)
			}
		}
		if !seq(argv, "--ro-bind", "/", "/") || !seq(argv, "--setenv", "CLAUDE_PROJECT_DIR", target) {
			t.Errorf("run %d lacks the read-only root or CLAUDE_PROJECT_DIR", i+1)
		}
		found := false
		for j := 0; j+2 < len(argv); j++ {
			if argv[j] == "--bind" && argv[j+2] == target+"/.claude" && argv[j+1] != argv[j+2] {
				found = true
			}
		}
		if !found {
			t.Errorf("run %d binds no throwaway copy over .claude", i+1)
		}
	}
}

func contains(s []string, v string) bool {
	for _, e := range s {
		if e == v {
			return true
		}
	}
	return false
}

// seq reports whether the consecutive elements want appear in argv.
func seq(argv []string, want ...string) bool {
	for i := 0; i+len(want) <= len(argv); i++ {
		ok := true
		for j, w := range want {
			if argv[i+j] != w {
				ok = false
				break
			}
		}
		if ok {
			return true
		}
	}
	return false
}
