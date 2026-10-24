package kit

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

// Differential tests: the REAL bash libs (testdata/diff-driver.sh) and the Go port must agree byte for byte on
// stdout, stderr and the return code. Bash runs under LC_ALL=C, the locale Go's sorting implements.
//
// The driver fails loudly: exit 97 means the harness is broken (lib missing, function not defined, unknown
// mode) and is a t.Fatal here, never a skip and never a pass. Only a missing bash binary skips, with a
// message that says the Go port is NOT proven in that run.

const (
	toolbeltRel = "../../../../toolbelt"
	harnessRC   = 97
)

type bashOut struct {
	stdout, stderr string
	rc             int
}

func bashDriver(t *testing.T, env map[string]string, stdin, mode string, args ...string) bashOut {
	t.Helper()
	bin, err := exec.LookPath("bash")
	if err != nil {
		t.Skip("differential: bash not found in PATH; the Go port is NOT proven against the kit's bash libs in this run")
	}
	tb, err := filepath.Abs(toolbeltRel)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(tb, "lib", "target-paths.sh")); err != nil {
		t.Fatalf("differential: toolbelt not found at %s (%v); a moved package must update toolbeltRel, not skip", tb, err)
	}
	script, _ := filepath.Abs(filepath.Join("testdata", "diff-driver.sh"))
	cmd := exec.Command(bin, append([]string{script, tb, mode}, args...)...)
	cmd.Env = []string{"PATH=" + os.Getenv("PATH"), "LC_ALL=C"}
	for k, v := range env {
		cmd.Env = append(cmd.Env, k+"="+v)
	}
	cmd.Stdin = strings.NewReader(stdin)
	var so, se bytes.Buffer
	cmd.Stdout, cmd.Stderr = &so, &se
	rc := 0
	if err := cmd.Run(); err != nil {
		var ee *exec.ExitError
		if !errors.As(err, &ee) {
			t.Fatalf("differential: cannot run the driver: %v", err)
		}
		rc = ee.ExitCode()
	}
	if rc == harnessRC {
		t.Fatalf("differential: driver harness failure for %s: %s", mode, se.String())
	}
	return bashOut{so.String(), se.String(), rc}
}

func lines(xs []string) string {
	if len(xs) == 0 {
		return ""
	}
	return strings.Join(xs, "\n") + "\n"
}

func bashEnv(rh, home string) map[string]string {
	e := map[string]string{"HOME": home}
	if rh != "" {
		e["RESEARCH_HOME"] = rh
	}
	return e
}

func TestDifferentialTargetPathsCorpus(t *testing.T) {
	names := make([]string, 0, len(targetCorpus))
	for n := range targetCorpus {
		names = append(names, n)
	}
	sort.Strings(names)
	dir := t.TempDir()
	for _, rh := range []string{"/rh-pinned", "/rh-slash/", "/rh&amp/x", "", "/two//"} {
		for _, name := range names {
			p := write(t, filepath.Join(dir, name+".md"), targetCorpus[name])
			home := "/home/pinned"
			gEnv := envOf(map[string]string{"RESEARCH_HOME": rh, "HOME": home})
			label := fmt.Sprintf("%s rh=%q", name, rh)

			all := bashDriver(t, bashEnv(rh, home), "", "tpall", p)
			if all.rc != 0 || all.stderr != "" {
				t.Fatalf("%s: bash tpall rc=%d stderr=%q", label, all.rc, all.stderr)
			}
			if got := lines(PathsAll(targetCorpus[name], gEnv)); got != all.stdout {
				t.Errorf("%s: PathsAll\n go=%q\nbash=%q", label, got, all.stdout)
			}
			pairs := bashDriver(t, bashEnv(rh, home), "", "tppairs", p)
			if pairs.rc != 0 || pairs.stderr != "" {
				t.Fatalf("%s: bash tppairs rc=%d stderr=%q", label, pairs.rc, pairs.stderr)
			}
			var pl []string
			for _, pr := range PairsAll(targetCorpus[name], gEnv) {
				pl = append(pl, pr.Line())
			}
			if got := lines(pl); got != pairs.stdout {
				t.Errorf("%s: PairsAll\n go=%q\nbash=%q", label, got, pairs.stdout)
			}
		}
	}
}

func TestDifferentialErrorsAreTyped(t *testing.T) {
	dir := t.TempDir()
	missing := filepath.Join(dir, "missing.md")
	for _, mode := range []string{"tpall", "tppairs"} {
		b := bashDriver(t, bashEnv("", "/h"), "", mode)
		_, err := ReadTargets("")
		if b.rc != 1 || err == nil || !errors.Is(err, ErrUsage) || err.Error()+"\n" != b.stderr {
			t.Errorf("%s no-arg: bash rc=%d stderr=%q go=%v", mode, b.rc, b.stderr, err)
		}
		b = bashDriver(t, bashEnv("", "/h"), "", mode, missing)
		_, err = ReadTargets(missing)
		if b.rc != 1 || !errors.Is(err, ErrAbsentInput) || err.Error()+"\n" != b.stderr {
			t.Errorf("%s absent: bash rc=%d stderr=%q go=%v", mode, b.rc, b.stderr, err)
		}
		b = bashDriver(t, bashEnv("", "/h"), "", mode, dir) // a directory is not `-f`
		_, err = ReadTargets(dir)
		if b.rc != 1 || !errors.Is(err, ErrAbsentInput) || err.Error()+"\n" != b.stderr {
			t.Errorf("%s dir: bash rc=%d stderr=%q go=%v", mode, b.rc, b.stderr, err)
		}
	}
}

// FINDING F2: an unreadable (mode 000) TARGETS.md is a confident empty list, rc 0, in bash. Go reports it.
func TestDifferentialFindingUnreadableFileIsASilentZeroInBash(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("running as root: chmod 000 stays readable, premise unavailable (NOT a pass)")
	}
	p := write(t, filepath.Join(t.TempDir(), "locked.md"), "| `/x` |\n")
	if err := os.Chmod(p, 0); err != nil {
		t.Fatal(err)
	}
	b := bashDriver(t, bashEnv("", "/h"), "", "tpall", p)
	if b.rc != 0 || b.stdout != "" {
		t.Fatalf("premise changed, bash is no longer silent: rc=%d out=%q err=%q", b.rc, b.stdout, b.stderr)
	}
	if _, err := ReadTargets(p); !errors.Is(err, ErrUnreadable) {
		t.Fatalf("Go must type it: %v", err)
	}
}

// FINDING F4: the return code of target_paths_all depends on the CALLER's pipefail: its last pipeline (the
// $RESEARCH_HOME form) exits 1 when no row has such a token, although the output is complete.
func TestDifferentialFindingPipefailMakesRCContentDependent(t *testing.T) {
	p := write(t, filepath.Join(t.TempDir(), "t.md"), targetCorpus["basic"])
	env := bashEnv("/rh", "/h")
	env["RSDD_DRIVER_PIPEFAIL"] = "1"
	b := bashDriver(t, env, "", "tpall", p)
	if b.rc != 1 || b.stdout != "/home/x/.../trunc-target\n/table/real/path\n" {
		t.Fatalf("pipefail on, no RH rows: rc=%d out=%q", b.rc, b.stdout)
	}
	p2 := write(t, filepath.Join(t.TempDir(), "t.md"), targetCorpus["rh-prose"])
	if b := bashDriver(t, env, "", "tpall", p2); b.rc != 0 {
		t.Fatalf("pipefail on, with RH rows: rc=%d", b.rc)
	}
}

func TestDifferentialRealTargetsMD(t *testing.T) {
	real, err := filepath.Abs("../../../../TARGETS.md")
	if err != nil {
		t.Fatal(err)
	}
	src, err := ReadTargets(real)
	if err != nil {
		t.Fatalf("the real registry must exist at %s: %v", real, err) // absent-input is a failure, never a skip
	}
	before, _ := os.ReadFile(real)
	for _, home := range []string{"/rh-pinned", "/rh-pinned/"} {
		env := bashEnv(home, "/home/pinned")
		gEnv := envOf(env)
		all := bashDriver(t, env, "", "tpall", real)
		if all.rc != 0 || all.stderr != "" {
			t.Fatalf("bash rc=%d stderr=%q", all.rc, all.stderr)
		}
		got := PathsAll(src, gEnv)
		if len(got) < 5 { // not vacuous: the registry holds many targets
			t.Fatalf("suspiciously few real targets: %q", got)
		}
		if lines(got) != all.stdout {
			t.Errorf("PathsAll over the real TARGETS.md differs (home=%q)\n go=%q\nbash=%q", home, lines(got), all.stdout)
		}
		pairs := bashDriver(t, env, "", "tppairs", real)
		var pl []string
		for _, p := range PairsAll(src, gEnv) {
			pl = append(pl, p.Line())
		}
		if lines(pl) != pairs.stdout {
			t.Errorf("PairsAll over the real TARGETS.md differs (home=%q)", home)
		}
	}
	// Classification under the machine's own RESEARCH_HOME/HOME: stat only, same env on both sides.
	rh, home := os.Getenv("RESEARCH_HOME"), os.Getenv("HOME")
	env := bashEnv(rh, home)
	paths := PathsAll(src, envOf(map[string]string{"RESEARCH_HOME": rh, "HOME": home}))
	b := bashDriver(t, env, lines(paths), "isdir")
	bashDirs := map[string]bool{}
	for _, l := range strings.Split(strings.TrimSuffix(b.stdout, "\n"), "\n") {
		if p, flag, ok := strings.Cut(l, "\t"); ok {
			bashDirs[p] = flag == "1"
		}
	}
	usable, warns := Classify(paths, func(p string) bool { st, err := os.Stat(p); return err == nil && st.IsDir() })
	if len(usable)+len(warns) != len(paths) {
		t.Fatalf("classification lost paths: %d+%d != %d", len(usable), len(warns), len(paths))
	}
	for _, p := range usable {
		if !bashDirs[p] {
			t.Errorf("Go says %q is usable, bash [ -d ] disagrees", p)
		}
	}
	for _, w := range warns {
		if w.Kind == WarnUnresolvable && bashDirs[w.Path] {
			t.Errorf("Go says %q is unresolvable, bash [ -d ] disagrees", w.Path)
		}
	}
	if after, _ := os.ReadFile(real); !bytes.Equal(before, after) {
		t.Fatal("the real TARGETS.md changed")
	}
}

func TestDifferentialNameForRetro(t *testing.T) {
	type sc struct {
		name  string
		build func(e *nameEnv) (targets, retro, rh string)
	}
	scenarios := []sc{
		{"flat", func(e *nameEnv) (string, string, string) {
			return e.targets(e.row(1, "reg-first", e.root+"/first"), e.row(2, "reg-middle", e.root+"/middle")), e.retro("middle"), e.root
		}},
		{"nested-corpus", func(e *nameEnv) (string, string, string) {
			return e.targets(e.row(1, "reg", e.root+"/m")), e.retro("m/sub/deeper"), e.root
		}},
		{"nearest-wins", func(e *nameEnv) (string, string, string) {
			e.retro("outer")
			return e.targets(e.row(1, "outer-t", e.root+"/outer"), e.row(2, "inner-t", e.root+"/outer/inner")), e.retro("outer/inner"), e.root
		}},
		{"rh-braced", func(e *nameEnv) (string, string, string) {
			return e.targets(e.row(1, "rh-braced", "${RESEARCH_HOME}/rhb")), e.retro("rhb"), e.root
		}},
		{"whitespace-name", func(e *nameEnv) (string, string, string) {
			return e.targets(e.row(1, "two words", e.root+"/sp")), e.retro("sp"), e.root
		}},
		{"bold-name", func(e *nameEnv) (string, string, string) {
			return e.targets(e.row(1, "**b-n**", e.root+"/b")), e.retro("b"), e.root
		}},
		{"empty-name", func(e *nameEnv) (string, string, string) {
			return e.targets(e.row(1, "", e.root+"/bl")), e.retro("bl"), e.root
		}},
		{"no-match", func(e *nameEnv) (string, string, string) {
			e.retro("x")
			return e.targets(e.row(1, "reg", e.root+"/x")), e.retro("stranger"), e.root
		}},
		{"wrong-rh", func(e *nameEnv) (string, string, string) {
			return e.targets(e.row(1, "rh", "$RESEARCH_HOME/rhp")), e.retro("rhp"), "/nonexistent-rh"
		}},
		{"abs-ghost-only", func(e *nameEnv) (string, string, string) {
			return e.targets(e.row(1, "g", e.root+"/ghost")), e.retro("m"), e.root
		}},
		{"empty-targets", func(e *nameEnv) (string, string, string) { return e.file(""), e.retro("m"), e.root }},
		{"header-only", func(e *nameEnv) (string, string, string) { return e.targets(), e.retro("m"), e.root }},
		{"absent-targets", func(e *nameEnv) (string, string, string) { return e.root + "/none.md", e.retro("m"), e.root }},
		{"absent-retro-dir", func(e *nameEnv) (string, string, string) {
			return e.targets(e.row(1, "r", e.root+"/m")), e.root + "/zz/retros/r.md", e.root
		}},
		{"escaped-pipe-name", func(e *nameEnv) (string, string, string) {
			e.retro("p")
			return e.file("| 1 | a\\|b | `" + e.root + "/p` |\n"), e.retro("p"), e.root
		}},
		{"no-trailing-newline", func(e *nameEnv) (string, string, string) {
			return e.file("| 1 | last | `" + e.root + "/nl` |"), e.retro("nl"), e.root
		}},
	}
	for _, s := range scenarios {
		t.Run(s.name, func(t *testing.T) {
			e := newNameEnv(t)
			targets, retro, rh := s.build(e)
			b := bashDriver(t, bashEnv(rh, "/home/pinned"), "", "tnr", targets, retro)
			r, err := NameForRetro(targets, retro, e.root, envOf(bashEnv(rh, "/home/pinned")))
			gotOut := ""
			if err == nil {
				gotOut = r.Name + "\n"
			}
			gotErr := strings.Join(r.Warnings, "\n")
			if err != nil && !errors.Is(err, ErrNoAncestor) {
				gotErr = err.Error()
			}
			if gotErr != "" {
				gotErr += "\n"
			}
			if RC(err) != b.rc || gotOut != b.stdout || gotErr != b.stderr {
				t.Errorf("go  rc=%d out=%q err=%q\nbash rc=%d out=%q err=%q", RC(err), gotOut, gotErr, b.rc, b.stdout, b.stderr)
			}
		})
	}
}

func TestDifferentialStateFiles(t *testing.T) {
	for _, c := range stateCases {
		t.Run(c.label, func(t *testing.T) {
			root := stateFixture(t, c.files...)
			args := []string{}
			if c.opt.FollowDir {
				args = append(args, "-H")
			}
			args = append(args, root)
			if c.opt.FocusSet {
				args = append(args, "--focus", c.opt.Focus)
			}
			b := bashDriver(t, bashEnv("", "/h"), "", "resolvestate", args...)
			got, err := ResolveStateFile(root, c.opt)
			if RC(err) != b.rc || got+nl(got) != b.stdout || b.stderr != "" {
				t.Errorf("resolve go rc=%d path=%q; bash rc=%d out=%q err=%q", RC(err), got, b.rc, b.stdout, b.stderr)
			}
			lb := bashDriver(t, bashEnv("", "/h"), "", "liststate", root)
			lg, lerr := ListStateFiles(root)
			if lerr != nil || lb.rc != 0 || lines(lg) != lb.stdout || lb.stderr != "" {
				t.Errorf("list go=%q err=%v; bash rc=%d out=%q err=%q", lg, lerr, lb.rc, lb.stdout, lb.stderr)
			}
		})
	}
}

func nl(s string) string {
	if s == "" {
		return ""
	}
	return "\n"
}

func TestDifferentialStateFilesFilesystemQuirks(t *testing.T) {
	real := stateFixture(t, "RESEARCH-STATE.md")
	link := filepath.Join(t.TempDir(), "link")
	if err := os.Symlink(real, link); err != nil {
		t.Fatal(err)
	}
	dirNamed := t.TempDir()
	if err := os.MkdirAll(filepath.Join(dirNamed, "RESEARCH-STATE-dir.md"), 0o755); err != nil {
		t.Fatal(err)
	}
	under := filepath.Join(stateFixture(t, ".git/corpus/RESEARCH-STATE.md"), ".git", "corpus")
	for label, dir := range map[string]string{"symlinked-dir": link, "dir-named-like-state": dirNamed, "start-under-.git": under, "trailing-slash": real + "/"} {
		for _, follow := range []bool{false, true} {
			args := []string{dir}
			if follow {
				args = []string{"-H", dir}
			}
			b := bashDriver(t, bashEnv("", "/h"), "", "resolvestate", args...)
			got, err := ResolveStateFile(dir, ResolveOptions{FollowDir: follow})
			if RC(err) != b.rc || got+nl(got) != b.stdout {
				t.Errorf("%s -H=%v resolve go rc=%d %q; bash rc=%d %q", label, follow, RC(err), got, b.rc, b.stdout)
			}
		}
		lb := bashDriver(t, bashEnv("", "/h"), "", "liststate", dir)
		lg, _ := ListStateFiles(dir)
		if lines(lg) != lb.stdout {
			t.Errorf("%s list go=%q bash=%q", label, lg, lb.stdout)
		}
	}
}

// FINDING F6: list_state_files on a directory that does not exist prints nothing and returns 0, the same as an
// empty corpus. Go separates absent-input from empty-input.
func TestDifferentialFindingListStateFilesAbsentDirIsASilentZeroInBash(t *testing.T) {
	missing := filepath.Join(t.TempDir(), "nope")
	b := bashDriver(t, bashEnv("", "/h"), "", "liststate", missing)
	if b.rc != 0 || b.stdout != "" {
		t.Fatalf("premise changed: rc=%d out=%q", b.rc, b.stdout)
	}
	if _, err := ListStateFiles(missing); !errors.Is(err, ErrAbsentInput) {
		t.Fatalf("Go must type it: %v", err)
	}
}

func TestDifferentialBlockFileFilter(t *testing.T) {
	for _, c := range filterCases {
		t.Run(c.label, func(t *testing.T) {
			var args []string
			if c.invert {
				args = append(args, "-v")
			}
			if c.prefix != "" {
				args = append(args, c.prefix)
			}
			b := bashDriver(t, nil, lines(c.in), "bff", args...)
			got, err := FilterBlockFiles(c.in, c.invert, c.prefix)
			if RC(err) != b.rc || lines(got) != b.stdout || (b.stderr != "") != errors.Is(err, ErrBadPattern) {
				t.Errorf("go rc=%d out=%q; bash rc=%d out=%q err=%q", RC(err), lines(got), b.rc, b.stdout, b.stderr)
			}
		})
	}
}

// FINDING F8: the prefix is a raw ERE fragment and GNU grep's ERE is laxer than Go's POSIX syntax: these prefixes
// are accepted by grep (GNU extensions, or a stray metacharacter taken literally) and rejected by Go. Kit-derived
// prefixes are `[A-Za-z]…-` and never reach them; the cases pin the premise so a dialect change is noticed.
func TestDifferentialFindingPrefixDialectGaps(t *testing.T) {
	in := []string{"/c/a-block1.md", "/c/dblock1.md"}
	for _, p := range []string{`\d`, `\w`, `\`, `)`} {
		b := bashDriver(t, nil, lines(in), "bff", p)
		if b.rc > 1 || b.stderr != "" {
			t.Errorf("premise changed: grep now rejects prefix %q (rc=%d %q)", p, b.rc, b.stderr)
		}
		if _, err := FilterBlockFiles(in, false, p); !errors.Is(err, ErrBadPattern) {
			t.Errorf("premise changed: Go now accepts prefix %q (%v); move it to filterCases", p, err)
		}
	}
}
