package niagara

import (
	"crypto/sha256"
	"encoding/hex"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/niagara/bog"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/niagara/bogtest"
)

// Differential parity for security-audit: the frozen legacy script (testdata/legacy/niagara_security_audit.py,
// byte-identical to niagara_security_audit.py at the base commit) and the Go command run on the same install
// tree in the same sandbox path, and stdout, stderr, exit code and everything the run left behind (name, mode,
// JSON content) must be byte-equal. The only differences allowed are the ones declared in saDeclared, each with
// the reason it cannot match; a declaration that no longer diverges fails.

// saLegacySHA256 pins the oracle: it is niagara_security_audit.py at 4c818820 (before the port). The oracle
// moves only with a recorded reason, never silently.
const saLegacySHA256 = "111098a7ddc915cc72cbb420d670525871821e43f09d94a0352c43abef5b1cb8"

var updateAuditGolden = flag.Bool("update-secaudit-golden", false, "rewrite testdata/golden/secaudit_*.json from the legacy script")

func saLegacyScript(t *testing.T) string {
	t.Helper()
	p, err := filepath.Abs(filepath.Join("testdata", "legacy", "niagara_security_audit.py"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(p); err != nil {
		t.Fatalf("parity: frozen legacy script missing at %s (%v): a moved package must update the path, not skip", p, err)
	}
	return p
}

func TestAuditLegacyOracleIsFrozen(t *testing.T) {
	b, err := os.ReadFile(saLegacyScript(t))
	if err != nil {
		t.Fatal(err)
	}
	if sum := sha256.Sum256(b); hex.EncodeToString(sum[:]) != saLegacySHA256 {
		t.Errorf("testdata/legacy/niagara_security_audit.py sha256 = %x, want %s: the parity oracle changed", sum, saLegacySHA256)
	}
}

// saDeclared are the divergences, keyed by case name. normalise is applied to the effects of BOTH sides.
var saDeclared = map[string]struct {
	reason    string
	normalise func(string) string
}{
	"license_name_not_utf8": {"Python carries the bytes of a non-UTF-8 name as lone surrogates and json.dumps writes \\udcXX; the shared encoder (core/jsonout) refuses invalid UTF-8, so Go writes U+FFFD", saSurrogates},
	"root_name_not_utf8":    {"same: install_root holds the non-UTF-8 bytes of the root's name", saSurrogates},
}

var surrogateRE = regexp.MustCompile(`\\udc[89a-f][0-9a-f]|\\ufffd`)

func saSurrogates(s string) string { return surrogateRE.ReplaceAllString(s, "<bad byte>") }

type saPar struct {
	name  string
	build func(t *testing.T, dir string) []string // returns the whole argument vector
}

func runGoSA(t *testing.T, dir string, args []string) outcome {
	t.Helper()
	code, out, errs := runSA(args...)
	return outcome{code, out, errs, snapshot(t, dir)}
}

// copyTree copies a fixture install tree into the sandbox.
func copyTree(t *testing.T, src, dst string) {
	t.Helper()
	err := filepath.Walk(src, func(p string, fi os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(src, p)
		target := filepath.Join(dst, rel)
		if fi.IsDir() {
			return os.MkdirAll(target, 0o700)
		}
		b, err := os.ReadFile(p)
		if err != nil {
			return err
		}
		return os.WriteFile(target, b, 0o600)
	})
	if err != nil {
		t.Fatal(err)
	}
}

func put(t *testing.T, home, rel string, data []byte) {
	t.Helper()
	saWrite(t, filepath.Join(home, rel), data)
}

func symlink(t *testing.T, target, path string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, path); err != nil {
		t.Fatal(err)
	}
}

func fifo(t *testing.T, path string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := syscall.Mkfifo(path, 0o600); err != nil {
		t.Fatal(err)
	}
}

// install builds a case whose install tree is made by f at dir/home and whose audit runs with extra flags.
func install(name string, f func(t *testing.T, dir, home string) []string) saPar {
	return saPar{name, func(t *testing.T, dir string) []string {
		home := filepath.Join(dir, "home")
		if err := os.MkdirAll(home, 0o700); err != nil {
			t.Fatal(err)
		}
		extra := f(t, dir, home)
		return append([]string{home, "--output", filepath.Join(dir, "out.json")}, extra...)
	}}
}

// withFiles is an install holding the given files, audited with no station.
func withFiles(name string, files map[string]string) saPar {
	return install(name, func(t *testing.T, dir, home string) []string {
		for rel, content := range files {
			put(t, home, rel, []byte(content))
		}
		return nil
	})
}

// withStation audits the secure fixture install with the given station bytes.
func withStation(name string, data []byte) saPar {
	return install(name, func(t *testing.T, dir, home string) []string {
		put(t, home, "system.properties", []byte("niagara.moduleVerificationMode=high\n"))
		st := filepath.Join(dir, "station.bog")
		saWrite(t, st, data)
		return []string{"--station", st}
	})
}

var propsTexts = []string{
	"#niagara.moduleVerificationMode=high\n", "  #   niagara.moduleVerificationMode = high\n", "##niagara.moduleVerificationMode=high\n",
	"niagara.moduleVerificationMode   =   high   \n", "\tniagara.moduleVerificationMode\t=\thigh\t\n", "niagara.moduleVerificationMode=high\r\n",
	"x=1\rniagara.moduleVerificationMode=high\r", "niagara.moduleVerificationMode=LOW\n", "niagara.moduleVerificationMode=low\nniagara.moduleVerificationMode=high\n",
	"niagara.moduleVerificationMode=high\n#niagara.moduleVerificationMode=high\n", "niagara.moduleVerificationMode=\n", "niagara.moduleVerificationMode=hi gh=2\n",
	"niagara.moduleVerificationMode high\n", "niagara.moduleVerificationModeX=high\n", "niagara.moduleVerificationMode = high \n",
	"\ufeffniagara.moduleVerificationMode=high\n", "niagara.moduleVerificationMode=hi\xffgh\n", "niagara.moduleVerificationMode=hi\u0085gh\n",
	"niagara.moduleVerificationMode=hi\x0bgh\x0c\n", "niagara.moduleVerificationMode=hi gh\n", "niagara.moduleVerificationMode\x1c=\x1dhigh\x1e\n",
	"niagara.moduleVerificationMode=high", "niagara.\xc3\xa9x=1\nniagara.moduleVerificationMode=high\n", "niagara..=1\nniagara.xé٣=2\nniagara.moduleVerificationMode=high\n",
	"program.requireSigning=true\n", "program.requireSigning=TRUE\n", "program.requireSigning=False\n", "#program.requireSigning=true\n",
	"program.requireSigning=maybe\nniagara.commandLinePropertyBlacklist=skipModuleValidation\n",
	"niagara.commandLinePropertyBlacklist=\n", "niagara.commandLinePropertyBlacklist=ignoreVerificationMode,skipModuleValidation\n",
	"#niagara.commandLinePropertyBlacklist=skipModuleValidation,ignoreVerificationMode\n", "niagara.commandLinePropertyBlacklist = x, skipModuleValidation ;ignoreVerificationMode\n",
	"niagara.moduleVerificationMode=high\nprogram.requireSigning=false\n", "", "\n\n\n", "garbage\x00niagara.moduleVerificationMode=high\n",
	"niagara.moduleVerificationMode=\"low\"\n", "niagara.moduleVerificationMode=lOw\n", "niagara.moduleVerificationMode=low # comment\n",
}

var licenseTexts = []string{
	`<l skipModuleValidation = "true"/>`, `<l unreleasedSoftware=true/>`, `<l skipModuleValidation="false"/>`, `<l skipModuleValidation="True"/>`,
	`<l smDeveloperMode="false" kind="developer"/>`, `<l smDeveloperMode="false"/>`,
	`skipModuleValidation="true" smDeveloperMode="true" unreleasedSoftware="true"`, "skipModuleValidation = \"true\"",
	"<l>\r\nunreleasedSoftware=\"true\"\r\n</l>", `skipModuleValidation=truely`, "skipModuleValidation=\n\"true\"", `skipModuleValidation='true'`,
	"skipModuleValidation = true", "\xff\xfe smDeveloperMode=\"true\"", strings.Repeat("x", 65536) + `smDeveloperMode="true"`,
	strings.Repeat("x", 65520) + `smDeveloperMode="true"`, strings.Repeat("\r\n", 40000) + `smDeveloperMode="true"`,
	strings.Repeat("é", 65530) + `smDeveloperMode="true"`, "unreleasedSoftware", "developer unreleasedSoftware", "", "SKIPMODULEVALIDATION=\"TRUE\"",
}

var stationTexts = []string{
	`<c allowProgramRuntimeExec="true"/>`, `<c allowProgramRuntimeExec='true'/>`, `<c ALLOWPROGRAMRUNTIMEEXEC = 'TRUE'/>`, `<c allowProgramRuntimeExec=true/>`,
	`<c allowProgramRuntimeExec="false"/>`, `<c allowProgramRuntimeExec="trueish"/>`, `<c allowProgramRuntimeExec = "true"/>`,
	"<c allowProgramRuntimeExec = true/>", "<c allowProgramRuntimeExec = \"true\"/>", "<c allowProgramRuntimeExec\x1c=\x1d\"true\"/>",
	"<c allowProgramRuntımeExec=\"true\"/>", "<c allowProgramRuntİmeExec=\"true\"/>", "<c allowProgramRuntimeExec=\"truıe\"/>", "<c allowProgramRuntimeExec=\"TRUK\"/>",
	"<c allowProgramRuntimeExec=\"\"true\"/>", `<c allowProgramRuntimeExec=''true/>`, `<c allowProgramRuntimeExec= \n"true"/>`,
	`<c n="SyslogService" enabled="true"/>`, `<c n="BSyslogSettings" enabled="true"/>`, `<c enabled="true"/>`, `<c n="SyslogService"/>`,
	`<c n="syslogservice" enabled="true"/>`, `<c n="SyslogService" enabled="false"/><d enabled='TRUE'/>`, `<c n="SyslogService" enabled="1"/>`,
	`<c n="SyslogService" ENABLED=true/>`, "<c n=\"SyslogService\" enabled = true/>", "<c n=\"SyslogService\" enablıed=true/>",
	`<c reversibleEncodingKeySource="external"/>`, `<c reversibleEncodingKeySource="none"/>`, `<c reversibleEncodingKeySource='None'/>`,
	`<c reversibleEncodingKeySource="false"/>`, `<c reversibleEncodingKeySource=0/>`, `<c reversibleEncodingKeySource=""/>`,
	`<c reversibleEncodingKeySource=""/><d reversibleEncodingKeySource="hsm"/>`, `<c reversibleEncodingKeySource="none"/><d reversibleEncodingKeySource="hsm"/>`,
	`<c REVERSIBLEENCODINGKEYSOURCE="vault"/>`, "<c reversibleEncodingKeySource=\"vault\"/>", "<c reversibleEncodingKeyſource=\"vault\"/>",
	"<c reversibleEncodingKeySource = \"vaulté\"/>", "<c reversibleEncodingKeySource=\"٠\"/>", "<c reversibleEncodingKeySource=\"_\"/>",
	"<c reversibleEncodingKeySource=\"NÓNE\"/>", "<c reversibleEncodingKeySource=\"none-ish\"/>", "<c reversibleEncodıngKeySource=\"vault\"/>",
	"", "  \n", "plain text\nno attributes", "\xef\xbb\xbf<c allowProgramRuntimeExec=\"true\"/>", "<c allowProgramRuntimeExec=\"true\"/>\xff\xfe",
	strings.Repeat("x", 600) + "\x00 allowProgramRuntimeExec='true'", "<c allowProgramRuntimeExec='true'/>" + strings.Repeat("\x00", 600),
	strings.Repeat("\x00", 512) + "allowProgramRuntimeExec='true'", strings.Repeat(" ", 511) + "\x00allowProgramRuntimeExec='true'",
}

func jar(xml string, extra ...string) string {
	entries := []bogtest.Entry{{Name: "META-INF/module.xml", Data: []byte(xml)}}
	for _, n := range extra {
		entries = append(entries, bogtest.Entry{Name: n, Data: []byte("sig")})
	}
	return string(bogtest.Zip(entries...))
}

func saParityCases(t *testing.T) []saPar {
	t.Helper()
	fx := fixtures(t)
	var cases []saPar

	// every install tree and station file of the retired bash suite
	for name, src := range map[string]string{"secure": fx.secure, "insecure": fx.insecure, "empty": fx.empty, "lic_hit": fx.licHit, "modules_wild": fx.modulesWild, "jar_bomb": fx.jarBomb} {
		cases = append(cases, install("suite_tree_"+name, func(t *testing.T, dir, home string) []string {
			copyTree(t, src, home)
			return nil
		}))
		for bn, bp := range fx.bog {
			cases = append(cases, install("suite_tree_"+name+"_station_"+bn, func(t *testing.T, dir, home string) []string {
				copyTree(t, src, home)
				st := filepath.Join(dir, "station.bog")
				b, _ := os.ReadFile(bp)
				saWrite(t, st, b)
				return []string{"--station", st}
			}))
		}
	}
	cases = append(cases, withStation("station_oversized_32MiB_plus_1", bogtest.Bomb(bog.MaxInflate)))
	cases = append(cases, withStation("station_exactly_32MiB", bogtest.Bog(strings.Repeat("A", bog.MaxInflate))))

	// property files
	for i, text := range propsTexts {
		cases = append(cases, withFiles(fmt.Sprintf("props_%02d", i), map[string]string{"system.properties": text}))
		cases = append(cases, withFiles(fmt.Sprintf("props_defaults_%02d", i), map[string]string{"defaults/system.properties": text, "system.properties": "niagara.moduleVerificationMode=high\nprogram.requireSigning=true\n"}))
	}
	cases = append(cases,
		withFiles("props_oversized", map[string]string{"defaults/system.properties": "niagara.moduleVerificationMode=low\n" + strings.Repeat("#", maxPropsBytes), "system.properties": "niagara.moduleVerificationMode=high\n"}),
		withFiles("props_at_cap", map[string]string{"system.properties": "niagara.moduleVerificationMode=high\n" + strings.Repeat("#", maxPropsBytes-len("niagara.moduleVerificationMode=high\n"))}),
		withFiles("props_one_over_cap", map[string]string{"system.properties": "niagara.moduleVerificationMode=high\n" + strings.Repeat("#", maxPropsBytes-len("niagara.moduleVerificationMode=high\n")+1)}),
		install("props_defaults_is_symlink", func(t *testing.T, dir, home string) []string {
			put(t, home, "real", []byte("niagara.moduleVerificationMode=low\n"))
			symlink(t, filepath.Join(home, "real"), filepath.Join(home, "defaults", "system.properties"))
			put(t, home, "system.properties", []byte("niagara.moduleVerificationMode=high\n"))
			return nil
		}),
		install("props_defaults_dir_escapes", func(t *testing.T, dir, home string) []string {
			put(t, dir, "outside/system.properties", []byte("niagara.moduleVerificationMode=low\n"))
			symlink(t, filepath.Join(dir, "outside"), filepath.Join(home, "defaults"))
			put(t, home, "system.properties", []byte("niagara.moduleVerificationMode=high\n"))
			return nil
		}),
		install("props_defaults_dir_symlink_inside", func(t *testing.T, dir, home string) []string {
			put(t, home, "elsewhere/system.properties", []byte("niagara.moduleVerificationMode=high\n"))
			symlink(t, filepath.Join(home, "elsewhere"), filepath.Join(home, "defaults"))
			return nil
		}),
		install("props_relative_defaults_symlink", func(t *testing.T, dir, home string) []string {
			put(t, home, "elsewhere/system.properties", []byte("niagara.moduleVerificationMode=high\n"))
			symlink(t, "elsewhere", filepath.Join(home, "defaults"))
			return nil
		}),
		install("props_is_fifo", func(t *testing.T, dir, home string) []string {
			fifo(t, filepath.Join(home, "system.properties"))
			return nil
		}),
		install("props_is_directory", func(t *testing.T, dir, home string) []string {
			_ = os.MkdirAll(filepath.Join(home, "system.properties"), 0o700)
			return nil
		}),
		install("props_unreadable", func(t *testing.T, dir, home string) []string {
			put(t, home, "system.properties", []byte("niagara.moduleVerificationMode=high\n"))
			if err := os.Chmod(filepath.Join(home, "system.properties"), 0); err != nil {
				t.Fatal(err)
			}
			return nil
		}),
	)

	// presence checks
	cases = append(cases,
		withFiles("presence_all", map[string]string{"security/truststore.jks": "x", "jre/lib/security/cacerts.bcfks": "x"}),
		install("presence_truststore_symlink", func(t *testing.T, dir, home string) []string {
			put(t, home, "real", []byte("x"))
			symlink(t, filepath.Join(home, "real"), filepath.Join(home, "security", "truststore.jks"))
			symlink(t, filepath.Join(home, "real"), filepath.Join(home, "jre", "lib", "security", "cacerts.bcfks"))
			return nil
		}),
		install("presence_security_is_symlink", func(t *testing.T, dir, home string) []string {
			put(t, dir, "sec/truststore.jks", []byte("x"))
			symlink(t, filepath.Join(dir, "sec"), filepath.Join(home, "security"))
			return nil
		}),
		install("presence_security_is_file", func(t *testing.T, dir, home string) []string {
			put(t, home, "security", []byte("x"))
			return nil
		}),
		install("presence_truststore_is_directory", func(t *testing.T, dir, home string) []string {
			_ = os.MkdirAll(filepath.Join(home, "security", "truststore.jks"), 0o700)
			return nil
		}),
	)

	// licenses
	for i, text := range licenseTexts {
		cases = append(cases, withFiles(fmt.Sprintf("license_text_%02d", i), map[string]string{"security/licenses/a.license": text}))
	}
	cases = append(cases,
		withFiles("license_several_files", map[string]string{
			"security/licenses/b.license": `smDeveloperMode="true"`, "security/licenses/a.license": `unreleasedSoftware="true" smDeveloperMode="true"`,
			"security/licenses/c.txt": `smDeveloperMode="true"`, "security/licenses/B.license": `skipModuleValidation=true`,
		}),
		install("license_name_not_utf8", func(t *testing.T, dir, home string) []string {
			put(t, home, "security/licenses/bad\xffname.license", []byte(`smDeveloperMode="true"`))
			return nil
		}),
		install("license_cap_200_entries", func(t *testing.T, dir, home string) []string {
			for i := 0; i < 200; i++ {
				put(t, home, fmt.Sprintf("security/licenses/a%03d.txt", i), nil)
			}
			put(t, home, "security/licenses/z.license", []byte(`smDeveloperMode="true"`))
			return nil
		}),
		install("license_cap_199_entries", func(t *testing.T, dir, home string) []string {
			for i := 0; i < 199; i++ {
				put(t, home, fmt.Sprintf("security/licenses/a%03d.txt", i), nil)
			}
			put(t, home, "security/licenses/z.license", []byte(`smDeveloperMode="true"`))
			return nil
		}),
		install("license_symlink_file_and_dir_and_fifo", func(t *testing.T, dir, home string) []string {
			put(t, home, "target", []byte(`smDeveloperMode="true"`))
			symlink(t, filepath.Join(home, "target"), filepath.Join(home, "security", "licenses", "link.license"))
			_ = os.MkdirAll(filepath.Join(home, "security", "licenses", "dir.license"), 0o700)
			fifo(t, filepath.Join(home, "security", "licenses", "pipe.license"))
			return nil
		}),
		install("licenses_dir_symlink_outside", func(t *testing.T, dir, home string) []string {
			put(t, dir, "outside/dev.license", []byte(`smDeveloperMode="true"`))
			symlink(t, filepath.Join(dir, "outside"), filepath.Join(home, "security", "licenses"))
			return nil
		}),
		install("licenses_dir_symlink_inside", func(t *testing.T, dir, home string) []string {
			put(t, home, "elsewhere/dev.license", []byte(`smDeveloperMode="true"`))
			symlink(t, filepath.Join(home, "elsewhere"), filepath.Join(home, "security", "licenses"))
			return nil
		}),
		install("licenses_dir_dangling_symlink", func(t *testing.T, dir, home string) []string {
			symlink(t, filepath.Join(dir, "gone"), filepath.Join(home, "security", "licenses"))
			return nil
		}),
		install("licenses_is_a_file", func(t *testing.T, dir, home string) []string {
			put(t, home, "security/licenses", []byte("x"))
			return nil
		}),
		install("licenses_unreadable_dir", func(t *testing.T, dir, home string) []string {
			put(t, home, "security/licenses/a.license", []byte(`smDeveloperMode="true"`))
			if err := os.Chmod(filepath.Join(home, "security", "licenses"), 0); err != nil {
				t.Fatal(err)
			}
			return nil
		}),
		install("licenses_security_symlink_outside", func(t *testing.T, dir, home string) []string {
			put(t, dir, "sec/licenses/dev.license", []byte(`smDeveloperMode="true"`))
			symlink(t, filepath.Join(dir, "sec"), filepath.Join(home, "security"))
			return nil
		}),
		install("licenses_relative_symlink_out", func(t *testing.T, dir, home string) []string {
			put(t, dir, "outside/dev.license", []byte(`smDeveloperMode="true"`))
			symlink(t, "../../outside", filepath.Join(home, "security", "licenses"))
			return nil
		}),
		install("licenses_loop", func(t *testing.T, dir, home string) []string {
			symlink(t, "loop", filepath.Join(home, "security", "licenses"))
			return nil
		}),
	)

	// modules
	wild := saWildcardXML
	cases = append(cases,
		withFiles("modules_signed_rsa", map[string]string{"modules/m.jar": jar(wild, "META-INF/X.RSA")}),
		withFiles("modules_signed_dsa_lower", map[string]string{"modules/m.jar": jar(wild, "META-INF/x.dsa")}),
		withFiles("modules_signed_ec_lower", map[string]string{"modules/m.jar": jar(wild, "META-INF/Y.ec")}),
		withFiles("modules_signed_nested_name", map[string]string{"modules/m.jar": jar(wild, "META-INF/sub/Z.Rsa")}),
		withFiles("modules_signed_long_s", map[string]string{"modules/m.jar": jar(wild, "META-INF/X.RſA")}),
		withFiles("modules_not_signatures", map[string]string{"modules/a.jar": jar(wild, "X.RSA"), "modules/b.jar": jar(wild, "META-INF/X.SF"), "modules/c.jar": jar(wild, "other/META-INF/X.RSA"), "modules/d.jar": jar(wild, "META-INF/RSA")}),
		withFiles("modules_target_form", map[string]string{"modules/b.jar": jar(`<m><p class="x.KeyRingPermission" target="*"/></m>`)}),
		withFiles("modules_named_form", map[string]string{"modules/c.jar": jar(`<m><p class="x.KeyRingPermission" name="vault"/></m>`)}),
		withFiles("modules_lazy_attribute_search", map[string]string{"modules/c.jar": jar(`<m><p class="x.KeyRingPermission" other="1" name="a" x="*"/><q class="x.KeyRingPermission" target="*"/></m>`)}),
		withFiles("modules_attribute_after_close", map[string]string{"modules/c.jar": jar(`<m><p class="x.KeyRingPermission"/><q name="*"/></m>`)}),
		withFiles("modules_multiline", map[string]string{"modules/c.jar": jar("<m><p class=\"x.KeyRingPermission\"\n   name=\"*\"/></m>")}),
		withFiles("modules_other_permission", map[string]string{"modules/d.jar": jar(saOtherXML)}),
		withFiles("modules_mixed", map[string]string{
			"modules/a-signed.jar": jar(wild, "META-INF/CERT.RSA"), "modules/b-target.jar": jar(`<m><p class="x.KeyRingPermission" target="*"/></m>`),
			"modules/c-named.jar": jar(`<m><p class="x.KeyRingPermission" name="vault"/></m>`), "modules/d-other.jar": jar(saOtherXML), "modules/e-readme.txt": "not a jar",
			"modules/F.JAR": jar(wild), "modules/g.jar.bak": jar(wild),
		}),
		withFiles("modules_no_module_xml", map[string]string{"modules/m.jar": string(bogtest.Zip(bogtest.Entry{Name: "other.xml", Data: []byte(wild)}))}),
		withFiles("modules_duplicate_module_xml_last_wins", map[string]string{"modules/m.jar": string(bogtest.Zip(
			bogtest.Entry{Name: "META-INF/module.xml", Data: []byte(wild)}, bogtest.Entry{Name: "META-INF/module.xml", Data: []byte(saOtherXML)}))}),
		withFiles("modules_module_xml_stored", map[string]string{"modules/m.jar": string(bogtest.Zip(bogtest.Entry{Name: "META-INF/module.xml", Data: []byte(wild), Method: bogtest.Stored}))}),
		withFiles("modules_module_xml_corrupt", map[string]string{"modules/m.jar": string(bogtest.CorruptDeflate())}),
		withFiles("modules_module_xml_bad_crc", map[string]string{"modules/m.jar": string(bogtest.Zip(bogtest.Entry{Name: "META-INF/module.xml", Data: []byte(wild), CRC: u(1)}))}),
		withFiles("modules_module_xml_encrypted", map[string]string{"modules/m.jar": string(bogtest.Zip(bogtest.Entry{Name: "META-INF/module.xml", Data: []byte(wild), Flags: 1}))}),
		withFiles("modules_module_xml_forged_size", map[string]string{"modules/m.jar": string(bogtest.Zip(bogtest.Entry{Name: "META-INF/module.xml", Data: []byte(wild + strings.Repeat("A", 70000)), Size: u(10)}))}),
		withFiles("modules_module_xml_at_cap", map[string]string{"modules/m.jar": jar(wild + strings.Repeat("A", 64*1024-len(wild)))}),
		withFiles("modules_module_xml_over_cap", map[string]string{"modules/m.jar": jar(wild + strings.Repeat("A", 64*1024-len(wild)+1))}),
		withFiles("modules_module_xml_invalid_utf8", map[string]string{"modules/m.jar": jar("\xff" + wild)}),
		withFiles("modules_empty_jar", map[string]string{"modules/m.jar": ""}),
		withFiles("modules_broken_jar", map[string]string{"modules/m.jar": "not a zip", "modules/n.jar": "PK\x03\x04junk"}),
		withFiles("modules_empty_zip", map[string]string{"modules/m.jar": string(bogtest.Zip())}),
		install("modules_dir_named_jar_and_symlink_jar", func(t *testing.T, dir, home string) []string {
			put(t, home, "modules/good.jar", []byte(jar(saOtherXML)))
			_ = os.MkdirAll(filepath.Join(home, "modules", "dir.jar"), 0o700)
			symlink(t, filepath.Join(home, "modules", "good.jar"), filepath.Join(home, "modules", "link.jar"))
			symlink(t, filepath.Join(home, "gone"), filepath.Join(home, "modules", "dangling.jar"))
			return nil
		}),
		install("modules_cap_5001_jars", func(t *testing.T, dir, home string) []string {
			tiny := []byte(jar(saOtherXML))
			for i := 0; i < 5001; i++ {
				put(t, home, fmt.Sprintf("modules/m%05d.jar", i), tiny)
			}
			return nil
		}),
		install("modules_cap_5000_jars", func(t *testing.T, dir, home string) []string {
			tiny := []byte(jar(saOtherXML))
			for i := 0; i < 5000; i++ {
				put(t, home, fmt.Sprintf("modules/m%05d.jar", i), tiny)
			}
			return nil
		}),
		install("modules_dir_symlink_outside", func(t *testing.T, dir, home string) []string {
			put(t, dir, "mods/w.jar", []byte(jar(wild)))
			symlink(t, filepath.Join(dir, "mods"), filepath.Join(home, "modules"))
			return nil
		}),
		install("modules_dir_symlink_inside", func(t *testing.T, dir, home string) []string {
			put(t, home, "mods/w.jar", []byte(jar(wild)))
			symlink(t, filepath.Join(home, "mods"), filepath.Join(home, "modules"))
			return nil
		}),
		install("modules_is_a_file", func(t *testing.T, dir, home string) []string { put(t, home, "modules", []byte("x")); return nil }),
		install("modules_unreadable_dir", func(t *testing.T, dir, home string) []string {
			put(t, home, "modules/w.jar", []byte(jar(wild)))
			if err := os.Chmod(filepath.Join(home, "modules"), 0); err != nil {
				t.Fatal(err)
			}
			return nil
		}),
		install("modules_unreadable_jar", func(t *testing.T, dir, home string) []string {
			put(t, home, "modules/w.jar", []byte(jar(wild)))
			if err := os.Chmod(filepath.Join(home, "modules", "w.jar"), 0); err != nil {
				t.Fatal(err)
			}
			return nil
		}),
		install("modules_jar_with_prefix_garbage", func(t *testing.T, dir, home string) []string {
			put(t, home, "modules/w.jar", []byte("stub-bytes-before-the-archive"+jar(wild)))
			return nil
		}),
	)

	// station files
	for i, text := range stationTexts {
		cases = append(cases, withStation(fmt.Sprintf("station_text_%02d", i), []byte(text)))
		cases = append(cases, withStation(fmt.Sprintf("station_zip_text_%02d", i), bogtest.Bog(text)))
	}
	zipOf := func(e ...bogtest.Entry) []byte { return bogtest.Zip(e...) }
	valid := `<c allowProgramRuntimeExec="true"/>`
	cases = append(cases,
		withStation("station_zip_stored", zipOf(bogtest.Entry{Name: "file.xml", Data: []byte(valid), Method: bogtest.Stored})),
		withStation("station_zip_nested_file_xml_only", zipOf(bogtest.Entry{Name: "dir/file.xml", Data: []byte(valid)})),
		withStation("station_zip_exact_beats_nested", zipOf(bogtest.Entry{Name: "x/file.xml", Data: []byte(`<c allowProgramRuntimeExec="false"/>`)}, bogtest.Entry{Name: "file.xml", Data: []byte(valid)})),
		withStation("station_zip_duplicate_file_xml", zipOf(bogtest.Entry{Name: "file.xml", Data: []byte(`<c allowProgramRuntimeExec="false"/>`)}, bogtest.Entry{Name: "file.xml", Data: []byte(valid)})),
		withStation("station_zip_no_file_xml", zipOf(bogtest.Entry{Name: "other.xml", Data: []byte(valid)})),
		withStation("station_zip_no_entries", zipOf()),
		withStation("station_zip_empty_file_xml", zipOf(bogtest.Entry{Name: "file.xml"})),
		withStation("station_zip_corrupt_deflate", bogtest.CorruptDeflate()),
		withStation("station_zip_bad_crc", bogtest.CRCMismatch()),
		withStation("station_zip_encrypted", bogtest.Encrypted()),
		withStation("station_zip_method99", bogtest.Method99()),
		withStation("station_zip_truncated_deflate", bogtest.TruncatedDeflate()),
		withStation("station_zip_flipped_deflate", bogtest.FlippedDeflate()),
		withStation("station_zip_truncated_deflate_forged_csize", bogtest.TruncatedDeflateForgedCSize()),
		withStation("station_zip_forged_small_size", zipOf(bogtest.Entry{Name: "file.xml", Data: []byte(valid), Size: u(10)})),
		withStation("station_zip_forged_big_size", zipOf(bogtest.Entry{Name: "file.xml", Data: []byte(valid), Size: u(1 << 20)})),
		withStation("station_zip_stored_claims_more", zipOf(bogtest.Entry{Name: "file.xml", Data: []byte("<a/>"), Method: bogtest.Stored, Size: u(1 << 20), CSize: u(1 << 20)})),
		withStation("station_zip_strong_encryption_flag", zipOf(bogtest.Entry{Name: "file.xml", Data: []byte(valid), Flags: 0x40})),
		withStation("station_zip_patched_flag", zipOf(bogtest.Entry{Name: "file.xml", Data: []byte(valid), Flags: 0x20})),
		withStation("station_zip_data_descriptor_flag", zipOf(bogtest.Entry{Name: "file.xml", Data: []byte(valid), Flags: 0x08})),
		withStation("station_zip_name_with_nul", zipOf(bogtest.Entry{Name: "file.xml\x00junk", Data: []byte(valid)})),
		withStation("station_zip_invalid_utf8", bogtest.Bog("\xff"+valid)),
		withStation("station_zip_bom", bogtest.Bog("\ufeff"+valid)),
		withStation("station_zip_prefixed_with_text", append([]byte("<c allowProgramRuntimeExec='true'/>\n"), bogtest.Bog(`<c allowProgramRuntimeExec="false"/>`)...)),
		withStation("station_pk_garbage", []byte("PK\x03\x04 not a real archive at all")),
		withStation("station_pk_three_bytes", []byte("PK<")),
		withStation("station_zero_bytes", nil),
		withStation("station_binary", bogtest.Binary()),
		withStation("station_plaintext_4MiB_cap_inside", []byte(strings.Repeat(" ", 4*1024*1024-40)+`allowProgramRuntimeExec="true"`)),
		withStation("station_plaintext_4MiB_cap_straddles", []byte(strings.Repeat(" ", 4*1024*1024-10)+`allowProgramRuntimeExec="true"`)),
		withStation("station_plaintext_past_4MiB", []byte(strings.Repeat(" ", 4*1024*1024)+`allowProgramRuntimeExec="true"`)),
		withStation("station_plaintext_cut_mid_rune", []byte(strings.Repeat(" ", 4*1024*1024-1)+"éallowProgramRuntimeExec=\"true\"")),
		install("station_is_directory", func(t *testing.T, dir, home string) []string {
			_ = os.MkdirAll(filepath.Join(dir, "station.bog"), 0o700)
			return []string{"--station", filepath.Join(dir, "station.bog")}
		}),
		install("station_is_symlink", func(t *testing.T, dir, home string) []string {
			put(t, dir, "real.bog", []byte(valid))
			symlink(t, filepath.Join(dir, "real.bog"), filepath.Join(dir, "station.bog"))
			return []string{"--station", filepath.Join(dir, "station.bog")}
		}),
		install("station_is_dangling_symlink", func(t *testing.T, dir, home string) []string {
			symlink(t, filepath.Join(dir, "gone"), filepath.Join(dir, "station.bog"))
			return []string{"--station", filepath.Join(dir, "station.bog")}
		}),
		install("station_through_symlinked_dir", func(t *testing.T, dir, home string) []string {
			put(t, dir, "real/station.bog", []byte(valid))
			symlink(t, filepath.Join(dir, "real"), filepath.Join(dir, "linkdir"))
			return []string{"--station", filepath.Join(dir, "linkdir", "station.bog")}
		}),
		install("station_absent", func(t *testing.T, dir, home string) []string {
			return []string{"--station", filepath.Join(dir, "nope.bog")}
		}),
		install("station_empty_path", func(t *testing.T, dir, home string) []string { return []string{"--station", ""} }),
		install("station_unreadable", func(t *testing.T, dir, home string) []string {
			put(t, dir, "station.bog", []byte(valid))
			if err := os.Chmod(filepath.Join(dir, "station.bog"), 0); err != nil {
				t.Fatal(err)
			}
			return []string{"--station", filepath.Join(dir, "station.bog")}
		}),
		install("station_inside_the_install", func(t *testing.T, dir, home string) []string {
			put(t, home, "config.bog", bogtest.Bog(valid))
			return []string{"--station", filepath.Join(home, "config.bog")}
		}),
		install("station_given_twice_last_wins", func(t *testing.T, dir, home string) []string {
			put(t, dir, "a.bog", []byte(valid))
			put(t, dir, "b.bog", []byte(`<c allowProgramRuntimeExec="false"/>`))
			return []string{"--station", filepath.Join(dir, "a.bog"), "--station=" + filepath.Join(dir, "b.bog")}
		}),
	)

	// roots and outputs
	cases = append(cases,
		saPar{"root_absent", func(t *testing.T, dir string) []string {
			return []string{filepath.Join(dir, "nope"), "--output", filepath.Join(dir, "o.json")}
		}},
		saPar{"root_is_file", func(t *testing.T, dir string) []string {
			put(t, dir, "f", []byte("x"))
			return []string{filepath.Join(dir, "f"), "--output", filepath.Join(dir, "o.json")}
		}},
		saPar{"root_through_a_file", func(t *testing.T, dir string) []string {
			put(t, dir, "f", []byte("x"))
			return []string{filepath.Join(dir, "f", "x"), "--output", filepath.Join(dir, "o.json")}
		}},
		saPar{"root_is_symlink", func(t *testing.T, dir string) []string {
			_ = os.MkdirAll(filepath.Join(dir, "real"), 0o700)
			symlink(t, filepath.Join(dir, "real"), filepath.Join(dir, "sym"))
			return []string{filepath.Join(dir, "sym"), "--output", filepath.Join(dir, "o.json")}
		}},
		saPar{"root_is_symlink_trailing_slashes", func(t *testing.T, dir string) []string {
			_ = os.MkdirAll(filepath.Join(dir, "real"), 0o700)
			symlink(t, filepath.Join(dir, "real"), filepath.Join(dir, "sym"))
			return []string{filepath.Join(dir, "sym") + "///", "--output", filepath.Join(dir, "o.json")}
		}},
		saPar{"root_through_a_symlinked_parent", func(t *testing.T, dir string) []string {
			put(t, dir, "real/home/system.properties", []byte("niagara.moduleVerificationMode=high\n"))
			symlink(t, filepath.Join(dir, "real"), filepath.Join(dir, "sym"))
			return []string{filepath.Join(dir, "sym", "home"), "--output", filepath.Join(dir, "o.json")}
		}},
		saPar{"root_trailing_slashes", func(t *testing.T, dir string) []string {
			put(t, dir, "home/system.properties", []byte("niagara.moduleVerificationMode=high\n"))
			return []string{filepath.Join(dir, "home") + "//", "--output", filepath.Join(dir, "o.json")}
		}},
		saPar{"root_with_dot_dot", func(t *testing.T, dir string) []string {
			put(t, dir, "home/system.properties", []byte("niagara.moduleVerificationMode=high\n"))
			_ = os.MkdirAll(filepath.Join(dir, "x"), 0o700)
			return []string{filepath.Join(dir, "x", "..", "home"), "--output", filepath.Join(dir, "o.json")}
		}},
		saPar{"root_with_dot_dot_through_symlink", func(t *testing.T, dir string) []string {
			put(t, dir, "real/deep/x", []byte("x"))
			put(t, dir, "home/system.properties", []byte("niagara.moduleVerificationMode=high\n"))
			symlink(t, filepath.Join(dir, "real", "deep"), filepath.Join(dir, "lnk"))
			return []string{filepath.Join(dir, "lnk", "..", "..", "home"), "--output", filepath.Join(dir, "o.json")}
		}},
		saPar{"root_name_not_utf8", func(t *testing.T, dir string) []string {
			put(t, dir, "bad\xffhome/system.properties", []byte("niagara.moduleVerificationMode=high\n"))
			return []string{filepath.Join(dir, "bad\xffhome"), "--output", filepath.Join(dir, "o.json")}
		}},
		saPar{"root_unreadable_dir", func(t *testing.T, dir string) []string {
			put(t, dir, "home/system.properties", []byte("niagara.moduleVerificationMode=high\n"))
			if err := os.Chmod(filepath.Join(dir, "home"), 0); err != nil {
				t.Fatal(err)
			}
			return []string{filepath.Join(dir, "home"), "--output", filepath.Join(dir, "o.json")}
		}},
		saPar{"root_is_filesystem_root_empty_string", func(t *testing.T, dir string) []string { return []string{"", "--output", filepath.Join(dir, "o.json")} }},
		saPar{"root_is_filesystem_root_slashes", func(t *testing.T, dir string) []string {
			return []string{"///", "--output", filepath.Join(dir, "o.json")}
		}},
		install("output_exists", func(t *testing.T, dir, home string) []string {
			put(t, dir, "out.json", []byte("existing\n"))
			return nil
		}),
		install("output_is_symlink", func(t *testing.T, dir, home string) []string {
			put(t, dir, "victim.txt", []byte("victim\n"))
			symlink(t, filepath.Join(dir, "victim.txt"), filepath.Join(dir, "out.json"))
			return nil
		}),
		install("output_is_dangling_symlink", func(t *testing.T, dir, home string) []string {
			symlink(t, filepath.Join(dir, "gone"), filepath.Join(dir, "out.json"))
			return nil
		}),
		install("output_is_directory", func(t *testing.T, dir, home string) []string {
			_ = os.MkdirAll(filepath.Join(dir, "out.json"), 0o700)
			return nil
		}),
		saPar{"output_directory_missing", func(t *testing.T, dir string) []string {
			_ = os.MkdirAll(filepath.Join(dir, "home"), 0o700)
			return []string{filepath.Join(dir, "home"), "--output", filepath.Join(dir, "no", "such", "o.json")}
		}},
		saPar{"output_empty_path", func(t *testing.T, dir string) []string {
			_ = os.MkdirAll(filepath.Join(dir, "home"), 0o700)
			return []string{filepath.Join(dir, "home"), "--output", ""}
		}},
		saPar{"output_path_through_a_file", func(t *testing.T, dir string) []string {
			_ = os.MkdirAll(filepath.Join(dir, "home"), 0o700)
			put(t, dir, "f", []byte("x"))
			return []string{filepath.Join(dir, "home"), "--output", filepath.Join(dir, "f", "o.json")}
		}},
		saPar{"output_name_with_quotes", func(t *testing.T, dir string) []string {
			_ = os.MkdirAll(filepath.Join(dir, "home"), 0o700)
			return []string{filepath.Join(dir, "home"), "--output", filepath.Join(dir, "no'such\"dir\\x", "o.json")}
		}},
		saPar{"output_name_with_control_and_unicode", func(t *testing.T, dir string) []string {
			_ = os.MkdirAll(filepath.Join(dir, "home"), 0o700)
			return []string{filepath.Join(dir, "home"), "--output", filepath.Join(dir, "no\tsuché dir\x7f", "o.json")}
		}},
		saPar{"output_name_not_utf8", func(t *testing.T, dir string) []string {
			_ = os.MkdirAll(filepath.Join(dir, "home"), 0o700)
			return []string{filepath.Join(dir, "home"), "--output", filepath.Join(dir, "no\xffsuch", "o.json")}
		}},
		saPar{"output_directory_not_writable", func(t *testing.T, dir string) []string {
			_ = os.MkdirAll(filepath.Join(dir, "home"), 0o700)
			_ = os.MkdirAll(filepath.Join(dir, "ro"), 0o500)
			return []string{filepath.Join(dir, "home"), "--output", filepath.Join(dir, "ro", "o.json")}
		}},
		saPar{"output_inside_the_install_tree", func(t *testing.T, dir string) []string {
			put(t, dir, "home/system.properties", []byte("niagara.moduleVerificationMode=high\n"))
			return []string{filepath.Join(dir, "home"), "--output", filepath.Join(dir, "home", "audit.json")}
		}},
		saPar{"output_given_before_root", func(t *testing.T, dir string) []string {
			put(t, dir, "home/system.properties", []byte("niagara.moduleVerificationMode=high\n"))
			return []string{"--output", filepath.Join(dir, "o.json"), filepath.Join(dir, "home")}
		}},
	)

	// the whole argparse table
	for _, ac := range auditArgTable() {
		args := ac.args
		cases = append(cases, saPar{"args: " + ac.name, func(t *testing.T, dir string) []string { return args }})
	}
	return cases
}

func TestParityOfSecurityAuditWithLegacyScript(t *testing.T) {
	py := python(t)
	script := saLegacyScript(t)
	dir := t.TempDir()
	cases := saParityCases(t)
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
			got := runGoSA(t, dir, args)
			if d, ok := saDeclared[c.name]; ok {
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
	for name, d := range saDeclared {
		if !used[name] {
			t.Errorf("declared divergence %q (%s) matches no case", name, d.reason)
			continue
		}
		diverged++
	}
	t.Logf("parity: %d cases against the frozen legacy script: %d byte-equal, %d equal after a declared normalisation", len(cases), len(cases)-diverged, diverged)
}

// saRestoreModes makes every directory in the sandbox accessible again so it can be removed.
func saRestoreModes(dir string) {
	_ = filepath.Walk(dir, func(p string, fi os.FileInfo, err error) error {
		if fi != nil && fi.IsDir() {
			_ = os.Chmod(p, 0o700)
		}
		return nil
	})
}

// ---- goldens: the legacy script's own bytes for two full runs ----

func goldenInstall(t *testing.T, dir string) (home string, args []string) {
	t.Helper()
	home = filepath.Join(dir, "install")
	put(t, home, "defaults/system.properties", []byte(
		"niagara.moduleVerificationMode=low\nprogram.requireSigning=true\n"+
			"niagara.commandLinePropertyBlacklist=skipModuleValidation\n"))
	put(t, home, "security/truststore.jks", []byte("x"))
	put(t, home, "security/licenses/dev.license", []byte("<license smDeveloperMode=\"true\"/>\n"))
	put(t, home, "security/licenses/ok.license", []byte("<license/>\n"))
	put(t, home, "modules/wild.jar", []byte(jar(saWildcardXML)))
	put(t, home, "modules/signed.jar", []byte(jar(saWildcardXML, "META-INF/CERT.RSA")))
	put(t, home, "modules/plain.jar", []byte(jar(saOtherXML)))
	put(t, home, "jre/lib/security/cacerts.bcfks", []byte("x"))
	station := filepath.Join(dir, "config.bog")
	saWrite(t, station, bogtest.Bog(`<config><ProgramService allowProgramRuntimeExec="true"/><SyslogService enabled="true"/><S reversibleEncodingKeySource="none"/></config>`))
	return home, []string{home, "--station", station, "--output", filepath.Join(dir, "out.json")}
}

func emptyInstall(t *testing.T, dir string) (home string, args []string) {
	t.Helper()
	home = filepath.Join(dir, "install")
	saMkdir(t, home)
	return home, []string{home, "--output", filepath.Join(dir, "out.json")}
}

func TestGoldenAuditMatchesLegacyBytes(t *testing.T) {
	for _, g := range []struct {
		name  string
		build func(*testing.T, string) (string, []string)
	}{{"full", goldenInstall}, {"empty", emptyInstall}} {
		t.Run(g.name, func(t *testing.T) {
			dir := t.TempDir()
			home, args := g.build(t, dir)
			golden := filepath.Join("testdata", "golden", "secaudit_"+g.name+".json")
			if *updateAuditGolden {
				py := python(t)
				runLegacy(t, py, saLegacyScript(t), dir, args)
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
			if code, out, errs := runSA(args...); code != 0 || out != "" || errs != "" {
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
