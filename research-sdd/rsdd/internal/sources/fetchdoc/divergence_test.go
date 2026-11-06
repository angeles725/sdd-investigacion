package fetchdoc

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/srcregistry"
)

// divergence is one intended difference from the legacy script (declared in tool-registry.d/fetch-doc.md). check
// asserts what the Go command does; legacy, when set, asserts what the frozen script did (the differential file
// runs it, so each divergence is pinned from both sides).
type divergence struct {
	name   string
	stubs  []string
	env    []string
	setup  func(w *world)
	args   func(w *world) []string
	check  func(t *testing.T, w *world, got ran)
	legacy func(t *testing.T, w *world, got ran)
}

const (
	usageGeneralLine = "usage: fetch-doc.sh [--replace] doc|web|ocr ...\n"
	docUsageLine     = "usage: fetch-doc.sh doc <url> <target-dir> [datasheets|manuals] [name]\n"
)

func wantUsage(reason, usage string) func(*testing.T, *world, ran) {
	return func(t *testing.T, _ *world, got ran) {
		t.Helper()
		if got.rc != 2 || got.out != "" || got.err != "fetch-doc: "+reason+"\n"+usage {
			t.Errorf("want exit 2 with %q, got rc=%d out=%q err=%q", reason, got.rc, got.out, got.err)
		}
	}
}

func legacyBashFailure(t *testing.T, _ *world, got ran) {
	t.Helper()
	if got.rc != 1 || !strings.Contains(got.err, "fetch-doc.sh: line ") {
		t.Errorf("the legacy script fails with a bash line-number message and exit 1, got rc=%d err=%q", got.rc, got.err)
	}
}

func noFileNamed(t *testing.T, w *world, name string) {
	t.Helper()
	_ = filepath.Walk(w.root, func(p string, fi os.FileInfo, err error) error {
		if err == nil && !fi.IsDir() && filepath.Base(p) == name {
			t.Errorf("%s was written", strings.TrimPrefix(p, w.root+"/"))
		}
		return nil
	})
}

func fileNamed(t *testing.T, w *world, name string) bool {
	t.Helper()
	found := false
	_ = filepath.Walk(w.root, func(p string, fi os.FileInfo, err error) error {
		if err == nil && !fi.IsDir() && filepath.Base(p) == name {
			found = true
		}
		return nil
	})
	return found
}

func mode(t *testing.T, path string) os.FileMode {
	t.Helper()
	fi, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	return fi.Mode().Perm()
}

func divergences() []divergence {
	curl := []string{"curl", "wget"}
	return []divergence{
		{name: "usage-no-mode", args: func(*world) []string { return nil }, check: wantUsage("missing mode", usageGeneralLine), legacy: legacyBashFailure},
		{name: "usage-only-replace", args: func(*world) []string { return []string{"--replace"} }, check: wantUsage("missing mode", usageGeneralLine), legacy: legacyBashFailure},
		{name: "usage-doc-no-url", args: func(*world) []string { return []string{"doc"} }, check: wantUsage("missing url", docUsageLine), legacy: legacyBashFailure},
		{name: "usage-doc-empty-url", args: func(w *world) []string { return []string{"doc", "", w.dir} }, check: wantUsage("missing url", docUsageLine), legacy: legacyBashFailure},
		{name: "usage-doc-no-target", args: func(*world) []string { return []string{"doc", "http://h/a"} }, check: wantUsage("missing target-dir", docUsageLine), legacy: legacyBashFailure},
		{name: "usage-web-no-url", args: func(*world) []string { return []string{"web"} }, check: wantUsage("missing url", "usage: fetch-doc.sh web <url> <target-dir>\n"), legacy: legacyBashFailure},
		{name: "usage-web-no-target", args: func(*world) []string { return []string{"web", "http://h/a"} }, check: wantUsage("missing target-dir", "usage: fetch-doc.sh web <url> <target-dir>\n"), legacy: legacyBashFailure},
		{name: "usage-ocr-no-pdf", args: func(*world) []string { return []string{"ocr"} }, check: wantUsage("missing pdf", "usage: fetch-doc.sh ocr <pdf>\n"), legacy: legacyBashFailure},

		{name: "name-cannot-leave-sources", stubs: curl, args: func(w *world) []string { return []string{"doc", "http://h/a", w.dir, "datasheets", "../../escape.pdf"} },
			check: func(t *testing.T, w *world, got ran) {
				wantUsage("the file name must not contain \"/\"", docUsageLine)(t, w, got)
				noFileNamed(t, w, "escape.pdf")
			},
			legacy: func(t *testing.T, w *world, got ran) {
				if got.rc != 0 || !fileNamed(t, w, "escape.pdf") {
					t.Errorf("the legacy script wrote outside sources/: rc=%d", got.rc)
				}
			}},
		{name: "name-dotdot", stubs: curl, args: func(w *world) []string { return []string{"doc", "http://h/a", w.dir, "datasheets", ".."} },
			check: wantUsage(`".." is not a usable file name; give one as the last argument`, docUsageLine)},
		{name: "url-without-basename", stubs: curl, args: func(w *world) []string { return []string{"doc", "http://h/..", w.dir} },
			check: wantUsage(`".." is not a usable file name; give one as the last argument`, docUsageLine)},
		{name: "sub-cannot-leave-sources", stubs: curl, args: func(w *world) []string { return []string{"doc", "http://h/a", w.dir, "../..", "esc.pdf"} },
			check: func(t *testing.T, w *world, got ran) {
				wantUsage(`the sub-directory must not contain ".."`, docUsageLine)(t, w, got)
				noFileNamed(t, w, "esc.pdf")
			},
			legacy: func(t *testing.T, w *world, got ran) {
				if got.rc != 0 || !fileNamed(t, w, "esc.pdf") {
					t.Errorf("the legacy script wrote outside sources/: rc=%d err=%q", got.rc, got.err)
				}
			}},
		{name: "sub-absolute", stubs: curl, args: func(w *world) []string { return []string{"doc", "http://h/a", w.dir, "/abs", "x.pdf"} },
			check: wantUsage("the sub-directory must be relative to TARGET/sources", docUsageLine)},
		{name: "name-with-pipe-would-split-the-row", stubs: curl, args: func(w *world) []string { return []string{"doc", "http://h/a", w.dir, "datasheets", "a|b.pdf"} },
			check: wantUsage(`a "|" would shift the SOURCES.md columns`, docUsageLine),
			legacy: func(t *testing.T, w *world, got ran) {
				b, _ := os.ReadFile(w.path("sources/SOURCES.md"))
				if got.rc != 0 || !strings.Contains(string(b), "| datasheets/a|b.pdf |") {
					t.Errorf("the legacy script registered a row with an extra column: rc=%d\n%s", got.rc, b)
				}
			}},
		{name: "sub-with-newline", stubs: curl, args: func(w *world) []string { return []string{"doc", "http://h/a", w.dir, "da\nta", "a.pdf"} },
			check: wantUsage("control characters are not allowed", docUsageLine)},
		{name: "url-with-pipe-is-encoded-in-the-origin-cell", stubs: curl, args: func(w *world) []string { return []string{"doc", "http://h/a|b.pdf", w.dir, "datasheets", "p.pdf"} },
			check: func(t *testing.T, w *world, got ran) {
				b, _ := os.ReadFile(w.path("sources/SOURCES.md"))
				rows := srcregistry.ParseRows(b)
				last := rows[len(rows)-1]
				if got.rc != 0 || last.Origin != "http://h/a%7Cb.pdf" || last.SHA == "" || last.Citing != "" {
					t.Errorf("rc=%d row=%+v", got.rc, last)
				}
			},
			legacy: func(t *testing.T, w *world, got ran) {
				b, _ := os.ReadFile(w.path("sources/SOURCES.md"))
				rows := srcregistry.ParseRows(b)
				if got.rc != 0 || rows[len(rows)-1].Origin != "http://h/a" {
					t.Errorf("the legacy row was cut at the pipe: %+v", rows[len(rows)-1])
				}
			}},
		{name: "url-looking-like-an-option", stubs: curl, env: []string{"STUB_PROBE_COUNT_FILE=/dev/null"}, args: func(w *world) []string { return []string{"doc", "--config=/etc/passwd", w.dir} },
			check: wantUsage(`a URL must not start with "-" (curl would read it as an option)`, docUsageLine)},
		{name: "web-url-looking-like-an-option", stubs: curl, args: func(w *world) []string { return []string{"web", "-K/x", w.dir} },
			check: wantUsage(`a URL must not start with "-" (curl would read it as an option)`, "usage: fetch-doc.sh web <url> <target-dir>\n")},
		{name: "url-with-control-character", stubs: curl, args: func(w *world) []string { return []string{"doc", "http://h/a\nb", w.dir} },
			check: wantUsage("control characters are not allowed in a URL", docUsageLine)},

		{name: "sources-md-keeps-its-mode", stubs: curl,
			setup: func(w *world) {
				seeded("datasheets/old.pdf", "OLD\n")(w)
				_ = os.Chmod(w.path("sources/SOURCES.md"), 0o664)
			},
			args: doc("http://h/a.pdf"),
			check: func(t *testing.T, w *world, got ran) {
				if m := mode(t, w.path("sources/SOURCES.md")); got.rc != 0 || m != 0o664 {
					t.Errorf("rc=%d mode %v: an existing registry keeps its mode", got.rc, m)
				}
			},
			legacy: func(t *testing.T, w *world, got ran) {
				if m := mode(t, w.path("sources/SOURCES.md")); m != 0o600 {
					t.Errorf("the legacy script left the registry at %v (mktemp's mode)", m)
				}
			}},
		{name: "new-sources-md-is-not-private", stubs: curl, args: doc("http://h/a.pdf"),
			check: func(t *testing.T, w *world, got ran) {
				if m := mode(t, w.path("sources/SOURCES.md")); got.rc != 0 || m != 0o644 {
					t.Errorf("rc=%d mode %v", got.rc, m)
				}
			},
			legacy: func(t *testing.T, w *world, got ran) {
				if m := mode(t, w.path("sources/SOURCES.md")); m != 0o600 {
					t.Errorf("legacy mode %v", m)
				}
			}},

		{name: "no-sha256-tool-is-not-a-dependency", stubs: curl,
			setup: func(w *world) { _ = os.Remove(w.bin + "/sha256sum") },
			args:  doc("http://h/a.pdf"),
			check: func(t *testing.T, w *world, got ran) {
				if got.rc != 0 || !strings.Contains(got.out, "registered in SOURCES.md") {
					t.Errorf("rc=%d out=%q err=%q: the hash is computed in process", got.rc, got.out, got.err)
				}
			},
			legacy: func(t *testing.T, w *world, got ran) {
				if got.rc != 3 || !strings.Contains(got.err, "DEGRADED: no sha256 tool") {
					t.Errorf("legacy rc=%d err=%q", got.rc, got.err)
				}
			}},
		{name: "ocr-tesseract-failure-is-reported", stubs: []string{"pdftoppm"},
			setup: func(w *world) {
				_ = os.WriteFile(w.bin+"/tesseract", []byte("#!/usr/bin/env bash\ncase \"$1\" in *-2.png) exit 7 ;; *) echo ok-page ;; esac\n"), 0o755)
			},
			args: func(*world) []string { return []string{"ocr", "scan.pdf"} },
			check: func(t *testing.T, w *world, got ran) {
				if got.rc != 1 || got.out != "ok-page\n" || got.err != "fetch-doc: tesseract failed on page 2 of 2 (exit 7); the text above is incomplete\n" {
					t.Errorf("rc=%d out=%q err=%q", got.rc, got.out, got.err)
				}
			},
			legacy: func(t *testing.T, w *world, got ran) {
				if got.rc != 7 || got.err != "" {
					t.Errorf("the legacy script aborted silently with the tool's status: rc=%d err=%q", got.rc, got.err)
				}
			}},
		{name: "ocr-no-pages-is-reported", stubs: []string{"tesseract"},
			setup: func(w *world) { _ = os.WriteFile(w.bin+"/pdftoppm", []byte("#!/usr/bin/env bash\nexit 0\n"), 0o755) },
			args:  func(*world) []string { return []string{"ocr", "scan.pdf"} },
			check: func(t *testing.T, w *world, got ran) {
				if got.rc != 1 || got.out != "" || got.err != "fetch-doc: pdftoppm produced no pages for scan.pdf; nothing to read\n" {
					t.Errorf("rc=%d out=%q err=%q", got.rc, got.out, got.err)
				}
			},
			legacy: func(t *testing.T, w *world, got ran) {
				if got.rc != 0 || got.err != "" || got.out != "" {
					t.Errorf("the legacy script exited silently (a silent zero) after handing tesseract the literal glob: rc=%d out=%q err=%q", got.rc, got.out, got.err)
				}
			}},
		{name: "pdf-hint-without-file-tool", stubs: curl, env: []string{"STUB_BODY=%PDF-1.4 stub"},
			setup: func(w *world) { _ = os.Remove(w.bin + "/file") },
			args:  doc("http://h/a.pdf"),
			check: func(t *testing.T, w *world, got ran) {
				if got.rc != 0 || !strings.Contains(got.err, "hint: PDF saved.") {
					t.Errorf("rc=%d err=%q: the PDF magic is read when file(1) is missing", got.rc, got.err)
				}
			},
			legacy: func(t *testing.T, w *world, got ran) {
				if got.rc != 0 || strings.Contains(got.err, "hint:") {
					t.Errorf("the legacy hint depends on file(1): err=%q", got.err)
				}
			}},
		{name: "mkdir-failure-is-typed", stubs: curl,
			setup: func(w *world) { w.write("blocker", "i am a file") },
			args:  func(w *world) []string { return []string{"doc", "http://h/a", w.path("blocker"), "datasheets"} },
			check: func(t *testing.T, w *world, got ran) {
				if got.rc != 1 || !strings.HasPrefix(got.err, "fetch-doc: cannot create <R>/target/blocker/sources/datasheets: ") {
					t.Errorf("rc=%d err=%q", got.rc, w.norm(got.err))
				}
			}},
	}
}

func TestIntendedDivergences(t *testing.T) {
	for _, d := range divergences() {
		t.Run(d.name, func(t *testing.T) {
			w := newWorld(t, d.stubs...)
			w.setEnv(d.env...)
			if d.setup != nil {
				d.setup(w)
			}
			got := w.goRun(d.args(w)...)
			got.err, got.out = w.norm(got.err), w.norm(got.out)
			d.check(t, w, got)
		})
	}
}
