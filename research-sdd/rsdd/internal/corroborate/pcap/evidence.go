package pcap

import (
	"math/big"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

const (
	evidenceSchema = "pcap-evidence.v1"
	evidenceProg   = "corroborate-pcap"
)

var evidenceLimitations = []string{
	"capinfos and tshark operate read-only on the capture file; no live capture, injection, or replay occurs.",
	"Protocol dissection is heuristic; encrypted or tunnelled traffic may not be identified correctly.",
	"Bubblewrap on WSL2 is defense-in-depth, not a hostile-parser security boundary; use a disposable VM for hostile captures.",
}

var evidenceCmdline = cmdline{
	prog: "corroborate_pcap.py",
	usage: `usage: corroborate_pcap.py [-h] --input INPUT --output OUTPUT
                           [--timeout-seconds TIMEOUT_SECONDS]
                           [--max-bytes MAX_BYTES]
`,
	help: `usage: corroborate_pcap.py [-h] --input INPUT --output OUTPUT
                           [--timeout-seconds TIMEOUT_SECONDS]
                           [--max-bytes MAX_BYTES]

options:
  -h, --help            show this help message and exit
  --input INPUT
  --output OUTPUT
  --timeout-seconds TIMEOUT_SECONDS
  --max-bytes MAX_BYTES
`,
	options: []option{
		{"--input", "input", kindPath}, {"--output", "output", kindPath},
		{"--timeout-seconds", "timeout_seconds", kindInt}, {"--max-bytes", "max_bytes", kindInt},
		{"--manifest-cli", "manifest_cli", kindPath},
	},
	required: []string{"input", "output", "manifest_cli"},
}

// withDefaults fills the caps a caller left out.
func (p parsedArgs) withDefaults() parsedArgs {
	if p.num["timeout_seconds"] == nil {
		p.num["timeout_seconds"] = big.NewInt(30)
	}
	if p.num["max_bytes"] == nil {
		p.num["max_bytes"] = big.NewInt(1_000_000)
	}
	return p
}

// Run is `rsdd corroborate pcap`: capinfos and the tshark protocol hierarchy of a capture, run offline in a
// network-denied Bubblewrap sandbox and published as pcap-evidence.v1. Exit 0 complete, 1 an analyzer failed
// (evidence published with status "failed"), 2 refused (nothing published).
func Run(args []string, s cli.Stdio) int {
	a, code, done := evidenceCmdline.parse(args, s.Out, s.Err)
	if done {
		return code
	}
	c := &session{tool: evidenceProg, s: s, manifestCLI: a.str["manifest_cli"]}
	defer c.cleanup()
	return c.evidence(a.withDefaults())
}

func (c *session) evidence(a parsedArgs) int {
	if err := c.open(a, sessionOptions{needCapinfos: true}); err != nil {
		return c.fail(err)
	}
	capinfosCmd := append(append([]string(nil), c.run.prefix...), c.capinfosExe, "input/capture.pcap")
	capRun, err := c.run.run(c.capinfosExe, "input/capture.pcap")
	if err != nil {
		return c.fail(err)
	}
	summary := map[string]any{}
	if len(capRun.errors) == 0 {
		parsed, err := parseCapinfos(capRun.stdout)
		if err != nil {
			return c.fail(err)
		}
		summary = parsed.toMap()
	}

	tsharkCmd := append(append([]string(nil), c.run.prefix...), c.tsharkPath, "-q", "-z", "io,phs", "-r", "input/capture.pcap")
	phsRun, err := c.run.run(c.tsharkPath, "-q", "-z", "io,phs", "-r", "input/capture.pcap")
	if err != nil {
		return c.fail(err)
	}
	protocols := []any{}
	if len(phsRun.errors) == 0 {
		protocols = protocolMaps(parseHierarchy(phsRun.stdout))
	}

	all := append(append([]string{}, capRun.errors...), phsRun.errors...)
	err = c.emit(emission{
		schema: evidenceSchema,
		domain: map[string]any{
			"capinfos":           map[string]any{"argv": capinfosCmd, "summary": summary, "tool": recordMap(c.capinfos)},
			"protocol_hierarchy": map[string]any{"argv": tsharkCmd, "protocols": protocols, "tool": recordMap(c.tshark)},
		},
		limitations: evidenceLimitations, errors: all, argv: tsharkCmd, run: phsRun.record, timeout: 60,
	})
	if err != nil {
		return c.fail(err)
	}
	c.published()
	if len(all) > 0 {
		return cli.ExitOperational
	}
	return cli.ExitOK
}
