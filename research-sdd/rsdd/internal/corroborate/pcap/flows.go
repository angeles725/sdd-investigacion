package pcap

import (
	"encoding/json"
	"fmt"
	"math/big"
	"sort"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

const (
	flowsSchema = "pcap-flows.v1"
	flowsProg   = "pcap-flows"
	// defaultMaxStreams caps the per-stream follow passes unless --max-streams says otherwise.
	defaultMaxStreams = 128
)

var flowsLimitations = []string{
	"tshark operates read-only; no live capture, injection, or replay occurs.",
	"TCP stream indices are encounter-order (0..N-1 where N = unique tcp.stream count).",
	"Per-stream evidence stores SHA-256 of reassembled payload — raw bytes never written.",
	"Bubblewrap on WSL2 is defense-in-depth; use a disposable VM for hostile captures.",
}

var flowsCmdline = cmdline{
	prog: "pcap_flows.py",
	usage: `usage: pcap_flows.py [-h] --input INPUT --output OUTPUT
                     [--timeout-seconds TIMEOUT_SECONDS]
                     [--max-bytes MAX_BYTES] [--max-streams MAX_STREAMS]
`,
	help: `usage: pcap_flows.py [-h] --input INPUT --output OUTPUT
                     [--timeout-seconds TIMEOUT_SECONDS]
                     [--max-bytes MAX_BYTES] [--max-streams MAX_STREAMS]

options:
  -h, --help            show this help message and exit
  --input INPUT
  --output OUTPUT
  --timeout-seconds TIMEOUT_SECONDS
  --max-bytes MAX_BYTES
  --max-streams MAX_STREAMS
                        maximum TCP stream follow passes (default 128); excess
                        streams are counted but not analyzed
`,
	options: []option{
		{"--input", "input", kindPath}, {"--output", "output", kindPath},
		{"--timeout-seconds", "timeout_seconds", kindInt}, {"--max-bytes", "max_bytes", kindInt},
		{"--max-streams", "max_streams", kindInt}, {"--manifest-cli", "manifest_cli", kindPath},
	},
	required: []string{"input", "output", "manifest_cli"},
}

// streamIDs is sorted(set(int(x) for x in text.split() if x.strip().isdigit())): the distinct tcp.stream
// values tshark printed (blank for non-TCP packets), as numbers.
func streamIDs(text string) []*big.Int {
	seen := map[string]*big.Int{}
	for _, tok := range pyFields(text) {
		if asciiDigits(tok) {
			n, _ := new(big.Int).SetString(tok, 10)
			seen[n.String()] = n
		}
	}
	ids := make([]*big.Int, 0, len(seen))
	for _, n := range seen {
		ids = append(ids, n)
	}
	sort.Slice(ids, func(i, j int) bool { return ids[i].Cmp(ids[j]) < 0 })
	return ids
}

// firstN is ids[:n] with Python's slice rules: a negative n drops that many from the end.
func firstN(ids []*big.Int, n *big.Int) []*big.Int {
	switch {
	case n.Sign() < 0:
		keep := new(big.Int).Add(big.NewInt(int64(len(ids))), n)
		if keep.Sign() <= 0 {
			return nil
		}
		return ids[:keep.Int64()]
	case !n.IsInt64() || n.Int64() >= int64(len(ids)):
		return ids
	}
	return ids[:n.Int64()]
}

// RunFlows is `rsdd corroborate pcap-flows`: TCP and UDP conversations plus the SHA-256 of every reassembled
// TCP stream (at most --max-streams of them), run offline in a network-denied Bubblewrap sandbox and
// published as pcap-flows.v1. Exit codes as Run.
func RunFlows(args []string, s cli.Stdio) int {
	a, code, done := flowsCmdline.parse(args, s.Out, s.Err)
	if done {
		return code
	}
	c := &session{tool: flowsProg, s: s, manifestCLI: a.str["manifest_cli"]}
	defer c.cleanup()
	a = a.withDefaults()
	if a.num["max_streams"] == nil {
		a.num["max_streams"] = big.NewInt(defaultMaxStreams)
	}
	return c.flows(a)
}

func (c *session) flows(a parsedArgs) int {
	if err := c.open(a, sessionOptions{}); err != nil {
		return c.fail(err)
	}
	const capture = "input/capture.pcap"
	// Step 1: the distinct TCP stream indices.
	fieldsRun, err := c.run.run(c.tsharkPath, "-T", "fields", "-e", "tcp.stream", "-r", capture)
	if err != nil {
		return c.fail(err)
	}
	ids := streamIDs(fieldsRun.stdout)

	// Step 2: one follow pass per stream, keeping only the SHA-256 of the reassembled payload.
	total := len(ids)
	maxStreams := a.num["max_streams"]
	truncated := big.NewInt(int64(total)).Cmp(maxStreams) > 0
	if truncated {
		fmt.Fprintf(c.s.Err, "%s: warning: %d TCP streams found; analyzing only the first %s (--max-streams=%s)\n",
			flowsProg, total, maxStreams, maxStreams)
		ids = firstN(ids, maxStreams)
	}
	follows := make([]streamFollow, 0, len(ids))
	var followErrors []string
	for _, id := range ids {
		r, err := c.run.run(c.tsharkPath, "-q", "-z", "follow,tcp,raw,"+id.String(), "-r", capture)
		if err != nil {
			return c.fail(err)
		}
		follows = append(follows, parseFollow(r.stdout, json.Number(id.String())))
		followErrors = append(followErrors, r.errors...)
	}

	// Step 3: conversation statistics run last, so engine/stdout.txt holds this output when the manifest is built.
	convCmd := append(append([]string(nil), c.run.prefix...), c.tsharkPath, "-q", "-z", "conv,tcp", "-z", "conv,udp", "-r", capture)
	convRun, err := c.run.run(c.tsharkPath, "-q", "-z", "conv,tcp", "-z", "conv,udp", "-r", capture)
	if err != nil {
		return c.fail(err)
	}

	all := append(append(append([]string{}, fieldsRun.errors...), followErrors...), convRun.errors...)
	err = c.emit(emission{
		schema: flowsSchema,
		domain: map[string]any{
			"conversations": map[string]any{
				"argv": convCmd, "tcp": conversationMaps(parseConversations(convRun.stdout, "tcp")),
				"udp": conversationMaps(parseConversations(convRun.stdout, "udp")), "tool": recordMap(c.tshark),
			},
			"stream_count_total": total, "streams_analyzed": len(follows), "streams_truncated": truncated,
			"tcp_stream_follows": followMaps(follows),
		},
		limitations: flowsLimitations, errors: all, argv: convCmd, run: convRun.record, timeout: 30,
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
