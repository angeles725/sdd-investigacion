package java

import (
	"bytes"
	"compress/flate"
	"encoding/binary"
	"fmt"
	"hash/crc32"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestUnsafeArchiveEntriesFailBeforeAdapters(t *testing.T) {
	cases := []struct {
		name  string
		entry entry
	}{
		{"dot-dot", entry{name: "../escape.class", data: []byte("class")}},
		{"nested dot-dot", entry{name: "a/../b.class", data: []byte("class")}},
		{"absolute", entry{name: "/abs.class", data: []byte("class")}},
		{"backslash", entry{name: `a\b.class`, data: []byte("class")}},
		{"empty component", entry{name: "a//b.class", data: []byte("class")}},
		{"dot component", entry{name: "a/./b.class", data: []byte("class")}},
		{"symlink", entry{name: "link.class", data: []byte("/etc/passwd"), mode: os.ModeSymlink | 0o777}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			h := newHarness(t)
			writeJar(t, h.input, c.entry)
			r := h.run(h.args("--output", h.out("unsafe-out"))...)
			if r.rc != 2 || !strings.Contains(r.err, "unsafe or duplicate JAR entry: "+c.entry.name) {
				t.Fatalf("rc=%d stderr=%q", r.rc, r.err)
			}
			if h.exists(h.out("unsafe-out")) || h.exists(h.root, ".unsafe-out.stage") {
				t.Error("evidence or a stage was left behind")
			}
		})
	}
}

func TestDuplicateEntryNamesAreRefused(t *testing.T) {
	h := newHarness(t)
	writeJar(t, h.input, entry{name: "a.class", data: classBytes(52, false)}, entry{name: "a.class", data: classBytes(65, false)})
	r := h.run(h.args("--output", h.out("dup"))...)
	if r.rc != 2 || !strings.Contains(r.err, "unsafe or duplicate JAR entry: a.class") {
		t.Fatalf("rc=%d stderr=%q", r.rc, r.err)
	}
}

func TestSafeNamesThePathlibRuleAccepts(t *testing.T) {
	h := newHarness(t)
	writeJar(t, h.input, entry{name: "a/", data: nil}, entry{name: "a/b/", data: nil}, entry{name: "a/b/C.class", data: classBytes(52, false)},
		entry{name: "..hidden.class", data: classBytes(52, false)}, entry{name: "a/.x/Y.class", data: classBytes(52, false)})
	inv, err := jarInventory(h.input, 100, 1<<20, 100)
	if err != nil {
		t.Fatal(err)
	}
	if want := []string{"..hidden.class", "a/.x/Y.class", "a/b/C.class"}; !reflect.DeepEqual(inv.classEntries, want) {
		t.Fatalf("classEntries = %v, want %v", inv.classEntries, want)
	}
}

func TestInventoryCapsAreEnforcedInOrder(t *testing.T) {
	h := newHarness(t)
	writeJar(t, h.input, entry{name: "a.class", data: bytes.Repeat([]byte{1}, 4000)}, entry{name: "b.class", data: bytes.Repeat([]byte{2}, 4000)})
	fi, _ := os.Stat(h.input)
	cases := []struct {
		name                         string
		maxFiles, maxBytes, maxClass int64
		want                         string
	}{
		{"input size", 10, fi.Size() - 1, 10, "input exceeds --max-bytes"},
		{"entry count", 1, 1 << 20, 10, "JAR entry count exceeds --max-files"},
		{"expanded bytes", 10, 7999, 10, "JAR expanded bytes exceed --max-bytes"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			_, err := jarInventory(h.input, c.maxFiles, c.maxBytes, c.maxClass)
			if err == nil || err.Error() != c.want {
				t.Fatalf("err = %v, want %q", err, c.want)
			}
		})
	}
	// The input-size cap is checked before the archive is even opened.
	notZip := filepath.Join(h.root, "x.bin")
	if err := os.WriteFile(notZip, bytes.Repeat([]byte("z"), 50), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := jarInventory(notZip, 10, 10, 10); err == nil || err.Error() != "input exceeds --max-bytes" {
		t.Fatalf("err = %v", err)
	}
	if _, err := jarInventory(notZip, 10, 1000, 10); err == nil || err.Error() != "input is not a valid JAR/ZIP" {
		t.Fatalf("err = %v", err)
	}
}

func TestExpectedClassesFollowTheJavaRules(t *testing.T) {
	h := newHarness(t)
	c := classBytes(52, false)
	writeJar(t, h.input,
		entry{name: "p/B.class", data: c}, entry{name: "p/A.class", data: c}, entry{name: "p/A$Inner.class", data: c},
		entry{name: "module-info.class", data: c}, entry{name: "p/package-info.class", data: c},
		entry{name: "META-INF/versions/11/p/A.class", data: c}, entry{name: "p/readme.txt", data: []byte("x")}, entry{name: "dir.class/", data: nil})
	inv, err := jarInventory(h.input, 100, 1<<20, 100)
	if err != nil {
		t.Fatal(err)
	}
	if want := []string{"p.A", "p.A$Inner", "p.B"}; !reflect.DeepEqual(inv.expectedClasses, want) || inv.expectedTotal != 3 || inv.classesTruncated {
		t.Errorf("expected = %v total %d truncated %v, want %v", inv.expectedClasses, inv.expectedTotal, inv.classesTruncated, want)
	}
	if !inv.multiRelease || len(inv.classEntries) != 6 || inv.entryCount != 8 {
		t.Errorf("multiRelease=%v classEntries=%v entries=%d", inv.multiRelease, inv.classEntries, inv.entryCount)
	}
	inv, err = jarInventory(h.input, 100, 1<<20, 2)
	if err != nil {
		t.Fatal(err)
	}
	if !inv.classesTruncated || inv.expectedTotal != 3 || !reflect.DeepEqual(inv.expectedClasses, []string{"p.A", "p.A$Inner"}) {
		t.Errorf("truncated inventory = %+v", inv)
	}
}

func TestEmptyArchiveYieldsEmptyListsNotNull(t *testing.T) {
	h := newHarness(t)
	writeJar(t, h.input)
	inv, err := jarInventory(h.input, 100, 1<<20, 100)
	if err != nil {
		t.Fatal(err)
	}
	if inv.classEntries == nil || inv.expectedClasses == nil || len(inv.classEntries) != 0 || inv.multiRelease {
		t.Fatalf("inventory = %+v", inv)
	}
}

// corruptDeflate returns a jar whose only entry has a valid central directory and a damaged deflate stream.
func corruptDeflate(t *testing.T, path string) {
	t.Helper()
	payload := bytes.Repeat([]byte("class body "), 40)
	var comp bytes.Buffer
	w, _ := flate.NewWriter(&comp, flate.BestCompression)
	_, _ = w.Write(payload)
	_ = w.Close()
	data := comp.Bytes()
	data[0], data[1] = 0x07, 0xff // a reserved block type
	name := []byte("bad.class")
	var b bytes.Buffer
	local := append([]byte("PK\x03\x04"), make([]byte, 26)...)
	binary.LittleEndian.PutUint16(local[4:], 20)
	binary.LittleEndian.PutUint16(local[8:], 8)
	binary.LittleEndian.PutUint32(local[14:], crc32.ChecksumIEEE(payload))
	binary.LittleEndian.PutUint32(local[18:], uint32(len(data)))
	binary.LittleEndian.PutUint32(local[22:], uint32(len(payload)))
	binary.LittleEndian.PutUint16(local[26:], uint16(len(name)))
	b.Write(local)
	b.Write(name)
	b.Write(data)
	cdStart := b.Len()
	cd := append([]byte("PK\x01\x02"), make([]byte, 42)...)
	binary.LittleEndian.PutUint16(cd[4:], 20)
	binary.LittleEndian.PutUint16(cd[6:], 20)
	binary.LittleEndian.PutUint16(cd[10:], 8)
	binary.LittleEndian.PutUint32(cd[16:], crc32.ChecksumIEEE(payload))
	binary.LittleEndian.PutUint32(cd[20:], uint32(len(data)))
	binary.LittleEndian.PutUint32(cd[24:], uint32(len(payload)))
	binary.LittleEndian.PutUint16(cd[28:], uint16(len(name)))
	b.Write(cd)
	b.Write(name)
	end := append([]byte("PK\x05\x06"), make([]byte, 18)...)
	binary.LittleEndian.PutUint16(end[8:], 1)
	binary.LittleEndian.PutUint16(end[10:], 1)
	binary.LittleEndian.PutUint32(end[12:], uint32(b.Len()-cdStart))
	binary.LittleEndian.PutUint32(end[16:], uint32(cdStart))
	b.Write(end)
	if err := os.WriteFile(path, b.Bytes(), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestCorruptDeflateEntryIsATypedRefusalNotACrash(t *testing.T) {
	h := newHarness(t)
	corruptDeflate(t, h.input)
	r := h.run(h.args("--output", h.out("corrupt"))...)
	if r.rc != 2 || !strings.Contains(r.err, "corrupt JAR entry: error") || strings.Contains(r.err, "goroutine") {
		t.Fatalf("rc=%d stderr=%q", r.rc, r.err)
	}
	if h.exists(h.out("corrupt")) || h.exists(h.root, ".corrupt.stage") {
		t.Error("nothing may be published for a corrupt archive")
	}
}

func TestBadCRCNamesTheEntry(t *testing.T) {
	h := newHarness(t)
	writeJar(t, h.input, entry{name: "x.class", data: classBytes(52, false), stored: true})
	raw, err := os.ReadFile(h.input)
	if err != nil {
		t.Fatal(err)
	}
	i := bytes.Index(raw, classBytes(52, false)[:8])
	raw[i+10] ^= 0xff // flip a body byte: the stored CRC no longer matches
	if err := os.WriteFile(h.input, raw, 0o644); err != nil {
		t.Fatal(err)
	}
	r := h.run(h.args("--output", h.out("crc"))...)
	if r.rc != 2 || !strings.Contains(r.err, "corrupt JAR entry: x.class") {
		t.Fatalf("rc=%d stderr=%q", r.rc, r.err)
	}
}

func TestInputThatIsNotAnArchiveIsRefused(t *testing.T) {
	h := newHarness(t)
	if err := os.WriteFile(h.input, []byte("not a zip at all"), 0o644); err != nil {
		t.Fatal(err)
	}
	r := h.run(h.args("--output", h.out("nz"))...)
	if r.rc != 2 || !strings.Contains(r.err, "input is not a valid JAR/ZIP") {
		t.Fatalf("rc=%d stderr=%q", r.rc, r.err)
	}
}

func TestInputIdentityFailuresAreTyped(t *testing.T) {
	h := newHarness(t)
	for name, path := range map[string]string{"missing": filepath.Join(h.root, "nope.jar"), "directory": h.root} {
		in := h.input
		h.input = path
		r := h.run(h.args("--output", h.out("id"))...)
		h.input = in
		want := "file identity cannot be opened safely"
		if name == "directory" {
			want = "file identity is not a regular file"
		}
		if r.rc != 2 || !strings.Contains(r.err, want) {
			t.Errorf("%s: rc=%d stderr=%q, want %q", name, r.rc, r.err, want)
		}
	}
}

func TestClassFactsAreReportedPerClassWithTypedNulls(t *testing.T) {
	h := newHarness(t)
	headerOnly := append(classBytes(52, false)[:8:8], 0, 0)
	writeJar(t, h.input,
		entry{name: "a/Old.class", data: classBytes(52, true)},
		entry{name: "a/New.class", data: classBytes(65, false)},
		entry{name: "a/Short.class", data: []byte{0xca, 0xfe, 0xba, 0xbe, 0, 0, 0}},
		entry{name: "a/Magic.class", data: append([]byte{0xde, 0xad, 0xbe, 0xef, 0, 0, 0, 52}, 0, 0)},
		entry{name: "a/Header.class", data: headerOnly})
	r := h.run(h.args("--output", h.out("facts"))...)
	if r.rc != 0 {
		t.Fatalf("rc=%d %s", r.rc, r.err)
	}
	rep := h.report(h.out("facts"))
	want := map[string][5]any{ // major, lvt, risk, reason
		"a/Old.class":    {float64(52), true, false, nil},
		"a/New.class":    {float64(65), false, true, nil},
		"a/Short.class":  {nil, nil, nil, "truncated-header"},
		"a/Magic.class":  {nil, nil, nil, "bad-magic"},
		"a/Header.class": {float64(52), nil, false, "truncated-body"},
	}
	for _, f := range rep["class_facts"].([]any) {
		rec := f.(map[string]any)
		w, ok := want[rec["entry"].(string)]
		if !ok {
			t.Fatalf("unexpected entry %v", rec)
		}
		got := [5]any{rec["major_version"], rec["has_LocalVariableTable"], rec["resugar_risk"], rec["reason"]}
		if got != w {
			t.Errorf("%s: facts = %v, want %v", rec["entry"], got[:4], w[:4])
		}
	}
	if len(rep["class_facts"].([]any)) != len(want) {
		t.Errorf("class_facts has %d records", len(rep["class_facts"].([]any)))
	}
	s := rep["class_facts_summary"].(map[string]any)
	if s["classes"] != float64(5) || s["lvt"] != "mixed" || s["resugar_risk_classes"] != float64(1) ||
		s["unreadable_classes"] != float64(2) || s["partial_classes"] != float64(1) || fmt.Sprint(s["major_versions"]) != "[52 65]" {
		t.Errorf("summary = %v", s)
	}
}

func TestFactsOfAnUnreadableEntryCarryTheirReason(t *testing.T) {
	h := newHarness(t)
	big := bytes.Repeat([]byte{0xca}, 64)
	writeJar(t, h.input, entry{name: "Big.class", data: big, stored: true}, entry{name: "Ok.class", data: classBytes(61, false)})
	h.env["RSDD_CLASSFACTS_MAX_CLASS_BYTES"] = "32"
	r := h.run(h.args("--output", h.out("limit"))...)
	if r.rc != 0 {
		t.Fatalf("rc=%d %s", r.rc, r.err)
	}
	facts := h.report(h.out("limit"))["class_facts"].([]any)
	byName := map[string]map[string]any{}
	for _, f := range facts {
		byName[f.(map[string]any)["entry"].(string)] = f.(map[string]any)
	}
	if byName["Big.class"]["reason"] != "entry-too-large" || byName["Big.class"]["major_version"] != nil {
		t.Errorf("Big = %v", byName["Big.class"])
	}
	// classBytes is larger than 32 bytes too, so it is the limit and not the content that decides.
	if byName["Ok.class"]["reason"] != "entry-too-large" {
		t.Errorf("Ok = %v", byName["Ok.class"])
	}
}

func TestMalformedClassFactsLimitWarnsOnceAndRunSurvives(t *testing.T) {
	h := newHarness(t)
	for _, bad := range []string{"abc", "0", "-5", "²", "٣"} {
		h.env["RSDD_CLASSFACTS_MAX_CLASS_BYTES"] = bad
		r := h.run(h.args("--output", h.out("bad"), "--overwrite")...)
		if r.rc != 0 {
			t.Fatalf("%q: rc=%d %s", bad, r.rc, r.err)
		}
		if n := strings.Count(r.err, "WARN: classfile-facts: invalid RSDD_CLASSFACTS_MAX_CLASS_BYTES="); n != 1 {
			t.Errorf("%q: %d warnings in %q", bad, n, r.err)
		}
		if h.report(h.out("bad"))["status"] != "complete" {
			t.Errorf("%q: run did not complete", bad)
		}
	}
}
