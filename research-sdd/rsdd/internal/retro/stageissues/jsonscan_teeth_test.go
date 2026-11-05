package stageissues

import (
	"strings"
	"testing"
)

// esc turns the @ markers into backslashes, so the JSON \u escapes survive any tooling that decodes them.
func esc(s string) string { return strings.ReplaceAll(s, "@", "\x5c") }

// Pure unit tests (no build tag, no host tools) that pin the exact output of the JSON tokenizer, so a mutated
// boundary or arithmetic operator changes a value the test compares (kit issue #2592).

func TestJSONIssueScanExactOutputs(t *testing.T) {
	sigReply := `[{"number":1,"state":"OPEN","body":"a\nSIG\nb"},{"number":2,"state":"CLOSED","body":"SIG"},{"number":3,"state":"OPEN","body":"none"}]`
	cases := []struct {
		name  string
		mode  scanMode
		reply string
		want  string
	}{
		{"sig joins hits with one comma", scanSig, sigReply, "[{\"state\":\"OPEN\"},{\"state\":\"CLOSED\"}]\ntotal=3\n"},
		{"sig single hit has no comma", scanSig, `[{"state":"OPEN","body":"SIG"}]`, "[{\"state\":\"OPEN\"}]\ntotal=1\n"},
		{"sigs lists number and state", scanSigs, sigReply, "1 OPEN\n2 CLOSED\ntotal=3\n"},
		{"occ keeps a zero number and joins with one space", scanOcc,
			`[{"number":0,"state":"OPEN","title":"T"},{"number":12,"state":"OPEN","title":"T"},{"number":3,"state":"CLOSED","title":"T"}]`,
			"0 12\ntotal=3\n"},
		{"occ single hit has no leading space", scanOcc, `[{"number":7,"state":"OPEN","title":"T"}]`, "7\ntotal=1\n"},
		{"occ fields never leak into the next object", scanOcc,
			`[{"number":1,"state":"OPEN","title":"T"},{"number":2}]`, "1\ntotal=2\n"},
		{"unicode escapes decode to ascii, middle dot or a question mark", scanOcc,
			esc(`[{"number":5,"state":"OPEN","title":"A@u0042@u00b7@u00e9@u00zz"}]`), "5\ntotal=1\n"},
	}
	for _, c := range cases {
		needle := "T"
		if c.mode != scanOcc {
			needle = "SIG"
		}
		if c.name[:7] == "unicode" {
			needle = "AB·??"
		}
		got, err := jsonIssueScan(c.mode, needle, c.reply)
		if err != nil || got != c.want {
			t.Errorf("%s: got %q err %v, want %q", c.name, got, err, c.want)
		}
	}
}

func TestHexvalValues(t *testing.T) {
	for in, want := range map[string]int{
		"": 0, "0": 0, "9": 9, "a": 10, "f": 15, "A": 10, "F": 15,
		"41": 65, "00b7": 183, "00B7": 183, "ffff": 65535, "g": -1, "1g": -1, "00zz": -1,
	} {
		if got := hexval(in); got != want {
			t.Errorf("hexval(%q) = %d, want %d", in, got, want)
		}
	}
}

func TestIsDigitsValues(t *testing.T) {
	for in, want := range map[string]bool{"": false, "0": true, "9": true, "12": true, "a": false, "1a": false, "a1": false} {
		if got := isDigits(in); got != want {
			t.Errorf("isDigits(%q) = %v, want %v", in, got, want)
		}
	}
}
