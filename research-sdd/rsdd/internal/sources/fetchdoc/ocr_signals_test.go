package fetchdoc

import (
	"os"
	"strings"
	"syscall"
	"testing"
)

// The legacy `ocr` branch (testdata/legacy, run with INT/TERM sent to its whole process group, as a terminal does)
// answers 130/143, removes its temporary directory (the EXIT trap), prints nothing for the page it was in and never
// starts a later page. These tests pin that for a signal during pdftoppm and during each page's tesseract.
func TestSignalDuringOCRStopsTheRunAndCleansUp(t *testing.T) {
	for _, c := range []struct {
		name         string
		stubs        []string
		page         string
		wantOut      string
		wantTessRuns int
	}{
		{"pdftoppm", []string{"pdftoppm-hang", "tesseract-hang"}, "9", "", 0},
		{"first page", []string{"pdftoppm", "tesseract-hang"}, "1", "", 1},
		{"second page", []string{"pdftoppm", "tesseract-hang"}, "2", "TEXT:page1\n", 2},
	} {
		for _, s := range []struct {
			sig  os.Signal
			code int
		}{{syscall.SIGINT, 130}, {syscall.SIGTERM, 143}} {
			t.Run(c.name+"/"+s.sig.String(), func(t *testing.T) {
				w := newWorld(t, c.stubs...)
				w.setEnv("STUB_HANG_PAGE="+c.page, "STUB_HANG_MARKER="+w.root+"/started",
					"STUB_HANG_PIDFILE="+w.root+"/sleep.pid", "STUB_CALLS="+w.root+"/calls")
				got := cancelRan(t, w, s.sig, "ocr", "scan.pdf")
				if got.rc != s.code {
					t.Errorf("exit %d, want %d (err=%q)", got.rc, s.code, got.err)
				}
				if got.out != c.wantOut {
					t.Errorf("stdout %q, want %q", got.out, c.wantOut)
				}
				calls, _ := os.ReadFile(w.root + "/calls")
				if n := len(strings.Fields(string(calls))); n != c.wantTessRuns {
					t.Errorf("tesseract started %d times, want %d (a page after the signal was processed)", n, c.wantTessRuns)
				}
				if left, _ := os.ReadDir(w.tmp); len(left) != 0 {
					t.Errorf("TMPDIR not cleaned: %v", left)
				}
				if !pidDead(t, w.root+"/sleep.pid") {
					t.Error("the stage's child process survived the cancel (an orphan)")
				}
			})
		}
	}
}

func TestOCRWithAFailingPdftoppmExitsMissing(t *testing.T) {
	w := newWorld(t, "tesseract", "pdftoppm-fail")
	got := w.goRun("ocr", "scan.pdf")
	if got.rc != 3 || got.out != "" || got.err != "pdftoppm failed\n" {
		t.Errorf("rc=%d out=%q err=%q", got.rc, got.out, got.err)
	}
	if left, _ := os.ReadDir(w.tmp); len(left) != 0 {
		t.Errorf("TMPDIR not cleaned: %v", left)
	}
}
