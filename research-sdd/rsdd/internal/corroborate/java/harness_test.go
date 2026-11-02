package java

import (
	"archive/zip"
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/proc"
)

// TestMain lets the test binary stand in for rsdd: started with the hidden helper command it becomes the rlimit
// re-exec helper, so the adapter's RLIMIT_FSIZE is exercised without an installed binary.
func TestMain(m *testing.M) {
	if len(os.Args) > 1 && os.Args[1] == proc.HelperCommand {
		os.Exit(proc.HelperMain(os.Args[2:], os.Environ(), os.Stderr))
	}
	os.Exit(m.Run())
}

// ---- class files and archives -----------------------------------------------------------------------------------

func u16(v int) []byte { return []byte{byte(v >> 8), byte(v)} }
func u32(v int) []byte { return []byte{byte(v >> 24), byte(v >> 16), byte(v >> 8), byte(v)} }
func cat(parts ...[]byte) []byte {
	return bytes.Join(parts, nil)
}
func utf8c(s string) []byte { return cat([]byte{1}, u16(len(s)), []byte(s)) }
func attr(name int, body []byte) []byte {
	return cat(u16(name), u32(len(body)), body)
}

// classBytes is a minimal valid class of the given major with one method; lvt gives its Code attribute a
// LocalVariableTable.
func classBytes(major int, lvt bool) []byte {
	codeAttrs := u16(0)
	if lvt {
		codeAttrs = cat(u16(1), attr(2, []byte{0, 0}))
	}
	code := cat(u16(0), u16(1), u32(1), []byte{0xb1}, u16(0), codeAttrs)
	method := cat(u16(1), u16(1), u16(1), u16(1), attr(1, code))
	return cat([]byte{0xca, 0xfe, 0xba, 0xbe}, u16(0), u16(major), u16(3), utf8c("Code"), utf8c("LocalVariableTable"),
		u16(0x21), u16(0), u16(0), u16(0), u16(0), u16(1), method, u16(0))
}

// entry is one archive member.
type entry struct {
	name   string
	data   []byte
	mode   os.FileMode // 0: the default regular file
	stored bool
}

// writeJar writes a ZIP/JAR holding the entries in order.
func writeJar(t testing.TB, path string, entries ...entry) {
	t.Helper()
	var buf bytes.Buffer
	zw := zip.NewWriter(&buf)
	for _, e := range entries {
		h := &zip.FileHeader{Name: e.name, Method: zip.Deflate}
		if e.stored {
			h.Method = zip.Store
		}
		if e.mode != 0 {
			h.SetMode(e.mode)
		}
		w, err := zw.CreateHeader(h)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := w.Write(e.data); err != nil {
			t.Fatal(err)
		}
	}
	if err := zw.Close(); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, buf.Bytes(), 0o644); err != nil {
		t.Fatal(err)
	}
}

// fixtureEntries is the standard target: one class, a directory entry and a manifest.
func fixtureEntries() []entry {
	return []entry{
		{name: "META-INF/MANIFEST.MF", data: []byte("Manifest-Version: 1.0\n")},
		{name: "fixture/", data: nil},
		{name: "fixture/App.class", data: classBytes(65, false)},
	}
}

// ---- fake runtime -------------------------------------------------------------------------------------------------

const fakeBwrap = `#!/bin/sh
# Stands in for Bubblewrap: drop every option up to "--", then run the command in the current directory.
while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do shift; done
shift
exec "$@"
`

const fakeJava = `#!/bin/sh
shift
[ "$1" = -jar ] || exit 90
jar=$2; shift 2
name=$(basename "$jar" .jar)
mode=ok
[ -f "$JAVA_HOME/mode-$name" ] && mode=$(cat "$JAVA_HOME/mode-$name")
case "$name" in
  vineflower) shift; in=$1; out=$2 ;;
  cfr) in=$1; [ "$2" = --outputdir ] || exit 91; out=$3 ;;
  procyon) [ "$1" = -jar ] || exit 92; in=$2; [ "$3" = -o ] || exit 93; out=$4 ;;
esac
case "$mode" in
  fail) echo 'stub failure' >&2; exit 7 ;;
  slow) sleep 3 ;;
  spam)
    mkdir -p "$out/fixture"; i=1
    while [ "$i" -le 20 ]; do head -c 1024 /dev/zero > "$out/fixture/$i.java"; i=$((i+1)); done
    head -c 131072 /dev/zero >&2; sleep 30; exit 8 ;;  # still running when the cap is seen, so it is always stopped
  link) mkdir -p "$out"; ln -s /etc/passwd "$out/link.java" ;;
esac
mkdir -p "$out/fixture"
printf 'package fixture; public final class App { public static void main(String[] a) {} }\n' > "$out/fixture/App.java"
for n in A Z; do printf 'final class %s {}\n' "$n" > "$out/fixture/$n.java"; done
printf 'stage=%s\n' "$PWD" >&2
echo "adapter=$name.jar input=$(basename "$in")"
`

const fakeJavap = `#!/bin/sh
printf 'stage=%s\n' "$PWD" >&2
cat <<'EOF'
public final class fixture.App {
  public static void main(java.lang.String[]);
    descriptor: ([Ljava/lang/String;)V
}
EOF
`

const fakeJdeps = `#!/bin/sh
printf 'stage=%s\n' "$PWD" >&2
echo 'fixture.App -> java.lang.Object java.base'
`

// harness is a fake JDK, a fake Bubblewrap, three stub decompiler JARs and an input JAR in a temp directory.
type harness struct {
	t        *testing.T
	root     string
	javaHome string
	bwrap    string
	input    string
	tools    map[string]string
	env      map[string]string
	clock    time.Time
}

func newHarness(t *testing.T) *harness {
	t.Helper()
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	h := &harness{t: t, root: root, javaHome: filepath.Join(root, "jdk"), tools: map[string]string{},
		clock: time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC)}
	h.bwrap = filepath.Join(h.javaHome, "bin", "bwrap")
	for name, body := range map[string]string{"bwrap": fakeBwrap, "java": fakeJava, "javap": fakeJavap, "jdeps": fakeJdeps} {
		h.write(filepath.Join(h.javaHome, "bin", name), body, 0o755)
	}
	h.write(filepath.Join(root, "wrapper-trap"), "#!/bin/sh\ntouch '"+filepath.Join(root, "WRAPPER_EXECUTED")+"'\nexit 99\n", 0o755)
	h.write(filepath.Join(root, "analysis_manifest.py"), "# never loaded\n", 0o644)
	// A published root keeps trusted-tools read-only (0500); open it up again so the temp directory can go.
	t.Cleanup(func() {
		_ = filepath.WalkDir(root, func(p string, d os.DirEntry, err error) error {
			if err == nil && d.IsDir() && d.Name() == "trusted-tools" {
				_ = os.Chmod(p, 0o700)
			}
			return nil
		})
	})
	h.input = filepath.Join(root, "space dir", "fixture app.jar")
	if err := os.MkdirAll(filepath.Dir(h.input), 0o755); err != nil {
		t.Fatal(err)
	}
	writeJar(t, h.input, fixtureEntries()...)
	h.env = map[string]string{"JAVA_HOME": h.javaHome, "RSDD_BWRAP": h.bwrap, "HOME": root, "SECRET_TOKEN": "do-not-persist"}
	for _, name := range engineNames[:3] {
		h.useTool(name, name+".jar", "stub "+name)
	}
	return h
}

func (h *harness) write(path, body string, mode os.FileMode) {
	h.t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		h.t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(body), mode); err != nil {
		h.t.Fatal(err)
	}
}

// useTool installs a stub decompiler JAR under file and pins the engine to it.
func (h *harness) useTool(name, file, content string) {
	h.t.Helper()
	p := filepath.Join(h.root, "tools", file)
	h.write(p, content, 0o644)
	sum := sha256.Sum256([]byte(content))
	h.tools[name] = p
	h.env["RSDD_CORROBORATE_"+strings.ToUpper(name)] = p
	h.env[strings.ToUpper(name)+"_SHA256"] = hex.EncodeToString(sum[:])
}

// mode makes the fake java behave as mode ("fail", "slow", "spam", "link") for the engine.
func (h *harness) mode(name, mode string) {
	h.write(filepath.Join(h.javaHome, "mode-"+name), mode, 0o644)
}

func (h *harness) args(extra ...string) []string {
	return append([]string{"--decompile-wrapper", filepath.Join(h.root, "wrapper-trap"), "--manifest-module", filepath.Join(h.root, "analysis_manifest.py"),
		"--input", h.input, "--timeout-seconds", "5", "--max-heap", "128m", "--max-files", "100", "--max-bytes", "1048576", "--max-classes", "100"}, extra...)
}

// result is one run's observable outcome.
type result struct {
	rc          int
	stdout, err string
}

// stdio is the harness environment as a cli.Stdio with a fixed clock.
func (h *harness) stdio(out, errb io.Writer) cli.Stdio {
	environ := make([]string, 0, len(h.env))
	for k, v := range h.env {
		environ = append(environ, k+"="+v)
	}
	return cli.Stdio{
		Out: out, Err: errb, Cwd: h.root,
		Env:     func(k string) string { return h.env[k] },
		Environ: func() []string { return environ },
		Clock:   func() time.Time { return h.clock },
	}
}

// run executes the command with the harness environment and the fake seams.
func (h *harness) run(args ...string) result {
	h.t.Helper()
	var out, errb bytes.Buffer
	e := newEnv(h.stdio(&out, &errb))
	e.helper = nil
	e.mountRoot = filepath.Join(h.root, "rsdd-mount")
	e.uid = 0
	e.owner = func(os.FileInfo) (int, bool) { return 0, true }
	rc := e.main(args)
	return result{rc: rc, stdout: out.String(), err: errb.String()}
}

// report reads and decodes the published report below dir.
func (h *harness) report(dir string) map[string]any {
	h.t.Helper()
	b, err := os.ReadFile(filepath.Join(dir, schema+".json"))
	if err != nil {
		h.t.Fatal(err)
	}
	var v map[string]any
	if err := json.Unmarshal(b, &v); err != nil {
		h.t.Fatal(err)
	}
	return v
}

func (h *harness) out(name string) string { return filepath.Join(h.root, name) }

func (h *harness) exists(parts ...string) bool {
	_, err := os.Lstat(filepath.Join(parts...))
	return err == nil
}

// get walks a decoded JSON document by keys.
func get(v any, keys ...string) any {
	for _, k := range keys {
		m, ok := v.(map[string]any)
		if !ok {
			return nil
		}
		v = m[k]
	}
	return v
}
