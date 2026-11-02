//go:build unix

package ghidra

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/adapter"
)

const mountExt4 = "1 0 0:1 / / rw - ext4 /dev/sda rw\n"

var fixedNow = time.Date(2026, 11, 2, 12, 0, 0, 123456000, time.UTC)

func must(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}

// smallCaps are the caps every test run asks for; the curated documents the fake analyzer writes carry them.
var smallCaps = []string{"--max-functions", "2", "--max-strings", "2", "--max-references", "2", "--max-string-chars", "32"}

// world is one hermetic scenario: a fake Ghidra tree and JDK, the fake launcher, the kit's toolbelt and injected deps.
type world struct {
	t      *testing.T
	root   string
	gh     string
	jdk    string
	input  string
	env    map[string]string
	d      deps
	out    bytes.Buffer
	errBuf bytes.Buffer
}

func newWorld(t *testing.T) *world {
	t.Helper()
	for _, tool := range []string{"/usr/bin/env", "/usr/bin/prlimit", "/bin/sh", "/bin/true"} {
		if _, err := os.Stat(tool); err != nil {
			t.Skipf("%s is required by the sandboxed command line: %v", tool, err)
		}
	}
	root, err := filepath.EvalSymlinks(t.TempDir())
	must(t, err)
	w := &world{t: t, root: root, gh: filepath.Join(root, "gh"), jdk: filepath.Join(root, "jdk"), input: filepath.Join(root, "target.bin")}
	for _, d := range []string{"gh/support", "gh/Ghidra/Framework/Utility/lib", "jdk/bin", "bin", "toolbelt/ghidra"} {
		must(t, os.MkdirAll(filepath.Join(root, d), 0o755))
	}
	must(t, os.WriteFile(w.gh+"/Ghidra/application.properties", []byte("application.name=Ghidra\napplication.version=12.1-test\n"), 0o644))
	for _, f := range []string{"support/launch.sh", "support/launch.properties", "support/LaunchSupport.jar", "Ghidra/Framework/Utility/lib/Utility.jar"} {
		must(t, os.WriteFile(filepath.Join(w.gh, f), []byte(f+"\n"), 0o644))
	}
	java := "#!/bin/sh\n[ \"${1:-}\" = -version ] && { echo 'openjdk version \"21.0.1\"' >&2; exit 0; }\nexit 0\n"
	must(t, os.WriteFile(w.jdk+"/bin/java", []byte(java), 0o755))
	must(t, os.WriteFile(w.jdk+"/bin/javap", []byte(java), 0o755))
	must(t, os.WriteFile(root+"/toolbelt/ghidra/CuratedEvidenceExporter.java", []byte("// exporter\n"), 0o644))
	must(t, os.WriteFile(w.input, []byte("\x7fELF fake target\n"), 0o644))
	linkBwrap(t, root+"/bin/bwrap")
	w.headless("good")
	w.env = map[string]string{
		"ANALYZE_HEADLESS": w.gh + "/support/analyzeHeadless", "JAVA_HOME": w.jdk, "RSDD_BWRAP": root + "/bin/bwrap",
		"RSDD_TEST_ONLY_UNTRUSTED_BWRAP": "1", "PATH": "/usr/bin:/bin",
	}
	w.d = deps{mountinfo: func() (string, error) { return mountExt4, nil }, uid: os.Getuid()}
	return w
}

// curatedDoc is a valid ghidra-curated-evidence.v1 document for smallCaps; mods adjust it.
func curatedDoc(mods ...func(map[string]any)) map[string]any {
	caps := map[string]any{"functions": 2, "symbols": 2, "imports": 2, "exports": 2, "strings": 2, "references": 2, "string_chars": 32}
	counts, trunc := map[string]any{}, map[string]any{}
	d := map[string]any{
		"schema": "ghidra-curated-evidence.v1", "status": "complete",
		"program":  map[string]any{"name": "target.bin", "format": "ELF", "language": "x", "compiler": "x", "image_base": "0", "md5": "0"},
		"analysis": map[string]any{"timed_out": false}, "caps": caps, "counts": counts, "truncation": trunc,
		"string_values_truncated": 0, "warnings": []any{}, "errors": []any{}, "limitations": []any{},
	}
	for _, k := range kinds {
		d[k] = []any{}
		counts[k] = map[string]any{"emitted": 0, "observed": 0, "exact": true}
		trunc[k] = false
	}
	for _, m := range mods {
		m(d)
	}
	return d
}

func curatedBytes(d map[string]any) []byte {
	b, err := json.Marshal(d)
	if err != nil {
		panic(err)
	}
	return append(b, '\n')
}

// headless installs a fake analyzeHeadless whose behaviour is chosen by mode. It parses the exporter's arguments
// as the real one would (output path after the script name, the two log paths) and then acts.
func (w *world) headless(mode string, extra ...string) {
	body := map[string]string{
		"good":       `printf '%s' '` + string(curatedBytes(curatedDoc())) + `' >"$out"`,
		"partial":    `printf '%s' '` + string(curatedBytes(curatedDoc(partialFunctions, func(d map[string]any) { d["status"] = "partial" }))) + `' >"$out"`,
		"dishonest":  `printf '%s' '` + string(curatedBytes(curatedDoc(partialFunctions))) + `' >"$out"`,
		"boolean":    `printf '%s' '` + string(curatedBytes(curatedDoc(func(d map[string]any) { d["counts"].(map[string]any)["functions"].(map[string]any)["emitted"] = false }))) + `' >"$out"`,
		"nonzero":    `exit 9`,
		"missing":    `:`,
		"malformed":  `printf '{bad' >"$out"`,
		"sentinel":   `printf 'RSDD-SENTINEL' >"$out"`,
		"flood":      `yes x`,
		"timeout":    `sleep 4`,
		"loglink":    `rm -f "$log"; ln -s ` + shellQuote(filepath.Join(w.root, "outside.log")) + ` "$log"; exit 9`,
		"descendant": `sleep 30 & echo $! >` + shellQuote(filepath.Join(w.root, "child.pid")) + `; exit 9`,
		"symlinkout": `printf x >` + shellQuote(filepath.Join(w.root, "outside.json")) + `; rm -f "$out"; ln -s ` + shellQuote(filepath.Join(w.root, "outside.json")) + ` "$out"`,
		"bigout":     `head -c 5000 /dev/zero | tr '\0' x >"$out"`,
	}[mode]
	if body == "" {
		w.t.Fatalf("unknown headless mode %q", mode)
	}
	script := "#!/bin/sh\nout=''; log=''; slog=''; prev=''\n" +
		"for x in \"$@\"; do\n [ \"$prev\" = CuratedEvidenceExporter.java ] && out=\"$x\"\n [ \"$prev\" = -log ] && log=\"$x\"\n [ \"$prev\" = -scriptlog ] && slog=\"$x\"\n prev=\"$x\"\ndone\n" +
		"printf 'stdout\\n'; printf 'log\\n' >\"$log\"; printf 'scriptlog\\n' >\"$slog\"\n" + strings.Join(extra, "\n") + "\n" + body + "\n"
	p := w.gh + "/support/analyzeHeadless"
	_ = os.Remove(p)
	must(w.t, os.WriteFile(p, []byte(script), 0o755))
}

func partialFunctions(d map[string]any) {
	d["truncation"].(map[string]any)["functions"] = true
	d["counts"].(map[string]any)["functions"] = map[string]any{"emitted": 0, "observed": 1, "exact": false}
}

func shellQuote(s string) string { return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'" }

func (w *world) stdio() cli.Stdio {
	env := w.env
	return cli.Stdio{
		In: strings.NewReader(""), Out: &w.out, Err: &w.errBuf, Cwd: w.root,
		Env: func(k string) string { return env[k] },
		Environ: func() []string {
			var l []string
			for k, v := range env {
				l = append(l, k+"="+v)
			}
			return l
		},
		Clock: func() time.Time { return fixedNow },
	}
}

// run executes the command on <root>/<output> with the default input, toolbelt and small caps plus extra args.
func (w *world) run(output string, extra ...string) int {
	w.t.Helper()
	args := append([]string{"--input", w.input, "--output", filepath.Join(w.root, output), "--toolbelt", filepath.Join(w.root, "toolbelt")}, smallCaps...)
	return w.exec(append(args, extra...)...)
}

func (w *world) exec(args ...string) int {
	w.t.Helper()
	w.out.Reset()
	w.errBuf.Reset()
	return execute(args, w.stdio(), w.d)
}

func (w *world) path(rel string) string { return filepath.Join(w.root, rel) }

func (w *world) exists(rel string) bool {
	_, err := os.Lstat(w.path(rel))
	return err == nil
}

func (w *world) readJSON(rel string) map[string]any {
	w.t.Helper()
	b, err := os.ReadFile(w.path(rel))
	if err != nil {
		w.t.Fatal(err)
	}
	var v map[string]any
	if err := json.Unmarshal(b, &v); err != nil {
		w.t.Fatalf("%s: %v", rel, err)
	}
	return v
}

// verify runs the manifest CLI port's `validate` and `verify` over a published output.
func (w *world) verify(out string) {
	w.t.Helper()
	var o, e bytes.Buffer
	s := w.stdio()
	s.Out, s.Err = &o, &e
	m := filepath.Join(out, manifestFile)
	if rc := adapter.ManifestRun([]string{"validate", m}, s); rc != 0 {
		w.t.Fatalf("manifest validate rc=%d: %s", rc, e.String())
	}
	if rc := adapter.ManifestRun([]string{"verify", "--root", out, m}, s); rc != 0 {
		w.t.Fatalf("manifest verify rc=%d: %s", rc, e.String())
	}
}

// refused asserts exit 2, exactly "corroborate-ghidra: <msg>\n" on stderr, nothing on stdout and no output/stage left.
func (w *world) refused(rc int, out, msg string) {
	w.t.Helper()
	if rc != 2 {
		w.t.Fatalf("rc=%d stderr=%q", rc, w.errBuf.String())
	}
	if got, want := w.errBuf.String(), "corroborate-ghidra: "+msg+"\n"; got != want {
		w.t.Fatalf("stderr:\n got %q\nwant %q", got, want)
	}
	if w.out.Len() != 0 {
		w.t.Fatalf("stdout must stay empty: %q", w.out.String())
	}
	if out != "" && w.exists(out) {
		w.t.Fatalf("%s must not be published after a refusal", out)
	}
}

func sub(m map[string]any, keys ...string) any {
	var v any = m
	for _, k := range keys {
		v = v.(map[string]any)[k]
	}
	return v
}
