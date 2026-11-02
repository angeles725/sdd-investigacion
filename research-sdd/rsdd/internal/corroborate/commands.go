// Package corroborate owns the rsdd commands for corroboration tools (one subpackage per tool).
// See docs/adding-a-command.md.
package corroborate

import (
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/corroborate/capa"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/corroborate/classfile"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/corroborate/decompile"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/corroborate/fidelity"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/corroborate/floss"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/corroborate/ghidra"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/corroborate/java"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/corroborate/kaitai"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/corroborate/native"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/corroborate/pcap"
)

// Commands is this domain's contribution to the command table. A unit adds
// its entries here and never edits internal/commands.
var Commands = []cli.Command{
	{Name: "classfile", Group: "corroborate", Summary: "One CLASSFILE line (major, LocalVariableTable, re-sugar risk) read from a .class or .jar", Run: classfile.Run},
	{Name: "decompile", Group: "corroborate", Summary: "Decompile a Java .jar or .class to source: Vineflower, falling back to CFR or Procyon per unit (typed OK / DEGRADED / PARTIAL)", Run: decompile.Run},
	{Name: "java", Group: "corroborate", Summary: "bounded multi-engine Java corroboration (java-corroboration.v1)", Run: java.Run},
	{Name: "java-fidelity", Group: "corroborate", Summary: "measure what the Java decompilation pipeline preserves (javac, decompile, recompile, javap)", Run: fidelity.Run},
	{Name: "floss", Group: "corroborate", Summary: "bounded obfuscated-string inventory of a PE/ELF binary (floss in a network-denied sandbox)", Run: floss.Run},
	{Name: "capa", Group: "corroborate", Summary: "offline capa capability inventory of a PE/ELF/.NET binary (bubblewrap)", Run: capa.Run},
	{Name: "kaitai", Group: "corroborate", Summary: "parse a binary with a Kaitai Struct .ksy in network-denied sandboxes (kaitai-evidence.v1)", Run: kaitai.Run},
	{Name: "pcap", Group: "corroborate", Summary: "capinfos summary and tshark protocol hierarchy of a capture (pcap-evidence.v1)", Run: pcap.Run},
	{Name: "pcap-flows", Group: "corroborate", Summary: "TCP/UDP conversations and per-stream payload digests (pcap-flows.v1)", Run: pcap.RunFlows},
	{Name: "native", Group: "corroborate", Summary: "bounded radare2 evidence for one native binary (native-static.v1)", Run: native.Run},
	{Name: "ghidra", Group: "corroborate", Summary: "sandboxed Ghidra curated evidence for one native binary (ghidra-corroboration.v1)", Run: ghidra.Run},
}
