// Package install owns the rsdd commands for install and tool detection: detect-tools (the capability report
// the installer's VERIFY step and the research loop read). detect-tools sits here, not in a new package, because it
// is the read-only half of install-tool.sh: both answer "which RE tools does this host really have".
// See docs/adding-a-command.md.
package install

import "github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"

// Commands is this domain's contribution to the command table. A unit adds
// its entries here and never edits internal/commands.
var Commands = []cli.Command{
	{Name: "detect-tools", Group: "install", Summary: "probe the real availability of the RE/decompile tools and print a capability report (cached; --require gates)", Run: detectToolsRun},
}
