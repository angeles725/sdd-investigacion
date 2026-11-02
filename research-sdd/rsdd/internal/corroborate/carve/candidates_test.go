package carve

import (
	"bytes"
	"errors"
	"testing"
)

func scan(t *testing.T, data []byte, c caps) ([]candidate, error) {
	t.Helper()
	return findCandidates(bytes.NewReader(data), int64(len(data)), c)
}

var roomy = caps{carves: 16, files: 17, output: 1 << 40}

func TestFindsBothFormatsSortedByOffset(t *testing.T) {
	got, err := scan(t, firmwareImage(), roomy)
	if err != nil {
		t.Fatal(err)
	}
	want := []candidate{{uimageAt, uimageAt + 64 + int64(len(uimagePayload)), kindUImage}, {int64(squashAt), int64(squashAt) + 160, kindSquashFS}}
	if len(got) != 2 || got[0] != want[0] || got[1] != want[1] {
		t.Errorf("candidates = %v, want %v", got, want)
	}
}

func TestRepeatedCandidatesStayBounded(t *testing.T) {
	data := bytes.Repeat(squashfs(), 10000)
	if _, err := scan(t, data, caps{carves: 2, files: 3, output: 1 << 40}); !errors.Is(err, errCandidateCaps) {
		t.Errorf("candidate-count cap: err = %v, want %v", err, errCandidateCaps)
	}
	if _, err := scan(t, data, caps{carves: 16, files: 17, output: 320}); !errors.Is(err, errOutputBytes) {
		t.Errorf("output-bytes cap: err = %v, want %v", err, errOutputBytes)
	}
}

func TestRequiredSquashFSTablesFailClosed(t *testing.T) {
	cases := []struct {
		name   string
		mutate func(b []byte)
	}{
		{"id table absent", func(b []byte) { put64(b[48:], noTable) }},
		{"inode table absent", func(b []byte) { put64(b[64:], noTable) }},
		{"directory table absent", func(b []byte) { put64(b[72:], noTable) }},
		{"export table absent while exportable", func(b []byte) { b[24] = 0x80; put64(b[88:], noTable) }},
		{"fragment table absent while fragments exist", func(b []byte) { b[16] = 1; put64(b[80:], noTable) }},
		{"table past the end", func(b []byte) { put64(b[64:], 160) }},
		{"table inside the superblock", func(b []byte) { put64(b[64:], 95) }},
		{"block size is not 1<<log", func(b []byte) { b[22] = 13 }},
		{"block log too large to shift", func(b []byte) { b[22], b[23] = 200, 0 }},
		{"no inodes", func(b []byte) { b[4] = 0 }},
		{"no ids", func(b []byte) { b[26] = 0 }},
		{"version 3", func(b []byte) { b[28] = 3 }},
		{"minor version", func(b []byte) { b[30] = 1 }},
		{"unknown compressor", func(b []byte) { b[20] = 7 }},
		{"zero compressor", func(b []byte) { b[20] = 0 }},
		{"bytes used below the header", func(b []byte) { put64(b[40:], 95) }},
		{"bytes used overflows the offset", func(b []byte) { put64(b[40:], ^uint64(0)) }},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			s := squashfs()
			tc.mutate(s)
			if got, err := scan(t, s, roomy); err != nil || len(got) != 0 {
				t.Errorf("candidates = %v, err = %v; want none", got, err)
			}
		})
	}
	// Control: an optional table may be absent when nothing requires it.
	if got, _ := scan(t, squashfs(), roomy); len(got) != 1 {
		t.Errorf("valid superblock with absent optional tables found %d candidates, want 1", len(got))
	}
}

func TestUImageMustHaveBothCRCsAndFitTheInput(t *testing.T) {
	good := uimage(uimagePayload)
	cases := []struct {
		name string
		data []byte
	}{
		{"header CRC flipped", flip(good, 20)},
		{"payload CRC flipped", flip(good, len(good)-1)},
		{"payload truncated", good[:len(good)-1]},
		{"header truncated", good[:63]},
	}
	for _, tc := range cases {
		if got, err := scan(t, tc.data, roomy); err != nil || len(got) != 0 {
			t.Errorf("%s: candidates = %v, err = %v; want none", tc.name, got, err)
		}
	}
	if got, _ := scan(t, good, roomy); len(got) != 1 {
		t.Errorf("control: valid uImage found %d candidates, want 1", len(got))
	}
}

func flip(b []byte, i int) []byte {
	c := append([]byte(nil), b...)
	c[i] ^= 0xff
	return c
}

func TestMagicAcrossAWindowBoundaryIsFound(t *testing.T) {
	// The search reads fixed windows; a magic that straddles the boundary must still be seen.
	for _, pad := range []int{scanChunk - 3, scanChunk - 2, scanChunk - 1, scanChunk, scanChunk + 1} {
		data := append(bytes.Repeat([]byte{0}, pad), uimage(uimagePayload)...)
		got, err := scan(t, data, roomy)
		if err != nil || len(got) != 1 || got[0].start != int64(pad) {
			t.Errorf("pad %d: candidates = %v, err = %v", pad, got, err)
		}
	}
}

func TestEmptyAndMagiclessInputsFindNothing(t *testing.T) {
	for _, data := range [][]byte{nil, []byte("hs"), bytes.Repeat([]byte("x"), 1000)} {
		if got, err := scan(t, data, roomy); err != nil || len(got) != 0 {
			t.Errorf("%d bytes: candidates = %v, err = %v", len(data), got, err)
		}
	}
}
