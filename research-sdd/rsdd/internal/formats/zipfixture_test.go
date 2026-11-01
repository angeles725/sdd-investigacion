package formats

import (
	"bytes"
	"compress/flate"
	"encoding/binary"
	"hash/crc32"
	"os"
	"path/filepath"
	"testing"
)

// zfx describes one archive member for the fixture builder. Zero values are the common case.
type zfx struct {
	name    []byte
	flags   uint16
	method  uint16
	payload []byte // the bytes stored after the local header (already compressed for method 8)
	size    uint32 // uncompressed size; 0 means len(payload)
	attrs   uint32
	extra   []byte
	crc     uint32 // 0 means crc32 of payload
	fakeCRC bool   // use crc as given even when 0
}

// zipOpts shapes the whole archive.
type zipOpts struct {
	madeBy   uint16 // version made by
	dosTime  uint16
	dosDate  uint16
	disk     uint16
	sentinel bool // 0xffff in the total-entries field
	truncate int  // bytes dropped from the end
	comment  []byte
	prefix   []byte
	fixedCRC uint32 // when non-zero, every member's CRC
}

func buildZip(entries []zfx, o zipOpts) []byte {
	if o.madeBy == 0 {
		o.madeBy = 20
	}
	le := binary.LittleEndian
	var body, central bytes.Buffer
	body.Write(o.prefix)
	for _, e := range entries {
		off := uint32(body.Len() - len(o.prefix))
		crc := e.crc
		if crc == 0 && !e.fakeCRC {
			crc = crc32.ChecksumIEEE(e.payload)
		}
		if o.fixedCRC != 0 {
			crc = o.fixedCRC
		}
		size := e.size
		if size == 0 {
			size = uint32(len(e.payload))
		}
		local := make([]byte, 30)
		le.PutUint32(local, 0x04034b50)
		le.PutUint16(local[4:], 20)
		le.PutUint16(local[6:], e.flags)
		le.PutUint16(local[8:], e.method)
		le.PutUint16(local[10:], o.dosTime)
		le.PutUint16(local[12:], o.dosDate)
		le.PutUint32(local[14:], crc)
		le.PutUint32(local[18:], uint32(len(e.payload)))
		le.PutUint32(local[22:], size)
		le.PutUint16(local[26:], uint16(len(e.name)))
		le.PutUint16(local[28:], uint16(len(e.extra)))
		body.Write(local)
		body.Write(e.name)
		body.Write(e.extra)
		body.Write(e.payload)
		cd := make([]byte, 46)
		le.PutUint32(cd, 0x02014b50)
		le.PutUint16(cd[4:], o.madeBy)
		le.PutUint16(cd[6:], 20)
		le.PutUint16(cd[8:], e.flags)
		le.PutUint16(cd[10:], e.method)
		le.PutUint16(cd[12:], o.dosTime)
		le.PutUint16(cd[14:], o.dosDate)
		le.PutUint32(cd[16:], crc)
		le.PutUint32(cd[20:], uint32(len(e.payload)))
		le.PutUint32(cd[24:], size)
		le.PutUint16(cd[28:], uint16(len(e.name)))
		le.PutUint16(cd[30:], uint16(len(e.extra)))
		le.PutUint32(cd[38:], e.attrs)
		le.PutUint32(cd[42:], off)
		central.Write(cd)
		central.Write(e.name)
		central.Write(e.extra)
	}
	cdOffset := uint32(body.Len() - len(o.prefix))
	body.Write(central.Bytes())
	end := make([]byte, 22)
	le.PutUint32(end, 0x06054b50)
	le.PutUint16(end[4:], o.disk)
	le.PutUint16(end[6:], o.disk)
	le.PutUint16(end[8:], uint16(len(entries)))
	total := uint16(len(entries))
	if o.sentinel {
		total = 0xffff
	}
	le.PutUint16(end[10:], total)
	le.PutUint32(end[12:], uint32(central.Len()))
	le.PutUint32(end[16:], cdOffset)
	le.PutUint16(end[20:], uint16(len(o.comment)))
	body.Write(end)
	body.Write(o.comment)
	b := body.Bytes()
	if o.truncate > 0 {
		b = b[:len(b)-o.truncate]
	}
	return b
}

func deflateBytes(t testing.TB, data []byte) []byte {
	t.Helper()
	var buf bytes.Buffer
	w, err := flate.NewWriter(&buf, flate.BestCompression)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := w.Write(data); err != nil {
		t.Fatal(err)
	}
	if err := w.Close(); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

// metaFixtures are the archives of zip-metadata.test.sh, built the same way.
func metaFixtures() map[string][]byte {
	mixed := []zfx{
		{name: []byte("ok.txt"), payload: []byte("PAYLOAD-NOT-METADATA")},
		{name: []byte("../evil"), flags: 1, method: 99, payload: []byte("SECRET")},
		{name: []byte("\\root"), method: 8, payload: []byte("X")},
		{name: []byte("/abs"), payload: []byte("Y")},
		{name: []byte("dup"), payload: []byte("A")},
		{name: []byte("dup"), payload: []byte("B")},
		{name: []byte("nul\x00x"), payload: []byte("C")},
	}
	o := zipOpts{fixedCRC: 0x12345678}
	m := buildZip(mixed, o)
	malformed := append([]byte(nil), m...)
	copy(malformed[bytes.Index(malformed, []byte("PK\x01\x02")):], "BAD!")
	return map[string][]byte{
		"empty.zip":     buildZip(nil, o),
		"mixed.zip":     m,
		"multi.zip":     buildZip(nil, zipOpts{disk: 1}),
		"zip64.zip":     buildZip(nil, zipOpts{sentinel: true}),
		"truncated.zip": buildZip(nil, zipOpts{truncate: 1}),
		"malformed.zip": malformed,
		"comment.zip":   buildZip([]zfx{{name: []byte("a"), payload: []byte("a")}}, zipOpts{comment: []byte("hello PK\x05\x06 comment")}),
		"prefix.zip":    buildZip([]zfx{{name: []byte("a"), payload: []byte("a")}}, zipOpts{prefix: []byte("#!stub\n")}),
		// drive-letter syntax: only "X:" followed by a separator is absolute for the metadata report
		"drive.zip": buildZip([]zfx{
			{name: []byte("C:\\x"), payload: []byte("1")}, {name: []byte("d:/y"), payload: []byte("2")}, {name: []byte("e:z"), payload: []byte("3")},
			{name: []byte("1:/q"), payload: []byte("4")}, {name: []byte("ab:/q"), payload: []byte("5")}, {name: []byte("f:"), payload: []byte("6")},
		}, o),
		"utf8.zip": buildZip([]zfx{
			{name: []byte("caf\xc3\xa9"), flags: 0x800, payload: []byte("x")},
			{name: []byte("bad\xe2\x82"), flags: 0x800, payload: []byte("x")},
			{name: []byte("cp\x80\xe9\xff"), payload: []byte("x")},
		}, zipOpts{dosDate: 0x5821, dosTime: 1}),
	}
}

// storedFixtures are the archives of zip-stored.test.sh, built the same way.
func storedFixtures() map[string][]byte {
	reg := uint32(0o100644) << 16
	dir := uint32(0o40755)<<16 | 0x10
	o := zipOpts{madeBy: 3<<8 | 20, dosTime: 1, dosDate: 0x5821}
	one := func(e zfx) []byte { return buildZip([]zfx{e}, o) }
	fx := map[string][]byte{
		"good.zip": buildZip([]zfx{
			{name: []byte("dir/"), attrs: dir},
			{name: []byte("dir/a.txt"), payload: []byte("alpha"), attrs: reg},
			{name: []byte("b.bin"), payload: []byte{0, 1}, attrs: reg},
		}, o),
		"deflate":      one(zfx{name: []byte("x"), payload: []byte("x"), method: 8, attrs: reg}),
		"encrypted":    one(zfx{name: []byte("x"), payload: []byte("x"), flags: 1, attrs: reg}),
		"descriptor":   one(zfx{name: []byte("x"), payload: []byte("x"), flags: 8, attrs: reg}),
		"zip64":        one(zfx{name: []byte("x"), payload: []byte("x"), attrs: reg, extra: []byte{1, 0, 0, 0}}),
		"traversal":    one(zfx{name: []byte("../x"), payload: []byte("x"), attrs: reg}),
		"backslash":    one(zfx{name: []byte("a\\b"), payload: []byte("x"), attrs: reg}),
		"duplicate":    buildZip([]zfx{{name: []byte("x"), payload: []byte("a"), attrs: reg}, {name: []byte("x"), payload: []byte("b"), attrs: reg}}, o),
		"conflict":     buildZip([]zfx{{name: []byte("x"), payload: []byte("a"), attrs: reg}, {name: []byte("x/y"), payload: []byte("b"), attrs: reg}}, o),
		"symlink":      one(zfx{name: []byte("x"), payload: []byte("target"), attrs: 0o120777 << 16}),
		"dir-data":     one(zfx{name: []byte("x/"), payload: []byte("x"), attrs: dir}),
		"nfd":          one(zfx{name: []byte("e\xcc\x81"), flags: 0x800, payload: []byte("x"), attrs: reg}),
		"nested":       buildZip([]zfx{{name: []byte("a/b/c/d.txt"), payload: []byte("deep"), attrs: reg}, {name: []byte("a/"), attrs: dir}}, o),
		"dos":          buildZip([]zfx{{name: []byte("d/"), attrs: 0x10}, {name: []byte("d/f"), payload: []byte("f"), attrs: 0}}, zipOpts{madeBy: 20, dosTime: 1, dosDate: 0x5821}),
		"empty.zip":    buildZip(nil, o),
		"drive-letter": one(zfx{name: []byte("C:x"), payload: []byte("x"), attrs: reg}),
		"colons":       buildZip([]zfx{{name: []byte("1:x"), payload: []byte("1"), attrs: reg}, {name: []byte("ab:c"), payload: []byte("2"), attrs: reg}}, o),
		"zero-file":    one(zfx{name: []byte("z"), attrs: reg}),
		"prefix":       buildZip([]zfx{{name: []byte("a"), payload: []byte("a"), attrs: reg}}, zipOpts{madeBy: 3<<8 | 20, dosTime: 1, dosDate: 0x5821, prefix: []byte("stub")}),
	}
	// Overlap: the first entry's payload contains the second entry's whole local record.
	fx["overlap"] = overlapArchive(reg)
	good := fx["good.zip"]
	for _, c := range []struct {
		name  string
		delta int
	}{{"local-name", 30}, {"payload", 73}} {
		d := append([]byte(nil), good...)
		d[c.delta] ^= 1
		fx[c.name] = d
	}
	return fx
}

func localRecord(name, data []byte) []byte {
	le := binary.LittleEndian
	h := make([]byte, 30)
	le.PutUint32(h, 0x04034b50)
	le.PutUint16(h[4:], 20)
	le.PutUint16(h[10:], 1)
	le.PutUint16(h[12:], 0x5821)
	le.PutUint32(h[14:], crc32.ChecksumIEEE(data))
	le.PutUint32(h[18:], uint32(len(data)))
	le.PutUint32(h[22:], uint32(len(data)))
	le.PutUint16(h[26:], uint16(len(name)))
	return append(h, name...)
}

// overlapArchive is two entries whose payload ranges overlap (the zip-stored.test.sh "overlap" case).
func overlapArchive(reg uint32) []byte {
	le := binary.LittleEndian
	data := []byte("B")
	second := append(localRecord([]byte("b"), data), data...)
	// first.payload = the whole second record; its local header declares CRC of that record
	first := append(localRecord([]byte("a"), second), second...)
	var central []byte
	for _, c := range []struct {
		name    string
		payload []byte
		off     uint32
	}{{"a", second, 0}, {"b", data, 31}} {
		cd := make([]byte, 46)
		le.PutUint32(cd, 0x02014b50)
		le.PutUint16(cd[4:], 3<<8|20)
		le.PutUint16(cd[6:], 20)
		le.PutUint16(cd[12:], 1)
		le.PutUint16(cd[14:], 0x5821)
		le.PutUint32(cd[16:], crc32.ChecksumIEEE(c.payload))
		le.PutUint32(cd[20:], uint32(len(c.payload)))
		le.PutUint32(cd[24:], uint32(len(c.payload)))
		le.PutUint16(cd[28:], 1)
		le.PutUint32(cd[38:], reg)
		le.PutUint32(cd[42:], c.off)
		central = append(append(central, cd...), c.name...)
	}
	end := make([]byte, 22)
	le.PutUint32(end, 0x06054b50)
	le.PutUint16(end[8:], 2)
	le.PutUint16(end[10:], 2)
	le.PutUint32(end[12:], uint32(len(central)))
	le.PutUint32(end[16:], uint32(len(first)))
	return append(append(first, central...), end...)
}

// writeFixtures stores the archives in dir and returns name -> path.
func writeFixtures(t testing.TB, dir string, fx map[string][]byte) map[string]string {
	t.Helper()
	paths := map[string]string{}
	for name, data := range fx {
		if filepath.Ext(name) != ".zip" {
			name += ".zip"
		}
		p := filepath.Join(dir, name)
		if err := os.WriteFile(p, data, 0o600); err != nil {
			t.Fatal(err)
		}
		paths[name] = p
	}
	return paths
}
