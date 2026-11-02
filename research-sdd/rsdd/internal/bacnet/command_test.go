package bacnet

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"errors"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// run drives the command in process, as `rsdd bacnet corroborate-bacnet` would.
func run(t testing.TB, cwd string, args ...string) (code int, stdout, stderr string) {
	t.Helper()
	var out, errb bytes.Buffer
	s := cli.Stdio{
		In: strings.NewReader(""), Out: &out, Err: &errb,
		Env:     func(string) string { return "" },
		Environ: func() []string { return nil },
		Clock:   time.Now,
		Cwd:     cwd,
	}
	code = CorroborateBACnet(args, s)
	return code, out.String(), errb.String()
}

const planOnlyJSON = `{
  "guard": "live probe requires --allow-live-probe; no frames sent",
  "host": "192.0.2.1",
  "plan": {
    "note": "broadcast-who-is requires --local-bcast",
    "probes": [
      "unicast-who-is",
      "broadcast-who-is",
      "read-bdt",
      "read-fdt"
    ],
    "protocol": "ANSI/ASHRAE 135 BACnet/IP",
    "read_only": true
  },
  "port": 47808,
  "schema": "bacnet-evidence.v1",
  "status": "plan-only"
}
`

func TestPlanOnlyGuard(t *testing.T) {
	dir := t.TempDir()
	out := filepath.Join(dir, "nested", "out")
	code, stdout, stderr := run(t, dir, "--host", "192.0.2.1", "--output", out)
	if code != 3 {
		t.Fatalf("exit %d, want 3", code)
	}
	if stdout != "" {
		t.Errorf("stdout without --json: %q", stdout)
	}
	if !strings.HasPrefix(stderr, "DEGRADED: plan-only") {
		t.Errorf("stderr: %q", stderr)
	}
	b, err := os.ReadFile(filepath.Join(out, "bacnet-evidence.v1.json"))
	if err != nil {
		t.Fatal(err)
	}
	if string(b) != planOnlyJSON {
		t.Errorf("plan-only file:\n%s", b)
	}
}

func TestPlanOnlyJSONFlagAndPort(t *testing.T) {
	dir := t.TempDir()
	code, stdout, _ := run(t, dir, "--host", "192.0.2.1", "--output", "rel", "--json", "--port", "47809")
	if code != 3 {
		t.Fatalf("exit %d, want 3", code)
	}
	b, err := os.ReadFile(filepath.Join(dir, "rel", "bacnet-evidence.v1.json"))
	if err != nil {
		t.Fatalf("a relative --output is taken from the injected working directory: %v", err)
	}
	if stdout != string(b) {
		t.Errorf("--json stdout differs from the file:\n%s\n%s", stdout, b)
	}
	if want := strings.Replace(planOnlyJSON, `"port": 47808`, `"port": 47809`, 1); stdout != want {
		t.Errorf("stdout:\n%s", stdout)
	}
}

func TestPlanOnlyKeepsAnyIntegerPort(t *testing.T) {
	for in, want := range map[string]string{
		"1_000":                       "1000",
		" +7 ":                        "7",
		"-1":                          "-1",
		"007":                         "7",
		"1000000000000000000000000":   "1000000000000000000000000",
		"-99999999999999999999999999": "-99999999999999999999999999",
	} {
		dir := t.TempDir()
		code, stdout, stderr := run(t, dir, "--host", "h", "--output", "o", "--json", "--port", in)
		if code != 3 || !strings.Contains(stdout, `"port": `+want+",") {
			t.Errorf("--port %q: exit %d stdout %q stderr %q", in, code, stdout, stderr)
		}
	}
}

func TestPlanOnlyEscapesNonASCIIHost(t *testing.T) {
	dir := t.TempDir()
	_, stdout, _ := run(t, dir, "--host", "hé世\U0001F600\"\\", "--output", "o", "--json")
	if !strings.Contains(stdout, `"host": "h\u00e9\u4e16\ud83d\ude00\"\\",`) {
		t.Errorf("host not escaped as ensure_ascii does:\n%s", stdout)
	}
}

func TestUsageErrors(t *testing.T) {
	dir := t.TempDir()
	cases := []struct {
		name string
		args []string
		msg  string
	}{
		{"no arguments", nil, "the following arguments are required: --host, --output"},
		{"missing output", []string{"--host", "h"}, "the following arguments are required: --output"},
		{"missing host", []string{"--output", "o"}, "the following arguments are required: --host"},
		{"bad port", []string{"--host", "h", "--output", "o", "--port", "x1"}, "invalid int value: 'x1'"},
		{"float port", []string{"--host", "h", "--output", "o", "--port", "1.5"}, "invalid int value: '1.5'"},
		{"underscore edge", []string{"--host", "h", "--output", "o", "--port", "1__0"}, "invalid int value: '1__0'"},
		{"bad src-port", []string{"--host", "h", "--output", "o", "--src-port", ""}, "invalid int value: ''"},
		{"bad timeout", []string{"--host", "h", "--output", "o", "--timeout", "1e"}, "invalid float value: '1e'"},
		{"hex timeout", []string{"--host", "h", "--output", "o", "--timeout", "0x10"}, "invalid float value: '0x10'"},
		{"stray argument", []string{"--host", "h", "--output", "o", "extra"}, "unrecognized arguments: extra"},
		{"unknown flag", []string{"--host", "h", "--output", "o", "--nope"}, "flag provided but not defined"},
	}
	for _, c := range cases {
		code, stdout, stderr := run(t, dir, c.args...)
		if code != 2 || stdout != "" || !strings.Contains(stderr, c.msg) {
			t.Errorf("%s: exit %d stdout %q stderr %q", c.name, code, stdout, stderr)
		}
	}
	if _, err := os.Stat(filepath.Join(dir, "o")); err == nil {
		t.Errorf("a usage error wrote output")
	}
}

func TestEmptyHostIsPresent(t *testing.T) {
	// argparse counts an empty string as a given value
	code, _, _ := run(t, t.TempDir(), "--host", "", "--output", "o")
	if code != 3 {
		t.Errorf("exit %d, want 3", code)
	}
}

func TestHelp(t *testing.T) {
	code, stdout, stderr := run(t, t.TempDir(), "-h")
	if code != 0 || stdout != "" || !strings.Contains(stderr, "usage: rsdd bacnet corroborate-bacnet") {
		t.Errorf("exit %d stdout %q stderr %q", code, stdout, stderr)
	}
}

// --- live probe, through a scripted link ---------------------------------------------------------------

type sent struct {
	frame string
	host  string
	port  string
}

type fakeLink struct {
	sends   []sent
	queue   []fakeReply
	script  func(frame []byte, host string) []fakeReply
	sendErr error
	closed  bool
}

type fakeReply struct {
	ip   string
	data []byte
}

func (f *fakeLink) send(frame []byte, host string, port *big.Int) error {
	if f.sendErr != nil {
		return f.sendErr
	}
	f.sends = append(f.sends, sent{hex.EncodeToString(frame), host, port.String()})
	if f.script != nil {
		f.queue = append(f.queue, f.script(frame, host)...)
	}
	return nil
}

func (f *fakeLink) recv(time.Time) (string, []byte, error) {
	if len(f.queue) == 0 {
		return "", nil, errors.New("timed out")
	}
	r := f.queue[0]
	f.queue = f.queue[1:]
	return r.ip, r.data, nil
}

func (f *fakeLink) close() { f.closed = true }

func useLink(t *testing.T, f *fakeLink) {
	t.Helper()
	old := openLinkFn
	openLinkFn = func(*big.Int) (link, error) { return f, nil }
	t.Cleanup(func() { openLinkFn = old })
}

func iamFrame(fn byte, inst uint32) fakeReply {
	id := 8<<22 | inst
	npdu := []byte{1, 0, 0x10, 0x00, 0xc4, byte(id >> 24), byte(id >> 16), byte(id >> 8), byte(id)}
	return fakeReply{data: bvlc(fn, npdu)}
}

func at(ip string, r fakeReply) fakeReply { r.ip = ip; return r }

func bdtAck(entries ...string) []byte {
	var p []byte
	for _, e := range entries {
		b, _ := hex.DecodeString(e)
		p = append(p, b...)
	}
	return bvlc(fnReadBDTAck, p)
}

func fdtAck(entries ...string) []byte {
	var p []byte
	for _, e := range entries {
		b, _ := hex.DecodeString(e)
		p = append(p, b...)
	}
	return bvlc(fnReadFDTAck, p)
}

// answer is a device at devIP that answers every probe kind the way a BBMD would.
func answer(devIP string, inst uint32, bdt, fdt []byte) func([]byte, string) []fakeReply {
	return func(frame []byte, host string) []fakeReply {
		switch frame[1] {
		case fnOriginalUnicast:
			return []fakeReply{at(devIP, iamFrame(fnOriginalUnicast, inst))}
		case fnReadBDT:
			if bdt != nil {
				return []fakeReply{at(devIP, fakeReply{data: bdt})}
			}
		case fnReadFDT:
			if fdt != nil {
				return []fakeReply{at(devIP, fakeReply{data: fdt})}
			}
		}
		return nil
	}
}

func liveJSON(t *testing.T, args ...string) (code int, doc map[string]any, stderr string) {
	t.Helper()
	dir := t.TempDir()
	code, _, stderr = run(t, dir, append([]string{"--host", "10.1.1.5", "--output", "o", "--allow-live-probe", "--timeout", "0.05"}, args...)...)
	b, err := os.ReadFile(filepath.Join(dir, "o", "bacnet-evidence.v1.json"))
	if err != nil {
		return code, nil, stderr
	}
	if err := json.Unmarshal(b, &doc); err != nil {
		t.Fatalf("evidence is not JSON: %v\n%s", err, b)
	}
	return code, doc, stderr
}

func j(t *testing.T, s string) any {
	t.Helper()
	var v any
	if err := json.Unmarshal([]byte(s), &v); err != nil {
		t.Fatal(err)
	}
	return v
}

func TestLiveRebindOKWithBroadcastAndBBMD(t *testing.T) {
	bcast := func(frame []byte, host string) []fakeReply {
		if frame[1] == fnOriginalBroadcast {
			return []fakeReply{
				at("10.1.1.5", iamFrame(fnOriginalBroadcast, 7)),
				at("10.1.1.9", iamFrame(fnOriginalBroadcast, 9)),
				at("10.1.1.9", iamFrame(fnOriginalBroadcast, 3)),
				at("10.1.1.9", iamFrame(fnOriginalBroadcast, 9)),
				at("172.16.0.2", iamFrame(fnOriginalBroadcast, 2)),
				at("172.16.0.3", fakeReply{data: bvlc(fnOriginalBroadcast, []byte{1, 0, 0x10, 0x08})}), // a Who-Is: no instance
			}
		}
		return answer("10.1.1.5", 7, bdtAck("c0a80105bac0ffffff00"), fdtAck("c0a80109bac0003c0014"))(frame, host)
	}
	f := &fakeLink{script: bcast}
	useLink(t, f)
	code, doc, stderr := liveJSON(t, "--local-bcast", "10.1.1.255", "--bbmd", "10.9.9.9")
	if code != 0 || stderr != "" {
		t.Fatalf("exit %d stderr %q", code, stderr)
	}
	want := j(t, `{
	  "schema": "bacnet-evidence.v1", "status": "complete", "host": "10.1.1.5", "port": 47808,
	  "probes": {
	    "unicast_who_is": {"reachable": true, "instance": 7},
	    "broadcast_who_is": {
	      "local_bcast": "10.1.1.255",
	      "responders": {"10.1.1.5": [7], "10.1.1.9": [3, 9], "172.16.0.2": [2]},
	      "crossed_from_target_subnet": {"10.1.1.5": [7], "10.1.1.9": [3, 9]},
	      "same_as_local": {"172.16.0.2": [2]}
	    },
	    "bbmd_probe": {
	      "10.1.1.5": {"is_bbmd": true, "bdt": [{"addr": "192.168.1.5:0xBAC0", "mask": "255.255.255.0"}],
	                   "fdt": [{"addr": "192.168.1.9:0xBAC0", "ttl_s": 60, "remaining_s": 20}]},
	      "10.9.9.9": {"is_bbmd": true, "bdt": [{"addr": "192.168.1.5:0xBAC0", "mask": "255.255.255.0"}],
	                   "fdt": [{"addr": "192.168.1.9:0xBAC0", "ttl_s": 60, "remaining_s": 20}]}
	    }
	  },
	  "verdict_code": "ok",
	  "verdict": "REBIND OK — broadcast Who-Is reaches the target subnet (BBMD confirmed). Instance-based re-binding will work on an IP change."
	}`)
	if !reflect.DeepEqual(doc, want) {
		got, _ := json.MarshalIndent(doc, "", " ")
		t.Errorf("evidence:\n%s", got)
	}
	wantSends := []sent{
		{"810a000801001008", "10.1.1.5", "47808"},
		{"810b000801001008", "10.1.1.255", "47808"},
		{"81020004", "10.1.1.5", "47808"},
		{"81060004", "10.1.1.5", "47808"},
		{"81020004", "10.9.9.9", "47808"},
		{"81060004", "10.9.9.9", "47808"},
	}
	if !reflect.DeepEqual(f.sends, wantSends) {
		t.Errorf("frames sent:\n%v\nwant\n%v", f.sends, wantSends)
	}
	if !f.closed {
		t.Errorf("socket left open")
	}
}

func TestLiveRebindFailWhenOnlyUnicastAnswers(t *testing.T) {
	useLink(t, &fakeLink{script: answer("10.1.1.5", 12, nil, nil)})
	code, doc, _ := liveJSON(t, "--local-bcast", "10.1.1.255")
	if code != 1 {
		t.Fatalf("exit %d, want 1", code)
	}
	p := doc["probes"].(map[string]any)
	if !reflect.DeepEqual(p["broadcast_who_is"], j(t, `{"local_bcast":"10.1.1.255","responders":{},"crossed_from_target_subnet":{},"same_as_local":{}}`)) {
		t.Errorf("broadcast: %v", p["broadcast_who_is"])
	}
	if !reflect.DeepEqual(p["bbmd_probe"], j(t, `{"10.1.1.5":{"is_bbmd":false,"bdt":null,"fdt":null}}`)) {
		t.Errorf("bbmd: %v", p["bbmd_probe"])
	}
	if doc["verdict_code"] != "rebind_fail" || doc["verdict"] != "REBIND WILL FAIL — device responds to unicast but NOT broadcast Who-Is, and no BBMD answered. Configure a BBMD/Foreign-Device path or use a static IP / DHCP reservation." {
		t.Errorf("verdict %v %v", doc["verdict_code"], doc["verdict"])
	}
}

func TestLiveInconclusiveWhenNothingAnswers(t *testing.T) {
	f := &fakeLink{}
	useLink(t, f)
	code, doc, _ := liveJSON(t)
	if code != 1 {
		t.Fatalf("exit %d, want 1", code)
	}
	p := doc["probes"].(map[string]any)
	if !reflect.DeepEqual(p["unicast_who_is"], j(t, `{"reachable":false,"instance":null}`)) {
		t.Errorf("unicast: %v", p["unicast_who_is"])
	}
	if !reflect.DeepEqual(p["broadcast_who_is"], j(t, `{"local_bcast":null,"note":"--local-bcast not provided; broadcast Who-Is skipped"}`)) {
		t.Errorf("broadcast: %v", p["broadcast_who_is"])
	}
	if doc["verdict_code"] != "inconclusive" || doc["verdict"] != "INCONCLUSIVE — device did not respond to directed unicast Who-Is. Verify --host, --port, firewall rules, and routing." {
		t.Errorf("verdict %v %v", doc["verdict_code"], doc["verdict"])
	}
	// no broadcast without --local-bcast: unicast, then BDT for the host only
	if got := []string{f.sends[0].frame, f.sends[1].frame}; len(f.sends) != 2 || got[0] != "810a000801001008" || got[1] != "81020004" {
		t.Errorf("sends %v", f.sends)
	}
}

func TestLiveBBMDAloneIsEnough(t *testing.T) {
	useLink(t, &fakeLink{script: answer("10.1.1.5", 12, bdtAck(), nil)})
	code, doc, _ := liveJSON(t)
	if code != 0 || doc["verdict_code"] != "ok" || doc["verdict"] != "REBIND OK — broadcast Who-Is reaches the target subnet (BBMD confirmed). Instance-based re-binding will work on an IP change." {
		t.Errorf("exit %d verdict %v %v", code, doc["verdict_code"], doc["verdict"])
	}
	// an ack with no entries is still an ack: bdt is [] and fdt stays null without an FDT ack
	if got := doc["probes"].(map[string]any)["bbmd_probe"]; !reflect.DeepEqual(got, j(t, `{"10.1.1.5":{"is_bbmd":true,"bdt":[],"fdt":null}}`)) {
		t.Errorf("bbmd: %v", got)
	}
}

func TestLiveBroadcastAloneIsOKWithoutBBMDSuffix(t *testing.T) {
	useLink(t, &fakeLink{script: func(frame []byte, _ string) []fakeReply {
		if frame[1] == fnOriginalBroadcast {
			return []fakeReply{at("10.1.1.40", iamFrame(fnOriginalBroadcast, 40))}
		}
		return nil
	}})
	code, doc, _ := liveJSON(t, "--local-bcast", "10.1.1.255")
	if code != 0 || doc["verdict"] != "REBIND OK — broadcast Who-Is reaches the target subnet. Instance-based re-binding will work on an IP change." {
		t.Errorf("exit %d verdict %v", code, doc["verdict"])
	}
	if got := doc["probes"].(map[string]any)["unicast_who_is"]; !reflect.DeepEqual(got, j(t, `{"reachable":false,"instance":null}`)) {
		t.Errorf("unicast: %v", got)
	}
}

func TestLiveUnicastHitMustComeFromTheHost(t *testing.T) {
	useLink(t, &fakeLink{script: func(frame []byte, _ string) []fakeReply {
		if frame[1] == fnOriginalUnicast {
			return []fakeReply{
				at("10.1.1.99", iamFrame(fnOriginalUnicast, 1)),                                    // another device
				at("10.1.1.5", fakeReply{data: bvlc(fnOriginalUnicast, []byte{1, 0, 0x10, 0x08})}), // the host, but no I-Am
				{ip: "10.1.1.5", data: []byte{0x00}},                                               // not even BVLC
				at("10.1.1.5", iamFrame(fnOriginalUnicast, 21)),
				at("10.1.1.5", iamFrame(fnOriginalUnicast, 22)),
			}
		}
		return nil
	}})
	_, doc, _ := liveJSON(t)
	if got := doc["probes"].(map[string]any)["unicast_who_is"]; !reflect.DeepEqual(got, j(t, `{"reachable":true,"instance":21}`)) {
		t.Errorf("the first I-Am from the host wins: %v", got)
	}
}

func TestLiveHostEqualToBBMDIsProbedOnce(t *testing.T) {
	f := &fakeLink{}
	useLink(t, f)
	liveJSON(t, "--bbmd", "10.1.1.5")
	n := 0
	for _, s := range f.sends {
		if s.frame == "81020004" {
			n++
		}
	}
	if n != 1 {
		t.Errorf("read-bdt sent %d times: %v", n, f.sends)
	}
}

func TestLiveLastBDTAndFDTAckWin(t *testing.T) {
	useLink(t, &fakeLink{script: func(frame []byte, _ string) []fakeReply {
		switch frame[1] {
		case fnReadBDT:
			return []fakeReply{
				at("10.1.1.5", fakeReply{data: bdtAck("0a000001bac0ffffffff")}),
				at("10.7.7.7", fakeReply{data: bdtAck("0a000002bac1ffffff00")}), // any source counts
			}
		case fnReadFDT:
			return []fakeReply{
				at("10.1.1.5", fakeReply{data: fdtAck("0a000001bac00001ffff")}),
				at("10.1.1.5", fakeReply{data: fdtAck("0a000002bac10002fffe")}),
			}
		}
		return nil
	}})
	_, doc, _ := liveJSON(t)
	want := j(t, `{"10.1.1.5":{"is_bbmd":true,"bdt":[{"addr":"10.0.0.2:0xBAC1","mask":"255.255.255.0"}],"fdt":[{"addr":"10.0.0.2:0xBAC1","ttl_s":2,"remaining_s":65534}]}}`)
	if got := doc["probes"].(map[string]any)["bbmd_probe"]; !reflect.DeepEqual(got, want) {
		t.Errorf("bbmd: %v", got)
	}
}

func TestLivePortIsSentAndRecorded(t *testing.T) {
	f := &fakeLink{}
	useLink(t, f)
	_, doc, _ := liveJSON(t, "--port", "5000")
	if doc["port"] != float64(5000) {
		t.Errorf("port %v", doc["port"])
	}
	for _, s := range f.sends {
		if s.port != "5000" {
			t.Errorf("sent to port %s", s.port)
		}
	}
}

func TestLiveSendFailureIsAnOperationalError(t *testing.T) {
	f := &fakeLink{sendErr: &pyError{kind: "OSError", msg: "[Errno 101] Network is unreachable"}}
	useLink(t, f)
	dir := t.TempDir()
	code, stdout, stderr := run(t, dir, "--host", "10.1.1.5", "--output", "o", "--allow-live-probe", "--json")
	if code != 2 || stdout != "" || stderr != "corroborate-bacnet: ERROR — [Errno 101] Network is unreachable\n" {
		t.Errorf("exit %d stdout %q stderr %q", code, stdout, stderr)
	}
	if _, err := os.Stat(filepath.Join(dir, "o")); err == nil {
		t.Errorf("an operational error left an output directory")
	}
	if !f.closed {
		t.Errorf("socket left open")
	}
}

func TestLiveOpenFailure(t *testing.T) {
	old := openLinkFn
	openLinkFn = func(*big.Int) (link, error) {
		return nil, &pyError{kind: "OSError", msg: "cannot bind :9 ([Errno 98] Address already in use); retry with --src-port 0"}
	}
	t.Cleanup(func() { openLinkFn = old })
	code, _, stderr := run(t, t.TempDir(), "--host", "h", "--output", "o", "--allow-live-probe")
	if code != 2 || stderr != "corroborate-bacnet: ERROR — cannot bind :9 ([Errno 98] Address already in use); retry with --src-port 0\n" {
		t.Errorf("exit %d stderr %q", code, stderr)
	}
}

func TestLiveJSONFlagPrintsTheEvidence(t *testing.T) {
	useLink(t, &fakeLink{})
	dir := t.TempDir()
	code, stdout, _ := run(t, dir, "--host", "10.1.1.5", "--output", "o", "--allow-live-probe", "--timeout", "0.01", "--json")
	b, _ := os.ReadFile(filepath.Join(dir, "o", "bacnet-evidence.v1.json"))
	if code != 1 || stdout != string(b) || !strings.HasSuffix(stdout, "}\n") || !strings.Contains(stdout, "\n  \"probes\": {\n") {
		t.Errorf("exit %d stdout %q", code, stdout)
	}
}

func TestLiveTimeoutValidation(t *testing.T) {
	cases := []struct {
		timeout string
		code    int
		msg     string
	}{
		{"nan", 1, "ValueError: Invalid value NaN (not a number)"},
		{"-1", 1, "ValueError: Timeout value out of range"},
		{"-0.001", 1, "ValueError: Timeout value out of range"},
		{"inf", 2, "timeout value out of range"},
		{"-inf", 2, "timeout value out of range"},
		{"1e10", 2, "timeout value out of range"},
	}
	for _, c := range cases {
		f := &fakeLink{}
		useLink(t, f)
		dir := t.TempDir()
		code, _, stderr := run(t, dir, "--host", "10.1.1.5", "--output", "o", "--allow-live-probe", "--timeout", c.timeout)
		if code != c.code || stderr != "corroborate-bacnet: ERROR — "+c.msg+"\n" || len(f.sends) != 0 || !f.closed {
			t.Errorf("--timeout %s: exit %d stderr %q sends %v closed %v", c.timeout, code, stderr, f.sends, f.closed)
		}
	}
	// zero is a valid non-blocking timeout
	useLink(t, &fakeLink{})
	if code, _, stderr := run(t, t.TempDir(), "--host", "10.1.1.5", "--output", "o", "--allow-live-probe", "--timeout", "0"); code != 1 {
		t.Errorf("--timeout 0: exit %d stderr %q", code, stderr)
	}
}

func TestPlanOnlyIgnoresTimeoutValidity(t *testing.T) {
	if code, _, _ := run(t, t.TempDir(), "--host", "h", "--output", "o", "--timeout", "-5"); code != 3 {
		t.Errorf("exit %d", code)
	}
}

// --- output directory and file failures -----------------------------------------------------------------

func TestOutputFailures(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "file"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(dir, "isdir", "bacnet-evidence.v1.json"), 0o755); err != nil {
		t.Fatal(err)
	}
	cases := []struct {
		name string
		out  string
		msg  string
	}{
		{"output is a file", "file", "[Errno 17] File exists: 'file'"},
		{"parent is a file", "file/sub", "[Errno 20] Not a directory: 'file/sub'"},
		{"evidence path is a directory", "isdir", "cannot write isdir/bacnet-evidence.v1.json: [Errno 21] Is a directory: 'isdir/bacnet-evidence.v1.json'"},
		{"empty output", "", "[Errno 2] No such file or directory: ''"},
	}
	for _, c := range cases {
		code, stdout, stderr := run(t, dir, "--host", "h", "--output", c.out, "--json")
		if code != 2 || stdout != "" || stderr != "corroborate-bacnet: ERROR — "+c.msg+"\n" {
			t.Errorf("%s: exit %d stdout %q stderr %q", c.name, code, stdout, stderr)
		}
	}
}

func TestOutputDirectoryMayExist(t *testing.T) {
	dir := t.TempDir()
	if err := os.Mkdir(filepath.Join(dir, "there"), 0o755); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 2; i++ { // and the evidence file is overwritten
		if code, _, stderr := run(t, dir, "--host", "h", "--output", "there/", "--port", "1"); code != 3 {
			t.Fatalf("run %d: exit %d stderr %q", i, code, stderr)
		}
	}
	b, _ := os.ReadFile(filepath.Join(dir, "there", "bacnet-evidence.v1.json"))
	if !strings.Contains(string(b), `"port": 1,`) {
		t.Errorf("evidence: %s", b)
	}
}

// --- the real socket ------------------------------------------------------------------------------------

func TestRealSocketPortErrors(t *testing.T) {
	cases := []struct {
		args []string
		msg  string
	}{
		{[]string{"--port", "70000"}, "sendto(): port must be 0-65535."},
		{[]string{"--port", "-1"}, "sendto(): port must be 0-65535."},
		{[]string{"--port", "65536"}, "sendto(): port must be 0-65535."},
		{[]string{"--port", "2147483648"}, "sendto(): port must be 0-65535."},
		{[]string{"--port", "-2147483649"}, "sendto(): port must be 0-65535."},
		{[]string{"--port", "9223372036854775808"}, "sendto(): port must be 0-65535."},
		{[]string{"--src-port", "70000"}, "bind(): port must be 0-65535."},
		{[]string{"--src-port", "-1"}, "bind(): port must be 0-65535."},
	}
	for _, c := range cases {
		dir := t.TempDir()
		args := append([]string{"--host", "192.0.2.1", "--output", "o", "--allow-live-probe", "--timeout", "0.05"}, c.args...)
		code, _, stderr := run(t, dir, args...)
		if code != 2 || stderr != "corroborate-bacnet: ERROR — "+c.msg+"\n" {
			t.Errorf("%v: exit %d stderr %q", c.args, code, stderr)
		}
		if _, err := os.Stat(filepath.Join(dir, "o")); err == nil {
			t.Errorf("%v: left an output directory", c.args)
		}
	}
}

func TestRealSocketBindFailure(t *testing.T) {
	occupant, err := net.ListenPacket("udp4", "0.0.0.0:0")
	if err != nil {
		t.Skipf("no UDP sockets here: %v", err)
	}
	defer occupant.Close()
	port := occupant.LocalAddr().(*net.UDPAddr).Port
	want := "corroborate-bacnet: ERROR — cannot bind :" + itoa(port) + " ([Errno 98] Address already in use); retry with --src-port 0\n"
	code, _, stderr := run(t, t.TempDir(), "--host", "192.0.2.1", "--output", "o", "--allow-live-probe", "--src-port", itoa(port))
	if code != 2 || stderr != want {
		t.Errorf("exit %d stderr %q want %q", code, stderr, want)
	}
}

func itoa(n int) string { return big.NewInt(int64(n)).String() }

func TestRealSocketResolutionFailure(t *testing.T) {
	old := lookupIPv4
	lookupIPv4 = func(string) ([]net.IP, error) { return nil, &net.DNSError{Err: "no such host", IsNotFound: true} }
	t.Cleanup(func() { lookupIPv4 = old })
	code, _, stderr := run(t, t.TempDir(), "--host", "no-such.example", "--output", "o", "--allow-live-probe", "--timeout", "0.05")
	if code != 2 || stderr != "corroborate-bacnet: ERROR — [Errno -2] Name or service not known\n" {
		t.Errorf("exit %d stderr %q", code, stderr)
	}
	lookupIPv4 = func(string) ([]net.IP, error) { return nil, &net.DNSError{Err: "timeout", IsTemporary: true} }
	code, _, stderr = run(t, t.TempDir(), "--host", "no-such.example", "--output", "o", "--allow-live-probe", "--timeout", "0.05")
	if code != 2 || stderr != "corroborate-bacnet: ERROR — [Errno -3] Temporary failure in name resolution\n" {
		t.Errorf("temporary: exit %d stderr %q", code, stderr)
	}
}

func TestInetAton(t *testing.T) {
	cases := map[string]string{
		"1.2.3.4": "1.2.3.4", "127.1": "127.0.0.1", "10.1.2": "10.1.0.2", "2130706433": "127.0.0.1",
		"0x7f.1": "127.0.0.1", "0177.0.0.01": "127.0.0.1", "0x7f000001": "127.0.0.1", "255.255.255.255": "255.255.255.255",
		"0": "0.0.0.0", "00": "0.0.0.0", "0x0": "0.0.0.0",
	}
	for in, want := range cases {
		a, ok := inetAton(in)
		if !ok || a.String() != want {
			t.Errorf("inetAton(%q) = %v %v, want %s", in, a, ok, want)
		}
	}
	for _, in := range []string{"", "1.2.3.4.5", "1..2", "256.1.1.1", "1.2.3.256", "1.2.65536", "1.16777216", "4294967296", "08", "0x", "0xg", "1_0.1", "+1.2.3.4", "-1", "a.b.c.d", "1.2.3.", ".1.2.3"} {
		if a, ok := inetAton(in); ok {
			t.Errorf("inetAton(%q) = %v, want a refusal", in, a)
		}
	}
}

func TestResolveSpecialHosts(t *testing.T) {
	for in, want := range map[string]string{"": "0.0.0.0", "<broadcast>": "255.255.255.255", "192.0.2.7": "192.0.2.7"} {
		if a, e := resolveIPv4(in); e != nil || a.String() != want {
			t.Errorf("resolveIPv4(%q) = %v %v", in, a, e)
		}
	}
	old := lookupIPv4
	lookupIPv4 = func(h string) ([]net.IP, error) {
		return []net.IP{net.ParseIP("2001:db8::1"), net.ParseIP("203.0.113.9")}, nil
	}
	t.Cleanup(func() { lookupIPv4 = old })
	if a, e := resolveIPv4("named.example"); e != nil || a.String() != "203.0.113.9" {
		t.Errorf("first IPv4 answer: %v %v", a, e)
	}
	lookupIPv4 = func(string) ([]net.IP, error) { return []net.IP{net.ParseIP("2001:db8::1")}, nil }
	if _, e := resolveIPv4("v6only.example"); e == nil || e.msg != "[Errno -2] Name or service not known" {
		t.Errorf("an IPv6-only answer: %v", e)
	}
}

func TestOSErrorTextWithoutErrno(t *testing.T) {
	if got := osErrorText(errors.New("plain"), "f"); got != "plain" {
		t.Errorf("%q", got)
	}
	if got := osErrorText(syscall.EACCES, "a'b"); got != `[Errno 13] Permission denied: "a'b"` {
		t.Errorf("%q", got)
	}
}

func TestPyRepr(t *testing.T) {
	for in, want := range map[string]string{
		"plain": `'plain'`, "it's": `"it's"`, `both'"`: `'both\'"'`, "tab\there": `'tab\there'`, "nl\n": `'nl\n'`, "cr\r": `'cr\r'`,
		"back\\slash": `'back\\slash'`, "\x01": `'\x01'`, "\x7f": `'\x7f'`, "café": `'café'`, " ": `'\xa0'`,
		"\u200b": `'\u200b'`, "\U000e0001": `'\U000e0001'`, "bad\xffbyte": `'bad\udcffbyte'`, "世": `'世'`,
	} {
		if got := pyRepr(in); got != want {
			t.Errorf("pyRepr(%q) = %s, want %s", in, got, want)
		}
	}
}
