package consumers

// scriptRoots are the directories the live script list is read from (issue #2758, S2).
var scriptRoots = []string{"research-sdd/toolbelt/", "research-sdd/templates/", "research-sdd/install/"}

// scriptExts are the extensions the plan counts as scripts.
var scriptExts = map[string]bool{".sh": true, ".py": true, ".mjs": true, ".cjs": true, ".js": true, ".ts": true, ".java": true}

// exclusion is one thing removed from the script list. A file is counted under the first exclusion it meets, so
// the counts add up to the number of files removed.
type exclusion struct {
	label string
	kind  predKind
	value string
}

var exclusions = []exclusion{
	{"`.test.` in the name", nameContains, ".test."},
	{"`fixtures` directory", dirSegment, "fixtures"},
	{"`node_modules`", dirSegment, "node_modules"},
}
