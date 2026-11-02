//go:build linux && !nodiff

package capa

// Records the legacy Python tool's answers as the goldens that goldens_test.go replays, and proves they are
// not stale: without RSDD_UPDATE_GOLDENS=1 this test asserts every file equals what the oracle says today.
// The corpora below are the inputs; the answers always come from the oracle, never from the port.

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// goldenOracle answers one request per case with the real legacy argparse parser, json reader and inventory.
const goldenOracle = `
import sys, os, io, json, contextlib, importlib.util, tempfile
from pathlib import Path
legacy, toolbelt = sys.argv[1], sys.argv[2]
sys.path.insert(0, toolbelt)
spec = importlib.util.spec_from_file_location("legacy_capa", legacy)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
def fix(v):
    if isinstance(v, float) and (v != v or v in (float("inf"), float("-inf"))): return {"$f": repr(v)}
    if isinstance(v, list): return [fix(x) for x in v]
    if isinstance(v, dict): return {k: fix(x) for k, x in v.items()}
    return v
canon = lambda v: json.dumps(fix(v), sort_keys=True, separators=(",", ":"), allow_nan=False)
def lone(v):
    if isinstance(v, str): return any(0xd800 <= ord(c) <= 0xdfff for c in v)
    if isinstance(v, list): return any(lone(x) for x in v)
    if isinstance(v, dict): return any(lone(k) or lone(x) for k, x in v.items())
    return False
class ArgErr(Exception): pass
def one(c):
    k = c["kind"]
    if k == "usage":
        if c.get("cols", "") == "": os.environ.pop("COLUMNS", None)
        else: os.environ["COLUMNS"] = c["cols"]
        p = m._parser()
        return {"usage": p.format_usage(), "help": p.format_help()}
    if k == "args":
        os.environ.pop("COLUMNS", None)
        p = m._parser()
        def err(msg): raise ArgErr(msg)
        p.error = err
        try:
            with contextlib.redirect_stdout(io.StringIO()):
                ns = p.parse_args(c["argv"])
            return {"kind": "ok", "ns": {"input": str(ns.input), "output": str(ns.output), "rules": str(ns.rules),
                    "manifest_cli": str(ns.manifest_cli), "timeout": str(ns.timeout), "max_capabilities": str(ns.max_capabilities)}}
        except ArgErr as e: return {"kind": "error", "msg": str(e)}
        except SystemExit: return {"kind": "help"}
    if k == "wrap":
        import textwrap
        return {"lines": textwrap.wrap(" ".join(c["text"].split()), c["width"])}
    raw = bytes.fromhex(c.get("hex", ""))
    try:
        if k == "read":
            with tempfile.TemporaryDirectory() as d:
                p = Path(d) / "stdout.txt"
                p.write_bytes(raw)
                v, e = m._read_stdout_json(p)
            return {"ok": True, "value": canon(v), "err": e, "lone": lone(v)}
        inv, lims = m._build_inventory(json.loads(raw), int(c["max"]))
        return {"ok": True, "value": canon(inv), "lims": lims}
    except Exception as e:
        return {"ok": False}
json.dump([one(c) for c in json.load(sys.stdin)], sys.stdout)
`

type goldenRequest struct {
	Kind  string   `json:"kind"`
	Cols  string   `json:"cols,omitempty"`
	Argv  []string `json:"argv"`
	Hex   string   `json:"hex,omitempty"`
	Max   string   `json:"max,omitempty"`
	Text  string   `json:"text,omitempty"`
	Width int      `json:"width,omitempty"`
}

type goldenAnswer struct {
	Usage string            `json:"usage"`
	Help  string            `json:"help"`
	Kind  string            `json:"kind"`
	Msg   string            `json:"msg"`
	NS    map[string]string `json:"ns"`
	OK    bool              `json:"ok"`
	Value string            `json:"value"`
	Err   *string           `json:"err"`
	Lims  []string          `json:"lims"`
	Lines []string          `json:"lines"`
	Lone  bool              `json:"lone"`
}

// wrapCorpus is hyphenated, long and ordinary words at every width the help text can reach (argparse never wraps
// narrower than 11 columns).
func wrapCorpus() []goldenRequest {
	texts := []string{
		"a", "ab", "abc def", "well-known", "ab-cd", "a-b", "a-bc", "ab-c", "abc-def-ghi", "--flag-name",
		"-x-y", "x-", "ab-", "-ab", "ab-1", "1b-cd", "a_b-c_d", "é-é-éé", "éé-éé", "word-with-many-hyphens-in-it", "super-long-word-without-spaces-whatsoever",
		"a  b   c    d", " leading and trailing ", "path/to/some-file-name.json and more words here",
		"supercalifragilisticexpialidocious", "x supercalifragilisticexpialidocious y", "ab-supercalifragilisticexpialidocious",
		"--------------------", "a-b-c-d-e-f-g-h-i-j", "cap-evidence.v1 no-hyphen double a-b",
		"The maximum number of capabilities to list (default: 500); more are summarized in a limitation.",
		"Wall-clock seconds the analyzer may run before it is killed (default: 600), and a re-run after-the-fact.",
	}
	// a long word around every hyphen context, so that breaking inside it depends on where textwrap may split
	contexts := []string{"ab-cd", "1b-cd", "ab-1d", "a-bcd", "ab-c", "ab-c-d", "a-b-cd", "a-b-c", "_b-cd", "b_-cd", "-b-cd", "b-cd", "ab-_d",
		"a1-cd", "ab-c-", "ab-c-1", "a-b-1d", "1-b-cd", "ab-cd-ef", "x-y-z-w", "ab-", "a-", "-a", "ab-é-d", "éb-cd", "ab-cé", "a-éb-cd", "a-1-cd", "a-1-c-d", "ab-c1d", "ab-c.d", "a.-b-cd"}
	for _, c := range contexts {
		for pre := 0; pre <= 11; pre++ {
			texts = append(texts, strings.Repeat("x", pre)+c+"yyyyyyyyyyyyyyyyyyyy")
		}
	}
	// long unbroken words that contain a hyphen (broken after it) or only leading hyphens (never broken there)
	texts = append(texts, "a-bcdefghijklmnopqrstuvwxyzabcdefgh", "ab-1234567890123456789012345", "1-abcdefghijklmnopqrstuvwxyz1234",
		"--abcdefghijklmnopqrstuvwxyzabcdefgh", "-abcdefghijklmnopqrstuvwxyzabcdefgh", "-----------------------------", "x -abcdefghijklmnopqrstuvwxyzabcdefgh",
		"abcdefghijklmnopqrstuvwxyz-1234567890123456", "abcdefghij-1234567890abcdefghijklmnopqrstuvwxyz")
	var out []goldenRequest
	for _, t := range texts {
		for w := 11; w <= 30; w++ {
			if len(t) < 40 && w > 17 && w < 30 {
				continue // short texts do not need every width
			}
			out = append(out, goldenRequest{Kind: "wrap", Text: t, Width: w})
		}
		out = append(out, goldenRequest{Kind: "wrap", Text: t, Width: 40}, goldenRequest{Kind: "wrap", Text: t, Width: 79})
	}
	return out
}

func askGoldenOracle(t *testing.T, reqs []goldenRequest) []goldenAnswer {
	t.Helper()
	in, _ := json.Marshal(reqs)
	script, _ := filepath.Abs(legacyScript)
	tb, _ := filepath.Abs(toolbeltDir)
	cmd := exec.Command(python312(t), "-I", "-c", goldenOracle, script, tb)
	var out, errb bytes.Buffer
	cmd.Stdin, cmd.Stdout, cmd.Stderr = bytes.NewReader(in), &out, &errb
	if err := cmd.Run(); err != nil {
		t.Fatalf("oracle: %v\n%s", err, errb.String())
	}
	var as []goldenAnswer
	if err := json.Unmarshal(out.Bytes(), &as); err != nil || len(as) != len(reqs) {
		t.Fatalf("oracle output: %v (%d answers for %d requests)", err, len(as), len(reqs))
	}
	return as
}

// ---------------------------------------------------------------- corpora

func usageCorpus() []goldenRequest {
	cols := []string{""}
	for i := 1; i <= 60; i++ {
		cols = append(cols, fmt.Sprint(i))
	}
	for i := 61; i <= 230; i++ {
		cols = append(cols, fmt.Sprint(i))
	}
	cols = append(cols, "150", "200", "abc", "0", "-3", "+80", " 90 ", "1_0", "")
	var out []goldenRequest
	for _, c := range cols[:len(cols)-1] {
		out = append(out, goldenRequest{Kind: "usage", Cols: c})
	}
	return out
}

func argsCorpus() []goldenRequest {
	ok := []string{"--input", "a", "--output", "b", "--manifest-cli", "c"}
	with := func(extra ...string) []string { return append(append([]string{}, ok...), extra...) }
	lines := [][]string{
		nil, {"-h"}, {"--help"}, {"--h"}, {"--he=x"}, {"-hx"}, {"-hfoo"}, {"-h=3"}, {"-h", "--bogus"}, {"--bogus", "-h"}, {"-hh"},
		{"--m", "x"}, {"--ma"}, {"--man=x"}, {"--max=3", "--man=q"}, {"--timeout"}, {"--timeout", "x"}, {"--timeout", "-5"},
		{"--timeout=-1_0"}, {"--timeout=1e3"}, {"--timeout", "-1.5"}, {"--timeout", "--", "5"}, {"--input", "--", "--output", "b"},
		{"--input"}, {"--input", "-a"}, {"--input", "- a"}, {"--input", "-"}, {"-5", "--input", "a"}, {"--input", "a", "-5"},
		{"--foo"}, {"-x", "--input", "a"}, {"-x"}, {"-"}, {"--manifest-cli="}, {"--manifest-cli=", "--input=i", "--output="},
		{"--input", "a", "--input", "b", "--output", "o", "--manifest-cli", "m"}, {"--timeout=x", "--bogus", "--m", "x"},
		{"--input=", "--output", ""}, {"--=x"}, {"--"}, {"--", "--input", "a"}, {"", "--input", "a"}, {"--input", "", "--output", "", "--manifest-cli", ""},
		{"--timeout", "-.5"}, {"--timeout", "-5."}, {"--timeout", "-"}, {"--timeout", "-1x"}, {"--timeout", "-1 "},
		ok, with("extra"), with("--"), with("--", "x"), with("--unk=1", "x"), with("-z"), with("-z", "v"), with("--unk", "v"),
		with("--rules", "~/r//x/"), with("--rules=./r/./x"), with("--input=x y"), with("--output", "/"), with("--output", "a/../b"),
	}
	longs := []string{"help", "input", "output", "rules", "timeout", "max-capabilities", "manifest-cli"}
	for _, l := range longs {
		for n := 1; n <= len(l); n++ {
			p := "--" + l[:n]
			lines = append(lines, []string{p}, []string{p, "7"}, []string{p + "=7"}, with(p, "7"))
		}
	}
	ints := []string{"\x1b7", "\x1c7", "\x1d7", "\x1e7", "\x1f7", "\x207", "7\x1b", "7\x1c", "7\x1f", "7\x20", "\x0b7", "\x0c7", "\xc2\xa07", "\xe2\x80\x837", "\xe3\x80\x807", "0", "1", "-1", "+7", " 7", "7 ", "\t7\n", "1_0", "1__0", "_1", "1_", "0_0", "00", "-0", "+-1", "1e2", "1.0", "0x10",
		"12345678901234567890123456789", "-12345678901234567890123456789", "٣", "١٢", "７", "", " ", "-", "+", "9" + strings.Repeat("0", 4299), "9" + strings.Repeat("0", 4300)}
	for _, v := range ints {
		lines = append(lines, with("--timeout", v), with("--max-capabilities", v), with("--timeout="+v), with("--max-capabilities="+v))
	}
	for _, v := range []string{"a", "a/b", "a//b/", "./a", "../a", "/", "//", "///a", "~", "~u", "a b", "-x", "--y", "-5", "-5.5", "é"} {
		lines = append(lines, with("--input", v), with("--rules="+v), with("--output="+v), with("--manifest-cli", v))
	}
	seen := map[string]bool{}
	var out []goldenRequest
	for _, l := range lines {
		key, _ := json.Marshal(l)
		if !seen[string(key)] {
			seen[string(key)] = true
			out = append(out, goldenRequest{Kind: "args", Argv: append([]string{}, l...)})
		}
	}
	return out
}

const richDoc = `{"rules": {"a b": {"meta": {"namespace": "x/y", "attack": [{"id": "T1"}]}, "matches": [[1, {"k": -2.5e-3}], null, true, false]}}, "s": "@u00e9\n@ud83d@ude00\\\/\b\f\r\t"}`
const shortDoc = `[1, "a\n", {"k": null}, -0.5e+2]`

func jsonCorpus() [][]byte {
	var docs [][]byte
	for _, d := range readCorpus {
		docs = append(docs, []byte(d))
	}
	rs := []rune(strings.ReplaceAll(richDoc, "@u", `\u`))
	for i := 0; i <= len(rs); i++ {
		docs = append(docs, []byte(string(rs[:i])))
	}
	short := []rune(shortDoc)
	for i := range short {
		for _, c := range []rune{'x', '"', '\\', '{', '}', '[', ']', ',', ':', '\n', '0', '-', 'e', '.', ' ', 'u', 'é'} {
			m := append([]rune{}, short...)
			m[i] = c
			docs = append(docs, []byte(string(m)))
		}
		docs = append(docs, []byte(string(short[:i])+string(short[i+1:])))
	}
	for _, n := range []string{"-", "-0", "0", "00", "-00", "1", "10", "-10", "1.5", "1.", "1.e5", ".5", "1e5", "1E5", "1e+5", "1e-5", "1e", "1e+", "1ee5",
		"1.5e", "1.5.5", "0.0", "-0.0", "1e400", "-1e400", "123456789012345678901234567890", "1.7976931348623157e308", "5e-324", "NaN", "-NaN", "Infinity",
		"-Infinity", "Inf", "nan", "+1", "0x1", "1_0", "١", "[1,2", "[1 ,2]", "[ 1 , 2 ]", "[-]", "[--1]", "[1.5,]", "{\"a\":-}", "-9223372036854775808", strings.Repeat("9", 4300), strings.Repeat("9", 4301)} {
		docs = append(docs, []byte(n), []byte("["+n+"]"), []byte(" "+n+" "))
	}
	strs := []string{`""`, `"a"`, `"@u0041"`, `"@u00"`, `"@uzzzz"`, `"@ud800"`, `"@ud800@u0041"`, `"@ud83d@ude00"`, `"@ude00"`, `"@u0000"`, `"\"`, `"\\"`, `"\n"`, `"\x"`,
		"\"a\tb\"", "\"a\x01b\"", "\"a\x1fb\"", "\"a\x7fb\"", `"é"`, `"😀"`, `"/"`, `"\/"`, `"\b\f\n\r\t"`, `"a`, `"a\`, `"a@u`, `"a@u00`, `"a@u004`, `"a@u0041`}
	// every surrogate boundary, alone and followed by every boundary of the other half
	halves := []string{"d7ff", "d800", "dbff", "dc00", "dfff", "e000"}
	for _, h := range halves {
		strs = append(strs, `"@u`+h+`"`, `"@u`+h+`x"`, `"@u`+h+`@u"`, `"@u`+h+`\"`, `"@u`+h+`@u00"`)
		for _, l := range halves {
			strs = append(strs, `"@u`+h+`@u`+l+`"`)
		}
	}
	// every character class around the hex digits, at each of the four positions
	for _, c := range []string{"/", ":", "@", "G", "`", "g", "0", "9", "a", "f", "A", "F", "é"} {
		for p := 0; p < 4; p++ {
			d := []string{"0", "0", "0", "0"}
			d[p] = c
			strs = append(strs, `"@u`+strings.Join(d, "")+`"`)
		}
	}
	for _, s := range strs {
		s = strings.ReplaceAll(s, "@u", `\u`)
		docs = append(docs, []byte(s), []byte("["+s+"]"), []byte("{"+s+": 1}"), []byte("{\"k\": "+s+"}"))
	}
	for _, s := range []string{"", " ", "\t\r\n ", "\xef\xbb\xbf", "\xef\xbb\xbf[]", "\xef\xbb\xbf\xef\xbb\xbf[]", "\xff", "[\xff]", "\xc3\x28", "\xff\xfe", "\xfe\xff", "\xff\xfe[\x00]\x00", "\x00[]", "[\x00]", "\x00\x00\x00[", "[\x00\x00\x00", "\x00[\x00\x00", "[\x00\x00", "\x00\x00[", "\x00[\x00", "\x00\x00\x00\x00",
		"true", "false", "null", "nul", "tru", "fals", "True", "NULL", "truefalse", "nulll", "n", "t", "f", "N", "I", "-I", "{}", "{ }", "{\n}", "{,}", "{:}", "{\"a\"}", "{\"a\":}", "{\"a\":1,}", "{\"a\":1,,}", "{1:2}", "{'a':1}", "[,]", "[1,,2]", "[}", "{]",
		"[[]]", "[[],[]]", "{\"a\":{}}", "{\"a\":[]}", "{\"a\":{\"b\":{\"c\":[1,[2,[3]]]}}}", strings.Repeat("[", 50) + strings.Repeat("]", 50), strings.Repeat("{\"a\":", 30) + "1" + strings.Repeat("}", 30), "1 2", "[] []", "{} x", "//", "/* */ []", "[1]\n\n\n x", "\n\n[1,\n\n2,\n\nx]"} {
		docs = append(docs, []byte(s))
	}
	for _, n := range []int{20000} {
		docs = append(docs, []byte(strings.Repeat("[", n)+strings.Repeat("]", n)), []byte(strings.Repeat(`{"a":`, n)+"1"+strings.Repeat("}", n)))
	}
	seen := map[string]bool{}
	var out [][]byte
	for _, d := range docs {
		if !seen[string(d)] {
			seen[string(d)] = true
			out = append(out, d)
		}
	}
	return out
}

func inventoryDocs() [][]byte {
	var docs [][]byte
	for _, d := range inventoryCorpus {
		docs = append(docs, []byte(d))
	}
	var b strings.Builder
	b.WriteString(`{"rules": {`)
	for i := 0; i < 12; i++ {
		if i > 0 {
			b.WriteString(",")
		}
		fmt.Fprintf(&b, `"rule %02d": {"meta": {"namespace": "ns/%d", "attack": [{"id": "T%d"}], "mbc": [{"id": "B%d"}, {"x": 1}]}, "matches": [[1, {}]]}`, i, i%4, 1000+i, i)
	}
	b.WriteString(`}}`)
	docs = append(docs, []byte(b.String()),
		[]byte(`{"rules": {"b": {"meta": {"namespace": "z"}, "matches": [1]}, "a": {"meta": {"namespace": "z"}, "matches": [1, 2]}, "c": {"meta": {"namespace": "a"}, "matches": ""}}}`),
		[]byte(`{"rules": {"x": {"meta": {"attack": [{"id": true}, {"id": false}, {"id": 0.0}, {"id": 1.5}, {"id": {"k": 1}}, {"id": {}}, {"id": "0"}]}}}}`),
		[]byte(`{"rules": {"x": {"meta": {"mbc": [{"id": "M"}], "attack": []}, "matches": {}}}}`),
		[]byte(`{"rules": {"é": {"meta": {"namespace": "é"}}, "e": {"meta": {"namespace": "e"}}, "z": {"meta": {"namespace": "ê"}}}}`),
		[]byte(`{"rules": {"x": {"meta": {"namespace": ""}}, "y": {"meta": {}}}}`),
		[]byte(`{"rules": {"x": {"meta": {"namespace": "n"}, "matches": [[1,2]], "extra": 1}}, "other": 1}`),
	)
	return docs
}

var inventoryCaps = []string{"1", "2", "3", "4", "12", "500", "9223372036854775807", "9223372036854775808", "123456789012345678901234567890"}

// ---------------------------------------------------------------- the test

// marshalGolden is {"cases": [...]} with one case per line.
func marshalGolden[T any](t *testing.T, cases []T) []byte {
	t.Helper()
	var b bytes.Buffer
	b.WriteString("{\"cases\": [\n")
	for i, c := range cases {
		var line bytes.Buffer
		enc := json.NewEncoder(&line)
		enc.SetEscapeHTML(false)
		if err := enc.Encode(c); err != nil {
			t.Fatal(err)
		}
		b.WriteString("  " + strings.TrimSuffix(line.String(), "\n"))
		if i < len(cases)-1 {
			b.WriteString(",")
		}
		b.WriteString("\n")
	}
	b.WriteString("]}\n")
	return b.Bytes()
}

func TestGoldensMatchOracle(t *testing.T) {
	var reqs []goldenRequest
	var sections [5][2]int // [start, end) of usage, args, jsonread, inventory
	add := func(i int, rs []goldenRequest) {
		sections[i] = [2]int{len(reqs), len(reqs) + len(rs)}
		reqs = append(reqs, rs...)
	}
	add(0, usageCorpus())
	add(1, argsCorpus())
	var read, inv []goldenRequest
	for _, d := range jsonCorpus() {
		read = append(read, goldenRequest{Kind: "read", Hex: hex.EncodeToString(d)})
	}
	for _, d := range inventoryDocs() {
		for _, m := range inventoryCaps {
			inv = append(inv, goldenRequest{Kind: "inventory", Hex: hex.EncodeToString(d), Max: m})
		}
	}
	add(2, read)
	add(3, inv)
	add(4, wrapCorpus())
	as := askGoldenOracle(t, reqs)

	var usage []usageGolden
	for i := sections[0][0]; i < sections[0][1]; i++ {
		usage = append(usage, usageGolden{Cols: reqs[i].Cols, Usage: as[i].Usage, Help: as[i].Help})
	}
	var args []argsGolden
	for i := sections[1][0]; i < sections[1][1]; i++ {
		args = append(args, argsGolden{Argv: reqs[i].Argv, Kind: as[i].Kind, Msg: as[i].Msg, NS: as[i].NS})
	}
	docs := func(sec int) []docGolden {
		var gs []docGolden
		for i := sections[sec][0]; i < sections[sec][1]; i++ {
			raw, _ := hex.DecodeString(reqs[i].Hex)
			g := newDocGolden(raw)
			g.Max, g.OK, g.Value, g.Err, g.Lims, g.Lone = reqs[i].Max, as[i].OK, as[i].Value, as[i].Err, as[i].Lims, as[i].Lone
			gs = append(gs, g)
		}
		return gs
	}
	var wraps []wrapGolden
	for i := sections[4][0]; i < sections[4][1]; i++ {
		wraps = append(wraps, wrapGolden{Text: reqs[i].Text, Width: reqs[i].Width, Lines: as[i].Lines})
	}
	files := map[string][]byte{
		"usage.json":     marshalGolden(t, usage),
		"args.json":      marshalGolden(t, args),
		"jsonread.json":  marshalGolden(t, docs(2)),
		"inventory.json": marshalGolden(t, docs(3)),
		"wrap.json":      marshalGolden(t, wraps),
	}
	for name, want := range files {
		path := goldenDir + name
		if os.Getenv("RSDD_UPDATE_GOLDENS") == "1" {
			if err := os.MkdirAll(goldenDir, 0o755); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(path, want, 0o644); err != nil {
				t.Fatal(err)
			}
			continue
		}
		got, err := os.ReadFile(path)
		if err != nil || !bytes.Equal(got, want) {
			t.Errorf("%s is stale: the legacy oracle answers differently (regenerate with RSDD_UPDATE_GOLDENS=1 and review the diff; read error: %v)", path, err)
		}
	}
}
