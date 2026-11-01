package fidelity

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/proc"
)

// TestNormalise: constant-pool references and the "Compiled from" header go; offsets and targets stay.
func TestNormalise(t *testing.T) {
	cases := []struct{ name, in, want string }{
		{"pool ref", "  0: ldc #12\n", "  0: ldc \n"},
		{"pool ref with index", "  0: invokedynamic #7, 3\n", "  0: invokedynamic \n"},
		{"pool ref with spaces after comma", "  0: x #7,   3 // y\n", "  0: x  // y\n"},
		{"several refs", "#1 #22 #333\n", "  \n"},
		{"hash without digits stays", "# no digits #x\n", "# no digits #x\n"},
		{"offsets and targets stay", "  4: goto 17\n  7: ifeq 12\n", "  4: goto 17\n  7: ifeq 12\n"},
		{"compiled from removed", "Compiled from \"A.java\"\nclass A {\n}\n", "class A {\n}\n"},
		{"compiled from only at line start", "  Compiled from x\n", "  Compiled from x\n"},
		{"compiled from after substitution", "Compiled from #1\nkeep\n", "keep\n"},
		{"comma without index keeps the comma", "#7, x\n", ", x\n"},
		{"no trailing newline", "a #1", "a "},
		{"empty", "", ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := normalise([]byte(c.in)); got != c.want {
				t.Fatalf("got %q, want %q", got, c.want)
			}
		})
	}
}

// TestSameBytecode: the comparison is on the normalised text with trailing newlines ignored, like $(...).
func TestSameBytecode(t *testing.T) {
	cases := []struct {
		name string
		a, b string
		want bool
	}{
		{"identical", "x\n", "x\n", true},
		{"pool indices differ", "ldc #1\n", "ldc #99, 3\n", true},
		{"header differs", "Compiled from \"A.java\"\nx\n", "Compiled from \"B.java\"\nx\n", true},
		{"trailing newlines differ", "x\n\n\n", "x", true},
		{"offset differs", "  0: nop\n", "  1: nop\n", false},
		{"body differs", "a\n", "b\n", false},
		{"leading blank line is content", "\nx\n", "x\n", false},
		{"inner blank line is content", "a\n\nb\n", "a\nb\n", false},
	}
	for _, c := range cases {
		if got := sameBytecode([]byte(c.a), []byte(c.b)); got != c.want {
			t.Errorf("%s: got %v", c.name, got)
		}
	}
}

// TestEngineOf: the wrapper's "(engine=<e>)" label from either status-line shape; the last matching line wins.
func TestEngineOf(t *testing.T) {
	cases := []struct{ name, in, want string }{
		{"ok line", "OK: a -> b  (engine=vineflower)\n", "vineflower"},
		{"degraded line", "DEGRADED: a -> b  (engine=cfr units=1 primary=error)\n", "cfr"},
		{"last line wins", "OK (engine=a)\nnoise\nOK (engine=b)\n", "b"},
		{"last occurrence on a line wins", "x (engine=a) y (engine=b)\n", "b"},
		{"no engine", "UNIT: x\n", ""},
		{"empty label", "(engine= x)\n", ""},
		{"no closing", "(engine=a\n", ""},
		{"charset", "(engine=A_b.c-1)\n", "A_b.c-1"},
		{"bad char stops the label", "(engine=a/b)\n", ""},
		{"no trailing newline", "(engine=z)", "z"},
		{"empty log", "", ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := engineOf([]byte(c.in)); got != c.want {
				t.Fatalf("got %q, want %q", got, c.want)
			}
		})
	}
}

// TestProcRunner runs the production runner against the shell: status, combined output, bound and spawn failure.
func TestProcRunner(t *testing.T) {
	if _, err := os.Stat("/bin/sh"); err != nil {
		t.Skip("no /bin/sh")
	}
	env := []string{"PATH=/bin:/usr/bin"}
	r := Runner(procRun)
	t.Run("status and output order", func(t *testing.T) {
		got := r(Cmd{Argv: []string{"/bin/sh", "-c", "echo out; echo err >&2; exit 4"}, Env: env, Dir: t.TempDir(), Timeout: 5 * time.Second})
		if got.RC != 4 || string(got.Output) != "out\nerr\n" {
			t.Fatalf("%+v %q", got, got.Output)
		}
	})
	t.Run("bound hit is 124 whatever the child was doing", func(t *testing.T) {
		start := time.Now()
		got := r(Cmd{Argv: []string{"/bin/sh", "-c", "sleep 30"}, Env: env, Dir: t.TempDir(), Timeout: 200 * time.Millisecond})
		if got.RC != 124 {
			t.Fatalf("rc=%d", got.RC)
		}
		if time.Since(start) > 10*time.Second {
			t.Fatalf("not stopped promptly: %v", time.Since(start))
		}
	})
	t.Run("killed by a signal is 128+N", func(t *testing.T) {
		got := r(Cmd{Argv: []string{"/bin/sh", "-c", "kill -9 $$"}, Env: env, Dir: t.TempDir(), Timeout: 5 * time.Second})
		if got.RC != 137 {
			t.Fatalf("rc=%d", got.RC)
		}
	})
	t.Run("signal 1 is 129", func(t *testing.T) {
		got := r(Cmd{Argv: []string{"/bin/sh", "-c", "kill -HUP $$"}, Env: env, Dir: t.TempDir(), Timeout: 5 * time.Second})
		if got.RC != 129 {
			t.Fatalf("rc=%d", got.RC)
		}
	})
	t.Run("an invalid spec is 127, not a panic", func(t *testing.T) {
		if got := r(Cmd{Argv: []string{"/bin/sh"}, Env: env}); got.RC != 127 || len(got.Output) == 0 {
			t.Fatalf("%+v", got)
		}
	})
	t.Run("a program that cannot start is 127", func(t *testing.T) {
		got := r(Cmd{Argv: []string{"/nonexistent/prog"}, Env: env, Dir: t.TempDir(), Timeout: 5 * time.Second})
		if got.RC != 127 {
			t.Fatalf("rc=%d", got.RC)
		}
	})
	t.Run("output cap is a failure, not a pass", func(t *testing.T) {
		old := maxOutput
		maxOutput = 1000
		t.Cleanup(func() { maxOutput = old })
		got := r(Cmd{Argv: []string{"/bin/sh", "-c", "yes | head -c 100000"}, Env: env, Dir: t.TempDir(), Timeout: 20 * time.Second})
		if got.RC == 0 {
			t.Fatalf("a run cut at the output cap reported success")
		}
		if len(got.Output) > maxOutput {
			t.Fatalf("output %d over the cap", len(got.Output))
		}
	})
}

// TestFindFiles: only regular files count (not a directory named like a class, not a symlink), recursively and sorted.
// TestExitStatus: the proc result as a shell status; a run cut at the output cap never reads as success.
func TestExitStatus(t *testing.T) {
	for _, c := range []struct {
		res  proc.Result
		want int
	}{
		{proc.Result{ReturnCode: 0}, 0},
		{proc.Result{ReturnCode: 4}, 4},
		{proc.Result{ReturnCode: 3}, 3},
		{proc.Result{ReturnCode: -9}, 137},
		{proc.Result{ReturnCode: -1}, 129},
		{proc.Result{Reason: proc.ReasonTimeout, ReturnCode: -15}, 124},
		{proc.Result{Reason: proc.ReasonTimeout, ReturnCode: 0}, 124},
		{proc.Result{Reason: proc.ReasonOutputCap, ReturnCode: 0}, 1},
		{proc.Result{Reason: proc.ReasonOutputCap, ReturnCode: 7}, 7},
		{proc.Result{Reason: proc.ReasonOutputCap, ReturnCode: -15}, 143},
	} {
		if got := exitStatus(c.res); got != c.want {
			t.Errorf("%+v: %d, want %d", c.res, got, c.want)
		}
	}
}

func TestFindFiles(t *testing.T) {
	w := newWorld(t)
	root := filepath.Join(w.root, "d")
	for _, d := range []string{"a.class", "z", "b"} {
		if err := os.MkdirAll(filepath.Join(root, d), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	for _, f := range []string{"z/two.class", "b/one.class", "top.class", "note.txt", "a.class/in.class"} {
		if err := os.WriteFile(filepath.Join(root, f), nil, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.Symlink(filepath.Join(root, "top.class"), filepath.Join(root, "link.class")); err != nil {
		t.Fatal(err)
	}
	s, _, _ := w.stdio()
	e := &experiment{s: s}
	got := strings.Join(e.findFiles("d", ".class"), ",")
	if want := "d/a.class/in.class,d/b/one.class,d/top.class,d/z/two.class"; got != want {
		t.Fatalf("got %s, want %s", got, want)
	}
}

func TestUsableTool(t *testing.T) {
	dir := t.TempDir()
	exe := dir + "/x"
	plain := dir + "/p"
	for p, mode := range map[string]os.FileMode{exe: 0o755, plain: 0o644} {
		if err := os.WriteFile(p, nil, mode); err != nil {
			t.Fatal(err)
		}
	}
	for _, c := range []struct {
		path string
		want bool
	}{{exe, true}, {plain, false}, {dir, false}, {dir + "/absent", false}, {"", false}} {
		if got := usableTool("", c.path); got != c.want {
			t.Errorf("%q: %v", c.path, got)
		}
	}
	if !usableTool(dir, "x") || usableTool(dir, "p") { // relative paths resolve against the working directory
		t.Error("relative path not resolved against cwd")
	}
}
