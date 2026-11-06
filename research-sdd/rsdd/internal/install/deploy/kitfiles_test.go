//go:build unix && !nodiff

package deploy

// kitFiles is the synthetic kit the frozen installer deploys from: small, fixed texts so every golden is stable
// when the real kit's skill or agent text moves. Only toolbelt/render-profile.sh is borrowed from the real kit
// (the renderer is the dependency the installer shells out to; it is not part of this slice's oracle).
var kitFiles = map[string]string{
	"skills/research-sdd/SKILL.md":              "# research-sdd skill\n<!-- slot:intro -->claude intro<!-- /slot -->\nkit source v1\n",
	"PROMPT-LOOP.md":                            "# loop\n<!-- slot:intro -->claude loop<!-- /slot -->\n",
	"METHODOLOGY.md":                            "# methodology\n",
	"TARGETS.md":                                "# targets\n",
	"profiles/general.slots.md":                 "## slot:intro\n\ngeneral intro\n",
	"install/pi/research-sdd-hooks.ts":          "// pi extension v1\nexport default function () {}\n",
	"agents/claude/research-sdd-risk.md":        "---\nname: research-sdd-risk\ntools: Read, Grep, Glob\n---\nrisk lens\n",
	"agents/claude/research-sdd-readability.md": "---\nname: research-sdd-readability\ntools: Read, Grep, Glob\n---\nreadability lens\n",
	"agents/pi/research-sdd-mechanical.md":      "---\nname: research-sdd-mechanical\ntools: [read, grep, find]\n---\nmechanical tier\n",
	"agents/pi/research-sdd-structural.md":      "---\nname: research-sdd-structural\ntools: [read, grep, find]\n---\nstructural tier\n",
	"agents/pi/research-sdd-reasoning.md":       "---\nname: research-sdd-reasoning\ntools: [read, grep, find]\n---\nreasoning tier\n",
}

// realKitFiles are borrowed unmodified from the real kit (relative to research-sdd).
var realKitFiles = []string{"toolbelt/render-profile.sh"}

// systemTools are linked into the world's PATH from the host; nothing else is reachable. optionalTools may be
// absent (the installer degrades without them); every other missing tool is a skip or, under RSDD_PARITY_REQUIRE=1,
// a failure.
var systemTools = []string{"bash", "sh", "env", "cat", "cmp", "sed", "awk", "grep", "cut", "tr", "head", "tail",
	"mktemp", "rm", "dirname", "basename", "readlink", "realpath", "stat", "date", "git", "timeout", "sleep", "sort",
	"find", "cp", "mv", "chmod", "mkdir", "rmdir", "ln", "tee", "sha256sum", "python3", "touch", "ls", "wc", "uniq",
	"true", "false", "paste", "jq"}

var optionalTools = map[string]bool{"jq": true}

// fakeTools record their call and fail: a scenario that reaches the network or a package manager is a failure.
var fakeTools = []string{"curl", "wget", "apt-get", "apt", "sudo", "npm", "pipx", "pip", "node"}
