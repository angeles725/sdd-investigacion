package goimpact

// exemptBlind declares the bash files whose unresolvable rsdd calls are not Go blind spots, each
// with its reason. It is data, kept apart from the scanner: a file belongs here only when its unresolved forms
// are generic templates it writes into a fixture and runs against stub binaries, while the real commands it
// reaches are named explicitly elsewhere in the same file (and so resolve). A stale entry (the file no longer
// has an unresolved form, or no longer exists) fails TestBashEnumeratorMatchesRegistryOnTheRealTree, like a stale waiver.
//
// The kit's traced-run check (static reach must contain traced reach, issue #2613 task T2) is what proves an
// exemption hides no real edge.
var exemptBlind = map[string]string{
	"research-sdd/toolbelt/tests/rsdd-exec.test.sh": "writes generic `rsdd_exec \"$@\"` / `rsdd_exec_hook \"$@\"` shim templates into a fixture kit and runs them against stub binaries; the commands it really reaches are named explicitly in the same file",
}

// Exemptions returns a copy of the declared exemptions (path -> reason), for the staleness test.
func Exemptions() map[string]string {
	out := make(map[string]string, len(exemptBlind))
	for k, v := range exemptBlind {
		out[k] = v
	}
	return out
}
