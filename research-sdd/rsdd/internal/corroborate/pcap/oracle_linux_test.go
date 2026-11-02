//go:build linux && !nodiff

package pcap

import (
	"bytes"
	"encoding/json"
	"fmt"
	"math/rand/v2"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// The frozen legacy tools (testdata/legacy, byte copies of corroborate_pcap.py and pcap_flows.py apart from the
// sys.path line) are the oracle: every parser here must give the same canonical value, or the same error text,
// as the real Python function on the same input.

const legacyDir = "testdata/legacy"

// oracleDriver is run as `python3 -I -c`: it loads the legacy modules by path and applies one parser to a batch
// of cases read from stdin, reporting the canonical JSON of each value or the exception.
const oracleDriver = `
import importlib.util, json, sys
legacy = sys.argv[1]
def load(name):
    spec = importlib.util.spec_from_file_location(name, legacy + "/" + name + ".py")
    mod = importlib.util.module_from_spec(spec); sys.modules[name] = mod; spec.loader.exec_module(mod); return mod
cp, pf = load("corroborate_pcap"), load("pcap_flows")
ops = {
    "capinfos": lambda c: cp._parse_capinfos(c["text"]),
    "phs": lambda c: cp._parse_phs(c["text"]),
    "conv": lambda c: pf._parse_conversations(c["text"], c["proto"]),
    "follow": lambda c: pf._parse_follow(c["text"], c["idx"]),
}
req = json.load(sys.stdin)
out = []
for c in req["cases"]:
    try:
        out.append({"ok": True, "canon": json.dumps(ops[req["op"]](c), sort_keys=True, separators=(",", ":")), "msg": ""})
    except Exception as exc:
        out.append({"ok": False, "canon": "", "msg": type(exc).__name__ + ": " + str(exc)})
json.dump(out, sys.stdout)
`

type oracleCase struct {
	Text  string `json:"text"`
	Proto string `json:"proto"`
	Idx   int    `json:"idx"`
}

type oracleResult struct {
	OK    bool   `json:"ok"`
	Canon string `json:"canon"`
	Msg   string `json:"msg"`
}

// python runs the oracle; a missing python3 FAILS the test (a skipped parity test proves nothing).
func python(t testing.TB) string {
	t.Helper()
	py, err := exec.LookPath("python3")
	if err != nil {
		t.Fatalf("python3 is required for the parity tests and was not found: %v", err)
	}
	return py
}

func runOracle(t testing.TB, op string, cases []oracleCase) []oracleResult {
	t.Helper()
	in, err := json.Marshal(map[string]any{"op": op, "cases": cases})
	if err != nil {
		t.Fatal(err)
	}
	legacy, err := filepath.Abs(legacyDir)
	if err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command(python(t), "-I", "-c", oracleDriver, legacy)
	var out, stderr bytes.Buffer
	cmd.Stdin, cmd.Stdout, cmd.Stderr = bytes.NewReader(in), &out, &stderr
	if err := cmd.Run(); err != nil {
		t.Fatalf("oracle %s failed: %v\n%s", op, err, stderr.String())
	}
	var rs []oracleResult
	if err := json.Unmarshal(out.Bytes(), &rs); err != nil {
		t.Fatalf("oracle output: %v", err)
	}
	if len(rs) != len(cases) {
		t.Fatalf("oracle returned %d results for %d cases", len(rs), len(cases))
	}
	return rs
}

// pick draws n lines from pool joined by sep.
func pick(r *rand.Rand, pool []string, n int, sep string) string {
	lines := make([]string, n)
	for i := range lines {
		lines[i] = pool[r.IntN(len(pool))]
	}
	return strings.Join(lines, sep)
}

func fuzzTexts(seed uint64, pool []string, count int) []string {
	r := rand.New(rand.NewPCG(seed, seed^0x9e3779b97f4a7c15))
	seps := []string{"\n", "\r\n", "\n\n", "\r", " "}
	out := make([]string, count)
	for i := range out {
		out[i] = pick(r, pool, 1+r.IntN(9), seps[r.IntN(len(seps))])
	}
	return out
}

func compare(t *testing.T, op string, cases []oracleCase, got func(oracleCase) (string, string)) {
	t.Helper()
	want := runOracle(t, op, cases)
	bad := 0
	for i, c := range cases {
		canonical, msg := got(c)
		w := want[i]
		switch {
		case w.OK && msg == "" && canonical == w.Canon:
		case !w.OK && msg != "" && strings.HasSuffix(w.Msg, ": "+msg):
		default:
			bad++
			if bad <= 5 {
				t.Errorf("case %d %q\n  python: ok=%v %s %s\n  go:     %s %s", i, c.Text, w.OK, w.Canon, w.Msg, canonical, msg)
			}
		}
	}
	if bad > 0 {
		t.Fatalf("%d of %d cases differ from the legacy parser", bad, len(cases))
	}
}

func TestOracleParseCapinfos(t *testing.T) {
	pool := []string{
		"File encapsulation:  Ethernet", "File encapsulation:", "File size:           86 bytes", "File size: 1_000",
		"File size: 1,000", "Data size:           42 bytes", "Data size: +7", "Data size: 0x10", "Number of packets:   1",
		"Number of packets: 12 k", "Number of packets:", "Capture duration:    0.000000 seconds", "Capture duration: 1e3",
		"Capture duration: .5", "Capture duration: abc seconds", "Capture duration: 12_3.5_5", "Capture duration:  ",
		"no colon here", " : x", "A: B: C", "Number of packets:\t3\t", "File size: 99999999999999999999999",
		"File encapsulation: Linux cooked v2", "Capture duration: 1.5.5",
	}
	texts := append(fuzzTexts(1, pool, 400), capinfosSample, "", "\n\n")
	cases := make([]oracleCase, len(texts))
	for i, s := range texts {
		cases[i] = oracleCase{Text: s}
	}
	compare(t, "capinfos", cases, func(c oracleCase) (string, string) {
		s, err := parseCapinfos(c.Text)
		if err != nil {
			return "", err.Error()
		}
		return canonOf(s.toMap()), ""
	})
}

func canonOf(v any) string {
	b, err := canonical(v)
	if err != nil {
		return "ERR " + err.Error()
	}
	return strings.TrimSuffix(string(b), "\n")
}

func TestOracleParseHierarchy(t *testing.T) {
	pool := []string{
		"===", "====", "Protocol Hierarchy Statistics", "Filter: ", "",
		"eth                                      frames:2 bytes:84", "  ip                                     frames:1 bytes:42",
		"    udp frames:1 bytes:42", "  arp frames:1 bytes:42 extra", "x frames:1 bytes:", "x frames: bytes:3", "x  frames:007  bytes:08",
		"x frames:1bytes:2", "x frames:1x bytes:2", "frames:1 bytes:2", "\teth frames:1 bytes:2", "   ", "a-b_c frames:99999999999999999999 bytes:1",
		"x frames:1 bytes:2", "eth frames:1\tbytes:2", " ip frames:3 bytes:4",
	}
	texts := append(fuzzTexts(2, pool, 500), phsSample)
	cases := make([]oracleCase, len(texts))
	for i, s := range texts {
		cases[i] = oracleCase{Text: s}
	}
	compare(t, "phs", cases, func(c oracleCase) (string, string) {
		return canonOf(protocolMaps(parseHierarchy(c.Text))), ""
	})
}

func TestOracleParseConversations(t *testing.T) {
	pool := []string{
		"===", "TCP Conversations", "UDP Conversations", "Filter:<No Filter>", "",
		"192.168.1.9:80 <-> 192.168.1.2:4321 5 1000 3 200 8 1200", "10.0.0.1:1 <-> 10.0.0.2:2 1 2 3 4 5 6",
		"b:1 <-> a:2 | bytes 10 20 20.5 30 40 | 50 60", "a:1 <-> b:2 1 2 3 4 5", "a:1 <-> b:2", "a:1 <->", "<-> b:2 1 2 3 4 5 6",
		"a:1   <->   a:1  1 2 3 4 5 6 7 8", "z <-> y 007 8 9 10 11 12", "a:1 <-> b:2 bytes bytes 1 2 3 4 5 6 | |", "no arrow 1 2 3",
		"x <-> y 99999999999999999999 1 2 3 4 5", "[::1]:80 <-> [::2]:81 1 2 3 4 5 6 1.5 2.5",
	}
	for _, proto := range []string{"tcp", "udp", "icmp"} {
		texts := fuzzTexts(3, pool, 400)
		cases := make([]oracleCase, len(texts))
		for i, s := range texts {
			cases[i] = oracleCase{Text: s, Proto: proto}
		}
		t.Run(proto, func(t *testing.T) {
			compare(t, "conv", cases, func(c oracleCase) (string, string) {
				return canonOf(conversationMaps(parseConversations(c.Text, c.Proto))), ""
			})
		})
	}
}

func TestOracleParseFollow(t *testing.T) {
	pool := []string{
		"===", "Node 0: 127.0.0.1:1", "Node 1: 127.0.0.1:2", "Node 0:", "Node 1:   x  y ", "48454c4c4f", "abc", "ABCDEF",
		"\t48454c4c4f", "\t4 8", "\t41 42 43", "\t", "\tzz", " 4142", "\t 4142 ", "4142 4344", "zz", "00", "0",
		"Node 0:x", "node 0: lower", "", "  ", "4142\t", "\t\t41",
	}
	texts := fuzzTexts(4, pool, 500)
	cases := make([]oracleCase, len(texts))
	for i, s := range texts {
		cases[i] = oracleCase{Text: s, Idx: i % 7}
	}
	compare(t, "follow", cases, func(c oracleCase) (string, string) {
		return canonOf(parseFollow(c.Text, json.Number(fmt.Sprint(c.Idx))).toMap()), ""
	})
}
