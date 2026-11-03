package native

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// refused asserts the command refused with status 2, printed exactly "corroborate-native: <msg>\n" and published nothing.
func (w *world) refused(rc int, out, msg string) {
	w.t.Helper()
	if rc != 2 {
		w.t.Fatalf("rc=%d stderr=%q", rc, w.errBuf.String())
	}
	if got := w.errBuf.String(); got != "corroborate-native: "+msg+"\n" {
		w.t.Fatalf("stderr:\n got %q\nwant %q", got, "corroborate-native: "+msg+"\n")
	}
	if w.out.Len() != 0 {
		w.t.Fatalf("stdout must stay empty: %q", w.out.String())
	}
	if out != "" && w.exists(out) {
		w.t.Fatalf("%s must not exist after a refusal", out)
	}
}

func TestInputRefusals(t *testing.T) {
	w := newWorld(t)
	link := w.path("link.elf")
	must(t, os.Symlink(w.input, link))
	w.refused(w.exec("--input", link, "--output", w.path("o1")), "o1", "cannot open regular non-symlink file: "+link)
	w.refused(w.exec("--input", w.root, "--output", w.path("o2")), "o2", "not a regular file: "+w.root)
	w.refused(w.exec("--input", w.path("absent"), "--output", w.path("o3")), "o3", "cannot open regular non-symlink file: "+w.path("absent"))
	w.refused(w.exec("--input", "link.elf", "--output", "o4"), "o4", "cannot open regular non-symlink file: link.elf")
}

func TestOutputRefusals(t *testing.T) {
	w := newWorld(t)
	must(t, os.Mkdir(w.path("taken"), 0o755))
	w.refused(w.run("taken"), "", "output must be a new non-colliding path")

	must(t, os.Symlink("nowhere", w.path("dangling")))
	w.refused(w.run("dangling"), "", "output must be a new non-colliding path")

	w.refused(w.exec("--input", w.input, "--output", w.input), "", "output must be a new non-colliding path")

	w.refused(w.run("nodir/out"), "nodir", "[Errno 2] No such file or directory: '"+w.path("nodir")+"'")
}

func TestForeignStagingDirectoryIsNeverRemoved(t *testing.T) {
	w := newWorld(t)
	must(t, os.Mkdir(w.path(".occupied.stage"), 0o700))
	must(t, os.WriteFile(w.path(".occupied.stage/sentinel"), []byte("keep"), 0o600))
	w.refused(w.run("occupied"), "occupied", "[Errno 17] File exists: '"+w.path(".occupied.stage")+"'")
	if b, err := os.ReadFile(w.path(".occupied.stage/sentinel")); err != nil || string(b) != "keep" {
		t.Fatalf("foreign stage content lost: %q %v", b, err)
	}
}

func TestCapsAreValidatedBeforeAnyWork(t *testing.T) {
	for _, args := range [][]string{{"--timeout-seconds", "0"}, {"--max-bytes", "0"}, {"--max-functions", "-1"}, {"--max-files", "5"}} {
		w := newWorld(t)
		w.refused(w.run("caps", args...), "caps", "caps must be positive and max-files at least 6")
		if w.exists(".caps.stage") {
			t.Fatalf("%v: nothing may be staged", args)
		}
	}
	w := newWorld(t)
	if rc := w.run("six", "--max-files", "6"); rc == 2 {
		t.Fatalf("6 is the smallest allowed file cap: %q", w.errBuf.String())
	}
}

func TestEvidenceFileCapIsEnforcedBeforePublishing(t *testing.T) {
	w := newWorld(t)
	// Six evidence files exist at the end (r2, stdout, stderr, functions, manifest, report); the staged target is not counted.
	w.d.beforeRun = func(stage string) {
		must(t, os.WriteFile(filepath.Join(stage, "engine/extra.txt"), []byte("x"), 0o644))
	}
	w.refused(w.run("capped", "--max-files", "6"), "capped", "evidence file cap exceeded")
	if w.exists(".capped.stage") {
		t.Fatal("a refused stage is removed")
	}
}

func TestPrivateFilesystemIsEnforced(t *testing.T) {
	w := newWorld(t)
	w.d.mountinfo = func() (string, error) { return "1 0 0:1 / / rw - 9p drvfs rw\n", nil }
	w.refused(w.run("shared"), "shared", "output must reside on a Linux-private filesystem")
	if w.exists(".shared.stage") {
		t.Fatal("rejected before staging")
	}
	w.d.mountinfo = func() (string, error) { return "", errors.New("boom") }
	if rc := w.run("unreadable"); rc != 2 || !strings.Contains(w.errBuf.String(), "boom") {
		t.Fatalf("rc=%d %q", rc, w.errBuf.String())
	}
}

func TestLauncherRefusals(t *testing.T) {
	w := newWorld(t)
	w.env["RSDD_R2"] = "/usr/bin/true"
	w.refused(w.run("wrong"), "wrong", "configured r2 does not match PATH-selected executable")
	if w.exists(".wrong.stage") {
		t.Fatal("stage must be cleaned")
	}

	w = newWorld(t)
	w.env["PATH"] = "/nonexistent-dir"
	w.refused(w.run("nor2"), "nor2", "PATH-selected r2 is missing")

	w = newWorld(t)
	w.env["RSDD_BWRAP"] = "/usr/bin/true"
	w.refused(w.run("otherbwrap"), "otherbwrap", "configured bwrap does not match PATH-selected executable")

	w = newWorld(t)
	w.d.bwrapOK = func(os.FileInfo) error { return errors.New("Bubblewrap must be root-owned and non-writable") }
	w.refused(w.run("untrusted"), "untrusted", "Bubblewrap must be root-owned and non-writable")
}

func TestMountpointIsChecked(t *testing.T) {
	w := newWorld(t)
	must(t, os.Symlink(w.root, w.d.mountRoot))
	w.refused(w.run("sym"), "sym", "unsafe Bubblewrap mountpoint")

	w = newWorld(t)
	must(t, os.Mkdir(w.d.mountRoot, 0o755))
	must(t, os.Chmod(w.d.mountRoot, 0o755))
	w.refused(w.run("open"), "open", "unsafe Bubblewrap mountpoint")

	w = newWorld(t)
	w.d.uid = os.Getuid() + 1
	w.refused(w.run("foreign"), "foreign", "unsafe Bubblewrap mountpoint")
}

func TestIsolationProbeFailureIsRefused(t *testing.T) {
	w := newWorld(t)
	w.script("bwrap", "#!/bin/sh\nexit 1\n")
	w.refused(w.run("noiso"), "noiso", "network-denied isolation probe failed")
	if w.exists(".noiso.stage") {
		t.Fatal("stage must be cleaned")
	}
}

func TestVersionProbeFailureIsRefused(t *testing.T) {
	w := newWorld(t)
	w.script("r2", "#!/bin/sh\n[ \"${1:-}\" = -v ] && exit 4\necho '[]'\n")
	w.refused(w.run("nov"), "nov", "radare2 version probe failed: exit status 4")

	w = newWorld(t)
	w.script("r2", "#!/bin/sh\n[ \"${1:-}\" = -v ] && exit 0\necho '[]'\n")
	w.refused(w.run("emptyv"), "emptyv", "radare2 version probe printed no version")
}

func TestUsage(t *testing.T) {
	w := newWorld(t)
	for _, args := range [][]string{{}, {"--input", "x"}, {"--bogus"}, {"--input", "x", "--output", "y", "stray"}, {"--input", "x", "--output", "y", "--max-bytes", "many"}} {
		w.out.Reset()
		w.errBuf.Reset()
		if rc := execute(args, w.stdio(), w.d); rc != 2 || !strings.HasPrefix(w.errBuf.String(), "usage: rsdd corroborate native") || w.out.Len() != 0 {
			t.Fatalf("%v: rc=%d stderr=%q", args, rc, w.errBuf.String())
		}
	}
	w.out.Reset()
	w.errBuf.Reset()
	if rc := execute([]string{"-h"}, w.stdio(), w.d); rc != 0 || !strings.HasPrefix(w.out.String(), "usage: rsdd corroborate native") || w.errBuf.Len() != 0 {
		t.Fatalf("help: rc=%d out=%q err=%q", rc, w.out.String(), w.errBuf.String())
	}
}

func TestLegacyManifestCLIFlagIsAcceptedAndIgnored(t *testing.T) {
	w := newWorld(t)
	if rc := w.run("legacy", "--manifest-cli", "/nonexistent/analysis_manifest.py"); rc != 0 {
		t.Fatalf("rc=%d err=%q", rc, w.errBuf.String())
	}
}
