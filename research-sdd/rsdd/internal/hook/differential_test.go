package hook

import (
	"bytes"
	"fmt"
	"math/rand/v2"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// Differential test: the frozen bash half of lib/hook-wiring.sh (testdata/legacy, verbatim from origin/main
// 9cf94d50) and the Go port must answer the same for every fixture. A missing bash or awk FAILS the test: a
// skipped parity test proves nothing. The oracle needs gawk semantics (a directory read as a getline source is
// -1); that is the awk of the machines this kit runs on.

// legacyAsk runs driver.sh in mode over args and returns its NUL-separated answers.
func legacyAsk(t *testing.T, cwd string, env map[string]string, mode string, args ...string) []string {
	t.Helper()
	bash, err := exec.LookPath("bash")
	if err != nil {
		t.Fatalf("bash is required for the differential test: %v", err)
	}
	if _, err := exec.LookPath("awk"); err != nil {
		t.Fatalf("awk is required for the differential test: %v", err)
	}
	driver, err := filepath.Abs("testdata/legacy/driver.sh")
	if err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command(bash, append([]string{driver, mode}, args...)...)
	cmd.Dir = cwd
	cmd.Env = []string{"PATH=" + os.Getenv("PATH"), "PWD=" + cwd}
	for k, v := range env {
		cmd.Env = append(cmd.Env, k+"="+v)
	}
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	if err := cmd.Run(); err != nil {
		t.Fatalf("driver %s failed: %v: %s", mode, err, stderr.String())
	}
	out := strings.Split(stdout.String(), "\x00")
	return out[:len(out)-1] // the trailing NUL leaves one empty tail
}

func legacyEnv(r, home string) map[string]string {
	return map[string]string{envCeiling: filepath.Dir(r), envHome: home}
}

func TestDifferentialWiringFixtures(t *testing.T) {
	for _, tt := range wiringCases() {
		t.Run(tt.name, func(t *testing.T) {
			if tt.skipRoot && os.Geteuid() == 0 {
				t.Skip("running as root: permission bits are bypassed")
			}
			r, _ := sandbox(t)
			target := tt.setup(t, r)
			e := envOf(r, legacyEnv(r, ""))
			want := legacyAsk(t, r, legacyEnv(r, ""), "wiring", target)
			if got := within(t, func() string { return WiringState(e, target) }); len(want) != 1 || got != want[0] {
				t.Errorf("WiringState(%q) = %q, bash says %q", target, got, want)
			}
			root := legacyAsk(t, r, legacyEnv(r, ""), "root", target)
			gotRoot, gotIs := FindGitRoot(e, target)
			flag := "0"
			if gotIs {
				flag = "1"
			}
			if len(root) != 2 || root[0] != flag || root[1] != gotRoot {
				t.Errorf("FindGitRoot(%q) = (%q, %s), bash says %q", target, gotRoot, flag, root)
			}
			abs := legacyAsk(t, r, legacyEnv(r, ""), "abs", target)
			if got := AbsPath(r, target); len(abs) != 1 || abs[0] != got {
				t.Errorf("AbsPath(%q) = %q, bash says %q", target, got, abs)
			}
		})
	}
}

func TestDifferentialScriptFixtures(t *testing.T) {
	for _, tt := range scriptCases() {
		t.Run(tt.name, func(t *testing.T) {
			if tt.skipRoot && os.Geteuid() == 0 {
				t.Skip("running as root: permission bits are bypassed")
			}
			r, _ := sandbox(t)
			target := tt.setup(t, r)
			home := homeOf(r, tt.home)
			e := envOf(r, legacyEnv(r, home))
			want := legacyAsk(t, r, legacyEnv(r, home), "script", target)
			if got := within(t, func() string { return ScriptState(e, target) }); len(want) != 1 || got != want[0] {
				t.Errorf("ScriptState(%q) = %q, bash says %q", target, got, want)
			}
		})
	}
}

func TestDifferentialRelativeTargets(t *testing.T) {
	r, _ := sandbox(t)
	gitInit(t, filepath.Join(r, "a"))
	wireSettings(t, filepath.Join(r, "a"), stopWired)
	gitInit(t, filepath.Join(r, "repo"))
	wireSettings(t, filepath.Join(r, "repo", "nested"), stopWired)
	writeFile(t, filepath.Join(r, "proj", "sub", "retro-gate-stop.sh"), "")
	wireSettings(t, filepath.Join(r, "proj"), st(`sub/retro-gate-stop.sh`))
	for _, c := range []struct{ cwd, target string }{
		{"a", "."}, {"a", "./"}, {"repo", "nested"}, {"repo/nested", ".."}, {"repo/nested", "."}, {".", "proj"}, {"proj", "."},
		{"repo/nested", "../nested/./"}, {"a", "../repo/nested"},
	} {
		cwd := filepath.Join(r, c.cwd)
		env := legacyEnv(r, "")
		e := envOf(cwd, env)
		for _, mode := range []string{"wiring", "script"} {
			want := legacyAsk(t, cwd, env, mode, c.target)
			got := WiringState(e, c.target)
			if mode == "script" {
				got = ScriptState(e, c.target)
			}
			if len(want) != 1 || got != want[0] {
				t.Errorf("%s(cwd=%s, %q) = %q, bash says %q", mode, c.cwd, c.target, got, want)
			}
		}
	}
}

func TestDifferentialAbsPath(t *testing.T) {
	cwd := "/"
	r, _ := sandbox(t)
	cwd = r
	paths := []string{
		"", ".", "..", "/", "/..", "//", "a", "a/", "a//b", "/a/../..", "/a/b/../../../c", "./a/./b/.", "../x", "../../x/y",
		"a/b/../c/..", "/a b/c d", "/a\nb/c", "a\n", "/a/b\n", ".../x", "/..a/b..", "/a/..b/../c", strings.Repeat("x/", 30) + "..",
	}
	want := legacyAsk(t, cwd, nil, "abs", paths...)
	if len(want) != len(paths) {
		t.Fatalf("driver answered %d of %d paths", len(want), len(paths))
	}
	for i, p := range paths {
		if got := AbsPath(cwd, p); got != want[i] {
			t.Errorf("AbsPath(%q) = %q, bash says %q", p, got, want[i])
		}
	}
}

// fuzzDirs writes n settings.json fixtures under r/<prefix>/<i> and returns their dirs.
func fuzzDirs(t *testing.T, r, prefix string, contents []string) []string {
	t.Helper()
	dirs := make([]string, len(contents))
	for i, c := range contents {
		dirs[i] = filepath.Join(r, prefix, fmt.Sprint(i))
		mkdirs(t, dirs[i])
		wireSettings(t, dirs[i], c)
		writeFile(t, filepath.Join(dirs[i], "ok-retro-gate.sh"), "")
	}
	return dirs
}

func pick(rng *rand.Rand, pool []string) string { return pool[rng.IntN(len(pool))] }

func TestDifferentialStopScanFuzz(t *testing.T) {
	rng := rand.New(rand.NewPCG(1, 2))
	pool := []string{"{", "}", "[", "]", `"Stop"`, `"Stop" `, ":", " ", "\t", "retro-gate", "retro-gat", ",", "\n", `"x"`, `"hooks"`, "\r\n", `"Stop":`}
	contents := make([]string, 400)
	for i := range contents {
		var b strings.Builder
		for n := 3 + rng.IntN(14); n > 0; n-- {
			b.WriteString(pick(rng, pool))
		}
		contents[i] = b.String()
	}
	r, _ := sandbox(t)
	dirs := fuzzDirs(t, r, "fz", contents)
	e := envOf(r, legacyEnv(r, ""))
	want := legacyAsk(t, r, legacyEnv(r, ""), "wiring", dirs...)
	if len(want) != len(dirs) {
		t.Fatalf("driver answered %d of %d", len(want), len(dirs))
	}
	seen := map[string]int{}
	for i, d := range dirs {
		got := WiringState(e, d)
		seen[got]++
		if got != want[i] {
			t.Errorf("fixture %q: WiringState = %q, bash says %q", contents[i], got, want[i])
		}
	}
	if seen[WiringWired] == 0 || seen[WiringUnwired] == 0 {
		t.Errorf("the generator exercised too little of the state space: %v", seen)
	}
}

func TestDifferentialScriptFuzz(t *testing.T) {
	rng := rand.New(rand.NewPCG(3, 4))
	r, _ := sandbox(t)
	words := []string{
		"retro-gate", "retro-gate-stop.sh", "/nope/retro-gate.sh", "$CLAUDE_PROJECT_DIR/ok-retro-gate.sh",
		"${CLAUDE_PROJECT_DIR}/nope-retro-gate.sh", "$HOME/ok-retro-gate.sh", "~/ok-retro-gate.sh", "~user/retro-gate", "sub/retro-gate",
		"./ok-retro-gate.sh", "bash", "sh", "-c", "-lc", "cd", "cd sub &&", "env", "--cfg=/x/retro-gate.json", "C:/x/retro-gate",
		`\"`, `\"/nope/retro-gate.sh\"`, `\"$HOME/ok-retro-gate.sh\"`, `'`, `'$HOME/retro-gate'`, "&&", ";", "|", "*", "$VAR/retro-gate",
		"a\\\\b/retro-gate", "retro-gate-b", "/", "x:retro-gate/y",
	}
	contents := make([]string, 500)
	for i := range contents {
		var cmds []string
		for n := 1 + rng.IntN(2); n > 0; n-- {
			var ws []string
			for m := 1 + rng.IntN(5); m > 0; m-- {
				ws = append(ws, pick(rng, words))
			}
			cmds = append(cmds, `{"command":"`+strings.Join(ws, " ")+`"}`)
		}
		contents[i] = `{"hooks":{"Stop":[{"hooks":[` + strings.Join(cmds, ",") + `]}]}}`
	}
	dirs := fuzzDirs(t, r, "fs", contents)
	// the fixtures name their own sandbox files through $CLAUDE_PROJECT_DIR; HOME holds one too
	home := filepath.Join(r, "home")
	writeFile(t, filepath.Join(home, "ok-retro-gate.sh"), "")
	env := legacyEnv(r, home)
	e := envOf(r, env)
	want := legacyAsk(t, r, env, "script", dirs...)
	if len(want) != len(dirs) {
		t.Fatalf("driver answered %d of %d", len(want), len(dirs))
	}
	seen := map[string]int{}
	for i, d := range dirs {
		got := ScriptState(e, d)
		seen[got]++
		if got != want[i] {
			t.Errorf("fixture %q: ScriptState = %q, bash says %q", contents[i], got, want[i])
		}
	}
	for _, s := range []string{ScriptPresent, ScriptMissing, ScriptUnverifiable, ScriptNoEntry} {
		if seen[s] == 0 {
			t.Errorf("the generator never produced %q: %v", s, seen)
		}
	}
}
