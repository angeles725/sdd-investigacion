//go:build !nodiff

package budget

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// Differential tests, pi / gentle-shell harness (kit issue #2174): the kit extension research-sdd-hooks.ts runs
// for real against a stub kit (eight sweep hooks printing RSDD_STUB_N characters); fixture targets add
// .pi/extensions sections of known size. The records come from lib/session-budget-pi.mjs, which both
// implementations run unchanged.

func TestDifferentialPiDegradedWithoutSandbox(t *testing.T) {
	sb := newSbx(t)
	card := sb.target("pi-card")
	t.Run("node missing", func(t *testing.T) {
		o := sb.same("no node", sb.piEnv("PATH="+sb.mkbin("pbin-nonode", "node")), "--harness", "pi", card)
		if !has(o.stdout, `pi: DEGRADED — node unavailable`) || has(o.stdout, `aggregate\[pi\]`) {
			t.Errorf("got %q", o.stdout)
		}
	})
	t.Run("node without type stripping", func(t *testing.T) {
		bin := sb.mkbin("pbin-nots", "node")
		sb.shim(bin, "node", "#!/bin/sh\necho false\n")
		o := sb.same("no ts", sb.piEnv("PATH="+bin), "--harness", "pi", card)
		if !has(o.stdout, `pi: DEGRADED — node .*no built-in TypeScript type stripping`) || has(o.stdout, `aggregate\[pi\]`) {
			t.Errorf("got %q", o.stdout)
		}
	})
	t.Run("kit extension and helper not found", func(t *testing.T) {
		needTS(t)
		sb.same("no extension", sb.piEnv("RSDD_BUDGET_PI_HOOKS="+sb.root+"/nope.ts"), "--harness", "pi", card)
		lib := filepath.Join(sb.toolbelt, "lib")
		target, _ := os.Readlink(lib)
		_ = os.Remove(lib)
		defer func() { _ = os.Symlink(target, lib) }()
		o := sb.same("no helper", sb.piEnv(), "--harness", "pi", card)
		if !has(o.stdout, `pi: DEGRADED — measuring helper not found: `+lib+`/session-budget-pi.mjs`) {
			t.Errorf("got %q", o.stdout)
		}
	})
	t.Run("bwrap and timeout missing, bwrap broken", func(t *testing.T) {
		needTS(t)
		o := sb.same("no bwrap", sb.piEnv("PATH="+sb.mkbin("pbin-nobwrap", "bwrap")), "--harness", "pi", card)
		if !has(o.stdout, `pi: DEGRADED — no-sandbox: bwrap not installed`) || has(o.stdout, `aggregate\[pi\]`) {
			t.Errorf("got %q", o.stdout)
		}
		sb.same("no timeout", sb.piEnv("PATH="+sb.mkbin("pbin-notimeout", "timeout")), "--harness", "pi", card)
		bad := sb.mkbin("pbin-badbwrap", "bwrap")
		sb.shim(bad, "bwrap", "#!/bin/sh\necho 'bwrap: No permissions to create new namespace' >&2\nexit 1\n")
		sb.same("bad bwrap", sb.piEnv("PATH="+bad), "--harness", "pi", card)
	})
	t.Run("a harness that prints nothing is a typed DEGRADED, not 0 chars", func(t *testing.T) {
		needTS(t)
		bin := sb.mkbin("pbin-silent", "bwrap")
		sb.shim(bin, "bwrap", "#!/bin/sh\nif [ \"$*\" = \"--ro-bind / / true\" ]; then exit 0; fi\nexit 0\n")
		o := sb.same("silent harness", sb.piEnv("PATH="+bin), "--harness", "pi", card)
		if !has(o.stdout, `pi: DEGRADED — extension harness produced no records`) || has(o.stdout, `aggregate\[pi\]`) {
			t.Errorf("got %q", o.stdout)
		}
		fail := sb.mkbin("pbin-exit7", "bwrap")
		sb.shim(fail, "bwrap", "#!/bin/sh\nif [ \"$*\" = \"--ro-bind / / true\" ]; then exit 0; fi\necho 'harness went away' >&2\nexit 7\n")
		o = sb.same("harness exit", sb.piEnv("PATH="+fail), "--harness", "pi", card)
		if !has(o.stdout, `extension harness exit 7 \(harness went away\)`) {
			t.Errorf("got %q", o.stdout)
		}
	})
	t.Run("temp dir cannot be created", func(t *testing.T) {
		needTS(t)
		// a fake bwrap that passes the probe: the temp-dir check comes after the sandbox check, so a host without
		// bwrap (the CI rsdd-go job) would otherwise stop at "no-sandbox" and never reach it
		bin := sb.mkbin("pbin-tmpdir", "bwrap")
		sb.shim(bin, "bwrap", "#!/bin/sh\nif [ \"$*\" = \"--ro-bind / / true\" ]; then exit 0; fi\nexit 0\n")
		env := sb.piEnv("TMPDIR="+sb.root+"/no/such/tmp", "PATH="+bin)
		l, g := sb.legacy(env, "--harness", "pi", card), sb.golang(env, "--harness", "pi", card)
		if l.stdout != g.stdout || l.rc != g.rc || !has(g.stdout, `pi: DEGRADED — cannot create a temp dir`) {
			t.Errorf("legacy %+v\n    go %+v", l, g)
		}
	})
}

func TestDifferentialPiContainmentArgv(t *testing.T) {
	needNodeTS(t)
	sb := newSbx(t)
	logPath := filepath.Join(sb.root, "pishim.log")
	bin := sb.mkbin("pbin-shim", "bwrap")
	sb.shim(bin, "bwrap", "#!/bin/sh\nif [ \"$*\" = \"--ro-bind / / true\" ]; then exit 0; fi\n{ for a in \"$@\"; do printf \"%s\\n\" \"$a\"; done; echo \"--END--\"; } >> \"$RSDD_SHIM_LOG\"\nexit 0\n")
	env := sb.piEnv("PATH="+bin, "RSDD_SHIM_LOG="+logPath)
	for _, name := range []string{"pi-card", "pi-nodot", "pi-sub"} {
		d := sb.target(name)
		_ = os.WriteFile(logPath, nil, 0o644)
		want := sb.legacy(env, "--harness", "pi", d)
		wantLog, _ := os.ReadFile(logPath)
		_ = os.WriteFile(logPath, nil, 0o644)
		got := sb.golang(env, "--harness", "pi", d)
		gotLog, _ := os.ReadFile(logPath)
		w, g := workDir.ReplaceAllString(string(wantLog), "tmp.X"), workDir.ReplaceAllString(string(gotLog), "tmp.X")
		if w != g || strings.Count(g, "--END--") != 1 {
			t.Errorf("%s: the pi run must be ONE bwrap invocation with the same argv:\n--- legacy\n%s\n--- go\n%s", name, w, g)
		}
		if want != got {
			t.Errorf("%s: output differs: %+v vs %+v", name, want, got)
		}
	}
	argv := strings.Split(strings.TrimSpace(workDir.ReplaceAllString(readFile(t, logPath), "tmp.X")), "\n")
	for _, w := range []string{"--unshare-pid", "--unshare-net", "--unshare-ipc", "--new-session", "--die-with-parent"} {
		if !contains(argv, w) {
			t.Errorf("pi run lacks %s", w)
		}
	}
	for _, v := range []string{"SSH_AUTH_SOCK", "SSH_AGENT_PID", "GPG_AGENT_INFO", "DBUS_SESSION_BUS_ADDRESS", "XDG_RUNTIME_DIR", "GENTLE_PI_AGENTS_CHILD", "PI_CODING_AGENT_DIR", "RSDD_PI_HOOKS"} {
		if !seq(argv, "--unsetenv", v) {
			t.Errorf("pi run does not unset %s", v)
		}
	}
}

func readFile(t *testing.T, p string) string {
	t.Helper()
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func TestDifferentialPiMeasurements(t *testing.T) {
	needNodeTS(t)
	sb := newSbx(t)
	pi := func(name string, extra []string, target string) observed {
		t.Helper()
		return sb.same(name, sb.piEnv(extra...), "--harness", "pi", target)
	}
	t.Run("card: kit section plus a 2500-char target section", func(t *testing.T) {
		before := snapshot(t, sb.target("pi-card"))
		o := pi("pi-card", nil, sb.target("pi-card"))
		for _, re := range []string{`^harness: pi `, `^limits: fake pi `, `^section\[card.ts\] card-section chars=2500 status=ok`,
			`^section\[research-sdd-hooks.ts\] research-sdd-session chars=[1-9][0-9]* status=ok`, `^aggregate\[pi\]: [0-9]+ chars \(budget < 8000\) OK$`, `^state: ok \(2 pi sections from 2 extensions\)`} {
			if !has(o.stdout, re) {
				t.Errorf("no line /%s/ in\n%s", re, o.stdout)
			}
		}
		if snapshot(t, sb.target("pi-card")) != before {
			t.Error("the target changed: writes must land in the sandbox copy")
		}
	})
	t.Run("the pi run removes its temp dir", func(t *testing.T) {
		leak := filepath.Join(sb.root, "leak")
		_ = os.MkdirAll(leak, 0o755)
		o := sb.golang(sb.piEnv("TMPDIR="+leak), "--harness", "pi", sb.target("pi-card"))
		ents, _ := os.ReadDir(leak)
		if len(ents) != 0 || !has(o.stdout, `^aggregate\[pi\]: `) {
			t.Errorf("temp dir left behind (%d entries) or no aggregate: %q", len(ents), o.stdout)
		}
	})
	t.Run("over budget", func(t *testing.T) {
		o := pi("pi-big", []string{"RSDD_STUB_N=1200"}, sb.target("pi-big"))
		if !has(o.stdout, `^aggregate\[pi\]: [0-9]+ chars \(budget < 8000\) OVER BUDGET$`) || !has(o.stdout, `section\[big.ts\] big-section chars=6000`) {
			t.Errorf("got %q", o.stdout)
		}
	})
	for _, name := range []string{"pi-none", "pi-broken", "pi-routes", "pi-exit", "pi-sub"} {
		t.Run(name, func(t *testing.T) { pi(name, nil, sb.target(name)) })
	}
	t.Run("a hanging extension has its own degraded line", func(t *testing.T) {
		o := pi("pi-hang", []string{"RSDD_BUDGET_HOOK_TIMEOUT=1"}, sb.target("pi-hang"))
		if !has(o.stdout, `^ext\[hang.ts\] status=degraded\(before_agent_start failed: timed out`) || has(o.stdout, `pi: DEGRADED`) {
			t.Errorf("got %q", o.stdout)
		}
	})
	t.Run("an unresolvable kit and slow sweeps are measured but partial", func(t *testing.T) {
		pi("kit missing", []string{"RSDD_BUDGET_KIT=" + sb.root + "/no-such-kit"}, sb.target("pi-none"))
		pi("slow sweeps", []string{"RSDD_STUB_SLEEP=4", "RSDD_BUDGET_HOOK_TIMEOUT=1"}, sb.target("pi-none"))
	})
	t.Run("the caller's GENTLE_PI_AGENTS_CHILD / RSDD_PI_HOOKS do not turn the kit extension off", func(t *testing.T) {
		o := pi("ambient env", []string{"GENTLE_PI_AGENTS_CHILD=1", "RSDD_PI_HOOKS=off"}, sb.target("pi-card"))
		if !has(o.stdout, `section\[research-sdd-hooks.ts\] research-sdd-session chars=[1-9]`) {
			t.Errorf("got %q", o.stdout)
		}
	})
	t.Run("--harness both is the Claude report then the pi report", func(t *testing.T) {
		o := sb.same("both", sb.piEnv(), "--harness", "both", sb.target("pi-card"))
		if !has(o.stdout, `^state: absent-input`) || !has(o.stdout, `^aggregate\[pi\]: `) {
			t.Errorf("got %q", o.stdout)
		}
		sb.same("both with hooks", sb.piEnv(), "--harness", "both", sb.target("mixed"))
	})
	t.Run("a corpus target with no .claude is measured like one with a copy bound", func(t *testing.T) {
		d := filepath.Join(sb.root, "nodot-git")
		sb.cp(sb.target("pi-nodot")+"/.", d)
		for _, args := range [][]string{{"init", "-q"}, {"add", "-A"}, {"-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "init"}} {
			if out, err := exec.Command("git", append([]string{"-C", d}, args...)...).CombinedOutput(); err != nil {
				t.Fatalf("git %v: %v %s", args, err, out)
			}
		}
		before := snapshot(t, d)
		o := pi("nodot", nil, d)
		if !has(o.stdout, `section\[research-sdd-hooks.ts\] research-sdd-session chars=[1-9][0-9]* status=ok`) || !has(o.stdout, `^state: ok`) {
			t.Errorf("got %q", o.stdout)
		}
		if snapshot(t, d) != before {
			t.Error("the target changed")
		}
		if _, err := os.Stat(filepath.Join(d, ".claude")); err == nil {
			t.Error("a .claude appeared in the target")
		}
	})
	t.Run("the helper channel is authenticated: forged records run nothing and are not believed", func(t *testing.T) {
		canary := filepath.Join(sb.root, "canary-evil")
		o := pi("pi-evil", []string{"RSDD_TEST_CANARY=" + canary}, sb.target("pi-evil"))
		if _, err := os.Stat(canary); err == nil {
			t.Error("a forged record was evaluated")
		}
		if has(o.stdout, `section\[evil.ts\]`) || !has(o.stdout, `^harness: degraded\([0-9]+ unauthenticated or malformed record`) {
			t.Errorf("got %q", o.stdout)
		}
		// Even a record with the CORRECT nonce is validated before any arithmetic.
		canary2 := filepath.Join(sb.root, "canary-forge")
		node, _ := exec.LookPath("node")
		shimDir := filepath.Join(sb.root, "shim-forge-node")
		src := readFile(t, filepath.Join(fixturesRel, "_shims", "forge-node.sh"))
		sb.shim(shimDir, "node", src)
		o = pi("forged node", []string{"RSDD_TEST_CANARY=" + canary2, "RSDD_TEST_REALNODE=" + node, "PATH=" + shimDir + ":" + os.Getenv("PATH")}, sb.target("pi-none"))
		if _, err := os.Stat(canary2); err == nil {
			t.Error("a record with the correct nonce was evaluated")
		}
		if !has(o.stdout, `^harness: degraded\(1 unauthenticated or malformed record`) {
			t.Errorf("got %q", o.stdout)
		}
	})
}
