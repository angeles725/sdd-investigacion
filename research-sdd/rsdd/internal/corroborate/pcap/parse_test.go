package pcap

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"strings"
	"testing"
)

// canon renders a model value the way the evidence file does.
func canon(t testing.TB, v any) string {
	t.Helper()
	b, err := canonical(v)
	if err != nil {
		t.Fatal(err)
	}
	return strings.TrimSuffix(string(b), "\n")
}

const capinfosSample = `File name:           input/capture.pcap
File type:           Wireshark/tcpdump/... - pcap
File encapsulation:  Ethernet
Number of packets:   1
File size:           86 bytes
Data size:           42 bytes
Capture duration:    0.000000 seconds
`

func TestParseCapinfosSummary(t *testing.T) {
	s, err := parseCapinfos(capinfosSample)
	if err != nil {
		t.Fatal(err)
	}
	want := `{"capture_duration_s":0.0,"data_size_bytes":42,"encapsulation":"Ethernet","file_size_bytes":86,"packet_count":1}`
	if got := canon(t, s.toMap()); got != want {
		t.Fatalf("got %s\nwant %s", got, want)
	}
}

func TestParseCapinfosMissingKeysDefault(t *testing.T) {
	s, err := parseCapinfos("Number of packets:\nnothing here\n")
	if err != nil {
		t.Fatal(err)
	}
	want := `{"capture_duration_s":0.0,"data_size_bytes":0,"encapsulation":"unknown","file_size_bytes":0,"packet_count":0}`
	if got := canon(t, s.toMap()); got != want {
		t.Fatalf("an empty or absent value reads as zero and an absent encapsulation as unknown:\ngot  %s\nwant %s", got, want)
	}
}

func TestParseCapinfosLastDuplicateKeyWins(t *testing.T) {
	s, err := parseCapinfos("Number of packets: 3\nNumber of packets: 9 packets\n")
	if err != nil {
		t.Fatal(err)
	}
	if s.Packets.String() != "9" {
		t.Fatalf("packets = %s, want 9", s.Packets)
	}
}

func TestParseCapinfosUnparseableValuesNameTheToken(t *testing.T) {
	cases := []struct{ name, text, want string }{
		{"int", "Number of packets: 1,234\n", "capinfos output unparseable: invalid literal for int() with base 10: '1,234'"},
		{"float", "Capture duration: soon seconds\n", "capinfos output unparseable: could not convert string to float: 'soon'"},
		{"first failing field wins", "Capture duration: x\nNumber of packets: y\n", "capinfos output unparseable: could not convert string to float: 'x'"},
	}
	for _, c := range cases {
		_, err := parseCapinfos(c.text)
		if err == nil || err.Error() != c.want {
			t.Errorf("%s: got %v, want %q", c.name, err, c.want)
		}
	}
}

const phsSample = `
===================================================================
Protocol Hierarchy Statistics
Filter:

eth                                      frames:2 bytes:84
  ip                                     frames:1 bytes:42
    udp                                  frames:1 bytes:42
  arp                                    frames:1 bytes:42
===================================================================
eth                                      frames:9 bytes:9
`

func TestParseHierarchyLevelsAndStableOrder(t *testing.T) {
	got := canon(t, protocolMaps(parseHierarchy(phsSample)))
	want := `[{"bytes":84,"frames":2,"level":0,"protocol":"eth"},{"bytes":42,"frames":1,"level":1,"protocol":"arp"},` +
		`{"bytes":42,"frames":1,"level":1,"protocol":"ip"},{"bytes":42,"frames":1,"level":2,"protocol":"udp"}]`
	if got != want {
		t.Fatalf("rows sort by (level, protocol) and rows outside the === section are ignored:\ngot  %s\nwant %s", got, want)
	}
}

func TestParseConversationsSwapsDirectionalCounts(t *testing.T) {
	text := "===\nTCP Conversations\n192.168.1.9:80 <-> 192.168.1.2:4321 5 1000 3 200 8 1200\n===\n"
	c := parseConversations(text, "tcp")
	if len(c) != 1 {
		t.Fatalf("rows = %d, want 1", len(c))
	}
	if c[0].EndpointA != "192.168.1.2:4321" || c[0].EndpointB != "192.168.1.9:80" {
		t.Fatalf("endpoints = %s, %s; the smaller string comes first", c[0].EndpointA, c[0].EndpointB)
	}
	if c[0].FramesA2B != "5" || c[0].BytesA2B != "1000" || c[0].FramesB2A != "3" || c[0].BytesB2A != "200" {
		t.Fatalf("frames_a2b=%s bytes_a2b=%s frames_b2a=%s bytes_b2a=%s, want 5 1000 3 200 (swapped with the endpoints)",
			c[0].FramesA2B, c[0].BytesA2B, c[0].FramesB2A, c[0].BytesB2A)
	}
}

func TestParseConversationsKeepsOrderedEndpoints(t *testing.T) {
	text := "===\nTCP Conversations\n192.168.1.2:4321 <-> 192.168.1.9:80 5 1000 3 200 8 1200\n===\n"
	c := parseConversations(text, "tcp")
	if len(c) != 1 || c[0].FramesB2A != "5" || c[0].FramesA2B != "3" || c[0].FramesTotal != "8" || c[0].BytesTotal != "1200" {
		t.Fatalf("an already ordered row keeps its counts: %+v", c)
	}
}

func TestParseConversationsSelectsTheRequestedSection(t *testing.T) {
	text := "===\nTCP Conversations\nb:1 <-> a:2 1 2 3 4 5 6\n===\n" +
		"===\nUDP Conversations\nd:1 <-> c:2 | bytes 10 20 20.5 30 40 | 50 60\n===\n"
	udp := parseConversations(text, "udp")
	if len(udp) != 1 || udp[0].EndpointA != "c:2" || udp[0].FramesTotal != "50" {
		t.Fatalf("udp rows = %+v", udp)
	}
	if tcp := parseConversations(text, "tcp"); len(tcp) != 1 || tcp[0].EndpointA != "a:2" {
		t.Fatalf("tcp rows = %+v", tcp)
	}
}

func TestParseConversationsSkipsShortRows(t *testing.T) {
	text := "===\nTCP Conversations\na:1 <-> b:2 1 2 3 4 5\n===\n"
	if c := parseConversations(text, "tcp"); len(c) != 0 {
		t.Fatalf("a row with fewer than six integers is skipped: %+v", c)
	}
}

func hexOf(s string) string { return hex.EncodeToString([]byte(s)) }

func TestParseFollowOddHexIsIncomplete(t *testing.T) {
	f := parseFollow("===\nNode 0: 127.0.0.1:1\nNode 1: 127.0.0.1:2\nabc\n===\n", "0")
	if f.Complete {
		t.Fatal("an odd-length hex line is a partial reassembly: payload_complete must be false")
	}
}

func TestParseFollowEvenHexIsComplete(t *testing.T) {
	f := parseFollow("===\nNode 0: 127.0.0.1:1\nNode 1: 127.0.0.1:2\n48454c4c4f\n===\n", "0")
	if !f.Complete || f.ClientBytes != 5 || f.ServerBytes != 0 {
		t.Fatalf("complete=%v client=%d server=%d, want true 5 0", f.Complete, f.ClientBytes, f.ServerBytes)
	}
	if f.Client != "127.0.0.1:1" || f.Server != "127.0.0.1:2" {
		t.Fatalf("nodes = %q, %q", f.Client, f.Server)
	}
}

func TestParseFollowDigestCoversBothDirectionsInOrder(t *testing.T) {
	text := "===\nNode 0: c\nNode 1: s\n" + hexOf("GET ") + "\n\t" + hexOf("200") + "\n" + hexOf("more") + "\n===\nignored\n"
	f := parseFollow(text, "7")
	sum := sha256.Sum256([]byte("GET 200more"))
	if f.SHA256 != "sha256:"+hex.EncodeToString(sum[:]) || f.ClientBytes != 8 || f.ServerBytes != 3 || f.Index != json.Number("7") {
		t.Fatalf("follow = %+v", f)
	}
	if got := canon(t, f.toMap()); !strings.Contains(got, `"payload_bytes":11`) {
		t.Fatalf("payload_bytes is client+server: %s", got)
	}
}

func TestPySplitlines(t *testing.T) {
	got := pySplitlines("a\r\nb\rc\x0bd\u0085e f\n")
	want := []string{"a", "b", "c", "d", "e", "f"}
	if strings.Join(got, "|") != strings.Join(want, "|") || len(got) != len(want) {
		t.Fatalf("got %q want %q", got, want)
	}
	if got := pySplitlines(""); len(got) != 0 {
		t.Fatalf("empty text has no lines: %q", got)
	}
}

func TestFromHexMatchesBytesFromhex(t *testing.T) {
	for _, ok := range []string{"", "ab", "AB cd", "ab\tcd\n", " ab"} {
		if _, good := fromHex(ok); !good {
			t.Errorf("%q should parse", ok)
		}
	}
	for _, bad := range []string{"a", "abc", "a b", "zz", "ab é"} {
		if _, good := fromHex(bad); good {
			t.Errorf("%q should be refused", bad)
		}
	}
}

func TestDecodeReplaceReplacesEachMaximalIllFormedSubpart(t *testing.T) {
	cases := map[string]string{
		"a\xffb":       "a�b",
		"\xe2\x82":     "�",  // a truncated 3-byte sequence is one replacement
		"\xe2\x82\x41": "�A", // ... and the byte that broke it survives
		"\xc0\x80":     "��", // 0xC0 is never a lead byte
		"\xf0\x9f\x98": "�",
	}
	for in, want := range cases {
		if got := decodeReplace([]byte(in)); got != want {
			t.Errorf("decodeReplace(%q) = %q, want %q", in, got, want)
		}
	}
}
