package bacnet

import (
	"bytes"
	"encoding/hex"
	"reflect"
	"testing"
)

func mustHex(t testing.TB, s string) []byte {
	t.Helper()
	b, err := hex.DecodeString(s)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func TestBuildFrames(t *testing.T) {
	cases := []struct {
		name string
		got  []byte
		want string
	}{
		{"unicast who-is", buildWhoIs(false), "810a000801001008"},
		{"broadcast who-is", buildWhoIs(true), "810b000801001008"},
		{"read-bdt", buildReadBDT(), "81020004"},
		{"read-fdt", buildReadFDT(), "81060004"},
	}
	for _, c := range cases {
		if hex.EncodeToString(c.got) != c.want {
			t.Errorf("%s: got %x want %s", c.name, c.got, c.want)
		}
	}
}

func TestParseBVLC(t *testing.T) {
	cases := []struct {
		name    string
		in      string
		ok      bool
		fn      byte
		payload string
	}{
		{"empty", "", false, 0, ""},
		{"three bytes", "810a00", false, 0, ""},
		{"wrong type byte", "820a00050102", false, 0, ""},
		{"exact length", "810a0007aabbcc", true, 0x0a, "aabbcc"},
		{"trailing bytes beyond the declared length are cut", "810a0006aabbcc", true, 0x0a, "aabb"},
		{"declared length beyond the data keeps all the data", "810b0040aabbcc", true, 0x0b, "aabbcc"},
		{"declared length below the header gives an empty payload", "810b0003aabbcc", true, 0x0b, ""},
		{"header only", "81020004", true, 0x02, ""},
		{"length exactly the data length", "81040005ff", true, 0x04, "ff"},
	}
	for _, c := range cases {
		fn, payload, ok := parseBVLC(mustHex(t, c.in))
		if ok != c.ok || (ok && (fn != c.fn || hex.EncodeToString(payload) != c.payload)) {
			t.Errorf("%s: got fn=%#x payload=%x ok=%v, want fn=%#x payload=%s ok=%v", c.name, fn, payload, ok, c.fn, c.payload, c.ok)
		}
	}
}

func TestExtractIAm(t *testing.T) {
	iam := "1000c402000005" // I-Am, device object 5
	cases := []struct {
		name string
		fn   byte
		pay  string
		inst uint32
		ok   bool
	}{
		{"original unicast", 0x0a, "0100" + iam, 5, true},
		{"original broadcast with trailing bytes", 0x0b, "0100" + iam + "9122", 5, true},
		{"forwarded npdu skips the 6 byte origin", 0x04, "c0a80105bac0" + "0100" + iam, 5, true},
		{"forwarded npdu shorter than the origin", 0x04, "c0a80105ba", 0, false},
		{"forwarded npdu that is only the origin", 0x04, "c0a80105bac0", 0, false},
		{"other function", 0x09, "0100" + iam, 0, false},
		{"npdu of one byte", 0x0a, "01", 0, false},
		{"empty npdu", 0x0a, "", 0, false},
		{"dnet present", 0x0a, "0120" + "000101aa" + "ff" + iam, 5, true},
		{"dnet present but cut", 0x0a, "0120" + "0001", 0, false},
		{"snet present", 0x0a, "0108" + "000101aa" + iam, 5, true},
		{"snet present but cut", 0x0a, "0108" + "0001", 0, false},
		{"dnet and snet", 0x0a, "0128" + "000101aa" + "000102bbcc" + "ff" + iam, 5, true},
		{"dnet with a zero length address", 0x0a, "0120" + "000100" + "ff" + iam, 5, true},
		{"dnet length beyond the data", 0x0a, "0120" + "0001ff" + "ff" + iam, 0, false},
		{"not an unconfirmed request", 0x0a, "0100" + "3000c402000005", 0, false},
		{"unconfirmed but not an I-Am", 0x0a, "0100" + "1008", 0, false},
		{"apdu of one byte", 0x0a, "0100" + "10", 0, false},
		{"body shorter than an object id", 0x0a, "0100" + "1000c4020000", 0, false},
		{"wrong application tag", 0x0a, "0100" + "1000c502000005", 0, false},
		{"analog input object is not a device", 0x0a, "0100" + "1000c400000005", 0, false},
		{"largest instance", 0x0a, "0100" + "1000c4023fffff", 0x3fffff, true},
		{"instance zero", 0x0a, "0100" + "1000c402000000", 0, true},
		{"object type 9", 0x0a, "0100" + "1000c402400005", 0, false},
	}
	for _, c := range cases {
		inst, ok := extractIAm(c.fn, mustHex(t, c.pay))
		if ok != c.ok || inst != c.inst {
			t.Errorf("%s: got (%d, %v) want (%d, %v)", c.name, inst, ok, c.inst, c.ok)
		}
	}
}

func entry(kv ...any) map[string]any {
	m := map[string]any{}
	for i := 0; i < len(kv); i += 2 {
		m[kv[i].(string)] = kv[i+1]
	}
	return m
}

func TestParseBDTAck(t *testing.T) {
	two := "c0a80105bac0ffffff00" + "0a00000cbac1ffff0000"
	got, ok := parseBDTAck(mustHex(t, "81030018"+two))
	want := []map[string]any{
		entry("addr", "192.168.1.5:0xBAC0", "mask", "255.255.255.0"),
		entry("addr", "10.0.0.12:0xBAC1", "mask", "255.255.0.0"),
	}
	if !ok || !reflect.DeepEqual(got, want) {
		t.Errorf("two entries: got %v %v", got, ok)
	}
	// a trailing partial entry (9 bytes) is ignored
	got, ok = parseBDTAck(mustHex(t, "81030021"+two+"010203040506070809"))
	if !ok || !reflect.DeepEqual(got, want) {
		t.Errorf("partial trailing entry: got %v %v", got, ok)
	}
	// an ack with no entries is still an ack: an empty, non-nil list
	got, ok = parseBDTAck(mustHex(t, "81030004"))
	if !ok || got == nil || len(got) != 0 {
		t.Errorf("empty ack: got %#v %v", got, ok)
	}
	// 9 payload bytes are less than one entry
	got, ok = parseBDTAck(mustHex(t, "8103000d010203040506070809"))
	if !ok || got == nil || len(got) != 0 {
		t.Errorf("nine payload bytes: got %#v %v", got, ok)
	}
	// exactly one entry
	got, ok = parseBDTAck(mustHex(t, "8103000ec0a80105bac0ffffff00"))
	if !ok || len(got) != 1 {
		t.Errorf("one entry: got %v %v", got, ok)
	}
	for _, in := range []string{"", "8103", "82030004", "81060004", "810b0004"} {
		if got, ok := parseBDTAck(mustHex(t, in)); ok || got != nil {
			t.Errorf("%q: not a BDT ack, got %v %v", in, got, ok)
		}
	}
}

func TestParseFDTAck(t *testing.T) {
	two := "c0a80109bac0003c0014" + "0a00000dbac10e100001"
	got, ok := parseFDTAck(mustHex(t, "81070018"+two))
	want := []map[string]any{
		entry("addr", "192.168.1.9:0xBAC0", "ttl_s", 60, "remaining_s", 20),
		entry("addr", "10.0.0.13:0xBAC1", "ttl_s", 3600, "remaining_s", 1),
	}
	if !ok || !reflect.DeepEqual(got, want) {
		t.Errorf("two entries: got %v %v", got, ok)
	}
	got, ok = parseFDTAck(mustHex(t, "81070004"))
	if !ok || got == nil || len(got) != 0 {
		t.Errorf("empty ack: got %#v %v", got, ok)
	}
	got, ok = parseFDTAck(mustHex(t, "8107000ec0a80109bac0003c0014"))
	if !ok || len(got) != 1 {
		t.Errorf("one entry: got %v %v", got, ok)
	}
	got, ok = parseFDTAck(mustHex(t, "8107000dc0a80109bac0003c00"))
	if !ok || len(got) != 0 {
		t.Errorf("nine payload bytes: got %v %v", got, ok)
	}
	for _, in := range []string{"", "8107", "82070004", "81030004", "81070004"[:6]} {
		if got, ok := parseFDTAck(mustHex(t, in)); ok || got != nil {
			t.Errorf("%q: not an FDT ack, got %v %v", in, got, ok)
		}
	}
}

func TestSameSlash24(t *testing.T) {
	cases := []struct {
		a, b string
		want bool
	}{
		{"192.168.1.5", "192.168.1.200", true},
		{"192.168.1.5", "192.168.2.5", false},
		{"192.168.1.5", "10.168.1.5", false},
		{"192.168.1.5", "192.169.1.5", false},
		{"192.168.1.5", "192.168.1.5", true},
		{"1.2", "1.2", true},
		{"1.2", "1.3", false},
		{"1.2.3", "1.2.3.4", true},
		{"", "", true},
		{"a.b.c.d", "a.b.c.z", true},
		{"a.b.c.d", "a.b.x.d", false},
	}
	for _, c := range cases {
		if got := sameSlash24(c.a, c.b); got != c.want {
			t.Errorf("sameSlash24(%q, %q) = %v, want %v", c.a, c.b, got, c.want)
		}
	}
}

func TestBuildFramesAreFresh(t *testing.T) {
	// a caller that edits a built frame must not corrupt the next one
	a := buildWhoIs(false)
	a[0] = 0
	if b := buildWhoIs(false); !bytes.Equal(b[:2], []byte{0x81, 0x0a}) {
		t.Errorf("shared backing array: %x", b)
	}
}
