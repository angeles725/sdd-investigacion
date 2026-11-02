package verify

import (
	"fmt"
	"strings"
)

// The --json envelope of `verify registry` (research-sdd.verify-registry/v1), printed exactly as the script's
// `jq -n` printed it: two-space indent, keys in construction order, strings escaped the way jq escapes them
// (strings through jqString, the jq-compatible encoder shared with the kit-clean hook).

type regItem struct{ Kind, Severity, Target, Message string }

type regCounts struct {
	Targets, TargetsAbsent, TargetsSkipped, Reconciled, CountDrift, RetroDrift, Unresolved, OversizedRows, Attention int
}

// registryEnvelope builds the envelope text (with its trailing newline). allAbsent selects the absent-input
// state and drops the items; otherwise the state is ok with items and no-match without.
func registryEnvelope(allAbsent bool, c regCounts, items []regItem) string {
	state, reason := "ok", "null"
	switch {
	case allAbsent:
		state, reason = "absent-input", jqString("every registered target directory is absent on disk")
		items = nil
	case len(items) == 0:
		state, reason = "no-match", jqString("targets reconciled, no findings")
	}
	var b strings.Builder
	b.WriteString("{\n  \"schema\": \"research-sdd.verify-registry/v1\",\n")
	b.WriteString("  \"state\": " + jqString(state) + ",\n")
	b.WriteString("  \"counts\": {\n")
	rows := []struct {
		k string
		v int
	}{
		{"targets", c.Targets}, {"targets_absent", c.TargetsAbsent}, {"targets_skipped", c.TargetsSkipped},
		{"reconciled", c.Reconciled}, {"count_drift", c.CountDrift}, {"retro_drift", c.RetroDrift},
		{"unresolved", c.Unresolved}, {"oversized_rows", c.OversizedRows}, {"attention", c.Attention},
	}
	for i, r := range rows {
		sep := ","
		if i == len(rows)-1 {
			sep = ""
		}
		fmt.Fprintf(&b, "    \"%s\": %d%s\n", r.k, r.v, sep)
	}
	b.WriteString("  },\n  \"reason\": " + reason + ",\n")
	if len(items) == 0 {
		b.WriteString("  \"items\": []\n}\n")
		return b.String()
	}
	b.WriteString("  \"items\": [\n")
	for i, it := range items {
		b.WriteString("    {\n")
		b.WriteString("      \"kind\": " + jqString(it.Kind) + ",\n")
		b.WriteString("      \"severity\": " + jqString(it.Severity) + ",\n")
		b.WriteString("      \"target\": " + jqString(it.Target) + ",\n")
		b.WriteString("      \"message\": " + jqString(it.Message) + "\n")
		if i == len(items)-1 {
			b.WriteString("    }\n")
		} else {
			b.WriteString("    },\n")
		}
	}
	b.WriteString("  ]\n}\n")
	return b.String()
}
