package kit

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

// Part 2 differential tests: block-files, focus-prefix and inplace_*. Every comparison goes through expectSame
// (intended_test.go), so an unlisted divergence fails and nothing here is listed.

func env0() map[string]string { return bashEnv("", "/h") }

func sortedCorpusNames(m map[string]string) []string {
	var ns []string
	for n := range m {
		ns = append(ns, n)
	}
	sort.Strings(ns)
	return ns
}

func TestDifferentialBlockFileFilter(t *testing.T) {
	inputs := []string{
		"", "\n", "a-block1.md", "a-block1.md\n", "notes.md\n", "notes.md",
		"a/x-block1.md\nblock12.md\nblocked-notes.md\n", "block12.md\nretros/y-bloque22-suf_1.md\nx-block1-.md", "x-block1--a.md\r\nx-block2.md\n",
		"x-block1.md\n\nx-block2.md\n", "dir-block1.md/file\nops-block3.md\nXops-block3.md\n", "é-block1.md\nz-block01.md\n",
	}
	for _, in := range inputs {
		for _, inv := range []bool{false, true} {
			for _, pfx := range []string{"", "ops-", "a.b-", "z-", "(", "[", "x+-"} {
				args := []string{}
				if inv {
					args = append(args, "-v")
				}
				if pfx != "" {
					args = append(args, pfx)
				}
				b := bashDriver(t, env0(), in, "bfilter", args...)
				g := BlockFileFilter(in, inv, pfx)
				name := fmt.Sprintf("bfilter in=%q inv=%v pfx=%q", in, inv, pfx)
				if g.Status == 2 { // error: grep's own stderr text is not part of the contract, its status and silence on stdout are
					expectSame(t, name, render(g.Status, ""), render(b.rc, b.stdout))
					if b.stderr == "" || g.Err == nil {
						t.Errorf("%s: an error must be loud on both sides: bash=%q go=%v", name, b.stderr, g.Err)
					}
					continue
				}
				expectSame(t, name, render(g.Status, lines(g.Lines)), render(b.rc, b.stdout))
			}
		}
	}
}

func TestDifferentialNestedWorktrees(t *testing.T) {
	root := physical(t, t.TempDir())
	mkWorktree(t, root, "a-first")
	mkWorktree(t, root, "m/mid")
	mkWorktree(t, root, "z-last")
	write(t, filepath.Join(root, "gitdirs", "forged", "commondir"), "x\n")
	write(t, filepath.Join(root, "forged", ".git"), "gitdir: "+filepath.Join(root, "gitdirs", "forged")+"\n")
	write(t, filepath.Join(root, "sub", ".git"), "gitdir: "+filepath.Join(root, "gitdirs")+"/modules/sub\n")
	write(t, filepath.Join(root, "clone", ".git", "HEAD"), "ref\n")
	write(t, filepath.Join(root, "stale", ".git"), "gitdir: /nonexistent/gd\n")
	write(t, filepath.Join(root, "nogd", ".git"), "not a gitdir line\n")
	spoofGD := filepath.Join(root, "gitdirs", "spoof")
	write(t, filepath.Join(spoofGD, "commondir"), "x\n")
	write(t, filepath.Join(spoofGD, "gitdir"), filepath.Join(root, "a-first", ".git")+"\n")
	write(t, filepath.Join(root, "spoof", ".git"), "gitdir: "+spoofGD+"\n")
	write(t, filepath.Join(root, "empty", ".git"), "")
	write(t, filepath.Join(root, "nonl", ".git"), "gitdir: /nonexistent")
	write(t, filepath.Join(root, ".git"), "gitdir: x\n")
	mkWorktree(t, filepath.Join(root, ".claude/worktrees"), "inner")
	rel := filepath.Join(root, "rel")
	write(t, filepath.Join(rel, "gd", "commondir"), "x\n")
	write(t, filepath.Join(rel, "gd", "gitdir"), "../.git\n")
	write(t, filepath.Join(rel, ".git"), "gitdir: gd\n")
	for _, r := range []string{root, root + "/", filepath.Join(root, "nope")} {
		b := bashDriver(t, env0(), "", "nwroots", r)
		got, err := NestedWorktreeRoots(r)
		goErr := ""
		if err != nil && !strings.Contains(err.Error(), "find exited") {
			goErr = err.Error() + "\n"
		}
		if b.rc == 0 || b.rc == 2 {
			expectSame(t, "nwroots rc "+r, render(RC(err), sortedAfterFirst(got)+goErr), render(b.rc, bashRoots(b.stdout)+b.stderr))
		} else {
			t.Fatalf("unexpected bash rc %d: %q", b.rc, b.stderr)
		}
	}
	if os.Geteuid() != 0 {
		locked := filepath.Join(root, "locked")
		write(t, filepath.Join(locked, "x"), "")
		_ = os.Chmod(locked, 0)
		defer os.Chmod(locked, 0o755)
		b := bashDriver(t, env0(), "", "nwroots", root)
		got, err := NestedWorktreeRoots(root)
		goErr := ""
		if err != nil {
			goErr = err.Error() + "\n"
		}
		expectSame(t, "nwroots incomplete", render(RC(err), sortedAfterFirst(got)+goErr), render(b.rc, bashRoots(b.stdout)+b.stderr))
	}
	roots := []string{"/r/.claude/worktrees", "/r/wt1", "/r/wt2"}
	for _, p := range []string{"/r/wt1", "/r/wt1/a", "/r/wt2/x", "/r/.claude/worktrees/q", "/r/wt10/x", "/r/wt", "/o", "", "/r/wt1/"} {
		for _, rs := range [][]string{roots, nil, {""}, {"/only"}, {"/r/wt*"}} {
			b := bashDriver(t, env0(), "", "pathin", p, strings.Join(rs, "\n"))
			got := 1
			if PathInNestedWorktree(p, rs) {
				got = 0
			}
			expectSame(t, fmt.Sprintf("pathin %q %q", p, rs), render(got, ""), render(b.rc, b.stdout))
		}
	}
}

// sortedAfterFirst keeps the always-first "<root>/.claude/worktrees" entry first and sorts the rest: bash emits
// find's readdir order, which is not defined.
func sortedAfterFirst(ls []string) string {
	if len(ls) == 0 {
		return ""
	}
	rest := append([]string{}, ls[1:]...)
	sort.Strings(rest)
	return lines(append([]string{ls[0]}, rest...))
}

func bashRoots(out string) string {
	if out == "" {
		return ""
	}
	return sortedAfterFirst(strings.Split(strings.TrimSuffix(out, "\n"), "\n"))
}

func TestDifferentialFocus(t *testing.T) {
	for _, name := range sortedCorpusNames(focusCorpus) {
		dir, sf := focusDir(t, focusCorpus[name], scanFiles...)
		mkfiles(t, dir, "RESEARCH-STATE-auth.md")
		for _, f := range []string{sf, filepath.Join(dir, "RESEARCH-STATE-auth.md"), filepath.Join(dir, "other.md"), filepath.Join(t.TempDir(), "RESEARCH-STATE.md")} {
			label := fmt.Sprintf("%s %s", name, filepath.Base(f))
			b := bashDriver(t, env0(), "", "fprefix", f)
			p, _ := DerivePrefix(f)
			expectSame(t, "fprefix "+label, p+"\n", b.stdout)
			b = bashDriver(t, env0(), "", "frange", f)
			expectSame(t, "frange "+label, DeriveRange(f).Output()+"\n", b.stdout)
			b = bashDriver(t, env0(), "", "freport", f)
			var rep []string
			for _, d := range RangeReport(f) {
				rep = append(rep, d.Kind+"|"+d.Text)
			}
			expectSame(t, "freport "+label, lines(rep), b.stdout)
			if b.rc != 0 {
				t.Errorf("%s: freport rc %d (%q)", label, b.rc, b.stderr)
			}
		}
		if r := DeriveRange(sf); r.Kind == RangeOK {
			lo, hi := 0, 0
			fmt.Sscanf(r.Value, "%d-%d", &lo, &hi)
			b := bashDriver(t, env0(), "", "fscan", dir, r.Value, sf)
			sc, err := ScanRange(dir, lo, hi, sf)
			if err != nil {
				t.Fatalf("%s: %v", name, err)
			}
			expectSame(t, "fscan "+name, scanLines(sc), b.stdout)
		}
	}
	// a scan with no state file (no claims), and an absent directory (bash: counts of 0)
	dir, _ := focusDir(t, focusCorpus["claims"], scanFiles...)
	b := bashDriver(t, env0(), "", "fscan", dir, "1-6", "")
	sc, _ := ScanRange(dir, 1, 6, "")
	expectSame(t, "fscan no-state", scanLines(sc), b.stdout)
}

// scanLines renders a RangeScan as _focus_range_scan prints it, sorted (FAM order is awk's for-in order).
func scanLines(r RangeScan) string {
	ls := []string{fmt.Sprintf("COUNT\t%d", r.Count), fmt.Sprintf("FILES\t%d", r.Files), fmt.Sprintf("SPAN\t%d", r.Span), fmt.Sprintf("OUTSIDE\t%d", r.Outside)}
	for f, n := range r.Families {
		ls = append(ls, fmt.Sprintf("FAM\t%s\t%d", f, n))
	}
	var m []string
	for _, v := range r.MissingFirst {
		m = append(m, fmt.Sprint(v))
	}
	ls = append(ls, fmt.Sprintf("MISSING\t%d\t%s", r.MissingCount, strings.Join(m, ",")))
	sort.Strings(ls)
	return lines(ls)
}

func TestDifferentialBlockRangeFilter(t *testing.T) {
	paths := []string{"/c/x-bloque1.md", "/c/x-bloque2.md", "/c/x-bloque3.md", "/c/x-block4.md", "/c/x-bloque5-suffix.md", "/c/x-bloque10.md", "plain.md", "/c/a-block7-block8.md", "/c/z-block007.md"}
	for _, withNL := range []bool{true, false} {
		in := strings.Join(paths, "\n")
		if withNL {
			in += "\n"
		}
		for _, rg := range [][2]int{{2, 4}, {1, 1}, {10, 10}, {5, 5}, {6, 9}, {0, 99}, {7, 7}, {3, 2}} {
			for _, num := range []bool{false, true} {
				args := []string{fmt.Sprint(rg[0]), fmt.Sprint(rg[1])}
				if num {
					args = append([]string{"-n"}, args...)
				}
				b := bashDriver(t, env0(), in, "brfilter", args...)
				expectSame(t, fmt.Sprintf("brfilter nl=%v %v n=%v", withNL, rg, num), lines(BlockRangeFilter(paths, rg[0], rg[1], num)), b.stdout)
			}
		}
	}
}

func TestDifferentialInplace(t *testing.T) {
	for _, c := range gapIDCases {
		b := bashDriver(t, env0(), "", "ipid", c.in)
		got := ""
		if id := InplaceGapID(c.in); id != "" {
			got = id + "\n"
		}
		expectSame(t, fmt.Sprintf("ipid %q", c.in), got, b.stdout)
	}
	for _, s := range ipScenarios {
		b := bashDriver(t, env0(), s.rows, "ipcount", s.body)
		expectSame(t, "ipcount "+s.name, fmt.Sprintf("%d\n", InplaceBlockedCount(s.body, s.rows)), b.stdout)
	}
	// F9 (bash drops a final row without a trailing newline) and the IFS-tab collapse of an empty priority cell
	b := bashDriver(t, env0(), "h\tA1\topen\nh\tA2\tblocked", "ipcount", "")
	if b.stdout != "0\n" {
		t.Errorf("premise changed, bash no longer drops the unterminated last row: %q", b.stdout)
	}
	b = bashDriver(t, env0(), "\tA1 x\tblocked\n", "ipcount", "")
	expectSame(t, "ipcount empty-priority-collapse", fmt.Sprintf("%d\n", InplaceBlockedCount("", "\tA1 x\tblocked\n")), b.stdout)
}
