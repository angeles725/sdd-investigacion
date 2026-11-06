package consumers

// scriptRoots are the directories the live script list is read from (issue #2758, S2).
var scriptRoots = []string{"research-sdd/toolbelt/", "research-sdd/templates/", "research-sdd/install/"}

// scriptExts are the extensions the plan counts as scripts.
var scriptExts = map[string]bool{".sh": true, ".py": true, ".mjs": true, ".cjs": true, ".js": true, ".ts": true, ".java": true}

// exclusion is one thing removed from the script list. A file is counted under one exclusion only, so the counts
// add up to the number of files removed (claimOrder says which one wins).
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

// claimOrder is the order in which exclusions claim a file, as indexes into exclusions: a file in a `fixtures`
// directory is counted there even when its name contains `.test.`, the order of the reading of L6 in
// odd/tasks/maint-consumers.md.
var claimOrder = []int{1, 0, 2}
