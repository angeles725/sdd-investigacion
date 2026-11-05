package sweep

// allScripts are the eight canonical session-start scripts `sweep all` runs, in the order it runs them. Every
// entry is a toolbelt shim of a Go command, so the aggregator execs them instead of importing the sweep and verify
// domains together. The list must equal the set of SessionStart hooks the kit registers in .claude/settings.json
// (one hook maps to the script of the same name); tests/sweep-all.test.sh reads this file for that parity check, so
// keep it one quoted name per line and name no other script in double quotes here.
var allScripts = []string{
	"sweep-retros.sh",
	"sweep-audits.sh",
	"sweep-breakthroughs.sh",
	"verify-registry.sh",
	"verify-kit-clean.sh",
	"sweep-tools.sh",
	"verify-tool-catalog.sh",
	"verify-skill-drift.sh",
}
