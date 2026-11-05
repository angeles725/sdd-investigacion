package fetchdoc

import (
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/srcregistry"
)

// waitFor polls until cond holds or fails the test after a bound; it is how a test waits for a stub to announce
// itself without a fixed sleep.
func waitFor(t *testing.T, what string, cond func() bool) {
	t.Helper()
	for i := 0; i < 200; i++ {
		if cond() {
			return
		}
		time.Sleep(25 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s", what)
}

func exists(path string) bool { _, err := os.Stat(path); return err == nil }

func pidDead(t *testing.T, pidfile string) bool {
	t.Helper()
	b, err := os.ReadFile(pidfile)
	if err != nil {
		t.Fatal(err)
	}
	pid, _ := strconv.Atoi(strings.TrimSpace(string(b)))
	for i := 0; i < 100; i++ {
		if syscall.Kill(pid, 0) == syscall.ESRCH {
			return true
		}
		time.Sleep(20 * time.Millisecond)
	}
	return false
}

func partFiles(w *world) []string {
	var parts []string
	for _, l := range strings.Split(w.snapshot(), "\n") {
		if strings.Contains(l, ".fetchdoc-part.") {
			parts = append(parts, l)
		}
	}
	return parts
}

// cancelDuring runs args in w with a stub that hangs, sends sig once the stub has announced itself, and returns the
// exit status and the world for inspection.
func cancelDuring(t *testing.T, w *world, sig os.Signal, args ...string) int {
	t.Helper()
	sigs := make(chan os.Signal, 2)
	done := make(chan ran, 1)
	go func() { done <- w.goRunSig(sigs, 4242, args...) }()
	waitFor(t, "the stub to start", func() bool { return exists(w.root + "/started") })
	sigs <- sig
	select {
	case r := <-done:
		return r.rc
	case <-time.After(10 * time.Second):
		t.Fatal("the run did not stop after the signal")
		return -1
	}
}

func hangEnv(w *world) {
	w.setEnv("STUB_ROUTES=", "STUB_DOWNLOAD_HANG=1", "STUB_HANG_SECS=20", "STUB_HANG_MARKER="+w.root+"/started",
		"STUB_HANG_PIDFILE="+w.root+"/sleep.pid", "STUB_HANG_DONE_MARKER="+w.root+"/finished")
}

func TestSignalMidDownloadCancelsTheChildAndKeepsTheEvidence(t *testing.T) {
	for _, c := range []struct {
		sig  os.Signal
		code int
	}{{syscall.SIGTERM, 143}, {syscall.SIGINT, 130}} {
		t.Run(c.sig.String(), func(t *testing.T) {
			w := newWorld(t, "curl", "wget")
			hangEnv(w)
			seeded("datasheets/a.pdf", "REGISTERED\n")(w)
			before, _ := os.ReadFile(w.path("sources/SOURCES.md"))
			rc := cancelDuring(t, w, c.sig, "--replace", "doc", "http://h/a.pdf", w.dir)
			if rc != c.code {
				t.Errorf("exit %d, want %d", rc, c.code)
			}
			if b, _ := os.ReadFile(w.path("sources/datasheets/a.pdf")); string(b) != "REGISTERED\n" {
				t.Errorf("the registered file changed: %q", b)
			}
			if after, _ := os.ReadFile(w.path("sources/SOURCES.md")); string(after) != string(before) {
				t.Error("a row was written for a cancelled run")
			}
			if p := partFiles(w); len(p) != 0 {
				t.Errorf("part files left: %v", p)
			}
			if !pidDead(t, w.root+"/sleep.pid") {
				t.Error("the download's child process survived the cancel (an orphan)")
			}
			if exists(w.root + "/finished") {
				t.Error("the download was not cancelled: it ran to completion")
			}
		})
	}
}

func TestSignalMidConversionKillsPandocAndInstallsNothing(t *testing.T) {
	w := newWorld(t, "curl", "wget", "pandoc-hang")
	w.setEnv("STUB_ROUTES=", "STUB_HANG_MARKER="+w.root+"/started", "STUB_HANG_PIDFILE="+w.root+"/sleep.pid")
	rc := cancelDuring(t, w, syscall.SIGTERM, "web", "http://h/page", w.dir)
	if rc != 143 {
		t.Errorf("exit %d", rc)
	}
	if exists(w.path("sources/web-snapshots/h_page.md")) || exists(w.path("sources/SOURCES.md")) {
		t.Error("a cancelled conversion installed or registered something")
	}
	if p := partFiles(w); len(p) != 0 {
		t.Errorf("part files left: %v", p)
	}
	if left, _ := os.ReadDir(w.tmp); len(left) != 0 {
		t.Errorf("TMPDIR not cleaned: %v", left)
	}
	if !pidDead(t, w.root+"/sleep.pid") {
		t.Error("pandoc's child survived")
	}
}

// notifyThisProcess routes real signals sent to the test process into a channel, as Run does.
func notifyThisProcess(t *testing.T) <-chan os.Signal {
	t.Helper()
	ch := make(chan os.Signal, 2)
	signal.Notify(ch, syscall.SIGINT, syscall.SIGTERM)
	t.Cleanup(func() { signal.Stop(ch) })
	return ch
}

func TestSeamAfterForkSignalIsHonouredBeforeAnyDownload(t *testing.T) {
	w := newWorld(t, "curl", "wget")
	w.setEnv("STUB_ROUTES=", "FETCHDOC_TEST_SEAM=1", "FETCHDOC_TEST_AT=after-fork", "FETCHDOC_TEST_CMD=kill -TERM $$")
	got := w.goRunSig(notifyThisProcess(t), os.Getpid(), "doc", "http://h/a.pdf", w.dir)
	if got.rc != 143 || exists(w.path("sources/SOURCES.md")) || len(partFiles(w)) != 0 {
		t.Errorf("rc=%d tree:\n%s", got.rc, got.tree)
	}
}

func TestSignalAfterTheInstallPointIsIgnoredSoRowAndBytesAgree(t *testing.T) {
	w := newWorld(t, "curl", "wget")
	w.setEnv("STUB_ROUTES=", "FETCHDOC_TEST_SEAM=1", "FETCHDOC_TEST_AT=install", "FETCHDOC_TEST_CMD=kill -TERM $$")
	got := w.goRunSig(notifyThisProcess(t), os.Getpid(), "doc", "http://h/a.pdf", w.dir)
	if got.rc != 0 || !exists(w.path("sources/datasheets/a.pdf")) {
		t.Fatalf("rc=%d err=%q", got.rc, got.err)
	}
	md, _ := os.ReadFile(w.path("sources/SOURCES.md"))
	if !srcregistry.HasRow(md, "datasheets/a.pdf", "") {
		t.Error("the bytes landed without their row")
	}
}

func TestSeamIsInertWithoutTheOptIn(t *testing.T) {
	for _, optIn := range []bool{false, true} {
		w := newWorld(t, "curl", "wget")
		w.setEnv("STUB_ROUTES=", "FETCHDOC_TEST_AT=install", "FETCHDOC_TEST_CMD=: > \"$MARK\"", "MARK="+w.root+"/seam.marker")
		if optIn {
			w.setEnv("FETCHDOC_TEST_SEAM=1")
		}
		w.goRun("doc", "http://h/a.pdf", w.dir)
		if exists(w.root+"/seam.marker") != optIn {
			t.Errorf("opt-in=%v: marker=%v", optIn, exists(w.root+"/seam.marker"))
		}
	}
}

func TestConcurrentWriterAtInstall(t *testing.T) {
	const hook = "FETCHDOC_TEST_SEAM=1"
	t.Run("a file that appears is never overwritten without --replace", func(t *testing.T) {
		w := newWorld(t, "curl", "wget")
		w.setEnv("STUB_ROUTES=", hook, "FETCHDOC_TEST_AT=install", `FETCHDOC_TEST_CMD=printf "OTHER-RUN\n" > "$DEST"`)
		got := w.goRun("doc", "http://h/a.pdf", w.dir)
		if b, _ := os.ReadFile(w.path("sources/datasheets/a.pdf")); got.rc != 4 || string(b) != "OTHER-RUN\n" || exists(w.path("sources/SOURCES.md")) || len(partFiles(w)) != 0 {
			t.Errorf("rc=%d dest=%q err=%q", got.rc, b, got.err)
		}
	})
	t.Run("with --replace the appeared bytes are archived, not destroyed", func(t *testing.T) {
		w := newWorld(t, "curl", "wget")
		w.setEnv("STUB_ROUTES=", hook, "FETCHDOC_TEST_AT=install", `FETCHDOC_TEST_CMD=printf "OTHER-RUN\n" > "$DEST"`)
		got := w.goRun("--replace", "doc", "http://h/a.pdf", w.dir)
		v := "sources/datasheets/a." + srcregistry.SHA256Hex([]byte("OTHER-RUN\n"))[:12] + ".pdf"
		if b, _ := os.ReadFile(w.path(v)); got.rc != 0 || string(b) != "OTHER-RUN\n" {
			t.Errorf("rc=%d archived=%q err=%q", got.rc, b, got.err)
		}
	})
	t.Run("a symlink that appears is refused and not written through", func(t *testing.T) {
		w := newWorld(t, "curl", "wget")
		w.setEnv("STUB_ROUTES=", hook, "FETCHDOC_TEST_AT=install", `FETCHDOC_TEST_CMD=ln -s "$LINK" "$DEST"`, "LINK="+w.root+"/victim.txt")
		got := w.goRun("doc", "http://h/a.pdf", w.dir)
		if got.rc != 5 || exists(w.root+"/victim.txt") || exists(w.path("sources/SOURCES.md")) {
			t.Errorf("rc=%d err=%q", got.rc, got.err)
		}
	})
}
