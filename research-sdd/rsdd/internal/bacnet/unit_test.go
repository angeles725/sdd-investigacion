package bacnet

import (
	"errors"
	"math"
	"math/big"
	"testing"
	"time"
)

// These tests pin the exact edges of the flag, port, timeout, float and collection-window helpers with plain
// values, so the mutation gate needs neither the Python oracle nor the live-parity files.

func TestFlagStrings(t *testing.T) {
	var nilInt *intFlag
	if got := nilInt.String(); got != "" {
		t.Errorf("nil intFlag: got %q", got)
	}
	if got := (&intFlag{}).String(); got != "" {
		t.Errorf("unset intFlag: got %q", got)
	}
	if got := (&intFlag{v: big.NewInt(-42)}).String(); got != "-42" {
		t.Errorf("set intFlag: got %q", got)
	}
	var nilFloat *floatFlag
	if got := nilFloat.String(); got != "" {
		t.Errorf("nil floatFlag: got %q", got)
	}
	if got := (&floatFlag{v: 2.5}).String(); got != "2.5" {
		t.Errorf("set floatFlag: got %q", got)
	}
}

func TestCheckPortEdges(t *testing.T) {
	cases := []struct {
		name string
		port int64
		bad  bool
	}{
		{"negative one", -1, true},
		{"zero", 0, false},
		{"largest port", 65535, false},
		{"one past the largest", 65536, true},
	}
	for _, c := range cases {
		err := checkPort(big.NewInt(c.port), "sendto")
		if c.bad {
			if err == nil || err.kind != "OverflowError" || err.msg != "sendto(): port must be 0-65535." {
				t.Errorf("%s: got %v", c.name, err)
			}
		} else if err != nil {
			t.Errorf("%s: got %v", c.name, err)
		}
	}
}

func TestCheckTimeoutEdges(t *testing.T) {
	two63 := 9223372036854775808.0
	atLimit := two63 / 1e9 // atLimit*1e9 is exactly 2^63 in float64
	cases := []struct {
		name string
		sec  float64
		kind string
		msg  string
	}{
		{"zero is valid", 0, "", ""},
		{"tiny negative", -1e-9, "ValueError", "Timeout value out of range"},
		{"just below the positive limit", math.Nextafter(atLimit, 0), "", ""},
		{"exactly the positive limit", atLimit, "OverflowError", "timeout value out of range"},
		{"exactly the negative limit is a plain negative", -atLimit, "ValueError", "Timeout value out of range"},
		{"beyond the negative limit", math.Nextafter(-atLimit, math.Inf(-1)), "OverflowError", "timeout value out of range"},
		{"NaN", math.NaN(), "ValueError", "Invalid value NaN (not a number)"},
	}
	for _, c := range cases {
		err := checkTimeout(c.sec)
		switch {
		case c.kind == "" && err != nil:
			t.Errorf("%s: got %v", c.name, err)
		case c.kind != "" && (err == nil || err.kind != c.kind || err.msg != c.msg):
			t.Errorf("%s: got %v", c.name, err)
		}
	}
}

func TestParsePyFloatInfinitySigns(t *testing.T) {
	cases := []struct {
		in   string
		want float64
	}{
		{"inf", math.Inf(1)},
		{"+Infinity", math.Inf(1)},
		{"-inf", math.Inf(-1)},
		{" -INFINITY ", math.Inf(-1)},
	}
	for _, c := range cases {
		got, ok := parsePyFloat(c.in)
		if !ok || got != c.want {
			t.Errorf("%q: got (%v, %v) want %v", c.in, got, ok, c.want)
		}
	}
	if got, ok := parsePyFloat("-nan"); !ok || !math.IsNaN(got) {
		t.Errorf("-nan: got (%v, %v)", got, ok)
	}
}

func TestPySplit(t *testing.T) {
	cases := []struct{ in, head, tail string }{
		{"", "", ""},
		{"x", "", "x"},
		{"/x", "/", "x"},
		{"//x", "//", "x"},
		{"a/b", "a", "b"},
		{"a//b", "a", "b"},
		{"/a/b", "/a", "b"},
		{"a/b/", "a/b", ""},
		{"/", "/", ""},
	}
	for _, c := range cases {
		head, tail := pySplit(c.in)
		if head != c.head || tail != c.tail {
			t.Errorf("%q: got (%q, %q) want (%q, %q)", c.in, head, tail, c.head, c.tail)
		}
	}
}

// windowLink records the deadline of each read, serves its frames, and then fails, which ends the collection.
type windowLink struct {
	deadlines []time.Time
	frames    [][]byte
}

func (w *windowLink) send([]byte, string, *big.Int) error { return nil }
func (w *windowLink) recv(deadline time.Time) (string, []byte, error) {
	w.deadlines = append(w.deadlines, deadline)
	if len(w.frames) == 0 {
		return "", nil, errors.New("timed out")
	}
	f := w.frames[0]
	w.frames = w.frames[1:]
	return "10.0.0.1", f, nil
}
func (w *windowLink) close() {}

func TestCollectWindow(t *testing.T) {
	t0 := time.Unix(1000, 0)
	frozen := func() time.Time { return t0 }
	cases := []struct {
		name   string
		window time.Duration
		reads  int
		wait   time.Duration
	}{
		{"an empty window reads nothing", 0, 0, 0},
		{"a window below the minimum read is stretched to it", 3 * time.Millisecond, 1, minRead},
		{"a window at the minimum read is kept", minRead, 1, minRead},
		{"a longer window is kept", 50 * time.Millisecond, 1, 50 * time.Millisecond},
	}
	for _, c := range cases {
		l := &windowLink{}
		collect(l, frozen, c.window, false)
		if len(l.deadlines) != c.reads {
			t.Errorf("%s: %d reads want %d", c.name, len(l.deadlines), c.reads)
			continue
		}
		if c.reads == 1 && !l.deadlines[0].Equal(t0.Add(c.wait)) {
			t.Errorf("%s: read deadline +%v want +%v", c.name, l.deadlines[0].Sub(t0), c.wait)
		}
	}
}

func TestCollectKeepsBVLCFramesOnly(t *testing.T) {
	iam := mustHex(t, "810b000d0100"+"1000c402000005")
	frozen := func() time.Time { return time.Unix(1000, 0) }
	l := &windowLink{frames: [][]byte{mustHex(t, "ffff"), iam}}
	got := collect(l, frozen, time.Second, true)
	if len(got) != 1 || got[0].ip != "10.0.0.1" || !got[0].hasInst || got[0].inst != 5 {
		t.Fatalf("got %+v", got)
	}
	l = &windowLink{frames: [][]byte{iam}}
	got = collect(l, frozen, time.Second, false)
	if len(got) != 1 || got[0].hasInst {
		t.Fatalf("without wantIAm: got %+v", got)
	}
}
