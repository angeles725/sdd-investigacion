package firmware

import (
	"encoding/json"
	"math/big"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/fsx"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/jsonout"
)

const schema = "firmware-static.v1"

// runRecord is what one analyzer run left: when it ran and how it ended.
type runRecord struct {
	startedAt, endedAt string
	durationMs         int64
	exitCode, signal   *int
}

func nullable(p *int) any {
	if p == nil {
		return nil
	}
	return *p
}

// manifestRun is the run block of the analysis manifest.
func (r runRecord) manifestRun() map[string]any {
	return map[string]any{"started_at": r.startedAt, "ended_at": r.endedAt, "duration_ms": r.durationMs,
		"exit_code": nullable(r.exitCode), "signal": nullable(r.signal)}
}

// reportRun is the run block of the report: how it ended, without the clock.
func (r runRecord) reportRun() map[string]any {
	return map[string]any{"exit_code": nullable(r.exitCode), "signal": nullable(r.signal)}
}

// isoUTC is datetime.isoformat() of a UTC time with the offset written as Z: microseconds only when non-zero.
func isoUTC(t time.Time) string {
	t = t.UTC()
	if t.Nanosecond()/1000 == 0 {
		return t.Format("2006-01-02T15:04:05") + "Z"
	}
	return t.Format("2006-01-02T15:04:05.000000") + "Z"
}

// jsonNumber is an integer of any size as the encoder writes it.
func jsonNumber(n *big.Int) json.Number { return json.Number(n.String()) }

// recordObject is a path/size/digest record as the report writes it.
func recordObject(r fsx.Record) map[string]any {
	return map[string]any{"path": r.Path, "size": r.Size, "sha256": r.SHA256}
}

func findingObjects(list []finding) []any {
	out := make([]any, len(list))
	for i, f := range list {
		out[i] = f.object()
	}
	return out
}

func strings2any(list []string) []any {
	out := make([]any, len(list))
	for i, s := range list {
		out[i] = s
	}
	return out
}

// canonical is the compact sorted ASCII JSON every evidence file is written in.
func canonical(v any) ([]byte, error) { return jsonout.Canonical(v) }

// limitationsFor is the report's caveat list: the heuristic nature of the findings, what the trust of the
// analyzer does and does not cover, and the sandbox's own limits.
func limitationsFor(trust string, override bool) []string {
	var scope string
	switch trust {
	case trustRoot:
		scope = "The distro Binwalk package, Python dependencies, and magic database are read-only but are not artifact-bound by this report."
	case trustOverride:
		scope = "The analyzer is a test override; its installation is not covered by any trust check."
	default:
		scope = "The analyzer is not root-owned (explicit RSDD_BINWALK): its installation, Python dependencies, and magic database are writable by the invoking user and are not artifact-bound by this report."
	}
	list := []string{
		"Binwalk signatures and entropy edges are heuristic, not proof of extractability or execution behavior.",
		scope,
		"Bubblewrap on WSL2 is defense in depth, not a hostile-parser security boundary; use a disposable VM for hostile firmware.",
	}
	if override {
		list = append(list, "RSDD_BINWALK_TEST_ONLY selected a test analyzer; this is not official Binwalk evidence.")
	}
	return list
}
