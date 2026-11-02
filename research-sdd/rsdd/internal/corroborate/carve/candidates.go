package carve

import (
	"bytes"
	"cmp"
	"encoding/binary"
	"errors"
	"hash/crc32"
	"io"
	"slices"
	"strings"
)

// Candidate kinds, as they appear in the report and in the carved file names.
const (
	kindUImage   = "uimage"
	kindSquashFS = "squashfs-v4-le"
)

const (
	uimageHeader   = 64
	squashfsHeader = 96
	scanChunk      = 1 << 20
	noTable        = ^uint64(0) // SquashFS "table absent" marker
	flagExportable = 0x80
)

var (
	uimageMagic   = []byte{0x27, 0x05, 0x19, 0x56}
	squashfsMagic = []byte("hsqs")

	errCandidateCaps = errors.New("candidate count exceeds output caps")
	errOutputBytes   = errors.New("carved bytes exceed max-output-bytes")
)

// candidate is one validated byte range [start, end) of the input.
type candidate struct {
	start, end int64
	kind       string
}

// caps bounds how many ranges, files and bytes a scan may accept.
type caps struct{ carves, files, output int64 }

// collector is the port of the add() closure: it counts accepted ranges and bytes against the caps. The count
// is checked before the bytes, as the script does, so the first cap that trips decides the message.
type collector struct {
	caps  caps
	found []candidate
	bytes int64
}

func (c *collector) add(item candidate) error {
	c.bytes += item.end - item.start
	n := int64(len(c.found))
	if n >= c.caps.carves || n+2 > c.caps.files {
		return errCandidateCaps
	}
	if c.bytes > c.caps.output {
		return errOutputBytes
	}
	c.found = append(c.found, item)
	return nil
}

// findCandidates scans size bytes of r for validated uImage and SquashFS v4 little-endian ranges and returns
// them sorted by (offset, kind, end). Reads are bounded: a fixed-size window for the magic search, the header
// for validation and a streamed CRC for the payload, so the input is never held in memory.
func findCandidates(r io.ReaderAt, size int64, limit caps) ([]candidate, error) {
	col := &collector{caps: limit}
	if err := scanUImage(r, size, col); err != nil {
		return nil, err
	}
	if err := scanSquashFS(r, size, col); err != nil {
		return nil, err
	}
	slices.SortFunc(col.found, func(a, b candidate) int {
		return cmp.Or(cmp.Compare(a.start, b.start), strings.Compare(a.kind, b.kind), cmp.Compare(a.end, b.end))
	})
	return col.found, nil
}

func scanUImage(r io.ReaderAt, size int64, col *collector) error {
	for from := int64(0); ; {
		offset, err := find(r, size, uimageMagic, from)
		if err != nil || offset < 0 {
			return err
		}
		from = offset + 1
		if offset+uimageHeader > size {
			continue
		}
		var header [uimageHeader]byte
		if _, err := r.ReadAt(header[:], offset); err != nil {
			return err
		}
		recorded := binary.BigEndian.Uint32(header[4:8])
		clear(header[4:8])
		length := int64(binary.BigEndian.Uint32(header[12:16]))
		payloadCRC := binary.BigEndian.Uint32(header[24:28])
		end := offset + uimageHeader + length
		if end > size || crc32.ChecksumIEEE(header[:]) != recorded {
			continue
		}
		sum, err := crcRange(r, offset+uimageHeader, end)
		if err != nil {
			return err
		}
		if sum == payloadCRC {
			if err := col.add(candidate{offset, end, kindUImage}); err != nil {
				return err
			}
		}
	}
}

// squashSuper holds the SquashFS v4 superblock fields the structural check reads.
type squashSuper struct {
	inodes, block, fragments                uint32
	compression, log, flags, ids, major, mi uint16
	used, idTable, xattr, inodeTable        uint64
	dirTable, fragTable, exportTable        uint64
}

func parseSuper(b []byte) squashSuper {
	le := binary.LittleEndian
	return squashSuper{
		inodes: le.Uint32(b[4:]), block: le.Uint32(b[12:]), fragments: le.Uint32(b[16:]),
		compression: le.Uint16(b[20:]), log: le.Uint16(b[22:]), flags: le.Uint16(b[24:]), ids: le.Uint16(b[26:]),
		major: le.Uint16(b[28:]), mi: le.Uint16(b[30:]),
		used: le.Uint64(b[40:]), idTable: le.Uint64(b[48:]), xattr: le.Uint64(b[56:]), inodeTable: le.Uint64(b[64:]),
		dirTable: le.Uint64(b[72:]), fragTable: le.Uint64(b[80:]), exportTable: le.Uint64(b[88:]),
	}
}

// valid is the structural check: version 4.0, a known compressor, a power-of-two block size matching its log,
// a byte range inside the input, every table offset absent or inside the image, and the tables the flags
// require actually present.
func (s squashSuper) valid(offset, size int64) bool {
	if s.inodes == 0 || s.ids == 0 || s.major != 4 || s.mi != 0 || s.compression < 1 || s.compression > 6 {
		return false
	}
	// A block size of 4096..1048576 that is exactly 1<<log means log is 12..20.
	if s.log < 12 || s.log > 20 || s.block != 1<<s.log {
		return false
	}
	// A used count below the header needs no check of its own: the required tables must lie in [header, used).
	if s.used > uint64(size-offset) {
		return false
	}
	table := func(x uint64) bool { return x == noTable || (x >= squashfsHeader && x < s.used) }
	for _, x := range []uint64{s.idTable, s.xattr, s.inodeTable, s.dirTable, s.fragTable, s.exportTable} {
		if !table(x) {
			return false
		}
	}
	required := []uint64{s.idTable, s.inodeTable, s.dirTable}
	if s.fragments != 0 {
		required = append(required, s.fragTable)
	}
	if s.flags&flagExportable != 0 {
		required = append(required, s.exportTable)
	}
	for _, x := range required {
		if x == noTable {
			return false
		}
	}
	return true
}

func scanSquashFS(r io.ReaderAt, size int64, col *collector) error {
	for from := int64(0); ; {
		offset, err := find(r, size, squashfsMagic, from)
		if err != nil || offset < 0 {
			return err
		}
		from = offset + 1
		if offset+squashfsHeader > size {
			continue
		}
		var header [squashfsHeader]byte
		if _, err := r.ReadAt(header[:], offset); err != nil {
			return err
		}
		super := parseSuper(header[:])
		if super.valid(offset, size) {
			if err := col.add(candidate{offset, offset + int64(super.used), kindSquashFS}); err != nil {
				return err
			}
		}
	}
}

// find returns the first offset >= from where pattern occurs in the first size bytes of r, or -1. It reads one
// window at a time, overlapping consecutive windows by len(pattern)-1 so a match across a boundary is found.
func find(r io.ReaderAt, size int64, pattern []byte, from int64) (int64, error) {
	buf := make([]byte, scanChunk+len(pattern)-1)
	for pos := from; pos < size; pos += scanChunk {
		n, err := r.ReadAt(buf[:min(int64(len(buf)), size-pos)], pos)
		if err != nil && !(errors.Is(err, io.EOF) && n > 0) {
			return -1, err
		}
		if i := bytes.Index(buf[:n], pattern); i >= 0 {
			return pos + int64(i), nil
		}
	}
	return -1, nil
}

// crcRange is the CRC-32 of bytes [start, end) of r.
func crcRange(r io.ReaderAt, start, end int64) (uint32, error) {
	sum := crc32.NewIEEE()
	if _, err := io.Copy(sum, io.NewSectionReader(r, start, end-start)); err != nil {
		return 0, err
	}
	return sum.Sum32(), nil
}
