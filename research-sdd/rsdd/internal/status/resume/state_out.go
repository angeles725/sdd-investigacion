package resume

import (
	"fmt"
	"regexp"
	"strconv"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/envelope"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/gh"
	envstate "github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/state"
)

// ghLimit is the page size asked of gh: a full page means the list may be incomplete.
const ghLimit = 1000

// openPRs is the PR block of the script. prs is nil exactly when the list is unknown, and then status says why; an empty
// non-nil list is gh's authoritative "no open PRs". truncated is nil when the list is unknown.
func (r *stateRun) openPRs(useGH bool) (prs []jv, status string, truncated *bool) {
	if !useGH {
		return nil, "skipped", nil
	}
	// The script had already changed into the repository: a relative PATH entry is relative to it.
	switch {
	case !onPath(r.env, r.top, "gh"):
		return nil, "degraded:gh-missing", nil
	// Without timeout the script's gh call would exit 127 and read as a gh failure; the real cause is named instead.
	case !onPath(r.env, r.top, "timeout"):
		return nil, "degraded:timeout-missing", nil
	}
	res, err := gh.Run(gh.Options{Env: r.env, Dir: r.top, Knob: "RSDD_RESUME_GH_TIMEOUT", Default: 30, Now: r.s.Clock},
		"pr", "list", "--state", "open", "--limit", strconv.Itoa(ghLimit), "--json", "number,headRefName,state,url")
	switch {
	case err != nil || res.State == gh.StateError || res.State == gh.StateMissing || res.State == gh.StateOutputCap || res.State == gh.StateProbeFailed:
		return nil, "degraded:gh-failed", nil
	case res.State == gh.StateTimeout:
		return nil, "degraded:gh-timeout", nil
	}
	mapped, ok := mapPRs(res.Stdout)
	if !ok {
		return nil, "degraded:gh-bad-json", nil
	}
	// gh silently caps at its limit. More than one document is not a list jq could count: the script reads it as not full.
	full := len(mapped) == 1 && len(mapped[0]) >= ghLimit
	return mapped[0], "ok", &full
}

// mapPRs is `jq -c 'map({number, branch:.headRefName, state, url})'` over the output of gh, one result per document:
// an array maps its elements and an object its values, a null element yields nulls, and any other shape (or no document
// at all) is a jq failure.
func mapPRs(raw []byte) ([][]jv, bool) {
	docs, err := parseDocs(raw)
	if err != nil || len(docs) == 0 {
		return nil, false
	}
	var out [][]jv
	for _, d := range docs {
		var elems []jv
		switch x := d.(type) {
		case []jv:
			elems = x
		case *jobj:
			for _, k := range x.keys {
				elems = append(elems, x.vals[k])
			}
		default:
			return nil, false
		}
		list := make([]jv, 0, len(elems))
		for _, e := range elems {
			if e != nil {
				if _, isObj := e.(*jobj); !isObj {
					return nil, false
				}
			}
			list = append(list, newObj().set("number", field(e, "number")).set("branch", field(e, "headRefName")).
				set("state", field(e, "state")).set("url", field(e, "url")))
		}
		out = append(out, list)
	}
	return out, true
}

// stateDoc is everything the document and the envelope are built from.
type stateDoc struct {
	generatedAt, top, remote string
	baseRef, baseSHA         string
	wt                       []worktree
	br                       []branch
	prs                      []jv
	prsStatus                string
	prsTruncated             *bool
}

func nullable(s string) jv {
	if s == "" {
		return nil
	}
	return toValid(s)
}

func intOrNull(p *int) jv {
	if p == nil {
		return nil
	}
	return *p
}

func (w worktree) object() *jobj {
	return newObj().set("path", toValid(w.path)).set("branch", nullable(w.branch)).set("head", nullable(w.head)).
		set("exists", w.exists).set("prunable", w.prunable).set("dirty", intOrNull(w.dirty)).
		set("untracked", intOrNull(w.untracked)).set("ahead", intOrNull(w.ahead)).set("behind", intOrNull(w.behind))
}

func (b branch) object() *jobj {
	return newObj().set("name", toValid(b.name)).set("head", toValid(b.head)).set("ahead", intOrNull(b.ahead)).set("behind", intOrNull(b.behind))
}

func (d stateDoc) truncatedJV() jv {
	if d.prsTruncated == nil {
		return nil
	}
	return *d.prsTruncated
}

// document is the default output: one JSON document, indented like jq prints it.
func (d stateDoc) document() []byte {
	wts, brs := make([]jv, 0, len(d.wt)), make([]jv, 0, len(d.br))
	for _, w := range d.wt {
		wts = append(wts, w.object())
	}
	for _, b := range d.br {
		brs = append(brs, b.object())
	}
	var prs jv
	if d.prs != nil {
		prs = d.prs
	}
	doc := newObj().set("schema", stateSchema).set("generated_at", d.generatedAt).
		set("repo", newObj().set("toplevel", toValid(d.top)).set("remote", nullable(d.remote))).
		set("base_ref", toValid(d.baseRef)).set("base_sha", toValid(d.baseSHA)).
		set("worktrees", wts).set("branches", brs).set("prs", prs).set("prs_truncated", d.truncatedJV()).
		set("prs_status", d.prsStatus)
	var b strings.Builder
	writeJV(&b, doc, true, 0)
	b.WriteByte('\n')
	return []byte(b.String())
}

// envelope is the --json form: the same facts as typed items of a json-envelope.v1 document.
func (d stateDoc) envelope() ([]byte, error) {
	obj := func(kind string, o *jobj) (envelope.Object, error) {
		out := envelope.Object{{Key: "kind", Value: kind}}
		for _, k := range o.keys {
			v, err := envValue2(o.vals[k])
			if err != nil {
				return nil, err
			}
			out = append(out, envelope.Field{Key: k, Value: v})
		}
		return out, nil
	}
	repo := newObj().set("generated_at", d.generatedAt).set("toplevel", toValid(d.top)).set("remote", nullable(d.remote)).
		set("base_ref", toValid(d.baseRef)).set("base_sha", toValid(d.baseSHA)).set("prs_status", d.prsStatus).
		set("prs_truncated", d.truncatedJV())
	var items []envelope.Object
	add := func(kind string, o *jobj) error {
		it, err := obj(kind, o)
		items = append(items, it)
		return err
	}
	if err := add("repo", repo); err != nil {
		return nil, err
	}
	missing, dirty := 0, 0
	for _, w := range d.wt {
		if !w.exists {
			missing++
		}
		if w.dirty != nil && *w.dirty > 0 {
			dirty++
		}
		if err := add("worktree", w.object()); err != nil {
			return nil, err
		}
	}
	for _, b := range d.br {
		if err := add("branch", b.object()); err != nil {
			return nil, err
		}
	}
	for _, p := range d.prs {
		if err := add("pr", p.(*jobj)); err != nil {
			return nil, err
		}
	}
	unknown := 0
	if d.prs == nil {
		unknown = 1
	}
	return envelope.Envelope{
		Schema: stateSchema, State: envstate.OK,
		Counts: envelope.Object{{Key: "worktrees", Value: len(d.wt)}, {Key: "worktrees_missing", Value: missing},
			{Key: "worktrees_dirty", Value: dirty}, {Key: "branches", Value: len(d.br)},
			{Key: "prs", Value: len(d.prs)}, {Key: "prs_unknown", Value: unknown}},
		Items: items,
	}.Pretty(envelope.ReasonBeforeCounts)
}

var plainInt = regexp.MustCompile(`^-?(0|[1-9][0-9]*)$`)

// envValue2 converts a jv to what the envelope renderer prints. The renderer has no number type but integers: a PR
// field that is a number written any other way (7.0, 1e2) cannot be carried by the envelope and fails the build.
func envValue2(v jv) (any, error) {
	switch x := v.(type) {
	case nil, bool, int, string:
		return x, nil
	case jnum:
		if !plainInt.MatchString(string(x)) || string(x) == "-0" {
			return nil, fmt.Errorf("number %s is not an integer", x)
		}
		n, err := strconv.ParseInt(string(x), 10, 64)
		if err != nil {
			return nil, err
		}
		return n, nil
	case []jv:
		out := make([]any, len(x))
		for i, e := range x {
			c, err := envValue2(e)
			if err != nil {
				return nil, err
			}
			out[i] = c
		}
		return out, nil
	case *jobj:
		out := envelope.Object{}
		for _, k := range x.keys {
			c, err := envValue2(x.vals[k])
			if err != nil {
				return nil, err
			}
			out = append(out, envelope.Field{Key: k, Value: c})
		}
		return out, nil
	}
	return nil, fmt.Errorf("unsupported value %T", v)
}
