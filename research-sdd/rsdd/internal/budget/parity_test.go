package budget

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"
)

// Parity of `rsdd budget verify` with the frozen legacy script (testdata/legacy, sha-pinned in harness_test.go).
//
// Two checks over the same case table:
//   - TestParity runs the frozen script and the Go command live on the same fixture copy, same environment, and compares
//     stdout, stderr and exit code byte for byte (path normalised to @ROOT@, the scratch the run lives in);
//   - TestGolden compares the Go command to testdata/golden/<case>/{stdout,stderr,exit}, recorded from the frozen script
//     (`go test -run TestGolden -update` re-records; the recording runs the oracle twice under scratch roots of different
//     length and keeps a golden only when both agree, otherwise it writes a `diff-only` marker: the output depends on the path
//     length, so only the live comparison is meaningful).
// TestFrozenOutputs holds the Go output to the 11 pre-change outputs under fixtures/_frozen.

type pcase struct {
	name    string
	fixture string   // fixture directory copied to <root>/fix/<fixture> ("" = none)
	args    []string // "@T@" target dir, "@ROOT@" scratch root
	env     []string // extra KEY=VALUE; same placeholders plus @KIT@ (stub kit), @EXT@ (the real kit pi extension)
	to      string   // RSDD_BUDGET_HOOK_TIMEOUT ("" = 10)
	bin     string   // PATH variant, see pathFor
	bw      bool     // needs a usable bwrap
	node    bool     // needs node with type stripping
	loose   bool     // the kit extension's DEGRADED text embeds timing, so its character count wobbles by a few: compare shapes
	prep    func(t testing.TB, root, target string)
}

const piEnv = "RSDD_BUDGET_KIT=@KIT@"

func piCase(name, fixture string, extra ...string) pcase {
	return pcase{name: name, fixture: fixture, args: []string{"--harness", "pi", "@T@"}, to: "20", bw: true, node: true,
		env: append([]string{piEnv, "RSDD_BUDGET_PI_HOOKS=@EXT@", "RSDD_STUB_N=100"}, extra...)}
}

func notRoot(t testing.TB) {
	if os.Geteuid() == 0 {
		t.Skip("running as root: permission bits are bypassed")
	}
}

var cases = []pcase{
	// typed input states and usage errors: no sandbox needed
	{name: "empty", fixture: "empty"},
	{name: "absent", fixture: "absent"},
	{name: "badjson", fixture: "badjson"},
	{name: "usage-nodir", args: []string{"@ROOT@/no-such-dir"}},
	{name: "usage-noarg"},
	{name: "usage-twoargs", fixture: "empty", args: []string{"@T@", "@T@"}},
	{name: "usage-badharness", fixture: "pi-card", args: []string{"--harness", "nope", "@T@"}},
	{name: "usage-harness-novalue", args: []string{"--harness"}},
	{name: "usage-file-not-dir", fixture: "empty", args: []string{"@T@/.claude/settings.json"}},
	{name: "nojq", fixture: "mixed", bin: "nojq"},
	{name: "nobwrap", fixture: "mixed", bin: "nobwrap"},
	{name: "badbwrap", fixture: "mixed", bin: "badbwrap"},
	{name: "garbage-timeout-env", fixture: "empty", to: "x0"},
	// sandboxed measurements
	{name: "mixed", fixture: "mixed", bw: true},
	{name: "harness-claude-explicit", fixture: "mixed", args: []string{"--harness", "claude", "@T@"}, bw: true},
	{name: "degraded", fixture: "degraded", to: "1", bw: true},
	{name: "over", fixture: "over", bw: true},
	{name: "sources", fixture: "sources", bw: true},
	{name: "newline", fixture: "newline", bw: true},
	{name: "timeouts", fixture: "timeouts", bw: true},
	{name: "matchers", fixture: "matchers", bw: true},
	{name: "partialmix", fixture: "partialmix", bw: true},
	{name: "capped", fixture: "capped", to: "1", bw: true},
	{name: "fresh", fixture: "fresh", bw: true},
	{name: "utf8", fixture: "utf8", bw: true},
	{name: "nowc", fixture: "utf8", bin: "nowc", bw: true},
	{name: "unreadable-copy", fixture: "utf8", bw: true, prep: func(t testing.TB, _, target string) {
		notRoot(t)
		p := filepath.Join(target, ".claude", "unreadable")
		write(t, p, "", 0o000)
		if err := os.Chmod(p, 0o000); err != nil {
			t.Fatal(err)
		}
	}},
	{name: "escape", fixture: "escape", bw: true, env: []string{"HOME=@ROOT@/home", "RSDD_ESCAPE_TMP=@ROOT@/escape-marker",
		"SSH_AUTH_SOCK=/tmp/agent.sock", "SSH_AGENT_PID=4242", "DBUS_SESSION_BUS_ADDRESS=unix:path=/x"}},
	// pi / gentle-shell harness
	{name: "pi-nonode", fixture: "pi-card", args: []string{"--harness", "pi", "@T@"}, bin: "nonode", env: []string{piEnv, "RSDD_BUDGET_PI_HOOKS=@EXT@"}},
	{name: "pi-nots", fixture: "pi-card", args: []string{"--harness", "pi", "@T@"}, bin: "nots", env: []string{piEnv, "RSDD_BUDGET_PI_HOOKS=@EXT@"}},
	{name: "pi-ext-missing", fixture: "pi-card", args: []string{"--harness", "pi", "@T@"}, node: true, env: []string{piEnv, "RSDD_BUDGET_PI_HOOKS=@ROOT@/nope.ts"}},
	{name: "pi-helper-missing", fixture: "pi-card", args: []string{"--harness", "pi", "@T@"}, node: true, bin: "nohelper", env: []string{piEnv, "RSDD_BUDGET_PI_HOOKS=@EXT@"}},
	{name: "pi-nobwrap", fixture: "pi-card", args: []string{"--harness", "pi", "@T@"}, bin: "pinobwrap", node: true, env: []string{piEnv, "RSDD_BUDGET_PI_HOOKS=@EXT@"}},
	piCase("pi-card", "pi-card"),
	piCase("pi-big", "pi-big", "RSDD_STUB_N=1200"),
	piCase("pi-none", "pi-none"),
	piCase("pi-broken", "pi-broken"),
	func() pcase {
		c := piCase("pi-kit-missing", "pi-none", "RSDD_BUDGET_KIT=@ROOT@/no-such-kit")
		c.loose = true
		return c
	}(),
	func() pcase {
		c := piCase("pi-slow-sweeps", "pi-none", "RSDD_STUB_SLEEP=4")
		c.to, c.loose = "1", true
		return c
	}(),
	piCase("pi-ambient-env", "pi-card", "GENTLE_PI_AGENTS_CHILD=1", "RSDD_PI_HOOKS=off"),
	func() pcase {
		c := piCase("pi-both", "pi-card")
		c.args = []string{"--harness", "both", "@T@"}
		return c
	}(),
	piCase("pi-routes", "pi-routes"),
	piCase("pi-exit", "pi-exit"),
	func() pcase { c := piCase("pi-hang", "pi-hang"); c.to = "1"; return c }(),
	piCase("pi-sub", "pi-sub"),
	func() pcase {
		c := piCase("pi-nodot-git", "pi-nodot")
		c.prep = func(t testing.TB, _, target string) {
			for _, a := range [][]string{{"init", "-q"}, {"add", "-A"}, {"-c", "user.name=t", "-c", "user.email=t@t", "-c", "gc.auto=0", "-c", "maintenance.auto=false", "commit", "-q", "-m", "init"}} {
				if out, err := exec.Command("git", append([]string{"-C", target}, a...)...).CombinedOutput(); err != nil {
					t.Fatalf("git %v: %v: %s", a, err, out)
				}
			}
		}
		return c
	}(),
	piCase("pi-evil", "pi-evil", "RSDD_TEST_CANARY=@ROOT@/canary-evil"),
	func() pcase {
		c := piCase("pi-forged-record", "pi-none", "RSDD_TEST_CANARY=@ROOT@/canary-forge")
		c.bin = "forge"
		return c
	}(),
}

// pathFor builds the PATH of a variant under root and returns the variant's PATH value ("" = the caller's own).
func pathFor(t testing.TB, root, variant string) string {
	t.Helper()
	b := filepath.Join(root, "bin-"+variant)
	switch variant {
	case "":
		return ""
	case "nojq":
		mkbin(t, b, "jq")
	case "nobwrap", "pinobwrap":
		mkbin(t, b, "bwrap")
		if variant == "pinobwrap" {
			if p, err := exec.LookPath("node"); err == nil {
				_ = os.Symlink(p, filepath.Join(b, "node"))
			}
		}
	case "badbwrap":
		mkbin(t, b, "bwrap")
		write(t, filepath.Join(b, "bwrap"), "#!/bin/sh\necho \"bwrap: No permissions to create new namespace\" >&2\nexit 1\n", 0o755)
	case "nowc":
		mkbin(t, b, "wc")
		write(t, filepath.Join(b, "wc"), "#!/bin/sh\necho 2\n", 0o755)
	case "nonode":
		mkbin(t, b)
	case "nots":
		mkbin(t, b)
		write(t, filepath.Join(b, "node"), "#!/bin/sh\necho false\n", 0o755)
	case "nohelper":
		return os.Getenv("PATH")
	case "forge":
		write(t, filepath.Join(b, "node"), drain(mustOpen(t, abs(t, fixturesRel+"/_shims/forge-node.sh"))), 0o755)
		return b + ":" + os.Getenv("PATH")
	default:
		t.Fatalf("unknown PATH variant %q", variant)
	}
	return b
}

func mustOpen(t testing.TB, p string) *os.File {
	t.Helper()
	f, err := os.Open(p)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = f.Close() })
	return f
}

// prepared is one case laid out in a fresh scratch root, ready to run.
type prepared struct {
	root, target, toolbelt string
	args, env              []string
}

func (c pcase) prepare(t testing.TB, pad string) prepared {
	t.Helper()
	root := scratch(t, pad)
	tmp := filepath.Join(root, "tmp")
	for _, d := range []string{tmp, filepath.Join(root, "home")} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	p := prepared{root: root, toolbelt: legacyKit(t, root)}
	if c.fixture != "" {
		fix := filepath.Join(root, "fix")
		if err := os.MkdirAll(fix, 0o755); err != nil {
			t.Fatal(err)
		}
		cpA(t, abs(t, fixturesRel+"/"+c.fixture), fix+"/")
		p.target = filepath.Join(fix, c.fixture)
	}
	if c.bin == "nohelper" {
		_ = os.RemoveAll(filepath.Join(p.toolbelt, "lib"))
	}
	kit := filepath.Join(root, "stubkit")
	stubKit(t, kit)
	sub := strings.NewReplacer("@T@", p.target, "@ROOT@", root, "@KIT@", kit, "@EXT@", abs(t, piExtRel))
	for _, a := range c.args {
		p.args = append(p.args, sub.Replace(a))
	}
	if c.args == nil && c.fixture != "" {
		p.args = []string{p.target}
	}
	to := c.to
	if to == "" {
		to = "10"
	}
	env := withEnv(baseEnv(tmp), "RSDD_BUDGET_HOOK_TIMEOUT="+to)
	if pv := pathFor(t, root, c.bin); pv != "" {
		env = withEnv(env, "PATH="+pv)
	}
	if c.bin == "forge" {
		if n, err := exec.LookPath("node"); err == nil {
			env = withEnv(env, "RSDD_TEST_REALNODE="+n)
		}
	}
	for _, e := range c.env {
		env = withEnv(env, sub.Replace(e))
	}
	p.env = env
	if c.prep != nil {
		c.prep(t, root, p.target)
	}
	return p
}

func (c pcase) gate(t *testing.T) {
	t.Helper()
	if c.bw {
		needBwrap(t)
	}
	if c.node {
		needNode(t)
	}
}

func (c pcase) runLegacyAt(t *testing.T, pad string) (result, string) {
	p := c.prepare(t, pad)
	return runLegacy(t, p.toolbelt, p.args, p.env, p.root), p.root
}

func (c pcase) runGoAt(t *testing.T, pad string) (result, string) {
	p := c.prepare(t, pad)
	return runGo(append([]string{"--toolbelt", p.toolbelt}, p.args...), p.env, p.root), p.root
}

func norm(r result, root string) result {
	f := func(s string) string { return strings.ReplaceAll(s, root, "@ROOT@") }
	return result{f(r.out), f(r.err), r.code}
}

var charCounts = regexp.MustCompile(`chars=[0-9]+|aggregate\[pi\]: [0-9]+ chars`)

// normFor additionally blanks character counts for the cases whose kit-extension text embeds timing.
func (c pcase) normFor(r result, root string) result {
	r = norm(r, root)
	if c.loose {
		r.out = charCounts.ReplaceAllString(r.out, "chars=N")
	}
	return r
}

func TestParity(t *testing.T) {
	if !differentialOn {
		t.Skip("legacy differential off under the nodiff tag (mutation run); goldens and behaviour tests still run")
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			t.Parallel()
			c.gate(t)
			l, lroot := c.runLegacyAt(t, "")
			g, groot := c.runGoAt(t, "")
			l, g = c.normFor(l, lroot), c.normFor(g, groot)
			if g != l {
				t.Errorf("Go differs from the frozen legacy script\n--- legacy (exit %d)\nstdout:\n%s\nstderr:\n%s\n--- go (exit %d)\nstdout:\n%s\nstderr:\n%s",
					l.code, l.out, l.err, g.code, g.out, g.err)
			}
		})
	}
}

const goldenDir = "testdata/golden"

func TestGolden(t *testing.T) {
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			t.Parallel()
			c.gate(t)
			dir := filepath.Join(goldenDir, c.name)
			if *update {
				l1, r1 := c.runLegacyAt(t, "")
				l2, r2 := c.runLegacyAt(t, "XXXXXXXXXXXXXXXX")
				a, b := norm(l1, r1), norm(l2, r2)
				_ = os.RemoveAll(dir)
				if a != b {
					write(t, filepath.Join(dir, "diff-only"), "the output depends on the length of the scratch path; only the live comparison in TestParity applies\n", 0o644)
					return
				}
				write(t, filepath.Join(dir, "stdout"), a.out, 0o644)
				write(t, filepath.Join(dir, "stderr"), a.err, 0o644)
				write(t, filepath.Join(dir, "exit"), strconv.Itoa(a.code)+"\n", 0o644)
				return
			}
			if hasFile(filepath.Join(dir, "diff-only")) {
				t.Log("path-length dependent output: compared live against the frozen script in TestParity")
				return
			}
			want := readGolden(t, dir)
			g, root := c.runGoAt(t, "")
			if got := norm(g, root); got != want {
				t.Errorf("Go output differs from the golden %s\n--- want (exit %d)\nstdout:\n%s\nstderr:\n%s\n--- got (exit %d)\nstdout:\n%s\nstderr:\n%s",
					dir, want.code, want.out, want.err, got.code, got.out, got.err)
			}
		})
	}
}

func readGolden(t testing.TB, dir string) result {
	t.Helper()
	rd := func(n string) string {
		b, err := os.ReadFile(filepath.Join(dir, n))
		if err != nil {
			t.Fatalf("golden file missing (a case without a golden or a diff-only marker is a failure, never a skip): %v", err)
		}
		return string(b)
	}
	code, err := strconv.Atoi(strings.TrimSpace(rd("exit")))
	if err != nil {
		t.Fatal(err)
	}
	return result{rd("stdout"), rd("stderr"), code}
}

// Every case has either a complete golden or a diff-only marker, and no golden directory is orphaned.
func TestGoldenCoverage(t *testing.T) {
	if *update {
		t.Skip("recording")
	}
	names := map[string]bool{}
	for _, c := range cases {
		names[c.name] = true
		dir := filepath.Join(goldenDir, c.name)
		if hasFile(filepath.Join(dir, "diff-only")) {
			continue
		}
		for _, f := range []string{"stdout", "stderr", "exit"} {
			if !hasFile(filepath.Join(dir, f)) {
				t.Errorf("case %s: golden file %s is missing", c.name, f)
			}
		}
	}
	ents, err := os.ReadDir(goldenDir)
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range ents {
		if !names[e.Name()] {
			t.Errorf("orphaned golden directory %s", e.Name())
		}
	}
}

// The 11 outputs frozen before the pi harness was added (fixtures/_frozen) stay byte-identical on the default (Claude) path.
// The frozen files carry the fixture path as @FIX@ and were produced with a 10 s hook cap; like the old suite's `$(...)` they
// compare without trailing newlines.
func TestFrozenOutputs(t *testing.T) {
	ents, err := os.ReadDir(abs(t, fixturesRel+"/_frozen"))
	if err != nil {
		t.Fatal(err)
	}
	if len(ents) != 11 {
		t.Fatalf("expected the 11 frozen outputs, found %d", len(ents))
	}
	for _, e := range ents {
		name := strings.TrimSuffix(e.Name(), ".out")
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			if name != "empty" && name != "absent" && name != "badjson" {
				needBwrap(t)
			}
			want, err := os.ReadFile(abs(t, fixturesRel+"/_frozen/"+e.Name()))
			if err != nil {
				t.Fatal(err)
			}
			c := pcase{name: name, fixture: name}
			p := c.prepare(t, "")
			r := runGo(append([]string{"--toolbelt", p.toolbelt}, p.args...), p.env, p.root)
			got := strings.ReplaceAll(r.out+r.err, filepath.Dir(p.target), "@FIX@")
			if strings.TrimRight(got, "\n") != strings.TrimRight(string(want), "\n") {
				t.Errorf("default output on %q differs from the frozen pre-change output:\n--- frozen\n%s\n--- got\n%s", name, want, got)
			}
			if r.code != 0 {
				t.Errorf("exit %d, want 0", r.code)
			}
		})
	}
}

var _ = fmt.Sprint
