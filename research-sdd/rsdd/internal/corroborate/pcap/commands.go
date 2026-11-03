// Package pcap owns the rsdd commands that turn a pcap/pcapng capture into offline evidence:
// `rsdd corroborate pcap` (capinfos summary and tshark protocol hierarchy, pcap-evidence.v1) and
// `rsdd corroborate pcap-flows` (TCP/UDP conversations and per-stream payload digests, pcap-flows.v1).
// See docs/adding-a-command.md.
//
// Both commands share one front half (session.go: the privilege guard, capture and output checks, the staged
// copy, executable lookup, the Bubblewrap prefix, the tshark version probe), one analyzer runner (tshark.go),
// one evidence model and set of parsers (model.go, parse.go) and one publication tail (emit.go). Each command
// file holds only what is its own: which analyzers run and what the evidence records.
//
// They replace corroborate_pcap.py and pcap_flows.py with the same output, exit codes and messages, apart from
// the documented differences below (all stricter, or crash-free where the scripts crashed):
//   - A stage directory that already exists is never deleted by the run that failed to create it; the scripts'
//     cleanup removed it.
//   - A FIFO or device as the capture is refused instead of blocking on open or being read as a file.
//   - Numbers use ASCII digits only; the scripts also took other Unicode decimal digits, and crashed on the
//     digit-like characters int() refuses.
//   - A capinfos duration of nan or inf is refused (no JSON form) where the scripts wrote NaN or Infinity.
//   - The analyzers' output reaches the runner through pipes, not files, so a run stopped at the output cap
//     ends on SIGTERM where the scripts' file-fed run ended on SIGXFSZ.
//   - Output that is not valid UTF-8 is decoded with one U+FFFD per bad sequence, and a tshark -v banner that
//     is not valid UTF-8 is decoded the same way instead of crashing the script.
package pcap

import "github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/adapter"

// currentCreds is the process ids the privilege guard reads; a test replaces it.
var currentCreds = adapter.CurrentCreds
