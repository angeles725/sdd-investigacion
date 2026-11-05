package scoreloop

// builtinVerdict classifies one record with the default filters (defaultOperatorJQ and defaultCompactJQ, in Go).
func builtinVerdict(obj map[string]any) (verdict, error) {
	op, err := isOperatorTurn(obj)
	if err != nil {
		return verdict{}, err
	}
	return verdict{operator: op, compact: isCompaction(obj)}, nil
}

// isOperatorTurn is `.type=="user" and ((.origin.kind // "")=="human")`: the structural stamp Claude Code puts on
// a genuine human turn. Tool results, task notifications, peer relays, /loop re-fires and hook feedback are all
// `type:"user"` with another or no origin kind. A user turn whose .origin is neither null nor an object is a shape
// error (jq cannot index it); the test short-circuits, so other record types never reach it.
func isOperatorTurn(obj map[string]any) (bool, error) {
	if obj["type"] != "user" {
		return false, nil
	}
	var kind any
	switch origin := obj["origin"].(type) {
	case nil:
	case map[string]any:
		kind = origin["kind"]
	default:
		return false, errShape
	}
	return kind == "human", nil
}

// isCompaction is `(.type=="system" and (.subtype // "")=="compact_boundary") or (.isCompactSummary // false)`:
// structural markers only, any truthy .isCompactSummary counts.
func isCompaction(obj map[string]any) bool {
	if obj["type"] == "system" && obj["subtype"] == "compact_boundary" {
		return true
	}
	return truthy(obj["isCompactSummary"])
}
