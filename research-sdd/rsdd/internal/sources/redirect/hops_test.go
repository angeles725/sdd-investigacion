package redirect

import "testing"

// After a real permanent hop the answer is the LAST permanent URL, never the typed one: a refusal or a probe
// failure on a later hop keeps where the chain had got to, and the notice names that URL.
func TestLaterHopFailuresKeepTheLastPermanentURL(t *testing.T) {
	cases := []struct {
		name   string
		second hop
		notice string
	}{
		{"scheme refusal", perm("301", "javascript:alert(1)"),
			"fetch-doc: refused non-http(s) redirect scheme (javascript:alert(1)); keeping http://a/mid\n"},
		{"probe failure", hop{headRC: 22, getRC: 22},
			"curl: get failed\nfetch-doc: redirect probe failed for http://a/mid; keeping http://a/mid\n"},
		{"temporary redirect", perm("302", "http://a/tmp"), ""},
		{"permanent without a target", perm("301", ""), ""},
	}
	for _, c := range cases {
		w := newWorld(map[string]hop{"http://a/1": perm("301", "http://a/mid"), "http://a/mid": c.second})
		if got := w.resolve("http://a/1"); got != "http://a/mid" {
			t.Errorf("%s: registered %q, want the last permanent URL", c.name, got)
		}
		if w.err.String() != c.notice {
			t.Errorf("%s: notice %q, want %q", c.name, w.err.String(), c.notice)
		}
	}
}

// Any HEAD answer that is not 2xx or a redirect is not definitive: the zero-range GET decides, and a permanent
// redirect it reports is still followed.
func TestNonDefinitiveHeadCodesFallBackToGet(t *testing.T) {
	for _, code := range []string{"403", "404", "405", "500", "000"} {
		w := newWorld(map[string]hop{"http://a/1": {headCode: code, getCode: "301", getLoc: "http://a/2"}})
		if got := w.resolve("http://a/1"); got != "http://a/2" {
			t.Errorf("HEAD %s: registered %q, want http://a/2", code, got)
		}
		if n := w.fake.Count("-r 0-0"); n != 1 {
			t.Errorf("HEAD %s: %d GET probes, want 1: %v", code, n, w.fake.Calls())
		}
		if w.err.String() != "" {
			t.Errorf("HEAD %s: notice %q", code, w.err.String())
		}
	}
}
