//go:build !nodiff

package gate

import (
	"os"
	"os/exec"
	"sort"
	"strings"
	"testing"
)

// TestRetroFindParity compares the native walk with the `find` the bash ran, on a tree of awkward names: the same
// paths in the same order (directory order, depth first), at depth 4 and no deeper, with the same -path / -iname
// filters.
func TestRetroFindParity(t *testing.T) {
	w := newRGWorld(t, false)
	d := w.root + "/t"
	for _, p := range []string{
		"retros/a.md", "retros/INDEX.md", "retros/x-index.MD", "retros/.md", "retros/notes.txt", "retros/sub/deep.md", "a/retros/b.md",
		"a/b/retros/c.md", "a/b/c/retros/d.md", "a/b/c/d/retros/e.md", "xretros/y.md", "retros.md", ".git/retros/z.md", "a/.git/retros/z.md",
		"a/.gitx/retros/z.md", "r/retros/dir.md/inner.md", "Retros/upper.md", "a b/retros/space name.md", "nl/retros/new\nline.md",
	} {
		w.write0(d+"/"+p, "x\n")
	}
	must(t, os.Symlink(d+"/retros", d+"/linked-retros"))
	must(t, os.Symlink(d+"/retros/a.md", d+"/retros/link.md"))
	g := &retroGate{target: d}
	got := g.findRetros(true)
	out, err := exec.Command("find", "-H", d, "-maxdepth", "4", "-path", "*/retros/*.md", "-not", "-path", "*/.git/*", "-not", "-iname", "*index*.md", "-print0").Output()
	if err != nil {
		t.Fatal(err)
	}
	want := strings.Split(strings.TrimSuffix(string(out), "\x00"), "\x00")
	if strings.Join(got, "|") != strings.Join(want, "|") {
		t.Errorf("walk differs from find:\n go   %q\n find %q", got, want)
	}
	if len(got) < 8 {
		t.Errorf("the fixture should match many paths, got %d", len(got))
	}
}

// TestRetroGateDifferential runs every scenario in two identical worlds, one against the frozen original
// (testdata/legacy/retro-gate.sh) and one against the port, and requires the same stdout, stderr and exit code for
// every run and the same state files under <target>/.claude. The bash side also has to satisfy the scenario's own
// checks, so an expectation written from reading the code cannot drift from what the original does.
func TestRetroGateDifferential(t *testing.T) {
	t.Parallel()
	for _, c := range rgCases {
		if c.goOnly {
			continue
		}
		t.Run(c.id, func(t *testing.T) {
			t.Parallel()
			bash := c.execute(t, true)
			port := c.execute(t, false)
			t.Run("bash-satisfies-checks", func(t *testing.T) { c.check(t, bash) })
			for i := range bash {
				b, g := bash[i], port[i]
				if b.out != g.out || b.err != g.err || b.rc != g.rc {
					t.Errorf("run %d differs:\n bash rc=%d out=%q\n  err=%q\n  go  rc=%d out=%q\n  err=%q", i, b.rc, b.out, b.err, g.rc, g.out, g.err)
				}
				if diff := treeDiff(b.tree, g.tree); diff != "" {
					t.Errorf("run %d state files differ: %s", i, diff)
				}
				if len(b.seeded) != len(g.seeded) {
					t.Errorf("run %d seeder calls: bash %v go %v", i, b.seeded, g.seeded)
				}
			}
		})
	}
}

func treeDiff(a, b map[string]string) string {
	var keys []string
	seen := map[string]bool{}
	for k := range a {
		keys = append(keys, k)
		seen[k] = true
	}
	for k := range b {
		if !seen[k] {
			keys = append(keys, k)
		}
	}
	sort.Strings(keys)
	for _, k := range keys {
		if av, ok := a[k]; !ok {
			return "only in go: " + k
		} else if bv, ok := b[k]; !ok {
			return "only in bash: " + k
		} else if av != bv {
			return k + ": bash=" + av + " go=" + bv
		}
	}
	return ""
}
