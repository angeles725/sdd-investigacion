//go:build linux

package serial

import (
	"bytes"
	"path/filepath"
	"testing"
	"time"
)

// The per-baud read cap is checked between reads: a baud that reaches exactly 64 KiB stops, one byte short reads on.
func TestSweepReadCapExact(t *testing.T) {
	for _, tc := range []struct {
		chunk, want int
	}{{16384, 65536}, {16383, 81915}} {
		clk := newClock()
		steps := make([]portStep, 6)
		for i := range steps {
			steps[i] = portStep{data: make([]byte, tc.chunk)}
		}
		sweepPorts(t, clk, map[int64][]portStep{2400: steps})
		out := filepath.Join(t.TempDir(), "o.json")
		capCmd(t, clk, "sweep", "--port", "/dev/x", "--seconds", "1", "--allow-live-probe", "--output", out)
		res := arr(obj(evidence(t, out)["results"])["baud_rates"])
		if n := obj(res[0])["byte_count"]; n != float64(tc.want) {
			t.Errorf("chunk %d: byte_count = %v, want %d", tc.chunk, n, tc.want)
		}
	}
}

// A baud whose entropy is exactly 6.5 bits is not framed (the rule is "below 6.5"): 128 values once and 16 values
// eight times each make 256 bytes of exactly that entropy.
func TestSweepEntropyBoundary(t *testing.T) {
	var data []byte
	for v := 0; v < 128; v++ {
		data = append(data, byte(v))
	}
	for v := 200; v < 216; v++ {
		data = append(data, bytes.Repeat([]byte{byte(v)}, 8)...)
	}
	if e := entropy(data); e != 6.5 {
		t.Fatalf("fixture entropy = %v, want exactly 6.5", e)
	}
	clk := newClock()
	sweepPorts(t, clk, map[int64][]portStep{9600: {{data: data}}})
	out := filepath.Join(t.TempDir(), "o.json")
	capCmd(t, clk, "sweep", "--port", "/dev/x", "--seconds", "1", "--allow-live-probe", "--output", out)
	for _, b := range arr(obj(evidence(t, out)["results"])["baud_rates"]) {
		if obj(b)["baud"] == float64(9600) && (obj(b)["likely_framed"] != false || obj(b)["entropy"] != 6.5) {
			t.Errorf("baud 9600 = %v, want entropy 6.5 and not framed", obj(b))
		}
	}
}

// Ports that open but never deliver a byte: the sweep failed (exit 1), it did not find "nothing framed".
func TestSweepZeroBytes(t *testing.T) {
	clk := newClock()
	sweepPorts(t, clk, nil)
	out := filepath.Join(t.TempDir(), "o.json")
	rc, _, stderr := capCmd(t, clk, "sweep", "--port", "/dev/x", "--seconds", "0.3", "--allow-live-probe", "--output", out)
	doc := evidence(t, out)
	if rc != 1 || stderr != "" || doc["status"] != "failed" {
		t.Errorf("rc = %d status = %v stderr = %q, want exit 1 / failed", rc, doc["status"], stderr)
	}
	first := obj(arr(obj(doc["results"])["baud_rates"])[0])
	if first["byte_count"] != float64(0) || first["likely_framed"] != false || first["error"] != nil {
		t.Errorf("first baud = %v, want an opened baud with 0 bytes", first)
	}
}

// Baud 0 is a rate pyserial accepts (B0); only a negative rate is refused.
func TestCaptureBaudZero(t *testing.T) {
	clk := newClock()
	var got int64 = -1
	withPorts(t, func(_ string, baud int64, _ func() time.Time) (serialPort, error) {
		got = baud
		return &scriptedPort{clk: clk}, nil
	})
	out := filepath.Join(t.TempDir(), "o.json")
	rc, _, stderr := capCmd(t, clk, "capture", "--port", "/dev/x", "--baud", "0", "--seconds", "0.1", "--allow-live-probe", "--output", out)
	if got != 0 || rc != 1 || stderr != "" {
		t.Errorf("opened at %d, rc = %d stderr = %q, want baud 0 and the no-data exit 1", got, rc, stderr)
	}
}
