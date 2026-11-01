package serial

import (
	"bytes"
	"encoding/json"
	"fmt"
	"math"
	"math/big"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// Port of toolbelt/serial-frame_capture.py (kit issue #2437, epic #2270): passive serial frame capture
// (serial-frame.v1). `sweep` tries the common baud rates and scores each, `capture` records frames at one baud
// rate using an idle-gap boundary and can write the canonical text log serial-frame-analyze reads.
//
// Exit codes (unchanged): 3 plan-only (no --allow-live-probe: an offline plan is written and no port is
// opened), 0 complete, 1 no data (sweep: every baud failed or read nothing; capture: no frames), 2 operational
// error (port cannot be opened or read, output exists, ...). The port is read-only: nothing is transmitted.
//
// Differences from the Python script:
//   - The port is driven through termios directly (Linux); pyserial is not needed. Open and configure errors
//     keep pyserial's message texts. Other systems report the port as unavailable (exit 2).
//   - Plan-only exit 3 also prints a "DEGRADED:" line on stderr, as the rsdd exit-3 contract requires.
//   - --seconds and --gap-ms refuse inf and nan (they would put non-JSON tokens in the plan); a negative baud
//     is a typed exit 2 where the Python script died with a traceback.
//   - Usage errors print the Go port's argparse-style message; the exit code (2) is the same.

const (
	captureTool         = "serial-frame-capture"
	maxCaptureFrames    = 1_000    // frame cap for live capture
	maxReadPerBaud      = 64 << 10 // per-baud read cap (bytes) during a sweep
	sweepReadTimeout    = 200 * time.Millisecond
	captureReadTimeout  = 20 * time.Millisecond
	sweepReadSize       = 4096
	captureReadSize     = 256
	framedMaxEntropy    = 6.5
	framedMinBytes      = 40
	sampleBytes         = 24
	defaultSweepSeconds = 4.0
	defaultCapSeconds   = 30.0
	defaultGapMS        = 8.0
	planGuard           = "hardware probe requires --allow-live-probe; no serial I/O issued"
	planNote            = "passive read-only; no data transmitted to the device"
)

var commonBauds = []int{2400, 4800, 9600, 19200, 38400, 57600, 115200}

// serialPort is the read side of an open serial port. Read returns as pyserial's read does: it collects up to
// n bytes and gives up when timeout has elapsed in total, returning what it has (possibly nothing).
type serialPort interface {
	Read(n int, timeout time.Duration) ([]byte, error)
	Close() error
}

// openPort opens path at baud for reading. It is a variable so tests can supply a scripted port.
var openPort = openSerialPort

// rawFrame is one captured frame with its time since the start of the capture.
type rawFrame struct {
	t    float64
	data []byte
}

// entropy is the Shannon entropy of data in bits per byte.
func entropy(data []byte) float64 {
	if len(data) == 0 {
		return 0
	}
	var counts [256]int
	for _, b := range data {
		counts[b]++
	}
	n := float64(len(data))
	h := 0.0
	for _, c := range counts {
		if c != 0 {
			p := float64(c) / n
			h -= p * math.Log2(p)
		}
	}
	return h
}

func planDoc(mode string, plan map[string]any) map[string]any {
	return map[string]any{"guard": planGuard, "mode": mode, "plan": plan, "schema": frameSchema, "status": "plan-only", "tool": captureTool}
}

// captureFrames reads port for seconds and splits the byte stream into frames at idle gaps longer than gap.
// The frame list is capped; the time of a frame is the time of its last byte.
func captureFrames(p serialPort, now func() time.Time, seconds, gap float64) ([]rawFrame, error) {
	var frames []rawFrame
	var cur []byte
	var lastRx time.Time
	t0 := now()
	for now().Sub(t0).Seconds() < seconds {
		if len(frames) >= maxCaptureFrames {
			break
		}
		chunk, err := p.Read(captureReadSize, captureReadTimeout)
		if err != nil {
			return nil, err
		}
		at := now()
		if len(chunk) > 0 {
			if !lastRx.IsZero() && at.Sub(lastRx).Seconds() > gap && len(cur) > 0 {
				frames = append(frames, rawFrame{lastRx.Sub(t0).Seconds(), cur})
				cur = nil
			}
			cur = append(cur, chunk...)
			lastRx = at
		}
	}
	if len(cur) > 0 {
		frames = append(frames, rawFrame{lastRx.Sub(t0).Seconds(), cur})
	}
	return frames, nil
}

// sweepBaud listens on port for seconds (at most maxReadPerBaud bytes, checked between reads).
func sweepBaud(p serialPort, now func() time.Time, seconds float64) ([]byte, error) {
	var raw []byte
	t0 := now()
	for now().Sub(t0).Seconds() < seconds {
		if len(raw) >= maxReadPerBaud {
			break
		}
		chunk, err := p.Read(sweepReadSize, sweepReadTimeout)
		if err != nil {
			return nil, err
		}
		raw = append(raw, chunk...)
	}
	return raw, nil
}

func baudResult(baud int, raw []byte) map[string]any {
	h := entropy(raw)
	unique := map[byte]bool{}
	for _, b := range raw {
		unique[b] = true
	}
	return map[string]any{
		"baud": baud, "byte_count": len(raw), "entropy": roundDigits(h, 4),
		"likely_framed":      len(raw) > 0 && h < framedMaxEntropy && len(raw) > framedMinBytes,
		"sample_hex":         fmt.Sprintf("%x", raw[:min(len(raw), sampleBytes)]),
		"unique_byte_values": len(unique),
	}
}

// liveSweep tries every common baud rate in turn. A baud that cannot be opened or read is recorded, not fatal.
func liveSweep(port string, now func() time.Time, seconds float64) map[string]any {
	results := make([]any, 0, len(commonBauds))
	anyData, framed := false, 0
	best := any(nil)
	for _, baud := range commonBauds {
		entry := sweepOne(port, baud, now, seconds)
		results = append(results, entry)
		if entry["byte_count"] != nil && entry["byte_count"].(int) > 0 {
			anyData = true
		}
		if entry["likely_framed"] == true {
			framed++
			best = baud // the highest framed baud wins
		}
	}
	status := "failed"
	if anyData {
		status = "complete"
	}
	return map[string]any{
		"mode":    "sweep",
		"results": map[string]any{"baud_rates": results, "best_candidate": best},
		"schema":  frameSchema, "status": status,
		"summary": map[string]any{"baud_count": len(results), "likely_framed_count": framed},
		"tool":    captureTool,
	}
}

func sweepOne(port string, baud int, now func() time.Time, seconds float64) map[string]any {
	fail := func(err error) map[string]any {
		return map[string]any{"baud": baud, "error": err.Error(), "likely_framed": false}
	}
	p, err := openPort(port, int64(baud))
	if err != nil {
		return fail(err)
	}
	raw, err := sweepBaud(p, now, seconds)
	_ = p.Close()
	if err != nil {
		return fail(err)
	}
	return baudResult(baud, raw)
}

// captureDoc builds the capture evidence for frames.
func captureDoc(port string, baud *big.Int, seconds, gapMS float64, frames []rawFrame) map[string]any {
	out := make([]any, len(frames))
	lengths := map[int]bool{}
	for i, f := range frames {
		out[i] = map[string]any{"hex": fmt.Sprintf("%x", f.data), "length": len(f.data), "t_rel_s": roundDigits(f.t, 6)}
		lengths[len(f.data)] = true
	}
	truncated := len(frames) >= maxCaptureFrames
	status := "no-data"
	if len(frames) > 0 {
		status = "complete"
	}
	return map[string]any{
		"frames": out,
		"input":  map[string]any{"baud": jsonInt(baud), "gap_ms": gapMS, "port": port, "seconds": seconds},
		"mode":   "capture", "schema": frameSchema, "status": status,
		"summary": map[string]any{"distinct_lengths": len(lengths), "frame_count": len(frames), "truncated": truncated},
		"tool":    captureTool, "truncated": truncated,
	}
}

// textLog renders frames as the canonical `t_rel  len=N  HH HH ...` log serial-frame-analyze reads.
func textLog(frames []rawFrame) []byte {
	var b bytes.Buffer
	for _, f := range frames {
		hexs := make([]string, len(f.data))
		for i, c := range f.data {
			hexs[i] = fmt.Sprintf("%02x", c)
		}
		fmt.Fprintf(&b, "%s  len=%d  %s\n", strconv.FormatFloat(f.t, 'f', 6, 64), len(f.data), strings.Join(hexs, " "))
	}
	return b.Bytes()
}

// jsonInt keeps an arbitrary-precision integer exact in the encoded document.
func jsonInt(v *big.Int) any {
	if v.IsInt64() {
		return v.Int64()
	}
	return json.Number(v.String())
}

// SerialFrameCapture is the `rsdd serial serial-frame-capture` command.
func SerialFrameCapture(args []string, s cli.Stdio) int {
	port := func(name string, kind argKind, required bool, metavar string) argSpec {
		return argSpec{name: name, kind: kind, required: required, metavar: metavar}
	}
	cl := &cmdLine{prog: captureTool, about: "Passive serial frame capture (serial-frame.v1). READ-ONLY: no data transmitted to the target device. Requires --allow-live-probe (after the subcommand) to perform real serial I/O.", subs: []subSpec{
		{name: "sweep", args: []argSpec{
			port("port", argString, true, "DEV"), port("seconds", argFloat, false, "N"),
			port("output", argString, true, "JSON"), port("allow-live-probe", argFlag, false, ""),
		}},
		{name: "capture", args: []argSpec{
			port("port", argString, true, "DEV"), port("baud", argInt, true, "N"), port("seconds", argFloat, false, "N"),
			port("gap-ms", argFloat, false, "MS"), port("output", argString, true, "JSON"),
			port("log", argString, false, "TXT"), port("allow-live-probe", argFlag, false, ""),
		}},
	}}
	if code, done := cl.parse(args, s); done {
		return code
	}
	c := &capture{s: s, cl: cl, port: cl.strs["port"], out: cl.strs["output"]}
	if cl.sub == "sweep" {
		return c.sweep(floatOr(cl.floats, "seconds", defaultSweepSeconds))
	}
	return c.capture(floatOr(cl.floats, "seconds", defaultCapSeconds), floatOr(cl.floats, "gap-ms", defaultGapMS))
}

func floatOr(m map[string]float64, name string, def float64) float64 {
	if v, ok := m[name]; ok {
		return v
	}
	return def
}

type capture struct {
	s    cli.Stdio
	cl   *cmdLine
	port string
	out  string
}

func (c *capture) errf(path string, err error) int {
	fmt.Fprintf(c.s.Err, "%s: %s: %s\n", captureTool, path, ioReason(err, false))
	return cli.ExitUsage
}

// planOnly writes the offline plan and reports exit 3.
func (c *capture) planOnly(doc map[string]any) int {
	if err := writeJSON(c.out, doc); err != nil {
		return c.errf(c.out, err)
	}
	fmt.Fprintln(c.s.Err, "DEGRADED: plan-only: --allow-live-probe not supplied; no serial I/O issued")
	return cli.ExitDegraded
}

func (c *capture) sweep(seconds float64) int {
	if !c.cl.flags["allow-live-probe"] {
		return c.planOnly(planDoc("sweep", map[string]any{
			"baud_rates": slices.Clone(commonBauds), "note": planNote, "port": c.port, "seconds_per_baud": seconds,
		}))
	}
	doc := liveSweep(c.port, c.s.Clock, seconds)
	if err := writeJSON(c.out, doc); err != nil {
		return c.errf(c.out, err)
	}
	if doc["status"] == "complete" {
		return cli.ExitOK
	}
	return cli.ExitOperational
}

func (c *capture) capture(seconds, gapMS float64) int {
	baud := c.cl.ints["baud"]
	if !c.cl.flags["allow-live-probe"] {
		return c.planOnly(planDoc("capture", map[string]any{
			"baud": jsonInt(baud), "gap_ms": gapMS, "note": planNote, "port": c.port, "seconds": seconds,
		}))
	}
	if !baud.IsInt64() || baud.Sign() < 0 {
		fmt.Fprintf(c.s.Err, "%s: %s: Not a valid baudrate: %s\n", captureTool, c.port, baud)
		return cli.ExitUsage
	}
	p, err := openPort(c.port, baud.Int64())
	if err != nil {
		fmt.Fprintf(c.s.Err, "%s: %s: %v\n", captureTool, c.port, err)
		return cli.ExitUsage
	}
	frames, err := captureFrames(p, c.s.Clock, seconds, gapMS/1000.0)
	_ = p.Close()
	if err != nil {
		fmt.Fprintf(c.s.Err, "%s: %s: %v\n", captureTool, c.port, err)
		return cli.ExitUsage
	}
	if log := c.cl.strs["log"]; log != "" && len(frames) > 0 {
		if err := writeNew(log, textLog(frames)); err != nil {
			return c.errf(log, err)
		}
	}
	if err := writeJSON(c.out, captureDoc(c.port, baud, seconds, gapMS, frames)); err != nil {
		return c.errf(c.out, err)
	}
	if len(frames) > 0 {
		return cli.ExitOK
	}
	return cli.ExitOperational
}
