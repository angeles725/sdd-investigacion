package fidelity

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// world is a JVM-free stand-in for javac, javap and the decompiler wrapper. A "class file" is the source text
// plus an lvt marker, so the recompiled class equals the original exactly when the decompiled source does.
type world struct {
	t       *testing.T
	root    string
	bin     string
	fix     string
	javac   string
	javap   string
	dec     string
	version string
	decs    map[string]decBehavior
	calls   []Cmd
	javacRC map[string]int // fixed javac exit status by source base name
	tmpFB   string         // the scratch parent used when TMPDIR is empty
	golden  string         // when set, javap replays captured real output from this directory
}

// decBehavior scripts the decompiler wrapper for one class name.
type decBehavior struct {
	rc    int
	nogRC int // when set, the status in nog mode instead of rc
	out   string
	files map[string]string // file -> content; "@orig" is the source recorded in the class file
}

func newWorld(t *testing.T) *world {
	t.Helper()
	root := t.TempDir()
	w := &world{t: t, root: root, bin: filepath.Join(root, "bin"), fix: filepath.Join(root, "fix"),
		version: "javac 21.0.1\n", decs: map[string]decBehavior{}, javacRC: map[string]int{}, tmpFB: filepath.Join(root, "fallback")}
	for _, d := range []string{w.bin, w.fix, w.tmpFB} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	w.javac, w.javap, w.dec = w.exe("javac"), w.exe("javap"), w.exe("decompiler")
	return w
}

func (w *world) exe(name string) string {
	p := filepath.Join(w.bin, name)
	if err := os.WriteFile(p, []byte("#!/bin/sh\n"), 0o755); err != nil {
		w.t.Fatal(err)
	}
	return p
}

func (w *world) fixture(name, src string) {
	w.t.Helper()
	if err := os.WriteFile(filepath.Join(w.fix, name+".java"), []byte(src), 0o644); err != nil {
		w.t.Fatal(err)
	}
}

// copyDec makes the decompiler return the original source, as the wrapper does on rc 0.
func copyDec(out string, rc int) decBehavior {
	return decBehavior{rc: rc, out: out, files: map[string]string{"@name.java": "@orig"}}
}

const okOut = "OK: in -> out (engine=stub)\n"

func (w *world) run(c Cmd) Result {
	w.calls = append(w.calls, c)
	switch c.Argv[0] {
	case w.javac:
		return w.runJavac(c.Argv[1:])
	case w.javap:
		return w.runJavap(c.Argv[1:])
	case w.dec:
		return w.runDec(c)
	}
	w.t.Fatalf("unexpected program %q", c.Argv[0])
	return Result{}
}

func (w *world) runJavac(args []string) Result {
	if len(args) == 1 && args[0] == "-version" {
		return Result{Output: []byte(w.version)}
	}
	i := 0
	var flags []string
	for args[i] != "-d" {
		flags = append(flags, args[i])
		i++
	}
	out, src := args[i+1], args[i+2]
	base := strings.TrimSuffix(filepath.Base(src), ".java")
	if rc := w.javacRC[base]; rc != 0 {
		return Result{RC: rc, Output: []byte("javac failed\n")}
	}
	body, err := os.ReadFile(src)
	if err != nil {
		w.t.Fatal(err)
	}
	if bytes.Contains(body, []byte("SYNTAX")) {
		return Result{RC: 1, Output: []byte("error: illegal start\n")}
	}
	if bytes.Contains(body, []byte("NOCLASS")) {
		return Result{}
	}
	lvt := "no"
	for _, f := range flags {
		if f == "-g" {
			lvt = "yes"
		}
	}
	class := "src:" + string(body) + "\nlvt:" + lvt + "\n"
	names := []string{base + ".class"}
	if bytes.Contains(body, []byte("INNER")) {
		names = append(names, base+"$In.class")
	}
	if bytes.Contains(body, []byte("PRE")) { // a second class whose name merely ends like the first
		names = append(names, "Pre"+base+".class")
	}
	if bytes.Contains(body, []byte("DUP")) { // the same class file name again, in a subdirectory
		if err := os.MkdirAll(filepath.Join(out, "sub"), 0o755); err != nil {
			w.t.Fatal(err)
		}
		names = append(names, "sub/"+base+".class")
	}
	for _, n := range names {
		if err := os.WriteFile(filepath.Join(out, n), []byte(class), 0o644); err != nil {
			w.t.Fatal(err)
		}
	}
	return Result{}
}

func (w *world) runJavap(args []string) Result {
	flag, cls := args[0], args[len(args)-1]
	if len(args) != 3 || args[1] != "-p" || (flag != "-c" && flag != "-l") {
		return Result{RC: 2, Output: []byte("javap: bad arguments\n")}
	}
	b, err := os.ReadFile(cls)
	if err != nil {
		return Result{RC: 2, Output: []byte("error: file not found\n")}
	}
	text := string(b)
	name := strings.TrimSuffix(filepath.Base(cls), ".class")
	if w.golden != "" {
		return w.replay(name, flag, text)
	}
	switch {
	case flag == "-c" && strings.Contains(text, "JAVAPFAIL"):
		return Result{RC: 1, Output: []byte("javap boom\n")}
	case flag == "-l" && strings.Contains(text, "LVTFAIL"):
		return Result{RC: 1, Output: []byte("javap boom\n")}
	case flag == "-l":
		out := "class " + name + "\n"
		if strings.Contains(text, "lvt:yes") {
			out += "      LocalVariableTable:\n"
		}
		return Result{Output: []byte(out)}
	}
	src, _, _ := strings.Cut(strings.TrimPrefix(text, "src:"), "\n")
	pool := len(cls)%50 + 1 // differs between the original and the recompiled path, like constant-pool indices
	return Result{Output: []byte(fmt.Sprintf("Compiled from \"%s.java\"\nclass %s {\n  0: ldc #%d, 3 // %s\n}\n", name, name, pool, src))}
}

func (w *world) runDec(c Cmd) Result {
	cls, out := c.Argv[1], c.Argv[2]
	name := strings.TrimSuffix(filepath.Base(cls), ".class")
	b := w.decs[name]
	if b.nogRC != 0 && strings.Contains(out, "/nog/") {
		b.rc = b.nogRC
	}
	if b.rc == 124 {
		return Result{RC: 124}
	}
	raw, err := os.ReadFile(cls)
	if err != nil {
		w.t.Fatal(err)
	}
	orig, _, _ := strings.Cut(strings.TrimPrefix(string(raw), "src:"), "\n")
	for f, content := range b.files {
		f = strings.ReplaceAll(f, "@name", name)
		content = strings.ReplaceAll(content, "@orig", orig)
		if err := os.WriteFile(filepath.Join(out, f), []byte(content), 0o644); err != nil {
			w.t.Fatal(err)
		}
	}
	return Result{RC: b.rc, Output: []byte(b.out)}
}

// stdio builds a hermetic Stdio whose environment is PATH=<bin> plus extra KEY=VALUE entries.
func (w *world) stdio(extra ...string) (cli.Stdio, *bytes.Buffer, *bytes.Buffer) {
	environ := append([]string{"PATH=" + w.bin, "RSDD_FIDELITY_DECOMPILER=" + w.dec}, extra...)
	env := map[string]string{}
	for _, kv := range environ {
		k, v, _ := strings.Cut(kv, "=")
		env[k] = v
	}
	var out, errb bytes.Buffer
	return cli.Stdio{Out: &out, Err: &errb, Cwd: w.root,
		Env:     func(k string) string { return env[k] },
		Environ: func() []string { return environ },
		Clock:   func() time.Time { return time.Time{} }}, &out, &errb
}

func (w *world) exec(args []string, extra ...string) (stdout, stderr string, rc int) {
	w.t.Helper()
	s, out, errb := w.stdio(extra...)
	rc = execute(args, s, deps{run: w.run, tmp: w.tmpFB})
	return out.String(), errb.String(), rc
}

func (w *world) args(more ...string) []string {
	return append([]string{"--fixtures", w.fix, "--work", filepath.Join(w.root, "work")}, more...)
}

func (w *world) callsTo(prog string) []Cmd {
	var out []Cmd
	for _, c := range w.calls {
		if c.Argv[0] == prog {
			out = append(out, c)
		}
	}
	return out
}

// replay answers javap from the captured real output: <Class>.<g|nog>.<c|l>.txt.
func (w *world) replay(name, flag, class string) Result {
	mode, kind := "nog", "c"
	if strings.Contains(class, "lvt:yes") {
		mode = "g"
	}
	if flag == "-l" {
		kind = "l"
	}
	b, err := os.ReadFile(filepath.Join(w.golden, name+"."+mode+"."+kind+".txt"))
	if err != nil {
		w.t.Fatalf("no captured javap output: %v", err)
	}
	return Result{Output: b}
}
