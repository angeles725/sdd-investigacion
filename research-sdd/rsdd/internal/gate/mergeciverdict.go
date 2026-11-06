package gate

import "strings"

// ciVerdict is the CI verdict: "ok" or "ci_failed (a,b)" / "ci_pending (...)" / "ci_skipped (...)" / "ci_missing (...)",
// in that precedence order.
//
// Declared divergence from the frozen merge-gate.sh (phase 8 slice 8.0): the jq counted the conclusions `skipped`
// and `neutral` as green for every check, so a REQUIRED check GitHub reported as skipped (a job whose `if:` was
// false, an upstream failure) merged as `ok`. Here a name in req must conclude `success`; `skipped` and `neutral`
// stay acceptable only for checks outside req. A name the path-filter exemption removed from req is no longer
// required. The refusal has its own verdict, never ci_failed, so the operator reads "skipped" and not "red".
func ciVerdict(latest []ciRun, req []string) string {
	var failed, pending, skipped []string
	for _, r := range latest {
		if r.status != "completed" {
			pending = append(pending, r.name)
			continue
		}
		c, isStr := jqString(r.conclusion)
		if !isStr || (c != "success" && c != "skipped" && c != "neutral") {
			failed = append(failed, r.name)
			continue
		}
		if c != "success" && ciRequires(req, r.name) {
			skipped = append(skipped, r.name)
		}
	}
	if len(failed) > 0 {
		return "ci_failed (" + strings.Join(uniqueSorted(failed), ",") + ")"
	}
	if len(pending) > 0 {
		return "ci_pending (" + strings.Join(uniqueSorted(pending), ",") + ")"
	}
	if len(latest) == 0 {
		return "ci_pending (no check runs reported)"
	}
	if len(skipped) > 0 {
		return "ci_skipped (" + strings.Join(uniqueSorted(skipped), ",") + ")"
	}
	if missing := ciAbsent(latest, req); len(missing) > 0 {
		return "ci_missing (" + strings.Join(missing, ",") + ")"
	}
	return "ok"
}

func ciRequires(req []string, name string) bool {
	for _, r := range req {
		if r == name {
			return true
		}
	}
	return false
}
