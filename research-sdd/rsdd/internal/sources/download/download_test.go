package download

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/sources/runner/runnertest"
)

// tools scripts curl and wget: probes answer 200, a download writes body (or fails / writes nothing).
type tools struct {
	curlRC, wgetRC int
	curlBody       string
	wgetBody       string
	probeCode      string
	probeLoc       string
}

func (tl tools) script(argv []string) runnertest.Reply {
	out := ""
	for i, a := range argv {
		if a == "-o" || a == "-O" {
			out = argv[i+1]
		}
	}
	switch argv[0] {
	case "curl":
		if strings.Contains(strings.Join(argv, " "), "http_code") {
			code := tl.probeCode
			if code == "" {
				code = "200"
			}
			return runnertest.Reply{Stdout: code + " 0.02 " + tl.probeLoc}
		}
		if tl.curlRC != 0 {
			_ = os.WriteFile(out, []byte("PARTIAL"), 0o644)
			return runnertest.Reply{RC: tl.curlRC, Stderr: "curl: failed\n"}
		}
		_ = os.WriteFile(out, []byte(tl.curlBody), 0o644)
	case "wget":
		_ = os.WriteFile(out, []byte(tl.wgetBody), 0o644) // wget -O creates the target even on failure
		return runnertest.Reply{RC: tl.wgetRC}
	}
	return runnertest.Reply{}
}

type fx struct {
	f    Fetcher
	fake *runnertest.Fake
	err  bytes.Buffer
	dir  string
}

func newFx(t *testing.T, tl tools, have ...string) *fx {
	x := &fx{dir: t.TempDir(), fake: &runnertest.Fake{Script: tl.script}}
	set := map[string]bool{}
	for _, h := range have {
		set[h] = true
	}
	x.f = Fetcher{Run: x.fake, Have: func(n string) bool { return set[n] }, Err: &x.err, Pid: 4242}
	return x
}

func (x *fx) fetch(url string, keep bool) (string, int) {
	return x.f.Fetch(context.Background(), url, filepath.Join(x.dir, "doc.pdf"), keep)
}

func TestPartPathIsMarkedWithThePid(t *testing.T) {
	if got := (Fetcher{Pid: 7}).PartPath("/d/a.pdf"); got != "/d/a.pdf.fetchdoc-part.7" {
		t.Error(got)
	}
}

func TestCurlSuccessKeepsThePartForTheCaller(t *testing.T) {
	x := newFx(t, tools{curlBody: "BODY"}, "curl", "wget")
	eff, code := x.fetch("http://a/x", true)
	if eff != "http://a/x" || code != 0 || x.err.Len() != 0 {
		t.Fatalf("%q %d %q", eff, code, x.err.String())
	}
	b, _ := os.ReadFile(x.f.PartPath(filepath.Join(x.dir, "doc.pdf")))
	if string(b) != "BODY" {
		t.Errorf("part %q", b)
	}
	if _, err := os.Stat(filepath.Join(x.dir, "doc.pdf")); err == nil {
		t.Error("with keepPart the destination must not be touched")
	}
	if want := "curl -fsS -L http://a/x -o " + x.f.PartPath(filepath.Join(x.dir, "doc.pdf")); x.fake.Calls()[len(x.fake.Calls())-1] != want {
		t.Errorf("download argv %q", x.fake.Calls())
	}
}

func TestWithoutKeepPartTheDownloadIsMovedIntoPlace(t *testing.T) {
	x := newFx(t, tools{curlBody: "BODY"}, "curl")
	if _, code := x.fetch("http://a/x", false); code != 0 {
		t.Fatal(code)
	}
	if b, _ := os.ReadFile(filepath.Join(x.dir, "doc.pdf")); string(b) != "BODY" {
		t.Errorf("%q", b)
	}
	if _, err := os.Stat(x.f.PartPath(filepath.Join(x.dir, "doc.pdf"))); err == nil {
		t.Error("part file left behind")
	}
}

func TestPermanentRedirectIsAnnouncedAfterTheDownload(t *testing.T) {
	x := newFx(t, tools{curlBody: "B", probeCode: "301", probeLoc: "http://a/new"}, "curl")
	x.fake.Script = func(argv []string) runnertest.Reply {
		tl := tools{curlBody: "B"}
		if strings.Contains(strings.Join(argv, " "), "http_code") {
			if argv[len(argv)-1] == "http://a/old" {
				return runnertest.Reply{Stdout: "301 0.02 http://a/new"}
			}
		}
		return tl.script(argv)
	}
	eff, code := x.fetch("http://a/old", true)
	if eff != "http://a/new" || code != 0 || x.err.String() != "fetch-doc: registered http://a/new (permanent redirect from http://a/old)\n" {
		t.Errorf("%q %d %q", eff, code, x.err.String())
	}
	if last := x.fake.Calls()[len(x.fake.Calls())-1]; !strings.HasPrefix(last, "curl -fsS -L http://a/new -o ") {
		t.Errorf("the download must target the resolved URL: %q", last)
	}
}

func TestEmptyBodyRegistersNothingAndSkipsWget(t *testing.T) {
	x := newFx(t, tools{curlBody: ""}, "curl", "wget")
	if eff, code := x.fetch("http://a/x", true); eff != "" || code != 1 || x.err.String() != "fetch-doc: empty body: http://a/x\n" {
		t.Errorf("%q %d %q", eff, code, x.err.String())
	}
	if x.fake.Count("wget") != 0 {
		t.Error("an empty 200 must not fall back to wget")
	}
	if _, err := os.Stat(x.f.PartPath(filepath.Join(x.dir, "doc.pdf"))); err == nil {
		t.Error("empty part left behind")
	}
}

func TestCurlFailureFallsBackToWgetOnTheTypedURL(t *testing.T) {
	x := newFx(t, tools{curlRC: 7, wgetBody: "W"}, "curl", "wget")
	eff, code := x.fetch("http://a/x", true)
	if eff != "http://a/x" || code != 0 {
		t.Fatalf("%q %d", eff, code)
	}
	if !strings.HasSuffix(x.err.String(), "fetch-doc: registered requested URL (wget fallback; effective URL unknown)\n") {
		t.Errorf("%q", x.err.String())
	}
	if b, _ := os.ReadFile(x.f.PartPath(filepath.Join(x.dir, "doc.pdf"))); string(b) != "W" {
		t.Errorf("part %q: the curl leftover must not survive", b)
	}
	if want := "wget -q http://a/x -O " + x.f.PartPath(filepath.Join(x.dir, "doc.pdf")); x.fake.Calls()[len(x.fake.Calls())-1] != want {
		t.Errorf("wget argv %q", x.fake.Calls())
	}
}

func TestWgetFailureModesNameTheirCause(t *testing.T) {
	for _, c := range []struct {
		name string
		tl   tools
		have []string
		want string
	}{
		{"wget failed", tools{curlRC: 7, wgetRC: 4, wgetBody: "X"}, []string{"curl", "wget"}, "fetch-doc: wget fallback ALSO failed for http://a/x; nothing registered\n"},
		{"wget empty", tools{curlRC: 7}, []string{"curl", "wget"}, "fetch-doc: empty body: http://a/x (wget fallback); nothing registered\n"},
		{"no wget", tools{curlRC: 7}, []string{"curl"}, "fetch-doc: curl failed and wget is not installed for http://a/x; nothing registered\n"},
	} {
		t.Run(c.name, func(t *testing.T) {
			x := newFx(t, c.tl, c.have...)
			eff, code := x.fetch("http://a/x", true)
			if eff != "" || code != 1 || !strings.HasSuffix(x.err.String(), c.want) {
				t.Errorf("%q %d %q", eff, code, x.err.String())
			}
			if _, err := os.Stat(x.f.PartPath(filepath.Join(x.dir, "doc.pdf"))); err == nil {
				t.Error("part file left behind")
			}
		})
	}
}

func TestWithoutCurlWgetIsTheOnlyDownloaderAndNothingIsProbed(t *testing.T) {
	x := newFx(t, tools{wgetBody: "W"}, "wget")
	if eff, code := x.fetch("http://a/x", true); eff != "http://a/x" || code != 0 {
		t.Errorf("%q %d", eff, code)
	}
	if x.fake.Count("curl") != 0 {
		t.Errorf("curl must not run: %v", x.fake.Calls())
	}
}

func TestAFailedDownloadNeverTouchesTheRegisteredFile(t *testing.T) {
	x := newFx(t, tools{curlRC: 18}, "curl")
	final := filepath.Join(x.dir, "doc.pdf")
	if err := os.WriteFile(final, []byte("REGISTERED"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, code := x.f.Fetch(context.Background(), "http://a/x", final, false); code != 1 {
		t.Fatal(code)
	}
	if b, _ := os.ReadFile(final); string(b) != "REGISTERED" {
		t.Errorf("registered evidence changed: %q", b)
	}
}

func TestMoveFailureIsReported(t *testing.T) {
	x := newFx(t, tools{curlBody: "B"}, "curl")
	final := filepath.Join(x.dir, "doc.pdf")
	if err := os.Mkdir(final, 0o755); err != nil { // renaming a file over a directory fails
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(final, "keep"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	eff, code := x.f.Fetch(context.Background(), "http://a/x", final, false)
	if eff != "" || code != 1 || !strings.Contains(x.err.String(), "fetch-doc: could not move download into place: "+final+"\n") {
		t.Errorf("%q %d %q", eff, code, x.err.String())
	}
	if _, err := os.Stat(x.f.PartPath(final)); err == nil {
		t.Error("part file left behind after a failed move")
	}
}

func TestCancelledRunNeitherFallsBackNorSpeaks(t *testing.T) {
	x := newFx(t, tools{curlRC: 143}, "curl", "wget")
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	eff, code := x.f.Fetch(ctx, "http://a/x", filepath.Join(x.dir, "d"), true)
	if eff != "" || code != Cancelled || x.err.Len() != 0 || x.fake.Count("wget") != 0 {
		t.Errorf("%q %d %q %v", eff, code, x.err.String(), x.fake.Calls())
	}
}
