// Package bogtest builds the hermetic .bog fixtures shared by the niagara test suites: ZIP archives written
// byte by byte (so a test controls every header field, flag bit and compression method) and the Baja XML
// documents the original bog-nav suite pinned. It imports only the standard library and is used by tests only.
package bogtest

import (
	"bytes"
	"compress/flate"
	"encoding/binary"
	"hash/crc32"
	"os"
	"path/filepath"
)

// Entry is one ZIP member. Zero Method means deflate (8); Stored is method 0.
type Entry struct {
	Name   string
	Data   []byte
	Method uint16
	Flags  uint16
	// CRC overrides the CRC-32 recorded in both headers when non-nil.
	CRC *uint32
	// Size overrides the uncompressed size recorded in the central directory when non-nil.
	Size *uint32
	// Raw, when non-nil, is the stored/compressed payload written as-is instead of compressing Data.
	Raw []byte
}

// Stored is the ZIP method number for an uncompressed member.
const Stored = 0xFFFF // sentinel for "method 0": the zero value of Entry.Method means deflate

func deflate(data []byte) []byte {
	var b bytes.Buffer
	w, _ := flate.NewWriter(&b, flate.DefaultCompression)
	_, _ = w.Write(data)
	_ = w.Close()
	return b.Bytes()
}

// Zip serialises entries into a ZIP archive: local header + payload per member, then the central directory
// and the end record. Dates are fixed so a rebuild is byte-identical for the same Go release.
func Zip(entries ...Entry) []byte {
	const (
		dosTime = 0
		dosDate = (44 << 9) | (1 << 5) | 1 // 2024-01-01
	)
	var out, cd bytes.Buffer
	le := binary.LittleEndian
	for _, e := range entries {
		method := e.Method
		switch method {
		case 0:
			method = 8
		case Stored:
			method = 0
		}
		payload := e.Raw
		if payload == nil {
			if method == 8 {
				payload = deflate(e.Data)
			} else {
				payload = e.Data
			}
		}
		crc := crc32.ChecksumIEEE(e.Data)
		if e.CRC != nil {
			crc = *e.CRC
		}
		usize := uint32(len(e.Data))
		if e.Size != nil {
			usize = *e.Size
		}
		off := uint32(out.Len())
		lfh := make([]byte, 30)
		le.PutUint32(lfh[0:], 0x04034b50)
		le.PutUint16(lfh[4:], 20)
		le.PutUint16(lfh[6:], e.Flags)
		le.PutUint16(lfh[8:], method)
		le.PutUint16(lfh[10:], dosTime)
		le.PutUint16(lfh[12:], dosDate)
		le.PutUint32(lfh[14:], crc)
		le.PutUint32(lfh[18:], uint32(len(payload)))
		le.PutUint32(lfh[22:], usize)
		le.PutUint16(lfh[26:], uint16(len(e.Name)))
		out.Write(lfh)
		out.WriteString(e.Name)
		out.Write(payload)

		ch := make([]byte, 46)
		le.PutUint32(ch[0:], 0x02014b50)
		le.PutUint16(ch[4:], 20)
		le.PutUint16(ch[6:], 20)
		le.PutUint16(ch[8:], e.Flags)
		le.PutUint16(ch[10:], method)
		le.PutUint16(ch[12:], dosTime)
		le.PutUint16(ch[14:], dosDate)
		le.PutUint32(ch[16:], crc)
		le.PutUint32(ch[20:], uint32(len(payload)))
		le.PutUint32(ch[24:], usize)
		le.PutUint16(ch[28:], uint16(len(e.Name)))
		le.PutUint32(ch[42:], off)
		cd.Write(ch)
		cd.WriteString(e.Name)
	}
	cdOff := uint32(out.Len())
	out.Write(cd.Bytes())
	end := make([]byte, 22)
	le.PutUint32(end[0:], 0x06054b50)
	le.PutUint16(end[8:], uint16(len(entries)))
	le.PutUint16(end[10:], uint16(len(entries)))
	le.PutUint32(end[12:], uint32(cd.Len()))
	le.PutUint32(end[16:], cdOff)
	out.Write(end)
	return out.Bytes()
}

// Bog is a deflate ZIP holding a single file.xml with the given content.
func Bog(xml string) []byte { return Zip(Entry{Name: "file.xml", Data: []byte(xml)}) }

// ValidXML is the suite's main station: three components, one link and a secret slot that must never be emitted.
const ValidXML = `<?xml version='1.0' encoding='UTF-8'?>
<bajaObjectGraph version='4.0'>
 <p n='Station' h='1' t='b:Station' m='b=baja c=control'>
  <p n='Services' h='2' t='b:ServiceContainer'>
  </p>
  <p n='Logic' h='3' t='c:BooleanWritable'>
   <p n='Password' v='PLAINSECRET'/>
   <p n='Link' t='b:Link'>
    <p n='sourceOrd' v='h:2'/>
    <p n='sourceSlotName' v='out'/>
    <p n='targetSlotName' v='in10'/>
   </p>
  </p>
 </p>
</bajaObjectGraph>`

// SelfClosingXML has seven handles: four self-closing, three open.
const SelfClosingXML = `<?xml version='1.0' encoding='UTF-8'?>
<bajaObjectGraph version='4.0'>
 <p n='Station' h='1' t='b:Station' m='b=baja'>
  <p n='A' h='2' t='b:Container'>
   <p n='Leaf1' h='3' t='b:Folder'/>
   <p n='Leaf2' h='4' t='b:Folder'/>
   <p n='Container2' h='5' t='b:Container'>
    <p n='Leaf3' h='6' t='b:Folder'/>
   </p>
  </p>
  <p n='B' h='7' t='b:Container'/>
 </p>
</bajaObjectGraph>`

// NestedAXML wraps an action element around its argument so a mishandled </a> pops the wrong frame.
const NestedAXML = `<?xml version='1.0' encoding='UTF-8'?>
<bajaObjectGraph version='4.0'>
 <p n='Station' h='1' t='b:Station' m='b=baja'>
  <p n='A' h='2' t='b:Container'>
   <a n='someAction'>
    <p n='arg' v='value'/>
   </a>
  </p>
  <p n='B' h='3' t='b:Container'>
  </p>
 </p>
</bajaObjectGraph>`

// EmptyXML is a valid document with no components.
const EmptyXML = `<?xml version='1.0'?><bajaObjectGraph version='4.0'></bajaObjectGraph>`

const tinyXML = `<?xml version="1.0"?><root/>`

// corruptTiny builds the one-member archive the corrupt fixtures start from.
func corruptTiny() []byte { return Bog(tinyXML) }

// CorruptDeflate holds a deflate payload that opens with the reserved block type 3, which every inflater
// rejects (the original suite xor-ed payload bytes, whose effect depends on the compressor that wrote them).
func CorruptDeflate() []byte {
	return Zip(Entry{Name: "file.xml", Data: []byte(tinyXML), Raw: []byte{0x07, 0x00, 0x00, 0x00}})
}

// FlippedDeflate is the original suite's corruption: payload bytes xor-ed in place. Whether the inflater
// notices depends on the compressor, so tests compare implementations on it rather than pin one message.
func FlippedDeflate() []byte {
	raw := corruptTiny()
	nameLen := int(binary.LittleEndian.Uint16(raw[26:]))
	start := 30 + nameLen
	for i := start + 5; i < min(start+20, len(raw)-20); i++ {
		raw[i] ^= 0xAA
	}
	return raw
}

// CRCMismatch flips the CRC-32 recorded in the local header and the central directory.
func CRCMismatch() []byte {
	raw := corruptTiny()
	raw[14] ^= 0xFF
	raw[15] ^= 0xFF
	if cd := bytes.Index(raw, []byte("PK\x01\x02")); cd >= 0 {
		raw[cd+16] ^= 0xFF
		raw[cd+17] ^= 0xFF
	}
	return raw
}

// Encrypted sets the encryption bit in both headers.
func Encrypted() []byte {
	raw := corruptTiny()
	raw[6] |= 0x01
	if cd := bytes.Index(raw, []byte("PK\x01\x02")); cd >= 0 {
		raw[cd+8] |= 0x01
	}
	return raw
}

// Method99 rewrites the compression method in both headers to an unsupported value.
func Method99() []byte {
	raw := corruptTiny()
	binary.LittleEndian.PutUint16(raw[8:], 99)
	if cd := bytes.Index(raw, []byte("PK\x01\x02")); cd >= 0 {
		binary.LittleEndian.PutUint16(raw[cd+10:], 99)
	}
	return raw
}

// Bomb is a deflate member inflating to limit+1 bytes of 'A'.
func Bomb(limit int) []byte {
	return Bog(string(bytes.Repeat([]byte("A"), limit+1)))
}

// Binary is neither a ZIP nor XML.
func Binary() []byte {
	b := bytes.Repeat([]byte{0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x01, 0x02, 0x03}, 256)
	return b
}

// Suite writes the original suite's fixtures into dir and returns name -> absolute path.
func Suite(dir string) (map[string]string, error) {
	files := map[string][]byte{
		"valid.bog":            Bog(ValidXML),
		"plaintext.bog":        []byte(ValidXML),
		"empty.bog":            Bog(EmptyXML),
		"binary.bog":           Binary(),
		"bomb.bog":             Bomb(32 * 1024 * 1024),
		"corrupt_deflate.bog":  CorruptDeflate(),
		"crc_mismatch.bog":     CRCMismatch(),
		"encrypted.bog":        Encrypted(),
		"method99.bog":         Method99(),
		"self_closing_mix.bog": Bog(SelfClosingXML),
		"nested_a.bog":         Bog(NestedAXML),
	}
	out := make(map[string]string, len(files))
	for name, data := range files {
		p := filepath.Join(dir, name)
		if err := os.WriteFile(p, data, 0o600); err != nil {
			return nil, err
		}
		out[name] = p
	}
	return out, nil
}
