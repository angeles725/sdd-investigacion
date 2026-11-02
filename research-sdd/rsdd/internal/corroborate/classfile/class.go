package classfile

import "bytes"

// Class-file facts (kit issue #1205), read straight from the bytes: no javap/JDK dependency, nothing executed.
// A port of corroborate_java.py class_file_facts / _scan_local_variable_table.

const (
	classMagic     = "\xca\xfe\xba\xbe"
	classHeaderLen = 8 // magic(4) + minor(2) + major(2); major_version is bytes 6-7, big-endian
	// resugarMinMajor is the first release (Java 9, major 53) whose lowering a decompiler reverses on the way
	// back. The threshold is deliberately conservative: a flag means "syntax-level claims need bytecode
	// evidence", never "the decompilation is wrong".
	resugarMinMajor = 53

	cpUTF8 = 1
)

// cpFixed is the payload length of every fixed-size constant-pool tag; 0 marks a tag the walk rejects.
var cpFixed = [21]int{3: 4, 4: 4, 5: 8, 6: 8, 7: 2, 8: 2, 9: 4, 10: 4, 11: 4, 12: 4, 15: 3, 16: 2, 17: 4, 18: 4, 19: 2, 20: 2}

// facts is what one class file yields. majorKnown=false means nothing could be read (the header was missing or
// wrong, or the entry could not be read); partial means the header was read but the body walk failed, so the
// major still counts and the LocalVariableTable fact is unknown.
type facts struct {
	majorKnown bool
	major      int
	lvtKnown   bool
	lvt        bool
	partial    bool
}

func (f facts) resugarRisk() bool { return f.majorKnown && f.major >= resugarMinMajor }

// nullFacts is the fact set of a class nothing could be read from: never a fake major 0.
func nullFacts() facts { return facts{} }

// classFacts reads the facts of one class file. An unreadable header gives null facts.
func classFacts(data []byte) facts {
	if len(data) < classHeaderLen || string(data[:4]) != classMagic {
		return nullFacts()
	}
	f := facts{majorKnown: true, major: int(data[6])<<8 | int(data[7])}
	if lvt, ok := scanLocalVariableTable(data); ok {
		f.lvtKnown, f.lvt = true, lvt
	} else {
		f.partial = true
	}
	return f
}

// reader is a bounds-checked big-endian cursor. The first failure sticks: every later call returns zeros, so a
// walker checks ok() at its loop heads and once at the end instead of after every read.
type reader struct {
	b      []byte
	pos    int
	failed bool
}

func (r *reader) ok() bool { return !r.failed }

func (r *reader) take(n uint64) []byte {
	if n > uint64(len(r.b)-r.pos) {
		r.failed = true
		return nil
	}
	chunk := r.b[r.pos : r.pos+int(n)]
	r.pos += int(n)
	return chunk
}

// uint reads an n-byte big-endian integer; 0 once the reader has failed.
func (r *reader) uint(n int) uint64 {
	var v uint64
	for _, b := range r.take(uint64(n)) {
		v = v<<8 | uint64(b)
	}
	return v
}

func (r *reader) u2() int { return int(r.uint(2)) }

// Attribute-name kinds the walk cares about; everything else is kindOther.
const (
	kindOther uint8 = iota
	kindCode
	kindLVT
)

// attributes walks one attribute table, calling visit with each attribute's name kind and body.
func attributes(r *reader, kinds []uint8, visit func(kind uint8, body []byte)) {
	for n := r.u2(); n > 0 && r.ok(); n-- {
		kind := kindOther
		if idx := r.u2(); idx < len(kinds) {
			kind = kinds[idx]
		}
		visit(kind, r.take(r.uint(4)))
	}
}

// scanLocalVariableTable reports whether any method's Code attribute carries a LocalVariableTable. ok=false
// means the bytes ran out or held an unknown constant-pool tag, and the first result is meaningless.
func scanLocalVariableTable(data []byte) (lvt, ok bool) {
	r := &reader{b: data, pos: classHeaderLen}
	count := r.u2()
	kinds := make([]uint8, count)
	for index := 1; index < count && r.ok(); {
		tag := byte(r.uint(1))
		switch t := int(tag); {
		case t == cpUTF8:
			name := r.take(uint64(r.u2()))
			switch {
			case bytes.Equal(name, []byte("Code")):
				kinds[index] = kindCode
			case bytes.Equal(name, []byte("LocalVariableTable")):
				kinds[index] = kindLVT
			}
		case t < len(cpFixed) && cpFixed[t] != 0:
			r.take(uint64(cpFixed[t]))
		default:
			r.failed = true // a tag this walk cannot size
		}
		index++
		if tag == 5 || tag == 6 { // Long and Double occupy two constant-pool slots
			index++
		}
	}
	r.take(6)                  // access_flags, this_class, super_class
	r.take(uint64(2 * r.u2())) // interfaces
	found := false
	for pass := 0; pass < 2; pass++ { // fields, then methods
		methods := pass == 1
		for n := r.u2(); n > 0 && r.ok(); n-- {
			r.take(6) // access_flags, name_index, descriptor_index
			attributes(r, kinds, func(kind uint8, body []byte) {
				if methods && kind == kindCode && codeHasLVT(r, kinds, body) {
					found = true
				}
			})
		}
	}
	attributes(r, kinds, func(uint8, []byte) {}) // class attributes: walked so a truncated tail is detected
	return found, r.ok()
}

// codeHasLVT walks one Code attribute body; a malformed body fails the enclosing reader.
func codeHasLVT(outer *reader, kinds []uint8, body []byte) bool {
	code := &reader{b: body}
	code.take(4)                     // max_stack, max_locals
	code.take(code.uint(4))          // bytecode
	code.take(uint64(8 * code.u2())) // exception table
	found := false
	attributes(code, kinds, func(kind uint8, _ []byte) {
		if kind == kindLVT {
			found = true
		}
	})
	outer.failed = outer.failed || code.failed
	return found
}
