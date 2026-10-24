package kit

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
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

// sortedTail sorts every line after the first: bash prints the nested roots in find's readdir order.
func sortedTail(out string) string {
	ls := SplitLines(out)
	if len(ls) > 1 {
		sort.Strings(ls[1:])
	}
	return lines(ls)
}

func TestDifferentialNestedWorktreeRoots(t *testing.T) {
	d := nwFixture(t)
	link := filepath.Join(t.TempDir(), "link")
	if err := os.Symlink(d, link); err != nil {
		t.Fatal(err)
	}
	inside := d + "/.claude/worktrees/agent-1"
	for label, root := range map[string]string{"fixture": d, "trailing-slash": d + "/", "symlinked-root": link,
		"inside-claude-worktrees": inside, "absent": d + "/missing", "a-file": d + "/side-wt/.git", "empty": ""} {
		t.Run(label, func(t *testing.T) {
			b := bashDriver(t, nil, "", "nwr", root)
			roots, err := NestedWorktreeRoots(root)
			gotErr := ""
			if err != nil {
				gotErr = err.Error() + "\n"
			}
			if RC(err) != b.rc || lines(roots) != sortedTail(b.stdout) || gotErr != b.stderr {
				t.Fatalf("go rc=%d out=%q err=%q\nbash rc=%d out=%q err=%q", RC(err), lines(roots), gotErr, b.rc, b.stdout, b.stderr)
			}
			for _, p := range []string{d + "/side-wt/x-block1.md", d + "/side-wt", d + "/side-wt-old/x", d + "/x-block1.md", inside + "/y", "", d} {
				pb := bashDriver(t, nil, "", "pinw", p, strings.TrimSuffix(b.stdout, "\n"))
				if RC2(PathInNestedWorktree(p, roots)) != pb.rc {
					t.Errorf("path_in_nested_worktree(%q): go=%v bash rc=%d", p, PathInNestedWorktree(p, roots), pb.rc)
				}
			}
		})
	}
}

// TestDifferentialNestedWorktreeRootsIncomplete: an unreadable subdirectory makes find exit 1; both sides keep the
// partial roots and type the gap (rc 3).
func TestDifferentialNestedWorktreeRootsIncomplete(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("running as root: chmod 000 stays readable, premise unavailable (NOT a pass)")
	}
	d := nwFixture(t)
	mkfiles(t, d, "locked/x")
	if err := os.Chmod(d+"/locked", 0); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(d+"/locked", 0o755) })
	b := bashDriver(t, nil, "", "nwr", d)
	roots, err := NestedWorktreeRoots(d)
	if b.rc != 3 || RC(err) != 3 || lines(roots) != sortedTail(b.stdout) || err.Error()+"\n" != b.stderr {
		t.Fatalf("go rc=%d out=%q err=%v\nbash rc=%d out=%q err=%q", RC(err), lines(roots), err, b.rc, b.stdout, b.stderr)
	}
}

// RC2 maps a predicate to a bash test status.
func RC2(ok bool) int {
	if ok {
		return 0
	}
	return 1
}

// prefixStdout is what derive_focus_prefix prints: the filename form without a newline, the FOCUSES.md form with.
func prefixStdout(p FocusPrefix) string {
	if p.Source == PrefixFromFocuses {
		return p.Value + "\n"
	}
	return p.Value
}

func TestDifferentialDeriveFocusPrefix(t *testing.T) {
	for _, c := range prefixCases {
		t.Run(c.label, func(t *testing.T) {
			d := t.TempDir()
			if c.table != "" {
				write(t, d+"/FOCUSES.md", c.table)
			}
			sf := d + "/" + c.stateBase
			b := bashDriver(t, nil, "", "dfp", sf)
			got, err := DeriveFocusPrefix(sf)
			if err != nil || b.rc != 0 || b.stderr != "" || prefixStdout(got) != b.stdout {
				t.Fatalf("go %q (%v); bash rc=%d out=%q err=%q", prefixStdout(got), err, b.rc, b.stdout, b.stderr)
			}
		})
	}
}

func TestDifferentialDeriveFocusRange(t *testing.T) {
	for _, c := range rangeCases {
		t.Run(c.label, func(t *testing.T) {
			sf := focusCorpus(t, t.TempDir(), c.table)
			for _, s := range []string{sf, filepath.Dir(sf) + "/RESEARCH-STATE-o.md", sf + "/"} {
				b := bashDriver(t, nil, "", "dfr", s)
				r, err := DeriveFocusRange(s)
				if err != nil || b.rc != 0 || b.stderr != "" || r.Value()+nl(r.Value()) != b.stdout {
					t.Fatalf("%s: go %q (%v); bash rc=%d out=%q err=%q", s, r.Value(), err, b.rc, b.stdout, b.stderr)
				}
			}
		})
	}
}

// FINDING F9: an unreadable FOCUSES.md is not a silent "no prefix" in Go. Bash lets awk print its error and the
// function prints nothing (derive_focus_prefix returns awk's 2, derive_focus_range the 0 of `head`).
func TestDifferentialFindingUnreadableFocusesIsSilentInBash(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("running as root: chmod 000 stays readable, premise unavailable (NOT a pass)")
	}
	d := t.TempDir()
	sf := d + "/RESEARCH-STATE.md"
	if err := os.Chmod(write(t, d+"/FOCUSES.md", niagaraHeader+rootRow("base-", "B1-B2")), 0); err != nil {
		t.Fatal(err)
	}
	for mode, rc := range map[string]int{"dfp": 2, "dfr": 0} {
		if b := bashDriver(t, nil, "", mode, sf); b.rc != rc || b.stdout != "" || b.stderr == "" {
			t.Errorf("premise changed for %s: rc=%d out=%q err=%q", mode, b.rc, b.stdout, b.stderr)
		}
	}
	if _, err := DeriveFocusPrefix(sf); !errors.Is(err, ErrUnreadable) {
		t.Errorf("prefix: %v", err)
	}
	if _, err := DeriveFocusRange(sf); !errors.Is(err, ErrUnreadable) {
		t.Errorf("range: %v", err)
	}
}

func TestDifferentialFocusRangeScanAndReport(t *testing.T) {
	for _, c := range scanCorpora {
		t.Run(c.label, func(t *testing.T) {
			d := t.TempDir()
			sf := focusCorpus(t, d, c.table)
			mkfiles(t, d, c.files...)
			b := bashDriver(t, nil, "", "frr", sf)
			rep, err := FocusRangeReport(sf)
			var got strings.Builder
			for _, x := range rep {
				got.WriteString(x.Kind + "|" + x.Text + "\n")
			}
			if err != nil || b.rc != 0 || b.stderr != "" || got.String() != b.stdout {
				t.Fatalf("report go %q (%v)\nbash rc=%d out=%q err=%q", got.String(), err, b.rc, b.stdout, b.stderr)
			}
			r, _ := DeriveFocusRange(sf)
			if r.State != RangeOK {
				return
			}
			for _, state := range []string{sf, ""} {
				s, err := ScanFocusRange(d, r.Lo, r.Hi, state)
				if err != nil {
					t.Fatal(err)
				}
				for field, want := range map[string]string{"COUNT": strconv.Itoa(s.Count), "FILES": strconv.Itoa(s.Files), "SPAN": awkNum(s.Span)} {
					if b := bashDriver(t, nil, "", "frs", d, r.Value(), state, field); b.rc != 0 || b.stdout != want+"\n" {
						t.Errorf("stat %s (claims from %q): go %s, bash rc=%d %q", field, state, want, b.rc, b.stdout)
					}
				}
			}
		})
	}
}

// FINDING F10: focus_range_stat on a directory that does not exist counts a confident 0 in bash (find's error is
// discarded). Go types it.
func TestDifferentialFindingRangeStatAbsentDirIsASilentZeroInBash(t *testing.T) {
	missing := filepath.Join(t.TempDir(), "nope")
	if b := bashDriver(t, nil, "", "frs", missing, "1-5", "", "COUNT"); b.rc != 0 || b.stdout != "0\n" {
		t.Fatalf("premise changed: rc=%d out=%q", b.rc, b.stdout)
	}
	if _, err := ScanFocusRange(missing, 1, 5, ""); !errors.Is(err, ErrAbsentInput) {
		t.Fatalf("Go must type it: %v", err)
	}
}

// TestDifferentialFocusRangeScanSymlinkedDir: find -P does not follow a symlinked start directory, so the scan
// sees no file through the link (a silent zero, kept for parity) unless the path ends with a slash.
func TestDifferentialFocusRangeScanSymlinkedDir(t *testing.T) {
	d := t.TempDir()
	mkfiles(t, d, "a-block1.md", "a-block2.md")
	link := filepath.Join(t.TempDir(), "link")
	if err := os.Symlink(d, link); err != nil {
		t.Fatal(err)
	}
	for _, dir := range []string{link, link + "/"} {
		s, err := ScanFocusRange(dir, 1, 2, "")
		b := bashDriver(t, nil, "", "frs", dir, "1-2", "", "COUNT")
		if err != nil || b.stdout != strconv.Itoa(s.Count)+"\n" {
			t.Errorf("%s: go %d (%v), bash %q", dir, s.Count, err, b.stdout)
		}
	}
}

func TestDifferentialInplaceGapID(t *testing.T) {
	for _, c := range gapIDCases {
		b := bashDriver(t, nil, "", "igid", c.in)
		got, _ := InplaceGapID(c.in)
		if b.rc != 0 || b.stderr != "" || got+nl(got) != b.stdout {
			t.Errorf("inplace_gap_id(%q): go %q; bash rc=%d out=%q err=%q", c.in, got, b.rc, b.stdout, b.stderr)
		}
	}
}

func TestDifferentialInplaceBlockedCount(t *testing.T) {
	for _, c := range inplaceCases {
		b := bashDriver(t, nil, c.rows, "ibc", c.body)
		if got := strconv.Itoa(InplaceBlockedCount(c.body, c.rows)) + "\n"; b.rc != 0 || b.stderr != "" || got != b.stdout {
			t.Errorf("%s: go %q; bash rc=%d out=%q err=%q", c.label, got, b.rc, b.stdout, b.stderr)
		}
	}
}
