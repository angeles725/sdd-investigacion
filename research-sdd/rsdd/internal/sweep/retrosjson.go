package sweep

import (
	"fmt"
	"io"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/hookenv"
)

// The --json envelope of sweep-retros.sh (research-sdd.sweep-retros/v1, json-envelope.v1.md), written byte for
// byte as the script's `jq -n` printed it: two-space indent, keys in insertion order, a trailing newline.
// Key order is schema, state, counts, reason, items: the script built the object first and added reason and
// items afterwards.

const retrosSchema = "research-sdd.sweep-retros/v1"

// retrosState is the envelope state enum.
func retrosState(items, targets, absent, total int) (state string, reason *string) {
	str := func(s string) *string { return &s }
	switch {
	case items > 0:
		return "ok", nil
	case targets > 0 && absent == targets:
		return "absent-input", str("every target corpus directory is absent")
	case total == 0:
		return "empty-input", str("target corpora found but no retro files under them")
	}
	return "no-match", str("retros found but none pending and no missing retro")
}

func writeRetrosEnvelope(w io.Writer, res sweepResult) {
	var b strings.Builder
	state, reason := retrosState(len(res.rows)+len(res.missing), res.targets, res.absent, res.total)
	b.WriteString("{\n  \"schema\": " + hookenv.JQString(retrosSchema) + ",\n  \"state\": " + hookenv.JQString(state) + ",\n")
	fmt.Fprintf(&b, "  \"counts\": {\n    \"targets\": %d,\n    \"targets_absent\": %d,\n    \"targets_skipped\": %d,\n    \"retros\": %d,\n    \"pending\": %d,\n    \"missing_retro\": %d\n  },\n",
		res.targets, res.absent, res.skipped, res.total, res.pendingCnt, len(res.missing))
	if reason == nil {
		b.WriteString("  \"reason\": null,\n")
	} else {
		b.WriteString("  \"reason\": " + hookenv.JQString(*reason) + ",\n")
	}
	if len(res.rows)+len(res.missing) == 0 {
		b.WriteString("  \"items\": []\n}\n")
		io.WriteString(w, b.String())
		return
	}
	b.WriteString("  \"items\": [\n")
	var items []string
	for _, r := range res.rows {
		deltas := "null"
		if allDigits(r.deltas) {
			deltas = r.deltas
		}
		warning := "null"
		if r.deltaWarns != "" {
			warning = hookenv.JQString(r.deltaWarns)
		}
		items = append(items, "    {\n      \"kind\": \"pending-retro\",\n      \"file\": "+hookenv.JQString(r.file)+",\n      \"target\": "+hookenv.JQString(r.target)+
			",\n      \"deltas\": "+deltas+",\n      \"deltas_state\": "+hookenv.JQString(r.dk)+",\n      \"status\": "+hookenv.JQString(r.status)+
			",\n      \"age_days\": "+r.age+",\n      \"age_state\": \"counted\",\n      \"escalated\": "+fmt.Sprint(r.tag != "")+
			",\n      \"warning\": "+warning+"\n    }")
	}
	for _, m := range res.missing {
		items = append(items, "    {\n      \"kind\": \"missing-retro\",\n      \"target\": "+hookenv.JQString(m)+"\n    }")
	}
	b.WriteString(strings.Join(items, ",\n") + "\n  ]\n}\n")
	io.WriteString(w, b.String())
}
