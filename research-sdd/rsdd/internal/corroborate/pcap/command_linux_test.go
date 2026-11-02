//go:build linux

package pcap

import (
	"bytes"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/adapter"
)

// The behaviour of the two commands against the fake Bubblewrap/capinfos/tshark rig, asserted directly (the
// oracle matrix in e2e_oracle_linux_test.go proves they also match the legacy tools byte for byte).

type commandUnderTest struct {
	name string
	run  func([]string, cli.Stdio) int
	json string // evidence file
	prog string // stderr prefix
}

var commands = []commandUnderTest{
	{"pcap", Run, "pcap-evidence.v1.json", "corroborate-pcap"},
	{"pcap-flows", RunFlows, "pcap-flows.v1.json", "pcap-flows"},
}

// workdir is a fresh working directory holding a capture named in.pcap.
func workdir(t *testing.T) string {
	t.Helper()
	dir, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	writePcap(t, filepath.Join(dir, "in.pcap"))
	return dir
}

// invoke runs a command with the default fakes and the real manifest tool.
func invoke(t *testing.T, c commandUnderTest, r *rig, cwd string, args ...string) (code int, stdout, stderr string) {
	t.Helper()
	hostReady(t)
	return goRun(c.run, cwd, r.env(python(t)), append(args, "--manifest-cli", manifestCLI(t))...)
}

func readJSON(t *testing.T, path string) map[string]any {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var m map[string]any
	if err := json.Unmarshal(b, &m); err != nil {
		t.Fatalf("%s: %v", path, err)
	}
	return m
}

func TestTwoRunsOnTheSameCaptureGiveByteIdenticalEvidence(t *testing.T) {
	for _, c := range commands {
		t.Run(c.name, func(t *testing.T) {
			r, cwd := newRig(t), workdir(t)
			for _, out := range []string{"a", "b"} {
				if code, _, errs := invoke(t, c, r, cwd, "--input", "in.pcap", "--output", out); code != 0 {
					t.Fatalf("exit %d: %s", code, errs)
				}
			}
			a, _ := os.ReadFile(filepath.Join(cwd, "a", c.json))
			b, _ := os.ReadFile(filepath.Join(cwd, "b", c.json))
			if len(a) == 0 || !bytes.Equal(a, b) {
				t.Fatalf("evidence differs between runs (%d and %d bytes)", len(a), len(b))
			}
		})
	}
}

func TestEvidenceCarriesTheCapinfosSummaryAndTheProtocolHierarchy(t *testing.T) {
	r, cwd := newRig(t), workdir(t)
	if code, _, errs := invoke(t, commands[0], r, cwd, "--input", "in.pcap", "--output", "out"); code != 0 {
		t.Fatalf("exit %d: %s", code, errs)
	}
	d := readJSON(t, filepath.Join(cwd, "out", "pcap-evidence.v1.json"))
	sum := d["capinfos"].(map[string]any)["summary"].(map[string]any)
	if d["schema"] != "pcap-evidence.v1" || d["status"] != "complete" || sum["packet_count"] != float64(1) || sum["encapsulation"] != "Ethernet" ||
		sum["file_size_bytes"] != float64(86) || sum["data_size_bytes"] != float64(42) || sum["capture_duration_s"] != float64(0) {
		t.Fatalf("evidence = %v", d)
	}
	var names []string
	for _, p := range d["protocol_hierarchy"].(map[string]any)["protocols"].([]any) {
		names = append(names, p.(map[string]any)["protocol"].(string))
	}
	if strings.Join(names, ",") != "eth,arp,ip,tcp" {
		t.Fatalf("protocols = %v, want eth,arp,ip,tcp (by level, then name)", names)
	}
}

func TestFlowsEvidenceCarriesConversationsAndStreamDigests(t *testing.T) {
	r, cwd := newRig(t), workdir(t)
	if code, _, errs := invoke(t, commands[1], r, cwd, "--input", "in.pcap", "--output", "out"); code != 0 {
		t.Fatalf("exit %d: %s", code, errs)
	}
	d := readJSON(t, filepath.Join(cwd, "out", "pcap-flows.v1.json"))
	conv := d["conversations"].(map[string]any)
	tcp, udp := conv["tcp"].([]any), conv["udp"].([]any)
	first := tcp[0].(map[string]any)
	if d["schema"] != "pcap-flows.v1" || d["status"] != "complete" || len(tcp) != 2 || len(udp) != 1 ||
		first["endpoint_a"] != "10.0.0.1:22" || first["frames_total"] != float64(7) {
		t.Fatalf("conversations = %v", conv)
	}
	follows := d["tcp_stream_follows"].([]any)
	hello := sha256.Sum256([]byte("HELLOWORLD"))
	f0 := follows[0].(map[string]any)
	if len(follows) != 2 || f0["payload_sha256"] != "sha256:"+hex.EncodeToString(hello[:]) || f0["payload_bytes"] != float64(10) ||
		f0["client_bytes"] != float64(5) || f0["server_bytes"] != float64(5) || f0["payload_complete"] != true {
		t.Fatalf("follows = %v", follows)
	}
	if d["stream_count_total"] != float64(2) || d["streams_analyzed"] != float64(2) || d["streams_truncated"] != false {
		t.Fatalf("counts = %v", d)
	}
}

func TestPayloadIsStoredAsADigestNotAsBytes(t *testing.T) {
	r, cwd := newRig(t), workdir(t)
	if code, _, errs := invoke(t, commands[1], r, cwd, "--input", "in.pcap", "--output", "out"); code != 0 {
		t.Fatalf("exit %d: %s", code, errs)
	}
	raw, _ := os.ReadFile(filepath.Join(cwd, "out", "pcap-flows.v1.json"))
	digest := regexp.MustCompile(`"payload_sha256":"sha256:[0-9a-f]{64}"`)
	if got := len(digest.FindAll(raw, -1)); got != 2 {
		t.Fatalf("%d digests of the expected form, want 2", got)
	}
	for _, leak := range []string{"48454c4c4f", "HELLO"} {
		if bytes.Contains(raw, []byte(leak)) {
			t.Fatalf("the evidence holds raw payload (%s)", leak)
		}
	}
}

func TestPublishedManifestValidatesAndItsHashesVerify(t *testing.T) {
	for _, c := range commands {
		t.Run(c.name, func(t *testing.T) {
			r, cwd := newRig(t), workdir(t)
			if code, _, errs := invoke(t, c, r, cwd, "--input", "in.pcap", "--output", "out"); code != 0 {
				t.Fatalf("exit %d: %s", code, errs)
			}
			manifest := filepath.Join(cwd, "out", "engine", "analysis-manifest.v1.json")
			for _, args := range [][]string{{"validate", manifest}, {"verify", "--root", filepath.Join(cwd, "out"), manifest}} {
				if out, err := exec.Command(python(t), append([]string{manifestCLI(t)}, args...)...).CombinedOutput(); err != nil {
					t.Fatalf("analysis_manifest.py %s: %v\n%s", args[0], err, out)
				}
			}
		})
	}
}

func TestRecordedSandboxArgvDeniesTheNetwork(t *testing.T) {
	r, cwd := newRig(t), workdir(t)
	if code, _, errs := invoke(t, commands[0], r, cwd, "--input", "in.pcap", "--output", "a"); code != 0 {
		t.Fatalf("exit %d: %s", code, errs)
	}
	if code, _, errs := invoke(t, commands[1], r, cwd, "--input", "in.pcap", "--output", "b"); code != 0 {
		t.Fatalf("exit %d: %s", code, errs)
	}
	ev := readJSON(t, filepath.Join(cwd, "a", "pcap-evidence.v1.json"))
	fl := readJSON(t, filepath.Join(cwd, "b", "pcap-flows.v1.json"))
	argvs := map[string]any{
		"capinfos":           ev["capinfos"].(map[string]any)["argv"],
		"protocol_hierarchy": ev["protocol_hierarchy"].(map[string]any)["argv"],
		"conversations":      fl["conversations"].(map[string]any)["argv"],
	}
	for name, argv := range argvs {
		var all []string
		for _, a := range argv.([]any) {
			all = append(all, a.(string))
		}
		joined := " " + strings.Join(all, " ") + " "
		for _, marker := range []string{"--unshare-net", "--unshare-pid", "--cap-drop ALL", "--die-with-parent", "--new-session"} {
			if !strings.Contains(joined, " "+marker+" ") {
				t.Errorf("%s argv lacks %s", name, marker)
			}
		}
	}
	iso := ev["isolation"].(map[string]any)["profile"].(map[string]any)
	if iso["name"] != "bubblewrap-pcap-offline" || iso["network_access"] != false || iso["target_execution"] != false || iso["static_only"] != true {
		t.Fatalf("isolation profile = %v", iso)
	}
}

func TestInputThatIsNotACaptureIsRejectedAndNothingIsLeftBehind(t *testing.T) {
	for _, c := range commands {
		t.Run(c.name, func(t *testing.T) {
			r, cwd := newRig(t), workdir(t)
			if err := os.WriteFile(filepath.Join(cwd, "garbage.txt"), []byte("not a pcap file\n"), 0o644); err != nil {
				t.Fatal(err)
			}
			code, _, errs := invoke(t, c, r, cwd, "--input", "garbage.txt", "--output", "out")
			if code != 2 || errs != c.prog+": not a pcap/pcapng file (magic: 6e6f7420)\n" {
				t.Fatalf("exit %d stderr %q", code, errs)
			}
			entries, _ := os.ReadDir(cwd)
			if len(entries) != 2 {
				t.Fatalf("the working directory gained entries: %v", entries)
			}
		})
	}
}

func TestSymlinkInputIsRejected(t *testing.T) {
	for _, c := range commands {
		t.Run(c.name, func(t *testing.T) {
			r, cwd := newRig(t), workdir(t)
			if err := os.Symlink("in.pcap", filepath.Join(cwd, "link.pcap")); err != nil {
				t.Fatal(err)
			}
			code, _, errs := invoke(t, c, r, cwd, "--input", "link.pcap", "--output", "out")
			if code != 2 || errs != c.prog+": not a pcap/pcapng file: link.pcap\n" {
				t.Fatalf("exit %d stderr %q", code, errs)
			}
		})
	}
}

func TestRootExecutionIsRefusedBeforeAnyIO(t *testing.T) {
	for _, creds := range []adapter.Creds{{UID: 0, EUID: 0, GID: 1000, EGID: 1000}, {UID: 1000, EUID: 0}, {UID: 1000, EUID: 1000, GID: 1000, EGID: 0}} {
		saved := currentCreds
		currentCreds = func() adapter.Creds { return creds }
		for _, c := range commands {
			// Inputs that would each fail differently if anything were read.
			code, out, errs := goRun(c.run, t.TempDir(), nil, "--input", "x", "--output", "y", "--manifest-cli", "z")
			if code != 2 || out != "" || errs != c.prog+": refusing root or set-id execution\n" {
				t.Errorf("%s with %+v: exit %d stdout %q stderr %q", c.name, creds, code, out, errs)
			}
		}
		currentCreds = saved
	}
}

func TestMaxStreamsCapsTheFollowPassesAndSaysSo(t *testing.T) {
	r, cwd := newRig(t), workdir(t)
	r.set("fields.txt", "0\n1\n2\n")
	r.set("follow-2.txt", "===\nNode 0: c\nNode 1: d\n43\n===\n")
	code, _, errs := invoke(t, commands[1], r, cwd, "--input", "in.pcap", "--output", "out", "--max-streams", "2")
	if code != 0 || errs != "pcap-flows: warning: 3 TCP streams found; analyzing only the first 2 (--max-streams=2)\n" {
		t.Fatalf("exit %d stderr %q", code, errs)
	}
	d := readJSON(t, filepath.Join(cwd, "out", "pcap-flows.v1.json"))
	if d["streams_truncated"] != true || d["streams_analyzed"] != float64(2) || d["stream_count_total"] != float64(3) || len(d["tcp_stream_follows"].([]any)) != 2 {
		t.Fatalf("evidence = %v", d)
	}
}

func TestAnalyzerFailureIsPublishedAsFailedEvidenceWithExitOne(t *testing.T) {
	r, cwd := newRig(t), workdir(t)
	r.set("fail-phs", "4")
	code, _, errs := invoke(t, commands[0], r, cwd, "--input", "in.pcap", "--output", "out")
	want := "pcap-evidence.v1: completed with issues (analyzer-exit:4) — see " + cwd + "/out/pcap-evidence.v1.json\n"
	if code != 1 || errs != want {
		t.Fatalf("exit %d stderr %q, want 1 and %q", code, errs, want)
	}
	d := readJSON(t, filepath.Join(cwd, "out", "pcap-evidence.v1.json"))
	if d["status"] != "failed" || len(d["protocol_hierarchy"].(map[string]any)["protocols"].([]any)) != 0 {
		t.Fatalf("evidence = %v", d)
	}
}

// A stage directory that already exists is somebody else's (another run in flight, or a leftover): the run that
// failed to create it must not delete it. The legacy scripts' cleanup removed it.
func TestExistingStageDirectoryIsLeftAlone(t *testing.T) {
	for _, c := range commands {
		t.Run(c.name, func(t *testing.T) {
			r, cwd := newRig(t), workdir(t)
			stage := filepath.Join(cwd, ".out.stage")
			if err := os.Mkdir(stage, 0o700); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(stage, "keep"), []byte("mine"), 0o600); err != nil {
				t.Fatal(err)
			}
			code, _, errs := invoke(t, c, r, cwd, "--input", "in.pcap", "--output", "out")
			if code != 2 || errs != c.prog+": [Errno 17] File exists: '"+stage+"'\n" {
				t.Fatalf("exit %d stderr %q", code, errs)
			}
			if b, err := os.ReadFile(filepath.Join(stage, "keep")); err != nil || string(b) != "mine" {
				t.Fatalf("the existing stage was disturbed: %q %v", b, err)
			}
		})
	}
}

func TestHelpIsPrintedOnStdoutWithExitZero(t *testing.T) {
	for _, c := range commands {
		code, out, errs := goRun(c.run, t.TempDir(), nil, "--help")
		if code != 0 || errs != "" || !strings.Contains(out, "--timeout-seconds TIMEOUT_SECONDS") || !strings.Contains(out, "--input INPUT") {
			t.Errorf("%s: exit %d stdout %q stderr %q", c.name, code, out, errs)
		}
	}
}

func TestUsageErrorsExitTwoOnStderr(t *testing.T) {
	cases := []struct {
		args []string
		want string
	}{
		{nil, "error: the following arguments are required: --input, --output, --manifest-cli\n"},
		{[]string{"--input", "a", "--output", "b", "--manifest-cli", "c", "--timeout-seconds", "x"}, "error: argument --timeout-seconds: invalid int value: 'x'\n"},
		{[]string{"--input"}, "error: argument --input: expected one argument\n"},
		{[]string{"--m", "1"}, "error: ambiguous option: --m could match --max-bytes,"},
		{[]string{"--input", "a", "--output", "b", "--manifest-cli", "c", "extra"}, "error: unrecognized arguments: extra\n"},
	}
	for _, c := range commands {
		for _, tc := range cases {
			code, out, errs := goRun(c.run, t.TempDir(), nil, tc.args...)
			if code != 2 || out != "" || !strings.HasPrefix(errs, "usage: ") || !strings.Contains(errs, tc.want) {
				t.Errorf("%s %q: exit %d stdout %q stderr %q", c.name, tc.args, code, out, errs)
			}
		}
	}
}

// ---------------------------------------------------------------------------- real tools

// mintTCPCapture writes a capture with one TCP stream: a SYN and a PSH|ACK carrying "HELLO".
func mintTCPCapture(t *testing.T, path string) {
	t.Helper()
	frame := func(ts uint32, sport, dport uint16, seq, ack uint32, flags uint16, data []byte) []byte {
		tcp := make([]byte, 20)
		binary.BigEndian.PutUint16(tcp[0:], sport)
		binary.BigEndian.PutUint16(tcp[2:], dport)
		binary.BigEndian.PutUint32(tcp[4:], seq)
		binary.BigEndian.PutUint32(tcp[8:], ack)
		binary.BigEndian.PutUint16(tcp[12:], 5<<12|flags)
		binary.BigEndian.PutUint16(tcp[14:], 65535)
		tcp = append(tcp, data...)
		ip := make([]byte, 20)
		ip[0], ip[8], ip[9] = 0x45, 64, 6
		binary.BigEndian.PutUint16(ip[2:], uint16(20+len(tcp)))
		binary.BigEndian.PutUint16(ip[4:], 1)
		binary.BigEndian.PutUint16(ip[6:], 0x4000)
		copy(ip[12:], []byte{192, 168, 1, 1})
		copy(ip[16:], []byte{192, 168, 1, 2})
		f := append(append(make([]byte, 12), 0x08, 0x00), append(ip, tcp...)...)
		rec := make([]byte, 16)
		binary.LittleEndian.PutUint32(rec[0:], ts)
		binary.LittleEndian.PutUint32(rec[8:], uint32(len(f)))
		binary.LittleEndian.PutUint32(rec[12:], uint32(len(f)))
		return append(rec, f...)
	}
	hdr := make([]byte, 24)
	binary.LittleEndian.PutUint32(hdr[0:], 0xa1b2c3d4)
	binary.LittleEndian.PutUint16(hdr[4:], 2)
	binary.LittleEndian.PutUint16(hdr[6:], 4)
	binary.LittleEndian.PutUint32(hdr[16:], 65535)
	binary.LittleEndian.PutUint32(hdr[20:], 1)
	body := append(hdr, frame(1, 4321, 80, 1000, 0, 0x002, nil)...)
	body = append(body, frame(2, 4321, 80, 1001, 1001, 0x018, []byte("HELLO"))...)
	if err := os.WriteFile(path, body, 0o644); err != nil {
		t.Fatal(err)
	}
}

// realTools skips (a typed SKIP, never a pass) when tshark, capinfos or a working Bubblewrap is missing.
func realTools(t *testing.T) {
	t.Helper()
	for _, tool := range []string{"tshark", "capinfos", "bwrap"} {
		if _, err := exec.LookPath(tool); err != nil {
			t.Skipf("SKIP tool-missing: %s is not in PATH", tool)
		}
	}
	if err := exec.Command("bwrap", "--ro-bind", "/", "/", "--unshare-net", "--unshare-pid", "true").Run(); err != nil {
		t.Skipf("SKIP tool-missing: bwrap cannot create its namespaces here: %v", err)
	}
}

func realEnv(t *testing.T) []string {
	return []string{"PATH=" + os.Getenv("PATH"), "HOME=" + t.TempDir()}
}

// mintARPCapture writes a capture with one Ethernet/ARP packet.
func mintARPCapture(t *testing.T, path string) {
	t.Helper()
	hdr := make([]byte, 24)
	binary.LittleEndian.PutUint32(hdr[0:], 0xa1b2c3d4)
	binary.LittleEndian.PutUint16(hdr[4:], 2)
	binary.LittleEndian.PutUint16(hdr[6:], 4)
	binary.LittleEndian.PutUint32(hdr[16:], 65535)
	binary.LittleEndian.PutUint32(hdr[20:], 1)
	arp := []byte{0, 1, 8, 0, 6, 4, 0, 1, 0, 0, 0, 0, 0, 0, 192, 168, 1, 1, 0, 0, 0, 0, 0, 0, 192, 168, 1, 100}
	pkt := append(append(make([]byte, 12), 0x08, 0x06), arp...)
	rec := make([]byte, 16)
	binary.LittleEndian.PutUint32(rec[0:], 1000000)
	binary.LittleEndian.PutUint32(rec[8:], uint32(len(pkt)))
	binary.LittleEndian.PutUint32(rec[12:], uint32(len(pkt)))
	if err := os.WriteFile(path, append(append(hdr, rec...), pkt...), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestRealToolsPcapEvidenceOfAnEthernetCapture(t *testing.T) {
	realTools(t)
	hostReady(t)
	cwd := t.TempDir()
	mintARPCapture(t, filepath.Join(cwd, "in.pcap"))
	code, _, errs := goRun(Run, cwd, realEnv(t), "--input", "in.pcap", "--output", "out", "--manifest-cli", manifestCLI(t))
	if code != 0 {
		t.Fatalf("exit %d: %s", code, errs)
	}
	d := readJSON(t, filepath.Join(cwd, "out", "pcap-evidence.v1.json"))
	sum := d["capinfos"].(map[string]any)["summary"].(map[string]any)
	if d["status"] != "complete" || sum["packet_count"] != float64(1) || sum["encapsulation"] != "Ethernet" || sum["file_size_bytes"].(float64) <= 0 {
		t.Fatalf("evidence = %v", d)
	}
	var names []string
	for _, p := range d["protocol_hierarchy"].(map[string]any)["protocols"].([]any) {
		names = append(names, p.(map[string]any)["protocol"].(string))
	}
	if !strings.Contains(strings.Join(names, ","), "eth") {
		t.Fatalf("protocols = %v, want eth among them", names)
	}
}

func TestRealToolsFlowsDigestOfARealTCPStream(t *testing.T) {
	realTools(t)
	hostReady(t)
	cwd := t.TempDir()
	mintTCPCapture(t, filepath.Join(cwd, "in.pcap"))
	code, _, errs := goRun(RunFlows, cwd, realEnv(t), "--input", "in.pcap", "--output", "out", "--manifest-cli", manifestCLI(t))
	if code != 0 {
		t.Fatalf("exit %d: %s", code, errs)
	}
	d := readJSON(t, filepath.Join(cwd, "out", "pcap-flows.v1.json"))
	hello := sha256.Sum256([]byte("HELLO"))
	follows := d["tcp_stream_follows"].([]any)
	f := follows[0].(map[string]any)
	if len(follows) != 1 || f["payload_sha256"] != "sha256:"+hex.EncodeToString(hello[:]) || f["payload_bytes"] != float64(5) {
		t.Fatalf("follows = %v", follows)
	}
	if tcp := d["conversations"].(map[string]any)["tcp"].([]any); len(tcp) != 1 {
		t.Fatalf("tcp conversations = %v", tcp)
	}
}
