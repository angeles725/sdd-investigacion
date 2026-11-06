package ciworkflow

// guards lists, per workflow file (relative to the repository root), the path-filter entries each event must keep.
//
// rsdd-go.yml: Go tests read LIVE kit files as their differential oracle, so the Go workflow must run on any kit
// change (kit issue #2734). A Go test that reads a repository file OUTSIDE research-sdd/ adds that path here and
// to both lists of the workflow in the same change; the workflow file itself is the first such read (this guard).
var guards = []struct {
	workflow string
	events   []string
	paths    []string
}{
	{
		workflow: ".github/workflows/rsdd-go.yml",
		events:   []string{"push", "pull_request"},
		// .claude/settings.json: core/hookenv's consumer-bound test reads the registered SessionStart hooks (#2631).
		paths: []string{"research-sdd/**", ".github/workflows/rsdd-go.yml", ".claude/settings.json"},
	},
}
