package bacnet

import "testing"

// TestWireBoundaryFrames pins frames that sit exactly on a length limit of the parsers.
func TestWireBoundaryFrames(t *testing.T) {
	iam := "1000c402000005"
	cases := []struct {
		name string
		fn   byte
		pay  string
		inst uint32
		ok   bool
	}{
		{"npdu of exactly two bytes", 0x0a, "0100", 0, false},
		{"forwarded payload of exactly six bytes", 0x04, "c0a80105bac0", 0, false},
		{"dnet specifier ends the npdu", 0x0a, "0120" + "000100", 0, false},
		{"dnet specifier and hop count end the npdu", 0x0a, "0120" + "000100" + "ff", 0, false},
		{"snet specifier ends the npdu", 0x0a, "0108" + "000100", 0, false},
		{"dnet then snet specifier ends the npdu", 0x0a, "0128" + "000100" + "000100", 0, false},
		{"snet specifier one byte short", 0x0a, "0108" + "0001", 0, false},
		{"I-Am apdu of exactly two bytes", 0x0a, "0100" + "1000", 0, false},
		{"I-Am apdu with a five byte body", 0x0a, "0100" + iam, 5, true},
	}
	for _, c := range cases {
		inst, ok := extractIAm(c.fn, mustHex(t, c.pay))
		if ok != c.ok || inst != c.inst {
			t.Errorf("%s: got (%d, %v) want (%d, %v)", c.name, inst, ok, c.inst, c.ok)
		}
	}
	for _, c := range []struct {
		in   string
		want bool
	}{{"1000", false}, {"10", false}, {"", false}, {"1000c402000005", true}} {
		if _, ok := parseIAm(mustHex(t, c.in)); ok != c.want {
			t.Errorf("parseIAm(%q): ok=%v want %v", c.in, ok, c.want)
		}
	}
	if got := first3("1.2.3"); len(got) != 3 || got[2] != "3" {
		t.Errorf("first3 of three fields: %v", got)
	}
	if got := first3("1.2.3.4"); len(got) != 3 || got[2] != "3" {
		t.Errorf("first3 of four fields: %v", got)
	}
	if !sameSlash24("1.2.3", "1.2.3.9") || sameSlash24("1.2", "1.2.3") {
		t.Errorf("sameSlash24 with short or long addresses")
	}
}
