package consumers

// Class names, as printed. The first two are never read: the Go module belongs to a later version of this
// command, and fixtures are frozen copies of other things.
const (
	classGo           = "Go module"
	classFixtures     = "fixtures"
	classScripts      = "scripts"
	classBashTests    = "bash tests"
	classDocs         = "doctrine and registries"
	classCI           = "CI workflows"
	classTemplates    = "templates"
	classHarness      = "harness wiring"
	classLists        = "lists"
	classUnclassified = "unclassified"
)

// classRule is one line of the class table. The table is read top to bottom and the first rule that holds
// decides (issue #2758, S17); a path no rule holds for is unclassified.
type classRule struct {
	class string
	kind  ruleKind
	value string
	under string // for byExtension: the path must also start with this prefix ("" for anywhere)
}

type ruleKind int

const (
	byPrefix ruleKind = iota
	byDir
	byNameContains
	byLiveScript
	byExtension
)

var classRules = []classRule{
	{class: classGo, kind: byPrefix, value: "research-sdd/rsdd/"},
	{class: classFixtures, kind: byDir, value: "fixtures"},
	{class: classCI, kind: byPrefix, value: ".github/"},
	{class: classHarness, kind: byPrefix, value: ".claude/"},
	{class: classHarness, kind: byPrefix, value: "research-sdd/install/pi/"},
	{class: classTemplates, kind: byPrefix, value: "research-sdd/templates/"},
	{class: classBashTests, kind: byNameContains, value: ".test."},
	{class: classScripts, kind: byLiveScript},
	{class: classDocs, kind: byExtension, value: ".md"},
	{class: classLists, kind: byExtension, value: ".txt", under: "research-sdd/toolbelt/"},
}

// reportClasses are the rows of the report, in order. The Go module and fixtures have no row: they are not read
// and the report counts them in its "not read" line.
var reportClasses = []string{classScripts, classBashTests, classDocs, classCI, classTemplates, classHarness, classLists, classUnclassified}
