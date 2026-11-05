// Package redirect resolves the URL that gets REGISTERED in SOURCES.md for a typed one: it walks the redirect
// chain with a bounded per-hop curl probe and follows ONLY PERMANENT redirects (301/308).
//
// It stops advancing, and keeps whatever URL it holds, at the first TEMPORARY redirect (302/303/307), a
// non-http(s) Location, a non-redirect response, a probe failure, a hop with no Location, or MaxHops. That is
// deliberate: a temporary redirect is how a short-lived signed CDN/S3/GitHub-asset URL is served, and registering
// one would put an expiring, credential-bearing link in SOURCES.md; a non-http(s) scheme (file:, javascript:,
// data:) in a Location is a misconfigured or hostile server and never a citable source.
//
// Every abnormal stop prints a stderr notice, so the reason resolution stopped is never silent; the "registered X
// (permanent redirect from Y)" claim belongs to the caller, which knows whether the download then succeeded.
package redirect

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/sources/runner"
)

// Bounds of the walk and of each probe, in the units curl takes.
const (
	MaxHops        = 10 // a chain longer than this is followed only up to the cap (an A<->B loop ends here)
	MaxTime        = 20 // curl --max-time per hop, so a hanging probe is bounded
	ConnectTimeout = 10 // curl --connect-timeout, so a connect failure can be told from a slow response
)

// Resolver probes with curl through Run; probe diagnostics (curl -S) go to Err untouched.
type Resolver struct {
	Run runner.Runner
	Err io.Writer
}

// Resolve returns the URL to register for url. It never returns an empty string for a non-empty url.
func (r Resolver) Resolve(ctx context.Context, url string) string {
	cur, hop := url, 0
	for hop < MaxHops {
		code, loc := r.probe(ctx, cur)
		if ctx.Err() != nil { // cancelled: the caller stops the run, a "probe failed" notice would be a lie
			return cur
		}
		if code == "" {
			fmt.Fprintf(r.Err, "fetch-doc: redirect probe failed for %s; keeping %s\n", cur, cur)
			break
		}
		if code != "301" && code != "308" {
			break
		}
		if loc == "" {
			break
		}
		if !strings.HasPrefix(loc, "http://") && !strings.HasPrefix(loc, "https://") {
			fmt.Fprintf(r.Err, "fetch-doc: refused non-http(s) redirect scheme (%s); keeping %s\n", loc, cur)
			break
		}
		cur = strings.ReplaceAll(loc, "|", "%7C")
		hop++
	}
	if hop == MaxHops {
		fmt.Fprintf(r.Err, "fetch-doc: hop cap (%d) reached; keeping %s\n", MaxHops, cur)
	}
	return cur
}

// probe is one hop: HEAD first (a GET would download the whole body of a manual on every hop), retried as a
// zero-byte-range GET when HEAD gave no definitive answer, unless HEAD demonstrably never reached a live host.
// It returns the HTTP code and the redirect target; an empty code means no usable response.
func (r Resolver) probe(ctx context.Context, cur string) (code, loc string) {
	out, rc := r.curl(ctx, "-sS", "-I", "-o", "/dev/null", "--connect-timeout", itoa(ConnectTimeout), "--max-time", itoa(MaxTime),
		"-w", "%{http_code} %{time_connect} %{redirect_url}", cur)
	timeConnect := "0"
	if out != "" {
		head, rest := before(out, " "), after(out, " ")
		timeConnect = before(rest, " ")
		out = head + " " + after(rest, " ")
	}
	switch c := before(out, " "); {
	case c == "301", c == "302", c == "303", c == "307", c == "308", len(c) == 3 && c[0] == '2':
		// HEAD gave a definitive answer.
	case neverReachedHost(rc, timeConnect):
		out = ""
	default:
		var rc2 int
		out, rc2 = r.curl(ctx, "-sS", "-o", "/dev/null", "--connect-timeout", itoa(ConnectTimeout), "--max-time", itoa(MaxTime),
			"-r", "0-0", "-w", "%{http_code} %{redirect_url}", cur)
		if rc2 != 0 {
			out = ""
		}
	}
	return before(out, " "), after(out, " ")
}

// neverReachedHost is true when a failed HEAD probe demonstrably never reached a live host, so the GET retry
// cannot do better: curl exit 6 (cannot resolve) or 7 (cannot connect) always; exit 28 (timed out) ONLY when
// time_connect is zero, i.e. the connect phase never completed. Exit 28 with a non-zero time_connect means the
// host accepted the connection and the RESPONSE then hung: the retry is worth it.
func neverReachedHost(rc int, timeConnect string) bool {
	switch rc {
	case 6, 7:
		return true
	case 28:
		switch timeConnect {
		case "0", "0.000000", "0.000000000", "":
			return true
		}
	}
	return false
}

// curl runs curl and returns its stdout with trailing newlines removed (a shell command substitution).
func (r Resolver) curl(ctx context.Context, args ...string) (string, int) {
	var out bytes.Buffer
	rc := r.Run.Run(ctx, append([]string{"curl"}, args...), &out, r.Err)
	return strings.TrimRight(out.String(), "\n"), rc
}

// before is ${s%% *}: s up to its first sep, or all of s when there is none.
func before(s, sep string) string { head, _, _ := strings.Cut(s, sep); return head }

// after is ${s#* }: s after its first sep, or all of s when there is none (the shell leaves s unchanged).
func after(s, sep string) string {
	if _, tail, ok := strings.Cut(s, sep); ok {
		return tail
	}
	return s
}

func itoa(n int) string { return fmt.Sprint(n) }
