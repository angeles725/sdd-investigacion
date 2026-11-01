package niagara

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/niagara/bogtest"
)

// Edge cases of the audit scanners: license, JAR, station and property forms, caps and special files.

func TestSec06LicenseForms(t *testing.T) {
	tests := []struct {
		name, text string
		note       string // "" means no hit
	}{
		{"quoted true", `<l skipModuleValidation = "true"/>`, "a.license:skipModuleValidation"},
		{"unquoted true", `<l unreleasedSoftware=true/>`, "a.license:unreleasedSoftware"},
		{"false is not a hit", `<l skipModuleValidation="false"/>`, ""},
		{"capitalised True is not a hit", `<l skipModuleValidation="True"/>`, ""},
		{"attribute name plus the word developer", `<l smDeveloperMode="false" kind="developer"/>`, "a.license:smDeveloperMode"},
		{"attribute name alone is not a hit", `<l smDeveloperMode="false"/>`, ""},
		{"three attributes are listed in file/attribute order", `skipModuleValidation="true" smDeveloperMode="true" unreleasedSoftware="true"`,
			"a.license:skipModuleValidation; a.license:smDeveloperMode; a.license:unreleasedSoftware"},
		{"no-break space around the equals sign", "skipModuleValidation = \"true\"", "a.license:skipModuleValidation"},
		{"CRLF line endings", "<l>\r\nunreleasedSoftware=\"true\"\r\n</l>", "a.license:unreleasedSoftware"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			home := t.TempDir()
			saWrite(t, filepath.Join(home, "security", "licenses", "a.license"), []byte(tt.text))
			c := runAudit(t, home).check(t, "SEC-06")
			if tt.note == "" {
				if c["verdict"] != "PASS" || c["observed"] != "none found" || c["note"] != "" {
					t.Errorf("SEC-06 = %v", c)
				}
				return
			}
			if c["verdict"] != "FAIL" || c["note"] != tt.note {
				t.Errorf("SEC-06 = %v, want note %q", c, tt.note)
			}
		})
	}
}

func TestSec06OnlyLicenseFilesThatAreRegularAreRead(t *testing.T) {
	home := t.TempDir()
	lic := filepath.Join(home, "security", "licenses")
	saWrite(t, filepath.Join(lic, "notes.txt"), []byte(`smDeveloperMode="true"`))
	saWrite(t, filepath.Join(lic, "real.bin"), []byte(`smDeveloperMode="true"`))
	target := filepath.Join(home, "target")
	saWrite(t, target, []byte(`smDeveloperMode="true"`))
	if err := os.Symlink(target, filepath.Join(lic, "link.license")); err != nil {
		t.Fatal(err)
	}
	saMkdir(t, filepath.Join(lic, "dir.license"))
	c := runAudit(t, home).check(t, "SEC-06")
	if c["verdict"] != "PASS" || c["observed"] != "none found" {
		t.Errorf("SEC-06 = %v: only regular *.license files count", c)
	}
}

// The scan stops after 200 directory entries (all names count, licenses or not).
func TestSec06ScanIsCappedAt200Entries(t *testing.T) {
	home := t.TempDir()
	lic := filepath.Join(home, "security", "licenses")
	for i := 0; i < 200; i++ {
		saWrite(t, filepath.Join(lic, fmt.Sprintf("a%03d.txt", i)), nil)
	}
	saWrite(t, filepath.Join(lic, "z.license"), []byte(`smDeveloperMode="true"`))
	if v := runAudit(t, home).verdict(t, "SEC-06"); v != "PASS" {
		t.Errorf("the 201st entry was read: SEC-06 = %s", v)
	}
	if err := os.Remove(filepath.Join(lic, "a199.txt")); err != nil {
		t.Fatal(err)
	}
	if v := runAudit(t, home).verdict(t, "SEC-06"); v != "FAIL" {
		t.Errorf("the 200th entry was not read: SEC-06 = %s", v)
	}
}

// T23: a wildcard KeyRingPermission in an unsigned module fails SEC-15 and the scan count is visible.
func TestSec15WildcardUnsignedFails(t *testing.T) {
	a := runAudit(t, fixtures(t).modulesWild)
	c := a.check(t, "SEC-15")
	wantObs := "1 module(s) declare KeyRingPermission; 1 wildcard (name=*); 1 wildcard AND unsigned; scanned 2 of 2 JAR(s)"
	if c["verdict"] != "FAIL" || c["observed"] != wantObs || c["note"] != "1 unsigned wildcard holder(s) detected" {
		t.Errorf("SEC-15 = %v", c)
	}
}

func TestSec15SignedAndTargetForms(t *testing.T) {
	home := t.TempDir()
	mods := filepath.Join(home, "modules")
	saWrite(t, filepath.Join(mods, "a-signed.jar"), saJar(saWildcardXML, true))
	saWrite(t, filepath.Join(mods, "b-target.jar"), saJar(`<m><p class="x.KeyRingPermission" target="*"/></m>`, false))
	saWrite(t, filepath.Join(mods, "c-named.jar"), saJar(`<m><p class="x.KeyRingPermission" name="vault"/></m>`, false))
	saWrite(t, filepath.Join(mods, "d-other.jar"), saJar(saOtherXML, false))
	saWrite(t, filepath.Join(mods, "e-readme.txt"), []byte("not a jar"))
	c := runAudit(t, home).check(t, "SEC-15")
	wantObs := "3 module(s) declare KeyRingPermission; 2 wildcard (name=*); 1 wildcard AND unsigned; scanned 4 of 4 JAR(s)"
	if c["verdict"] != "FAIL" || c["observed"] != wantObs {
		t.Errorf("SEC-15 = %v", c)
	}
	// only signed wildcard holders: PASS with the signed note
	saWrite(t, filepath.Join(mods, "b-target.jar"), saJar(saOtherXML, false))
	c = runAudit(t, home).check(t, "SEC-15")
	if c["verdict"] != "PASS" || c["note"] != "all wildcard holders are signed (or no wildcard holders found)" {
		t.Errorf("SEC-15 = %v", c)
	}
}

func TestSec15SignatureSuffixesAndCase(t *testing.T) {
	for _, sig := range []string{"META-INF/X.RSA", "META-INF/x.dsa", "META-INF/Y.ec", "META-INF/sub/Z.Rsa"} {
		home := t.TempDir()
		jar := bogtest.Zip(bogtest.Entry{Name: "META-INF/module.xml", Data: []byte(saWildcardXML)}, bogtest.Entry{Name: sig, Data: []byte("sig")})
		saWrite(t, filepath.Join(home, "modules", "m.jar"), jar)
		if v := runAudit(t, home).verdict(t, "SEC-15"); v != "PASS" {
			t.Errorf("signature member %s: SEC-15 = %s, want PASS (signed)", sig, v)
		}
	}
	for _, sig := range []string{"X.RSA", "META-INF/X.SF", "other/META-INF/X.RSA", "META-INF/RSA"} {
		home := t.TempDir()
		jar := bogtest.Zip(bogtest.Entry{Name: "META-INF/module.xml", Data: []byte(saWildcardXML)}, bogtest.Entry{Name: sig, Data: []byte("sig")})
		saWrite(t, filepath.Join(home, "modules", "m.jar"), jar)
		if v := runAudit(t, home).verdict(t, "SEC-15"); v != "FAIL" {
			t.Errorf("member %s is not a signature: SEC-15 = %s, want FAIL", sig, v)
		}
	}
}

// A symlinked JAR is skipped and not counted, so the scan reads as truncated; a bad archive is counted.
func TestSec15SymlinkedAndBrokenJarsAreVisibleInTheCount(t *testing.T) {
	home := t.TempDir()
	mods := filepath.Join(home, "modules")
	saWrite(t, filepath.Join(mods, "good.jar"), saJar(saOtherXML, false))
	saWrite(t, filepath.Join(mods, "broken.jar"), []byte("not a zip"))
	saMkdir(t, filepath.Join(mods, "dir.jar"))
	if err := os.Symlink(filepath.Join(mods, "good.jar"), filepath.Join(mods, "link.jar")); err != nil {
		t.Fatal(err)
	}
	c := runAudit(t, home).check(t, "SEC-15")
	want := "0 module(s) declare KeyRingPermission; 0 wildcard (name=*); 0 wildcard AND unsigned; scanned 3 of 4 JAR(s) (truncated)"
	if c["verdict"] != "PASS" || c["observed"] != want {
		t.Errorf("SEC-15 = %v", c)
	}
}

func TestSec15ScanIsCappedAt5000Jars(t *testing.T) {
	if testing.Short() {
		t.Skip("writes 5001 files")
	}
	home := t.TempDir()
	mods := filepath.Join(home, "modules")
	tiny := saJar(saOtherXML, false)
	for i := 0; i < 5001; i++ {
		saWrite(t, filepath.Join(mods, fmt.Sprintf("m%05d.jar", i)), tiny)
	}
	c := runAudit(t, home).check(t, "SEC-15")
	if want := "0 module(s) declare KeyRingPermission; 0 wildcard (name=*); 0 wildcard AND unsigned; scanned 5000 of 5001 JAR(s) (truncated)"; c["observed"] != want {
		t.Errorf("SEC-15 observed = %q", c["observed"])
	}
}

// A modules/ symlink out of the root is not scanned, and one that is a symlink is NA like an absent one.
func TestSec15ModulesSymlinkIsNA(t *testing.T) {
	outside := filepath.Join(t.TempDir(), "mods")
	saWrite(t, filepath.Join(outside, "w.jar"), saJar(saWildcardXML, false))
	home := t.TempDir()
	if err := os.Symlink(outside, filepath.Join(home, "modules")); err != nil {
		t.Fatal(err)
	}
	c := runAudit(t, home).check(t, "SEC-15")
	if c["verdict"] != "NA" || c["observed"] != "modules/ directory absent" {
		t.Errorf("SEC-15 = %v", c)
	}
}

// T24: a bog whose file.xml inflates past the cap is MANUAL (truncated), not a clean verdict.
func TestOversizedBogIsManualTruncated(t *testing.T) {
	a := runAudit(t, fixtures(t).secure, "--station", largeBog(t))
	for _, id := range []string{"SEC-08", "SEC-10", "SEC-12"} {
		c := a.check(t, id)
		if c["verdict"] != "MANUAL" || c["observed"] != "not checked (ZIP file.xml exceeds 32 MiB inflate cap)" {
			t.Errorf("%s = %v", id, c)
		}
	}
}

// T25: a module.xml over 64 KiB is skipped, so its wildcard is not reported.
func TestOversizedModuleXMLIsSkipped(t *testing.T) {
	a := runAudit(t, fixtures(t).jarBomb)
	c := a.check(t, "SEC-15")
	if c["verdict"] != "PASS" || !strings.Contains(c["observed"].(string), "0 module(s) declare KeyRingPermission") || !strings.Contains(c["observed"].(string), "scanned 1 of 1") {
		t.Errorf("SEC-15 = %v", c)
	}
}

func TestModuleXMLCapIsInclusive(t *testing.T) {
	home := t.TempDir()
	pad := func(n int) string { return saWildcardXML + strings.Repeat("A", n-len(saWildcardXML)) }
	saWrite(t, filepath.Join(home, "modules", "at-cap.jar"), saJar(pad(64*1024), false))
	if v := runAudit(t, home).verdict(t, "SEC-15"); v != "FAIL" {
		t.Errorf("a module.xml of exactly 64 KiB must be read: SEC-15 = %s", v)
	}
	saWrite(t, filepath.Join(home, "modules", "at-cap.jar"), saJar(pad(64*1024+1), false))
	if v := runAudit(t, home).verdict(t, "SEC-15"); v != "PASS" {
		t.Errorf("a module.xml one byte over 64 KiB must be skipped: SEC-15 = %s", v)
	}
}

// The plaintext fallback reads at most 4 MiB: an attribute after the cap is not seen.
func TestPlaintextBogIsReadOnlyUpToTheCap(t *testing.T) {
	dir := t.TempDir()
	inside := filepath.Join(dir, "inside.xml")
	saWrite(t, inside, []byte(strings.Repeat(" ", 4*1024*1024-40)+`allowProgramRuntimeExec="true"`))
	if v := runAudit(t, fixtures(t).secure, "--station", inside).verdict(t, "SEC-08"); v != "FAIL" {
		t.Errorf("an attribute inside the cap: SEC-08 = %s", v)
	}
	outside := filepath.Join(dir, "outside.xml")
	saWrite(t, outside, []byte(strings.Repeat(" ", 4*1024*1024)+`allowProgramRuntimeExec="true"`))
	if v := runAudit(t, fixtures(t).secure, "--station", outside).verdict(t, "SEC-08"); v != "PASS" {
		t.Errorf("an attribute past the cap must not be seen: SEC-08 = %s", v)
	}
}

func TestStationFormatEdges(t *testing.T) {
	dir := t.TempDir()
	root := fixtures(t).secure
	noFile := bogtest.Zip(bogtest.Entry{Name: "other.xml", Data: []byte("<a/>")})
	nul := append([]byte("<c allowProgramRuntimeExec='true'/>"), make([]byte, 600)...)
	lateNul := append([]byte(strings.Repeat("x", 600)), 0)
	lateNul = append(lateNul, []byte(" allowProgramRuntimeExec='true'")...)
	tests := []struct {
		name    string
		data    []byte
		verdict string // SEC-08
		obs     string
	}{
		{"zip without file.xml is unknown", noFile, "MANUAL", "not checked (station file format unrecognized: not a ZIP bog or plaintext)"},
		{"empty file is plaintext with nothing in it", nil, "PASS", "false/default"},
		{"a NUL in the first 512 bytes is binary", nul, "MANUAL", "not checked (station file format unrecognized: not a ZIP bog or plaintext)"},
		{"a NUL after byte 512 is still text", lateNul, "FAIL", "true"},
		{"a broken zip is unknown, not plaintext", []byte("PK\x03\x04\x00\x00 broken"), "MANUAL", "not checked (station file format unrecognized: not a ZIP bog or plaintext)"},
		{"a zip whose file.xml is corrupt falls back and is unknown", bogtest.CorruptDeflate(), "MANUAL", "not checked (station file format unrecognized: not a ZIP bog or plaintext)"},
		{"case-insensitive attribute and quote forms", []byte(`<c ALLOWPROGRAMRUNTIMEEXEC = 'TRUE'/>`), "FAIL", "true"},
		{"unquoted true", []byte(`<c allowProgramRuntimeExec=true/>`), "FAIL", "true"},
		{"false", []byte(`<c allowProgramRuntimeExec="false"/>`), "PASS", "false/default"},
		{"dotless i folds onto i like Python's re", []byte("<c allowProgramRuntımeExec=\"true\"/>"), "FAIL", "true"},
		{"dotted capital I folds onto i like Python's re", []byte("<c allowProgramRuntİmeExec=\"true\"/>"), "FAIL", "true"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			p := filepath.Join(dir, "s.bog")
			_ = os.Remove(p)
			saWrite(t, p, tt.data)
			c := runAudit(t, root, "--station", p).check(t, "SEC-08")
			if c["verdict"] != tt.verdict || c["observed"] != tt.obs {
				t.Errorf("SEC-08 = %v", c)
			}
		})
	}
}

func TestSec10NeedsServiceAndEnabled(t *testing.T) {
	root := fixtures(t).secure
	tests := []struct{ name, xml, verdict string }{
		{"BSyslogSettings enabled", `<c n="BSyslogSettings" enabled="true"/>`, "PASS"},
		{"enabled without a syslog service", `<c enabled="true"/>`, "FAIL"},
		{"service without enabled", `<c n="SyslogService"/>`, "FAIL"},
		{"the service name is case sensitive", `<c n="syslogservice" enabled="true"/>`, "FAIL"},
		{"enabled elsewhere counts, like the legacy regex", `<c n="SyslogService" enabled="false"/><d enabled='TRUE'/>`, "PASS"},
		{"enabled=1 is not true", `<c n="SyslogService" enabled="1"/>`, "FAIL"},
	}
	for _, tt := range tests {
		p := filepath.Join(t.TempDir(), "s.bog")
		saWrite(t, p, []byte(tt.xml))
		if v := runAudit(t, root, "--station", p).verdict(t, "SEC-10"); v != tt.verdict {
			t.Errorf("%s: SEC-10 = %s, want %s", tt.name, v, tt.verdict)
		}
	}
}

func TestSec12KeySourceValues(t *testing.T) {
	root := fixtures(t).secure
	tests := []struct{ name, xml, verdict string }{
		{"external", `<c reversibleEncodingKeySource="external"/>`, "PASS"},
		{"none", `<c reversibleEncodingKeySource="none"/>`, "FAIL"},
		{"None capitalised", `<c reversibleEncodingKeySource='None'/>`, "FAIL"},
		{"false", `<c reversibleEncodingKeySource="false"/>`, "FAIL"},
		{"zero", `<c reversibleEncodingKeySource=0/>`, "FAIL"},
		{"empty quoted value does not match, so no key source", `<c reversibleEncodingKeySource=""/>`, "FAIL"},
		{"the first usable occurrence wins", `<c reversibleEncodingKeySource=""/><d reversibleEncodingKeySource="hsm"/>`, "PASS"},
		{"the first match decides even when a later one differs", `<c reversibleEncodingKeySource="none"/><d reversibleEncodingKeySource="hsm"/>`, "FAIL"},
		{"case-insensitive name", `<c REVERSIBLEENCODINGKEYSOURCE="vault"/>`, "PASS"},
		{"Kelvin sign inside the name", "<c reversibleEncoding\u212aeySource=\"vault\"/>", "PASS"},
		{"long s inside the name", "<c reversibleEncodingKeyſource=\"vault\"/>", "PASS"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			p := filepath.Join(t.TempDir(), "s.bog")
			saWrite(t, p, []byte(tt.xml))
			if v := runAudit(t, root, "--station", p).verdict(t, "SEC-12"); v != tt.verdict {
				t.Errorf("SEC-12 = %s, want %s", v, tt.verdict)
			}
		})
	}
}

// The property file: first existing regular file wins, comments, case and spacing forms.
func TestPropertiesFileSelectionAndParsing(t *testing.T) {
	t.Run("defaults/ wins over the root file", func(t *testing.T) {
		home := t.TempDir()
		saWrite(t, filepath.Join(home, "defaults", "system.properties"), []byte("niagara.moduleVerificationMode=high\n"))
		saWrite(t, filepath.Join(home, "system.properties"), []byte("niagara.moduleVerificationMode=low\n"))
		if c := runAudit(t, home).check(t, "SEC-01"); c["verdict"] != "PASS" || c["observed"] != "high" {
			t.Errorf("SEC-01 = %v", c)
		}
	})
	t.Run("an existing defaults file without the key hides the root file", func(t *testing.T) {
		home := t.TempDir()
		saWrite(t, filepath.Join(home, "defaults", "system.properties"), []byte("# nothing here\n"))
		saWrite(t, filepath.Join(home, "system.properties"), []byte("niagara.moduleVerificationMode=high\n"))
		if c := runAudit(t, home).check(t, "SEC-01"); c["observed"] != "(unset)" {
			t.Errorf("SEC-01 = %v", c)
		}
	})
	t.Run("a symlinked or oversized defaults file is skipped for the root file", func(t *testing.T) {
		home := t.TempDir()
		saWrite(t, filepath.Join(home, "real"), []byte("niagara.moduleVerificationMode=low\n"))
		saMkdir(t, filepath.Join(home, "defaults"))
		if err := os.Symlink(filepath.Join(home, "real"), filepath.Join(home, "defaults", "system.properties")); err != nil {
			t.Fatal(err)
		}
		saWrite(t, filepath.Join(home, "system.properties"), []byte("niagara.moduleVerificationMode=high\n"))
		if c := runAudit(t, home).check(t, "SEC-01"); c["observed"] != "high" {
			t.Errorf("symlinked defaults file was read: %v", c)
		}
		_ = os.Remove(filepath.Join(home, "defaults", "system.properties"))
		saWrite(t, filepath.Join(home, "defaults", "system.properties"), append([]byte("niagara.moduleVerificationMode=low\n"), make([]byte, maxPropsBytes)...))
		if c := runAudit(t, home).check(t, "SEC-01"); c["observed"] != "high" {
			t.Errorf("an oversized defaults file was read: %v", c)
		}
	})
	t.Run("a defaults directory that escapes the root is skipped", func(t *testing.T) {
		outside := filepath.Join(t.TempDir(), "d")
		saWrite(t, filepath.Join(outside, "system.properties"), []byte("niagara.moduleVerificationMode=low\n"))
		home := t.TempDir()
		if err := os.Symlink(outside, filepath.Join(home, "defaults")); err != nil {
			t.Fatal(err)
		}
		saWrite(t, filepath.Join(home, "system.properties"), []byte("niagara.moduleVerificationMode=high\n"))
		if c := runAudit(t, home).check(t, "SEC-01"); c["observed"] != "high" {
			t.Errorf("SEC-01 = %v", c)
		}
	})
	t.Run("a file at the cap is read", func(t *testing.T) {
		home := t.TempDir()
		line := "niagara.moduleVerificationMode=high\n"
		saWrite(t, filepath.Join(home, "system.properties"), append([]byte(line), []byte(strings.Repeat("#", maxPropsBytes-len(line)))...))
		if c := runAudit(t, home).check(t, "SEC-01"); c["observed"] != "high" {
			t.Errorf("SEC-01 = %v", c)
		}
	})
}

func TestPropertyLineForms(t *testing.T) {
	tests := []struct {
		name, text string
		sec01      string // observed
		verdict    string
	}{
		{"commented", "#niagara.moduleVerificationMode=high\n", "(commented)", "FAIL"},
		{"commented with spaces", "  #   niagara.moduleVerificationMode = high\n", "(commented)", "FAIL"},
		{"double hash is not an assignment", "##niagara.moduleVerificationMode=high\n", "(unset)", "FAIL"},
		{"spaces around equals", "niagara.moduleVerificationMode   =   high   \n", "high", "PASS"},
		{"tab separators", "\tniagara.moduleVerificationMode\t=\thigh\t\n", "high", "PASS"},
		{"CRLF", "niagara.moduleVerificationMode=high\r\n", "high", "PASS"},
		{"lone CR is a line break", "x=1\rniagara.moduleVerificationMode=high\r", "high", "PASS"},
		{"uppercase LOW is low", "niagara.moduleVerificationMode=LOW\n", "LOW", "FAIL"},
		{"the last assignment wins", "niagara.moduleVerificationMode=low\nniagara.moduleVerificationMode=high\n", "high", "PASS"},
		{"a later comment overrides to commented", "niagara.moduleVerificationMode=high\n#niagara.moduleVerificationMode=high\n", "(commented)", "FAIL"},
		{"empty value is set and not low", "niagara.moduleVerificationMode=\n", "", "PASS"},
		{"value keeps inner spaces and equals", "niagara.moduleVerificationMode=hi gh=2\n", "hi gh=2", "PASS"},
		{"no equals sign", "niagara.moduleVerificationMode high\n", "(unset)", "FAIL"},
		{"a different key with the same prefix", "niagara.moduleVerificationModeX=high\n", "(unset)", "FAIL"},
		{"no-break space is whitespace", "niagara.moduleVerificationMode = high \n", "high", "PASS"},
		{"a BOM before the key hides it, as in Python", "\ufeffniagara.moduleVerificationMode=high\n", "(unset)", "FAIL"},
		{"invalid UTF-8 in the value becomes U+FFFD", "niagara.moduleVerificationMode=hi\xffgh\n", "hi�gh", "PASS"},
		{"U+0085 inside a value is kept, not a line break", "niagara.moduleVerificationMode=hi\u0085gh\n", "hi\u0085gh", "PASS"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			home := t.TempDir()
			saWrite(t, filepath.Join(home, "system.properties"), []byte(tt.text))
			c := runAudit(t, home).check(t, "SEC-01")
			if c["observed"] != tt.sec01 || c["verdict"] != tt.verdict {
				t.Errorf("SEC-01 = %v, want observed %q verdict %s", c, tt.sec01, tt.verdict)
			}
		})
	}
}

func TestSec07Forms(t *testing.T) {
	tests := []struct{ text, observed, verdict string }{
		{"program.requireSigning=true\n", "true", "PASS"},
		{"program.requireSigning=TRUE\n", "TRUE", "PASS"},
		{"program.requireSigning=False\n", "false/default", "FAIL"},
		{"#program.requireSigning=true\n", "false/default", "FAIL"},
		{"", "false/default", "FAIL"},
		{"program.requireSigning=maybe\n", "maybe", "PASS"},
	}
	for _, tt := range tests {
		home := t.TempDir()
		saWrite(t, filepath.Join(home, "system.properties"), []byte(tt.text))
		if c := runAudit(t, home).check(t, "SEC-07"); c["observed"] != tt.observed || c["verdict"] != tt.verdict {
			t.Errorf("%q: SEC-07 = %v", tt.text, c)
		}
	}
}

func TestSec02Sec03Sec11ReportPresence(t *testing.T) {
	home := t.TempDir()
	saWrite(t, filepath.Join(home, "security", "truststore.jks"), []byte("x"))
	saWrite(t, filepath.Join(home, "jre", "lib", "security", "cacerts.bcfks"), []byte("x"))
	a := runAudit(t, home)
	wantVerdicts(t, a, map[string]string{"SEC-02": "MANUAL", "SEC-03": "MANUAL", "SEC-11": "MANUAL"})
	if got := a.check(t, "SEC-02")["observed"]; got != "present" {
		t.Errorf("SEC-02 observed = %q", got)
	}
	if got := a.check(t, "SEC-03")["observed"]; got != "directory present" {
		t.Errorf("SEC-03 observed = %q", got)
	}
	if got := a.check(t, "SEC-11")["observed"]; got != "truststore.jks: present; FIPS indicator (cacerts.bcfks): present" {
		t.Errorf("SEC-11 observed = %q", got)
	}
	b := runAudit(t, t.TempDir())
	if got := b.check(t, "SEC-11")["observed"]; got != "truststore.jks: absent; FIPS indicator (cacerts.bcfks): absent" {
		t.Errorf("SEC-11 observed = %q", got)
	}
	if got := b.check(t, "SEC-03")["observed"]; got != "directory absent" {
		t.Errorf("SEC-03 observed = %q", got)
	}
	// a symlinked truststore does not count
	link := t.TempDir()
	saWrite(t, filepath.Join(link, "real"), []byte("x"))
	saMkdir(t, filepath.Join(link, "security"))
	if err := os.Symlink(filepath.Join(link, "real"), filepath.Join(link, "security", "truststore.jks")); err != nil {
		t.Fatal(err)
	}
	if got := runAudit(t, link).check(t, "SEC-02")["observed"]; got != "absent" {
		t.Errorf("symlinked truststore: SEC-02 observed = %q", got)
	}
}

func TestNetworkChecksAreAlwaysManual(t *testing.T) {
	a := runAudit(t, fixtures(t).secure)
	for _, id := range []string{"SEC-04", "SEC-09", "SEC-14"} {
		c := a.check(t, id)
		if c["verdict"] != "MANUAL" || c["observed"] != "not checked (requires live port probe)" {
			t.Errorf("%s = %v", id, c)
		}
	}
}
