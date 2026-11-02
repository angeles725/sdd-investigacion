//go:build unix

package ghidra

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// rawHeadless installs an analyzeHeadless with exactly this body (no standard log header), so a test controls
// every byte the fake analyzer writes.
func (w *world) rawHeadless(body string) {
	p := w.gh + "/support/analyzeHeadless"
	_ = os.Remove(p)
	must(w.t, os.WriteFile(p, []byte("#!/bin/sh\n"+body+"\n"), 0o755))
}

// outFinder is the shell prologue that sets $out to the exporter's output path argument.
const outFinder = "prev=''; for x in \"$@\"; do [ \"$prev\" = CuratedEvidenceExporter.java ] && out=\"$x\"; prev=\"$x\"; done\n"

func goodDoc() string { return string(curatedBytes(curatedDoc())) }

func sha(b []byte) string {
	s := sha256.Sum256(b)
	return "sha256:" + hex.EncodeToString(s[:])
}

func readFile(t *testing.T, p string) []byte {
	t.Helper()
	b, err := os.ReadFile(p)
	must(t, err)
	return b
}

// countRegular is the number of regular files under dir, symlinks followed, as the evidence file cap counts them.
func countRegular(t *testing.T, dir string) int {
	t.Helper()
	n := 0
	must(t, filepath.Walk(dir, func(p string, fi os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if fi.Mode().IsRegular() {
			n++
		}
		return nil
	}))
	return n
}

func logsTotal(t *testing.T, dir string) int64 {
	t.Helper()
	var total int64
	for _, f := range []string{"stdout.txt", "stderr.txt", "application.log", "script.log"} {
		fi, err := os.Stat(filepath.Join(dir, "logs", f))
		must(t, err)
		total += fi.Size()
	}
	return total
}

func TestManifestBindsTheStagedChainWithoutExecutingTheTarget(t *testing.T) {
	w := newWorld(t)
	must(t, os.WriteFile(w.input, []byte("#!/bin/sh\ntouch "+shellQuote(w.path("TARGET_EXECUTED"))+"\n"), 0o755))
	if rc := w.run("out"); rc != 0 {
		t.Fatalf("rc=%d %q", rc, w.errBuf.String())
	}
	if w.exists("TARGET_EXECUTED") {
		t.Fatal("the analysed target was executed")
	}
	if got := readFile(t, w.path("out/input/target.bin")); !strings.HasPrefix(string(got), "#!/bin/sh") {
		t.Fatalf("staged target: %q", got)
	}
	r, m := w.readJSON("out/report.json"), w.readJSON("out/"+manifestFile)
	if _, has := r["ghidra"].(map[string]any)["manifest_identity"]; has {
		t.Fatal("the report must not embed the manifest identity")
	}
	staged := map[string]bool{}
	for _, p := range r["provenance"].([]any) {
		staged[sub(p.(map[string]any), "staged", "path").(string)] = true
	}
	delete(staged, "tool/bwrap")
	argv := m["argv"].([]any)
	tool := map[string]bool{}
	for _, a := range sub(m, "tool", "artifacts").([]any) {
		art := a.(map[string]any)
		tool[art["path"].(string)] = true
		if idx := int(art["argv_index"].(float64)); argv[idx-1] != "--ro-bind" || argv[idx] != art["path"] {
			t.Errorf("artifact %v is not bound by --ro-bind at its argv slot", art)
		}
	}
	if !reflect.DeepEqual(tool, staged) || len(tool) != 8 {
		t.Fatalf("manifest artifacts %v differ from the staged provenance %v", tool, staged)
	}
	for _, a := range argv {
		if strings.HasPrefix(a.(string), "RSDD_PROVENANCE_") {
			t.Fatalf("provenance leaked into argv: %v", a)
		}
	}
	found := false
	for _, o := range m["outputs"].([]any) {
		found = found || sub(o.(map[string]any), "path") == "report.json"
	}
	if !found {
		t.Fatalf("report.json is not a manifest output: %v", m["outputs"])
	}
}

func TestOutputCollisions(t *testing.T) {
	t.Run("dangling symlink", func(t *testing.T) {
		w := newWorld(t)
		must(t, os.Symlink("nowhere", w.path("out")))
		w.refused(w.run("out"), "", "output must be new and non-colliding")
		if _, err := os.Readlink(w.path("out")); err != nil {
			t.Fatal("the planted link was replaced")
		}
	})
	t.Run("existing directory keeps its content", func(t *testing.T) {
		w := newWorld(t)
		must(t, os.Mkdir(w.path("out"), 0o755))
		must(t, os.WriteFile(w.path("out/keep"), []byte("keep"), 0o644))
		w.refused(w.run("out"), "", "output must be new and non-colliding")
		if string(readFile(t, w.path("out/keep"))) != "keep" || w.exists(".out.stage") {
			t.Fatal("collision handling changed the filesystem")
		}
	})
	t.Run("output is the input", func(t *testing.T) {
		w := newWorld(t)
		w.refused(w.exec("--input", w.input, "--output", w.input, "--toolbelt", w.path("toolbelt")), "", "output must be new and non-colliding")
	})
}

// w0 is a throwaway canonical directory for argument-only checks.
func w0(t *testing.T) string {
	t.Helper()
	d, err := filepath.EvalSymlinks(t.TempDir())
	must(t, err)
	return d
}

func TestFailedRunsCleanTheStageAndKeepOutsideFiles(t *testing.T) {
	for _, mode := range []string{"nonzero", "missing", "malformed", "sentinel", "dishonest", "boolean"} {
		w := newWorld(t)
		w.headless(mode)
		if rc := w.run("out"); rc != 1 {
			t.Fatalf("%s: rc=%d", mode, rc)
		}
		if w.exists(".out.stage") {
			t.Errorf("%s: stage left behind", mode)
		}
	}
	w := newWorld(t)
	w.headless("loglink")
	outside := bytes.Repeat([]byte("0"), 100)
	must(t, os.WriteFile(w.path("outside.log"), outside, 0o644))
	w.refused(w.run("out"), "out", "unsafe diagnostic file: application.log")
	if !bytes.Equal(readFile(t, w.path("outside.log")), outside) {
		t.Fatal("a sandbox-planted symlink modified an outside file")
	}
}

func TestSourceAndToolSwapsCannotChangeStagedBytes(t *testing.T) {
	w := newWorld(t)
	w.d.beforeRun = func(string) {
		must(t, os.WriteFile(w.input, []byte("changed\n"), 0o644))
		must(t, os.WriteFile(w.gh+"/support/analyzeHeadless", []byte("#!/bin/sh\ntouch "+shellQuote(w.path("REPLACEMENT_RAN"))+"\nexit 9\n"), 0o755))
	}
	if rc := w.run("out"); rc != 0 {
		t.Fatalf("rc=%d %q", rc, w.errBuf.String())
	}
	if w.exists("REPLACEMENT_RAN") {
		t.Fatal("the replaced analyzer ran")
	}
	r := w.readJSON("out/report.json")
	if sub(r, "input", "source", "sha256") != sub(r, "input", "staged", "sha256") {
		t.Fatalf("source and staged digests differ: %v", r["input"])
	}
	if string(readFile(t, w.path("out/input/target.bin"))) != "\x7fELF fake target\n" {
		t.Fatal("the staged target is not the bytes that were authenticated")
	}
}

func TestPublicationRaceReplacesNothing(t *testing.T) {
	w := newWorld(t)
	w.d.beforeRun = func(string) {
		must(t, os.Mkdir(w.path("out"), 0o755))
		must(t, os.WriteFile(w.path("out/keep"), []byte("keep"), 0o644))
	}
	if rc := w.run("out"); rc != 2 {
		t.Fatalf("rc=%d %q", rc, w.errBuf.String())
	}
	if string(readFile(t, w.path("out/keep"))) != "keep" || w.exists("out/report.json") || w.exists(".out.stage") {
		t.Fatal("the raced output was replaced or the stage left behind")
	}
}

func TestToolIdentityChecks(t *testing.T) {
	t.Run("java symlink chain is canonicalised", func(t *testing.T) {
		w := newWorld(t)
		must(t, os.Rename(w.jdk+"/bin/java", w.jdk+"/bin/java.real"))
		must(t, os.Symlink("java.real", w.jdk+"/bin/java"))
		if rc := w.run("out"); rc != 0 {
			t.Fatalf("rc=%d %q", rc, w.errBuf.String())
		}
	})
	t.Run("java writable by others", func(t *testing.T) {
		w := newWorld(t)
		must(t, os.Chmod(w.jdk+"/bin/java", 0o777))
		w.refused(w.run("out"), "out", "trusted executable is writable by others")
	})
	t.Run("launcher unrelated to the PATH bwrap", func(t *testing.T) {
		w := newWorld(t)
		delete(w.env, "RSDD_TEST_ONLY_UNTRUSTED_BWRAP")
		w.env["RSDD_BWRAP"] = "/bin/true"
		w.refused(w.run("out"), "out", "Bubblewrap must match trusted PATH-selected bwrap")
	})
	t.Run("launcher that cannot start the sandbox", func(t *testing.T) {
		w := newWorld(t)
		w.env["RSDD_BWRAP"] = "/bin/false"
		w.refused(w.run("out"), "out", "Bubblewrap isolation probe failed")
	})
	t.Run("analyzer replaced between trust and staging", func(t *testing.T) {
		w := newWorld(t)
		w.d.afterTrust = func(string) {
			must(t, os.WriteFile(w.gh+"/support/analyzeHeadless", []byte("#!/bin/sh\nexit 9\n"), 0o755))
		}
		w.refused(w.run("out"), "out", "trusted launcher changed before staging")
	})
	t.Run("java replaced between trust and staging", func(t *testing.T) {
		w := newWorld(t)
		w.d.afterTrust = func(string) { must(t, os.WriteFile(w.jdk+"/bin/java", []byte("#!/bin/sh\nexit 9\n"), 0o755)) }
		w.refused(w.run("out"), "out", "trusted launcher changed before staging")
	})
	t.Run("bubblewrap rewritten in place between trust and staging", func(t *testing.T) {
		w := newWorld(t)
		bw := w.path("bin/bwrap")
		must(t, os.Remove(bw))
		must(t, copyFile(sharedBwrap, bw, 0o755))
		w.d.afterTrust = func(string) {
			f, err := os.OpenFile(bw, os.O_WRONLY|os.O_APPEND, 0)
			must(t, err)
			_, err = f.WriteString("tampered")
			must(t, err)
			must(t, f.Close())
		}
		w.refused(w.run("out"), "out", "staged Bubblewrap differs from authenticated identity")
	})
}

func TestStagedLauncherIsTheAuthenticatedFileNotTheReplacedPath(t *testing.T) {
	w := newWorld(t)
	bw := w.path("bin/bwrap")
	want := sha(readFile(t, sharedBwrap))
	w.d.afterTrust = func(string) {
		must(t, os.Remove(bw))
		must(t, os.WriteFile(bw, []byte("#!/bin/sh\ntouch "+shellQuote(w.path("LAUNCHER_REPLACEMENT"))+"\nexit 9\n"), 0o755))
	}
	if rc := w.run("out"); rc != 0 {
		t.Fatalf("rc=%d %q", rc, w.errBuf.String())
	}
	if w.exists("LAUNCHER_REPLACEMENT") {
		t.Fatal("the replaced launcher executed")
	}
	if got := sub(w.readJSON("out/report.json"), "isolation", "launcher", "sha256"); got != want {
		t.Fatalf("launcher digest %v, want %s", got, want)
	}
	if got := sha(readFile(t, w.path("out/tool/bwrap"))); got != want {
		t.Fatalf("staged launcher digest %s, want %s", got, want)
	}
}

func TestEvidenceFileCapBoundary(t *testing.T) {
	w := newWorld(t)
	if rc := w.run("probe"); rc != 0 {
		t.Fatalf("rc=%d %q", rc, w.errBuf.String())
	}
	n := countRegular(t, w.path("probe"))
	if rc := w.run("exact", "--max-files", strconv.Itoa(n)); rc != 0 {
		t.Fatalf("a cap of exactly %d files: rc=%d %q", n, rc, w.errBuf.String())
	}
	w.refused(w.run("under", "--max-files", strconv.Itoa(n-1)), "under", "evidence file cap exceeded")
}

func TestRunsThatWriteNoLogsStillGetEmptyLogFiles(t *testing.T) {
	w := newWorld(t)
	w.rawHeadless(outFinder + "printf '%s' '" + goodDoc() + "' >\"$out\"")
	if rc := w.run("out"); rc != 0 {
		t.Fatalf("rc=%d %q", rc, w.errBuf.String())
	}
	for _, f := range []string{"application.log", "script.log", "stdout.txt", "stderr.txt"} {
		if fi, err := os.Stat(w.path("out/logs/" + f)); err != nil || fi.Size() != 0 {
			t.Errorf("%s: %v %v", f, fi, err)
		}
	}
}

func TestReportWriteFailureIsTypedAndPublishesNothing(t *testing.T) {
	w := newWorld(t)
	w.d.beforeRun = func(stage string) {
		must(t, os.MkdirAll(stage+"/report.json/x", 0o700))
	}
	rc := w.run("out")
	if rc != 2 || !strings.HasPrefix(w.errBuf.String(), "corroborate-ghidra: [Errno ") ||
		!strings.HasSuffix(w.errBuf.String(), "/.out.stage/report.json'\n") {
		t.Fatalf("rc=%d %q", rc, w.errBuf.String())
	}
	if w.exists("out") || w.exists(".out.stage") {
		t.Fatal("something was published or left behind")
	}
}

func TestFailedRunWarnsWithThePointer(t *testing.T) {
	w := newWorld(t)
	w.headless("nonzero")
	if rc := w.run("out"); rc != 1 {
		t.Fatalf("rc=%d", rc)
	}
	want := "ghidra-corroboration.v1: completed with issues (completeness=failed) — see " + w.path("out") + "/ghidra-corroboration.v1.json\n"
	if w.errBuf.String() != want || w.out.Len() != 0 {
		t.Fatalf("stderr %q, want %q (stdout %q)", w.errBuf.String(), want, w.out.String())
	}
}

func TestDiagnosticCapIsInclusive(t *testing.T) {
	w := newWorld(t)
	if rc := w.run("probe"); rc != 0 {
		t.Fatalf("rc=%d", rc)
	}
	total := logsTotal(t, w.path("probe"))
	// The analyzer lingers so the supervision poll observes the logs at exactly the cap before it exits.
	w.headless("good", "sleep 0.3")
	if rc := w.run("exact", "--max-diagnostic-bytes", strconv.FormatInt(total, 10)); rc != 0 {
		t.Fatalf("a run writing exactly the cap: rc=%d errors=%v", rc, w.readJSON("exact/report.json")["errors"])
	}
	if rc := w.run("over", "--max-diagnostic-bytes", strconv.FormatInt(total-1, 10)); rc != 1 ||
		w.readJSON("over/report.json")["errors"].([]any)[0] != "diagnostic-cap" || logsTotal(t, w.path("over")) != total-1 {
		t.Fatalf("one byte over the cap: rc=%d", rc)
	}
}

func TestBurstOverTheCapIsCaughtAfterTheRun(t *testing.T) {
	w := newWorld(t)
	w.rawHeadless(outFinder + "head -c 3000 /dev/zero | tr '\\0' x\nprintf '%s' '" + goodDoc() + "' >\"$out\"")
	if rc := w.run("out", "--max-diagnostic-bytes", "1000"); rc != 1 {
		t.Fatalf("rc=%d %q", rc, w.errBuf.String())
	}
	if w.readJSON("out/report.json")["errors"].([]any)[0] != "diagnostic-cap" || logsTotal(t, w.path("out")) != 1000 {
		t.Fatalf("errors=%v total=%d", w.readJSON("out/report.json")["errors"], logsTotal(t, w.path("out")))
	}
}

func TestWallTimeoutRecordsTheTerminatingSignal(t *testing.T) {
	w := newWorld(t)
	w.headless("timeout")
	if rc := w.run("out", "--timeout-seconds", "1"); rc != 1 {
		t.Fatalf("rc=%d", rc)
	}
	run := w.readJSON("out/report.json")["run"].(map[string]any)
	if run["exit_code"] != nil || run["signal"] != float64(syscall.SIGTERM) {
		t.Fatalf("run=%v", run)
	}
}

func TestWallTimeoutTermsTheLeaderBeforeKilling(t *testing.T) {
	w := newWorld(t)
	w.rawHeadless("trap 'echo term >" + shellQuote(w.path("leader.term")) + "; exit 0' TERM\nsleep 30 &\nwait")
	if rc := w.run("out", "--timeout-seconds", "1"); rc != 1 {
		t.Fatalf("rc=%d", rc)
	}
	if !w.exists("leader.term") {
		t.Fatal("the leader was killed before it could handle SIGTERM")
	}
	if run := w.readJSON("out/report.json")["run"].(map[string]any); run["exit_code"] != float64(0) {
		t.Fatalf("run=%v", run)
	}
}

func TestDescendantsGetTermBeforeKill(t *testing.T) {
	w := newWorld(t)
	w.rawHeadless("( trap 'echo term >" + shellQuote(w.path("desc.term")) + "; exit 0' TERM; : >" + shellQuote(w.path("desc.ready")) +
		"; sleep 30 & wait ) &\nwhile [ ! -e " + shellQuote(w.path("desc.ready")) + " ]; do sleep 0.01; done\nexit 9")
	if rc := w.run("out"); rc != 1 {
		t.Fatalf("rc=%d", rc)
	}
	if !w.exists("desc.term") {
		t.Fatal("the descendant was killed without a SIGTERM grace")
	}
}

func TestParseArgsMessages(t *testing.T) {
	parse := func(args ...string) (int, bool, string) {
		var e bytes.Buffer
		_, code, ok := parseArgs(args, cli.Stdio{Out: &bytes.Buffer{}, Err: &e, Env: func(string) string { return "" }})
		return code, ok, e.String()
	}
	for _, c := range []struct {
		args []string
		why  string
	}{
		{[]string{"--output", "o"}, "the following arguments are required: --input"},
		{[]string{"--input", "i"}, "the following arguments are required: --output"},
		{nil, "the following arguments are required: --input, --output"},
		{[]string{"--input", "i", "--output", "o", "extra", "more"}, "unrecognized arguments: extra more"},
		{[]string{"--input", "i", "--max-files", "x"}, "invalid value \"x\" for flag -max-files: invalid int value: \"x\""},
	} {
		code, ok, msg := parse(c.args...)
		if code != 2 || ok || !strings.HasSuffix(msg, "corroborate-ghidra: error: "+c.why+"\n") {
			t.Errorf("%v: code=%d ok=%v msg=%q", c.args, code, ok, msg)
		}
		if strings.Contains(c.why, "required") && strings.Contains(msg, "unrecognized") || strings.Contains(c.why, "unrecognized") && strings.Contains(msg, "required") {
			t.Errorf("%v: wrong reason: %q", c.args, msg)
		}
	}
	if code, ok, msg := parse("--input", "i", "--output", "o", "--max-files", " 5 "); code != 0 || !ok || msg != "" {
		t.Errorf("a padded integer is accepted: %d %v %q", code, ok, msg)
	}
}

func TestIntFlagString(t *testing.T) {
	n := 42
	if got := (intFlag{&n}).String(); got != "42" {
		t.Fatalf("%q", got)
	}
	if got := (intFlag{}).String(); got != "" {
		t.Fatalf("zero value: %q", got)
	}
}

func TestIsoZAndRunRecord(t *testing.T) {
	base := time.Date(2026, 11, 2, 12, 0, 0, 0, time.UTC)
	for _, c := range []struct {
		ns   int
		want string
	}{
		{0, "2026-11-02T12:00:00Z"},
		{999, "2026-11-02T12:00:00Z"},
		{1000, "2026-11-02T12:00:00.000001Z"},
		{123456000, "2026-11-02T12:00:00.123456Z"},
		{999999999, "2026-11-02T12:00:00.999999Z"},
	} {
		if got := isoZ(base.Add(time.Duration(c.ns))); got != c.want {
			t.Errorf("%dns: %s, want %s", c.ns, got, c.want)
		}
	}
	if got := isoZ(base.In(time.FixedZone("x", 3600))); got != "2026-11-02T12:00:00Z" {
		t.Errorf("zone: %s", got)
	}
	r := runRecord(base, base.Add(1500*time.Millisecond), 3)
	if r["exit_code"] != 3 || r["signal"] != nil || r["duration_ms"] != int64(1500) || r["started_at"] != "2026-11-02T12:00:00Z" {
		t.Errorf("exit: %v", r)
	}
	if r := runRecord(base, base, 0); r["exit_code"] != 0 || r["signal"] != nil {
		t.Errorf("zero exit: %v", r)
	}
	if r := runRecord(base, base, -15); r["exit_code"] != nil || r["signal"] != 15 {
		t.Errorf("signal: %v", r)
	}
}

func TestKernelReleaseIsTheKernelsOwn(t *testing.T) {
	b, err := os.ReadFile("/proc/sys/kernel/osrelease")
	if err != nil {
		t.Skip("no /proc/sys/kernel/osrelease")
	}
	if got, want := kernelRelease(), strings.TrimSpace(string(b)); got != want || got == "" || got == "unknown" {
		t.Fatalf("%q, want %q", got, want)
	}
}

func TestReportIsolationClaims(t *testing.T) {
	e := evidence{cfg: config{}, isolated: true, run: map[string]any{}}
	iso := e.report()["isolation"].(map[string]any)
	for k, want := range map[string]any{"network_access": false, "target_execution": false, "read_only_host_root": true,
		"new_session": true, "synthetic_user_state": true} {
		if iso[k] != want {
			t.Errorf("isolated %s=%v", k, iso[k])
		}
	}
	e.isolated = false
	iso = e.report()["isolation"].(map[string]any)
	for k, want := range map[string]any{"network_access": true, "target_execution": false, "read_only_host_root": false,
		"new_session": false, "synthetic_user_state": false} {
		if iso[k] != want {
			t.Errorf("test-only %s=%v", k, iso[k])
		}
	}
}

func TestLookPath(t *testing.T) {
	root := w0(t)
	d1, d2, d3 := root+"/d1", root+"/d2", root+"/d3"
	for _, d := range []string{d1, d2, d3} {
		must(t, os.Mkdir(d, 0o755))
	}
	must(t, os.Mkdir(d1+"/bwrap", 0o755))
	must(t, os.WriteFile(d2+"/bwrap", []byte("x"), 0o644))
	if p, ok := lookPath("bwrap", d1+":"+d2); ok || p != "" {
		t.Fatalf("nothing executable: %q %v", p, ok)
	}
	must(t, os.WriteFile(d3+"/bwrap", []byte("x"), 0o755))
	if p, ok := lookPath("bwrap", d1+":"+d2+":"+d3); !ok || p != d3+"/bwrap" {
		t.Fatalf("%q %v", p, ok)
	}
}

func TestUntrustedFilePolicy(t *testing.T) {
	for _, c := range []struct {
		owner, uid int
		perm       os.FileMode
		want       bool
	}{
		{0, 1000, 0o755, false}, {1000, 1000, 0o755, false}, {1001, 1000, 0o755, true}, {0, 1000, 0o775, true},
		{1000, 1000, 0o757, true}, {1000, 1000, 0o700, false}, {0, 0, 0o500, false},
	} {
		if got := untrustedFile(c.owner, c.uid, c.perm); got != c.want {
			t.Errorf("%+v: %v", c, got)
		}
	}
}

func TestTrustedRequiresTheExpectedFile(t *testing.T) {
	root := w0(t)
	a, b := root+"/a", root+"/b"
	must(t, os.WriteFile(a, []byte("a"), 0o755))
	must(t, os.WriteFile(b, []byte("b"), 0o755))
	if _, _, err := trusted(a, b); err == nil || err.Error() != "trusted path mismatch" {
		t.Fatalf("%v", err)
	}
	if res, rec, err := trusted(a, a); err != nil || res != a || rec.Path != a || rec.Size != 1 || rec.SHA256 != sha([]byte("a")) {
		t.Fatalf("%q %+v %v", res, rec, err)
	}
	if _, _, err := trusted(a, ""); err != nil {
		t.Fatalf("no expectation: %v", err)
	}
}

func TestTrustedBwrapReturnsTheCanonicalPath(t *testing.T) {
	root := w0(t)
	must(t, os.Mkdir(root+"/real", 0o755))
	must(t, copyFile(sharedBwrap, root+"/real/bwrap", 0o755))
	must(t, os.Symlink(root+"/real", root+"/alias"))
	f, path, rec, err := trustedBwrap(root+"/alias/bwrap", true)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	if path != root+"/real/bwrap" || rec.Path != path {
		t.Fatalf("path %q record %q", path, rec.Path)
	}
}

func TestStageOpenCopyErrorIsReported(t *testing.T) {
	root := w0(t)
	// A write-only descriptor on an empty file: statting works, reading fails, and the empty copy would otherwise
	// look like a faithful one.
	src, err := os.OpenFile(root+"/src", os.O_WRONLY|os.O_CREATE, 0o755)
	must(t, err)
	defer src.Close()
	if _, _, err := stageOpen(src, root+"/dst", "tool/bwrap", 0o500, root+"/src"); err == nil {
		t.Fatal("an unreadable source was staged")
	}
	if _, err := os.Lstat(root + "/dst"); err == nil {
		t.Fatal("the partial copy was kept")
	}
}

func TestSandboxCommandLine(t *testing.T) {
	cfg := config{heapMB: 2048, cpus: 2, analysisTimeout: 90, maxFunctions: 2, maxStrings: 3, maxReferences: 4, maxStringChars: 32}
	sb := buildSandbox(cfg, "/gh", "/jh")
	want := []string{"tool/bwrap", "--die-with-parent", "--new-session", "--unshare-net", "--ro-bind", "/", "/",
		"--proc", "/proc", "--dev", "/dev", "--tmpfs", "/tmp/rsdd", "--dir", "/tmp/rsdd/work", "--dir", "/tmp/rsdd/ghidra", "--dir", "/tmp/rsdd/jdk",
		"--ro-bind", "/gh", "/tmp/rsdd/ghidra", "--ro-bind", "/jh", "/tmp/rsdd/jdk", "--ro-bind", ".", "/tmp/rsdd/work",
		"--bind", "project", "/tmp/rsdd/work/project", "--bind", "output", "/tmp/rsdd/work/output",
		"--bind", "logs", "/tmp/rsdd/work/logs", "--bind", "state", "/tmp/rsdd/work/state",
		"--ro-bind", "/proc/self/fd/12", "/tmp/rsdd/work/input/target.bin",
		"--ro-bind", "/proc/self/fd/3", "/tmp/rsdd/work/script/CuratedEvidenceExporter.java",
		"--ro-bind", "/proc/self/fd/5", "/tmp/rsdd/ghidra/support/analyzeHeadless",
		"--ro-bind", "/proc/self/fd/6", "/tmp/rsdd/ghidra/support/launch.sh",
		"--ro-bind", "/proc/self/fd/7", "/tmp/rsdd/ghidra/support/launch.properties",
		"--ro-bind", "/proc/self/fd/8", "/tmp/rsdd/ghidra/support/LaunchSupport.jar",
		"--ro-bind", "/proc/self/fd/9", "/tmp/rsdd/ghidra/Ghidra/Framework/Utility/lib/Utility.jar",
		"--ro-bind", "/proc/self/fd/10", "/tmp/rsdd/ghidra/Ghidra/application.properties",
		"--ro-bind", "/proc/self/fd/11", "/tmp/rsdd/jdk/bin/java",
		"--dir", "/tmp/rsdd/provenance",
		"--ro-bind", "script/CuratedEvidenceExporter.java", "/tmp/rsdd/provenance/0",
		"--ro-bind", "tool/ghidra/support/analyzeHeadless", "/tmp/rsdd/provenance/1",
		"--ro-bind", "tool/ghidra/support/launch.sh", "/tmp/rsdd/provenance/2",
		"--ro-bind", "tool/ghidra/support/launch.properties", "/tmp/rsdd/provenance/3",
		"--ro-bind", "tool/ghidra/support/LaunchSupport.jar", "/tmp/rsdd/provenance/4",
		"--ro-bind", "tool/ghidra/Ghidra/Framework/Utility/lib/Utility.jar", "/tmp/rsdd/provenance/5",
		"--ro-bind", "tool/ghidra/Ghidra/application.properties", "/tmp/rsdd/provenance/6",
		"--ro-bind", "tool/jdk/bin/java", "/tmp/rsdd/provenance/7",
		"--setenv", "HOME", "/tmp/rsdd/work/state/home", "--setenv", "XDG_CACHE_HOME", "/tmp/rsdd/work/state/cache",
		"--setenv", "XDG_CONFIG_HOME", "/tmp/rsdd/work/state/config", "--setenv", "XDG_DATA_HOME", "/tmp/rsdd/work/state/data",
		"--setenv", "TMPDIR", "/tmp/rsdd/work/state/tmp", "--setenv", "JAVA_HOME", "/tmp/rsdd/jdk",
		"--setenv", "PATH", "/tmp/rsdd/jdk/bin:/usr/bin:/bin", "--setenv", "LANG", "C.UTF-8", "--setenv", "LC_ALL", "C.UTF-8",
		"--setenv", "TZ", "UTC",
		"--chdir", "/tmp/rsdd/work", "--",
		"/usr/bin/env", "GHIDRA_HEADLESS_MAXMEM=2048M", "GHIDRA_HEADLESS_JAVA_OPTIONS=-Djava.io.tmpdir=/tmp/rsdd/work/state/tmp",
		"/usr/bin/prlimit", "--cpu=95", "--", "/tmp/rsdd/ghidra/support/analyzeHeadless", "/tmp/rsdd/work/project", "rsdd",
		"-import", "/tmp/rsdd/work/input/target.bin", "-readOnly", "-deleteProject", "-analysisTimeoutPerFile", "90",
		"-max-cpu", "2", "-scriptPath", "/tmp/rsdd/work/script", "-postScript", "CuratedEvidenceExporter.java",
		"/tmp/rsdd/work/output/curated.json", "2", "2", "2", "2", "3", "4", "32",
		"-log", "/tmp/rsdd/work/logs/application.log", "-scriptlog", "/tmp/rsdd/work/logs/script.log"}
	if !reflect.DeepEqual(sb.command, want) {
		for i := range want {
			if i >= len(sb.command) || sb.command[i] != want[i] {
				t.Fatalf("argv differs at %d:\n got %q\nwant %q", i, sb.command[i:], want[i:])
			}
		}
		t.Fatalf("argv has %d extra elements", len(sb.command)-len(want))
	}
	if probe := sb.probeCommand(); probe[len(probe)-1] != "/bin/true" || probe[len(probe)-3] != "/tmp/rsdd/work" ||
		len(probe) != indexOf(want, "--chdir")+4 {
		t.Fatalf("probe %q", probe)
	}
}

func TestCuratedBoundaries(t *testing.T) {
	caps := map[string]int{"functions": 2, "symbols": 2, "imports": 2, "exports": 2, "strings": 2, "references": 2, "string_chars": 32}
	dir := t.TempDir()
	check := func(name string, d map[string]any, maxBytes int64, wantStatus, wantErr string) {
		t.Helper()
		p := dir + "/c.json"
		must(t, os.RemoveAll(p))
		must(t, os.WriteFile(p, curatedBytes(d), 0o644))
		st, errs := validateCurated(p, caps, maxBytes)
		if wantErr == "" && (st != wantStatus || errs != nil) || wantErr != "" && (st != "" || len(errs) != 1 || errs[0] != wantErr) {
			t.Errorf("%s: %q %v", name, st, errs)
		}
	}
	fn := func(n int) []any {
		var l []any
		for i := 0; i < n; i++ {
			l = append(l, map[string]any{"address": "1", "name": "f", "external": false, "thunk": false})
		}
		return l
	}
	setFunctions := func(items []any, observed int, exact, truncated bool) func(map[string]any) {
		return func(d map[string]any) {
			d["functions"] = items
			d["counts"].(map[string]any)["functions"] = map[string]any{"emitted": len(items), "observed": observed, "exact": exact}
			d["truncation"].(map[string]any)["functions"] = truncated
		}
	}
	size := int64(len(curatedBytes(curatedDoc())))
	check("exact size", curatedDoc(), size, "complete", "")
	check("one byte over", curatedDoc(), size-1, "", "curated-output-cap")
	check("full list", curatedDoc(setFunctions(fn(2), 2, true, false)), 1<<20, "complete", "")
	check("list over the cap", curatedDoc(setFunctions(fn(3), 3, true, false)), 1<<20, "", "malformed-curated-output")
	check("truncated at cap+1", curatedDoc(setFunctions(fn(2), 3, false, true), func(d map[string]any) { d["status"] = "partial" }), 1<<20, "partial", "")
	check("observed beyond cap+1", curatedDoc(setFunctions(fn(2), 4, false, true), func(d map[string]any) { d["status"] = "partial" }), 1<<20, "", "malformed-curated-output")
	check("observed below the list", curatedDoc(setFunctions(fn(2), 1, false, true), func(d map[string]any) { d["status"] = "partial" }), 1<<20, "", "malformed-curated-output")
	check("complete status lying about truncation", curatedDoc(setFunctions(fn(2), 3, false, true)), 1<<20, "", "malformed-curated-output")
	one := func(value string) func(map[string]any) {
		return func(d map[string]any) {
			d["strings"] = []any{map[string]any{"address": "1", "value": value, "value_truncated": false}}
			d["counts"].(map[string]any)["strings"] = map[string]any{"emitted": 1, "observed": 1, "exact": true}
		}
	}
	check("string of exactly the cap in runes", curatedDoc(one(strings.Repeat("\u00e9", 32))), 1<<20, "complete", "")
	check("string one rune over the cap", curatedDoc(one(strings.Repeat("\u00e9", 33))), 1<<20, "", "malformed-curated-output")
	if st, errs := validateCurated(dir+"/sentinel", caps, 1<<20); st != "" || errs[0] != "missing-curated-output" {
		t.Errorf("absent: %q %v", st, errs)
	}
	must(t, os.WriteFile(dir+"/sentinel", []byte(sentinel), 0o644))
	if st, errs := validateCurated(dir+"/sentinel", caps, 1<<20); st != "" || len(errs) != 1 || errs[0] != "unchanged-sentinel" {
		t.Errorf("sentinel: %q %v", st, errs)
	}
}

func TestRealBubblewrapRun(t *testing.T) {
	const real = "/usr/bin/bwrap"
	if out, err := execProbe(real, "--unshare-net", "--ro-bind", "/", "/", "/bin/true"); err != nil {
		t.Skipf("real Bubblewrap cannot run here: %v %s", err, out)
	}
	w := newWorld(t)
	w.env["RSDD_BWRAP"] = real
	delete(w.env, "RSDD_TEST_ONLY_UNTRUSTED_BWRAP")
	rc := w.run("out")
	if rc == 2 {
		t.Skipf("real Bubblewrap is not trusted or usable here: %q", w.errBuf.String())
	}
	if rc != 0 {
		t.Fatalf("rc=%d %q", rc, w.errBuf.String())
	}
	iso := w.readJSON("out/report.json")["isolation"].(map[string]any)
	if iso["network_access"] != false || iso["read_only_host_root"] != true || iso["new_session"] != true || iso["synthetic_user_state"] != true {
		t.Fatalf("isolation: %v", iso)
	}
}

// execProbe runs a command and returns its combined output.
func execProbe(name string, args ...string) (string, error) {
	out, err := exec.Command(name, args...).CombinedOutput()
	return string(out), err
}
