package carve

import (
	"bytes"
	"encoding/binary"
	"errors"
	"io"
	"os"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// recordingReader serves zeros and remembers every ReadAt it was asked for.
type recordingReader struct {
	size int64
	lens []int
	offs []int64
}

func (r *recordingReader) ReadAt(p []byte, off int64) (int, error) {
	r.lens = append(r.lens, len(p))
	r.offs = append(r.offs, off)
	n := int64(len(p))
	if off+n > r.size {
		n = r.size - off
	}
	clear(p[:n])
	if n < int64(len(p)) {
		return int(n), io.EOF
	}
	return int(n), nil
}

func TestCapsAreInclusiveAndCountEachRangeByItsLength(t *testing.T) {
	// A SquashFS of 160 bytes behind a 4-byte prefix: the byte total is its length, not its end offset.
	data := append([]byte("PFX!"), squashfs()...)
	if got, err := scan(t, data, caps{carves: 16, files: 17, output: 160}); err != nil || len(got) != 1 {
		t.Errorf("output cap equal to the carved bytes: candidates = %v, err = %v; want one", got, err)
	}
	if _, err := scan(t, data, caps{carves: 16, files: 17, output: 159}); !errors.Is(err, errOutputBytes) {
		t.Errorf("one byte over the output cap: err = %v, want %v", err, errOutputBytes)
	}
	// One range needs room for itself and the report: files = ranges + 2.
	if got, err := scan(t, data, caps{carves: 1, files: 2, output: 1 << 40}); err != nil || len(got) != 1 {
		t.Errorf("files cap of exactly range+2: candidates = %v, err = %v; want one", got, err)
	}
	if _, err := scan(t, data, caps{carves: 1, files: 1, output: 1 << 40}); !errors.Is(err, errCandidateCaps) {
		t.Errorf("files cap below range+2: err = %v, want %v", err, errCandidateCaps)
	}
}

func TestUImageCapsAndMultipleUImages(t *testing.T) {
	data := bytes.Repeat(uimage(uimagePayload), 10)
	if _, err := scan(t, data, caps{carves: 2, files: 3, output: 1 << 40}); !errors.Is(err, errCandidateCaps) {
		t.Errorf("uImage candidate-count cap: err = %v, want %v", err, errCandidateCaps)
	}
	if _, err := scan(t, data, caps{carves: 16, files: 17, output: 100}); !errors.Is(err, errOutputBytes) {
		t.Errorf("uImage output-bytes cap: err = %v, want %v", err, errOutputBytes)
	}
	got, err := scan(t, data, roomy)
	if err != nil || len(got) != 10 {
		t.Fatalf("ten uImages: candidates = %d, err = %v; want 10", len(got), err)
	}
	for i, c := range got {
		if c.start != int64(i*(64+len(uimagePayload))) || c.kind != kindUImage {
			t.Errorf("candidate %d = %+v", i, c)
		}
	}
}

func TestUImageWithAnEmptyPayloadEndingTheInputIsFound(t *testing.T) {
	got, err := scan(t, uimage(""), roomy)
	if err != nil || len(got) != 1 || got[0] != (candidate{0, 64, kindUImage}) {
		t.Errorf("header-only uImage: candidates = %v, err = %v", got, err)
	}
}

func TestSquashFSEdgesOfTheStructuralCheckAreAccepted(t *testing.T) {
	cases := []struct {
		name   string
		mutate func(b []byte)
	}{
		{"compressor 6", func(b []byte) { b[20] = 6 }},
		{"compressor 1", func(b []byte) { b[20] = 1 }},
		{"largest block size (log 20)", func(b []byte) {
			binary.LittleEndian.PutUint32(b[12:], 1<<20)
			b[22] = 20
		}},
		{"smallest block size (log 12)", func(b []byte) {}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			s := squashfs()
			tc.mutate(s)
			if got, err := scan(t, s, roomy); err != nil || len(got) != 1 {
				t.Errorf("candidates = %v, err = %v; want one", got, err)
			}
		})
	}
	for _, tc := range []struct {
		name  string
		block uint32
		log   byte
	}{{"log 21", 1 << 21, 21}, {"log 11", 1 << 11, 11}} {
		s := squashfs()
		binary.LittleEndian.PutUint32(s[12:], tc.block)
		s[22] = tc.log
		if got, err := scan(t, s, roomy); err != nil || len(got) != 0 {
			t.Errorf("%s: candidates = %v, err = %v; want none", tc.name, got, err)
		}
	}
}

func TestMagicWithoutRoomForAHeaderIsIgnoredNotAnError(t *testing.T) {
	for _, data := range [][]byte{[]byte("hsqs"), []byte("xxhsqs"), uimageMagic, append([]byte("x"), uimageMagic...), squashfs()[:95]} {
		if got, err := scan(t, data, roomy); err != nil || len(got) != 0 {
			t.Errorf("%d bytes: candidates = %v, err = %v; want none", len(data), got, err)
		}
	}
}

func TestFindStaysInsideTheDeclaredSize(t *testing.T) {
	data := append(make([]byte, 8), []byte("hsqs")...)
	if off, err := find(bytes.NewReader(data), 10, squashfsMagic, 0); off != -1 || err != nil {
		t.Errorf("a magic straddling the declared size: off = %d, err = %v; want -1, nil", off, err)
	}
	if off, err := find(bytes.NewReader(data), int64(len(data)), squashfsMagic, 0); off != 8 || err != nil {
		t.Errorf("control: off = %d, err = %v; want 8, nil", off, err)
	}
}

func TestFindToleratesAShortReaderOnlyWhenItGaveBytes(t *testing.T) {
	short := bytes.NewReader(make([]byte, 10))
	if off, err := find(short, 100, squashfsMagic, 0); off != -1 || err != nil {
		t.Errorf("a reader shorter than the size, window with data: off = %d, err = %v; want -1, nil", off, err)
	}
	if off, err := find(short, 100, squashfsMagic, 50); off != -1 || !errors.Is(err, io.EOF) {
		t.Errorf("a window past the end of the reader: off = %d, err = %v; want -1, EOF", off, err)
	}
}

func TestFindReadsOneBoundedOverlappingWindowAtATime(t *testing.T) {
	r := &recordingReader{size: 2*scanChunk + 10}
	if off, err := find(r, r.size, squashfsMagic, 0); off != -1 || err != nil {
		t.Fatalf("off = %d, err = %v", off, err)
	}
	wantLens := []int{scanChunk + 3, scanChunk + 3, 10}
	wantOffs := []int64{0, scanChunk, 2 * scanChunk}
	if !slices.Equal(r.lens, wantLens) || !slices.Equal(r.offs, wantOffs) {
		t.Errorf("windows = lens %v offs %v, want lens %v offs %v", r.lens, r.offs, wantLens, wantOffs)
	}
}

func TestOutputPathWithoutAComponentIsRefusedNotACrash(t *testing.T) {
	w := newWorld(t)
	in := w.write("firmware.bin", firmwareImage())
	for _, out := range []string{".", "./", "/"} {
		if code := w.carve(in, out); code != 2 || !strings.Contains(w.err.String(), "output must be a new canonical path in a private owned directory") {
			t.Errorf("output %q: exit %d stderr %q", out, code, w.err.String())
		}
	}
}

func TestWorkerEnvironmentIsTheCallersWhenGivenAndInheritedOtherwise(t *testing.T) {
	w := newWorld(t)
	in := w.write("firmware.bin", firmwareImage())
	var got launchSpec
	inner := w.d.launch
	w.d.launch = func(sp launchSpec) error { got = sp; return inner(sp) }
	w.d.self = func() (string, error) { return "/rsdd", nil }

	w.mustCarve(in, w.path("with-env"))
	if got.env == nil || !slices.Equal(got.env, os.Environ()) {
		t.Errorf("spec.env = %v, want the caller's environment", got.env)
	}

	got = launchSpec{}
	var out, errb bytes.Buffer
	args := []string{"--input", in, "--output", w.path("no-env")}
	if code := execute(args, cli.Stdio{Out: &out, Err: &errb, Cwd: w.root, Clock: time.Now}, w.d); code != 0 {
		t.Fatalf("exit %d, stderr %q", code, errb.String())
	}
	if got.env != nil {
		t.Errorf("spec.env = %v, want nil (inherit) when the caller gives no Environ", got.env)
	}
}
