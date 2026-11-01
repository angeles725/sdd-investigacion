package skilldrift

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// Shared harness of the skilldrift tests: the frozen legacy oracle, the staged kits, the two runners (the frozen bash script
// and the Go command run in process) and the normalisation that makes their output comparable.
//
// Frozen oracle: testdata/legacy holds verify-skill-drift.sh and verify-skill-drift-hook.sh verbatim from origin/main 73c79729
// (the scripts as they stood before the port, kit issue #2365). Their sha256 is pinned below: a changed oracle fails
// TestLegacyOraclesArePinned before any comparison can pass against a drifted copy. Re-freeze only by a reviewed edit of both.

const (
	legacyDriftSHA = "9e4fc3011315967e5558e969bd83852d18deb5fd037b64423c1676d8398798a0"
	legacyHookSHA  = "0108aeb934f8e9e8a7fb7e4e7a5c255ac80ef6a64ac8a8f8b3b4add1de863c46"
	legacyDriftRel = "testdata/legacy/verify-skill-drift.sh"
	legacyHookRel  = "testdata/legacy/verify-skill-drift-hook.sh"
)

var update = flag.Bool("update", false, "re-record testdata/golden from the frozen legacy scripts")

func TestLegacyOraclesArePinned(t *testing.T) {
	for rel, want := range map[string]string{legacyDriftRel: legacyDriftSHA, legacyHookRel: legacyHookSHA} {
		b, err := os.ReadFile(rel)
		if err != nil {
			t.Fatal(err)
		}
		sum := sha256.Sum256(b)
		if got := hex.EncodeToString(sum[:]); got != want {
			t.Fatalf("frozen oracle %s drifted: sha256 %s, pinned %s", rel, got, want)
		}
	}
}

func absPath(t testing.TB, rel string) string {
	t.Helper()
	p, err := filepath.Abs(rel)
	if err != nil {
		t.Fatal(err)
	}
	return p
}

// liveKit is the research-sdd directory of the checkout under test.
func liveKit(t testing.TB) string {
	t.Helper()
	p, err := filepath.EvalSymlinks(absPath(t, "../../../.."))
	if err != nil {
		t.Fatal(err)
	}
	return p
}

// scratch returns a fresh physical directory removed (permissions restored first) when the test ends.
func scratch(t testing.TB) string {
	t.Helper()
	d, err := os.MkdirTemp("", "skd")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { removeAll(d) })
	r, err := filepath.EvalSymlinks(d)
	if err != nil {
		t.Fatal(err)
	}
	return r
}

func removeAll(d string) {
	_ = filepath.WalkDir(d, func(p string, e os.DirEntry, err error) error {
		if e != nil && e.IsDir() {
			_ = os.Chmod(p, 0o700)
		}
		return nil
	})
	_ = os.RemoveAll(d)
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

func readFile(t testing.TB, path string) string {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func copyFile(t testing.TB, src, dst string, mode os.FileMode) {
	t.Helper()
	write(t, dst, readFile(t, src), mode)
}

func cpA(t testing.TB, src, dst string) {
	t.Helper()
	if out, err := exec.Command("cp", "-a", src, dst).CombinedOutput(); err != nil {
		t.Fatalf("cp -a %s %s: %v: %s", src, dst, err, out)
	}
}

func symlink(t testing.TB, target, link string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(link), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, link); err != nil {
		t.Fatal(err)
	}
}

func notRoot(t testing.TB) {
	t.Helper()
	if os.Geteuid() == 0 {
		t.Skip("running as root: permission bits are bypassed")
	}
}

func needTool(t testing.TB, name, requireEnv string) {
	t.Helper()
	if _, err := exec.LookPath(name); err == nil {
		return
	}
	if os.Getenv(requireEnv) == "1" {
		t.Fatalf("%s=1 but %s is not on PATH (the case would SKIP)", requireEnv, name)
	}
	t.Skipf("%s not on PATH", name)
}

// ---- worlds: one scratch tree per case, holding the staged kit, the home and the TMPDIR of the run ------------------------

type world struct {
	t    testing.TB
	root string // scratch root
	tb   string // toolbelt directory the commands run from (physical)
	home string // the --home / HOME directory
	tmp  string // TMPDIR of the run; must be empty afterwards
}

func newWorld(t testing.TB, kit string) *world {
	t.Helper()
	w := &world{t: t, root: scratch(t)}
	w.home = filepath.Join(w.root, "home")
	w.tmp = filepath.Join(w.root, "tmp")
	for _, d := range []string{w.home, w.tmp} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	w.tb = stageKit(t, filepath.Join(w.root, "kit"), kit)
	return w
}

func (w *world) sub(s string) string {
	return strings.NewReplacer("@ROOT@", w.root, "@HOME@", w.home, "@TB@", w.tb, "@TMP@", w.tmp, "@FIX@", fixRootPath()).Replace(s)
}

// stageKit builds <dir>/toolbelt (holding both frozen scripts) and returns its physical path. Variants:
//
//	real        a toolbelt whose install/ and lib/ link to the live kit, so the kit the scripts resolve IS the live checkout
//	two         a mini kit with the two-source fixture adapters.sh (no profile support)
//	noadapters  a mini kit with install/ but no adapters.sh
//	noinstall   a toolbelt with no install/ at all
//	nosrc       a mini kit with the real adapters.sh and no skills/ (the kit source is missing)
//	rfail       a mini kit whose render-profile.sh fails after printing to both streams
//	rnoexec     a mini kit whose render-profile.sh exists but is not executable
//	norender    a mini kit with profiles but no render-profile.sh
//	nopi        a mini kit whose adapters.sh drops gentle-shell from RESEARCH_SDD_HARNESSES
//	stub        the real variant with verify-skill-drift.sh replaced by the drift stub (hook cases)
func stageKit(t testing.TB, dir, variant string) string {
	t.Helper()
	live := liveKit(t)
	tb := filepath.Join(dir, "toolbelt")
	if variant == "" {
		variant = "real"
	}
	copyFile(t, absPath(t, legacyDriftRel), filepath.Join(tb, "verify-skill-drift.sh"), 0o755)
	copyFile(t, absPath(t, legacyHookRel), filepath.Join(tb, "verify-skill-drift-hook.sh"), 0o755)
	if variant == "real" || variant == "stub" {
		symlink(t, filepath.Join(live, "install"), filepath.Join(dir, "install"))
		symlink(t, filepath.Join(live, "toolbelt", "lib"), filepath.Join(tb, "lib"))
		write(t, filepath.Join(tb, "install-verify-stub.sh"), installStub, 0o755)
		if variant == "stub" {
			write(t, filepath.Join(tb, "verify-skill-drift.sh"), driftStub, 0o755)
		}
		return physical(t, tb)
	}
	copyFile(t, filepath.Join(live, "toolbelt", "lib", "hook-emit.sh"), filepath.Join(tb, "lib", "hook-emit.sh"), 0o644)
	switch variant {
	case "noinstall":
		return physical(t, tb)
	case "two":
		copyFile(t, filepath.Join(live, "toolbelt", "tests", "fixtures", "adapters-two-sources.sh"), filepath.Join(dir, "install", "adapters.sh"), 0o644)
		write(t, filepath.Join(dir, "skills", "source_a", "SKILL.md"), "source a\n", 0o644)
		write(t, filepath.Join(dir, "skills", "source_b", "SKILL.md"), "source b\n", 0o644)
		return physical(t, tb)
	case "noadapters":
		if err := os.MkdirAll(filepath.Join(dir, "install"), 0o755); err != nil {
			t.Fatal(err)
		}
		return physical(t, tb)
	}
	// the remaining variants carry the real adapters.sh and a copy of the kit source files
	adapters := readFile(t, filepath.Join(live, "install", "adapters.sh"))
	if variant == "nopi" {
		re := regexp.MustCompile(`(?m)^RESEARCH_SDD_HARNESSES="(.*) gentle-shell"`)
		if !re.MatchString(adapters) {
			t.Fatal("adapters.sh no longer registers gentle-shell last: the nopi variant cannot be built")
		}
		adapters = re.ReplaceAllString(adapters, `RESEARCH_SDD_HARNESSES="$1"`)
	}
	write(t, filepath.Join(dir, "install", "adapters.sh"), adapters, 0o644)
	if variant == "nosrc" {
		return physical(t, tb)
	}
	for _, f := range []string{"PROMPT-LOOP.md", "METHODOLOGY.md", "skills/research-sdd/SKILL.md"} {
		copyFile(t, filepath.Join(live, f), filepath.Join(dir, f), 0o644)
	}
	profiles, _ := filepath.Glob(filepath.Join(live, "profiles", "*.slots.md"))
	for _, p := range profiles {
		copyFile(t, p, filepath.Join(dir, "profiles", filepath.Base(p)), 0o644)
	}
	switch variant {
	case "norender":
	case "rfail":
		write(t, filepath.Join(tb, "render-profile.sh"), "#!/usr/bin/env bash\necho 'render out line'\necho 'render err line' >&2\nexit 7\n", 0o755)
	case "rnoexec":
		write(t, filepath.Join(tb, "render-profile.sh"), "#!/usr/bin/env bash\nexit 0\n", 0o644)
	default:
		copyFile(t, filepath.Join(live, "toolbelt", "render-profile.sh"), filepath.Join(tb, "render-profile.sh"), 0o755)
	}
	return physical(t, tb)
}

func physical(t testing.TB, p string) string {
	t.Helper()
	r, err := filepath.EvalSymlinks(p)
	if err != nil {
		t.Fatal(err)
	}
	return r
}

// driftStub and installStub are the stubs of the hook suite: output and exit code come from the environment.
const driftStub = `#!/usr/bin/env bash
[ -z "${STUB_DRIFT_OUT:-}" ] || printf '%s\n' "$STUB_DRIFT_OUT"
exit "${STUB_DRIFT_RC:-0}"
`

const installStub = `#!/usr/bin/env bash
[ "${1:-}" = "--verify" ] || { echo "stub: expected --verify" >&2; exit 64; }
[ -z "${STUB_VERIFY_GRANDCHILD:-}" ] || sleep "$STUB_VERIFY_GRANDCHILD" &
[ -z "${STUB_VERIFY_SLEEP:-}" ] || sleep "$STUB_VERIFY_SLEEP"
[ -z "${STUB_VERIFY_OUT:-}" ] || printf '%s\n' "$STUB_VERIFY_OUT"
exit "${STUB_VERIFY_RC:-0}"
`

// ---- runners ------------------------------------------------------------------------------------------------------------

type result struct {
	out, err string
	code     int
}

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

// steering lists the variables that steer the instruments; the caller's values never reach a run.
func steering(k string) bool {
	switch {
	case strings.HasPrefix(k, "RSDD_"), strings.HasPrefix(k, "RESEARCH_SDD_"), strings.HasPrefix(k, "GENTLE_PI_"),
		strings.HasPrefix(k, "STUB_"), strings.HasPrefix(k, "GIT_"), k == "PI_CODING_AGENT_DIR", k == "HOME", k == "TMPDIR",
		k == "SSH_AUTH_SOCK", k == "SSH_AGENT_PID":
		return true
	}
	return false
}

// runEnv is the environment of one run: the caller's minus the steering variables, HOME and TMPDIR of the world, then the
// case's overrides ("-NAME" unsets, "NAME=value" sets).
func (w *world) runEnv(extra []string) []string {
	var env []string
	for _, kv := range os.Environ() {
		k, _, _ := strings.Cut(kv, "=")
		if !steering(k) {
			env = append(env, kv)
		}
	}
	env = append(env, "HOME="+w.root+"/ambient", "TMPDIR="+w.tmp, "RESEARCH_SDD_KIT_STALE_CHECK=off",
		"GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_SYSTEM=/dev/null")
	for _, e := range extra {
		e = w.sub(e)
		if k, ok := strings.CutPrefix(e, "-"); ok {
			env = dropKey(env, k)
			continue
		}
		k, _, _ := strings.Cut(e, "=")
		env = append(dropKey(env, k), e)
	}
	return env
}

func dropKey(env []string, k string) []string {
	out := env[:0:0]
	for _, kv := range env {
		if kk, _, _ := strings.Cut(kv, "="); kk != k {
			out = append(out, kv)
		}
	}
	return out
}

func envFn(env []string) func(string) string {
	m := map[string]string{}
	for _, kv := range env {
		if k, v, ok := strings.Cut(kv, "="); ok {
			m[k] = v
		}
	}
	return func(k string) string { return m[k] }
}

// runBash runs a frozen script under the caller's bash.
func (w *world) runBash(script string, args, env []string) result {
	w.t.Helper()
	bash, err := exec.LookPath("bash")
	if err != nil {
		w.t.Fatal(err)
	}
	c := exec.Command(bash, append([]string{filepath.Join(w.tb, script)}, w.subAll(args)...)...)
	c.Env, c.Dir = env, w.root
	var out, errb bytes.Buffer
	c.Stdout, c.Stderr = &out, &errb
	code := codeOf(c.Run())
	return result{out.String(), errb.String(), code}
}

func (w *world) subAll(a []string) []string {
	out := make([]string, len(a))
	for i, s := range a {
		out[i] = w.sub(s)
	}
	return out
}

// goStdio builds the Stdio of an in-process run.
func (w *world) goStdio(env []string, out, errb *bytes.Buffer) cli.Stdio {
	env = append(dropKey(append([]string(nil), env...), "RSDD_TOOLBELT_DIR"), "RSDD_TOOLBELT_DIR="+w.tb)
	return cli.Stdio{In: strings.NewReader(""), Out: out, Err: errb, Env: envFn(env), Environ: func() []string { return env }, Clock: time.Now, Cwd: w.root}
}

func (w *world) runGoDrift(args, env []string) result {
	var out, errb bytes.Buffer
	code := RunDrift(w.subAll(args), w.goStdio(env, &out, &errb))
	return result{out.String(), errb.String(), code}
}

var tmpNameRe = regexp.MustCompile(`tmp\.[A-Za-z0-9]{6,}`)

// norm makes a run comparable: the scratch root and the random names of mktemp/MkdirTemp directories are replaced.
func (w *world) norm(r result) result {
	f := func(s string) string {
		s = strings.ReplaceAll(strings.ReplaceAll(s, w.root, "@ROOT@"), fixRootPath(), "@FIX@")
		return tmpNameRe.ReplaceAllString(s, "tmp.@T@")
	}
	return result{f(r.out), f(r.err), r.code}
}

// leftover lists what a run left in its TMPDIR: nothing may survive (kit issue #1024 review F3).
func (w *world) leftover() []string {
	ents, _ := os.ReadDir(w.tmp)
	var names []string
	for _, e := range ents {
		names = append(names, e.Name())
	}
	return names
}

// ---- installed homes ------------------------------------------------------------------------------------------------------

var (
	masterOnce sync.Once
	masterDir  string
	masterErr  error
)

// installedHome copies a home that the REAL installer produced for the given harnesses ("pi", "gentle-shell"), into dst. The
// installer runs once per test binary, against the live kit, into a private home that TestMain removes.
func installedHome(t testing.TB, dst string, harnesses ...string) {
	t.Helper()
	needTool(t, "bash", "RSDD_REQUIRE_BASH")
	masterOnce.Do(func() {
		masterDir, masterErr = os.MkdirTemp("", "skdmaster")
		if masterErr != nil {
			return
		}
		for _, h := range []string{"pi", "gentle-shell"} {
			c := exec.Command("bash", filepath.Join(liveKit(t), "install", "research-sdd-install.sh"), "--home", masterDir, "--harness", h)
			c.Env = append(dropKey(os.Environ(), "HOME"), "HOME="+masterDir+"/ambient")
			if out, err := c.CombinedOutput(); err != nil {
				masterErr = fmt.Errorf("installer --harness %s: %v: %s", h, err, out)
				return
			}
		}
	})
	if masterErr != nil {
		t.Fatalf("cannot build the installed master home: %v", masterErr)
	}
	for _, h := range harnesses {
		rel := map[string]string{"pi": ".pi", "gentle-shell": ".gentle-shell"}[h]
		if rel == "" {
			t.Fatalf("unknown harness %q", h)
		}
		cpA(t, filepath.Join(masterDir, rel), filepath.Join(dst, rel))
	}
}

func TestMain(m *testing.M) {
	code := m.Run()
	if masterDir != "" {
		removeAll(masterDir)
	}
	if builtBin != "" {
		_ = os.RemoveAll(filepath.Dir(builtBin))
	}
	if fixRoot != "" {
		removeAll(fixRoot)
	}
	os.Exit(code)
}
