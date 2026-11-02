package classfile

import (
	"bytes"
	"compress/flate"
	"encoding/binary"
	"hash/crc32"
)

// ---- class files ----------------------------------------------------------------------------------------------

func u16(v int) []byte { return []byte{byte(v >> 8), byte(v)} }
func u32(v int) []byte { return []byte{byte(v >> 24), byte(v >> 16), byte(v >> 8), byte(v)} }
func cat(parts ...[]byte) []byte {
	return bytes.Join(parts, nil)
}

func utf8Const(s string) []byte { return cat([]byte{1}, u16(len(s)), []byte(s)) }

// classOpts shapes a hand-built class. The constant pool always holds #1..#8 the way the suite's mkclass.py
// does: T, Class, Object, Class, m, ()V, Code, LocalVariableTable.
type classOpts struct {
	major      int
	lvt        bool
	extraPool  [][]byte // appended after the standard pool; counts toward constant_pool_count
	poolSlots  int      // extra slots counted but not written (wide constants), added to constant_pool_count
	fieldAttrs []byte   // raw attribute table of one field (count included); nil = no field
	methodAttr []byte   // replaces the method's single Code attribute with a raw attribute table (count included)
	classAttrs []byte   // raw class attribute table (count included); nil = zero attributes
	codeAttrs  []byte   // raw Code attribute table; nil = LVT per opts.lvt
	ifaces     int      // number of interfaces (two zero bytes each)
}

func attr(nameIdx int, body []byte) []byte { return cat(u16(nameIdx), u32(len(body)), body) }

func buildClass(o classOpts) []byte {
	pool := [][]byte{utf8Const("T"), {7, 0, 1}, utf8Const("java/lang/Object"), {7, 0, 3}, utf8Const("m"), utf8Const("()V"),
		utf8Const("Code"), utf8Const("LocalVariableTable")}
	pool = append(pool, o.extraPool...)
	codeAttrs := o.codeAttrs
	if codeAttrs == nil {
		codeAttrs = u16(0)
		if o.lvt {
			codeAttrs = cat(u16(1), attr(8, []byte{0, 0}))
		}
	}
	code := cat(u16(0), u16(1), u32(1), []byte{0xb1}, u16(0), codeAttrs)
	methodAttrs := o.methodAttr
	if methodAttrs == nil {
		methodAttrs = cat(u16(1), attr(7, code))
	}
	fields, fieldCount := []byte(nil), 0
	if o.fieldAttrs != nil {
		fields, fieldCount = cat(u16(1), u16(5), u16(6), o.fieldAttrs), 1
	}
	classAttrs := o.classAttrs
	if classAttrs == nil {
		classAttrs = u16(0)
	}
	return cat([]byte{0xca, 0xfe, 0xba, 0xbe}, u16(0), u16(o.major), u16(len(pool)+1+o.poolSlots), cat(pool...),
		u16(0x21), u16(2), u16(4), u16(o.ifaces), make([]byte, 2*o.ifaces), // access, this, super, interfaces
		u16(fieldCount), fields,
		u16(1), cat(u16(1), u16(5), u16(6), methodAttrs), // one method
		classAttrs)
}

// ---- zip archives ---------------------------------------------------------------------------------------------

// zent is one archive entry with every header field overridable.
type zent struct {
	name       []byte
	data       []byte
	method     uint16
	comp       []byte // stored bytes; default: data (stored) or its raw deflate
	crc        uint32
	csize      uint32 // 0xFFFFFFFF with a cextra zip64 field is how a test asks for ZIP64
	usize      uint32
	cflags     uint16
	lflags     uint16
	version    byte
	cextra     []byte
	lextra     []byte
	lextraDecl int    // declared local extra length when different from len(lextra)
	lname      []byte // local-header name; default: name
	lsig       []byte // local-header signature; default PK\3\4
	hoffAdd    int    // added to the central header offset
	gap        []byte // bytes between this entry's data and the next local header
}

func deflate(b []byte) []byte {
	var buf bytes.Buffer
	w, _ := flate.NewWriter(&buf, flate.BestCompression)
	w.Write(b)
	w.Close()
	return buf.Bytes()
}

func ent(name string, data []byte, method uint16) zent {
	z := zent{name: []byte(name), data: data, method: method, crc: crc32.ChecksumIEEE(data), version: 20}
	if method == 8 {
		z.comp = deflate(data)
	} else {
		z.comp = data
	}
	z.csize, z.usize = uint32(len(z.comp)), uint32(len(data))
	return z
}

type zopts struct {
	prepend []byte
	comment []byte
	cdTail  []byte // junk between the central directory and the end record (counted in its size)
	zip64   bool   // write a ZIP64 end record + locator (values taken from the real directory)
	eocdMut func(rec []byte)
}

func buildZip(entries []zent, o zopts) []byte {
	var out bytes.Buffer
	out.Write(o.prepend)
	base := out.Len()
	offs := make([]int, len(entries))
	for i, e := range entries {
		offs[i] = out.Len() - base
		lname, lsig := e.lname, e.lsig
		if lname == nil {
			lname = e.name
		}
		if lsig == nil {
			lsig = []byte("PK\x03\x04")
		}
		le := binary.LittleEndian
		h := make([]byte, 30)
		copy(h, lsig)
		h[4] = e.version
		le.PutUint16(h[6:], e.lflags)
		le.PutUint16(h[8:], e.method)
		le.PutUint32(h[14:], e.crc)
		le.PutUint32(h[18:], e.csize)
		le.PutUint32(h[22:], e.usize)
		le.PutUint16(h[26:], uint16(len(lname)))
		declared := len(e.lextra)
		if e.lextraDecl > 0 {
			declared = e.lextraDecl
		}
		le.PutUint16(h[28:], uint16(declared))
		out.Write(h)
		out.Write(lname)
		out.Write(e.lextra)
		out.Write(e.comp)
		out.Write(e.gap)
	}
	cdStart := out.Len() - base
	for i, e := range entries {
		le := binary.LittleEndian
		h := make([]byte, 46)
		copy(h, "PK\x01\x02")
		h[4], h[6] = 20, e.version
		le.PutUint16(h[8:], e.cflags)
		le.PutUint16(h[10:], e.method)
		le.PutUint32(h[16:], e.crc)
		le.PutUint32(h[20:], e.csize)
		le.PutUint32(h[24:], e.usize)
		le.PutUint16(h[28:], uint16(len(e.name)))
		le.PutUint16(h[30:], uint16(len(e.cextra)))
		le.PutUint32(h[42:], uint32(offs[i]+e.hoffAdd))
		out.Write(h)
		out.Write(e.name)
		out.Write(e.cextra)
	}
	out.Write(o.cdTail)
	cdSize := out.Len() - base - cdStart
	if o.zip64 {
		rec64 := out.Len() - base
		z := make([]byte, 56)
		copy(z, "PK\x06\x06")
		binary.LittleEndian.PutUint64(z[4:], 44)
		binary.LittleEndian.PutUint64(z[24:], uint64(len(entries)))
		binary.LittleEndian.PutUint64(z[32:], uint64(len(entries)))
		binary.LittleEndian.PutUint64(z[40:], uint64(cdSize))
		binary.LittleEndian.PutUint64(z[48:], uint64(cdStart))
		out.Write(z)
		l := make([]byte, 20)
		copy(l, "PK\x06\x07")
		binary.LittleEndian.PutUint64(l[8:], uint64(rec64))
		binary.LittleEndian.PutUint32(l[16:], 1)
		out.Write(l)
	}
	rec := make([]byte, 22)
	copy(rec, "PK\x05\x06")
	binary.LittleEndian.PutUint16(rec[8:], uint16(len(entries)))
	binary.LittleEndian.PutUint16(rec[10:], uint16(len(entries)))
	cs, co := uint32(cdSize), uint32(cdStart)
	if o.zip64 {
		cs, co = 0xFFFFFFFF, 0xFFFFFFFF
	}
	binary.LittleEndian.PutUint32(rec[12:], cs)
	binary.LittleEndian.PutUint32(rec[16:], co)
	binary.LittleEndian.PutUint16(rec[20:], uint16(len(o.comment)))
	if o.eocdMut != nil {
		o.eocdMut(rec)
	}
	out.Write(rec)
	out.Write(o.comment)
	return out.Bytes()
}

// zip64Extra is a 0x0001 extra field carrying the given 64-bit values.
func zip64Extra(vals ...uint64) []byte {
	b := cat(u16le(1), u16le(8*len(vals)))
	for _, v := range vals {
		b = binary.LittleEndian.AppendUint64(b, v)
	}
	return b
}

func u16le(v int) []byte { return binary.LittleEndian.AppendUint16(nil, uint16(v)) }

func extraField(tp int, body []byte) []byte { return cat(u16le(tp), u16le(len(body)), body) }

// unicodePath is an Info-ZIP unicode path extra field (0x7075) for the given raw entry name.
func unicodePath(version byte, rawName []byte, unicode string) []byte {
	return extraField(0x7075, cat([]byte{version}, binary.LittleEndian.AppendUint32(nil, crc32.ChecksumIEEE(rawName)), []byte(unicode)))
}

// atTail builds an archive whose last bytes are tail (carried as the end-record comment) and whose only real
// entry has its data start `back` bytes before the end of the file. A second central-directory entry with a far
// offset lifts the first entry's end offset past the end of the file, so its declared compressed size may
// exceed what the file holds. mut sets the entry's method, sizes and CRC.
func atTail(tail []byte, back int, mut func(e *zent)) []byte {
	build := func(decl int) []byte {
		e := ent("e.class", nil, 0)
		mut(&e)
		e.lextraDecl = decl
		far := ent("z.class", nil, 0)
		far.hoffAdd = 1 << 20
		return buildZip([]zent{e, far}, zopts{comment: tail})
	}
	size := len(build(1))
	return build(size - back - (localHeaderLen + len("e.class")))
}

// storedBlock is a raw deflate stream: one non-final stored block holding b, and nothing after it.
func storedBlock(b []byte) []byte {
	return cat([]byte{0}, binary.LittleEndian.AppendUint16(nil, uint16(len(b))), binary.LittleEndian.AppendUint16(nil, ^uint16(len(b))), b)
}
