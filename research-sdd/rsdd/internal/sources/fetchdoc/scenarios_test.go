package fetchdoc

import (
	"fmt"
	"os"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/srcregistry"
)

// scenario is one differential case: the stubs that exist, the environment (STUB_* controls of the frozen
// curl/wget stubs), the files present before the run and the command line. Only behaviour the Go port keeps is
// here; the intended divergences have their own tests (divergence_test.go).
type scenario struct {
	name  string
	stubs []string
	env   []string
	setup func(w *world)
	args  func(w *world) []string
}

func routes(lines ...string) string { return "STUB_ROUTES=" + strings.Join(lines, "\n") }

func doc(url string, rest ...string) func(*world) []string {
	return func(w *world) []string { return append([]string{"doc", url, w.dir}, rest...) }
}

func withFlag(flag string, f func(*world) []string) func(*world) []string {
	return func(w *world) []string { return append([]string{flag}, f(w)...) }
}

// seeded registers rel (under sources/) with content and a matching row, the way an earlier run would have.
func seeded(rel, content string) func(*world) {
	return func(w *world) {
		w.write("sources/"+rel, content)
		_ = srcregistry.Append(w.dir+"/sources", srcregistry.FormatRow(rel, "datasheets", "http://old", "2026-01-01T00:00:00Z", srcregistry.SHA256Hex([]byte(content))))
	}
}

var curlWget = []string{"curl", "wget"}

func scenarios() []scenario {
	chain := []string{}
	for i := 0; i < 12; i++ {
		chain = append(chain, fmt.Sprintf("http://h/c%d 301 http://h/c%d", i, i+1))
	}
	longURL := "http://h/" + strings.Repeat("seg/", 30) + "page.html"
	return []scenario{
		{name: "doc-basic", stubs: curlWget, args: doc("http://h/a.pdf")},
		{name: "doc-named-in-manuals", stubs: curlWget, args: doc("http://h/a.pdf", "manuals", "custom.pdf")},
		{name: "doc-name-from-url-without-query", stubs: curlWget, args: doc("http://h/p/x.pdf?dl=1&v=2")},
		{name: "doc-replace-flag-after-mode", stubs: curlWget, args: func(w *world) []string { return []string{"doc", "http://h/a.pdf", w.dir, "--replace"} }},
		{name: "doc-exists-refused", stubs: curlWget, setup: seeded("datasheets/a.pdf", "REGISTERED\n"), args: doc("http://h/a.pdf")},
		{name: "doc-replace-new-bytes", stubs: curlWget, env: []string{"STUB_BODY=NEW-BYTES"}, setup: seeded("datasheets/a.pdf", "OLD\n"), args: withFlag("--replace", doc("http://h/a.pdf"))},
		{name: "doc-replace-identical-registered", stubs: curlWget, env: []string{"STUB_BODY=SAME"}, setup: seeded("datasheets/a.pdf", "SAME\n"), args: withFlag("--replace", doc("http://h/a.pdf"))},
		{name: "doc-replace-identical-unregistered", stubs: curlWget, env: []string{"STUB_BODY=SAME"}, setup: func(w *world) { w.write("sources/datasheets/a.pdf", "SAME\n") }, args: withFlag("--replace", doc("http://h/a.pdf"))},
		{name: "doc-replace-without-extension", stubs: curlWget, env: []string{"STUB_BODY=NEW"}, setup: seeded("datasheets/README", "OLD\n"), args: withFlag("--replace", doc("http://h/README"))},
		{name: "doc-replace-versioned-name-taken", stubs: curlWget, env: []string{"STUB_BODY=NEW"}, setup: func(w *world) {
			seeded("datasheets/a.pdf", "OLD\n")(w)
			w.write("sources/datasheets/a."+srcregistry.SHA256Hex([]byte("OLD\n"))[:12]+".pdf", "DIFFERENT")
		}, args: withFlag("--replace", doc("http://h/a.pdf"))},
		{name: "doc-replace-other-row-sha", stubs: curlWget, env: []string{"STUB_BODY=NEW"}, setup: func(w *world) {
			seeded("datasheets/a.pdf", "OLD\n")(w)
			_ = srcregistry.Append(w.dir+"/sources", srcregistry.FormatRow("datasheets/a.pdf", "datasheets", "http://legacy", "2026-01-01T00:00:00Z", "legacysha"))
		}, args: withFlag("--replace", doc("http://h/a.pdf"))},
		{name: "doc-symlink-destination", stubs: curlWget, setup: func(w *world) {
			_ = os.MkdirAll(w.dir+"/sources/datasheets", 0o755)
			_ = os.Symlink("/nonexistent/elsewhere", w.dir+"/sources/datasheets/a.pdf")
		}, args: doc("http://h/a.pdf")},
		{name: "doc-symlink-destination-with-replace", stubs: curlWget, setup: func(w *world) {
			_ = os.MkdirAll(w.dir+"/sources/datasheets", 0o755)
			_ = os.Symlink("/nonexistent/elsewhere", w.dir+"/sources/datasheets/a.pdf")
		}, args: withFlag("--replace", doc("http://h/a.pdf"))},
		{name: "doc-registry-with-trailing-prose", stubs: curlWget, setup: func(w *world) {
			w.write("sources/SOURCES.md", srcregistry.Header+"| datasheets/old.pdf | datasheets | http://o | 2026-01-01T00:00:00Z | abc | |\n\n## Structure\n\n```\nsources/\n```\n")
		}, args: doc("http://h/a.pdf")},
		{name: "doc-backslash-url", stubs: curlWget, args: doc(`http://h/a\test\back.pdf`, "datasheets", "bs.pdf")},
		{name: "doc-redirect-permanent", stubs: curlWget, env: []string{routes("http://h/a.pdf 301 http://h/b.pdf", "http://h/b.pdf 308 http://h/c.pdf")}, args: doc("http://h/a.pdf")},
		{name: "doc-redirect-temporary-keeps-typed-url", stubs: curlWget, env: []string{routes("http://h/a.pdf 302 http://cdn/signed?sig=1")}, args: doc("http://h/a.pdf")},
		{name: "doc-redirect-non-http-scheme-refused", stubs: curlWget, env: []string{routes("http://h/a.pdf 301 file:///etc/passwd")}, args: doc("http://h/a.pdf")},
		{name: "doc-redirect-pipe-in-location", stubs: curlWget, env: []string{routes("http://h/a.pdf 301 http://h/x|y.pdf")}, args: doc("http://h/a.pdf")},
		{name: "doc-redirect-hop-cap", stubs: curlWget, env: []string{routes(chain...)}, args: doc("http://h/c0")},
		{name: "doc-redirect-probe-fails", stubs: curlWget, env: []string{"STUB_PROBE_FAIL_URL=http://h/a.pdf"}, args: doc("http://h/a.pdf")},
		{name: "doc-redirect-connect-fail-skips-get", stubs: curlWget, env: []string{"STUB_HEAD_CONNECT_FAIL_URL=http://h/a.pdf"}, args: doc("http://h/a.pdf")},
		{name: "doc-redirect-head-hang-retries-get", stubs: curlWget, env: []string{"STUB_HEAD_HANG_URL=http://h/a.pdf"}, args: doc("http://h/a.pdf")},
		{name: "doc-redirect-head-405-then-get-301", stubs: curlWget, env: []string{"STUB_HEAD_FAIL_URL=http://h/a.pdf", routes("http://h/a.pdf 301 http://h/b.pdf")}, args: doc("http://h/a.pdf")},
		{name: "doc-curl-fails-wget-registers-typed-url", stubs: curlWget, env: []string{"STUB_DOWNLOAD_FAIL=1"}, args: doc("http://h/a.pdf")},
		{name: "doc-curl-and-wget-fail", stubs: curlWget, env: []string{"STUB_DOWNLOAD_FAIL=1", "STUB_WGET_FAIL=1"}, args: doc("http://h/a.pdf")},
		{name: "doc-wget-empty-body", stubs: curlWget, env: []string{"STUB_DOWNLOAD_FAIL=1", "STUB_WGET_EMPTY=1"}, args: doc("http://h/a.pdf")},
		{name: "doc-curl-empty-body", stubs: curlWget, env: []string{"STUB_DOWNLOAD_EMPTY=1"}, args: doc("http://h/a.pdf")},
		{name: "doc-partial-download-keeps-registered-file", stubs: curlWget, env: []string{"STUB_DOWNLOAD_PARTIAL=1", "STUB_WGET_FAIL=1"}, setup: seeded("datasheets/a.pdf", "REGISTERED\n"), args: withFlag("--replace", doc("http://h/a.pdf"))},
		{name: "doc-wget-only", stubs: []string{"wget"}, args: doc("http://h/a.pdf")},
		{name: "doc-curl-only-failing", stubs: []string{"curl"}, env: []string{"STUB_DOWNLOAD_FAIL=1"}, args: doc("http://h/a.pdf")},
		{name: "doc-no-downloader", args: doc("http://h/a.pdf")},
		{name: "doc-pdf-hint", stubs: curlWget, env: []string{"STUB_BODY=%PDF-1.4 stub"}, args: doc("http://h/a.pdf")},
		{name: "doc-stale-part-sweep", stubs: curlWget, setup: func(w *world) {
			w.write("sources/datasheets/dead.pdf.fetchdoc-part.2147483646", "debris")
			w.write("sources/datasheets/live.pdf.fetchdoc-part.1", "in progress")
			w.write("sources/datasheets/kept.fetchdoc-part.2147483645", "registered")
			w.write("sources/datasheets/odd.fetchdoc-part.12x", "not a pid")
			_ = srcregistry.Append(w.dir+"/sources", srcregistry.FormatRow("datasheets/kept.fetchdoc-part.2147483645", "datasheets", "http://o", "2026-01-01T00:00:00Z", "sha"))
		}, args: doc("http://h/a.pdf")},
		{name: "web-basic", stubs: []string{"curl", "wget", "pandoc"}, args: func(w *world) []string { return []string{"web", "http://h/forum/t?id=1", w.dir} }},
		{name: "web-without-pandoc-copies", stubs: curlWget, args: func(w *world) []string { return []string{"web", "http://h/page", w.dir} }},
		{name: "web-pandoc-fails-copies", stubs: []string{"curl", "wget", "pandoc-fail"}, args: func(w *world) []string { return []string{"web", "http://h/page", w.dir} }},
		{name: "web-long-url-hash-name", stubs: curlWget, args: func(w *world) []string { return []string{"web", longURL, w.dir} }},
		{name: "web-exists-refused", stubs: curlWget, setup: func(w *world) { w.write("sources/web-snapshots/h_page.md", "OLD") }, args: func(w *world) []string { return []string{"web", "http://h/page", w.dir} }},
		{name: "web-replace-new-bytes", stubs: curlWget, env: []string{"STUB_BODY=NEW"}, setup: func(w *world) {
			w.write("sources/web-snapshots/h_page.md", "OLD\n")
			_ = srcregistry.Append(w.dir+"/sources", srcregistry.FormatRow("web-snapshots/h_page.md", "web-snapshot", "http://h/page", "2026-01-01T00:00:00Z", srcregistry.SHA256Hex([]byte("OLD\n"))))
		}, args: func(w *world) []string { return []string{"--replace", "web", "http://h/page", w.dir} }},
		{name: "web-replace-identical", stubs: curlWget, env: []string{"STUB_BODY=SAME"}, setup: func(w *world) {
			w.write("sources/web-snapshots/h_page.md", "SAME\n")
			_ = srcregistry.Append(w.dir+"/sources", srcregistry.FormatRow("web-snapshots/h_page.md", "web-snapshot", "http://h/page", "2026-01-01T00:00:00Z", srcregistry.SHA256Hex([]byte("SAME\n"))))
		}, args: func(w *world) []string { return []string{"web", "http://h/page", w.dir, "--replace"} }},
		{name: "web-permanent-redirect-registered", stubs: curlWget, env: []string{routes("http://h/old 301 http://h/new")}, args: func(w *world) []string { return []string{"web", "http://h/old", w.dir} }},
		{name: "web-curl-fails-wget-fallback", stubs: curlWget, env: []string{"STUB_DOWNLOAD_FAIL=1"}, args: func(w *world) []string { return []string{"web", "http://h/page", w.dir} }},
		{name: "web-empty-body", stubs: curlWget, env: []string{"STUB_DOWNLOAD_EMPTY=1"}, args: func(w *world) []string { return []string{"web", "http://h/page", w.dir} }},
		{name: "web-no-downloader", args: func(w *world) []string { return []string{"web", "http://h/page", w.dir} }},
		{name: "ocr-two-pages", stubs: []string{"tesseract", "pdftoppm"}, args: func(w *world) []string { return []string{"ocr", "scan.pdf"} }},
		{name: "ocr-ignores-replace", stubs: []string{"tesseract", "pdftoppm"}, args: func(w *world) []string { return []string{"--replace", "ocr", "scan.pdf"} }},
		{name: "ocr-without-tesseract", stubs: []string{"pdftoppm"}, args: func(w *world) []string { return []string{"ocr", "scan.pdf"} }},
		{name: "ocr-pdftoppm-fails", stubs: []string{"tesseract", "pdftoppm-fail"}, args: func(w *world) []string { return []string{"ocr", "scan.pdf"} }},
		{name: "ocr-without-pdftoppm", stubs: []string{"tesseract"}, args: func(w *world) []string { return []string{"ocr", "scan.pdf"} }},
		{name: "unknown-mode", args: func(w *world) []string { return []string{"fetch", "http://h/a"} }},
		{name: "unknown-mode-flag-shaped", args: func(w *world) []string { return []string{"--bogus", "doc"} }},
	}
}
