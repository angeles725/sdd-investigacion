package serial

import (
	"slices"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// The checksum sub-command of serial-frame-analyze: try the common one- and two-byte frame checksums over the
// last 1 or 2 bytes of every frame (with and without the first byte in the body) and report which validate.

func sum8(b []byte) uint16 {
	var s byte
	for _, c := range b {
		s += c
	}
	return uint16(s)
}

func twosComp8(b []byte) uint16 { return uint16(-byte(sum8(b))) }

func xor8(b []byte) uint16 {
	var x byte
	for _, c := range b {
		x ^= c
	}
	return uint16(x)
}

func crc16Modbus(b []byte) uint16 {
	crc := uint16(0xFFFF)
	for _, c := range b {
		crc ^= uint16(c)
		for range 8 {
			if crc&1 != 0 {
				crc = crc>>1 ^ 0xA001
			} else {
				crc >>= 1
			}
		}
	}
	return crc
}

func crc16CCITT(b []byte) uint16 {
	crc := uint16(0xFFFF)
	for _, c := range b {
		crc ^= uint16(c) << 8
		for range 8 {
			if crc&0x8000 != 0 {
				crc = crc<<1 ^ 0x1021
			} else {
				crc <<= 1
			}
		}
	}
	return crc
}

// checksumResult is one tested algorithm. littleEndian is nil for a one-byte checksum.
type checksumResult struct {
	name         string
	skip         int
	littleEndian *bool
	used, hits   int
}

func (r checksumResult) doc() map[string]any {
	rate := 0.0
	if r.used > 0 {
		rate = roundDigits(float64(r.hits)/float64(r.used), 4)
	}
	d := map[string]any{
		"candidate": r.used > 0 && r.hits == r.used, "hit_count": r.hits, "hit_rate": rate,
		"name": r.name, "skip_first": r.skip, "total_frames": r.used,
	}
	if r.littleEndian != nil {
		d["little_endian"] = *r.littleEndian
	}
	return d
}

// testOneByte checks fn(frame[skip:len-1]) == last byte over the frames that have a body after the skip.
func testOneByte(frames [][]byte, fn func([]byte) uint16, name string, skip int) checksumResult {
	r := checksumResult{name: name, skip: skip}
	for _, fr := range frames {
		if len(fr) > skip+1 {
			r.used++
			if fn(fr[skip:len(fr)-1]) == uint16(fr[len(fr)-1]) {
				r.hits++
			}
		}
	}
	return r
}

// testTwoByte checks a 16-bit checksum stored in the last two bytes, little or big endian.
func testTwoByte(frames [][]byte, fn func([]byte) uint16, name string, littleEndian bool, skip int) checksumResult {
	r := checksumResult{name: name, skip: skip, littleEndian: &littleEndian}
	for _, fr := range frames {
		if len(fr) < skip+3 {
			continue
		}
		r.used++
		hi, lo := uint16(fr[len(fr)-2]), uint16(fr[len(fr)-1])
		want := hi<<8 | lo
		if littleEndian {
			want = lo<<8 | hi
		}
		if fn(fr[skip:len(fr)-2]) == want {
			r.hits++
		}
	}
	return r
}

func (a *analysis) checksum(input string) int {
	fl, ok := a.load(input)
	if !ok {
		return cli.ExitUsage
	}
	if fl.nonBlank > 0 && len(fl.frames) == 0 {
		return a.write(map[string]any{
			"errors": strList(fl.errors), "line_count": fl.nonBlank, "mode": "checksum", "schema": frameSchema,
			"skipped_line_count": len(fl.errors), "status": "failed", "tool": analyzeTool,
		}, cli.ExitOperational)
	}
	var useful [][]byte
	for _, fr := range fl.frames {
		if len(fr) >= 3 {
			useful = append(useful, fr)
		}
	}
	algorithms := []any{}
	if len(useful) > 0 {
		var results []checksumResult
		for skip := range 2 {
			results = append(results,
				testOneByte(useful, sum8, "sum8", skip),
				testOneByte(useful, twosComp8, "twos-comp8", skip),
				testOneByte(useful, xor8, "xor8", skip),
				testTwoByte(useful, crc16Modbus, "crc16-modbus", true, skip),
				testTwoByte(useful, crc16Modbus, "crc16-modbus", false, skip),
				testTwoByte(useful, crc16CCITT, "crc16-ccitt", false, skip))
		}
		slices.SortStableFunc(results, func(x, y checksumResult) int {
			if x.hits != y.hits {
				return y.hits - x.hits
			}
			return strings.Compare(x.name, y.name) // equal keys keep the generated order: skip 0 before skip 1
		})
		for _, r := range results {
			algorithms = append(algorithms, r.doc())
		}
	}
	lengths := map[int]bool{}
	for _, fr := range fl.frames {
		lengths[len(fr)] = true
	}
	doc := map[string]any{
		"input": map[string]any{
			"frame_count": len(fl.frames), "line_count": fl.nonBlank, "path": input, "sha256": fl.sha256,
			"skipped_line_count": len(fl.errors), "useful_frame_count": len(useful),
		},
		"mode":    "checksum",
		"results": map[string]any{"algorithms": algorithms},
		"schema":  frameSchema,
		"status":  "complete",
		"summary": map[string]any{
			"distinct_lengths": len(lengths), "frame_count": len(fl.frames), "line_count": fl.nonBlank,
			"skipped_line_count": len(fl.errors), "truncated": fl.truncated, "useful_frame_count": len(useful),
		},
		"tool":      analyzeTool,
		"truncated": fl.truncated,
	}
	if len(fl.errors) > 0 {
		doc["errors"] = strList(fl.errors)
	}
	return a.write(doc, cli.ExitOK)
}
