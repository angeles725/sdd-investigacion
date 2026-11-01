package classfile

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

type env map[string]string

// run executes the command on a file holding input, with the given environment.
func run(t *testing.T, input []byte, e env) (stdout, stderr string, code int) {
	t.Helper()
	p := filepath.Join(t.TempDir(), "in.bin")
	if err := os.WriteFile(p, input, 0o644); err != nil {
		t.Fatal(err)
	}
	return runPath(p, e)
}

func runPath(arg string, e env) (stdout, stderr string, code int) {
	var out, errw bytes.Buffer
	s := cli.Stdio{Out: &out, Err: &errw, Env: func(k string) string { return e[k] }}
	code = Run([]string{arg}, s)
	return out.String(), errw.String(), code
}

const bs = "\\"

// line is the CLASSFILE line for the given parts.
func line(major, lvt string, classes int, risk string, unreadable, partial int, truncated string) string {
	l := fmt.Sprintf("CLASSFILE major=%s lvt=%s classes=%d resugar_risk=%s unreadable=%d partial=%d truncated=%s", major, lvt, classes, risk, unreadable, partial, truncated)
	if truncated != "none" {
		l += " reason=facts-truncated:" + truncated
	}
	return l + "\n"
}

func unreadableInput(class string) string {
	return "CLASSFILE major=unknown lvt=unknown classes=unknown resugar_risk=unknown unreadable=unknown partial=unknown truncated=unknown reason=unreadable-input(" + class + ")\n"
}

var (
	c52 = buildClass(classOpts{major: 52, lvt: true})
	c65 = buildClass(classOpts{major: 65})

	lineEmptyJar = line("unknown", "unknown", 0, "unknown", 0, 0, "none")
	lineMixed    = line("52-65", "mixed", 2, "yes", 0, 0, "none")
	lineOneBad   = line("unknown", "unknown", 1, "unknown", 1, 0, "none")
)

func twoClasses() []zent {
	return []zent{ent("p/Old.class", c52, 0), ent("p/New.class", c65, 8)}
}

type lineCase struct {
	name  string
	input []byte
	env   env
	want  string
}

func lineCases() []lineCase {
	good := buildZip(twoClasses(), zopts{})
	cdByte := func(off int) []byte { // flip one byte of the first central-directory header
		b := append([]byte(nil), good...)
		b[bytes.Index(b, []byte("PK\x01\x02"))+off] ^= 0xff
		return b
	}
	return []lineCase{
		{"class file, Java 8 with LVT", c52, nil, line("52", "yes", 1, "no", 0, 0, "none")},
		{"class file, Java 21 without LVT", c65, nil, line("65", "no", 1, "yes", 0, 0, "none")},
		{"class file with a truncated body is partial, its major still counts", c65[:len(c65)-1], nil, line("65", "unknown", 1, "yes", 0, 1, "none")},
		{"bad magic is unreadable, never a fake major", []byte("not a class file at all"), nil, lineOneBad},
		{"empty file is unreadable", nil, nil, lineOneBad},
		{"jar: stored and deflated entries, mixed versions", good, nil, lineMixed},
		{"jar with a comment", buildZip(twoClasses(), zopts{comment: []byte("hello jar")}), nil, lineMixed},
		{"jar appended to other data", buildZip(twoClasses(), zopts{prepend: bytes.Repeat([]byte("x"), 211)}), nil, lineMixed},
		{"jar with a ZIP64 end record", buildZip(twoClasses(), zopts{zip64: true}), nil, lineMixed},
		{"jar with ZIP64 extra fields on an entry", buildZip([]zent{
			func() zent {
				e := ent("p/Old.class", c52, 0)
				e.usize, e.csize, e.cextra = 0xFFFFFFFF, 0xFFFFFFFF, zip64Extra(uint64(len(c52)), uint64(len(c52)))
				return e
			}(), ent("p/New.class", c65, 8)}, zopts{}), nil, lineMixed},
		{"jar with no end record is read as a class: unreadable", good[:len(good)-30], nil, lineOneBad},
		{"jar without classes", buildZip([]zent{ent("README.txt", []byte("hi"), 0), ent("META-INF/", nil, 0)}, zopts{}), nil, lineEmptyJar},
		{"empty archive", buildZip(nil, zopts{}), nil, lineEmptyJar},
		{"entry with an empty name (a central header of exactly 46 bytes)", buildZip([]zent{ent("", c65, 0)}, zopts{}), nil, lineEmptyJar},
		{"directory and resource entries are not classes", buildZip([]zent{ent("p/", nil, 0), ent("p/data.bin", c65, 0), ent("p/A.class", c52, 0)}, zopts{}), nil, line("52", "yes", 1, "no", 0, 0, "none")},
		{"a name that merely contains .class is not a class", buildZip([]zent{ent("p/A.class.txt", c65, 0), ent("p/B.classx", c65, 0)}, zopts{}), nil, lineEmptyJar},
		{"unreadable class inside a jar counts, the rest still do", buildZip([]zent{ent("a/Bad.class", []byte("junk junk junk"), 0), ent("b/Ok.class", c65, 8)}, zopts{}), nil, line("65", "no", 2, "yes", 1, 0, "none")},
		{"partial class inside a jar", buildZip([]zent{ent("a/Cut.class", c52[:len(c52)-3], 0), ent("b/Ok.class", c65, 8)}, zopts{}), nil, line("52-65", "no", 2, "yes", 0, 1, "none")},
		{"central directory with a wrong signature", cdByte(0), nil, unreadableInput("BadZipFile")},
		{"version needed 6.3 still reads", buildZip([]zent{func() zent { e := ent("A.class", c52, 0); e.version = 63; return e }()}, zopts{}), nil, line("52", "yes", 1, "no", 0, 0, "none")},
		{"version needed 6.4 is not implemented", buildZip([]zent{func() zent { e := ent("A.class", c52, 0); e.version = 64; return e }()}, zopts{}), nil, unreadableInput("NotImplementedError")},
		{"central directory larger than the file", buildZip(twoClasses(), zopts{eocdMut: func(r []byte) { r[15] = 0x7f }}), nil, unreadableInput("BadZipFile")},
		{"central directory cut short by trailing bytes", buildZip(twoClasses(), zopts{cdTail: bytes.Repeat([]byte{7}, 10)}), nil, unreadableInput("BadZipFile")},
		{"duplicate names: the last entry answers for both", buildZip([]zent{ent("A.class", c52, 0), ent("A.class", c65, 0)}, zopts{}), nil, line("65", "no", 2, "yes", 0, 0, "none")},
		{"name cut at a NUL still ends in .class", buildZip([]zent{ent("A.class\x00junk", c65, 0)}, zopts{}), nil, line("65", "no", 1, "yes", 0, 0, "none")},
		{"name cut at a NUL no longer ends in .class", buildZip([]zent{ent("A\x00.class", c65, 0)}, zopts{}), nil, lineEmptyJar},
		{"entry name in a non-UTF-8 code page (cp437)", buildZip([]zent{ent("\x82.class", c65, 0)}, zopts{}), nil, line("65", "no", 1, "yes", 0, 0, "none")},
		{"invalid UTF-8 in a local header name is the helper's crash too", buildZip([]zent{func() zent { e := ent("A.class", c65, 0); e.lname, e.lflags = []byte("\xff.class"), 0x800; return e }()}, zopts{}), nil, ""},
		{"invalid UTF-8 in a flagged name is the helper's crash", buildZip([]zent{func() zent { e := ent("\xff.class", c65, 0); e.cflags = 0x800; return e }()}, zopts{}), nil, ""},
		// Limits.
		{"entry cap below the count truncates to the first names in order", buildZip([]zent{ent("b/B.class", c65, 0), ent("a/A.class", c52, 0), ent("c/C.class", c65, 0)}, zopts{}), env{envMaxEntries: "1"}, line("52", "yes", 1, "no", 0, 0, "entry-cap")},
		{"entry cap equal to the count is not a truncation", buildZip([]zent{ent("b/B.class", c65, 0), ent("a/A.class", c52, 0)}, zopts{}), env{envMaxEntries: "2"}, lineMixed},
		{"cp437 names sort by their decoded code point", buildZip([]zent{ent("\x82.class", c65, 0), ent("z.class", c52, 0)}, zopts{}), env{envMaxEntries: "1"}, line("52", "yes", 1, "no", 0, 0, "entry-cap")},
		{"byte cap stops before the entry that would exceed it", buildZip([]zent{ent("a/A.class", c52, 0), ent("b/B.class", c65, 0), ent("c/C.class", c65, 0)}, zopts{}),
			env{envMaxExpanded: fmt.Sprint(len(c52) + len(c65) + len(c65) - 1)}, line("52-65", "mixed", 2, "yes", 0, 0, "byte-cap")},
		{"byte cap equal to the total is not a truncation", buildZip([]zent{ent("a/A.class", c52, 0), ent("b/B.class", c65, 0)}, zopts{}),
			env{envMaxExpanded: fmt.Sprint(len(c52) + len(c65))}, lineMixed},
		{"byte cap wins over the entry cap in the label", buildZip([]zent{ent("a/A.class", c52, 0), ent("b/B.class", c65, 0), ent("c/C.class", c65, 0)}, zopts{}),
			env{envMaxEntries: "2", envMaxExpanded: fmt.Sprint(len(c52))}, line("52", "yes", 1, "no", 0, 0, "byte-cap")},
		{"entry larger than the class cap is unreadable", buildZip([]zent{ent("a/A.class", c52, 0), ent("b/B.class", c65, 0)}, zopts{}),
			env{envMaxClass: fmt.Sprint(len(c65))}, line("65", "no", 2, "yes", 1, 0, "none")},
		{"entry exactly at the class cap is read", buildZip([]zent{ent("a/A.class", c52, 0)}, zopts{}), env{envMaxClass: fmt.Sprint(len(c52))}, line("52", "yes", 1, "no", 0, 0, "none")},
		{"class file larger than the class cap is unreadable", c65, env{envMaxClass: fmt.Sprint(len(c65) - 1)}, lineOneBad},
		{"class file exactly at the class cap is read", c65, env{envMaxClass: fmt.Sprint(len(c65))}, line("65", "no", 1, "yes", 0, 0, "none")},
		{"a class limit between 2^63 and 2^64 is exact, not saturated", buildZip([]zent{func() zent {
			e := ent("A.class", c65, 0)
			e.usize, e.cextra = 0xFFFFFFFF, zip64Extra(1<<63+10)
			return e
		}()}, zopts{}), env{envMaxClass: "9223372036854775813", envMaxExpanded: "18446744073709551615"}, lineOneBad},
		{"limits above 64 bits saturate", good, env{envMaxEntries: "99999999999999999999999999", envMaxExpanded: "18446744073709551616", envMaxClass: "18446744073709551615"}, lineMixed},
		{"leading zeros are a valid limit", good, env{envMaxEntries: "0002"}, lineMixed},
	}
}

func TestRunClassfileFactsLines(t *testing.T) {
	t.Parallel()
	for _, tc := range lineCases() {
		t.Run(tc.name, func(t *testing.T) {
			out, errw, code := run(t, tc.input, tc.env)
			if tc.want == "" { // the helper's uncaught-exception path
				if code != cli.ExitOperational || out != "" || !strings.Contains(errw, "classfile-facts") {
					t.Fatalf("crash path: code=%d stdout=%q stderr=%q", code, out, errw)
				}
				return
			}
			if code != 0 || out != tc.want || errw != "" {
				t.Fatalf("code=%d\n got stdout %q\nwant stdout %q\n stderr %q", code, out, tc.want, errw)
			}
		})
	}
}

func TestRunUsage(t *testing.T) {
	t.Parallel()
	for _, args := range [][]string{nil, {}, {"a", "b"}, {"a", "b", "c"}} {
		var out, errw bytes.Buffer
		code := Run(args, cli.Stdio{Out: &out, Err: &errw, Env: func(string) string { return "" }})
		if code != cli.ExitUsage || out.Len() != 0 || errw.String() != "usage: rsdd corroborate classfile-facts <in.jar|in.class>\n" {
			t.Errorf("args %q: code=%d stdout=%q stderr=%q", args, code, out.String(), errw.String())
		}
	}
}

func TestRunUnreadablePaths(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	file := filepath.Join(dir, "a.class")
	if err := os.WriteFile(file, c65, 0o644); err != nil {
		t.Fatal(err)
	}
	jar := filepath.Join(dir, "a.jar")
	if err := os.WriteFile(jar, buildZip(twoClasses(), zopts{}), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(filepath.Join(dir, "d"), 0o755); err != nil {
		t.Fatal(err)
	}
	denied := filepath.Join(dir, "denied.class")
	if err := os.WriteFile(denied, c65, 0o000); err != nil {
		t.Fatal(err)
	}
	canRead := func() bool {
		f, err := os.Open(denied)
		f2 := f != nil
		if f2 {
			f.Close()
		}
		return err == nil
	}()
	for _, tc := range []struct {
		name, arg string
		want      string
		skip      bool
	}{
		{"missing file", filepath.Join(dir, "nope.jar"), unreadableInput("FileNotFoundError"), false},
		{"directory", filepath.Join(dir, "d"), unreadableInput("IsADirectoryError"), false},
		{"path through a file", file + "/sub", unreadableInput("NotADirectoryError"), false},
		{"name too long", filepath.Join(dir, strings.Repeat("a", 300)), unreadableInput("OSError"), false},
		{"permission denied", denied, unreadableInput("PermissionError"), canRead},
		{"empty argument is the current directory", "", unreadableInput("IsADirectoryError"), false},
		{"trailing slash is ignored like pathlib", jar + "/", lineMixed, false},
		{"dot components are ignored like pathlib", dir + "/./a.jar", lineMixed, false},
		{"doubled slashes are ignored like pathlib", dir + "//a.jar", lineMixed, false},
		{"a relative-looking dot dir", ".", unreadableInput("IsADirectoryError"), false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if tc.skip {
				t.Skip("the file is readable despite mode 000 (running as root?)")
			}
			out, errw, code := runPath(tc.arg, nil)
			if code != 0 || out != tc.want || errw != "" {
				t.Fatalf("code=%d stdout=%q want %q stderr=%q", code, out, tc.want, errw)
			}
		})
	}
}

func TestPyPath(t *testing.T) {
	t.Parallel()
	for in, want := range map[string]string{
		"": ".", ".": ".", "./": ".", "a": "a", "a/": "a", "./a": "a", "a//b": "a/b", "a/./b/": "a/b", "/": "/", "/a/b/": "/a/b",
		"//a": "/a", "a/../b": "a/../b", "..": "..", "../..": "../..",
	} {
		if got := pyPath(in); got != want {
			t.Errorf("pyPath(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestEnvLimitWarnings(t *testing.T) {
	t.Parallel()
	vars := []struct {
		name string
		def  string
	}{{envMaxEntries, "20000"}, {envMaxExpanded, "1073741824"}, {envMaxClass, "67108864"}}
	for _, tc := range []struct {
		raw, repr string // repr is Python's repr of raw; empty means no warning
	}{
		{"abc", `'abc'`}, {"0", `'0'`}, {"00", `'00'`}, {"-1", `'-1'`}, {"+5", `'+5'`}, {" 5", `' 5'`}, {"5 ", `'5 '`}, {"5\n", `'5\n'`},
		{"1.5", `'1.5'`}, {"0x10", `'0x10'`}, {"1_000", `'1_000'`}, {"\U00000663", "'\U00000663'"}, {"it's", `"it's"`}, {`a"b`, `'a"b'`}, {`it's "x"`, `'it\'s "x"'`},
		{"tab\there", `'tab\there'`}, {"cr\rhere", `'cr\rhere'`}, {"back\\slash", `'back\\slash'`}, {"\x01\x7f", `'\x01\x7f'`}, {"\xff", `'\udcff'`}, {"caf\xc3\xa9", "'caf\U000000e9'"},
		{"\xc2\xa0", `'\xa0'`}, {"\U0000200b", "'" + bs + "u200b'"}, {"\U0001f600", "'\U0001f600'"}, {"\U000e0001", `'\U000e0001'`},
		{"7", ""}, {"007", ""}, {"123456789012345678901234567890", ""}, {"", ""},
	} {
		for _, v := range vars {
			var errw bytes.Buffer
			got := envLimit(cli.Stdio{Err: &errw, Env: func(k string) string {
				if k == v.name {
					return tc.raw
				}
				return ""
			}}, v.name, 5)
			want := ""
			if tc.repr != "" {
				want = fmt.Sprintf("WARN: classfile-facts: invalid %s=%s; using default 5\n", v.name, tc.repr)
			}
			if errw.String() != want {
				t.Errorf("%s=%q: stderr %q, want %q", v.name, tc.raw, errw.String(), want)
			}
			if (tc.repr != "") != (got == 5) && tc.raw != "" && tc.raw != "7" && tc.raw != "007" {
				t.Errorf("%s=%q: limit %d", v.name, tc.raw, got)
			}
		}
	}
	// The default each variable falls back to is printed in the warning, and an accepted value is used as is.
	for _, v := range vars {
		out, errw, _ := run(t, c65, env{v.name: "nope"})
		if out != line("65", "no", 1, "yes", 0, 0, "none") || errw != fmt.Sprintf("WARN: classfile-facts: invalid %s='nope'; using default %s\n", v.name, v.def) {
			t.Errorf("%s: stdout %q stderr %q", v.name, out, errw)
		}
	}
	if got := envLimit(cli.Stdio{Env: func(string) string { return "0012" }}, "X", 5); got != 12 {
		t.Errorf("0012 = %d", got)
	}
	if got := envLimit(cli.Stdio{Env: func(string) string { return "18446744073709551616" }}, "X", 5); got != ^uint64(0) {
		t.Errorf("2^64 = %d, want saturation", got)
	}
}

func TestInvalidLimitsWarnOncePerVariableInOrder(t *testing.T) {
	t.Parallel()
	_, errw, _ := run(t, c65, env{envMaxClass: "x", envMaxEntries: "y", envMaxExpanded: "z"})
	want := "WARN: classfile-facts: invalid RSDD_CLASSFACTS_MAX_ENTRIES='y'; using default 20000\n" +
		"WARN: classfile-facts: invalid RSDD_CLASSFACTS_MAX_BYTES='z'; using default 1073741824\n" +
		"WARN: classfile-facts: invalid RSDD_CLASSFACTS_MAX_CLASS_BYTES='x'; using default 67108864\n"
	if errw != want {
		t.Fatalf("stderr %q, want %q", errw, want)
	}
}

func TestPyErrorMessage(t *testing.T) {
	t.Parallel()
	if got := (&pyError{"BadZipFile"}).Error(); got != "BadZipFile" {
		t.Fatalf("Error() = %q", got)
	}
}
