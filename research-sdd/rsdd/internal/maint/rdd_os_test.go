package maint

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// fakeGentle installs an executable gentle-ai script in a fresh directory and returns that directory.
func fakeGentle(t *testing.T, script string) string {
	t.Helper()
	dir := t.TempDir()
	writeFile(t, filepath.Join(dir, "gentle-ai"), "#!/bin/sh\n"+script+"\n")
	if err := os.Chmod(filepath.Join(dir, "gentle-ai"), 0o755); err != nil {
		t.Fatal(err)
	}
	return dir
}

func osToolFor(t *testing.T, path string) osTool {
	t.Helper()
	s, _, _ := stdio(t.TempDir())
	s.Env = func(k string) string {
		if k == "PATH" {
			return path
		}
		return ""
	}
	return newOSTool(s)
}

func TestOSToolRunsInDirWithAmbientEnvironment(t *testing.T) {
	bin := fakeGentle(t, `printf '{"pwd":"%s","v":"%s","args":"%s"}' "$(pwd -P)" "$RDD_TEST_AMBIENT" "$*"; exit 3`)
	t.Setenv("RDD_TEST_AMBIENT", "kept")
	dir := t.TempDir()
	real, err := filepath.EvalSymlinks(dir)
	if err != nil {
		t.Fatal(err)
	}
	tl := osToolFor(t, bin+":/usr/bin:/bin")
	if err := tl.present(); err != nil {
		t.Fatalf("present: %v", err)
	}
	res, err := tl.run([]string{"gentle-ai", "review", "x y"}, dir)
	if err != nil || res.rc != 3 {
		t.Fatalf("rc=%d err=%v", res.rc, err)
	}
	want := `{"pwd":"` + real + `","v":"kept","args":"review x y"}`
	if res.stdout != want {
		t.Fatalf("stdout=%q want %q", res.stdout, want)
	}
}

func TestOSToolCapturesStderrSeparately(t *testing.T) {
	bin := fakeGentle(t, `echo out; echo err >&2`)
	res, err := osToolFor(t, bin+":/usr/bin:/bin").run([]string{"gentle-ai"}, t.TempDir())
	if err != nil || res.stdout != "out\n" || res.stderr != "err\n" || res.rc != 0 {
		t.Fatalf("%+v err=%v", res, err)
	}
}

func TestOSToolDefaultPathAndAbsence(t *testing.T) {
	tl := osToolFor(t, "")
	if tl.path != "/bin:/usr/bin" || tl.env[0] != "PATH=/bin:/usr/bin" {
		t.Fatalf("default PATH: %q %q", tl.path, tl.env[0])
	}
	empty := t.TempDir()
	if err := osToolFor(t, empty).present(); err == nil {
		t.Fatal("gentle-ai must be reported absent")
	}
	if _, err := osToolFor(t, empty).run([]string{"gentle-ai"}, t.TempDir()); err == nil {
		t.Fatal("running an absent tool must fail")
	}
	n := 0
	for _, kv := range osToolFor(t, "/x").env {
		if strings.HasPrefix(kv, "PATH=") {
			n++
		}
	}
	if n != 1 {
		t.Fatalf("PATH appears %d times in the child environment", n)
	}
}

func TestOSToolBadDirIsAnError(t *testing.T) {
	bin := fakeGentle(t, `echo x`)
	if _, err := osToolFor(t, bin).run([]string{"gentle-ai"}, filepath.Join(t.TempDir(), "missing")); err == nil {
		t.Fatal("a missing working directory must be an error")
	}
}

func TestRddEntryPointsUseTheRealTool(t *testing.T) {
	bin := fakeGentle(t, `echo '{"review_due":false,"risk":"low","review_due_reason":"passive"}'`)
	s, o, _ := stdio(t.TempDir())
	s.Env = func(k string) string {
		if k == "PATH" {
			return bin + ":/usr/bin:/bin"
		}
		return ""
	}
	if rc := RddStart([]string{"/", filepath.Join(t.TempDir(), "o")}, s); rc != 10 || !strings.Contains(o.String(), "rdd-not-due: passive") {
		t.Fatalf("rc=%d out=%q", rc, o.String())
	}
	first := filepath.Join(t.TempDir(), "first.json")
	writeFile(t, first, fixture(t, "status-stop-acked.json"))
	if rc := RddDrive([]string{"/", first}, s); rc != 0 || !strings.Contains(o.String(), "rdd-stop: target_already_acknowledged") {
		t.Fatalf("rc=%d out=%q", rc, o.String())
	}
}

func TestFinishMapsErrors(t *testing.T) {
	s, _, e := stdio("/")
	if finish(nil, s, "x") != 0 || finish(&exit{14}, s, "x") != 14 {
		t.Fatal("exit codes")
	}
	if rc := finish(os.ErrNotExist, s, "rdd-drive"); rc != 1 || e.String() != "rsdd: maint rdd-drive: file does not exist\n" {
		t.Fatalf("rc=%d err=%q", rc, e.String())
	}
}
