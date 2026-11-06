package redirect

import (
	"bytes"
	"context"
	"fmt"
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/sources/runner/runnertest"
)

// hop is one URL's answer: code and Location for the HEAD probe (head) and the GET-fallback probe (get).
type hop struct {
	headCode, headLoc string
	headRC            int
	headTC            string // %{time_connect}; "" = 0.020000
	getCode, getLoc   string
	getRC             int
}

// world answers curl probes from a table, like the shell stub did, and counts them per kind.
type world struct {
	hops map[string]hop
	fake *runnertest.Fake
	err  bytes.Buffer
}

func newWorld(h map[string]hop) *world {
	w := &world{hops: h}
	w.fake = &runnertest.Fake{Script: func(argv []string) runnertest.Reply {
		url := argv[len(argv)-1]
		h, ok := w.hops[url]
		if !ok {
			h = hop{headCode: "200", getCode: "200"}
		}
		isHead := false
		for _, a := range argv {
			if a == "-I" {
				isHead = true
			}
		}
		if isHead {
			tc := h.headTC
			if tc == "" {
				tc = "0.020000"
			}
			if h.headCode == "" {
				return runnertest.Reply{RC: h.headRC}
			}
			return runnertest.Reply{Stdout: fmt.Sprintf("%s %s %s", h.headCode, tc, h.headLoc), RC: h.headRC}
		}
		if h.getCode == "" {
			return runnertest.Reply{RC: h.getRC, Stderr: "curl: get failed\n"}
		}
		return runnertest.Reply{Stdout: fmt.Sprintf("%s %s", h.getCode, h.getLoc), RC: h.getRC}
	}}
	return w
}

func (w *world) resolve(url string) string {
	return Resolver{Run: w.fake, Err: &w.err}.Resolve(context.Background(), url)
}

func perm(code, loc string) hop { return hop{headCode: code, headLoc: loc, getCode: code, getLoc: loc} }

func TestNoRedirectKeepsTheTypedURLSilently(t *testing.T) {
	w := newWorld(nil)
	if got := w.resolve("http://a/x"); got != "http://a/x" || w.err.Len() != 0 {
		t.Errorf("got %q err %q", got, w.err.String())
	}
	if n := w.fake.Count("-I"); n != 1 || w.fake.Count("-r 0-0") != 0 {
		t.Errorf("a definitive HEAD must cost exactly one probe: %v", w.fake.Calls())
	}
}

func TestProbeArgvShape(t *testing.T) {
	w := newWorld(nil)
	w.resolve("http://a/x")
	want := "curl -sS -I -o /dev/null --connect-timeout 10 --max-time 20 -w %{http_code} %{time_connect} %{redirect_url} http://a/x"
	if c := w.fake.Calls(); len(c) != 1 || c[0] != want {
		t.Errorf("%q", c)
	}
}

func TestFollowsOnlyPermanentRedirects(t *testing.T) {
	for _, c := range []struct {
		name string
		hops map[string]hop
		want string
	}{
		{"301 then 308", map[string]hop{"http://a/1": perm("301", "http://a/2"), "http://a/2": perm("308", "http://a/3")}, "http://a/3"},
		{"temporary 302 stops", map[string]hop{"http://a/1": perm("302", "http://a/2")}, "http://a/1"},
		{"303 stops", map[string]hop{"http://a/1": perm("303", "http://a/2")}, "http://a/1"},
		{"307 stops", map[string]hop{"http://a/1": perm("307", "http://a/2")}, "http://a/1"},
		{"301 then 302 keeps the 301 target", map[string]hop{"http://a/1": perm("301", "http://a/2"), "http://a/2": perm("302", "http://signed/x?sig=1")}, "http://a/2"},
		{"404 is terminal", map[string]hop{"http://a/1": perm("404", "")}, "http://a/1"},
	} {
		t.Run(c.name, func(t *testing.T) {
			w := newWorld(c.hops)
			if got := w.resolve("http://a/1"); got != c.want {
				t.Errorf("got %q want %q (err %q)", got, c.want, w.err.String())
			}
		})
	}
}

func TestRefusesNonHTTPSchemeWithNotice(t *testing.T) {
	for _, loc := range []string{"file:///etc/passwd", "javascript:alert(1)", "data:text/plain,x", "ftp://h/x", "//h/x", "/relative"} {
		w := newWorld(map[string]hop{"http://a/1": perm("301", loc)})
		if got := w.resolve("http://a/1"); got != "http://a/1" {
			t.Errorf("%s: registered %q", loc, got)
		}
		want := fmt.Sprintf("fetch-doc: refused non-http(s) redirect scheme (%s); keeping http://a/1\n", loc)
		if w.err.String() != want {
			t.Errorf("%s: notice %q", loc, w.err.String())
		}
	}
}

func TestLocationWithoutTargetKeepsTheURL(t *testing.T) {
	w := newWorld(map[string]hop{"http://a/1": perm("301", "")})
	if got := w.resolve("http://a/1"); got != "http://a/1" || w.err.Len() != 0 {
		t.Errorf("got %q err %q", got, w.err.String())
	}
}

func TestPipeInLocationIsPercentEncoded(t *testing.T) {
	w := newWorld(map[string]hop{"http://a/1": perm("301", "http://a/x|y||z")})
	if got := w.resolve("http://a/1"); got != "http://a/x%7Cy%7C%7Cz" {
		t.Errorf("got %q", got)
	}
}

func TestHopCapBoundsAChainAndALoop(t *testing.T) {
	chain := map[string]hop{}
	for i := 0; i < 15; i++ {
		chain[fmt.Sprintf("http://a/%d", i)] = perm("301", fmt.Sprintf("http://a/%d", i+1))
	}
	w := newWorld(chain)
	if got := w.resolve("http://a/0"); got != "http://a/10" {
		t.Errorf("a long chain stops after MaxHops hops: %q", got)
	}
	if want := "fetch-doc: hop cap (10) reached; keeping http://a/10\n"; w.err.String() != want {
		t.Errorf("notice %q", w.err.String())
	}
	if n := w.fake.Count("-I"); n != MaxHops {
		t.Errorf("%d probes, want %d", n, MaxHops)
	}
	loop := newWorld(map[string]hop{"http://l/a": perm("301", "http://l/b"), "http://l/b": perm("301", "http://l/a")})
	if got := loop.resolve("http://l/a"); got != "http://l/a" || !strings.Contains(loop.err.String(), "hop cap (10) reached") {
		t.Errorf("loop: %q %q", got, loop.err.String())
	}
}

func TestExactlyMaxHopsChainStillReportsTheCap(t *testing.T) {
	chain := map[string]hop{}
	for i := 0; i < MaxHops; i++ {
		chain[fmt.Sprintf("http://a/%d", i)] = perm("301", fmt.Sprintf("http://a/%d", i+1))
	}
	w := newWorld(chain)
	if got := w.resolve("http://a/0"); got != "http://a/10" || !strings.Contains(w.err.String(), "hop cap") {
		t.Errorf("%q %q", got, w.err.String())
	}
}

func TestHeadRefusedFallsBackToGet(t *testing.T) {
	w := newWorld(map[string]hop{"http://a/1": {headCode: "405", getCode: "301", getLoc: "http://a/2"}})
	if got := w.resolve("http://a/1"); got != "http://a/2" {
		t.Errorf("got %q", got)
	}
	if w.fake.Count("-r 0-0") != 1 || w.fake.Count("-I") != 2 {
		t.Errorf("hop 1 costs a HEAD and a GET, hop 2 only a HEAD: %v", w.fake.Calls())
	}
	if !strings.Contains(w.fake.Calls()[1], "-r 0-0 -w %{http_code} %{redirect_url} http://a/1") {
		t.Errorf("GET fallback argv: %q", w.fake.Calls()[1])
	}
}

func TestBothProbesFailingKeepsTheURLWithNotice(t *testing.T) {
	w := newWorld(map[string]hop{"http://a/1": {headRC: 22, getRC: 22}})
	if got := w.resolve("http://a/1"); got != "http://a/1" {
		t.Errorf("got %q", got)
	}
	if want := "curl: get failed\nfetch-doc: redirect probe failed for http://a/1; keeping http://a/1\n"; w.err.String() != want {
		t.Errorf("notice %q", w.err.String())
	}
	if w.fake.Count("-r 0-0") != 1 {
		t.Errorf("a non-connect failure must still try the GET: %v", w.fake.Calls())
	}
}

func TestConnectClassFailuresSkipTheGetRetry(t *testing.T) {
	for _, c := range []struct {
		name  string
		h     hop
		skips bool
	}{
		{"exit 6", hop{headRC: 6}, true},
		{"exit 7", hop{headRC: 7}, true},
		{"28 with zero time_connect", hop{headCode: "000", headRC: 28, headTC: "0.000000"}, true},
		{"28 with bare 0", hop{headCode: "000", headRC: 28, headTC: "0"}, true},
		{"28 with nine zeros", hop{headCode: "000", headRC: 28, headTC: "0.000000000"}, true},
		{"28 with nonzero time_connect (response hung)", hop{headCode: "000", headRC: 28, headTC: "1.234000", getCode: "301", getLoc: "http://a/2"}, false},
	} {
		t.Run(c.name, func(t *testing.T) {
			w := newWorld(map[string]hop{"http://a/1": c.h})
			got := w.resolve("http://a/1")
			gets := w.fake.Count("-r 0-0")
			if c.skips && (gets != 0 || got != "http://a/1" || !strings.Contains(w.err.String(), "redirect probe failed")) {
				t.Errorf("must skip the GET: gets=%d got=%q err=%q", gets, got, w.err.String())
			}
			if !c.skips && (gets != 1 || got != "http://a/2") {
				t.Errorf("must retry with GET: gets=%d got=%q", gets, got)
			}
		})
	}
}

func TestEmptyTimeConnectCountsAsNeverConnected(t *testing.T) {
	// "000 <empty> " : the time_connect field is empty.
	w := newWorld(map[string]hop{"http://a/1": {headCode: "000", headRC: 28, headTC: " "}})
	w.fake.Script = func(argv []string) runnertest.Reply { return runnertest.Reply{Stdout: "000  ", RC: 28} }
	if got := w.resolve("http://a/1"); got != "http://a/1" || w.fake.Count("-r 0-0") != 0 {
		t.Errorf("got %q calls %v", got, w.fake.Calls())
	}
}

func TestCancelledContextStopsWithoutANotice(t *testing.T) {
	w := newWorld(nil)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	w.fake.Script = func(argv []string) runnertest.Reply { return runnertest.Reply{RC: 143} }
	got := Resolver{Run: w.fake, Err: &w.err}.Resolve(ctx, "http://a/1")
	if got != "http://a/1" || w.err.Len() != 0 {
		t.Errorf("got %q err %q", got, w.err.String())
	}
}

func TestNeverReachedHostTable(t *testing.T) {
	for _, c := range []struct {
		rc   int
		tc   string
		want bool
	}{{6, "5", true}, {7, "", true}, {28, "0", true}, {28, "", true}, {28, "0.000001", false}, {22, "0", false}, {0, "0", false}, {1, "0", false}} {
		if got := neverReachedHost(c.rc, c.tc); got != c.want {
			t.Errorf("%+v got %v", c, got)
		}
	}
}

func TestStringHelpersFollowShellSemantics(t *testing.T) {
	if before("a b c", " ") != "a" || before("abc", " ") != "abc" || after("a b c", " ") != "b c" || after("abc", " ") != "abc" {
		t.Error("before/after must mirror ${s%% *} and ${s#* }")
	}
}
