package niagara

import (
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"syscall"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/niagara/bogtest"
)

// The expected values below are what the legacy script's regular expressions produce (CPython 3.15); the
// differential test runs the same inputs through the frozen script, so a wrong expectation cannot hide.

type refs = map[string][]string

// stationRefsCases are shared with the parity test.
var stationRefsCases = []struct {
	name       string
	text       string
	want       refs
	unresolved int
}{
	{"alias and type", `<p m='a=mod b=baja' t='a:X'/><p t='b:Y'/>`, refs{"mod": {"X"}, "baja": {"Y"}}, 0},
	{"an undeclared alias is counted", `<p t='z:Foo'/>`, refs{}, 1},
	{"double quotes", `<p m="a=mod" t="a:X"/>`, refs{"mod": {"X"}}, 0},
	{"mixed quote kinds close a value", `<p m="a=mod' t='a:X"/>`, refs{"mod": {"X"}}, 0},
	{"a module with no type is still listed", `<p m='a=mod'/>`, refs{"mod": {}}, 0},
	{"types are unique and sorted", `<m='a=mod'/><p t='a:B'/><p t='a:A'/><p t='a:B'/>`, refs{"mod": {"A", "B"}}, 0},
	{"m= must start a word", `<p xm='a=mod' t='a:X'/>`, refs{}, 1},
	{"a non-ASCII letter before m= is a word character", `<p ém='a=mod' t='a:X'/>`, refs{}, 1},
	{"a dash before m= is not", `<p -m='a=mod' t='a:X'/>`, refs{"mod": {"X"}}, 0},
	{"t= must start a word", `<p m='a=mod' at='a:X'/>`, refs{"mod": {}}, 0},
	{"an empty module name is falsy: the type is unresolved", `<p m='a=' t='a:X'/>`, refs{"": {}}, 1},
	{"later declarations override earlier ones", `<p m='a=x'/><p m='a=y' t='a:T'/>`, refs{"y": {"T"}}, 0},
	{"all declarations are read before any type: the last one wins even for an earlier reference", `<p m='a=x' t='a:T'/><p m='a=y'/>`, refs{"y": {"T"}}, 0},
	{"a part without = is ignored", `<p m='junk a=mod' t='a:X'/>`, refs{"mod": {"X"}}, 0},
	{"the module keeps later equals signs", `<p m='a=b=c' t='a:X'/>`, refs{"b=c": {"X"}}, 0},
	{"a type name with a dash does not match", `<p m='a=mod' t='a:X-Y'/>`, refs{"mod": {}}, 0},
	{"a type with two colons does not match", `<p m='a=mod' t='a:b:C'/>`, refs{"mod": {}}, 0},
	{"an alias with a tab does not match", "<p m='a=mod' t='a\tb:X'/>", refs{"mod": {}}, 0},
	{"an alias with a no-break space does not match", "<p m='a=mod' t='a\u00a0b:X'/>", refs{"mod": {}}, 0},
	{"an alias with a C0 separator does not match", "<p m='a=mod' t='a\x1cb:X'/>", refs{"mod": {}}, 0},
	{"an alias with a space does not match", `<p m='a=mod' t='a b:X'/>`, refs{"mod": {}}, 0},
	{"a hyphenated alias", `<p m='honbac-util=hon' t='honbac-util:Net'/>`, refs{"hon": {"Net"}}, 0},
	{"a non-ASCII alias", `<p m='é=mod' t='é:X'/>`, refs{"mod": {"X"}}, 0},
	{"a digit-led and underscore type", `<p m='a=mod' t='a:_9x'/>`, refs{"mod": {"_9x"}}, 0},
	{"an empty m= value does not match", `<p m='' t='a:X'/>`, refs{}, 1},
	{"a value closes at the next quote of either kind, and a t= inside it is still a reference", `<p m='a=mod t='a:X'`, refs{"": {}, "mod": {"X"}}, 0},
	{"m= with no quote", `<p m=a=mod t='a:X'/>`, refs{}, 1},
	{"nothing", ``, refs{}, 0},
}

func TestParseStationRefs(t *testing.T) {
	for _, tt := range stationRefsCases {
		t.Run(tt.name, func(t *testing.T) {
			got, unresolved := parseStationRefs(strings.Split(tt.text, "\n"))
			if !reflect.DeepEqual(got, tt.want) || unresolved != tt.unresolved {
				t.Errorf("parseStationRefs(%q) = %v, %d; want %v, %d", tt.text, got, unresolved, tt.want, tt.unresolved)
			}
		})
	}
}

// Module and attribute values may span lines: the legacy parser joins the lines with \n before matching.
func TestParseStationRefsJoinsLines(t *testing.T) {
	got, _ := parseStationRefs([]string{"<p m='a=x", "b=y'", "t='b:T'/>"})
	if want := map[string][]string{"x": {}, "y": {"T"}}; !reflect.DeepEqual(got, want) {
		t.Errorf("got %v, want %v", got, want)
	}
}

// moduleXMLCases are shared with the parity test.
var moduleXMLCases = []struct {
	name     string
	xml      string
	part     string
	module   string
	types    []string
	ok       bool
	partOnly bool
}{
	{"typical", `<?xml version="1.0"?><module name="baja-rt" moduleName="baja" runtimeProfile="rt"><type name="A"/><type name='B'/></module>`, "baja-rt", "baja", []string{"A", "B"}, true, false},
	{"no module element", `<other name="x"/>`, "", "", nil, false, false},
	{"the module name may come first", `<module moduleName="m" name="p"/>`, "p", "m", nil, true, false},
	{"modules is not module", `<modules name="x"/><module name="p" moduleName="m"/>`, "p", "m", nil, true, false},
	{"only modules is no module", `<modules name="x"/>`, "", "", nil, false, false},
	{"no attributes: ok with an empty part", `<module>`, "", "", nil, true, false},
	{"xname is not name", `<module xname="a" name="b"/>`, "b", "", nil, true, false},
	{"a non-ASCII letter before name is a word character", `<module énom="a" éname="x" name="b"/>`, "b", "", nil, true, false},
	{"mixed quotes", `<module name="p' moduleName='m"/>`, "p", "m", nil, true, false},
	{"attributes end at the first >", `<module name="a>b"/>`, "", "", nil, true, false},
	{"the module element may be preceded by anything", "garbage\n<module name='p'", "p", "", nil, true, false},
	{"types: only <type", `<module name="p"><types name="C"/><type name="A"/></module>`, "p", "", []string{"A"}, true, false},
	{"a type's last name attribute wins", `<module name="p"><type name="A" name="B"/></module>`, "p", "", []string{"B"}, true, false},
	{"a type's value may hold >", `<module name="p"><type foo="1" name="a>b"/></module>`, "p", "", []string{"a>b"}, true, false},
	{"a type may span lines", "<module name=\"p\"><type\n name=\"A\"\n/></module>", "p", "", []string{"A"}, true, false},
	{"an empty type name is kept", `<module name="p"><type name=""/></module>`, "p", "", []string{""}, true, false},
	{"type-x still starts a type", `<module name="p"><type-x name="A"/></module>`, "p", "", []string{"A"}, true, false},
	{"typeX does not", `<module name="p"><typeX name="A"/></module>`, "p", "", nil, true, false},
	{"a word character before name hides it in a type", `<module name="p"><type éname="A"/></module>`, "p", "", nil, true, false},
	{"a word character after the element name hides it", `<module name="p"><typeé name="A"/></module>`, "p", "", nil, true, false},
	{"a word character after module hides the element", `<moduleé name="p"/>`, "", "", nil, false, false},
	{"a type with an unterminated name is skipped and scanning goes on", `<module name="p"><type name="A/><type name="B"/></module>`, "p", "", []string{"A/><type name="}, true, false},
	{"duplicate types collapse", `<module name="p"><type name="A"/><type name="A"/></module>`, "p", "", []string{"A"}, true, false},
}

func TestParseModuleXML(t *testing.T) {
	for _, tt := range moduleXMLCases {
		t.Run(tt.name, func(t *testing.T) {
			part, module, types, ok := parseModuleXML(tt.xml)
			var got []string
			for k := range types {
				got = append(got, k)
			}
			sortStrings(got)
			want := append([]string(nil), tt.types...)
			sortStrings(want)
			if part != tt.part || module != tt.module || ok != tt.ok || !reflect.DeepEqual(got, want) {
				t.Errorf("parseModuleXML(%q) = %q, %q, %v, %v; want %q, %q, %v, %v", tt.xml, part, module, got, ok, tt.part, tt.module, want, tt.ok)
			}
		})
	}
}

func sortStrings(s []string) {
	for i := 1; i < len(s); i++ {
		for j := i; j > 0 && s[j] < s[j-1]; j-- {
			s[j], s[j-1] = s[j-1], s[j]
		}
	}
}

// ---- install scan, through the command ----

func smInstall(t *testing.T, files map[string][]byte) string {
	t.Helper()
	root := filepath.Join(t.TempDir(), "inst")
	saMkdir(t, filepath.Join(root, "modules"))
	for name, data := range files {
		smWrite(t, filepath.Join(root, "modules", name), data)
	}
	return root
}

func moduleXMLJar(xml string) []byte {
	return bogtest.Zip(bogtest.Entry{Name: "META-INF/module.xml", Data: []byte(xml)})
}

func TestSMInstallScanCounts(t *testing.T) {
	fx := smFix(t)
	root := smInstall(t, map[string][]byte{
		"a-rt.jar":   smJar("a", "a-rt", "T"),
		"notes.txt":  []byte("not a jar"),
		"UPPER.JAR":  smJar("u", "u-rt"),
		"broken.jar": []byte("not a zip"),
		"empty.jar":  moduleXMLJar(`<other/>`),
		"nopart.jar": moduleXMLJar(`<module moduleName="x"/>`),
		"nomod.jar":  bogtest.Zip(bogtest.Entry{Name: "readme", Data: []byte("x")}),
	})
	saMkdir(t, filepath.Join(root, "modules", "dir.jar"))
	if err := os.Symlink(filepath.Join(root, "modules", "a-rt.jar"), filepath.Join(root, "modules", "link.jar")); err != nil {
		t.Fatal(err)
	}
	if err := syscall.Mkfifo(filepath.Join(root, "modules", "pipe.jar"), 0o600); err != nil {
		t.Fatal(err)
	}
	r := runModules(t, fx.bog["empty_station.bog"], root)
	if r.code != 0 {
		t.Fatalf("code=%d doc=%v", r.code, r.doc)
	}
	// .jar entries: a-rt broken empty nopart nomod dir link pipe = 8; read: a-rt broken empty nopart nomod = 5
	if r.num(t, "jars_total") != 8 || r.num(t, "jars_scanned") != 5 || r.num(t, "jars_skipped_oversized") != 0 {
		t.Errorf("summary = %v", r.obj(t, "summary"))
	}
}

func TestSMOversizedModuleXMLIsCountedAndTheCapIsInclusive(t *testing.T) {
	fx := smFix(t)
	pad := func(n int) string {
		head := `<module name="big-rt" moduleName="big"><type name="T"/>`
		return head + strings.Repeat(" ", n-len(head))
	}
	root := smInstall(t, map[string][]byte{
		"at.jar":   moduleXMLJar(strings.Replace(pad(64*1024), "big-rt", "at-rt", 1)),
		"over.jar": moduleXMLJar(pad(64*1024 + 1)),
	})
	r := runModules(t, fx.bog["valid.bog"], root)
	if r.num(t, "jars_skipped_oversized") != 1 || r.num(t, "jars_scanned") != 2 {
		t.Errorf("summary = %v", r.obj(t, "summary"))
	}
	if _, ok := r.obj(t, "modules")["baja"]; !ok {
		t.Fatal("baja missing")
	}
}

func TestSMLaterPartWinsOnDuplicates(t *testing.T) {
	fx := smFix(t)
	root := smInstall(t, map[string][]byte{
		"1.jar": smJar("first", "dup-rt", "T"),
		"2.jar": smJar("baja", "dup-rt", "Station", "ServiceContainer"),
	})
	r := runModules(t, fx.bog["valid.bog"], root)
	baja := r.obj(t, "modules", "baja")
	if got := r.strs(t, baja["installed_parts"]); !reflect.DeepEqual(got, []string{"dup-rt"}) {
		t.Errorf("installed_parts = %v: the later JAR (sorted by name) must win", got)
	}
}

func TestSMPartWithAnotherNameBelongsToItsModule(t *testing.T) {
	fx := smFix(t)
	root := smInstall(t, map[string][]byte{
		"ui.jar": smJar("baja", "baja-ux", "Station"),
		"rt.jar": smJar("baja", "baja-rt", "ServiceContainer"),
	})
	r := runModules(t, fx.bog["valid.bog"], root)
	baja := r.obj(t, "modules", "baja")
	if got := r.strs(t, baja["installed_parts"]); !reflect.DeepEqual(got, []string{"baja-rt", "baja-ux"}) {
		t.Errorf("installed_parts = %v", got)
	}
	if got := r.strs(t, baja["types_unresolved"]); len(got) != 0 {
		t.Errorf("a type provided by another part of the module is resolved, got %v", got)
	}
}

func TestSMMissingModuleWordingAndKey(t *testing.T) {
	fx := smFix(t)
	p := filepath.Join(fx.dir, "m.bog")
	smWrite(t, p, bogtest.Bog(`<p m='a=zeta b=alpha c=beta' t='a:B' /><p t='a:A'/><p t='b:Q'/>`))
	r := runModules(t, p, fx.empty)
	want := map[string]any{
		"alpha-rt": "module alpha not installed (type Q referenced)",
		"beta-rt":  "module beta referenced, no part installed",
		"zeta-rt":  "module zeta not installed (type A referenced)",
	}
	if !reflect.DeepEqual(r.obj(t, "missing_parts"), want) {
		t.Errorf("missing_parts = %v, want %v", r.obj(t, "missing_parts"), want)
	}
	if r.num(t, "jars_total") != 0 || r.num(t, "modules_referenced") != 3 || r.num(t, "missing_parts") != 3 {
		t.Errorf("summary = %v", r.obj(t, "summary"))
	}
	if r.doc["status"] != "complete" {
		t.Errorf("an empty install is complete, got %v", r.doc["status"])
	}
}

func TestSMUnresolvedAliasesAreCounted(t *testing.T) {
	fx := smFix(t)
	p := filepath.Join(fx.dir, "u.bog")
	smWrite(t, p, bogtest.Bog(`<p t='x:A'/><p t='y:B'/><p m='b=baja' t='b:Station'/>`))
	r := runModules(t, p, fx.install)
	if r.num(t, "unresolved_aliases") != 2 {
		t.Errorf("summary = %v", r.obj(t, "summary"))
	}
}

func TestSMInstallScanIsCappedAndSaysSo(t *testing.T) {
	fx := smFix(t)
	files := map[string][]byte{}
	tiny := smJar("m", "m-rt")
	for i := 0; i < 2001; i++ {
		files[fmt.Sprintf("j%04d.jar", i)] = tiny
	}
	root := smInstall(t, files)
	r := runModules(t, fx.bog["empty_station.bog"], root)
	if r.code != 0 || r.doc["status"] != "complete" || r.doc["truncated"] != true {
		t.Fatalf("code=%d status=%v truncated=%v", r.code, r.doc["status"], r.doc["truncated"])
	}
	if r.num(t, "jars_scanned") != 2000 || r.num(t, "jars_total") != 2001 {
		t.Errorf("summary = %v", r.obj(t, "summary"))
	}
	if got := r.strs(t, r.doc["errors"]); !reflect.DeepEqual(got, []string{"install scan truncated at 2000 JARs (2001 total)"}) {
		t.Errorf("errors = %v", got)
	}
}

func TestSMInstallRootForms(t *testing.T) {
	fx := smFix(t)
	t.Run("trailing separators are stripped and reported stripped", func(t *testing.T) {
		r := runModules(t, fx.bog["valid.bog"], fx.install+"///")
		if r.code != 0 || r.doc["install_root"] != fx.install {
			t.Errorf("code=%d install_root=%v", r.code, r.doc["install_root"])
		}
	})
	t.Run("a symlink root is refused, with or without a trailing slash", func(t *testing.T) {
		link := filepath.Join(fx.dir, "root-link")
		if err := os.Symlink(fx.install, link); err != nil {
			t.Fatal(err)
		}
		for _, arg := range []string{link, link + "/", link + "///"} {
			r := runModules(t, fx.bog["valid.bog"], arg)
			want := fmt.Sprintf("station-modules: install root is a symbolic link (rejected): '%s'\n", link)
			if r.code != 2 || r.doc != nil || r.stderr != want {
				t.Errorf("%q: code=%d stderr=%q", arg, r.code, r.stderr)
			}
		}
	})
	t.Run("a file root is refused", func(t *testing.T) {
		f := filepath.Join(fx.dir, "afile")
		smWrite(t, f, []byte("x"))
		r := runModules(t, fx.bog["valid.bog"], f)
		want := fmt.Sprintf("station-modules: install root is not a directory: '%s'\n", f)
		if r.code != 2 || r.doc != nil || r.stderr != want {
			t.Errorf("code=%d stderr=%q", r.code, r.stderr)
		}
	})
	t.Run("a name that is not UTF-8 is shown as Python escapes it", func(t *testing.T) {
		bad := filepath.Join(fx.dir, "bad\xffroot")
		r := runModules(t, fx.bog["valid.bog"], bad)
		want := fmt.Sprintf("station-modules: install root not found: '%s/bad\\udcffroot'\n", fx.dir)
		if r.code != 2 || r.stderr != want {
			t.Errorf("code=%d stderr=%q", r.code, r.stderr)
		}
	})
	t.Run("a bog path with a quote is printed bare", func(t *testing.T) {
		p := filepath.Join(fx.dir, "no'such.bog")
		r := runModules(t, p, fx.install)
		if want := "station-modules: " + p + ": No such file or directory\n"; r.stderr != want {
			t.Errorf("stderr = %q", r.stderr)
		}
	})
}

func TestSMModulesDirForms(t *testing.T) {
	fx := smFix(t)
	t.Run("modules is a symlink inside the root", func(t *testing.T) {
		root := filepath.Join(fx.dir, "r1")
		saMkdir(t, filepath.Join(root, "real"))
		if err := os.Symlink(filepath.Join(root, "real"), filepath.Join(root, "modules")); err != nil {
			t.Fatal(err)
		}
		r := runModules(t, fx.bog["valid.bog"], root)
		want := fmt.Sprintf("modules/ is a symbolic link (rejected): '%s/modules'", root)
		if got := r.strs(t, r.doc["errors"]); r.code != 1 || !reflect.DeepEqual(got, []string{want}) {
			t.Errorf("code=%d errors=%v", r.code, got)
		}
	})
	t.Run("modules is a file", func(t *testing.T) {
		root := filepath.Join(fx.dir, "r2")
		smWrite(t, filepath.Join(root, "modules"), []byte("x"))
		r := runModules(t, fx.bog["valid.bog"], root)
		want := fmt.Sprintf("modules/ is not a directory: '%s/modules'", root)
		if got := r.strs(t, r.doc["errors"]); r.code != 1 || !reflect.DeepEqual(got, []string{want}) {
			t.Errorf("code=%d errors=%v", r.code, got)
		}
	})
	t.Run("an install error keeps the alias count of the bog and reports no modules", func(t *testing.T) {
		root := filepath.Join(fx.dir, "r3")
		saMkdir(t, root)
		p := filepath.Join(fx.dir, "ua.bog")
		smWrite(t, p, bogtest.Bog(`<p t='x:A'/>`))
		r := runModules(t, p, root)
		if r.code != 1 || r.num(t, "unresolved_aliases") != 1 || r.num(t, "modules_referenced") != 0 {
			t.Errorf("code=%d summary=%v", r.code, r.obj(t, "summary"))
		}
	})
	t.Run("a bog failure wins over an install failure and the install is not scanned", func(t *testing.T) {
		root := filepath.Join(fx.dir, "r4")
		saMkdir(t, root)
		r := runModules(t, fx.bog["binary.bog"], root)
		if got := r.strs(t, r.doc["errors"]); r.code != 1 || !reflect.DeepEqual(got, []string{"content is neither a ZIP nor XML"}) {
			t.Errorf("code=%d errors=%v", r.code, got)
		}
	})
}

// A bog that is a ZIP by its first two bytes is read as one, even when it is shorter than four bytes.
func TestSMShortInputs(t *testing.T) {
	fx := smFix(t)
	for _, tt := range []struct {
		name, content, format, err string
	}{
		{"PK only", "PK", "unknown", "not a valid ZIP: File is not a zip file"},
		{"PK and a byte", "PKx", "unknown", "not a valid ZIP: File is not a zip file"},
		{"one byte", "P", "unknown", "content is neither a ZIP nor XML"},
		{"empty", "", "unknown", "content is neither a ZIP nor XML"},
		{"blank", " \n\t", "unknown", "content is neither a ZIP nor XML"},
		{"zip without file.xml", string(bogtest.Zip(bogtest.Entry{Name: "other.xml", Data: []byte("<a/>")})), "unknown", "ZIP contains no file.xml entry"},
		{"leading space then XML", "  \n<a/>", "plaintext-xml", ""},
	} {
		t.Run(tt.name, func(t *testing.T) {
			p := filepath.Join(fx.dir, "short.bog")
			_ = os.Remove(p)
			smWrite(t, p, []byte(tt.content))
			r := runModules(t, p, fx.install)
			if f := r.obj(t, "input")["format"]; f != tt.format {
				t.Errorf("format = %v, want %v", f, tt.format)
			}
			errs := r.strs(t, r.doc["errors"])
			if tt.err == "" && len(errs) != 0 || tt.err != "" && !reflect.DeepEqual(errs, []string{tt.err}) {
				t.Errorf("errors = %v, want %q", errs, tt.err)
			}
		})
	}
}

func TestSMOutputIsPrivateAndIsTheOnlyFileWritten(t *testing.T) {
	fx := smFix(t)
	r := runModules(t, fx.bog["valid.bog"], fx.install)
	fi, err := os.Stat(r.out)
	if err != nil || fi.Mode().Perm() != 0o600 {
		t.Errorf("output: %v, %v", fi, err)
	}
	raw, _ := os.ReadFile(r.out)
	if !strings.HasSuffix(string(raw), "}\n") || !strings.HasPrefix(string(raw), "{\n  \"errors\": [],\n") {
		t.Errorf("output is not key-sorted indent-2 JSON: %.80q", raw)
	}
}

func TestSMDocumentCarriesTheLimitationsAndNeverASlotValue(t *testing.T) {
	fx := smFix(t)
	p := filepath.Join(fx.dir, "secret.bog")
	smWrite(t, p, bogtest.Bog(`<p m='b=baja' t='b:Station' password='hunter2' v='4.14.0'/>`))
	r := runModules(t, p, fx.install)
	raw, _ := os.ReadFile(r.out)
	if strings.Contains(string(raw), "hunter2") || strings.Contains(string(raw), "4.14.0") || strings.Contains(string(raw), "Tridium") {
		t.Errorf("evidence leaks a slot value, a version or a vendor:\n%s", raw)
	}
	want := []string{
		"Install JAR scan capped at 2000 entries.",
		"ZIP file.xml inflate capped at 32 MiB (zip-bomb protection).",
		"Plaintext bog read capped at 32 MiB (zip-bomb defence).",
		"Slot values are never emitted (secrets discipline).",
		"Fix operations are not performed (read-only tool).",
	}
	if got := r.strs(t, r.doc["limitations"]); !reflect.DeepEqual(got, want) {
		t.Errorf("limitations = %v", got)
	}
}

// sorted() orders os.listdir() names by code point, a byte that is not UTF-8 counting as the lone surrogate
// U+DC00+byte. The later of two JARs declaring one part wins, so the order is observable.
func TestSMJarOrderFollowsPythonSurrogateEscape(t *testing.T) {
	fx := smFix(t)
	p := filepath.Join(fx.dir, "baja.bog")
	smWrite(t, p, bogtest.Bog(`<p m='b=baja' t='b:Station'/>`))
	for _, tt := range []struct {
		other      string
		bajaIsLast bool
	}{
		{"\u00e9.jar", true},      // U+00E9 < U+DCFF: the invalid name sorts after it
		{"\uf000.jar", false},     // U+F000 > U+DCFF
		{"\U0001f600.jar", false}, // an astral character is above every surrogate
	} {
		t.Run(fmt.Sprintf("%q", tt.other), func(t *testing.T) {
			root := smInstall(t, map[string][]byte{
				"\xff.jar": smJar("baja", "dup-rt", "Station"),
				tt.other:   smJar("other", "dup-rt", "Station"),
			})
			r := runModules(t, p, root)
			got := r.strs(t, r.obj(t, "modules", "baja")["installed_parts"])
			if (len(got) == 1) != tt.bajaIsLast {
				t.Errorf("installed_parts = %v; the winner must be the name Python sorts last", got)
			}
		})
	}
}

func TestSMModuleXMLIsDecodedLeniently(t *testing.T) {
	fx := smFix(t)
	root := smInstall(t, map[string][]byte{"p.jar": moduleXMLJar("<module name=\"p\xff-rt\" moduleName=\"baja\"/>")})
	r := runModules(t, fx.bog["valid.bog"], root)
	got := r.strs(t, r.obj(t, "modules", "baja")["installed_parts"])
	if !reflect.DeepEqual(got, []string{"p\ufffd-rt"}) {
		t.Errorf("installed_parts = %q", got)
	}
}

func TestSMPartWithoutANameIsScannedButNotIndexed(t *testing.T) {
	fx := smFix(t)
	root := smInstall(t, map[string][]byte{"p.jar": moduleXMLJar(`<module moduleName="baja"/>`)})
	r := runModules(t, fx.bog["valid.bog"], root)
	if got := r.strs(t, r.obj(t, "modules", "baja")["installed_parts"]); len(got) != 0 || r.num(t, "jars_scanned") != 1 {
		t.Errorf("installed_parts = %q, summary = %v", got, r.obj(t, "summary"))
	}
	if _, ok := r.obj(t, "missing_parts")["baja-rt"]; !ok {
		t.Errorf("missing_parts = %v", r.obj(t, "missing_parts"))
	}
}
