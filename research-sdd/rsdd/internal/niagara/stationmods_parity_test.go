package niagara

import (
	"crypto/sha256"
	"encoding/hex"
	"flag"
	"fmt"
	"math/rand"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/niagara/bog"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/niagara/bogtest"
)

// Differential parity for station-modules: the frozen legacy script (testdata/legacy/station_modules.py,
// byte-identical to station_modules.py at the base commit) and the Go command run on the same inputs in the same
// sandbox path, and stdout, stderr, exit code and everything the run left behind (name, mode, JSON content) must
// be byte-equal. The only differences allowed are the ones declared in smDeclared, each with the reason it cannot
// match; a declaration that no longer diverges fails.

// smLegacySHA256 pins the oracle: it is station_modules.py at 2f0748f2 (before the port). The oracle moves only
// with a recorded reason, never silently.
const smLegacySHA256 = "b7489bb72e8a2e8060b0a0f77940649e578ed792eb4dcae7a89e5f690a771caf"

var updateStationGolden = flag.Bool("update-stationmods-golden", false, "rewrite testdata/golden/stationmods_*.json from the legacy script")

func smLegacyScript(t *testing.T) string {
	t.Helper()
	p, err := filepath.Abs(filepath.Join("testdata", "legacy", "station_modules.py"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(p); err != nil {
		t.Fatalf("parity: frozen legacy script missing at %s (%v): a moved package must update the path, not skip", p, err)
	}
	return p
}

func TestStationModulesLegacyOracleIsFrozen(t *testing.T) {
	b, err := os.ReadFile(smLegacyScript(t))
	if err != nil {
		t.Fatal(err)
	}
	if sum := sha256.Sum256(b); hex.EncodeToString(sum[:]) != smLegacySHA256 {
		t.Errorf("testdata/legacy/station_modules.py sha256 = %x, want %s: the parity oracle changed", sum, smLegacySHA256)
	}
}

// smDeclared are the divergences, keyed by case name. normalise is applied to the output of BOTH sides.
var smDeclared = map[string]struct {
	reason    string
	normalise func(string) string
}{
	"suite_corrupt.bog_std_install":            {"the text after 'Error -3 while decompressing data: ' is zlib's internal reason; Go's inflater words its own", zlibReason},
	"suite_corrupt.bog_empty_install":          {"the text after 'Error -3 while decompressing data: ' is zlib's internal reason; Go's inflater words its own", zlibReason},
	"bogsuite_corrupt_deflate.bog":             {"the text after 'Error -3 while decompressing data: ' is zlib's internal reason; Go's inflater words its own", zlibReason},
	"bog_zip_truncated_deflate_forged_csize":   {"CPython >= 3.13.x refuses a member whose compressed size overlaps the next header (\"Overlapped entries\") before reading; older ones, and Go, reach the bare EOF the read would hit", entryErrorText},
	"bog_zip_stored_claims_more_than_it_holds": {"CPython >= 3.13.x refuses a member whose compressed size overlaps the next header (\"Overlapped entries\") before reading; older ones, and Go, reach the bare EOF the read would hit", entryErrorText},
	"install_root_name_not_utf8":               {"Python carries the bytes of a non-UTF-8 name as lone surrogates and json.dumps writes \\udcXX; the shared encoder (core/jsonout) refuses invalid UTF-8, so Go writes U+FFFD in install_root", saSurrogates},
}

func runGoSM(t *testing.T, dir string, args []string) outcome {
	t.Helper()
	code, out, errs := runSM(args...)
	return outcome{code, out, errs, snapshot(t, dir)}
}

// smStd is the install the retired suite used.
func smStd() map[string][]byte {
	return map[string][]byte{
		"baja-rt.jar": smJar("baja", "baja-rt", "Station", "ServiceContainer"),
		"nre-rt.jar":  smJar("nre", "nre-rt", "NetworkRuntime"),
	}
}

// smCase audits bog bytes against an install holding the given module JARs.
func smCase(name string, bogData []byte, jars map[string][]byte) saPar {
	return saPar{name, func(t *testing.T, dir string) []string {
		in := filepath.Join(dir, "in.bog")
		smWrite(t, in, bogData)
		inst := filepath.Join(dir, "inst")
		saMkdir(t, filepath.Join(inst, "modules"))
		for n, d := range jars {
			smWrite(t, filepath.Join(inst, "modules", n), d)
		}
		return []string{"--input", in, "--install", inst, "--output", filepath.Join(dir, "out.json")}
	}}
}

// smTree builds a case from a function that lays out the sandbox and returns the three arguments.
func smTree(name string, f func(t *testing.T, dir string) (input, install, output string)) saPar {
	return saPar{name, func(t *testing.T, dir string) []string {
		in, inst, out := f(t, dir)
		return []string{"--input", in, "--install", inst, "--output", out}
	}}
}

// smOK lays out a valid bog and the standard install, for the cases that vary one argument.
func smOK(t *testing.T, dir string) (input, install, output string) {
	t.Helper()
	input = filepath.Join(dir, "in.bog")
	smWrite(t, input, bogtest.Bog(smStationXML))
	install = filepath.Join(dir, "inst")
	for n, d := range smStd() {
		smWrite(t, filepath.Join(install, "modules", n), d)
	}
	return input, install, filepath.Join(dir, "out.json")
}

const smRefBog = `<p m='a=m b=baja' t='a:A' t='b:Station' t='b:Nope'/>`

func smParityCases(t *testing.T) []saPar {
	t.Helper()
	var cases []saPar
	std := smStd()

	// the retired suite's fixtures, against its installs
	fx := smFix(t)
	for name, p := range fx.bog {
		raw, err := os.ReadFile(p)
		if err != nil {
			t.Fatal(err)
		}
		cases = append(cases, smCase("suite_"+name+"_std_install", raw, std), smCase("suite_"+name+"_empty_install", raw, nil))
	}
	suite, err := bogtest.Suite(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	for name, p := range suite {
		raw, err := os.ReadFile(p)
		if err != nil {
			t.Fatal(err)
		}
		cases = append(cases, smCase("bogsuite_"+name, raw, std))
	}

	// the shapes of a bog file
	xml := func(s string) []byte { return []byte(s) }
	bogs := map[string][]byte{
		"empty_file": nil, "one_byte": []byte("P"), "pk_only": []byte("PK"), "pk_and_a_byte": []byte("PKx"), "pk_header_garbage": []byte("PK\x03\x04garbage"),
		"blank": []byte(" \n\t"), "leading_space_xml": xml("  \n<a/>"), "bom_xml": xml("\xef\xbb\xbf<a/>"), "xml_with_invalid_utf8": xml("<p m='a=m\xff' t='a:A'/>"),
		"xml_with_crlf": xml("<p m='a=m'\r\n t='a:A'/>"), "xml_with_other_separators": xml("<p m='a=m b=n\x0bc=o\x1d' t='b:B'/>"),
		"zip_in_a_subdir":        bogtest.Zip(bogtest.Entry{Name: "dir/file.xml", Data: xml(smRefBog)}),
		"zip_without_file_xml":   bogtest.Zip(bogtest.Entry{Name: "other.xml", Data: xml(smRefBog)}),
		"zip_exact_beats_suffix": bogtest.Zip(bogtest.Entry{Name: "a/file.xml", Data: xml(`<p t='z:Z'/>`)}, bogtest.Entry{Name: "file.xml", Data: xml(smRefBog)}),
		"zip_stored":             bogtest.Zip(bogtest.Entry{Name: "file.xml", Data: xml(smRefBog), Method: bogtest.Stored}),
		"zip_no_xml_prolog":      bogtest.Bog("not xml at all"),
		"zip_with_invalid_utf8":  bogtest.Bog("<p m='a=m\xfe' t='a:A\xff'/>"),
		"zip_empty_file_xml":     bogtest.Bog(""),
		"bomb_at_cap":            bogtest.Bog(smRefBog + strings.Repeat(" ", bog.MaxInflate-len(smRefBog))),
		"bomb_over_cap":          bogtest.Bomb(bog.MaxInflate),
		"plaintext_at_cap":       xml("<p" + strings.Repeat(" ", bog.MaxInflate-2)),
		"plaintext_over_cap":     xml("<p" + strings.Repeat(" ", bog.MaxInflate-1)),
		"truncated_zip":          bogtest.Bog(smRefBog)[:30],
		"zip_flipped_deflate":    bogtest.FlippedDeflate(), "zip_truncated_deflate": bogtest.TruncatedDeflate(),
		"zip_truncated_deflate_forged_csize":   bogtest.TruncatedDeflateForgedCSize(),
		"zip_stored_claims_more_than_it_holds": bogtest.Zip(bogtest.Entry{Name: "file.xml", Data: []byte("<a/>"), Method: bogtest.Stored, Size: u(1 << 20), CSize: u(1 << 20)}),
	}
	for name, data := range bogs {
		cases = append(cases, smCase("bog_"+name, data, std))
	}

	// every table input of the scanner tests, as a station
	for _, c := range stationRefsCases {
		cases = append(cases, smCase("refs: "+c.name, bogtest.Bog("<x>"+c.text), std), smCase("refs_plain: "+c.name, []byte("<x>"+c.text), nil))
	}
	cases = append(cases, smCase("refs_lines", []byte("<p m='a=x\nb=y'\nt='b:T'/>"), std))

	// every module.xml of the scanner tests, as a JAR the station refers to
	refs := []byte(`<p m='a=m b=baja c=nre' t='a:A' t='a:B' t='b:Station' t='b:Missing' t='c:NetworkRuntime'/>`)
	for i, c := range moduleXMLCases {
		cases = append(cases, smCase(fmt.Sprintf("module_xml_%02d: %s", i, c.name), refs, map[string][]byte{
			"m.jar": moduleXMLJar(c.xml), "baja-rt.jar": std["baja-rt.jar"],
		}))
	}

	// generated texts: seeded random concatenations of the tokens the scanners react to, so the quote, boundary
	// and backtracking corners a table does not name are exercised too
	rng := rand.New(rand.NewSource(2431))
	pick := func(tokens []string, n int) string {
		var sb strings.Builder
		for i := 0; i < n; i++ {
			sb.WriteString(tokens[rng.Intn(len(tokens))])
		}
		return sb.String()
	}
	stationTokens := []string{"m='", "m=\"", "t='", "t=\"", " m='", " t='", "a=", "b=baja ", "c=nre ", "a:", "b:", "c:", ":", "=", "X", "Station", "NetworkRuntime", "Y_1",
		" ", "\n", "'", "\"", "-", "é", "_", "<p ", "/>", ">", "\t", "\u00a0", "\x1c"}
	moduleTokens := []string{"<module", "<modules", "<module ", "<type", "<types", "<type ", " name=", "name=", " moduleName=", "xname=", "éname=", "\"A\"", "'B'", "\"baja\"", "'baja-rt'",
		"\"Station\"", "\"", "'", ">", "/>", " ", "\n", "é", "x", "-", "=", "<dependency name=\"d\"/>", "</module>"}
	genRefs := []byte(`<p m='a=m b=baja c=nre' t='a:A' t='b:Station' t='c:NetworkRuntime' t='b:Nope'/>`)
	for i := 0; i < 130; i++ {
		text := "<" + pick(stationTokens, 4+rng.Intn(16))
		cases = append(cases, smCase(fmt.Sprintf("generated_station_%03d", i), []byte(text), std))
	}
	for i := 0; i < 130; i++ {
		xml := pick(moduleTokens, 4+rng.Intn(18))
		cases = append(cases, smCase(fmt.Sprintf("generated_module_xml_%03d", i), genRefs, map[string][]byte{"g.jar": moduleXMLJar(xml), "nre-rt.jar": std["nre-rt.jar"]}))
	}

	// shapes of an install
	jarFile := func(name string, data []byte) map[string][]byte { return map[string][]byte{name: data} }
	merge := func(ms ...map[string][]byte) map[string][]byte {
		out := map[string][]byte{}
		for _, m := range ms {
			for k, v := range m {
				out[k] = v
			}
		}
		return out
	}
	badModule := func(raw []byte) []byte {
		return bogtest.Zip(bogtest.Entry{Name: "META-INF/module.xml", Data: []byte(`<module name="p" moduleName="m"/>`), Raw: raw})
	}
	big := func(n int) string {
		head := `<module name="big-rt" moduleName="m"><type name="A"/>`
		return head + strings.Repeat(" ", n-len(head))
	}
	cases = append(cases,
		smCase("install_standard", []byte(smStationXML), std),
		smCase("install_non_jar_entries", []byte(smRefBog), merge(std, jarFile("notes.txt", []byte("x")), jarFile("UPPER.JAR", smJar("u", "u-rt")), jarFile("jar", smJar("j", "j-rt")))),
		smCase("install_broken_jar", []byte(smRefBog), merge(std, jarFile("broken.jar", []byte("not a zip")), jarFile("empty.jar", nil))),
		smCase("install_jar_without_module_xml", []byte(smRefBog), merge(std, jarFile("x.jar", bogtest.Zip(bogtest.Entry{Name: "readme", Data: []byte("x")})))),
		smCase("install_jar_with_corrupt_module_xml", []byte(smRefBog), merge(std, jarFile("c.jar", bogtest.Zip(bogtest.Entry{Name: "META-INF/module.xml", Data: []byte(`<module name="p" moduleName="m"/>`), Method: 99})))),
		smCase("install_jar_with_corrupt_deflate_module_xml", []byte(smRefBog), merge(std,
			jarFile("c.jar", badModule([]byte{0x07, 0, 0, 0})), jarFile("t.jar", badModule([]byte{0x4b, 0x4c})), jarFile("e.jar", badModule(nil)))),
		smCase("install_jar_with_bad_crc_module_xml", []byte(smRefBog), merge(std, jarFile("c.jar", bogtest.CRCMismatch()))),
		smCase("install_jar_with_encrypted_module_xml", []byte(smRefBog), merge(std, jarFile("c.jar", bogtest.Encrypted()))),
		smCase("install_jar_module_xml_in_a_subdir_only", []byte(smRefBog), merge(std, jarFile("c.jar", bogtest.Zip(bogtest.Entry{Name: "x/META-INF/module.xml", Data: []byte(`<module name="p" moduleName="m"/>`)})))),
		smCase("install_jar_module_xml_stored", []byte(smRefBog), merge(std, jarFile("c.jar", bogtest.Zip(bogtest.Entry{Name: "META-INF/module.xml", Data: []byte(`<module name="p" moduleName="m"><type name="A"/></module>`), Method: bogtest.Stored})))),
		smCase("install_module_xml_at_cap", []byte(smRefBog), merge(std, jarFile("big.jar", moduleXMLJar(big(64*1024))))),
		smCase("install_module_xml_over_cap", []byte(smRefBog), merge(std, jarFile("big.jar", moduleXMLJar(big(64*1024+1))))),
		smCase("install_duplicate_parts_later_wins", []byte(smRefBog), map[string][]byte{"1.jar": smJar("m", "dup-rt", "A"), "2.jar": smJar("baja", "dup-rt", "Station")}),
		smCase("install_duplicate_parts_earlier_loses", []byte(smRefBog), map[string][]byte{"1.jar": smJar("baja", "dup-rt", "Station"), "2.jar": smJar("m", "dup-rt", "A")}),
		smCase("install_two_parts_one_module", []byte(smRefBog), map[string][]byte{"ui.jar": smJar("baja", "baja-ux", "Station"), "rt.jar": smJar("baja", "baja-rt", "Nope")}),
		smCase("install_part_without_module_name", []byte(smRefBog), merge(std, jarFile("p.jar", moduleXMLJar(`<module name="orphan-rt"/>`)))),
		smCase("install_empty_module_name_matches_empty_alias", []byte(`<p m='a=' t='a:A'/><p m='b=baja'/>`), merge(std, jarFile("p.jar", moduleXMLJar(`<module name="orphan-rt"><type name="A"/></module>`)))),
		smCase("install_part_without_name", []byte(smRefBog), merge(std, jarFile("p.jar", moduleXMLJar(`<module moduleName="m"/>`)))),
		smCase("install_non_ascii_jar_names", []byte(smRefBog), merge(std, jarFile("é.jar", smJar("m", "é-rt", "A")), jarFile("日本.jar", smJar("m", "日本-rt", "B")))),
		smCase("install_jar_order_surrogates_after_bmp", []byte(smRefBog), map[string][]byte{"\xff.jar": smJar("baja", "dup-rt", "Station"), ".jar": smJar("m", "dup-rt", "A")}),
		smCase("install_jar_order_surrogates_before_astral", []byte(smRefBog), map[string][]byte{"\xff.jar": smJar("baja", "dup-rt", "Station"), "\U0001f600.jar": smJar("m", "dup-rt", "A")}),
		smCase("install_jar_name_not_utf8", []byte(smRefBog), merge(std, jarFile("bad\xffname.jar", smJar("m", "bad-rt", "A")))),
		smCase("module_names_with_json_specials", []byte(`<p m='a=q"uote b=back\slash c=é d=é e=😀' t='a:A' t='b:B' t='c:C' t='d:D' t='e:E'/>`), std),
		smCase("module_name_with_equals_and_slashes", []byte(`<p m="a=x/y=z" t='a:A'/>`), std),
	)
	manyJars := func(n int) map[string][]byte {
		jars := map[string][]byte{}
		tiny := smJar("m", "m-rt")
		for i := 0; i < n; i++ {
			jars[fmt.Sprintf("j%04d.jar", i)] = tiny
		}
		return jars
	}
	cases = append(cases,
		smCase("install_2000_jars", []byte(smRefBog), manyJars(2000)),
		smCase("install_2001_jars", []byte(smRefBog), manyJars(2001)),
		smCase("install_2001_jars_empty_station", bogtest.Bog(smEmptyXML), manyJars(2001)),
	)

	// the filesystem around the install
	cases = append(cases,
		smTree("jar_is_a_symlink", func(t *testing.T, dir string) (string, string, string) {
			in, inst, out := smOK(t, dir)
			symlink(t, filepath.Join(inst, "modules", "baja-rt.jar"), filepath.Join(inst, "modules", "link.jar"))
			return in, inst, out
		}),
		smTree("jar_symlink_outside_the_root", func(t *testing.T, dir string) (string, string, string) {
			in, inst, out := smOK(t, dir)
			smWrite(t, filepath.Join(dir, "outside", "o.jar"), smJar("m", "out-rt", "A"))
			symlink(t, filepath.Join(dir, "outside", "o.jar"), filepath.Join(inst, "modules", "o.jar"))
			return in, inst, out
		}),
		smTree("jar_is_a_directory", func(t *testing.T, dir string) (string, string, string) {
			in, inst, out := smOK(t, dir)
			saMkdir(t, filepath.Join(inst, "modules", "d.jar"))
			return in, inst, out
		}),
		smTree("jar_is_a_fifo", func(t *testing.T, dir string) (string, string, string) {
			in, inst, out := smOK(t, dir)
			fifo(t, filepath.Join(inst, "modules", "pipe.jar"))
			return in, inst, out
		}),
		smTree("jar_is_unreadable", func(t *testing.T, dir string) (string, string, string) {
			in, inst, out := smOK(t, dir)
			if err := os.Chmod(filepath.Join(inst, "modules", "nre-rt.jar"), 0); err != nil {
				t.Fatal(err)
			}
			return in, inst, out
		}),
		smTree("modules_is_missing", func(t *testing.T, dir string) (string, string, string) {
			in, inst, out := smOK(t, dir)
			if err := os.RemoveAll(filepath.Join(inst, "modules")); err != nil {
				t.Fatal(err)
			}
			return in, inst, out
		}),
		smTree("modules_is_a_file", func(t *testing.T, dir string) (string, string, string) {
			in, inst, out := smOK(t, dir)
			_ = os.RemoveAll(filepath.Join(inst, "modules"))
			smWrite(t, filepath.Join(inst, "modules"), []byte("x"))
			return in, inst, out
		}),
		smTree("modules_is_a_symlink_inside", func(t *testing.T, dir string) (string, string, string) {
			in, inst, out := smOK(t, dir)
			if err := os.Rename(filepath.Join(inst, "modules"), filepath.Join(inst, "real")); err != nil {
				t.Fatal(err)
			}
			symlink(t, filepath.Join(inst, "real"), filepath.Join(inst, "modules"))
			return in, inst, out
		}),
		smTree("modules_is_a_symlink_outside", func(t *testing.T, dir string) (string, string, string) {
			in, inst, out := smOK(t, dir)
			if err := os.Rename(filepath.Join(inst, "modules"), filepath.Join(dir, "elsewhere")); err != nil {
				t.Fatal(err)
			}
			symlink(t, filepath.Join(dir, "elsewhere"), filepath.Join(inst, "modules"))
			return in, inst, out
		}),
		smTree("modules_is_a_dangling_symlink", func(t *testing.T, dir string) (string, string, string) {
			in, inst, out := smOK(t, dir)
			_ = os.RemoveAll(filepath.Join(inst, "modules"))
			symlink(t, filepath.Join(dir, "gone"), filepath.Join(inst, "modules"))
			return in, inst, out
		}),
		smTree("modules_is_a_symlink_loop", func(t *testing.T, dir string) (string, string, string) {
			in, inst, out := smOK(t, dir)
			_ = os.RemoveAll(filepath.Join(inst, "modules"))
			symlink(t, "modules", filepath.Join(inst, "modules"))
			return in, inst, out
		}),
		smTree("modules_is_unreadable", func(t *testing.T, dir string) (string, string, string) {
			in, inst, out := smOK(t, dir)
			if err := os.Chmod(filepath.Join(inst, "modules"), 0); err != nil {
				t.Fatal(err)
			}
			return in, inst, out
		}),
		smTree("modules_is_not_searchable", func(t *testing.T, dir string) (string, string, string) {
			in, inst, out := smOK(t, dir)
			if err := os.Chmod(filepath.Join(inst, "modules"), 0o400); err != nil {
				t.Fatal(err)
			}
			return in, inst, out
		}),
		smTree("root_unsearchable", func(t *testing.T, dir string) (string, string, string) {
			in, inst, out := smOK(t, dir)
			if err := os.Chmod(inst, 0); err != nil {
				t.Fatal(err)
			}
			return in, inst, out
		}),
		smTree("root_absent", func(t *testing.T, dir string) (string, string, string) {
			in, _, out := smOK(t, dir)
			return in, filepath.Join(dir, "nope"), out
		}),
		smTree("root_is_a_symlink", func(t *testing.T, dir string) (string, string, string) {
			in, inst, out := smOK(t, dir)
			symlink(t, inst, filepath.Join(dir, "sym"))
			return in, filepath.Join(dir, "sym"), out
		}),
		smTree("root_is_a_symlink_trailing_slashes", func(t *testing.T, dir string) (string, string, string) {
			in, inst, out := smOK(t, dir)
			symlink(t, inst, filepath.Join(dir, "sym"))
			return in, filepath.Join(dir, "sym") + "///", out
		}),
		smTree("root_is_a_dangling_symlink", func(t *testing.T, dir string) (string, string, string) {
			in, _, out := smOK(t, dir)
			symlink(t, filepath.Join(dir, "gone"), filepath.Join(dir, "sym"))
			return in, filepath.Join(dir, "sym"), out
		}),
		smTree("root_is_a_file", func(t *testing.T, dir string) (string, string, string) {
			in, _, out := smOK(t, dir)
			smWrite(t, filepath.Join(dir, "afile"), []byte("x"))
			return in, filepath.Join(dir, "afile"), out
		}),
		smTree("root_is_a_file_trailing_slash", func(t *testing.T, dir string) (string, string, string) {
			in, _, out := smOK(t, dir)
			smWrite(t, filepath.Join(dir, "afile"), []byte("x"))
			return in, filepath.Join(dir, "afile") + "/", out
		}),
		smTree("root_trailing_slashes", func(t *testing.T, dir string) (string, string, string) {
			in, inst, out := smOK(t, dir)
			return in, inst + "//", out
		}),
		smTree("root_through_a_symlinked_parent", func(t *testing.T, dir string) (string, string, string) {
			in, _, out := smOK(t, dir)
			saMkdir(t, filepath.Join(dir, "p"))
			symlink(t, dir, filepath.Join(dir, "p", "up"))
			return in, filepath.Join(dir, "p", "up", "inst"), out
		}),
		smTree("root_with_dot_dot", func(t *testing.T, dir string) (string, string, string) {
			in, _, out := smOK(t, dir)
			saMkdir(t, filepath.Join(dir, "x"))
			return in, filepath.Join(dir, "x", "..", "inst"), out
		}),
		smTree("root_with_dot_dot_through_a_symlink", func(t *testing.T, dir string) (string, string, string) {
			in, _, out := smOK(t, dir)
			saMkdir(t, filepath.Join(dir, "real", "deep"))
			symlink(t, filepath.Join(dir, "real", "deep"), filepath.Join(dir, "lnk"))
			return in, filepath.Join(dir, "lnk", "..", "..", "inst"), out
		}),
		smTree("root_name_with_quotes", func(t *testing.T, dir string) (string, string, string) {
			in, _, out := smOK(t, dir)
			return in, filepath.Join(dir, "no'such\"dir\\x"), out
		}),
		smTree("root_name_with_single_quote_only", func(t *testing.T, dir string) (string, string, string) {
			in, _, out := smOK(t, dir)
			return in, filepath.Join(dir, "it's"), out
		}),
		smTree("root_name_with_control_and_unicode", func(t *testing.T, dir string) (string, string, string) {
			in, _, out := smOK(t, dir)
			return in, filepath.Join(dir, "no\tsuché dir\x7f \U0001f600"), out
		}),
		smTree("root_absent_name_not_utf8", func(t *testing.T, dir string) (string, string, string) {
			in, _, out := smOK(t, dir)
			return in, filepath.Join(dir, "no\xffsuch"), out
		}),
		smTree("install_root_name_not_utf8", func(t *testing.T, dir string) (string, string, string) {
			in, _, out := smOK(t, dir)
			bad := filepath.Join(dir, "bad\xffhome")
			if err := os.Rename(filepath.Join(dir, "inst"), bad); err != nil {
				t.Fatal(err)
			}
			return in, bad, out
		}),
		smTree("root_empty_string", func(t *testing.T, dir string) (string, string, string) {
			in, _, out := smOK(t, dir)
			return in, "", out
		}),
		smTree("root_slashes", func(t *testing.T, dir string) (string, string, string) {
			in, _, out := smOK(t, dir)
			return in, "///", out
		}),
		smTree("root_is_the_sandbox_itself", func(t *testing.T, dir string) (string, string, string) {
			in, _, out := smOK(t, dir)
			return in, dir, out
		}),
		smTree("root_is_dot_dot_of_modules", func(t *testing.T, dir string) (string, string, string) {
			in, inst, out := smOK(t, dir)
			return in, filepath.Join(inst, "modules", ".."), out
		}),
		smTree("root_is_the_modules_dir", func(t *testing.T, dir string) (string, string, string) {
			in, inst, out := smOK(t, dir)
			saMkdir(t, filepath.Join(inst, "modules", "modules"))
			return in, filepath.Join(inst, "modules"), out
		}),
	)

	// the input argument
	cases = append(cases,
		smTree("input_absent", func(t *testing.T, dir string) (string, string, string) {
			_, inst, out := smOK(t, dir)
			return filepath.Join(dir, "nope.bog"), inst, out
		}),
		smTree("input_absent_and_root_absent", func(t *testing.T, dir string) (string, string, string) {
			return filepath.Join(dir, "nope.bog"), filepath.Join(dir, "nope"), filepath.Join(dir, "out.json")
		}),
		smTree("input_is_a_symlink", func(t *testing.T, dir string) (string, string, string) {
			in, inst, out := smOK(t, dir)
			symlink(t, in, filepath.Join(dir, "sym.bog"))
			return filepath.Join(dir, "sym.bog"), inst, out
		}),
		smTree("input_is_a_dangling_symlink", func(t *testing.T, dir string) (string, string, string) {
			_, inst, out := smOK(t, dir)
			symlink(t, filepath.Join(dir, "gone"), filepath.Join(dir, "sym.bog"))
			return filepath.Join(dir, "sym.bog"), inst, out
		}),
		smTree("input_through_a_symlinked_parent", func(t *testing.T, dir string) (string, string, string) {
			_, inst, out := smOK(t, dir)
			symlink(t, dir, filepath.Join(dir, "up"))
			return filepath.Join(dir, "up", "in.bog"), inst, out
		}),
		smTree("input_is_a_directory", func(t *testing.T, dir string) (string, string, string) {
			_, inst, out := smOK(t, dir)
			saMkdir(t, filepath.Join(dir, "d.bog"))
			return filepath.Join(dir, "d.bog"), inst, out
		}),
		smTree("input_is_a_fifo", func(t *testing.T, dir string) (string, string, string) {
			_, inst, out := smOK(t, dir)
			fifo(t, filepath.Join(dir, "pipe.bog"))
			return filepath.Join(dir, "pipe.bog"), inst, out
		}),
		smTree("input_is_unreadable", func(t *testing.T, dir string) (string, string, string) {
			in, inst, out := smOK(t, dir)
			if err := os.Chmod(in, 0); err != nil {
				t.Fatal(err)
			}
			return in, inst, out
		}),
		smTree("input_is_dev_null", func(t *testing.T, dir string) (string, string, string) {
			_, inst, out := smOK(t, dir)
			return "/dev/null", inst, out
		}),
		smTree("input_empty_string", func(t *testing.T, dir string) (string, string, string) {
			_, inst, out := smOK(t, dir)
			return "", inst, out
		}),
		smTree("input_name_with_quotes", func(t *testing.T, dir string) (string, string, string) {
			_, inst, out := smOK(t, dir)
			return filepath.Join(dir, "it's\"x.bog"), inst, out
		}),
		smTree("input_name_not_utf8", func(t *testing.T, dir string) (string, string, string) {
			_, inst, out := smOK(t, dir)
			return filepath.Join(dir, "bad\xff.bog"), inst, out
		}),
		smTree("input_name_not_utf8_exists", func(t *testing.T, dir string) (string, string, string) {
			in, inst, out := smOK(t, dir)
			bad := filepath.Join(dir, "bad\xff.bog")
			if err := os.Rename(in, bad); err != nil {
				t.Fatal(err)
			}
			return bad, inst, out
		}),
		smTree("input_is_the_output", func(t *testing.T, dir string) (string, string, string) {
			in, inst, _ := smOK(t, dir)
			return in, inst, in
		}),
	)

	// the output argument
	cases = append(cases,
		smTree("output_exists", func(t *testing.T, dir string) (string, string, string) {
			in, inst, out := smOK(t, dir)
			smWrite(t, out, []byte("existing\n"))
			return in, inst, out
		}),
		smTree("output_is_a_symlink", func(t *testing.T, dir string) (string, string, string) {
			in, inst, out := smOK(t, dir)
			smWrite(t, filepath.Join(dir, "victim.txt"), []byte("victim\n"))
			symlink(t, filepath.Join(dir, "victim.txt"), out)
			return in, inst, out
		}),
		smTree("output_is_a_dangling_symlink", func(t *testing.T, dir string) (string, string, string) {
			in, inst, out := smOK(t, dir)
			symlink(t, filepath.Join(dir, "gone"), out)
			return in, inst, out
		}),
		smTree("output_is_a_directory", func(t *testing.T, dir string) (string, string, string) {
			in, inst, out := smOK(t, dir)
			saMkdir(t, out)
			return in, inst, out
		}),
		smTree("output_directory_missing", func(t *testing.T, dir string) (string, string, string) {
			in, inst, _ := smOK(t, dir)
			return in, inst, filepath.Join(dir, "no", "such", "o.json")
		}),
		smTree("output_empty_path", func(t *testing.T, dir string) (string, string, string) {
			in, inst, _ := smOK(t, dir)
			return in, inst, ""
		}),
		smTree("output_path_through_a_file", func(t *testing.T, dir string) (string, string, string) {
			in, inst, _ := smOK(t, dir)
			smWrite(t, filepath.Join(dir, "f"), []byte("x"))
			return in, inst, filepath.Join(dir, "f", "o.json")
		}),
		smTree("output_name_with_quotes", func(t *testing.T, dir string) (string, string, string) {
			in, inst, _ := smOK(t, dir)
			return in, inst, filepath.Join(dir, "no'such\"dir\\x", "o.json")
		}),
		smTree("output_name_with_control_and_unicode", func(t *testing.T, dir string) (string, string, string) {
			in, inst, _ := smOK(t, dir)
			return in, inst, filepath.Join(dir, "no\tsuché dir\x7f", "o.json")
		}),
		smTree("output_name_not_utf8", func(t *testing.T, dir string) (string, string, string) {
			in, inst, _ := smOK(t, dir)
			return in, inst, filepath.Join(dir, "no\xffsuch", "o.json")
		}),
		smTree("output_name_not_utf8_written", func(t *testing.T, dir string) (string, string, string) {
			in, inst, _ := smOK(t, dir)
			return in, inst, filepath.Join(dir, "out\xff.json")
		}),
		smTree("output_directory_not_writable", func(t *testing.T, dir string) (string, string, string) {
			in, inst, _ := smOK(t, dir)
			saMkdir(t, filepath.Join(dir, "ro"))
			if err := os.Chmod(filepath.Join(dir, "ro"), 0o500); err != nil {
				t.Fatal(err)
			}
			return in, inst, filepath.Join(dir, "ro", "o.json")
		}),
		smTree("output_inside_the_modules_dir", func(t *testing.T, dir string) (string, string, string) {
			in, inst, _ := smOK(t, dir)
			return in, inst, filepath.Join(inst, "modules", "out.json")
		}),
		smTree("output_is_the_input", func(t *testing.T, dir string) (string, string, string) {
			in, inst, _ := smOK(t, dir)
			return in, inst, in
		}),
		smTree("output_after_a_failed_bog", func(t *testing.T, dir string) (string, string, string) {
			_, inst, out := smOK(t, dir)
			smWrite(t, filepath.Join(dir, "bad.bog"), []byte("binary \x00 data"))
			return filepath.Join(dir, "bad.bog"), inst, out
		}),
		smTree("output_exists_and_input_failed", func(t *testing.T, dir string) (string, string, string) {
			_, inst, out := smOK(t, dir)
			smWrite(t, filepath.Join(dir, "bad.bog"), []byte("binary \x00 data"))
			smWrite(t, out, []byte("x"))
			return filepath.Join(dir, "bad.bog"), inst, out
		}),
	)

	// the whole argparse table
	for _, ac := range smArgTable() {
		args := ac.args
		cases = append(cases, saPar{"args: " + ac.name, func(t *testing.T, dir string) []string { return args }})
	}
	return cases
}

func TestParityOfStationModulesWithLegacyScript(t *testing.T) {
	py := python(t)
	script := smLegacyScript(t)
	dir := t.TempDir()
	cases := smParityCases(t)
	used := map[string]bool{}
	diverged := 0
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			defer saRestoreModes(dir)
			fresh(t, dir)
			legacy := runLegacy(t, py, script, dir, c.build(t, dir))
			saRestoreModes(dir)
			fresh(t, dir)
			args := c.build(t, dir)
			got := runGoSM(t, dir, args)
			if d, ok := smDeclared[c.name]; ok {
				used[c.name] = true
				if legacy == got {
					t.Errorf("declared divergence %q is stale: both sides already agree (%s)", c.name, d.reason)
				}
				legacy.stdout, got.stdout = d.normalise(legacy.stdout), d.normalise(got.stdout)
				legacy.stderr, got.stderr = d.normalise(legacy.stderr), d.normalise(got.stderr)
				legacy.effects, got.effects = d.normalise(legacy.effects), d.normalise(got.effects)
			}
			if legacy != got {
				t.Errorf("legacy and Go differ for %q\n legacy: code=%d stdout=%q stderr=%q\n    go:  code=%d stdout=%q stderr=%q\n legacy effects:\n%s\n go effects:\n%s",
					short(strings.Join(args, " ")), legacy.code, legacy.stdout, legacy.stderr, got.code, got.stdout, got.stderr, short(legacy.effects), short(got.effects))
			}
		})
	}
	for name, d := range smDeclared {
		if !used[name] {
			t.Errorf("declared divergence %q (%s) matches no case", name, d.reason)
			continue
		}
		diverged++
	}
	t.Logf("parity: %d cases against the frozen legacy script: %d byte-equal, %d equal after a declared normalisation", len(cases), len(cases)-diverged, diverged)
}

// ---- goldens: the legacy script's own bytes for two full runs ----

func smGoldenFull(t *testing.T, dir string) (home string, args []string) {
	t.Helper()
	home = filepath.Join(dir, "install")
	smWrite(t, filepath.Join(home, "modules", "baja-rt.jar"), smJar("baja", "baja-rt", "Station", "ServiceContainer"))
	smWrite(t, filepath.Join(home, "modules", "baja-ux.jar"), smJar("baja", "baja-ux", "BajaUx"))
	smWrite(t, filepath.Join(home, "modules", "nre-rt.jar"), smJar("nre", "nre-rt", "NetworkRuntime"))
	in := filepath.Join(dir, "config.bog")
	smWrite(t, in, bogtest.Bog(`<?xml version='1.0'?>
<bajaObjectGraph>
 <p n='Station' t='b:Station' m='b=baja n=nre d=testmodule h=honbac-util=hon'>
  <p n='A' t='b:Gone'/><p n='B' t='n:NetworkRuntime'/><p n='C' t='d:TestService'/><p n='D' t='z:Undeclared'/>
 </p>
</bajaObjectGraph>`))
	return home, []string{"--input", in, "--install", home, "--output", filepath.Join(dir, "out.json")}
}

func smGoldenEmpty(t *testing.T, dir string) (home string, args []string) {
	t.Helper()
	home = filepath.Join(dir, "install")
	saMkdir(t, filepath.Join(home, "modules"))
	in := filepath.Join(dir, "config.bog")
	smWrite(t, in, []byte(smEmptyXML))
	return home, []string{"--input", in, "--install", home, "--output", filepath.Join(dir, "out.json")}
}

func TestGoldenStationModulesMatchesLegacyBytes(t *testing.T) {
	for _, g := range []struct {
		name  string
		build func(*testing.T, string) (string, []string)
	}{{"full", smGoldenFull}, {"empty", smGoldenEmpty}} {
		t.Run(g.name, func(t *testing.T) {
			dir := t.TempDir()
			home, args := g.build(t, dir)
			golden := filepath.Join("testdata", "golden", "stationmods_"+g.name+".json")
			if *updateStationGolden {
				py := python(t)
				runLegacy(t, py, smLegacyScript(t), dir, args)
				raw, err := os.ReadFile(filepath.Join(dir, "out.json"))
				if err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(golden, []byte(strings.ReplaceAll(string(raw), home, "<ROOT>")), 0o644); err != nil {
					t.Fatal(err)
				}
				fresh(t, dir)
				g.build(t, dir)
			}
			want, err := os.ReadFile(golden)
			if err != nil {
				t.Fatal(err)
			}
			if code, out, errs := runSM(args...); (code != 0 && code != 1) || out != "" || errs != "" {
				t.Fatalf("code %d stdout %q stderr %q", code, out, errs)
			}
			got, err := os.ReadFile(filepath.Join(dir, "out.json"))
			if err != nil {
				t.Fatal(err)
			}
			if g := strings.ReplaceAll(string(got), home, "<ROOT>"); g != string(want) {
				t.Errorf("output differs from the golden (the legacy script's bytes)\n got:\n%s\nwant:\n%s", g, want)
			}
		})
	}
}
