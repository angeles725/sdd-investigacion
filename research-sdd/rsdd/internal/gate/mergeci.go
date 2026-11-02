package gate

import (
	"encoding/json"
	"errors"
	"sort"
	"strings"
	"unicode"
)

// The CI gate of merge-gate.sh (kit issues #1426, #1864): the check runs of the exact head sha, the latest run
// per (check name, app id), and the verdict. Refusals, in precedence order: ci_failed, ci_pending, ci_missing.

// ciRun is one check run reduced to what the verdict reads, the jq `map({name, status, conclusion, app_id, id})`.
type ciRun struct {
	name, status string
	conclusion   json.RawMessage // null when absent
	appID        json.RawMessage // `.app.id? // null`
	id           json.RawMessage // a number literal
	idNum        float64
}

var errCheckShape = errors.New("check runs are off-schema")

// parseCheckRuns reads the paginated check-runs answer (one JSON object per page, slurped): every page must
// carry a check_runs array of objects with a string name and status and a numeric id.
func parseCheckRuns(raw string) ([]ciRun, error) {
	pages, ok := jqSlurp(raw)
	if !ok || len(pages) == 0 {
		return nil, errCheckShape
	}
	var runs []json.RawMessage
	for _, p := range pages {
		if jqType(p) != "object" {
			return nil, errCheckShape
		}
		arr, _ := jqIndex(p, "check_runs")
		var items []json.RawMessage
		if jqType(arr) != "array" || json.Unmarshal(arr, &items) != nil {
			return nil, errCheckShape
		}
		runs = append(runs, items...)
	}
	out := make([]ciRun, 0, len(runs))
	for _, r := range runs {
		if jqType(r) != "object" {
			return nil, errCheckShape
		}
		name, _ := jqIndex(r, "name")
		status, _ := jqIndex(r, "status")
		id, _ := jqIndex(r, "id")
		n, nameOK := jqString(name)
		st, statusOK := jqString(status)
		idNum, idOK := jqNumber(id)
		if !nameOK || !statusOK || !idOK {
			return nil, errCheckShape
		}
		conclusion, _ := jqIndex(r, "conclusion")
		out = append(out, ciRun{name: n, status: st, conclusion: conclusion, appID: ciAppID(r), id: id, idNum: idNum})
	}
	return out, nil
}

// ciAppID is `.app.id? // null`: a non-object app is not an error here, and a null or false id is null.
func ciAppID(r json.RawMessage) json.RawMessage {
	app, _ := jqIndex(r, "app")
	id, ok := jqIndex(app, "id")
	if !ok || jqAbsent(id) {
		return json.RawMessage("null")
	}
	return id
}

// ciGroup is jq's group_by([.name, .app_id]): runs sorted (stably) by that key, split where it changes.
func ciGroup(runs []ciRun) [][]ciRun {
	sorted := append([]ciRun(nil), runs...)
	sort.SliceStable(sorted, func(i, j int) bool { return ciKeyCmp(sorted[i], sorted[j]) < 0 })
	var groups [][]ciRun
	for i, r := range sorted {
		if i > 0 && ciKeyCmp(sorted[i-1], r) == 0 {
			groups[len(groups)-1] = append(groups[len(groups)-1], r)
			continue
		}
		groups = append(groups, []ciRun{r})
	}
	return groups
}

func ciKeyCmp(a, b ciRun) int {
	if c := strings.Compare(a.name, b.name); c != 0 {
		return c
	}
	return jqCmp(a.appID, b.appID)
}

// ciLatest is jq's max_by(.id): the highest id, the LAST listed one among equal ids. It is the highest id and
// never started_at that makes a run the latest: a freshly queued rerun has no started_at.
func ciLatest(g []ciRun) ciRun {
	l := g[0]
	for _, r := range g[1:] {
		if r.idNum >= l.idNum {
			l = r
		}
	}
	return l
}

// ciNormalize returns the latest run of every (name, app id) group, in group order, and the typed notes for the
// older CANCELLED runs they superseded (kit issue #1864). A cancelled LATEST run is judged, not noted.
func ciNormalize(runs []ciRun) (latest []ciRun, notes []string) {
	for _, g := range ciGroup(runs) {
		l := ciLatest(g)
		latest = append(latest, l)
		for _, r := range g {
			if c, isStr := jqString(r.conclusion); r.status == "completed" && isStr && c == "cancelled" && r.idNum != l.idNum {
				notes = append(notes, "superseded cancelled run of "+r.name+" (check-run id "+jqRaw(r.id)+", superseded by id "+jqRaw(l.id)+")")
			}
		}
	}
	return latest, notes
}

// ciRequired is `$s | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))`.
func ciRequired(s string) []string {
	var out []string
	if s == "" {
		return out
	}
	for _, p := range strings.Split(s, ",") {
		if p = strings.TrimFunc(p, unicode.IsSpace); p != "" {
			out = append(out, p)
		}
	}
	return out
}

// ciAbsent lists the required names no latest run reports, in the required order (duplicates kept).
func ciAbsent(latest []ciRun, req []string) []string {
	var out []string
	for _, r := range req {
		if !ciSeen(latest, r) {
			out = append(out, r)
		}
	}
	return out
}

func ciSeen(latest []ciRun, name string) bool {
	for _, r := range latest {
		if r.name == name {
			return true
		}
	}
	return false
}

// ciVerdict is the jq verdict: "ok" or "ci_failed (a,b)" / "ci_pending (...)" / "ci_missing (...)".
func ciVerdict(latest []ciRun, req []string) string {
	var failed, pending []string
	for _, r := range latest {
		if r.status == "completed" {
			c, isStr := jqString(r.conclusion)
			if !isStr || (c != "success" && c != "skipped" && c != "neutral") {
				failed = append(failed, r.name)
			}
		} else {
			pending = append(pending, r.name)
		}
	}
	switch {
	case len(failed) > 0:
		return "ci_failed (" + strings.Join(uniqueSorted(failed), ",") + ")"
	case len(pending) > 0:
		return "ci_pending (" + strings.Join(uniqueSorted(pending), ",") + ")"
	case len(latest) == 0:
		return "ci_pending (no check runs reported)"
	}
	if missing := ciAbsent(latest, req); len(missing) > 0 {
		return "ci_missing (" + strings.Join(missing, ",") + ")"
	}
	return "ok"
}

// uniqueSorted is jq's `unique`: sorted by codepoint, duplicates removed.
func uniqueSorted(in []string) []string {
	s := append([]string(nil), in...)
	sort.Strings(s)
	out := s[:0]
	for i, v := range s {
		if i == 0 || v != s[i-1] {
			out = append(out, v)
		}
	}
	return out
}
