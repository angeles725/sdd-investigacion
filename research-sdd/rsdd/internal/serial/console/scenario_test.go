//go:build unix

// Guard-to-test table (adding-a-command.md section 5): each guard of the command, the scenarios and tests that pin
// it, and the hand mutant that turns them red (every one was applied to a copy of the package and `go test -tags
// nodiff` failed; the mutant list is in the pull request).
//
//	guard (file)                                          pinned by
//	empty mode -> usage, exit 2 (console.go Run)           usage-no-args, usage-empty-mode, golden no-mode, empty-mode
//	unknown mode -> message + usage, exit 2 (Run)          usage-unknown-mode*, golden unknown-mode, help-flag-is-an-unknown-mode
//	run needs exactly 4 arguments (run.go)                 validate-no-args .. validate-five-args, golden run-wrong-argument-count
//	dash-leading target dir (run.go)                       validate-dash-dir-*, golden run-dash-dir
//	COM<N> pattern, one or two digits (run.go isComPort)   validate-port-bad-*, validate-port-valid-*, TestPortAndBaudPredicates
//	baud is digits only, any length (run.go isDecimal)     validate-baud-bad-*, validate-baud-valid-*, TestPortAndBaudPredicates
//	empty command (run.go)                                 validate-empty-command, validate-space-command-is-valid
//	validation order (run.go switch)                       validate-order-*, golden run-validation-precedes-the-interop-check
//	availability before mkdir (run.go have)                absent-* (the tree stays empty), golden run-no-powershell-on-path
//	command -v or -x (pwsh.go have)                        absent-not-executable-*, exec-path-entry-not-executable-*, check-path-*
//	preservation dir failure, exit 4 (run.go, evidence.go) run-mkdir-* (the first failing component and its errno)
//	banner, header, '---', citation line (run.go)          run-exit-0, run-command-*, run-target-*, run-no-output
//	post-tee guard 1: tee status, exit 5 (run.go)          run-tee-permission-denied*, TestTeeKeepsTheStreamWhenTheFileFails
//	post-tee guard 2: the file is on disk (run.go)         run-evidence-file-vanishes-after-tee
//	PowerShell status mirrored, 128+N on a signal          run-exit-7-is-mirrored, run-exit-255-is-mirrored, *-killed-by-signal, list-exit-*
//	check: status 0, CRLF tolerated, newlines stripped     check-ok*, check-double-cr, check-leading-newline, check-ok-but-exit-*
//	PowerShell argument lists, byte for byte (pwsh.go)     check-argv-is-shown, list-argv-is-shown, run-argv-is-shown
//	stdin and environment reach PowerShell (pwsh.go)       list-stdin-reaches-the-child, run-stdin-reaches-the-child
//	interop hint text, exit 3 (console.go interopAbsent)   absent-*, golden check-no-powershell-on-path, list-explicit-bin-absent
//	exit 3 carries no DEGRADED: line (Command.PlainExit3)  every golden case that ends on 3; TestConsoleIsRegisteredInTheSerialDomain
//	locale-dependent coreutils texts (quote.go)            TestQuoteCMatchesMkdir, TestQuoteShellMatchesTee, TestUTF8Locale*, run-mkdir-*-utf8-*

package console

import (
	"encoding/json"
	"os"
	"strings"
	"testing"
)

// A scenario is one invocation of the command in a fresh world. The differential runs it against the frozen
// legacy script and the Go command and requires the same stdout, stderr, exit code and file tree; the replay
// (replay_test.go) runs it against the answers the differential recorded, so the same checks also run where
// there is no bash oracle (the mutation run, -tags nodiff).
type scenario struct {
	name  string
	args  []string // "<W>" is the world directory
	env   []string
	stdin string
	setup []func(*world)
	// needsUser skips the scenario for root, which ignores the permission bits it relies on.
	needsUser bool
	// legacyExec strips "<script>: line N: " from the legacy text: bash prefixes the message of a command it
	// cannot execute with its own path and line, which the Go command has no equivalent for.
	legacyExec bool
	// legacyKilled removes bash's "<script>: line N: <pid> Killed ..." job notice from the legacy stderr: it names the
	// script's own path and line and the child's pid, none of which the Go command has.
	legacyKilled bool
	// intended is what the Go command must print instead of what the legacy script printed (nil: the same).
	intended *ran
}

func sc(name string, args ...string) *scenario { return &scenario{name: name, args: args} }

func (s *scenario) withEnv(kv ...string) *scenario { s.env = append(s.env, kv...); return s }
func (s *scenario) in(text string) *scenario       { s.stdin = text; return s }
func (s *scenario) exec() *scenario                { s.legacyExec = true; return s }
func (s *scenario) killed() *scenario              { s.legacyKilled = true; return s }
func (s *scenario) user() *scenario                { s.needsUser = true; return s }
func (s *scenario) do(f func(*world)) *scenario    { s.setup = append(s.setup, f); return s }
func (s *scenario) stub(name, body string) *scenario {
	return s.do(func(w *world) { w.stub(name, body) })
}
func (s *scenario) file(rel, content string, mode os.FileMode) *scenario {
	return s.do(func(w *world) { w.file(rel, content, mode) })
}
func (s *scenario) dir(rel string, mode os.FileMode) *scenario {
	return s.do(func(w *world) { w.mkdir(rel, mode) })
}

const (
	dump = `for a in "$@"; do printf 'ARG<%s>\n' "$a"; done`
	ok   = `printf 'OK\n'`
	tgt  = "<W>/tgt"
	ps   = "powershell.exe"
)

func (s *scenario) prepare(w *world) {
	for _, f := range s.setup {
		f(w)
	}
}

// goldenFile holds the answers of the frozen legacy script, keyed by scenario name.
const goldenFile = "testdata/recorded/scenarios.json"

func loadRecorded(t *testing.T) map[string]ran {
	t.Helper()
	b, err := os.ReadFile(goldenFile)
	if err != nil {
		t.Fatal(err)
	}
	got := map[string]ran{}
	if err := json.Unmarshal(b, &got); err != nil {
		t.Fatal(err)
	}
	return got
}

// scenarios is the whole table. Names are unique; the first word groups them.
func scenarios() []*scenario {
	var l []*scenario
	add := func(s *scenario) { l = append(l, s) }
	absent := "POWERSHELL_BIN=<W>/absent"

	// ---- the mode word -------------------------------------------------------------------------------------
	add(sc("usage-no-args"))
	add(sc("usage-empty-mode", ""))
	add(sc("usage-unknown-mode", "frobble"))
	add(sc("usage-unknown-mode-help-flag", "--help"))
	add(sc("usage-unknown-mode-h-flag", "-h"))
	add(sc("usage-unknown-mode-case", "LIST"))
	add(sc("usage-unknown-mode-trailing-space", "list "))
	add(sc("usage-unknown-mode-extra-args", "frobble", "a", "b"))

	// ---- the interop is absent (exit 3, no powershell run) --------------------------------------------------
	for _, m := range []string{"list", "check"} {
		add(sc("absent-default-"+m, m))
		add(sc("absent-explicit-"+m, m).withEnv(absent))
		add(sc("absent-empty-env-"+m, m).withEnv("POWERSHELL_BIN="))
		add(sc("absent-not-executable-"+m, m).withEnv("POWERSHELL_BIN=<W>/plain").file("plain", "x", 0o644))
	}
	add(sc("absent-default-run", "run", tgt, "COM3", "9600", "show ver"))
	add(sc("absent-explicit-run", "run", tgt, "COM3", "9600", "show ver").withEnv(absent))
	add(sc("absent-not-executable-run", "run", tgt, "COM3", "9600", "show ver").withEnv("POWERSHELL_BIN=<W>/plain").file("plain", "x", 0o644))
	add(sc("absent-run-empty-target", "run", "", "COM3", "9600", "show ver").withEnv(absent))
	for _, m := range []string{"check", "list"} {
		// `command -v` accepts the first non-executable file of the PATH when nothing executable is found, so the
		// binary counts as present and the failure is the shell's own "Permission denied" (126).
		add(sc("exec-path-entry-not-executable-"+m, m).file("bin/powershell.exe", "x", 0o644).exec())
	}

	// ---- run: argument validation (the absent binary proves validation comes first) -------------------------
	runv := func(name string, a ...string) {
		add(sc("validate-"+name, append([]string{"run"}, a...)...).withEnv(absent))
	}
	runv("no-args")
	runv("one-arg", tgt)
	runv("three-args", tgt, "COM3", "9600")
	runv("five-args", tgt, "COM3", "9600", "x", "y")
	for _, d := range []string{"-d", "--", "-", "-x/y"} {
		runv("dash-dir-"+strings.ReplaceAll(d, "/", "_"), d, "COM3", "9600", "x")
	}
	for _, c := range []struct{ label, port string }{{"lowercase", "com3"}, {"no-number", "COM"}, {"three-digits", "COM100"},
		{"trailing-space", "COM3 "}, {"leading-space", " COM3"}, {"prefix", "XCOM3"}, {"trailing-newline", "COM3\n"},
		{"arabic-digit", "COM٣"}, {"empty", ""}, {"minus", "COM-1"}, {"suffix", "COM1x"}, {"mixed-case", "coM3"}, {"two-digits-and-suffix", "COM33x"}} {
		runv("port-bad-"+c.label, tgt, c.port, "9600", "x")
	}
	for _, p := range []string{"COM0", "COM9", "COM10", "COM99"} {
		runv("port-valid-"+p, tgt, p, "9600", "x")
	}
	for _, c := range []struct{ label, baud string }{{"word", "fast"}, {"empty", ""}, {"suffix", "12a"}, {"minus", "-9600"},
		{"space", "9 6"}, {"arabic-digit", "٣"}, {"decimal", "1.5"}, {"plus", "+1"}} {
		runv("baud-bad-"+c.label, tgt, "COM3", c.baud, "x")
	}
	for _, b := range []string{"0", "007", "115200", "99999999999999999999"} {
		runv("baud-valid-"+b, tgt, "COM3", b, "x")
	}
	runv("empty-command", tgt, "COM3", "9600", "")
	runv("space-command-is-valid", tgt, "COM3", "9600", " ")
	runv("order-dash-before-port", "-d", "com3", "fast", "")
	runv("order-port-before-baud", tgt, "com3", "fast", "")
	runv("order-baud-before-command", tgt, "COM3", "fast", "")
	runv("order-count-before-dash", "-d", "com3", "fast")

	// ---- check ----------------------------------------------------------------------------------------------
	chk := func(name, body string) { add(sc("check-"+name, "check").stub(ps, body)) }
	chk("ok", ok)
	chk("ok-no-newline", `printf 'OK'`)
	chk("ok-crlf", `printf 'OK\r\n'`)
	chk("ok-extra-newlines", `printf 'OK\n\n\n'`)
	chk("ok-on-stderr", `printf 'OK\n' >&2`)
	chk("ok-split-over-both-streams", `printf 'O'; printf 'K\n' >&2`)
	chk("double-cr", `printf 'OK\r\r\n'`)
	chk("leading-newline", `printf '\nOK\n'`)
	chk("lowercase", `printf 'ok\n'`)
	chk("padded", `printf ' OK\n'`)
	chk("trailing-text", `printf 'OK extra\n'`)
	chk("ok-but-exit-1", `printf 'OK\n'; exit 1`)
	chk("ok-but-exit-255", `printf 'OK\n'; exit 255`)
	chk("empty-output", `:`)
	chk("argv-is-shown", dump)
	chk("multiline-output", `printf 'one\ntwo\n'`)
	chk("killed-by-signal", `kill -9 $$`)
	chk("stderr-only-noise", `printf 'noise\n' >&2; exit 4`)
	add(sc("check-extra-args-ignored", "check", "a", "b").stub(ps, ok))
	add(sc("check-explicit-absolute", "check").withEnv("POWERSHELL_BIN=<W>/bin/pwsh-stub").stub("pwsh-stub", ok))
	add(sc("check-explicit-bare-name-on-path", "check").withEnv("POWERSHELL_BIN=pwsh-stub").stub("pwsh-stub", ok))
	add(sc("check-explicit-relative-with-slash", "check").withEnv("POWERSHELL_BIN=./local-stub").file("local-stub", "#!/bin/sh\n"+ok+"\n", 0o755))
	add(sc("check-explicit-path-with-spaces", "check").withEnv("POWERSHELL_BIN=<W>/my bin/pwsh").file("my bin/pwsh", "#!/bin/sh\n"+ok+"\n", 0o755))
	add(sc("check-path-first-match-is-run", "check").withEnv("PATH=<W>/bin2:<W>/bin").stub(ps, `printf 'NO\n'`).file("bin2/powershell.exe", "#!/bin/sh\n"+ok+"\n", 0o755))
	add(sc("check-path-skips-a-non-executable-first-entry", "check").withEnv("PATH=<W>/bin2:<W>/bin").stub(ps, ok).file("bin2/powershell.exe", "x", 0o644))
	add(sc("check-path-empty-entry-is-the-cwd", "check").withEnv("PATH=:<W>/bin").file("powershell.exe", "#!/bin/sh\n"+ok+"\n", 0o755))

	// ---- list -----------------------------------------------------------------------------------------------
	lst := func(name, body string) { add(sc("list-"+name, "list").stub(ps, body)) }
	lst("argv-is-shown", dump)
	lst("ports", `printf 'COM1\nCOM3\n'`)
	lst("no-ports", `:`)
	lst("exit-0-stderr", `printf 'warn\n' >&2`)
	lst("streams-stay-apart", `printf 'out\n'; printf 'err\n' >&2; exit 5`)
	lst("exit-1", `exit 1`)
	lst("exit-255", `exit 255`)
	add(sc("list-killed-by-signal", "list").stub(ps, `kill -9 $$`).killed())
	lst("no-trailing-newline", `printf 'COM1'`)
	add(sc("list-extra-args-ignored", "list", "a", "b").stub(ps, `printf 'COM1\n'`))
	add(sc("list-stdin-reaches-the-child", "list").stub(ps, `read a; read b; printf 'GOT<%s|%s>\n' "$a" "$b"`).in("first\nsecond\n"))
	add(sc("list-environment-reaches-the-child", "list").withEnv("SCENARIO_VAR=hello world").stub(ps, `printf 'ENV<%s>\n' "$SCENARIO_VAR"`))
	add(sc("check-environment-reaches-the-child", "check").withEnv("SCENARIO_VAR=hello").stub(ps, `[ "$SCENARIO_VAR" = hello ] && printf 'OK\n'`))
	add(sc("list-explicit-bin", "list").withEnv("POWERSHELL_BIN=<W>/bin/pwsh-stub").stub("pwsh-stub", `printf 'COM9\n'`))

	// ---- exec failures: the file passes the availability test but cannot be executed ------------------------
	for _, m := range []struct {
		name string
		args []string
	}{{"list", []string{"list"}}, {"check", []string{"check"}}, {"run", []string{"run", tgt, "COM3", "9600", "show ver"}}} {
		bin := func(kind string) *scenario {
			return sc("exec-"+kind+"-"+m.name, m.args...).withEnv("POWERSHELL_BIN=<W>/" + kind).exec()
		}
		add(bin("adir").dir("adir", 0o755))
		add(bin("binary").file("binary", "\x7fELF\x00\x00junk", 0o755))
		add(bin("badinterp").file("badinterp", "#!/nonexistent/interp\n", 0o755))
		add(sc("exec-cwd-bare-name-not-on-path-"+m.name, m.args...).withEnv("POWERSHELL_BIN=local-stub").file("local-stub", "#!/bin/sh\n"+ok+"\n", 0o755).exec())
	}

	// ---- run: the evidence ----------------------------------------------------------------------------------
	R := func(name string, a ...string) *scenario {
		s := sc("run-"+name, append([]string{"run"}, a...)...)
		add(s)
		return s
	}
	base := []string{tgt, "COM3", "9600", "show version"}
	R("argv-is-shown", base...).stub(ps, dump)
	R("exit-0", base...).stub(ps, `printf 'hw output line\n'`)
	R("exit-7-is-mirrored", base...).stub(ps, `printf 'hw error text\n'; exit 7`)
	R("exit-255-is-mirrored", base...).stub(ps, `exit 255`)
	R("killed-by-signal", base...).stub(ps, `printf 'x\n'; kill -9 $$`).killed()
	R("no-output", base...).stub(ps, `:`)
	R("no-trailing-newline", base...).stub(ps, `printf 'partial'`)
	R("crlf-output", base...).stub(ps, `printf 'a\r\nb\r\n'`)
	R("control-and-multibyte-output", base...).stub(ps, `printf 'a\000\001\033\177\303\251b\n'`)
	R("streams-are-merged-in-order", base...).stub(ps, `printf 'a\n'; printf 'b\n' >&2; printf 'c\n'; printf 'd\n' >&2`)
	R("large-output-exceeds-a-pipe-buffer", base...).stub(ps, `printf '%070000d\n' 7`)
	R("environment-reaches-the-child", base...).withEnv("SCENARIO_VAR=hello").stub(ps, `printf 'ENV<%s>\n' "$SCENARIO_VAR"`)
	R("stdin-reaches-the-child", base...).stub(ps, `read a; printf 'GOT<%s>\n' "$a"`).in("typed\n")
	R("port-com12-baud-115200", tgt, "COM12", "115200", "x").stub(ps, `:`)
	R("port-com0-baud-0", tgt, "COM0", "0", "x").stub(ps, `:`)
	R("baud-leading-zeros", tgt, "COM3", "007", "x").stub(ps, `:`)
	R("explicit-bin", base...).withEnv("POWERSHELL_BIN=<W>/bin/pwsh-stub").stub("pwsh-stub", `printf 'via explicit\n'`)
	// the command text reaches the header, the banner and the argv verbatim
	for i, c := range []string{"line1\nline2", `say "hi" 'there'`, "$HOME `id` $(id)", "café ☃", "-n", "--", "a\\nb", " lead and trail ", "tab\there", strings.Repeat("0123456789", 500), "back\\slash\\", "cr\rin"} {
		R("command-"+string(rune('a'+i)), tgt, "COM3", "9600", c).stub(ps, dump)
	}
	// where the evidence goes
	R("target-relative", "rel/tgt", "COM3", "9600", "x").stub(ps, `printf 'r\n'`)
	R("target-relative-dot-slash", "./tgt", "COM3", "9600", "x").stub(ps, `printf 'r\n'`)
	R("target-dot-dash-dir", "./-dir", "COM3", "9600", "x").stub(ps, `printf 'r\n'`)
	R("target-trailing-slash", tgt+"/", "COM3", "9600", "x").stub(ps, `printf 'r\n'`)
	R("target-double-slash", "<W>//tgt", "COM3", "9600", "x").stub(ps, `printf 'r\n'`)
	R("target-dotdot", "<W>/x/../tgt", "COM3", "9600", "x").dir("x", 0o755).stub(ps, `printf 'r\n'`)
	R("target-with-spaces", "<W>/my target", "COM3", "9600", "x").stub(ps, `printf 'r\n'`)
	R("target-existing-with-old-evidence", base...).file("tgt/sources/probes/old.txt", "old\n", 0o644).stub(ps, `printf 'new\n'`)
	R("target-is-a-symlink-to-a-dir", base...).dir("real", 0o755).do(func(w *world) { w.symlink("<W>/real", "tgt") }).stub(ps, `printf 's\n'`)
	R("target-nested-new", "<W>/a/b/c", "COM3", "9600", "x").stub(ps, `printf 'n\n'`)
	// preservation setup fails (exit 4): mkdir -p cannot create the directory
	R("mkdir-target-is-a-file", base...).file("tgt", "file", 0o644).stub(ps, ok)
	R("mkdir-sources-is-a-file", base...).file("tgt/sources", "file", 0o644).stub(ps, ok)
	R("mkdir-probes-is-a-file", base...).file("tgt/sources/probes", "file", 0o644).stub(ps, ok)
	R("mkdir-probes-is-a-dangling-symlink", base...).dir("tgt/sources", 0o755).do(func(w *world) { w.symlink("<W>/nowhere", "tgt/sources/probes") }).stub(ps, ok)
	R("mkdir-deep-component-is-a-file", "<W>/f/x/y", "COM3", "9600", "x").file("f", "file", 0o644).stub(ps, ok)
	R("mkdir-double-slash-component-is-a-file", "<W>//f//x", "COM3", "9600", "x").file("f", "file", 0o644).stub(ps, ok)
	R("mkdir-permission-denied", base...).dir("tgt", 0o555).stub(ps, ok).user()
	R("mkdir-permission-denied-nested", "<W>/tgt/a/b", "COM3", "9600", "x").dir("tgt", 0o555).stub(ps, ok).user()
	R("mkdir-permission-denied-quotes-in-path", "<W>/it's here", "COM3", "9600", "x").dir("it's here", 0o555).stub(ps, ok).user()
	R("mkdir-permission-denied-utf8-locale", "<W>/café dir", "COM3", "9600", "x").dir("café dir", 0o555).withEnv("LC_ALL=C.UTF-8").stub(ps, ok).user()
	R("mkdir-permission-denied-utf8-in-lang", "<W>/tgt", "COM3", "9600", "x").dir("tgt", 0o555).withEnv("LC_ALL=", "LANG=C.UTF-8").stub(ps, ok).user()
	R("mkdir-permission-denied-lc-ctype-wins", "<W>/tgt", "COM3", "9600", "x").dir("tgt", 0o555).withEnv("LC_ALL=", "LC_CTYPE=C.UTF-8", "LANG=C").stub(ps, ok).user()
	R("mkdir-permission-denied-lc-all-c-wins", "<W>/tgt", "COM3", "9600", "x").dir("tgt", 0o555).withEnv("LC_ALL=C", "LC_CTYPE=C.UTF-8", "LANG=C.UTF-8").stub(ps, ok).user()
	// preservation fails after the run (exit 5): tee cannot create the file, the response still reaches stdout
	R("tee-permission-denied", base...).dir("tgt/sources/probes", 0o555).stub(ps, `printf 'hw output\n'`).user()
	// the file was written by tee (rc 0) and is gone when the run ends: the stat guard alone catches it
	// (the stub waits for the file: in the script tee and PowerShell start at the same time)
	R("evidence-file-vanishes-after-tee", base...).stub(ps, `i=0; set -- ./tgt/sources/probes/*.txt
while [ ! -e "$1" ] && [ $i -lt 400000 ]; do i=$((i+1)); set -- ./tgt/sources/probes/*.txt; done
printf 'x\n'; /bin/rm -f ./tgt/sources/probes/*.txt`)
	R("tee-permission-denied-rc-7", base...).dir("tgt/sources/probes", 0o555).stub(ps, `printf 'hw\n'; exit 7`).user()
	R("tee-permission-denied-spaces", "<W>/my target", "COM3", "9600", "x").dir("my target/sources/probes", 0o555).stub(ps, `printf 'hw\n'`).user()
	R("tee-permission-denied-apostrophe", "<W>/it's here", "COM3", "9600", "x").dir("it's here/sources/probes", 0o555).stub(ps, `printf 'hw\n'`).user()
	R("tee-permission-denied-utf8-path", "<W>/café dir", "COM3", "9600", "x").dir("café dir/sources/probes", 0o555).stub(ps, `printf 'hw\n'`).user()
	R("tee-permission-denied-utf8-path-utf8-locale", "<W>/café dir", "COM3", "9600", "x").dir("café dir/sources/probes", 0o555).withEnv("LC_ALL=C.UTF-8").stub(ps, `printf 'hw\n'`).user()
	R("tee-permission-denied-leading-tilde", "~tilde", "COM3", "9600", "x").dir("~tilde/sources/probes", 0o555).stub(ps, `printf 'hw\n'`).user()

	// ---- a binary the shell would run as a script but the kernel will not (declared divergence) -------------
	add(&scenario{name: "exec-noshebang-script-check", args: []string{"check"}, env: []string{"POWERSHELL_BIN=<W>/noshebang"}, legacyExec: true,
		setup: []func(*world){func(w *world) { w.file("noshebang", ok+"\n", 0o755) }},
		intended: &ran{Out: "", RC: 3, Err: "serial-console.sh: powershell.exe present but did not execute cleanly:\n" +
			"  serial-console.sh: <W>/noshebang: cannot execute binary file: Exec format error\n" +
			"serial-console.sh: cannot reach Windows PowerShell (<W>/noshebang).\n" +
			"  If this is 'exec format error', WSLInterop binfmt_misc was dropped. Re-register (root, inside WSL):\n" +
			"    sudo sh -c 'echo :WSLInterop:M::MZ::/init:PF > /proc/sys/fs/binfmt_misc/register'\n" +
			"  (clear a stale handler first: echo -1 > /proc/sys/fs/binfmt_misc/WSLInterop)\n"}})
	add(&scenario{name: "exec-noshebang-script-list", args: []string{"list"}, env: []string{"POWERSHELL_BIN=<W>/noshebang"}, legacyExec: true,
		setup: []func(*world){func(w *world) { w.file("noshebang", ok+"\n", 0o755) }},
		intended: &ran{Out: "== COM ports (System.IO.Ports.SerialPort::GetPortNames) ==\n", RC: 126,
			Err: "serial-console.sh: <W>/noshebang: cannot execute binary file: Exec format error\n"}})
	return l
}

func TestScenarioNamesAreUnique(t *testing.T) {
	seen := map[string]bool{}
	for _, s := range scenarios() {
		if seen[s.name] {
			t.Errorf("duplicate scenario name %q", s.name)
		}
		seen[s.name] = true
	}
	if len(seen) < 150 {
		t.Errorf("only %d scenarios: the table lost its breadth", len(seen))
	}
}
