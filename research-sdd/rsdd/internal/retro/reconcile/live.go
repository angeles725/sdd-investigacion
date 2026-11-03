package reconcile

import (
	"context"
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/gh"
)

// DefaultRepo is the repository whose issues the audit reads (the legacy _REPO).
const DefaultRepo = "angeles725/sdd-investigacion"

// defaultListLimit is RECONCILE_ISSUES_LIST_LIMIT's default: GitHub search's practical ceiling (kit issue #1369 c).
const defaultListLimit = 1000

// The --jq programs of the legacy script, byte for byte: every record ends with one record-separator line (octal
// 036), so the issue COUNT is readable without a JSON parser and the cap guard can count every returned issue.
const (
	jqOpen   = `.[] | .body, "\u001e"`
	jqClosed = `.[] | (if .stateReason == "COMPLETED" then ("Closed-issue-number: \(.number // "")\n" + (([.body] + [(.comments // [])[] | select(.authorAssociation as $a | ["OWNER","MEMBER","COLLABORATOR"] | index($a)) | .body]) | join("\n"))) else "" end), "\u001e"`
	// jqClosedOld is the kit issue #1752 fallback for a gh without the stateReason --json field.
	jqClosedOld = `.[] | "\u001f\(.number)", ([.body] + [(.comments // [])[] | select(.authorAssociation as $a | ["OWNER","MEMBER","COLLABORATOR"] | index($a)) | .body] | join("\n") | gsub("[\u001e\u001f]"; "")), "\u001e"`
	jqReasons   = `.[] | "\(.number) \(.state_reason // "")"`
)

var (
	reOldGH      = regexp.MustCompile(`Unknown JSON field.*stateReason`)
	reRetryAfter = regexp.MustCompile(`retry-after[:= ]+([0-9]{1,12})([^0-9]|$)`)
	reRateReset  = regexp.MustCompile(`x-ratelimit-reset[:= ]+([0-9]{1,12})([^0-9]|$)`)
	reRetroDate  = regexp.MustCompile(`^([0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01]))([^0-9]|$)`)
)

// listLimit is RECONCILE_ISSUES_LIST_LIMIT: the text handed to gh --limit, its value, and the degraded line when
// it is not a positive integer. Unset or empty is the default.
func listLimit(get func(string) string) (text string, n int, bad string) {
	text = get("RECONCILE_ISSUES_LIST_LIMIT")
	if text == "" {
		return strconv.Itoa(defaultListLimit), defaultListLimit, ""
	}
	n, err := strconv.Atoi(text)
	if strings.Trim(text, "0123456789") != "" || text == "0" {
		return text, 0, fmt.Sprintf("degraded: RECONCILE_ISSUES_LIST_LIMIT must be a positive integer (got '%s')", text)
	}
	if err != nil { // more digits than an int holds: larger than any cap that can be filled
		n = int(^uint(0) >> 1)
	}
	return text, n, ""
}

// ghClient is one run's gh access: the bounded launcher, the --limit, and the state_reason listing cache (kit
// issue #1752), shared by every retro of the run.
type ghClient struct {
	ctx       context.Context
	o         gh.Options
	repo      string
	limitText string
	limit     int
	get       func(string) string
	sleep     func(context.Context, time.Duration)
	now       func() time.Time

	// err is the first operational failure (the context ending, a gh run core/proc could not finish).
	err error

	// sinceReq is the oldest retro date the current closed lookup needs, as an ISO instant ("" = unbounded).
	sinceReq string
	sr       stateReasons
}

// stateReasons is the per-run listing of "<number> <state_reason>" lines for the closed issues of one repo,
// loaded since a bound ("none" = the whole listing).
type stateReasons struct {
	loaded bool
	repo   string
	since  string
	lines  []string
}

func newGHClient(ctx context.Context, o Options, limitText string, limit int) *ghClient {
	repo := o.Repo
	if repo == "" {
		repo = DefaultRepo
	}
	sleep := o.Sleep
	if sleep == nil {
		sleep = sleepCtx
	}
	return &ghClient{ctx: ctx, o: o.GH, repo: repo, limitText: limitText, limit: limit, get: o.Env, sleep: sleep, now: o.Now}
}

func sleepCtx(ctx context.Context, d time.Duration) {
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
	case <-t.C:
	}
}

// run is one gh call. ok is false when the run must stop for an operational reason (g.err is set).
func (g *ghClient) run(args ...string) (gh.RunResult, bool) {
	if err := g.ctx.Err(); err != nil {
		g.err = fmt.Errorf("reconcile: %w", err)
		return gh.RunResult{}, false
	}
	res, err := gh.Run(g.o, args...)
	if err != nil {
		g.err = fmt.Errorf("reconcile: %w", err)
		return res, false
	}
	if res.State != gh.StateOK && res.RC == 0 { // the output cap stops gh without an exit code of its own
		res.RC = 1
	}
	return res, true
}

// substitution is what `$(...)` leaves of gh's stdout: NUL bytes dropped and every trailing newline removed.
func substitution(b []byte) string {
	return strings.TrimRight(strings.ReplaceAll(string(b), "\x00", ""), "\n")
}

// firstLine is `head -1` of gh's stderr.
func firstLine(b []byte) string {
	s, _, _ := strings.Cut(string(b), "\n")
	return s
}

// withMsg is `${msg:+ — }${msg}`.
func withMsg(msg string) string {
	if msg == "" {
		return ""
	}
	return " — " + msg
}

// countSeps is the number of record-separator lines of out.
func countSeps(out string) int {
	n := 0
	for _, l := range strings.Split(out, "\n") {
		if l == recordSep {
			n++
		}
	}
	return n
}

func searchFor(prefix string) string { return `"Source retro: ` + prefix + ` ·"` }

// openBodies is the live branch of the open-issue read: one query per signature prefix, the record separators
// removed, one newline after each reply. The reply of a query that fails or fills the --limit is a typed
// degraded, never a confident answer (kit issue #1369 c).
func (g *ghClient) openBodies(r *Report, base string, prefixes []string) (string, bool) {
	var all strings.Builder
	for _, p := range prefixes {
		res, ok := g.run("issue", "list", "--repo", g.repo, "--state", "open", "--limit", g.limitText,
			"--search", searchFor(p), "--json", "body", "--jq", jqOpen)
		if !ok {
			return "", false
		}
		if res.State != gh.StateOK {
			r.degrade("degraded: gh issue list failed for %s (exit %d)%s", base, res.RC, withMsg(firstLine(res.Stderr)))
			return "", false
		}
		out := substitution(res.Stdout)
		if n := countSeps(out); n >= g.limit { // RECONCILE_ISSUES_LIST_CAP_GUARD
			r.degrade("degraded: gh issue list returned %d results = the --limit %s cap for %s — the result may be truncated (raise RECONCILE_ISSUES_LIST_LIMIT)", n, g.limitText, base)
			return "", false
		}
		all.WriteString(dropSeps(out))
		all.WriteString("\n")
	}
	return all.String(), true
}

// dropSeps is `printf '%s\n' | awk '$0 != "\036"'` inside a substitution: the separator lines removed.
func dropSeps(out string) string {
	var keep []string
	for _, l := range strings.Split(out, "\n") {
		if l != recordSep {
			keep = append(keep, l)
		}
	}
	return strings.TrimRight(strings.Join(keep, "\n"), "\n")
}

// closedBodies is _fetch_closed_bodies for the live gh path: the closed-as-completed records (body plus the
// comments of a trusted author) of every signature prefix, record separators kept (kit issue #1709).
func (g *ghClient) closedBodies(r *Report, base string, prefixes []string) (string, bool) {
	var all strings.Builder
	for _, p := range prefixes {
		res, ok := g.run("issue", "list", "--repo", g.repo, "--state", "closed", "--limit", g.limitText,
			"--search", searchFor(p), "--json", "body,stateReason,comments,number", "--jq", jqClosed)
		if !ok {
			return "", false
		}
		out := substitution(res.Stdout)
		if res.State != gh.StateOK {
			em := firstLine(res.Stderr)
			rc := res.RC
			if reOldGH.Match(res.Stderr) { // RECONCILE_ISSUES_OLD_GH_FALLBACK
				fb, ok := g.closedOldGH(r, p)
				if !ok {
					return "", false
				}
				out, rc = fb, 0
			}
			if rc != 0 {
				r.degrade("degraded: gh issue list (closed) failed for %s (exit %d)%s", base, rc, withMsg(em))
				return "", false
			}
		}
		if n := countSeps(out); n >= g.limit {
			r.degrade("degraded: gh issue list (closed) returned %d results = the --limit %s cap for %s — the result may be truncated (raise RECONCILE_ISSUES_LIST_LIMIT)", n, g.limitText, base)
			return "", false
		}
		all.WriteString(out + "\n")
	}
	return strings.TrimRight(all.String(), "\n"), true
}

// closedOldGH is _closed_query_old_gh: for a gh without the stateReason --json field, list number+body+comments
// and read each state_reason from the batched REST listing, printing the same record stream the primary query
// prints. A failed listing is a typed degraded; an issue still missing after one reload keeps only its signature
// lines (its rows read borderline) plus a typed note.
func (g *ghClient) closedOldGH(r *Report, prefix string) (string, bool) {
	g.sinceReq = ""
	d := prefix[strings.LastIndex(prefix, "/")+1:]
	if m := reRetroDate.FindStringSubmatch(d); m != nil {
		// The bound is the retro filename's date MINUS TWO DAYS at 00:00:00Z: the filename carries the author's
		// LOCAL date while updated_at is UTC, and the second day absorbs a retro seeded the day before its date.
		if t, err := time.Parse("2006-01-02", m[1]); err == nil { // RECONCILE_ISSUES_SINCE_DERIVE
			g.sinceReq = t.AddDate(0, 0, -2).Format("2006-01-02") + "T00:00:00Z" // RECONCILE_ISSUES_SINCE_MARGIN
		} else {
			r.note("note: date arithmetic unavailable — the closed-issue listing for %s is not bounded by a retro date", d)
		}
	}
	res, ok := g.run("issue", "list", "--repo", g.repo, "--state", "closed", "--limit", g.limitText,
		"--search", searchFor(prefix), "--json", "number,body,comments", "--jq", jqClosedOld)
	if !ok {
		return "", false
	}
	if res.State != gh.StateOK {
		r.degrade("degraded: gh issue list (closed, old-gh fallback) failed (exit %d)%s", res.RC, withMsg(firstLine(res.Stderr)))
		return "", false
	}
	raw := substitution(res.Stdout)
	if !g.loadStateReasons(r, false) {
		return "", false
	}
	bad, unk := map[string]bool{}, map[string]bool{}
	for _, l := range strings.Split(raw, "\n") {
		num, isMark := strings.CutPrefix(l, "\x1f")
		if !isMark || num == "" {
			continue
		}
		sr, found, ok := g.stateReasonOf(r, num)
		switch {
		case !ok:
			return "", false
		case !found:
			unk[num] = true
			r.note("note: state_reason for issue #%s missing from the closed-issue listing after one reload — its rows are reported borderline, not shipped", num)
		case sr != "completed":
			bad[num] = true
		}
	}
	var out []string
	skip, sigOnly := false, false
	for _, l := range strings.Split(raw, "\n") {
		switch {
		case strings.HasPrefix(l, "\x1f"):
			num := l[1:]
			skip, sigOnly = bad[num], unk[num]
			if !skip {
				out = append(out, "Closed-issue-number: "+num)
			}
		case l == recordSep:
			out = append(out, l)
			skip, sigOnly = false, false
		case skip:
		case sigOnly && !strings.Contains(l, "Source retro: "):
		default:
			out = append(out, l)
		}
	}
	return strings.TrimRight(strings.Join(out, "\n"), "\n"), true
}

// stateReasonOf is _state_reason_of: the cached state_reason of a closed issue of the current repo. found is
// false when the issue is missing even after ONE forced reload of the listing (a stale cache); ok is false when
// the listing failed (the typed degraded was already written).
func (g *ghClient) stateReasonOf(r *Report, num string) (reason string, found, ok bool) {
	if !g.loadStateReasons(r, false) {
		return "", false, false
	}
	for i := 0; i < 2; i++ {
		for _, l := range g.sr.lines {
			f := strings.Fields(l)
			if len(f) > 0 && f[0] == num {
				if len(f) > 1 {
					reason = f[1]
				}
				return reason, true, true
			}
		}
		if i == 0 && !g.loadStateReasons(r, true) {
			return "", false, false
		}
	}
	return "", false, true
}

// loadStateReasons is _load_state_reasons: ONE paginated `gh api repos/<repo>/issues?state=closed` call (REST
// items carry state_reason) with one bounded retry. A cached listing for the current repo is reused unless force
// is given, and serves a request only when its bound covers it (an equal or newer bound, or none); an older or
// unbounded request reloads with the OLDER bound, so one run never thrashes (kit issue #1784).
func (g *ghClient) loadStateReasons(r *Report, force bool) bool {
	cached := ""
	if g.sr.loaded {
		cached = g.sr.since
	}
	covers := true
	if cached != "" && cached != "none" {
		covers = g.sinceReq != "" && g.sinceReq >= cached
	}
	here := g.sr.loaded && g.sr.repo == g.repo
	if !force && covers && here {
		return true
	}
	eff := g.sinceReq
	if cached != "" && here {
		if cached == "none" {
			eff = ""
		} else if eff != "" && cached < eff {
			eff = cached
		}
	}
	url := "repos/" + g.repo + "/issues?state=closed&per_page=100"
	if eff != "" {
		url += "&since=" + eff // RECONCILE_ISSUES_CLOSED_SINCE
	}
	var em string
	for try := 1; try <= 2; try++ {
		res, ok := g.run("api", "--paginate", url, "--jq", jqReasons)
		if !ok {
			return false
		}
		if res.State == gh.StateOK {
			since := eff
			if since == "" {
				since = "none"
			}
			g.sr = stateReasons{loaded: true, repo: g.repo, since: since, lines: strings.Split(substitution(res.Stdout), "\n")}
			return true
		}
		em = firstLine(res.Stderr)
		if try == 1 {
			g.retryPause(r, res.Stderr) // RECONCILE_ISSUES_RETRY_PAUSE: no wait after the final failure
		}
	}
	r.degrade("degraded: gh api state_reason listing failed (this gh has no stateReason --json field)%s", withMsg(em))
	return false
}

// envSeconds reads a non-negative integer knob; unset, empty or not all digits is def.
func (g *ghClient) envSeconds(name string, def int) int {
	v := g.get(name)
	if v == "" || strings.Trim(v, "0123456789") != "" {
		return def
	}
	n, err := strconv.Atoi(v)
	if err != nil {
		return def
	}
	return n
}

// retryPause is _retry_pause: the wait before the ONE retry of the batched listing, since an immediate retry of a
// rate-limited call fails the same way. In order: a Retry-After (seconds) found in gh's stderr; else the seconds
// until an X-RateLimit-Reset (epoch) found there; else RECONCILE_ISSUES_RETRY_BACKOFF (default 2). It is at least
// 1 s and at most RECONCILE_ISSUES_RETRY_MAX_WAIT (default 30; 0 = never wait), so a hostile or buggy header can
// never stall the run.
func (g *ghClient) retryPause(r *Report, stderr []byte) {
	w := g.envSeconds("RECONCILE_ISSUES_RETRY_BACKOFF", 2)
	maxWait := g.envSeconds("RECONCILE_ISSUES_RETRY_MAX_WAIT", 30)
	t := asciiLower(substitution(stderr))
	if m := reRetryAfter.FindStringSubmatch(t); m != nil { // RECONCILE_ISSUES_RETRY_AFTER
		w, _ = strconv.Atoi(m[1])
	} else if m := reRateReset.FindStringSubmatch(t); m != nil && g.now != nil {
		reset, _ := strconv.ParseInt(m[1], 10, 64)
		w = int(reset - g.now().Unix())
	}
	w = min(max(w, 1), maxWait) // RECONCILE_ISSUES_RETRY_CAP: at least 1 s, at most the max (0 = never wait)
	if w < 1 {
		return
	}
	r.note("note: gh api state_reason listing failed — retrying once in %ds", w)
	g.sleep(g.ctx, time.Duration(w)*time.Second)
}

// toolName and ghLogin are the fixed words of the two ProbeGH messages (the legacy script's text, byte for byte).
const (
	toolName = "reconcile-issues"
	ghLogin  = "gh auth login"
)

// ProbeGH is the §7 degraded probe of a run without an --issues-cache: gh missing or not authenticated is a typed
// degraded line (the caller exits 1), never a silent pass. "" = gh is usable. The error is operational only.
func ProbeGH(o gh.Options) (string, error) {
	res, err := gh.Run(o, "auth", "status")
	switch {
	case err != nil:
		return "", fmt.Errorf("reconcile: %w", err)
	case res.State == gh.StateMissing:
		return fmt.Sprintf("degraded: gh not found on PATH — install gh CLI to use %s", toolName), nil
	case res.State != gh.StateOK:
		return fmt.Sprintf("degraded: gh is not authenticated — run '%s'", ghLogin), nil
	}
	return "", nil
}

// LoadCache is the batch prefetch for callers that audit several retros (rsdd status show): every OPEN issue body
// of repo in one gh call, reusable across retros as Options.IssuesCache. A run that finds untracked rows against
// such a cache re-verifies them with a per-retro query (see Run). The listing honours RECONCILE_ISSUES_LIST_LIMIT
// read from gh.Options.Env; a failed query or a reply that fills the limit is an error, never a partial cache.
func LoadCache(ctx context.Context, o gh.Options, repo string) (*Cache, error) {
	if repo == "" {
		repo = DefaultRepo
	}
	text, limit, bad := listLimit(func(k string) string { return envValue(o.Env, k) })
	if bad != "" {
		return nil, fmt.Errorf("reconcile: %s", bad)
	}
	g := &ghClient{ctx: ctx, o: o, repo: repo, limitText: text, limit: limit}
	res, ok := g.run("issue", "list", "--repo", repo, "--state", "open", "--limit", text, "--json", "body", "--jq", jqOpen)
	if !ok {
		return nil, g.err
	}
	if res.State != gh.StateOK {
		return nil, fmt.Errorf("reconcile: gh issue list failed (exit %d)%s", res.RC, withMsg(firstLine(res.Stderr)))
	}
	out := substitution(res.Stdout)
	if n := countSeps(out); n >= limit {
		return nil, fmt.Errorf("reconcile: gh issue list returned %d results = the --limit %s cap — the result may be truncated (raise RECONCILE_ISSUES_LIST_LIMIT)", n, text)
	}
	c := CacheBodies(dropSeps(out))
	c.prefetched = true
	return c, nil
}

// envValue is the last KEY=VALUE entry of environ for key.
func envValue(environ []string, key string) string {
	for i := len(environ) - 1; i >= 0; i-- {
		if v, ok := strings.CutPrefix(environ[i], key+"="); ok {
			return v
		}
	}
	return ""
}

// asciiLower is `tr 'A-Z' 'a-z'`.
func asciiLower(s string) string {
	return strings.Map(func(r rune) rune {
		if r >= 'A' && r <= 'Z' {
			return r + 'a' - 'A'
		}
		return r
	}, s)
}
