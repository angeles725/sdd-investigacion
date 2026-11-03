package serial

import (
	"reflect"
	"testing"
)

func TestHexFrame(t *testing.T) {
	got, ok := hexFrame([]string{"00", "0", "ff", "FF", "0a", "A", "000ff", "10"})
	if !ok || !reflect.DeepEqual(got, []byte{0, 0, 255, 255, 10, 10, 255, 16}) {
		t.Errorf("hexFrame = %v %v", got, ok)
	}
	for _, bad := range []string{"100", "1ff", "abc", "0100"} {
		if _, ok := hexFrame([]string{"aa", bad}); ok {
			t.Errorf("hexFrame accepted %q", bad)
		}
	}
	for c, want := range map[byte]byte{'0': 0, '9': 9, 'a': 10, 'f': 15, 'A': 10, 'F': 15} {
		if hexNibble(c) != want {
			t.Errorf("hexNibble(%q) = %d", c, hexNibble(c))
		}
	}
}

func TestChecksumPrimitives(t *testing.T) {
	data := []byte("123456789")
	if got := crc16Modbus(data); got != 0x4B37 {
		t.Errorf("crc16Modbus = %#x, want 0x4b37", got)
	}
	if got := crc16CCITT(data); got != 0x29B1 {
		t.Errorf("crc16CCITT = %#x, want 0x29b1", got)
	}
	if crc16Modbus(nil) != 0xFFFF || crc16CCITT(nil) != 0xFFFF {
		t.Error("empty-input CRC must be the initial value")
	}
	if got := sum8([]byte{0xff, 0x02, 0x10}); got != 0x11 {
		t.Errorf("sum8 wraps at 8 bits: %#x", got)
	}
	if got := twosComp8([]byte{0xff, 0x02, 0x10}); got != 0xef {
		t.Errorf("twosComp8 = %#x", got)
	}
	if twosComp8(nil) != 0 || twosComp8([]byte{1}) != 0xff {
		t.Error("twosComp8 edge values")
	}
	if got := xor8([]byte{0xf0, 0x0f, 0x01}); got != 0xfe {
		t.Errorf("xor8 = %#x", got)
	}
	// the algorithm tests: counts, endianness, skip
	le := testTwoByte([][]byte{{0x81, 0x01, 0xa0, 0x20}}, crc16Modbus, "m", true, 0)
	be := testTwoByte([][]byte{{0x81, 0x01, 0xa0, 0x20}}, crc16Modbus, "m", false, 0)
	if le.hits != 1 || le.used != 1 || be.hits != 0 || be.used != 1 {
		t.Errorf("endianness: le=%+v be=%+v", le, be)
	}
	short := testTwoByte([][]byte{{1, 2, 3, 4}, {1, 2, 3}}, crc16Modbus, "m", true, 1)
	if short.used != 1 {
		t.Errorf("a frame shorter than skip+3 is not used: %+v", short)
	}
	one := testOneByte([][]byte{{1, 2, 3}, {1, 2, 3, 4}, {1, 2}}, sum8, "sum8", 1)
	if one.used != 2 {
		t.Errorf("testOneByte skip=1 uses frames longer than 2: %+v", one)
	}
	if r := (checksumResult{}).doc(); r["hit_rate"] != 0.0 || r["candidate"] != false {
		t.Errorf("empty result doc = %v", r)
	}
}
