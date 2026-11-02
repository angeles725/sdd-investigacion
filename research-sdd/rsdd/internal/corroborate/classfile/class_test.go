package classfile

import "testing"

// Teeth for class.go. Each decision in classFacts / scanLocalVariableTable has a row that goes red when the
// decision is inverted, dropped or off by one (see the mutant table in the commit notes of kit issue #2419).

func TestClassFactsHeader(t *testing.T) {
	t.Parallel()
	magic := []byte{0xca, 0xfe, 0xba, 0xbe}
	for _, tc := range []struct {
		name    string
		data    []byte
		known   bool
		major   int
		risk    bool
		partial bool
	}{
		{"empty", nil, false, 0, false, false},
		{"seven bytes", cat(magic, u16(0), []byte{0}), false, 0, false, false},
		{"bad magic", cat([]byte{0xca, 0xfe, 0xba, 0xbf}, u16(0), u16(52), u16(1)), false, 0, false, false},
		{"magic of 3 bytes plus padding", cat([]byte{0xca, 0xfe, 0xba, 0, 0xbe, 0, 0, 52}), false, 0, false, false},
		{"header only: major known, body truncated", cat(magic, u16(0), u16(52)), true, 52, false, true},
		{"major 0 is a real major, not unreadable", cat(magic, u16(0), u16(0)), true, 0, false, true},
		{"major is big-endian bytes 6-7", cat(magic, u16(7), u16(0x0100)), true, 256, true, true},
		{"major high byte only", cat(magic, u16(0xffff), u16(0xff00)), true, 0xff00, true, true},
		{"major 52 (Java 8) is below the re-sugar threshold", buildClass(classOpts{major: 52}), true, 52, false, false},
		{"major 53 (Java 9) is the first flagged", buildClass(classOpts{major: 53}), true, 53, true, false},
		{"major 65 (Java 21)", buildClass(classOpts{major: 65}), true, 65, true, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got := classFacts(tc.data)
			if got.majorKnown != tc.known || got.major != tc.major || got.resugarRisk() != tc.risk || got.partial != tc.partial {
				t.Fatalf("classFacts = %+v (risk %v), want known=%v major=%d risk=%v partial=%v", got, got.resugarRisk(), tc.known, tc.major, tc.risk, tc.partial)
			}
			if !tc.known && (got.lvtKnown || got.lvt) {
				t.Fatalf("an unreadable header must carry no LVT fact: %+v", got)
			}
			if tc.partial && got.lvtKnown {
				t.Fatalf("a failed body walk must leave the LVT fact unknown: %+v", got)
			}
		})
	}
}

func TestClassFactsLVT(t *testing.T) {
	t.Parallel()
	lvtAttr := attr(8, []byte{0, 0})
	other := attr(1, []byte{9, 9, 9})
	for _, tc := range []struct {
		name string
		opts classOpts
		lvt  bool
	}{
		{"code with LVT", classOpts{major: 52, lvt: true}, true},
		{"code without LVT", classOpts{major: 52}, false},
		{"LVT after another Code attribute", classOpts{major: 52, codeAttrs: cat(u16(2), other, lvtAttr)}, true},
		{"LVT before another Code attribute", classOpts{major: 52, codeAttrs: cat(u16(2), lvtAttr, other)}, true},
		{"LVT as a method attribute outside Code does not count", classOpts{major: 52, methodAttr: cat(u16(1), lvtAttr)}, false},
		{"LVT inside a field's Code attribute does not count", classOpts{major: 52, fieldAttrs: cat(u16(1), attr(7, cat(u16(0), u16(1), u32(0), u16(0), u16(1), lvtAttr)))}, false},
		{"attribute name index past the pool is ignored", classOpts{major: 52, codeAttrs: cat(u16(2), attr(999, nil), other)}, false},
		{"attribute name index equal to constant_pool_count is ignored", classOpts{major: 52, codeAttrs: cat(u16(1), attr(9, nil))}, false},
		{"attribute name index of a non-UTF8 slot is ignored", classOpts{major: 52, codeAttrs: cat(u16(1), attr(2, nil))}, false},
		{"Code with a non-empty exception table", classOpts{major: 52, methodAttr: cat(u16(1), attr(7, cat(u16(0), u16(1), u32(1), []byte{0xb1}, u16(2), make([]byte, 16), u16(1), lvtAttr)))}, true},
		{"interfaces are skipped", classOpts{major: 52, lvt: true, ifaces: 3}, true},
		{"fields are skipped", classOpts{major: 52, lvt: true, fieldAttrs: cat(u16(1), other)}, true},
		{"class attributes are walked", classOpts{major: 52, lvt: true, classAttrs: cat(u16(1), other)}, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got := classFacts(buildClass(tc.opts))
			if got.partial || !got.lvtKnown || got.lvt != tc.lvt {
				t.Fatalf("classFacts = %+v, want lvt=%v and not partial", got, tc.lvt)
			}
		})
	}
}

func TestClassFactsConstantPool(t *testing.T) {
	t.Parallel()
	fixed := map[byte]int{3: 4, 4: 4, 7: 2, 8: 2, 9: 4, 10: 4, 11: 4, 12: 4, 15: 3, 16: 2, 17: 4, 18: 4, 19: 2, 20: 2}
	for tag, n := range fixed {
		got := classFacts(buildClass(classOpts{major: 52, lvt: true, extraPool: [][]byte{cat([]byte{tag}, make([]byte, n))}}))
		if got.partial || !got.lvt {
			t.Errorf("tag %d (%d payload bytes): %+v", tag, n, got)
		}
		// One payload byte short must read as a truncated body, never as a different layout.
		got = classFacts(buildClass(classOpts{major: 52, lvt: true, extraPool: [][]byte{cat([]byte{tag}, make([]byte, n-1))}}))
		if !got.partial {
			t.Errorf("tag %d with a short payload parsed cleanly: %+v", tag, got)
		}
	}
	for _, tag := range []byte{5, 6} { // Long and Double take two pool slots
		got := classFacts(buildClass(classOpts{major: 52, lvt: true, poolSlots: 1, extraPool: [][]byte{cat([]byte{tag}, make([]byte, 8))}}))
		if got.partial || !got.lvt {
			t.Errorf("wide tag %d: %+v", tag, got)
		}
	}
	for _, tag := range []byte{0, 2, 13, 14, 21, 255} {
		got := classFacts(buildClass(classOpts{major: 52, lvt: true, extraPool: [][]byte{{tag, 0, 0, 0, 0}}}))
		if !got.partial || !got.majorKnown || got.lvtKnown {
			t.Errorf("tag %d: %+v, want a partial walk", tag, got)
		}
	}
	// A UTF8 constant longer than 255 bytes (two-byte length) is skipped whole.
	big := make([]byte, 300)
	got := classFacts(buildClass(classOpts{major: 52, lvt: true, extraPool: [][]byte{cat([]byte{1}, u16(300), big)}}))
	if got.partial || !got.lvt {
		t.Errorf("long UTF8: %+v", got)
	}
	// The pool ends exactly at constant_pool_count - 1; a count that promises more entries than exist is truncation.
	got = classFacts(buildClass(classOpts{major: 52, lvt: true, poolSlots: 200}))
	if !got.partial {
		t.Errorf("pool count larger than the pool parsed cleanly: %+v", got)
	}
}

func TestClassFactsTruncation(t *testing.T) {
	t.Parallel()
	full := buildClass(classOpts{major: 61, lvt: true})
	if got := classFacts(full); got.partial || !got.lvt {
		t.Fatalf("control: %+v", got)
	}
	for n := classHeaderLen; n < len(full); n++ {
		got := classFacts(full[:n])
		if !got.partial || !got.majorKnown || got.major != 61 || got.lvtKnown {
			t.Fatalf("prefix of %d/%d bytes: %+v, want a partial walk with major 61", n, len(full), got)
		}
	}
	// Bytes after the class attributes are ignored.
	if got := classFacts(append(append([]byte(nil), full...), 1, 2, 3)); got.partial || !got.lvt {
		t.Errorf("trailing bytes: %+v", got)
	}
}

func TestClassFactsMalformedBodies(t *testing.T) {
	t.Parallel()
	lvtAttr := attr(8, []byte{0, 0})
	for _, tc := range []struct {
		name string
		opts classOpts
	}{
		{"Code body shorter than max_stack/max_locals", classOpts{major: 52, methodAttr: cat(u16(1), attr(7, []byte{0, 0, 0}))}},
		{"Code length past the body", classOpts{major: 52, methodAttr: cat(u16(1), attr(7, cat(u16(0), u16(0), u32(99))))}},
		{"exception table past the body", classOpts{major: 52, methodAttr: cat(u16(1), attr(7, cat(u16(0), u16(0), u32(0), u16(1), make([]byte, 7))))}},
		{"Code attribute table truncated", classOpts{major: 52, methodAttr: cat(u16(1), attr(7, cat(u16(0), u16(0), u32(0), u16(0), u16(1), u16(8), u32(50))))}},
		{"4 GiB attribute length", classOpts{major: 52, methodAttr: cat(u16(1), u16(7), u32(0x7fffffff))}},
		{"LVT found, then the class attribute table is cut", classOpts{major: 52, lvt: true, classAttrs: cat(u16(1), u16(1), u32(10))}},
		{"LVT found in one method, then a later Code is malformed", classOpts{major: 52, methodAttr: cat(u16(2), attr(7, cat(u16(0), u16(1), u32(1), []byte{0xb1}, u16(0), u16(1), lvtAttr)), attr(7, []byte{1}))}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got := classFacts(buildClass(tc.opts))
			if !got.partial || !got.majorKnown || got.lvtKnown || got.lvt {
				t.Fatalf("classFacts = %+v, want a partial walk and no LVT fact", got)
			}
		})
	}
}
