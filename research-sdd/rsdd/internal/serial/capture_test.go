//go:build linux

package serial

// Guard-to-test table for serial-frame-capture. The port is replaced by a scripted fake with a fake clock, so
// every timing rule is exact; capture_pty_test.go drives the real termios path through a pseudo-terminal.
//
//	bash suite case (serial-frame-capture.test.sh, pre-port)   Go test
//	T1  sweep without --allow-live-probe: exit 3                 TestCapturePlanOnly
//	T2  plan-only sweep document                                 TestCapturePlanOnly
//	T3  capture without --allow-live-probe: exit 3               TestCapturePlanOnly
//	T4  plan-only capture document                               TestCapturePlanOnly
//	T5..T7 missing --port / --baud / --output: non-zero          TestCaptureUsage
//	T8  --allow-live-probe after the subcommand; all bauds fail:
//	    exit 1, status failed                                    TestSweepAllFail
//	T8b guard holds with a port that would open                  TestCapturePlanOnlyOpensNothing
//	T9  capture --log round trip into serial-frame-analyze       TestCaptureLogRoundTrip
//	    idle-gap framing, frame cap, t_rel rounding              TestCaptureFramesGap, TestCaptureFrameCap
//	    sweep scoring: entropy, framed rule, best candidate      TestSweepScoring

import (
	"errors"
	"math"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

type fakeClock struct{ t time.Time }

func (c *fakeClock) now() time.Time { return c.t }

type portStep struct {
	data    []byte
	advance time.Duration
	err     error
}

// scriptedPort answers each Read with the next step (advancing the clock first); once the script is spent every
// Read times out empty, advancing the clock by the timeout it was given.
type scriptedPort struct {
	clk    *fakeClock
	steps  []portStep
	closed bool
	reads  []int // the n of every Read
	tmo    []time.Duration
}

func (p *scriptedPort) Read(n int, timeout time.Duration) ([]byte, error) {
	p.reads = append(p.reads, n)
	p.tmo = append(p.tmo, timeout)
	if len(p.steps) == 0 {
		p.clk.t = p.clk.t.Add(timeout)
		return nil, nil
	}
	s := p.steps[0]
	p.steps = p.steps[1:]
	p.clk.t = p.clk.t.Add(s.advance)
	return s.data, s.err
}

func (p *scriptedPort) Close() error { p.closed = true; return nil }

// withPorts swaps openPort for the duration of a test: open is called with (path, baud).
func withPorts(t *testing.T, open func(path string, baud int64, _ func() time.Time) (serialPort, error)) {
	t.Helper()
	old := openPort
	openPort = open
	t.Cleanup(func() { openPort = old })
}

// capCmd runs the command with the fake clock.
func capCmd(t *testing.T, clk *fakeClock, args ...string) (rc int, stdout, stderr string) {
	t.Helper()
	s, out, errb := testStdio(t.TempDir())
	s.Clock = clk.now
	rc = SerialFrameCapture(args, s)
	return rc, out.String(), errb.String()
}

func newClock() *fakeClock { return &fakeClock{t: time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)} }

func readFile(t *testing.T, p string) string {
	t.Helper()
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatalf("not written: %v", err)
	}
	return string(b)
}

const sweepPlanWant = `{
  "guard": "hardware probe requires --allow-live-probe; no serial I/O issued",
  "mode": "sweep",
  "plan": {
    "baud_rates": [
      2400,
      4800,
      9600,
      19200,
      38400,
      57600,
      115200
    ],
    "note": "passive read-only; no data transmitted to the device",
    "port": "/dev/null",
    "seconds_per_baud": 4.0
  },
  "schema": "serial-frame.v1",
  "status": "plan-only",
  "tool": "serial-frame-capture"
}
`

const capturePlanWant = `{
  "guard": "hardware probe requires --allow-live-probe; no serial I/O issued",
  "mode": "capture",
  "plan": {
    "baud": 19200,
    "gap_ms": 8.0,
    "note": "passive read-only; no data transmitted to the device",
    "port": "/dev/null",
    "seconds": 30.0
  },
  "schema": "serial-frame.v1",
  "status": "plan-only",
  "tool": "serial-frame-capture"
}
`

func TestCapturePlanOnly(t *testing.T) {
	withPorts(t, func(string, int64, func() time.Time) (serialPort, error) {
		t.Fatal("plan-only opened a port")
		return nil, nil
	})
	dir := t.TempDir()
	for _, tc := range []struct {
		name string
		args []string
		want string
	}{
		{"sweep", []string{"sweep", "--port", "/dev/null"}, sweepPlanWant},
		{"capture", []string{"capture", "--port", "/dev/null", "--baud", "19200"}, capturePlanWant},
		{"sweep seconds", []string{"sweep", "--port", "/dev/null", "--seconds", "2.5"}, strings.Replace(sweepPlanWant, "4.0", "2.5", 1)},
		{"capture knobs", []string{"capture", "--port", "/dev/null", "--baud", "19_200", "--seconds", "5", "--gap-ms", "0.25"},
			strings.NewReplacer("30.0", "5.0", "8.0", "0.25").Replace(capturePlanWant)},
		{"huge baud", []string{"capture", "--port", "/dev/null", "--baud", "123456789012345678901234567890"},
			strings.Replace(capturePlanWant, "19200", "123456789012345678901234567890", 1)},
	} {
		out := filepath.Join(dir, strings.ReplaceAll(tc.name, " ", "_")+".json")
		rc, stdout, stderr := capCmd(t, newClock(), append(tc.args, "--output", out)...)
		if rc != 3 || stdout != "" {
			t.Errorf("%s: rc = %d stdout = %q, want exit 3", tc.name, rc, stdout)
		}
		if !strings.HasPrefix(stderr, "DEGRADED: plan-only") || strings.Count(stderr, "\n") != 1 {
			t.Errorf("%s: stderr = %q, want one DEGRADED line", tc.name, stderr)
		}
		if got := readFile(t, out); got != tc.want {
			t.Errorf("%s: plan differs\n got: %s\nwant: %s", tc.name, got, tc.want)
		}
	}
}

func TestCapturePlanOnlyOpensNothing(t *testing.T) {
	opened := false
	withPorts(t, func(string, int64, func() time.Time) (serialPort, error) { opened = true; return nil, errors.New("no") })
	out := filepath.Join(t.TempDir(), "o.json")
	if rc, _, _ := capCmd(t, newClock(), "sweep", "--port", "/dev/ttySTUB0", "--output", out); rc != 3 || opened {
		t.Errorf("rc = %d opened = %v, want exit 3 and no open", rc, opened)
	}
}

func TestCapturePlanOnlyOutputExists(t *testing.T) {
	out := filepath.Join(t.TempDir(), "o.json")
	if err := os.WriteFile(out, []byte("keep"), 0o600); err != nil {
		t.Fatal(err)
	}
	rc, _, stderr := capCmd(t, newClock(), "sweep", "--port", "/dev/null", "--output", out)
	if rc != 2 || stderr != "serial-frame-capture: "+out+": File exists\n" || readFile(t, out) != "keep" {
		t.Errorf("rc = %d stderr = %q", rc, stderr)
	}
}

func TestCaptureUsage(t *testing.T) {
	out := filepath.Join(t.TempDir(), "o.json")
	for name, args := range map[string][]string{
		"no command":      {},
		"unknown command": {"probe"},
		"sweep no port":   {"sweep", "--output", out},
		"sweep no output": {"sweep", "--port", "/dev/null"},
		"capture no baud": {"capture", "--port", "/dev/null", "--output", out},
		"capture no port": {"capture", "--baud", "9600", "--output", out},
		"baud not int":    {"capture", "--port", "/dev/null", "--baud", "fast", "--output", out},
		"baud float":      {"capture", "--port", "/dev/null", "--baud", "9600.5", "--output", out},
		"seconds not num": {"sweep", "--port", "/dev/null", "--seconds", "soon", "--output", out},
		"seconds inf":     {"sweep", "--port", "/dev/null", "--seconds", "inf", "--output", out},
		"gap nan":         {"capture", "--port", "/dev/null", "--baud", "9600", "--gap-ms", "nan", "--output", out},
		"log on sweep":    {"sweep", "--port", "/dev/null", "--log", "x", "--output", out},
		"gap on sweep":    {"sweep", "--port", "/dev/null", "--gap-ms", "1", "--output", out},
		"flag with value": {"sweep", "--port", "/dev/null", "--allow-live-probe=yes", "--output", out},
		"flag before cmd": {"--allow-live-probe", "sweep", "--port", "/dev/null", "--output", out},
	} {
		rc, stdout, stderr := capCmd(t, newClock(), args...)
		if rc != 2 || stdout != "" || !strings.Contains(stderr, "error: ") {
			t.Errorf("%s: rc = %d stdout = %q stderr = %q, want exit 2 and an error line", name, rc, stdout, stderr)
		}
	}
	if _, err := os.Stat(out); err == nil {
		t.Error("a document was written after a usage error")
	}
	rc, stdout, _ := capCmd(t, newClock(), "capture", "-h")
	if rc != 0 || !strings.Contains(stdout, "--gap-ms MS") || !strings.Contains(stdout, "[--log TXT]") {
		t.Errorf("help: rc = %d stdout = %q", rc, stdout)
	}
	// a negative number is a value, not an option
	if rc, _, stderr := capCmd(t, newClock(), "capture", "--port", "/dev/null", "--baud", "-5", "--output", out); rc != 3 {
		t.Errorf("negative baud in plan-only: rc = %d stderr = %q, want the plan (exit 3)", rc, stderr)
	}
}

func TestSweepAllFail(t *testing.T) {
	var opened []int64
	withPorts(t, func(path string, baud int64, _ func() time.Time) (serialPort, error) {
		opened = append(opened, baud)
		return nil, errors.New("stub: cannot open " + path)
	})
	out := filepath.Join(t.TempDir(), "o.json")
	rc, _, stderr := capCmd(t, newClock(), "sweep", "--port", "/dev/ttySTUB0", "--allow-live-probe", "--output", out)
	if rc != 1 || stderr != "" {
		t.Errorf("rc = %d stderr = %q, want exit 1 and a quiet stderr", rc, stderr)
	}
	if len(opened) != 7 || opened[0] != 2400 || opened[6] != 115200 {
		t.Errorf("bauds tried = %v", opened)
	}
	doc := evidence(t, out)
	if doc["status"] != "failed" || doc["mode"] != "sweep" || doc["tool"] != "serial-frame-capture" {
		t.Errorf("doc = %v", doc)
	}
	res := obj(doc["results"])
	if res["best_candidate"] != nil || len(arr(res["baud_rates"])) != 7 {
		t.Errorf("results = %v", res)
	}
	first := obj(arr(res["baud_rates"])[0])
	if first["error"] != "stub: cannot open /dev/ttySTUB0" || first["likely_framed"] != false || first["baud"] != float64(2400) {
		t.Errorf("first baud = %v", first)
	}
	if sum := obj(doc["summary"]); sum["baud_count"] != float64(7) || sum["likely_framed_count"] != float64(0) {
		t.Errorf("summary = %v", sum)
	}
}

// sweepPorts opens a scripted port per baud from byBaud (other bauds read nothing).
func sweepPorts(t *testing.T, clk *fakeClock, byBaud map[int64][]portStep) (opened *[]*scriptedPort) {
	t.Helper()
	var ports []*scriptedPort
	withPorts(t, func(_ string, baud int64, _ func() time.Time) (serialPort, error) {
		p := &scriptedPort{clk: clk, steps: byBaud[baud]}
		ports = append(ports, p)
		return p, nil
	})
	return &ports
}

func counting(n int) []byte { // n distinct values then repeats: entropy rises with n
	b := make([]byte, n)
	for i := range b {
		b[i] = byte(i)
	}
	return b
}

func TestSweepScoring(t *testing.T) {
	clk := newClock()
	flat := make([]byte, 100) // one value: entropy 0
	for i := range flat {
		flat[i] = 0x55
	}
	random := counting(256) // 8.0 bits: never framed
	ports := sweepPorts(t, clk, map[int64][]portStep{
		4800:   {{data: flat[:40]}},              // exactly 40 bytes: not framed (needs more than 40)
		9600:   {{data: flat[:41]}},              // 41 bytes: framed
		19200:  {{data: random}},                 // high entropy: not framed
		38400:  {{data: flat}, {data: flat}},     // framed, 200 bytes
		57600:  {{err: errors.New("read boom")}}, // read error: recorded, sweep goes on
		115200: {{data: []byte{0xaa, 0xbb}}},     // 2 bytes: data but not framed
	})
	out := filepath.Join(t.TempDir(), "o.json")
	rc, _, stderr := capCmd(t, clk, "sweep", "--port", "/dev/ttyUSB0", "--seconds", "1", "--allow-live-probe", "--output", out)
	if rc != 0 || stderr != "" {
		t.Fatalf("rc = %d stderr = %q", rc, stderr)
	}
	doc := evidence(t, out)
	res := obj(doc["results"])
	if res["best_candidate"] != float64(38400) {
		t.Errorf("best_candidate = %v, want the highest framed baud 38400", res["best_candidate"])
	}
	bauds := arr(res["baud_rates"])
	byB := map[float64]map[string]any{}
	for _, b := range bauds {
		byB[obj(b)["baud"].(float64)] = obj(b)
	}
	framed := func(b float64) any { return byB[b]["likely_framed"] }
	if framed(2400) != false || framed(4800) != false || framed(9600) != true || framed(19200) != false ||
		framed(38400) != true || framed(57600) != false || framed(115200) != false {
		t.Errorf("framed flags wrong: %v", bauds)
	}
	if byB[2400]["byte_count"] != float64(0) || byB[2400]["entropy"] != 0.0 || byB[2400]["sample_hex"] != "" || byB[2400]["unique_byte_values"] != float64(0) {
		t.Errorf("empty baud = %v", byB[2400])
	}
	if e := byB[19200]["entropy"]; e != 8.0 || byB[19200]["unique_byte_values"] != float64(256) || byB[19200]["byte_count"] != float64(256) {
		t.Errorf("random baud = %v", byB[19200])
	}
	if got := byB[19200]["sample_hex"]; got != "000102030405060708090a0b0c0d0e0f1011121314151617" {
		t.Errorf("sample_hex = %v, want the first 24 bytes", got)
	}
	if byB[57600]["error"] != "read boom" || byB[57600]["byte_count"] != nil {
		t.Errorf("read-error baud = %v", byB[57600])
	}
	if sum := obj(doc["summary"]); sum["baud_count"] != float64(7) || sum["likely_framed_count"] != float64(2) {
		t.Errorf("summary = %v", sum)
	}
	for i, p := range *ports {
		if !p.closed {
			t.Errorf("port %d not closed", i)
		}
	}
	if p := (*ports)[0]; p.reads[0] != 4096 || p.tmo[0] != 200*time.Millisecond {
		t.Errorf("sweep read parameters = %v %v, want 4096 bytes / 200ms", p.reads, p.tmo)
	}
	if doc["status"] != "complete" {
		t.Errorf("status = %v", doc["status"])
	}
}

func TestSweepEntropyRounded(t *testing.T) {
	clk := newClock()
	// 3 values with counts 1,2,3 in 6 bytes: entropy 1.459147917...
	data := []byte{1, 2, 2, 3, 3, 3}
	sweepPorts(t, clk, map[int64][]portStep{9600: {{data: data}}})
	out := filepath.Join(t.TempDir(), "o.json")
	capCmd(t, clk, "sweep", "--port", "/dev/x", "--seconds", "1", "--allow-live-probe", "--output", out)
	for _, b := range arr(obj(evidence(t, out)["results"])["baud_rates"]) {
		if obj(b)["baud"] == float64(9600) && obj(b)["entropy"] != 1.4591 {
			t.Errorf("entropy = %v, want 1.4591", obj(b)["entropy"])
		}
	}
}

func TestSweepReadCapAndWindow(t *testing.T) {
	clk := newClock()
	big := make([]byte, 40000)
	ports := sweepPorts(t, clk, map[int64][]portStep{
		2400: {{data: big}, {data: big}, {data: big}, {data: big}},         // the cap is checked between reads: 2 reads reach 65536+
		4800: {{data: []byte{1}, advance: time.Second}, {data: []byte{2}}}, // the window closes after the first read
	})
	out := filepath.Join(t.TempDir(), "o.json")
	capCmd(t, clk, "sweep", "--port", "/dev/x", "--seconds", "1", "--allow-live-probe", "--output", out)
	res := arr(obj(evidence(t, out)["results"])["baud_rates"])
	if n := obj(res[0])["byte_count"]; n != float64(80000) {
		t.Errorf("byte_count at the cap = %v, want 80000 (two 40000-byte reads)", n)
	}
	if n := obj(res[1])["byte_count"]; n != float64(1) {
		t.Errorf("byte_count after the window = %v, want 1", n)
	}
	_ = ports
}

func TestSweepOpenErrorPerBaud(t *testing.T) {
	clk := newClock()
	withPorts(t, func(_ string, baud int64, _ func() time.Time) (serialPort, error) {
		if baud == 9600 {
			return &scriptedPort{clk: clk, steps: []portStep{{data: make([]byte, 50)}}}, nil
		}
		return nil, errors.New("busy")
	})
	out := filepath.Join(t.TempDir(), "o.json")
	rc, _, _ := capCmd(t, clk, "sweep", "--port", "/dev/x", "--seconds", "1", "--allow-live-probe", "--output", out)
	doc := evidence(t, out)
	if rc != 0 || doc["status"] != "complete" || obj(doc["results"])["best_candidate"] != float64(9600) {
		t.Errorf("rc = %d doc = %v, want complete with the one working baud", rc, doc)
	}
}

func TestSweepOutputExists(t *testing.T) {
	clk := newClock()
	sweepPorts(t, clk, nil)
	out := filepath.Join(t.TempDir(), "o.json")
	_ = os.WriteFile(out, []byte("keep"), 0o600)
	rc, _, stderr := capCmd(t, clk, "sweep", "--port", "/dev/x", "--seconds", "0.1", "--allow-live-probe", "--output", out)
	if rc != 2 || stderr != "serial-frame-capture: "+out+": File exists\n" {
		t.Errorf("rc = %d stderr = %q", rc, stderr)
	}
}

func captureRun(t *testing.T, clk *fakeClock, steps []portStep, extra ...string) (rc int, doc map[string]any, stderr string, p *scriptedPort) {
	t.Helper()
	p = &scriptedPort{clk: clk, steps: steps}
	var openedBaud int64 = -1
	withPorts(t, func(_ string, baud int64, _ func() time.Time) (serialPort, error) { openedBaud = baud; return p, nil })
	out := filepath.Join(t.TempDir(), "o.json")
	args := append([]string{"capture", "--port", "/dev/ttyUSB0", "--baud", "19200", "--allow-live-probe", "--output", out}, extra...)
	rc, _, stderr = capCmd(t, clk, args...)
	if openedBaud != 19200 {
		t.Errorf("opened at baud %d, want 19200", openedBaud)
	}
	if _, err := os.Stat(out); err == nil {
		doc = evidence(t, out)
	}
	return rc, doc, stderr, p
}

func TestCaptureFramesGap(t *testing.T) {
	clk := newClock()
	ms := time.Millisecond
	rc, doc, stderr, p := captureRun(t, clk, []portStep{
		{data: []byte{0x81, 0x00}, advance: 10 * ms}, // t=10ms
		{data: []byte{0x17}, advance: 5 * ms},        // 5ms later: same frame
		{data: []byte{0x82}, advance: 9 * ms},        // 9ms later (> 8ms gap): new frame
		{data: nil, advance: 50 * ms},                // idle read
		{data: []byte{0x83, 0x01}, advance: 8 * ms},  // exactly 8ms after the idle read does not matter: gap is from last byte
	}, "--seconds", "1")
	if rc != 0 || stderr != "" {
		t.Fatalf("rc = %d stderr = %q", rc, stderr)
	}
	frames := arr(doc["frames"])
	if len(frames) != 3 {
		t.Fatalf("frames = %v, want 3", frames)
	}
	want := []struct {
		hex string
		t   float64
	}{{"810017", 0.015}, {"82", 0.024}, {"8301", 0.082}}
	for i, w := range want {
		f := obj(frames[i])
		if f["hex"] != w.hex || f["t_rel_s"] != w.t || f["length"] != float64(len(w.hex)/2) {
			t.Errorf("frame %d = %v, want %+v", i, f, w)
		}
	}
	if doc["status"] != "complete" || doc["truncated"] != false || obj(doc["summary"])["distinct_lengths"] != float64(3) {
		t.Errorf("doc = %v", doc)
	}
	in := obj(doc["input"])
	if in["baud"] != float64(19200) || in["gap_ms"] != 8.0 || in["port"] != "/dev/ttyUSB0" || in["seconds"] != 1.0 {
		t.Errorf("input = %v", in)
	}
	if !p.closed || p.reads[0] != 256 || p.tmo[0] != 20*ms {
		t.Errorf("closed = %v reads = %v tmo = %v, want 256-byte reads with a 20ms timeout", p.closed, p.reads[:1], p.tmo[:1])
	}
}

func TestCaptureGapBoundary(t *testing.T) {
	ms := time.Millisecond
	for gap, wantFrames := range map[string]int{"8": 1, "7.999": 2} { // a gap equal to the threshold does not split
		clk := newClock()
		_, doc, _, _ := captureRun(t, clk, []portStep{{data: []byte{1}, advance: ms}, {data: []byte{2}, advance: 8 * ms}}, "--seconds", "1", "--gap-ms", gap)
		if n := len(arr(doc["frames"])); n != wantFrames {
			t.Errorf("gap %s: %d frames, want %d", gap, n, wantFrames)
		}
	}
	// a custom gap is carried into the document
	clk := newClock()
	_, doc, _, _ := captureRun(t, clk, []portStep{{data: []byte{1}, advance: ms}}, "--seconds", "1", "--gap-ms", "25")
	if obj(doc["input"])["gap_ms"] != 25.0 {
		t.Errorf("input = %v", doc["input"])
	}
}

func TestCaptureWindowEnds(t *testing.T) {
	ms := time.Millisecond
	clk := newClock()
	// the window is 100ms: the read that ends exactly at 100ms is the last one (the loop tests elapsed < seconds)
	_, doc, _, p := captureRun(t, clk, []portStep{{data: []byte{1}, advance: 100 * ms}, {data: []byte{2}, advance: ms}}, "--seconds", "0.1")
	if frames := arr(doc["frames"]); len(frames) != 1 || obj(frames[0])["hex"] != "01" {
		t.Errorf("frames = %v, want only the first byte", frames)
	}
	if len(p.reads) != 1 {
		t.Errorf("reads = %d, want 1", len(p.reads))
	}
}

func TestCaptureNoData(t *testing.T) {
	clk := newClock()
	logPath := filepath.Join(t.TempDir(), "x.log")
	rc, doc, stderr, _ := captureRun(t, clk, nil, "--seconds", "0.1", "--log", logPath)
	if rc != 1 || stderr != "" || doc["status"] != "no-data" {
		t.Errorf("rc = %d status = %v stderr = %q, want exit 1 / no-data", rc, doc["status"], stderr)
	}
	if fr := doc["frames"]; fr == nil || len(arr(fr)) != 0 {
		t.Errorf("frames = %v, want an empty list", fr)
	}
	if sum := obj(doc["summary"]); sum["frame_count"] != float64(0) || sum["distinct_lengths"] != float64(0) || sum["truncated"] != false {
		t.Errorf("summary = %v", sum)
	}
	if _, err := os.Stat(logPath); err == nil {
		t.Error("a text log was created although no frame was captured")
	}
}

func TestCaptureFrameCap(t *testing.T) {
	ms := time.Millisecond
	steps := make([]portStep, 1100)
	for i := range steps {
		steps[i] = portStep{data: []byte{byte(i)}, advance: 10 * ms} // every read is a new frame (10ms > 8ms gap)
	}
	clk := newClock()
	_, doc, _, p := captureRun(t, clk, steps, "--seconds", "1000")
	// the loop stops when 1000 frames are closed; the byte then in progress is the 1001st
	if n := len(arr(doc["frames"])); n != 1001 || obj(doc["summary"])["frame_count"] != float64(1001) {
		t.Errorf("frames = %d, want 1001 (cap 1000 plus the open frame)", n)
	}
	if doc["truncated"] != true || obj(doc["summary"])["truncated"] != true {
		t.Errorf("truncated = %v", doc["truncated"])
	}
	if len(p.reads) != 1001 {
		t.Errorf("reads = %d, want 1001", len(p.reads))
	}
	// 999 closed frames and one open: below the cap, not truncated
	clk = newClock()
	_, doc, _, _ = captureRun(t, clk, steps[:1000], "--seconds", "1000")
	if n := len(arr(doc["frames"])); n != 1000 || doc["truncated"] != true {
		t.Errorf("frames = %d truncated = %v, want 1000 and truncated (reaching the cap counts)", n, doc["truncated"])
	}
	clk = newClock()
	_, doc, _, _ = captureRun(t, clk, steps[:999], "--seconds", "1000")
	if n := len(arr(doc["frames"])); n != 999 || doc["truncated"] != false {
		t.Errorf("frames = %d truncated = %v, want 999 and not truncated", n, doc["truncated"])
	}
}

func TestCaptureReadError(t *testing.T) {
	clk := newClock()
	out := filepath.Join(t.TempDir(), "o.json")
	p := &scriptedPort{clk: clk, steps: []portStep{{data: []byte{1}, advance: time.Millisecond}, {err: errors.New("read failed: boom")}}}
	withPorts(t, func(string, int64, func() time.Time) (serialPort, error) { return p, nil })
	rc, _, stderr := capCmd(t, clk, "capture", "--port", "/dev/ttyUSB0", "--baud", "9600", "--allow-live-probe", "--output", out)
	if rc != 2 || stderr != "serial-frame-capture: /dev/ttyUSB0: read failed: boom\n" || !p.closed {
		t.Errorf("rc = %d stderr = %q closed = %v", rc, stderr, p.closed)
	}
	if _, err := os.Stat(out); err == nil {
		t.Error("a document was written after a read failure")
	}
}

func TestCaptureOpenError(t *testing.T) {
	withPorts(t, func(path string, _ int64, _ func() time.Time) (serialPort, error) {
		return nil, errors.New("[Errno 2] could not open port " + path)
	})
	out := filepath.Join(t.TempDir(), "o.json")
	rc, _, stderr := capCmd(t, newClock(), "capture", "--port", "/dev/ttySTUB0", "--baud", "9600", "--allow-live-probe", "--output", out)
	if rc != 2 || stderr != "serial-frame-capture: /dev/ttySTUB0: [Errno 2] could not open port /dev/ttySTUB0\n" {
		t.Errorf("rc = %d stderr = %q", rc, stderr)
	}
	if _, err := os.Stat(out); err == nil {
		t.Error("a document was written when the port failed to open")
	}
}

func TestCaptureBadBaud(t *testing.T) {
	withPorts(t, func(string, int64, func() time.Time) (serialPort, error) { t.Fatal("opened"); return nil, nil })
	out := filepath.Join(t.TempDir(), "o.json")
	for _, baud := range []string{"-5", "123456789012345678901234567890"} {
		rc, _, stderr := capCmd(t, newClock(), "capture", "--port", "/dev/x", "--baud", baud, "--allow-live-probe", "--output", out)
		if rc != 2 || stderr != "serial-frame-capture: /dev/x: Not a valid baudrate: "+baud+"\n" {
			t.Errorf("baud %s: rc = %d stderr = %q", baud, rc, stderr)
		}
	}
}

func TestCaptureLogRoundTrip(t *testing.T) {
	ms := time.Millisecond
	clk := newClock()
	dir := t.TempDir()
	logPath := filepath.Join(dir, "cap.log")
	rc, _, stderr, _ := captureRun(t, clk, []portStep{
		{data: []byte{0x81, 0x00, 0x17}, advance: 1500 * ms},
		{data: []byte{0xff}, advance: 20 * ms},
	}, "--seconds", "5", "--log", logPath)
	if rc != 0 || stderr != "" {
		t.Fatalf("rc = %d stderr = %q", rc, stderr)
	}
	if got, want := readFile(t, logPath), "1.500000  len=3  81 00 17\n1.520000  len=1  ff\n"; got != want {
		t.Errorf("log = %q, want %q", got, want)
	}
	if st, _ := os.Stat(logPath); st.Mode().Perm()&0o077 != 0 {
		t.Errorf("log mode = %v", st.Mode().Perm())
	}
	ana := filepath.Join(dir, "ana.json")
	if rc, _, stderr := analyze(t, "stats", "--input", logPath, "--output", ana); rc != 0 {
		t.Fatalf("analyze rc = %d stderr = %q", rc, stderr)
	}
	if n := obj(evidence(t, ana)["summary"])["frame_count"]; n != float64(2) {
		t.Errorf("analyze frame_count = %v, want 2", n)
	}
}

func TestCaptureLogExists(t *testing.T) {
	clk := newClock()
	logPath := filepath.Join(t.TempDir(), "cap.log")
	_ = os.WriteFile(logPath, []byte("keep"), 0o600)
	rc, doc, stderr, _ := captureRun(t, clk, []portStep{{data: []byte{1}, advance: time.Millisecond}}, "--seconds", "1", "--log", logPath)
	if rc != 2 || stderr != "serial-frame-capture: "+logPath+": File exists\n" || doc != nil {
		t.Errorf("rc = %d stderr = %q doc = %v, want exit 2 before the document is written", rc, stderr, doc)
	}
	if readFile(t, logPath) != "keep" {
		t.Error("existing log modified")
	}
}

func TestCaptureOutputExists(t *testing.T) {
	clk := newClock()
	out := filepath.Join(t.TempDir(), "o.json")
	_ = os.WriteFile(out, []byte("keep"), 0o600)
	withPorts(t, func(string, int64, func() time.Time) (serialPort, error) {
		return &scriptedPort{clk: clk, steps: []portStep{{data: []byte{1}, advance: time.Millisecond}}}, nil
	})
	rc, _, stderr := capCmd(t, clk, "capture", "--port", "/dev/x", "--baud", "9600", "--seconds", "1", "--allow-live-probe", "--output", out)
	if rc != 2 || stderr != "serial-frame-capture: "+out+": File exists\n" {
		t.Errorf("rc = %d stderr = %q", rc, stderr)
	}
}

func TestEntropyAndTextLog(t *testing.T) {
	if e := entropy(nil); e != 0 || math.Signbit(e) {
		t.Errorf("entropy(nil) = %v, want +0", e)
	}
	if e := entropy([]byte{7, 7, 7}); e != 0 || !math.Signbit(e) {
		t.Errorf("entropy of constant data = %v, want -0 as the Python expression gives", e)
	}
	if e := entropy([]byte{0, 1}); e != 1 {
		t.Errorf("entropy = %v, want 1 bit", e)
	}
	if got := string(textLog([]rawFrame{{0.1234567, []byte{0x0a, 0xff}}})); got != "0.123457  len=2  0a ff\n" {
		t.Errorf("textLog = %q", got)
	}
	if got := string(textLog(nil)); got != "" {
		t.Errorf("textLog(nil) = %q", got)
	}
}

var _ = cli.ExitOK
