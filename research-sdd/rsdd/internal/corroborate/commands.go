// Package corroborate owns the rsdd commands for corroboration tools (one subpackage per tool).
// See docs/adding-a-command.md.
package corroborate

import (
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/corroborate/fidelity"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/corroborate/pcap"
)

// Commands is this domain's contribution to the command table. A unit adds
// its entries here and never edits internal/commands.
var Commands = []cli.Command{
	{Name: "java-fidelity", Group: "corroborate", Summary: "measure what the Java decompilation pipeline preserves (javac, decompile, recompile, javap)", Run: fidelity.Run},
	{Name: "pcap", Group: "corroborate", Summary: "capinfos summary and tshark protocol hierarchy of a capture (pcap-evidence.v1)", Run: pcap.Run},
	{Name: "pcap-flows", Group: "corroborate", Summary: "TCP/UDP conversations and per-stream payload digests (pcap-flows.v1)", Run: pcap.RunFlows},
}
