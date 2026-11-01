//go:build linux && !nodiff

package serial

// The differential half of the serial-frame tests: the frozen legacy scripts (testdata/legacy) are the oracle,
// run through testdata/oracle_driver.py. `make teeth` (-tags nodiff) leaves them out; the unit tests carry the
// mutation kills. The analyzer is compared on every fixture, on error paths and on seeded random logs; the
// capture command is compared on plan-only documents and on live paths against a scripted port with a fake
// clock, which the driver reproduces with a stub `serial` module and a fake time.monotonic.

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"math/rand/v2"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const (
	legacyAnalyze = "testdata/legacy/serial_frame_analyze.py"
	legacyCapture = "testdata/legacy/serial_frame_capture.py"
	oracleDriver  = "testdata/oracle_driver.py"
)

type oracleCase struct {
	Tool     string                       `json:"tool"`
	Argv     []string                     `json:"argv"`
	Outputs  map[string]string            `json:"outputs"`
	Script   map[string][]json.RawMessage `json:"script,omitempty"`
	FailOpen []int                        `json:"fail_open,omitempty"`
}

type oracleResult struct {
	RC        int                `json:"rc"`
	Stderr    string             `json:"stderr"`
	Traceback bool               `json:"traceback"`
	Outputs   map[string]*string `json:"outputs"`
}

func runOracle(t *testing.T, cases []oracleCase) []oracleResult {
	t.Helper()
	py, err := exec.LookPath("python3")
	if err != nil {
		t.Fatalf("python3 is required for the parity tests and was not found: %v", err)
	}
	in, _ := json.Marshal(cases)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()
	cmd := exec.CommandContext(ctx, py, "-I", abs(t, oracleDriver), abs(t, legacyAnalyze), abs(t, legacyCapture))
	var out, errb bytes.Buffer
	cmd.Stdin, cmd.Stdout, cmd.Stderr = bytes.NewReader(in), &out, &errb
	if err := cmd.Run(); err != nil {
		t.Fatalf("oracle driver failed: %v\n%s", err, errb.String())
	}
	var rs []oracleResult
	if err := json.Unmarshal(out.Bytes(), &rs); err != nil || len(rs) != len(cases) {
		t.Fatalf("oracle output: %v (%d results for %d cases)\n%s", err, len(rs), len(cases), out.String())
	}
	return rs
}

func readOutputs(paths map[string]string) map[string]*string {
	got := map[string]*string{}
	for name, p := range paths {
		if b, err := os.ReadFile(p); err == nil {
			e := base64.StdEncoding.EncodeToString(b)
			got[name] = &e
		} else {
			got[name] = nil
		}
	}
	return got
}

// requireSame fails when the Go result differs from the oracle. usageOnly relaxes the stderr comparison for
// argparse usage errors, whose wording is the Go port's own.
func requireSame(t *testing.T, label string, rc int, stderr string, outs map[string]*string, py oracleResult, pyDir, goDir string, planOnly bool) {
	t.Helper()
	if py.Traceback {
		t.Errorf("%s: the legacy script crashed (traceback): the case is not a valid parity case", label)
		return
	}
	if rc != py.RC {
		t.Errorf("%s: exit go %d, legacy %d\n go stderr: %q\n py stderr: %q", label, rc, py.RC, stderr, py.Stderr)
	}
	switch want := strings.ReplaceAll(py.Stderr, pyDir, goDir); {
	case strings.HasPrefix(py.Stderr, "usage:"):
		if !strings.Contains(stderr, "error: ") {
			t.Errorf("%s: legacy usage error but go stderr = %q", label, stderr)
		}
	case planOnly: // the exit-3 contract adds one DEGRADED line the script never printed
		if stderr != "DEGRADED: plan-only: --allow-live-probe not supplied; no serial I/O issued\n" || want != "" {
			t.Errorf("%s: stderr go %q, legacy %q", label, stderr, want)
		}
	case stderr != want:
		t.Errorf("%s: stderr go %q, legacy %q", label, stderr, want)
	}
	for name, p := range py.Outputs {
		g := outs[name]
		if (g == nil) != (p == nil) || (g != nil && *g != *p) {
			var gb, pb []byte
			if g != nil {
				gb, _ = base64.StdEncoding.DecodeString(*g)
			}
			if p != nil {
				pb, _ = base64.StdEncoding.DecodeString(*p)
			}
			t.Errorf("%s: output %q differs\n go: %s\n py: %s", label, name, gb, pb)
		}
	}
}

// ---------------------------------------------------------------- serial-frame-analyze

type analyzeCase struct {
	argv  []string // {OUT} is the output path
	label string
}

func TestAnalyzeParityFixtures(t *testing.T) {
	logs, _ := filepath.Glob("testdata/frames/*.log")
	if len(logs) < 20 {
		t.Fatalf("fixtures missing: %v", logs)
	}
	var cases []analyzeCase
	for _, l := range logs {
		l = abs(t, l)
		cases = append(cases,
			analyzeCase{label: "stats " + filepath.Base(l), argv: []string{"stats", "--input", l, "--output", "{OUT}"}},
			analyzeCase{label: "checksum " + filepath.Base(l), argv: []string{"checksum", "--input", l, "--output", "{OUT}"}},
			analyzeCase{label: "diff basic " + filepath.Base(l), argv: []string{"diff", "--input-a", abs(t, "testdata/frames/basic.log"), "--input-b", l, "--output", "{OUT}"}},
			analyzeCase{label: "diff " + filepath.Base(l) + " self", argv: []string{"diff", "--input-a", l, "--input-b", l, "--output", "{OUT}"}},
		)
	}
	runAnalyzeParity(t, cases)
}

func TestAnalyzeParityErrors(t *testing.T) {
	tmp := t.TempDir()
	good := abs(t, "testdata/frames/basic.log")
	link := filepath.Join(tmp, "link.log")
	_ = os.Symlink(good, link)
	exist := filepath.Join(tmp, "exists.json")
	_ = os.WriteFile(exist, []byte("x"), 0o600)
	cases := []analyzeCase{
		{label: "absent", argv: []string{"stats", "--input", filepath.Join(tmp, "none"), "--output", "{OUT}"}},
		{label: "symlink", argv: []string{"stats", "--input", link, "--output", "{OUT}"}},
		{label: "directory", argv: []string{"checksum", "--input", tmp, "--output", "{OUT}"}},
		{label: "diff symlink b", argv: []string{"diff", "--input-a", good, "--input-b", link, "--output", "{OUT}"}},
		{label: "output exists", argv: []string{"stats", "--input", good, "--output", exist}},
		{label: "output exists, failed doc", argv: []string{"stats", "--input", abs(t, "testdata/frames/malformed.log"), "--output", exist}},
		{label: "output dir missing", argv: []string{"stats", "--input", good, "--output", filepath.Join(tmp, "no", "dir", "o")}},
		{label: "no args", argv: nil},
		{label: "bad command", argv: []string{"bogus"}},
		{label: "missing output", argv: []string{"stats", "--input", good}},
		{label: "unknown option", argv: []string{"stats", "--input", good, "--output", "{OUT}", "--x", "1"}},
		{label: "equals form", argv: []string{"stats", "--input=" + good, "--output={OUT}"}},
		{label: "prefix form", argv: []string{"diff", "--input-a", good, "--input-b", good, "--out", "{OUT}"}},
		{label: "ambiguous prefix", argv: []string{"diff", "--input", good, "--output", "{OUT}"}},
	}
	runAnalyzeParity(t, cases)
}

// randomLog builds a log from a mix of valid frames, near-misses and junk, deterministic for a seed.
func randomLog(rng *rand.Rand) []byte {
	var b bytes.Buffer
	seps := []string{" ", "  ", "\t", " ", "　", " \x1f"}
	ends := []string{"\n", "\r\n", "\r", "\x0b", " ", "\x85"}
	digits := []string{"0", "1", "2", "3", "٣", "۴", "５"}
	for i, n := 0, rng.IntN(14); i < n; i++ {
		switch rng.IntN(9) {
		case 0: // comment or blank
			b.WriteString([]string{"# note", "", "   ", "#"}[rng.IntN(4)])
		case 1: // junk
			b.WriteString([]string{"hello world", "len=", "len=3", "len=x 00", "0.0 len=2  zz", "1.0  LEN=2 00 11"}[rng.IntN(6)])
		case 2: // invalid UTF-8 inside a line
			b.Write([]byte{'0', '.', '0', ' ', 0xe2, 0x82, ' ', 0x80, 0xc0, 0xaf, ' ', 'x'})
		default:
			l := 1 + rng.IntN(7)
			declared := fmt.Sprint(l)
			switch rng.IntN(8) {
			case 0:
				declared = fmt.Sprint(l + 1) // mismatch
			case 1:
				declared = digits[rng.IntN(len(digits))]
			case 2:
				declared = "0" + declared
			}
			fmt.Fprintf(&b, "%d.%03d%slen=%s%s", rng.IntN(5), rng.IntN(1000), seps[rng.IntN(len(seps))], declared, seps[rng.IntN(len(seps))])
			for j := 0; j < l; j++ {
				if j > 0 {
					b.WriteString(" ")
				}
				switch rng.IntN(12) {
				case 0:
					b.WriteString("1ff") // out of range
				case 1:
					b.WriteString("00a")
				case 2:
					b.WriteString("zz")
				default:
					fmt.Fprintf(&b, "%02x", []int{0x81, 0x81, 0x82, 0x00, 0xff, rng.IntN(256)}[rng.IntN(6)])
				}
			}
			if rng.IntN(6) == 0 {
				b.WriteString("  ")
			}
		}
		if i < n-1 || rng.IntN(2) == 0 {
			b.WriteString(ends[rng.IntN(len(ends))])
		}
	}
	return b.Bytes()
}

func TestAnalyzeParityRandom(t *testing.T) {
	rng := rand.New(rand.NewPCG(2437, 23))
	dir := t.TempDir()
	var paths []string
	for i := range 120 {
		p := filepath.Join(dir, fmt.Sprintf("r%03d.log", i))
		if err := os.WriteFile(p, randomLog(rng), 0o600); err != nil {
			t.Fatal(err)
		}
		paths = append(paths, p)
	}
	var cases []analyzeCase
	for i, p := range paths {
		cases = append(cases,
			analyzeCase{label: "random stats " + filepath.Base(p), argv: []string{"stats", "--input", p, "--output", "{OUT}"}},
			analyzeCase{label: "random checksum " + filepath.Base(p), argv: []string{"checksum", "--input", p, "--output", "{OUT}"}},
			analyzeCase{label: "random diff " + filepath.Base(p), argv: []string{"diff", "--input-a", p, "--input-b", paths[(i+1)%len(paths)], "--output", "{OUT}"}},
		)
	}
	runAnalyzeParity(t, cases)
}

func runAnalyzeParity(t *testing.T, cases []analyzeCase) {
	t.Helper()
	pyDir, goDir := t.TempDir(), t.TempDir()
	expand := func(c analyzeCase, i int, dir string) ([]string, string) {
		o := filepath.Join(dir, fmt.Sprintf("o%04d.json", i))
		argv := make([]string, len(c.argv))
		for k, a := range c.argv {
			argv[k] = strings.ReplaceAll(a, "{OUT}", o)
		}
		return argv, o
	}
	var oc []oracleCase
	for i, c := range cases {
		argv, o := expand(c, i, pyDir)
		oc = append(oc, oracleCase{Tool: "analyze", Argv: argv, Outputs: map[string]string{"json": o}})
	}
	results := runOracle(t, oc)
	for i, c := range cases {
		argv, o := expand(c, i, goDir)
		rc, stdout, stderr := analyze(t, argv...)
		if stdout != "" {
			t.Errorf("%s: stdout = %q", c.label, stdout)
		}
		if !strings.Contains(strings.Join(c.argv, " "), "{OUT}") {
			// a fixed output path (it exists, or its directory is missing): both runs share it, so the
			// documents cannot be compared; the exit code and the stderr line must still agree
			if rc != results[i].RC || (!strings.HasPrefix(results[i].Stderr, "usage:") && stderr != results[i].Stderr) {
				t.Errorf("%s: exit go %d, legacy %d\n go stderr: %q\n py stderr: %q", c.label, rc, results[i].RC, stderr, results[i].Stderr)
			}
			continue
		}
		requireSame(t, c.label, rc, stderr, readOutputs(map[string]string{"json": o}), results[i], pyDir, goDir, false)
	}
}

// ---------------------------------------------------------------- serial-frame-capture

type step struct {
	hex string
	adv float64
	err string
}

func (s step) raw() json.RawMessage {
	if s.err != "" {
		b, _ := json.Marshal(map[string]string{"err": s.err})
		return b
	}
	b, _ := json.Marshal([]any{s.hex, s.adv})
	return b
}

type captureCase struct {
	label    string
	argv     []string // {OUT} and {LOG} are output paths
	script   map[string][]step
	failOpen []int
	planOnly bool
	preLog   bool // the log file exists before the run
}

func (c captureCase) steps(baud int64) []portStep {
	list, ok := c.script[fmt.Sprint(baud)]
	if !ok {
		list = c.script["default"]
	}
	var out []portStep
	for _, s := range list {
		ps := portStep{advance: time.Duration(s.adv * float64(time.Second))}
		switch {
		case s.err != "":
			ps.err = errors.New(s.err)
		default:
			ps.data, _ = hex.DecodeString(s.hex)
		}
		out = append(out, ps)
	}
	return out
}

func TestCaptureParity(t *testing.T) {
	d := func(h string, adv float64) step { return step{hex: h, adv: adv} }
	frames := []step{d("810017", 0.010), d("00", 0.005), d("82", 0.012), {}, d("8301", 0.030), d("ff", 0.002)}
	flat := strings.Repeat("55", 60)
	rnd := ""
	for i := 0; i < 64; i++ {
		rnd += fmt.Sprintf("%02x", i*4)
	}
	cases := []captureCase{
		{label: "plan sweep", argv: []string{"sweep", "--port", "/dev/ttyUSB0", "--output", "{OUT}"}, planOnly: true},
		{label: "plan sweep seconds", argv: []string{"sweep", "--port", "/dev/ttyUSB0", "--seconds", "2", "--output", "{OUT}"}, planOnly: true},
		{label: "plan capture", argv: []string{"capture", "--port", "/dev/ttyUSB0", "--baud", "19200", "--output", "{OUT}"}, planOnly: true},
		{label: "plan capture knobs", argv: []string{"capture", "--port", "p q", "--baud", " 9_600 ", "--seconds", "1e1", "--gap-ms", "12.5", "--output", "{OUT}"}, planOnly: true},
		{label: "plan capture big baud", argv: []string{"capture", "--port", "/dev/x", "--baud", "99999999999999999999", "--output", "{OUT}"}, planOnly: true},
		{label: "plan capture negative baud", argv: []string{"capture", "--port", "/dev/x", "--baud", "-1", "--output", "{OUT}"}, planOnly: true},
		{label: "plan with log", argv: []string{"capture", "--port", "/dev/x", "--baud", "1", "--log", "{LOG}", "--output", "{OUT}"}, planOnly: true},
		{label: "usage: no baud", argv: []string{"capture", "--port", "/dev/x", "--output", "{OUT}"}},
		{label: "usage: no port", argv: []string{"sweep", "--output", "{OUT}"}},
		{label: "usage: bad float", argv: []string{"sweep", "--port", "/dev/x", "--seconds", "x", "--output", "{OUT}"}},
		{label: "sweep all fail", argv: []string{"sweep", "--port", "/dev/x", "--seconds", "0.5", "--allow-live-probe", "--output", "{OUT}"}, failOpen: []int{2400, 4800, 9600, 19200, 38400, 57600, 115200}},
		{label: "sweep mixed", argv: []string{"sweep", "--port", "/dev/x", "--seconds", "0.5", "--allow-live-probe", "--output", "{OUT}"}, failOpen: []int{2400, 115200}, script: map[string][]step{
			"4800": {d(flat, 0.0)}, "9600": {d(rnd, 0.01), d(rnd, 0.01)}, "19200": {d("aabb", 0.1)}, "38400": {{err: "read exploded"}}, "57600": {d(strings.Repeat("0102", 30), 0.3)},
		}},
		{label: "sweep no data", argv: []string{"sweep", "--port", "/dev/x", "--seconds", "0.7", "--allow-live-probe", "--output", "{OUT}"}},
		{label: "sweep output exists", argv: []string{"sweep", "--port", "/dev/x", "--allow-live-probe", "--output", "{LOG}"}, preLog: true},
		{label: "capture frames", argv: []string{"capture", "--port", "/dev/ttyUSB0", "--baud", "19200", "--seconds", "0.95", "--allow-live-probe", "--log", "{LOG}", "--output", "{OUT}"}, script: map[string][]step{"default": frames}},
		{label: "capture gap 50", argv: []string{"capture", "--port", "/dev/x", "--baud", "9600", "--seconds", "0.95", "--gap-ms", "50", "--allow-live-probe", "--output", "{OUT}"}, script: map[string][]step{"default": frames}},
		{label: "capture no data", argv: []string{"capture", "--port", "/dev/x", "--baud", "9600", "--seconds", "0.35", "--allow-live-probe", "--log", "{LOG}", "--output", "{OUT}"}},
		{label: "capture open fails", argv: []string{"capture", "--port", "/dev/x", "--baud", "9600", "--allow-live-probe", "--output", "{OUT}"}, failOpen: []int{9600}},
		{label: "capture read fails", argv: []string{"capture", "--port", "/dev/x", "--baud", "9600", "--seconds", "0.95", "--allow-live-probe", "--output", "{OUT}"}, script: map[string][]step{"default": {d("01", 0.01), {err: "read exploded"}}}},
		{label: "capture log exists", argv: []string{"capture", "--port", "/dev/x", "--baud", "9600", "--seconds", "0.95", "--allow-live-probe", "--log", "{LOG}", "--output", "{OUT}"}, script: map[string][]step{"default": frames}, preLog: true},
		{label: "capture output exists", argv: []string{"capture", "--port", "/dev/x", "--baud", "9600", "--seconds", "0.95", "--allow-live-probe", "--output", "{LOG}"}, script: map[string][]step{"default": frames}, preLog: true},
	}
	pyDir, goDir := t.TempDir(), t.TempDir()
	expand := func(c captureCase, i int, dir string) ([]string, map[string]string) {
		o, l := filepath.Join(dir, fmt.Sprintf("o%02d.json", i)), filepath.Join(dir, fmt.Sprintf("l%02d.log", i))
		argv := make([]string, len(c.argv))
		for k, a := range c.argv {
			argv[k] = strings.NewReplacer("{OUT}", o, "{LOG}", l).Replace(a)
		}
		if c.preLog {
			_ = os.WriteFile(l, []byte("keep"), 0o600)
		}
		return argv, map[string]string{"json": o, "log": l}
	}
	var oc []oracleCase
	for i, c := range cases {
		argv, outs := expand(c, i, pyDir)
		o := oracleCase{Tool: "capture", Argv: argv, Outputs: outs, FailOpen: c.failOpen, Script: map[string][]json.RawMessage{}}
		for k, steps := range c.script {
			for _, s := range steps {
				o.Script[k] = append(o.Script[k], s.raw())
			}
		}
		oc = append(oc, o)
	}
	results := runOracle(t, oc)
	for i, c := range cases {
		argv, outs := expand(c, i, goDir)
		clk := newClock()
		withPorts(t, func(path string, baud int64, _ func() time.Time) (serialPort, error) {
			for _, b := range c.failOpen {
				if int64(b) == baud {
					return nil, fmt.Errorf("stub open failed at %d", baud)
				}
			}
			return &scriptedPort{clk: clk, steps: c.steps(baud)}, nil
		})
		rc, stdout, stderr := capCmd(t, clk, argv...)
		if stdout != "" {
			t.Errorf("%s: stdout = %q", c.label, stdout)
		}
		requireSame(t, c.label, rc, stderr, readOutputs(outs), results[i], pyDir, goDir, c.planOnly)
	}
}
