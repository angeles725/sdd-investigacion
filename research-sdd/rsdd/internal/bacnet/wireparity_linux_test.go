//go:build linux && !nodiff

package bacnet

import (
	"bytes"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"math/rand/v2"
	"os/exec"
	"path/filepath"
	"testing"
)

// The legacy corroborate_bacnet.py is the oracle: testdata/parity_driver.py runs its real frame builders and
// parsers over a batch of cases in one process and the Go functions must agree on every one of them.

const toolbelt = "../../../toolbelt"

// runPy runs the legacy driver; a missing python3 FAILS the test (a skipped parity test proves nothing).
func runPy(t testing.TB, op string, cases any, into any) {
	t.Helper()
	py, err := exec.LookPath("python3")
	if err != nil {
		t.Fatalf("python3 is required for the parity tests and was not found: %v", err)
	}
	tb, err := filepath.Abs(toolbelt)
	if err != nil {
		t.Fatal(err)
	}
	in, err := json.Marshal(cases)
	if err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command(py, "-I", "testdata/parity_driver.py", tb, op)
	var out, stderr bytes.Buffer
	cmd.Stdin, cmd.Stdout, cmd.Stderr = bytes.NewReader(in), &out, &stderr
	if err := cmd.Run(); err != nil {
		t.Fatalf("driver %s failed: %v\n%s", op, err, stderr.String())
	}
	dec := json.NewDecoder(bytes.NewReader(out.Bytes()))
	dec.UseNumber()
	if err := dec.Decode(into); err != nil {
		t.Fatalf("driver output: %v", err)
	}
}

func TestParityBuildFrames(t *testing.T) {
	kinds := []string{"unicast", "broadcast", "bdt", "fdt"}
	cases := make([]map[string]string, len(kinds))
	for i, k := range kinds {
		cases[i] = map[string]string{"kind": k}
	}
	var res []struct {
		Hex string `json:"hex"`
	}
	runPy(t, "build", cases, &res)
	got := [][]byte{buildWhoIs(false), buildWhoIs(true), buildReadBDT(), buildReadFDT()}
	for i, k := range kinds {
		if hex.EncodeToString(got[i]) != res[i].Hex {
			t.Errorf("%s: go %x, python %s", k, got[i], res[i].Hex)
		}
	}
}

// frameCorpus is a seeded mix of fully random bytes and structured frames (valid BVLC headers over NPDUs with
// every control-flag combination, I-Am bodies, and BDT/FDT acks with ragged lengths).
func frameCorpus(n int) [][]byte {
	r := rand.New(rand.NewPCG(2438, 1))
	rb := func(k int) []byte {
		b := make([]byte, k)
		for i := range b {
			b[i] = byte(r.IntN(256))
		}
		return b
	}
	bvlc := func(fn byte, payload []byte, lenDelta int) []byte {
		l := 4 + len(payload) + lenDelta
		if l < 0 {
			l = 0
		}
		return append([]byte{0x81, fn, byte(l >> 8), byte(l)}, payload...)
	}
	iam := func(typ uint32, inst uint32) []byte {
		id := typ<<22 | inst&0x3fffff
		return []byte{0x10, 0x00, 0xc4, byte(id >> 24), byte(id >> 16), byte(id >> 8), byte(id)}
	}
	var out [][]byte
	for len(out) < n {
		switch r.IntN(6) {
		case 0:
			out = append(out, rb(r.IntN(24)))
		case 1: // header with random fn over random payload and a wrong length
			out = append(out, bvlc(byte(r.IntN(10)), rb(r.IntN(16)), r.IntN(7)-3))
		case 2: // NPDU with random control byte, random DNET/SNET bytes, then an I-Am
			npdu := append([]byte{1, byte(r.IntN(256))}, rb(r.IntN(12))...)
			if r.IntN(2) == 0 {
				npdu = append(npdu, iam(uint32(r.IntN(10)), r.Uint32())...)
			}
			fn := []byte{0x0a, 0x0b, 0x04}[r.IntN(3)]
			if fn == 0x04 {
				npdu = append(rb(r.IntN(8)), npdu...)
			}
			out = append(out, bvlc(fn, npdu, r.IntN(3)-1))
		case 3: // clean I-Am, optionally behind a DNET/SNET
			npdu := []byte{1, []byte{0, 0x20, 0x08, 0x28}[r.IntN(4)]}
			if npdu[1]&0x20 != 0 {
				npdu = append(npdu, 0, 1, 2, 9, 9)
			}
			if npdu[1]&0x08 != 0 {
				npdu = append(npdu, 0, 1, 1, 7)
			}
			if npdu[1]&0x20 != 0 {
				npdu = append(npdu, 0xff)
			}
			npdu = append(npdu, iam(8, r.Uint32())...)
			out = append(out, bvlc(0x0a, npdu, 0))
		case 4: // BDT ack with whole and partial entries
			out = append(out, bvlc(0x03, rb(r.IntN(45)), 0))
		default: // FDT ack
			out = append(out, bvlc(0x07, rb(r.IntN(45)), 0))
		}
	}
	return out
}

func TestParityParse(t *testing.T) {
	frames := frameCorpus(1500)
	cases := make([]string, len(frames))
	for i, f := range frames {
		cases[i] = hex.EncodeToString(f)
	}
	var res []struct {
		Fn      *int             `json:"fn"`
		Payload *string          `json:"payload"`
		Inst    *int64           `json:"inst"`
		BDT     []map[string]any `json:"bdt"`
		FDT     []map[string]any `json:"fdt"`
	}
	runPy(t, "parse", cases, &res)
	if len(res) != len(frames) {
		t.Fatalf("driver returned %d results for %d cases", len(res), len(frames))
	}
	var sawInst, sawBDT, sawFDT, sawEmpty int
	for i, f := range frames {
		fn, payload, ok := parseBVLC(f)
		r := res[i]
		if ok != (r.Fn != nil) {
			t.Fatalf("case %d %x: parseBVLC ok=%v, python has a frame: %v", i, f, ok, r.Fn != nil)
		}
		if ok {
			if int(fn) != *r.Fn || hex.EncodeToString(payload) != *r.Payload {
				t.Fatalf("case %d %x: go fn=%#x payload=%x, python fn=%#x payload=%s", i, f, fn, payload, *r.Fn, *r.Payload)
			}
			inst, iok := extractIAm(fn, payload)
			if iok != (r.Inst != nil) || (iok && int64(inst) != *r.Inst) {
				t.Fatalf("case %d %x: go I-Am (%d,%v), python has one: %v", i, f, inst, iok, r.Inst != nil)
			}
			if iok {
				sawInst++
			}
		}
		for _, p := range []struct {
			name string
			got  func([]byte) ([]map[string]any, bool)
			want []map[string]any
			cnt  *int
		}{{"bdt", parseBDTAck, r.BDT, &sawBDT}, {"fdt", parseFDTAck, r.FDT, &sawFDT}} {
			got, gok := p.got(f)
			if gok != (p.want != nil) {
				t.Fatalf("case %d %x: %s ack ok=%v, python %v", i, f, p.name, gok, p.want)
			}
			if gok {
				*p.cnt++
				if len(got) == 0 {
					sawEmpty++
				}
				if !sameEntries(got, p.want) {
					t.Fatalf("case %d %x: %s go %v python %v", i, f, p.name, got, p.want)
				}
			}
		}
	}
	// the corpus must exercise every branch it is meant to compare, or a green run proves little
	if sawInst < 100 || sawBDT < 100 || sawFDT < 100 || sawEmpty < 5 {
		t.Fatalf("corpus too thin: I-Am %d, BDT %d, FDT %d, empty acks %d", sawInst, sawBDT, sawFDT, sawEmpty)
	}
}

// sameEntries compares Go entries (int values) with the driver's JSON (json.Number values).
func sameEntries(got, want []map[string]any) bool {
	if len(got) != len(want) {
		return false
	}
	for i := range got {
		if len(got[i]) != len(want[i]) {
			return false
		}
		for k, v := range got[i] {
			w, ok := want[i][k]
			if !ok || fmt.Sprint(v) != fmt.Sprint(w) {
				return false
			}
		}
	}
	return true
}

func TestParitySameSlash24(t *testing.T) {
	pool := []string{"192.168.1.5", "192.168.1.9", "192.168.2.5", "10.0.0.1", "1.2", "1.2.3", "1.2.3.4", "", "a.b.c.d", "a.b.c", "1.2.4.4", "...", "1..3.4"}
	var cases [][2]string
	for _, a := range pool {
		for _, b := range pool {
			cases = append(cases, [2]string{a, b})
		}
	}
	var res []struct {
		Same bool `json:"same"`
	}
	runPy(t, "same24", cases, &res)
	for i, c := range cases {
		if got := sameSlash24(c[0], c[1]); got != res[i].Same {
			t.Errorf("sameSlash24(%q, %q) = %v, python %v", c[0], c[1], got, res[i].Same)
		}
	}
}
