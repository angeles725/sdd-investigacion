package secretscan

// allCases is every black-box scenario, grouped by what it pins. A new case goes in the group of its subject:
// cases_hc (the seven rules), cases_adv (the advisory tier), cases_scope (file scope, walking, NUL files, target
// forms), cases_ff (narrowing and --files-from), cases_hist (--committed).
func allCases() []scase {
	var all []scase
	for _, g := range [][]scase{
		hcCases(), advCases(), scopeCases(), narrowCases(), ffCases(),
		histBasicCases(), histEncodingCases(), histMetaCases(), histRefusalCases(), histScopeCases(),
	} {
		all = append(all, g...)
	}
	return all
}
