//go:build linux

package bacnet

import (
	"bytes"
	"errors"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
)

// End-to-end parity: the real legacy corroborate_bacnet.py and the Go command probe the same loopback
// responders and must leave the same evidence bytes, stdout and exit code. Nothing leaves the machine: the
// responders are UDP sockets on 127.0.0.1 and 127.0.1.1 (both are loopback on Linux).

type responder struct {
	conn *net.UDPConn
	wg   sync.WaitGroup
}

// startResponder answers each datagram with whatever reply returns for it (nil: silence).
func startResponder(t *testing.T, ip string, port int, reply func(frame []byte) [][]byte) *responder {
	t.Helper()
	conn, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.ParseIP(ip), Port: port})
	if err != nil {
		t.Fatalf("responder on %s:%d: %v", ip, port, err)
	}
	r := &responder{conn: conn}
	r.wg.Add(1)
	go func() {
		defer r.wg.Done()
		buf := make([]byte, 1500)
		for {
			n, from, err := conn.ReadFromUDP(buf)
			if err != nil {
				return
			}
			for _, rep := range reply(append([]byte(nil), buf[:n]...)) {
				_, _ = conn.WriteToUDP(rep, from)
			}
		}
	}()
	t.Cleanup(func() { conn.Close(); r.wg.Wait() })
	return r
}

func (r *responder) port() int { return r.conn.LocalAddr().(*net.UDPAddr).Port }

func iamReply(inst uint32) []byte { return iamFrame(fnOriginalUnicast, inst).data }

// device answers like a BBMD for the frames it supports.
func device(inst uint32, bdt, fdt []byte) func([]byte) [][]byte {
	return func(f []byte) [][]byte {
		switch f[1] {
		case fnOriginalUnicast, fnOriginalBroadcast:
			return [][]byte{iamReply(inst)}
		case fnReadBDT:
			if bdt != nil {
				return [][]byte{bdt}
			}
		case fnReadFDT:
			if fdt != nil {
				return [][]byte{fdt}
			}
		}
		return nil
	}
}

type outcome struct {
	code           int
	stdout, stderr string
	evidence       string // "" when the file does not exist
}

func evidenceOf(dir string) string {
	b, err := os.ReadFile(filepath.Join(dir, "out", "bacnet-evidence.v1.json"))
	if err != nil {
		return ""
	}
	return string(b)
}

func runGoE2E(t *testing.T, args []string) outcome {
	t.Helper()
	dir := t.TempDir()
	code, stdout, stderr := run(t, dir, append(args, "--output", filepath.Join(dir, "out"))...)
	return outcome{code, stdout, stderr, evidenceOf(dir)}
}

func runPyE2E(t *testing.T, args []string) outcome {
	t.Helper()
	py, err := exec.LookPath("python3")
	if err != nil {
		t.Fatalf("python3 is required for the parity tests: %v", err)
	}
	tb, _ := filepath.Abs(toolbelt)
	dir := t.TempDir()
	cmd := exec.Command(py, append([]string{"-I", filepath.Join(tb, "corroborate_bacnet.py")}, append(args, "--output", filepath.Join(dir, "out"))...)...)
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	err = cmd.Run()
	code := 0
	var ee *exec.ExitError
	if errors.As(err, &ee) {
		code = ee.ExitCode()
	} else if err != nil {
		t.Fatal(err)
	}
	return outcome{code, out.String(), errb.String(), evidenceOf(dir)}
}

func TestE2EParityLoopbackScenarios(t *testing.T) {
	bdt := bdtAck("c0a80105bac0ffffff00", "0a00000cbac1ffff0000")
	fdt := fdtAck("c0a80109bac0003c0014", "0a00000dbac10e100001")
	scenarios := []struct {
		name     string
		hostRep  func([]byte) [][]byte
		otherRep func([]byte) [][]byte
		args     []string // placeholders: PORT
		expect   int
		word     string
	}{
		{"rebind ok through a BBMD and the broadcast", device(7, bdt, fdt), device(99, nil, nil),
			[]string{"--local-bcast", "127.0.1.1", "--bbmd", "127.0.1.1"}, 0, `"verdict_code": "ok"`},
		{"unicast only fails to rebind", device(12, nil, nil), nil,
			[]string{"--local-bcast", "127.0.0.2"}, 1, `"verdict_code": "rebind_fail"`},
		{"silent host is inconclusive", func([]byte) [][]byte { return nil }, nil,
			[]string{"--bbmd", "127.0.1.1"}, 1, `"verdict_code": "inconclusive"`},
		{"broadcast to the host's own subnet crosses", device(5, nil, nil), nil,
			[]string{"--local-bcast", "127.0.0.1"}, 0, `"crossed_from_target_subnet": {`},
		{"host listed as its own bbmd is probed once", device(5, bdt, nil), nil,
			[]string{"--bbmd", "127.0.0.1"}, 0, `"is_bbmd": true`},
		{"garbage datagrams are skipped", func(f []byte) [][]byte {
			return append([][]byte{{0x01}, {0x81}, {0x81, 0x0a, 0x00}}, device(3, nil, bdt)(f)...)
		}, nil, nil, 1, `"verdict_code": "rebind_fail"`},
		{"forwarded I-Am and a NAT-style source", func(f []byte) [][]byte {
			if f[1] == fnOriginalUnicast {
				return [][]byte{bvlc(fnForwardedNPDU, append([]byte{10, 0, 0, 1, 0xba, 0xc0}, iamFrame(0, 31).data[4:]...))}
			}
			return nil
		}, nil, nil, 1, `"instance": 31`},
	}
	for _, sc := range scenarios {
		t.Run(sc.name, func(t *testing.T) {
			t.Parallel()
			h := startResponder(t, "127.0.0.1", 0, sc.hostRep)
			port := h.port()
			if sc.otherRep != nil {
				startResponder(t, "127.0.1.1", port, sc.otherRep)
			}
			args := append([]string{"--host", "127.0.0.1", "--port", strconv.Itoa(port), "--allow-live-probe", "--timeout", "0.2", "--json"}, sc.args...)
			g, p := runGoE2E(t, args), runPyE2E(t, args)
			if g.code != sc.expect || p.code != sc.expect {
				t.Errorf("exit go %d python %d, want %d\ngo stderr %q\npy stderr %q", g.code, p.code, sc.expect, g.stderr, p.stderr)
			}
			if g.evidence != p.evidence || g.stdout != p.stdout || g.stderr != p.stderr {
				t.Errorf("outputs differ\n--- go evidence\n%s\n--- python evidence\n%s\n--- stderr go %q python %q", g.evidence, p.evidence, g.stderr, p.stderr)
			}
			if !strings.Contains(g.evidence, sc.word) {
				t.Errorf("evidence lacks %s:\n%s", sc.word, g.evidence)
			}
			if g.evidence != g.stdout {
				t.Errorf("--json stdout differs from the file")
			}
		})
	}
}

func TestE2EParityPlanOnlyAndErrors(t *testing.T) {
	cases := []struct {
		name   string
		args   []string
		code   int
		degr   bool // the Go command adds its DEGRADED line to Python's empty stderr
		evid   bool
		stderr bool // compare stderr exactly
	}{
		{"plan-only", []string{"--host", "192.0.2.1", "--json"}, 3, true, true, false},
		{"plan-only with a port and unicode host", []string{"--host", "h\u00e9\u4e16", "--port", "1_0", "--json"}, 3, true, true, false},
		{"plan-only huge port", []string{"--host", "h", "--port", "123456789012345678901234567890", "--json"}, 3, true, true, false},
		{"plan-only negative timeout", []string{"--host", "h", "--timeout", "-5", "--json"}, 3, true, true, false},
		{"port overflow", []string{"--host", "127.0.0.1", "--port", "70000", "--allow-live-probe", "--timeout", "0.1"}, 2, false, false, true},
		{"port negative", []string{"--host", "127.0.0.1", "--port", "-1", "--allow-live-probe", "--timeout", "0.1"}, 2, false, false, true},
		{"port above C int", []string{"--host", "127.0.0.1", "--port", "2147483648", "--allow-live-probe", "--timeout", "0.1"}, 2, false, false, true},
		{"port below C int", []string{"--host", "127.0.0.1", "--port", "-2147483649", "--allow-live-probe", "--timeout", "0.1"}, 2, false, false, true},
		{"port above C long", []string{"--host", "127.0.0.1", "--port", "9223372036854775808", "--allow-live-probe", "--timeout", "0.1"}, 2, false, false, true},
		{"src port overflow", []string{"--host", "127.0.0.1", "--src-port", "70000", "--allow-live-probe", "--timeout", "0.1"}, 2, false, false, true},
		{"timeout inf", []string{"--host", "127.0.0.1", "--allow-live-probe", "--timeout", "inf"}, 2, false, false, false},        // stderr wording is CPython-version specific; exit code only
		{"timeout too large", []string{"--host", "127.0.0.1", "--allow-live-probe", "--timeout", "1e10"}, 2, false, false, false}, // stderr wording is CPython-version specific; exit code only
		{"timeout nan", []string{"--host", "127.0.0.1", "--allow-live-probe", "--timeout", "nan"}, 1, false, false, false},
		{"timeout negative", []string{"--host", "127.0.0.1", "--allow-live-probe", "--timeout", "-1"}, 1, false, false, false},
		{"missing host", []string{}, 2, false, false, false},
		{"bad int", []string{"--host", "h", "--port", "x"}, 2, false, false, false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			t.Parallel()
			g, p := runGoE2E(t, c.args), runPyE2E(t, c.args)
			if g.code != c.code || p.code != c.code {
				t.Errorf("exit go %d python %d, want %d\ngo %q\npy %q", g.code, p.code, c.code, g.stderr, p.stderr)
			}
			if g.stdout != p.stdout || g.evidence != p.evidence {
				t.Errorf("outputs differ\n--- go\n%s%s\n--- python\n%s%s", g.stdout, g.evidence, p.stdout, p.evidence)
			}
			if c.evid && g.evidence == "" {
				t.Errorf("no evidence written")
			}
			if c.stderr && g.stderr != p.stderr {
				t.Errorf("stderr go %q python %q", g.stderr, p.stderr)
			}
			if c.degr && p.stderr != "" {
				t.Errorf("python wrote stderr %q", p.stderr)
			}
			if c.degr && !strings.HasPrefix(g.stderr, "DEGRADED: plan-only") {
				t.Errorf("go stderr %q", g.stderr)
			}
		})
	}
}

func TestE2EParityBindFailure(t *testing.T) {
	occupant, err := net.ListenPacket("udp4", "0.0.0.0:0")
	if err != nil {
		t.Skipf("no UDP sockets here: %v", err)
	}
	defer occupant.Close()
	port := strconv.Itoa(occupant.LocalAddr().(*net.UDPAddr).Port)
	args := []string{"--host", "127.0.0.1", "--src-port", port, "--allow-live-probe", "--timeout", "0.1"}
	g, p := runGoE2E(t, args), runPyE2E(t, args)
	if g.code != 2 || p.code != 2 || g.stderr != p.stderr || g.evidence != "" || p.evidence != "" {
		t.Errorf("go %d %q / python %d %q", g.code, g.stderr, p.code, p.stderr)
	}
}

func TestE2EParityOutputFailures(t *testing.T) {
	dir := t.TempDir()
	file := filepath.Join(dir, "file")
	if err := os.WriteFile(file, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(dir, "isdir", "bacnet-evidence.v1.json"), 0o755); err != nil {
		t.Fatal(err)
	}
	py, err := exec.LookPath("python3")
	if err != nil {
		t.Fatal(err)
	}
	tb, _ := filepath.Abs(toolbelt)
	for _, out := range []string{file, filepath.Join(file, "sub"), filepath.Join(dir, "isdir")} {
		args := []string{"--host", "h", "--output", out}
		var perr bytes.Buffer
		cmd := exec.Command(py, "-I", filepath.Join(tb, "corroborate_bacnet.py"), args[0], args[1], args[2], args[3])
		cmd.Stderr = &perr
		var ee *exec.ExitError
		pcode := 0
		if err := cmd.Run(); errors.As(err, &ee) {
			pcode = ee.ExitCode()
		}
		gcode, _, gerr := run(t, dir, args...)
		if gcode != pcode || gerr != perr.String() {
			t.Errorf("%s: go %d %q / python %d %q", out, gcode, gerr, pcode, perr.String())
		}
	}
}
