//go:build linux

package pcap

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"math/rand/v2"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"
	"unicode/utf8"
)

// Frozen oracle outcomes. The legacy Python tools are the oracle of the parity tests (build tag !nodiff); running
// them with RSDD_UPDATE_GOLDENS=1 freezes what they did under testdata/goldens, and without it asserts the goldens
// still equal the oracle. The tests of this file need no Python: they replay the scenarios and the parser cases
// through the Go code and compare with the frozen outcomes.

const goldenDir = "testdata/goldens"

// manifestEntry is the analysis manifest. Its content is not frozen from the oracle (the real tool adds hashes and
// identity); the replay runs a fake manifest tool that copies the spec, so what is frozen under Spec is the spec the
// command asked the tool to record.
const manifestEntry = "engine/analysis-manifest.v1.json"

// frozen is one scenario outcome with the paths of the run replaced by ROOT (working directory) and RIG (tool
// directory). Large tree files, and any that is not valid UTF-8, are kept as their SHA-256 except in the scenario named "ok", which keeps them whole.
type frozen struct {
	Code   int               `json:"code"`
	Stdout string            `json:"stdout"`
	Stderr string            `json:"stderr"`
	Tree   map[string]string `json:"tree"`
	Spec   string            `json:"spec,omitempty"`
}

const keepWhole = 1024

// looseRun matches the run record's exit status, which a run stopped at the output cap does not settle: the killed
// tool may already have finished.
var looseRun = regexp.MustCompile("\"exit_code\":(null|-?[0-9]+),\"signal\":(null|-?[0-9]+)")

func freeze(o outcome, rigDir, scenarioName string, loose bool) (f frozen, manifest string) {
	norm := func(s string) string { return strings.ReplaceAll(s, rigDir, "RIG") }
	f = frozen{Code: o.code, Stdout: norm(o.stdout), Stderr: norm(o.stderr), Tree: map[string]string{}}
	for k, v := range o.tree {
		v = norm(v)
		if strings.HasSuffix(k, manifestEntry) {
			if i := strings.Index(v, "{"); i >= 0 {
				manifest = v[i:]
				if loose {
					manifest = looseRun.ReplaceAllString(manifest, "\"exit_code\":\"*\",\"signal\":\"*\"")
				}
			}
			continue
		}
		if (len(v) > keepWhole && scenarioName != "ok") || !utf8.ValidString(v) {
			sum := sha256.Sum256([]byte(v))
			v = "sha256:" + hex.EncodeToString(sum[:])
		}
		f.Tree[k] = v
	}
	return f, manifest
}

// goldenKey names one scenario of one tool.
func goldenKey(tl tool, sc scenario) string { return tl.name + "/" + sc.name }

type goldenSet map[string]frozen

func (g goldenSet) write(t *testing.T, name string) {
	t.Helper()
	keys := make([]string, 0, len(g))
	for k := range g {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	var b strings.Builder
	b.WriteString("{\n")
	for i, k := range keys {
		kb, _ := json.Marshal(k)
		vb, err := json.Marshal(g[k])
		if err != nil {
			t.Fatal(err)
		}
		b.Write(kb)
		b.WriteString(": ")
		b.Write(vb)
		if i < len(keys)-1 {
			b.WriteString(",")
		}
		b.WriteString("\n")
	}
	b.WriteString("}\n")
	if err := os.MkdirAll(goldenDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(goldenDir, name), []byte(b.String()), 0o644); err != nil {
		t.Fatal(err)
	}
}

func readGolden[T any](t testing.TB, name string) map[string]T {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(goldenDir, name))
	if err != nil {
		t.Fatalf("golden %s: %v (regenerate with RSDD_UPDATE_GOLDENS=1 on the oracle tests)", name, err)
	}
	var m map[string]T
	if err := json.Unmarshal(b, &m); err != nil {
		t.Fatalf("golden %s: %v", name, err)
	}
	if len(m) == 0 {
		t.Fatalf("golden %s is empty", name)
	}
	return m
}

// replay runs one scenario through the Go command against a rig whose manifest tool is the fake one. It needs
// no Python: this is what the committed goldens are compared with.
func replay(t *testing.T, tl tool, sc scenario) (f frozen, spec string) {
	t.Helper()
	r := newRig(t)
	r.fakeManifest()
	cwd, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	writePcap(t, filepath.Join(cwd, "in.pcap"))
	if sc.prep != nil {
		sc.prep(r, cwd)
	}
	fake := filepath.Join(r.dir, "manifest-cli")
	args := append([]string(nil), sc.args...)
	if sc.raw {
		for i, a := range args {
			args[i] = strings.ReplaceAll(a, "@MANIFEST@", fake)
		}
	} else {
		args = append(args, "--manifest-cli", fake)
	}
	code, out, errs := goRun(tl.run, cwd, r.env("", sc.env...), args...)
	o := snapshotWith(t, cwd, code, out, errs, func(body string) string { return body })
	return freeze(o, r.dir, sc.name, sc.loose)
}

func TestGoldenScenariosReplay(t *testing.T) {
	hostReady(t)
	for _, tl := range both() {
		golden := readGolden[frozen](t, "scenarios-"+tl.name+".json")
		seen := map[string]bool{}
		for _, sc := range scenarios() {
			if sc.diverges != nil || !hasTool(sc, tl) {
				continue
			}
			key := goldenKey(tl, sc)
			seen[key] = true
			want, ok := golden[key]
			if !ok {
				t.Errorf("no golden for %s", key)
				continue
			}
			t.Run(key, func(t *testing.T) {
				t.Parallel()
				got, spec := replay(t, tl, sc)
				if want.Spec != spec {
					t.Errorf("manifest spec differs at byte %d:\nwant: %q\ngot:  %q", firstDiff(want.Spec, spec), window(want.Spec, firstDiff(want.Spec, spec)), window(spec, firstDiff(want.Spec, spec)))
				}
				want.Spec = ""
				report(t, outcome{code: want.Code, stdout: want.Stdout, stderr: want.Stderr, tree: want.Tree}, outcome{code: got.Code, stdout: got.Stdout, stderr: got.Stderr, tree: got.Tree})
			})
		}
		for key := range golden {
			if !seen[key] {
				t.Errorf("golden %s names no scenario", key)
			}
		}
	}
}

func hasTool(sc scenario, tl tool) bool {
	for _, x := range sc.tools {
		if x.name == tl.name {
			return true
		}
	}
	return false
}

func runGo(t *testing.T, tl tool, cwd string, loose bool, env []string, args []string) outcome {
	t.Helper()
	code, out, errs := goRun(tl.run, cwd, env, args...)
	return snapshot(t, cwd, loose, code, out, errs)
}

// ---------------------------------------------------------------------------- parser cases

type oracleCase struct {
	Text  string `json:"text"`
	Proto string `json:"proto"`
	Idx   int    `json:"idx"`
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
	seps := []string{"\n", "\r\n", "\n\n", "\r", " "}
	out := make([]string, count)
	for i := range out {
		out[i] = pick(r, pool, 1+r.IntN(9), seps[r.IntN(len(seps))])
	}
	return out
}

func canonOf(v any) string {
	b, err := canonical(v)
	if err != nil {
		return "ERR " + err.Error()
	}
	return strings.TrimSuffix(string(b), "\n")
}

// parseSuite is one parser, the cases it is held to, and the function that runs the Go parser on a case and
// returns its canonical value or its error text.
type parseSuite struct {
	file  string
	op    string
	cases []oracleCase
	got   func(oracleCase) (canonical, errText string)
}

func textCases(texts []string, proto string) []oracleCase {
	cases := make([]oracleCase, len(texts))
	for i, s := range texts {
		cases[i] = oracleCase{Text: s, Proto: proto}
	}
	return cases
}

func parseSuites() []parseSuite {
	var capTexts, phsTexts, followTexts []string
	var convCases []oracleCase
	{
		pool := []string{
			"File encapsulation:  Ethernet", "File encapsulation:", "File size:           86 bytes", "File size: 1_000",
			"File size: 1,000", "Data size:           42 bytes", "Data size: +7", "Data size: 0x10", "Number of packets:   1",
			"Number of packets: 12 k", "Number of packets:", "Capture duration:    0.000000 seconds", "Capture duration: 1e3",
			"Capture duration: .5", "Capture duration: abc seconds", "Capture duration: 12_3.5_5", "Capture duration:  ",
			"no colon here", " : x", "A: B: C", "Number of packets:\t3\t", "File size: 99999999999999999999999",
			"File encapsulation: Linux cooked v2", "Capture duration: 1.5.5",
		}
		capTexts = append(fuzzTexts(1, pool, 150), capinfosSample, "", "\n\n")
	}
	{
		pool := []string{
			"===", "====", "Protocol Hierarchy Statistics", "Filter: ", "",
			"eth                                      frames:2 bytes:84", "  ip                                     frames:1 bytes:42",
			"    udp frames:1 bytes:42", "  arp frames:1 bytes:42 extra", "x frames:1 bytes:", "x frames: bytes:3", "x  frames:007  bytes:08",
			"x frames:1bytes:2", "x frames:1x bytes:2", "frames:1 bytes:2", "\teth frames:1 bytes:2", "   ", "a-b_c frames:99999999999999999999 bytes:1",
			"x frames:1 bytes:2", "eth frames:1\tbytes:2", " ip frames:3 bytes:4",
		}
		phsTexts = append(fuzzTexts(2, pool, 150), phsSample)
	}
	{
		pool := []string{
			"===", "TCP Conversations", "UDP Conversations", "Filter:<No Filter>", "",
			"192.168.1.9:80 <-> 192.168.1.2:4321 5 1000 3 200 8 1200", "10.0.0.1:1 <-> 10.0.0.2:2 1 2 3 4 5 6",
			"b:1 <-> a:2 | bytes 10 20 20.5 30 40 | 50 60", "a:1 <-> b:2 1 2 3 4 5", "a:1 <-> b:2", "a:1 <->", "<-> b:2 1 2 3 4 5 6",
			"a:1   <->   a:1  1 2 3 4 5 6 7 8", "z <-> y 007 8 9 10 11 12", "a:1 <-> b:2 bytes bytes 1 2 3 4 5 6 | |", "no arrow 1 2 3",
			"x <-> y 99999999999999999999 1 2 3 4 5", "[::1]:80 <-> [::2]:81 1 2 3 4 5 6 1.5 2.5",
		}
		for _, proto := range []string{"tcp", "udp", "icmp"} {
			convCases = append(convCases, textCases(fuzzTexts(3, pool, 70), proto)...)
		}
	}
	{
		pool := []string{
			"===", "Node 0: 127.0.0.1:1", "Node 1: 127.0.0.1:2", "Node 0:", "Node 1:   x  y ", "48454c4c4f", "abc", "ABCDEF",
			"\t48454c4c4f", "\t4 8", "\t41 42 43", "\t", "\tzz", " 4142", "\t 4142 ", "4142 4344", "zz", "00", "0",
			"Node 0:x", "node 0: lower", "", "  ", "4142\t", "\t\t41",
		}
		followTexts = fuzzTexts(4, pool, 150)
	}
	followCases := textCases(followTexts, "")
	for i := range followCases {
		followCases[i].Idx = i % 7
	}
	return []parseSuite{
		{"parse-capinfos.json", "capinfos", textCases(capTexts, ""), func(c oracleCase) (string, string) {
			s, err := parseCapinfos(c.Text)
			if err != nil {
				return "", err.Error()
			}
			return canonOf(s.toMap()), ""
		}},
		{"parse-phs.json", "phs", textCases(phsTexts, ""), func(c oracleCase) (string, string) {
			return canonOf(protocolMaps(parseHierarchy(c.Text))), ""
		}},
		{"parse-conv.json", "conv", convCases, func(c oracleCase) (string, string) {
			return canonOf(conversationMaps(parseConversations(c.Text, c.Proto))), ""
		}},
		{"parse-follow.json", "follow", followCases, func(c oracleCase) (string, string) {
			return canonOf(parseFollow(c.Text, json.Number(fmt.Sprint(c.Idx))).toMap()), ""
		}},
	}
}

// parseGolden is one frozen case: the input and what the legacy parser answered.
type parseGolden struct {
	Text  string `json:"text"`
	Proto string `json:"proto,omitempty"`
	Idx   int    `json:"idx,omitempty"`
	OK    bool   `json:"ok"`
	Canon string `json:"canon,omitempty"`
	Msg   string `json:"msg,omitempty"`
}

func writeParseGolden(t *testing.T, name string, rows []parseGolden) {
	t.Helper()
	var b strings.Builder
	b.WriteString("[\n")
	for i, r := range rows {
		line, err := json.Marshal(r)
		if err != nil {
			t.Fatal(err)
		}
		b.Write(line)
		if i < len(rows)-1 {
			b.WriteString(",")
		}
		b.WriteString("\n")
	}
	b.WriteString("]\n")
	if err := os.MkdirAll(goldenDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(goldenDir, name), []byte(b.String()), 0o644); err != nil {
		t.Fatal(err)
	}
}

func readParseGolden(t testing.TB, name string) []parseGolden {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(goldenDir, name))
	if err != nil {
		t.Fatalf("golden %s: %v (regenerate with RSDD_UPDATE_GOLDENS=1 on the oracle tests)", name, err)
	}
	var rows []parseGolden
	if err := json.Unmarshal(b, &rows); err != nil {
		t.Fatalf("golden %s: %v", name, err)
	}
	if len(rows) == 0 {
		t.Fatalf("golden %s is empty", name)
	}
	return rows
}

// TestGoldenParsersReplay runs every frozen parser case through the Go parser.
func TestGoldenParsersReplay(t *testing.T) {
	for _, s := range parseSuites() {
		t.Run(s.op, func(t *testing.T) {
			rows := readParseGolden(t, s.file)
			bad := 0
			for i, g := range rows {
				canonical, msg := s.got(oracleCase{Text: g.Text, Proto: g.Proto, Idx: g.Idx})
				switch {
				case g.OK && msg == "" && canonical == g.Canon:
				case !g.OK && msg != "" && strings.HasSuffix(g.Msg, ": "+msg):
				default:
					bad++
					if bad <= 5 {
						t.Errorf("case %d %q\n  golden: ok=%v %s %s\n  go:     %s %s", i, g.Text, g.OK, g.Canon, g.Msg, canonical, msg)
					}
				}
			}
			if bad > 0 {
				t.Fatalf("%d of %d cases differ from the frozen legacy answers", bad, len(rows))
			}
		})
	}
}
