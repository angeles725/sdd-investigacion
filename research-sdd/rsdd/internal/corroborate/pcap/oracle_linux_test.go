//go:build linux && !nodiff

package pcap

import (
	"bytes"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
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

type oracleResult struct {
	OK    bool   `json:"ok"`
	Canon string `json:"canon"`
	Msg   string `json:"msg"`
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

// TestOracleParsers holds every Go parser to the real Python function on the same cases. With
// RSDD_UPDATE_GOLDENS=1 it freezes the answers under testdata/goldens; otherwise it asserts the committed goldens
// are still what the legacy parsers answer.
func TestOracleParsers(t *testing.T) {
	update := os.Getenv("RSDD_UPDATE_GOLDENS") == "1"
	for _, s := range parseSuites() {
		t.Run(s.op, func(t *testing.T) {
			want := runOracle(t, s.op, s.cases)
			rows := make([]parseGolden, len(s.cases))
			bad := 0
			for i, c := range s.cases {
				w := want[i]
				rows[i] = parseGolden{Text: c.Text, Proto: c.Proto, Idx: c.Idx, OK: w.OK, Canon: w.Canon, Msg: w.Msg}
				canonical, msg := s.got(c)
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
				t.Fatalf("%d of %d cases differ from the legacy parser", bad, len(s.cases))
			}
			if update {
				writeParseGolden(t, s.file, rows)
			} else if !reflect.DeepEqual(rows, readParseGolden(t, s.file)) {
				t.Errorf("%s no longer equals what the legacy parser answers", s.file)
			}
		})
	}
}
