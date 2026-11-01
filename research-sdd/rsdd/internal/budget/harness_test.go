package budget

import (
	"bytes"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// Shared harness of the budget tests: the frozen legacy oracle, the fixture copies, the PATH variants and the two runners
// (the frozen bash script, and the Go command dispatched through this domain's own Commands).
//
// Frozen oracle: testdata/legacy/verify-session-budget.sh is verify-session-budget.sh verbatim from origin/main 53ab1a12
// (the script as it stood before the port, kit issue #2446). Its sha256 is pinned below: a changed oracle fails
// TestLegacyOracleIsPinned before any comparison can pass against a drifted copy. Re-freeze only by a reviewed edit of both.

const legacySHA256 = "f35dada96b9e61ed1a4f1c434be82392eb146f52bf0ba55694f474853df37f6a"

var update = flag.Bool("update", false, "re-record testdata/golden from the frozen legacy script")

const (
	fixturesRel = "../../../toolbelt/tests/fixtures/verify-session-budget"
	piHelperRel = "../../../toolbelt/lib/session-budget-pi.mjs"
	piExtRel    = "../../../install/pi/research-sdd-hooks.ts"
	legacyRel   = "testdata/legacy/verify-session-budget.sh"
)

func abs(t testing.TB, rel string) string {
	t.Helper()
	p, err := filepath.Abs(rel)
	if err != nil {
		t.Fatal(err)
	}
	return p
}

func TestLegacyOracleIsPinned(t *testing.T) {
	b, err := os.ReadFile(legacyRel)
	if err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(b)
	if got := hex.EncodeToString(sum[:]); got != legacySHA256 {
		t.Fatalf("frozen oracle drifted: sha256 %s, pinned %s", got, legacySHA256)
	}
}

// bwrapOK reports whether an unprivileged bwrap can start here (the suite probed this once with `bwrap --ro-bind / / true`).
func bwrapOK() bool {
	p, err := exec.LookPath("bwrap")
	if err != nil {
		return false
	}
	if _, err := exec.LookPath("timeout"); err != nil {
		return false
	}
	return exec.Command(p, "--ro-bind", "/", "/", "true").Run() == nil
}

func nodeTS() bool {
	p, err := exec.LookPath("node")
	if err != nil {
		return false
	}
	out, err := exec.Command(p, "-p", "String(process.features.typescript)").Output()
	if err != nil {
		return false
	}
	v := strings.TrimSpace(string(out))
	return v != "" && v != "false" && v != "undefined"
}

// gateDecision is the sandbox/node gate (kit issue #2138): an unusable tool is a FAIL when CI demands it (REQUIRE=1) and a
// typed SKIP otherwise, never a silent pass.
func gateDecision(usable bool, require string) string {
	switch {
	case usable:
		return "run"
	case require == "1":
		return "fail"
	}
	return "skip"
}

// needBwrap gates a sandbox-dependent case on RSDD_REQUIRE_BWRAP.
func needBwrap(t *testing.T) {
	t.Helper()
	switch gateDecision(bwrapOK(), os.Getenv("RSDD_REQUIRE_BWRAP")) {
	case "fail":
		t.Fatal("RSDD_REQUIRE_BWRAP=1 but no usable unprivileged bwrap (sandbox cases would SKIP)")
	case "skip":
		t.Skip("no usable bwrap")
	}
}

// needNode gates a pi case on RSDD_REQUIRE_NODE_TS.
func needNode(t *testing.T) {
	t.Helper()
	switch gateDecision(nodeTS(), os.Getenv("RSDD_REQUIRE_NODE_TS")) {
	case "fail":
		t.Fatal("RSDD_REQUIRE_NODE_TS=1 but this node has no built-in TypeScript type stripping")
	case "skip":
		t.Skip("node has no built-in TypeScript type stripping")
	}
}

// scratch returns a fresh physical (symlink-resolved) directory; pad lengthens its name to show path-length dependence.
func scratch(t testing.TB, pad string) string {
	t.Helper()
	// A fixed-length random name: pi section sizes depend on the length of the paths the kit extension prints.
	var rnd [8]byte
	if _, err := rand.Read(rnd[:]); err != nil {
		t.Fatal(err)
	}
	d := filepath.Join(os.TempDir(), "bud"+pad+hex.EncodeToString(rnd[:]))
	if err := os.Mkdir(d, 0o700); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = filepath.WalkDir(d, func(p string, e os.DirEntry, err error) error {
			if e != nil && e.IsDir() {
				_ = os.Chmod(p, 0o700)
			}
			return nil
		})
		_ = os.RemoveAll(d)
	})
	r, err := filepath.EvalSymlinks(d)
	if err != nil {
		t.Fatal(err)
	}
	return r
}

func cpA(t testing.TB, src, dst string) {
	t.Helper()
	if out, err := exec.Command("cp", "-a", src, dst).CombinedOutput(); err != nil {
		t.Fatalf("cp -a %s %s: %v: %s", src, dst, err, out)
	}
}

func write(t testing.TB, path, content string, mode os.FileMode) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), mode); err != nil {
		t.Fatal(err)
	}
}

// mkbin builds a PATH directory holding symlinks to every tool the script and the stub hooks use, minus omit.
func mkbin(t testing.TB, dir string, omit ...string) {
	t.Helper()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
next:
	for _, tool := range strings.Fields("mktemp rm mkdir basename head cut tr wc cat sleep timeout jq bwrap cp date true env bash") {
		for _, o := range omit {
			if o == tool {
				continue next
			}
		}
		p, err := exec.LookPath(tool)
		if err != nil {
			continue
		}
		_ = os.Remove(filepath.Join(dir, tool))
		if err := os.Symlink(p, filepath.Join(dir, tool)); err != nil {
			t.Fatal(err)
		}
	}
}

// result is one run's observable behavior.
type result struct {
	out, err string
	code     int
}

func (r result) both() string { return r.out + r.err }

func codeOf(err error) int {
	if err == nil {
		return 0
	}
	var ee *exec.ExitError
	if errors.As(err, &ee) {
		if ws, ok := ee.Sys().(syscall.WaitStatus); ok && ws.Signaled() {
			return 128 + int(ws.Signal())
		}
		return ee.ExitCode()
	}
	return -1
}

// baseEnv is the caller environment of a run: the real one minus every variable that steers the instrument or
// would leak an agent socket, TMPDIR pointed into the scratch.
func baseEnv(tmp string) []string {
	var env []string
	for _, kv := range os.Environ() {
		k, _, _ := strings.Cut(kv, "=")
		switch {
		case strings.HasPrefix(k, "RSDD_"), strings.HasPrefix(k, "GENTLE_PI_"), k == "PI_CODING_AGENT_DIR",
			k == "SSH_AUTH_SOCK", k == "SSH_AGENT_PID", k == "GPG_AGENT_INFO", k == "DBUS_SESSION_BUS_ADDRESS",
			k == "TMPDIR", k == "LC_ALL", k == "RESEARCH_SDD_KIT":
			continue
		}
		env = append(env, kv)
	}
	return append(env, "TMPDIR="+tmp)
}

func withEnv(env []string, kv ...string) []string {
	out := append([]string(nil), env...)
	for _, e := range kv {
		k, _, _ := strings.Cut(e, "=")
		kept := out[:0:0]
		for _, o := range out {
			if !strings.HasPrefix(o, k+"=") {
				kept = append(kept, o)
			}
		}
		out = append(kept, e)
	}
	return out
}

// runGo dispatches the Go command through this domain's own Commands (a domain cannot import internal/commands).
func runGo(args []string, env []string, cwd string) result {
	var out, errb bytes.Buffer
	lookup := func(k string) string {
		v := ""
		for _, kv := range env {
			if rest, ok := strings.CutPrefix(kv, k+"="); ok {
				v = rest
			}
		}
		return v
	}
	s := cli.Stdio{
		In: strings.NewReader(""), Out: &out, Err: &errb,
		Env: lookup, Environ: func() []string { return env },
		Clock: func() time.Time { return time.Unix(0, 0) }, Cwd: cwd,
	}
	code := cli.Run(Commands, append([]string{"budget", "verify"}, args...), s)
	return result{out.String(), errb.String(), code}
}

// legacyKit lays the frozen script out as a toolbelt (<kit>/toolbelt/verify-session-budget.sh beside lib/session-budget-pi.mjs),
// so it finds its helper the way the real one does.
func legacyKit(t testing.TB, root string) string {
	t.Helper()
	tb := filepath.Join(root, "legacykit", "toolbelt")
	b, err := os.ReadFile(legacyRel)
	if err != nil {
		t.Fatal(err)
	}
	write(t, filepath.Join(tb, "verify-session-budget.sh"), string(b), 0o755)
	if err := os.MkdirAll(filepath.Join(tb, "lib"), 0o755); err != nil {
		t.Fatal(err)
	}
	cpA(t, abs(t, piHelperRel), filepath.Join(tb, "lib")+"/")
	return tb
}

// runLegacy runs the frozen script under bash with the same environment.
func runLegacy(t testing.TB, tb string, args []string, env []string, cwd string) result {
	t.Helper()
	bash, err := exec.LookPath("bash")
	if err != nil {
		t.Fatalf("bash is required for the differential test: %v", err)
	}
	cmd := exec.Command(bash, append([]string{filepath.Join(tb, "verify-session-budget.sh")}, args...)...)
	cmd.Dir, cmd.Env = cwd, env
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	err = cmd.Run()
	return result{out.String(), errb.String(), codeOf(err)}
}

func mustRealpath(t testing.TB, p string) string {
	t.Helper()
	r, err := filepath.EvalSymlinks(p)
	if err != nil {
		t.Fatal(err)
	}
	return r
}

// stubKit builds the eight-sweep stub kit the pi cases feed to the real kit extension.
func stubKit(t testing.TB, dir string) {
	t.Helper()
	for _, h := range strings.Fields("sweep-retros-hook sweep-audits-hook sweep-breakthroughs-hook verify-registry-hook verify-kit-clean-hook sweep-tools-hook verify-tool-catalog-hook verify-skill-drift-hook") {
		write(t, filepath.Join(dir, "toolbelt", h+".sh"),
			"#!/usr/bin/env bash\nprintf '{\"hookSpecificOutput\":{\"hookEventName\":\"SessionStart\",\"additionalContext\":\"%s\"}}' \"$(sleep \"${RSDD_STUB_SLEEP:-0}\"; head -c \"${RSDD_STUB_N:-100}\" /dev/zero | tr \"\\0\" k)\"\n", 0o755)
	}
}

func drain(r io.Reader) string { b, _ := io.ReadAll(r); return string(b) }

func hasFile(p string) bool { _, err := os.Stat(p); return err == nil }

var _ = fmt.Sprintf
