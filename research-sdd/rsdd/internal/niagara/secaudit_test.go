package niagara

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/niagara/bog"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/niagara/bogtest"
)

// ---- fixtures: every install tree and station file of the retired bash suite, built in memory ----

func saWrite(t *testing.T, path string, data []byte) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}
}

func saMkdir(t *testing.T, path string) {
	t.Helper()
	if err := os.MkdirAll(path, 0o700); err != nil {
		t.Fatal(err)
	}
}

// saJar is a module JAR whose only interesting member is META-INF/module.xml.
func saJar(moduleXML string, signed bool) []byte {
	entries := []bogtest.Entry{{Name: "META-INF/module.xml", Data: []byte(moduleXML)}}
	if signed {
		entries = append(entries, bogtest.Entry{Name: "META-INF/CERT.RSA", Data: []byte("fake-cert-data")})
	}
	return bogtest.Zip(entries...)
}

const (
	saWildcardXML = `<module><permission class="com.tridium.security.KeyRingPermission" name="*"/></module>`
	saOtherXML    = `<module><permission class="com.tridium.security.SomeOtherPermission" name="*"/></module>`
)

type saFixtures struct {
	secure, insecure, empty, licHit, modulesWild, jarBomb string
	bog                                                   map[string]string
}

func fixtures(t *testing.T) saFixtures {
	t.Helper()
	root := t.TempDir()
	fx := saFixtures{
		secure: filepath.Join(root, "secure-home"), insecure: filepath.Join(root, "insecure-home"),
		empty: filepath.Join(root, "empty-home"), licHit: filepath.Join(root, "lic-hit-home"),
		modulesWild: filepath.Join(root, "modules-wild-home"), jarBomb: filepath.Join(root, "jar-bomb-home"),
		bog: map[string]string{},
	}
	saWrite(t, filepath.Join(fx.secure, "defaults", "system.properties"), []byte(
		"niagara.moduleVerificationMode=high\nprogram.requireSigning=true\n"+
			"niagara.commandLinePropertyBlacklist=skipModuleValidation,commissioning.ignoreVerificationMode\n"))
	saMkdir(t, filepath.Join(fx.secure, "security"))
	saWrite(t, filepath.Join(fx.insecure, "defaults", "system.properties"), []byte(
		"niagara.moduleVerificationMode=low\nprogram.requireSigning=false\n"))
	saMkdir(t, filepath.Join(fx.insecure, "security"))
	saMkdir(t, fx.empty)

	bogs := map[string][]byte{
		"bog-exec-on.zip":    bogtest.Bog(`<config><ProgramService allowProgramRuntimeExec="true"/></config>`),
		"bog-exec-off.zip":   bogtest.Bog(`<config><ProgramService allowProgramRuntimeExec="false"/></config>`),
		"bog-syslog-on.zip":  bogtest.Bog(`<config><SyslogService enabled="true" serverHost="siem.example.com"/></config>`),
		"bog-syslog-off.zip": bogtest.Bog(`<config><SyslogService enabled="false"/></config>`),
		"bog-ext-key.zip":    bogtest.Bog(`<config><SecurityService reversibleEncodingKeySource="external"/></config>`),
		"bog-no-key.zip":     bogtest.Bog(`<config><station someAttr="value"/></config>`),
		"bog-binary.dat":     bogtest.Binary(),
		"bog-plaintext.xml":  []byte(`<config><ProgramService allowProgramRuntimeExec="true"/><SyslogService enabled="false"/></config>`),
	}
	for name, data := range bogs {
		p := filepath.Join(root, "bogs", name)
		saWrite(t, p, data)
		fx.bog[name] = p
	}

	saWrite(t, filepath.Join(fx.licHit, "defaults", "system.properties"), []byte("niagara.moduleVerificationMode=high\n"))
	saWrite(t, filepath.Join(fx.licHit, "security", "licenses", "dev.license"), []byte("<?xml version=\"1.0\"?>\n<license smDeveloperMode=\"true\"/>\n"))

	saWrite(t, filepath.Join(fx.modulesWild, "modules", "wildcard-unsigned.jar"), saJar(saWildcardXML, false))
	saWrite(t, filepath.Join(fx.modulesWild, "modules", "plain-unsigned.jar"), saJar(saOtherXML, false))

	saWrite(t, filepath.Join(fx.jarBomb, "modules", "bomb.jar"), saJar(saWildcardXML+strings.Repeat("A", 64*1024+1), false))
	return fx
}

// largeBog is a ZIP whose file.xml inflates to one byte over the 32 MiB cap.
func largeBog(t *testing.T) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "bog-large.zip")
	saWrite(t, p, bogtest.Bomb(bog.MaxInflate))
	return p
}

// ---- helpers ----

type audit struct {
	code   int
	stdout string
	stderr string
	out    string // the --output path
	doc    map[string]any
}

// runAudit runs security-audit on root with extra flags and decodes the JSON it wrote (nil when none).
func runAudit(t *testing.T, root string, extra ...string) audit {
	t.Helper()
	a := audit{out: filepath.Join(t.TempDir(), "out.json")}
	a.code, a.stdout, a.stderr = runSA(append([]string{root, "--output", a.out}, extra...)...)
	raw, err := os.ReadFile(a.out)
	if err != nil {
		return a
	}
	if err := json.Unmarshal(raw, &a.doc); err != nil {
		t.Fatalf("output is not JSON: %v\n%s", err, raw)
	}
	return a
}

func (a audit) check(t *testing.T, id string) map[string]any {
	t.Helper()
	if a.doc == nil {
		t.Fatalf("no JSON written (exit %d, stderr %q)", a.code, a.stderr)
	}
	for _, c := range a.doc["checks"].([]any) {
		if m := c.(map[string]any); m["id"] == id {
			return m
		}
	}
	t.Fatalf("no check %s in %v", id, a.doc["checks"])
	return nil
}

func (a audit) verdict(t *testing.T, id string) string {
	t.Helper()
	return a.check(t, id)["verdict"].(string)
}

func wantVerdicts(t *testing.T, a audit, want map[string]string) {
	t.Helper()
	if a.code != 0 || a.stdout != "" {
		t.Fatalf("exit %d stdout %q stderr %q, want exit 0 and an empty stdout", a.code, a.stdout, a.stderr)
	}
	for id, v := range want {
		if got := a.verdict(t, id); got != v {
			t.Errorf("%s = %s, want %s (observed %q)", id, got, v, a.check(t, id)["observed"])
		}
	}
}

const notProvided = "not checked (no --station config.bog provided)"

// T1: an absent root exits 2 and writes nothing.
func TestAbsentRootExits2WithoutJSON(t *testing.T) {
	out := filepath.Join(t.TempDir(), "o.json")
	missing := filepath.Join(t.TempDir(), "no-such-dir")
	code, stdout, stderr := runSA(missing, "--output", out)
	if code != 2 || stdout != "" || stderr != "niagara-security-audit: "+missing+": No such file or directory\n" {
		t.Errorf("code %d stdout %q stderr %q", code, stdout, stderr)
	}
	if _, err := os.Stat(out); err == nil {
		t.Error("an output file was written for an absent root")
	}
}

// T2 and T19: a symlink root is refused, with or without a trailing slash.
func TestSymlinkRootRefused(t *testing.T) {
	fx := fixtures(t)
	link := filepath.Join(t.TempDir(), "sym-home")
	if err := os.Symlink(fx.secure, link); err != nil {
		t.Fatal(err)
	}
	for _, root := range []string{link, link + "/", link + "///"} {
		a := runAudit(t, root)
		want := "niagara-security-audit: " + link + ": is a symbolic link (rejected)\n"
		if a.code != 2 || a.stderr != want || a.doc != nil {
			t.Errorf("root %q: code %d stderr %q doc %v", root, a.code, a.stderr, a.doc)
		}
	}
}

// T3: a regular file is not an install root.
func TestNonDirectoryRootRefused(t *testing.T) {
	p := filepath.Join(t.TempDir(), "notadir.txt")
	saWrite(t, p, []byte("notadir\n"))
	a := runAudit(t, p)
	if a.code != 2 || a.stderr != "niagara-security-audit: "+p+": not a directory\n" || a.doc != nil {
		t.Errorf("code %d stderr %q doc %v", a.code, a.stderr, a.doc)
	}
}

// T4: an empty directory is a complete audit that proves it looked: every static check still fires.
func TestEmptyInstallIsCompleteAndRanChecks(t *testing.T) {
	a := runAudit(t, fixtures(t).empty)
	if a.code != 0 || a.doc["schema"] != "niagara-audit.v1" || a.doc["status"] != "complete" {
		t.Fatalf("code %d doc %v", a.code, a.doc)
	}
	if errs := a.doc["errors"].([]any); len(errs) != 0 {
		t.Errorf("errors = %v", errs)
	}
	sum := a.doc["summary"].(map[string]any)
	if sum["checks_run"].(float64) != 15 {
		t.Errorf("checks_run = %v, want 15 (SEC-13 is not defined)", sum["checks_run"])
	}
	// absent, empty and no-match stay distinct: nothing was found, and the report says so per check.
	wantVerdicts(t, a, map[string]string{"SEC-01": "FAIL", "SEC-06": "NA", "SEC-15": "NA", "SEC-02": "MANUAL"})
	if got := a.check(t, "SEC-01")["observed"]; got != "(unset)" {
		t.Errorf("SEC-01 observed = %q", got)
	}
}

// T5: a hardened install passes the property checks.
func TestSecureInstallPasses(t *testing.T) {
	a := runAudit(t, fixtures(t).secure)
	wantVerdicts(t, a, map[string]string{"SEC-01": "PASS", "SEC-05": "PASS", "SEC-07": "PASS"})
	if got := a.check(t, "SEC-01")["observed"]; got != "high" {
		t.Errorf("SEC-01 observed = %q", got)
	}
	if got := a.check(t, "SEC-05")["observed"]; got != "full" {
		t.Errorf("SEC-05 observed = %q", got)
	}
	if got := a.check(t, "SEC-07")["observed"]; got != "true" {
		t.Errorf("SEC-07 observed = %q", got)
	}
}

// T6: a weakened install fails SEC-01 and SEC-07.
func TestInsecureInstallFails(t *testing.T) {
	a := runAudit(t, fixtures(t).insecure)
	wantVerdicts(t, a, map[string]string{"SEC-01": "FAIL", "SEC-07": "FAIL", "SEC-05": "FAIL"})
	if got := a.check(t, "SEC-07")["observed"]; got != "false/default" {
		t.Errorf("SEC-07 observed = %q", got)
	}
	sum := a.doc["summary"].(map[string]any)
	if sum["checks_fail"].(float64) < 2 {
		t.Errorf("checks_fail = %v, want >= 2", sum["checks_fail"])
	}
}

// T7: an --output symlink is refused and its victim is left alone.
func TestAuditOutputSymlinkRefused(t *testing.T) {
	dir := t.TempDir()
	victim := filepath.Join(dir, "victim.txt")
	saWrite(t, victim, []byte("victim-content\n"))
	link := filepath.Join(dir, "out_sym.json")
	if err := os.Symlink(victim, link); err != nil {
		t.Fatal(err)
	}
	code, _, stderr := runSA(fixtures(t).secure, "--output", link)
	if b, _ := os.ReadFile(victim); code != 2 || string(b) != "victim-content\n" {
		t.Errorf("code %d victim %q stderr %q", code, b, stderr)
	}
	if want := "niagara-security-audit: output error: [Errno 17] File exists: '" + link + "'\n"; stderr != want {
		t.Errorf("stderr = %q, want %q", stderr, want)
	}
}

// T8: an existing output is never overwritten (O_CREAT|O_EXCL).
func TestAuditExistingOutputRefused(t *testing.T) {
	out := filepath.Join(t.TempDir(), "pre_existing.json")
	saWrite(t, out, []byte("existing\n"))
	code, _, stderr := runSA(fixtures(t).secure, "--output", out)
	if b, _ := os.ReadFile(out); code != 2 || string(b) != "existing\n" {
		t.Errorf("code %d content %q", code, b)
	}
	if want := "niagara-security-audit: output error: [Errno 17] File exists: '" + out + "'\n"; stderr != want {
		t.Errorf("stderr = %q, want %q", stderr, want)
	}
}

func TestOutputErrorsNameTheErrno(t *testing.T) {
	root := fixtures(t).secure
	missing := filepath.Join(t.TempDir(), "no", "such", "o.json")
	code, _, stderr := runSA(root, "--output", missing)
	if want := "niagara-security-audit: output error: [Errno 2] No such file or directory: '" + missing + "'\n"; code != 2 || stderr != want {
		t.Errorf("missing directory: code %d stderr %q", code, stderr)
	}
	dir := t.TempDir()
	code, _, stderr = runSA(root, "--output", dir)
	if want := "niagara-security-audit: output error: [Errno 17] File exists: '" + dir + "'\n"; code != 2 || stderr != want {
		t.Errorf("directory as output: code %d stderr %q", code, stderr)
	}
	code, _, stderr = runSA(root, "--output", "")
	if want := "niagara-security-audit: output error: [Errno 2] No such file or directory: ''\n"; code != 2 || stderr != want {
		t.Errorf("empty output: code %d stderr %q", code, stderr)
	}
}

func TestOutputIsWrittenPrivateAndNothingElseIsTouched(t *testing.T) {
	fx := fixtures(t)
	out := filepath.Join(t.TempDir(), "o.json")
	code, stdout, stderr := runSA(fx.secure, "--output", out)
	fi, err := os.Stat(out)
	if err != nil || code != 0 || stdout != "" || stderr != "" || fi.Mode().Perm() != 0o600 {
		t.Fatalf("code %d stdout %q stderr %q stat %v %v", code, stdout, stderr, fi, err)
	}
	raw, _ := os.ReadFile(out)
	if !strings.HasSuffix(string(raw), "\n") || !strings.HasPrefix(string(raw), "{\n  \"checks\": [") {
		t.Errorf("output is not indent=2 key-sorted JSON ending in a newline: %.80q", raw)
	}
}

// T9: SEC-16 fails by design in every install.
func TestSec16AlwaysFails(t *testing.T) {
	fx := fixtures(t)
	for _, root := range []string{fx.secure, fx.empty, fx.insecure} {
		a := runAudit(t, root)
		c := a.check(t, "SEC-16")
		if c["verdict"] != "FAIL" || c["observed"] != "unsigned by design (architectural limitation)" {
			t.Errorf("%s: SEC-16 = %v", root, c)
		}
	}
}

// T10-T14 and T16: station checks read the bog (ZIP or plaintext) and decide.
func TestStationChecks(t *testing.T) {
	fx := fixtures(t)
	tests := []struct {
		name, bog, id, want string
	}{
		{"T10 exec on", "bog-exec-on.zip", "SEC-08", "FAIL"},
		{"T11 exec off", "bog-exec-off.zip", "SEC-08", "PASS"},
		{"T12 syslog on", "bog-syslog-on.zip", "SEC-10", "PASS"},
		{"syslog off", "bog-syslog-off.zip", "SEC-10", "FAIL"},
		{"T13 external key source", "bog-ext-key.zip", "SEC-12", "PASS"},
		{"T14 no key source", "bog-no-key.zip", "SEC-12", "FAIL"},
		{"T16 plaintext exec on", "bog-plaintext.xml", "SEC-08", "FAIL"},
		{"plaintext syslog off", "bog-plaintext.xml", "SEC-10", "FAIL"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			a := runAudit(t, fx.secure, "--station", fx.bog[tt.bog])
			wantVerdicts(t, a, map[string]string{tt.id: tt.want})
		})
	}
	a := runAudit(t, fx.secure, "--station", fx.bog["bog-exec-on.zip"])
	if got := a.check(t, "SEC-08")["observed"]; got != "true" {
		t.Errorf("SEC-08 observed = %q", got)
	}
	a = runAudit(t, fx.secure, "--station", fx.bog["bog-ext-key.zip"])
	if got := a.check(t, "SEC-12")["observed"]; got != "external/encoded" {
		t.Errorf("SEC-12 observed = %q", got)
	}
}

// Without --station the three station checks are MANUAL with the "not provided" text.
func TestStationChecksAreManualWithoutAStation(t *testing.T) {
	a := runAudit(t, fixtures(t).secure)
	for _, id := range []string{"SEC-08", "SEC-10", "SEC-12"} {
		c := a.check(t, id)
		if c["verdict"] != "MANUAL" || c["observed"] != notProvided || c["note"] != "pass --station <config.bog> to enable this check" {
			t.Errorf("%s = %v", id, c)
		}
	}
}

// T15: a binary station file is MANUAL with its own reason, never a false PASS or FAIL.
func TestBinaryStationIsManualNotAVerdict(t *testing.T) {
	a := runAudit(t, fixtures(t).secure, "--station", fixtures(t).bog["bog-binary.dat"])
	for _, id := range []string{"SEC-08", "SEC-10", "SEC-12"} {
		c := a.check(t, id)
		if c["verdict"] != "MANUAL" || c["observed"] != "not checked (station file format unrecognized: not a ZIP bog or plaintext)" {
			t.Errorf("%s = %v", id, c)
		}
	}
}

// T17: no security/licenses/ is NA, not PASS.
func TestSec06AbsentLicenseDirIsNA(t *testing.T) {
	a := runAudit(t, fixtures(t).insecure)
	c := a.check(t, "SEC-06")
	if c["verdict"] != "NA" || c["observed"] != "security/licenses/ absent, unreadable, or outside install root" || c["note"] != "" {
		t.Errorf("SEC-06 = %v", c)
	}
}

// T18: a station that was given but is missing reads differently from one that was never given.
func TestMissingStationIsDistinctFromNoStation(t *testing.T) {
	root := fixtures(t).secure
	a := runAudit(t, root, "--station", filepath.Join(t.TempDir(), "nonexistent-config.bog"))
	for _, id := range []string{"SEC-08", "SEC-10", "SEC-12"} {
		c := a.check(t, id)
		if c["verdict"] != "MANUAL" || c["observed"] != "not checked (station file not found or not a regular file)" {
			t.Errorf("%s = %v", id, c)
		}
	}
	// the other ways a station is "not found": a directory, a symlink, an empty path
	dir := t.TempDir()
	real := filepath.Join(dir, "real.bog")
	saWrite(t, real, bogtest.Bog(`<c allowProgramRuntimeExec="true"/>`))
	link := filepath.Join(dir, "link.bog")
	if err := os.Symlink(real, link); err != nil {
		t.Fatal(err)
	}
	for _, st := range []string{dir, link, ""} {
		a := runAudit(t, root, "--station", st)
		if got := a.check(t, "SEC-08")["observed"]; got != "not checked (station file not found or not a regular file)" {
			t.Errorf("station %q: SEC-08 observed = %q", st, got)
		}
	}
}

// T20: a licenses directory that is a symlink out of the install root is not followed.
func TestSec06SymlinkEscapeIsNA(t *testing.T) {
	outside := filepath.Join(t.TempDir(), "outside-licenses")
	saWrite(t, filepath.Join(outside, "dev.license"), []byte(`<lic><prop name="smDeveloperMode" value="true"/></lic>`))
	home := filepath.Join(t.TempDir(), "escape-home")
	saMkdir(t, filepath.Join(home, "security"))
	if err := os.Symlink(outside, filepath.Join(home, "security", "licenses")); err != nil {
		t.Fatal(err)
	}
	a := runAudit(t, home)
	wantVerdicts(t, a, map[string]string{"SEC-06": "NA"})
}

// A symlink that stays inside the install root is followed.
func TestSec06SymlinkInsideTheRootIsFollowed(t *testing.T) {
	home := filepath.Join(t.TempDir(), "home")
	saWrite(t, filepath.Join(home, "elsewhere", "dev.license"), []byte(`<license smDeveloperMode="true"/>`))
	saMkdir(t, filepath.Join(home, "security"))
	if err := os.Symlink(filepath.Join(home, "elsewhere"), filepath.Join(home, "security", "licenses")); err != nil {
		t.Fatal(err)
	}
	wantVerdicts(t, runAudit(t, home), map[string]string{"SEC-06": "FAIL"})
}

// T21: an absent blacklist fails SEC-05.
func TestSec05AbsentBlacklistFails(t *testing.T) {
	a := runAudit(t, fixtures(t).insecure)
	c := a.check(t, "SEC-05")
	if c["verdict"] != "FAIL" || c["observed"] != "disabled/absent" {
		t.Errorf("SEC-05 = %v", c)
	}
}

func TestSec05PartialBlacklist(t *testing.T) {
	tests := []struct {
		value, verdict, observed string
	}{
		{"skipModuleValidation", "FAIL", "partial (missing skip levers)"},
		{"ignoreVerificationMode", "FAIL", "partial (missing skip levers)"},
		{"x,skipModuleValidation,ignoreVerificationMode", "PASS", "full"},
		{"", "FAIL", "disabled/absent"},
	}
	for _, tt := range tests {
		home := t.TempDir()
		saWrite(t, filepath.Join(home, "system.properties"), []byte("niagara.commandLinePropertyBlacklist="+tt.value+"\n"))
		c := runAudit(t, home).check(t, "SEC-05")
		if c["verdict"] != tt.verdict || c["observed"] != tt.observed {
			t.Errorf("blacklist %q: %v", tt.value, c)
		}
	}
	home := t.TempDir()
	saWrite(t, filepath.Join(home, "system.properties"), []byte("#niagara.commandLinePropertyBlacklist=skipModuleValidation,ignoreVerificationMode\n"))
	if c := runAudit(t, home).check(t, "SEC-05"); c["verdict"] != "FAIL" || c["observed"] != "disabled/absent" {
		t.Errorf("a commented blacklist counts as disabled: %v", c)
	}
}

// T22: a license that relaxes validation fails SEC-06, and the note names the file and attribute.
func TestSec06RelaxationLicenseFails(t *testing.T) {
	a := runAudit(t, fixtures(t).licHit)
	c := a.check(t, "SEC-06")
	if c["verdict"] != "FAIL" || c["observed"] != "1 relaxation attribute(s) found" || c["note"] != "dev.license:smDeveloperMode" {
		t.Errorf("SEC-06 = %v", c)
	}
	wantVerdicts(t, a, map[string]string{"SEC-01": "PASS"})
}

// The document keys, order and static text of one full run.
func TestDocumentShape(t *testing.T) {
	a := runAudit(t, fixtures(t).empty)
	ids := []string{}
	for _, c := range a.doc["checks"].([]any) {
		m := c.(map[string]any)
		ids = append(ids, m["id"].(string))
		if len(m) != 7 {
			t.Errorf("%s has %d keys, want 7 (id note observed secure severity title verdict)", m["id"], len(m))
		}
	}
	if got := strings.Join(ids, ","); got != "SEC-01,SEC-02,SEC-03,SEC-04,SEC-05,SEC-06,SEC-07,SEC-08,SEC-09,SEC-10,SEC-11,SEC-12,SEC-14,SEC-15,SEC-16" {
		t.Errorf("check order = %s", got)
	}
	if got := a.doc["install_root"].(string); !strings.HasSuffix(got, "/empty-home") {
		t.Errorf("install_root = %v", got)
	}
	lim := a.doc["limitations"].([]any)
	if len(lim) != 5 || lim[4] != "SEC-13 is not defined by the source corpus check set." {
		t.Errorf("limitations = %v", lim)
	}
	sum := a.doc["summary"].(map[string]any)
	if sum["checks_pass"].(float64)+sum["checks_fail"].(float64)+sum["checks_manual"].(float64)+sum["checks_na"].(float64) != sum["checks_run"].(float64) {
		t.Errorf("summary does not add up: %v", sum)
	}
}

func TestTrailingSlashesAreStrippedFromTheReportedRoot(t *testing.T) {
	fx := fixtures(t)
	a := runAudit(t, fx.empty+"//")
	if a.code != 0 || a.doc["install_root"] != fx.empty {
		t.Errorf("code %d install_root %v, want %s", a.code, a.doc["install_root"], fx.empty)
	}
}

// A failing walk is reported as status failed, errors set, no checks, exit 1, JSON still written.
func TestFailedWalkIsReportedNotLost(t *testing.T) {
	prev := auditChecks
	auditChecks = func(string, string, string, bool) []map[string]any { panic("walk exploded") }
	defer func() { auditChecks = prev }()
	a := runAudit(t, fixtures(t).secure)
	if a.code != 1 || a.doc["status"] != "failed" {
		t.Fatalf("code %d doc %v", a.code, a.doc)
	}
	if errs := a.doc["errors"].([]any); len(errs) != 1 || errs[0] != "walk exploded" {
		t.Errorf("errors = %v", errs)
	}
	sum := a.doc["summary"].(map[string]any)
	if sum["checks_run"].(float64) != 0 || len(a.doc["checks"].([]any)) != 0 {
		t.Errorf("a failed walk must carry no checks: %v", a.doc)
	}
}

// FIFOs in the tree must never hang the audit.
func TestSpecialFilesDoNotHang(t *testing.T) {
	home := t.TempDir()
	if err := syscall.Mkfifo(filepath.Join(home, "system.properties"), 0o600); err != nil {
		t.Fatal(err)
	}
	saMkdir(t, filepath.Join(home, "modules"))
	if err := syscall.Mkfifo(filepath.Join(home, "modules", "pipe.jar"), 0o600); err != nil {
		t.Fatal(err)
	}
	saMkdir(t, filepath.Join(home, "security", "licenses"))
	if err := syscall.Mkfifo(filepath.Join(home, "security", "licenses", "pipe.license"), 0o600); err != nil {
		t.Fatal(err)
	}
	fifo := filepath.Join(home, "station.fifo")
	if err := syscall.Mkfifo(fifo, 0o600); err != nil {
		t.Fatal(err)
	}
	done := make(chan audit, 1)
	go func() { done <- runAudit(t, home, "--station", fifo) }()
	select {
	case a := <-done:
		if a.code != 0 {
			t.Errorf("exit %d stderr %q", a.code, a.stderr)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("the audit hung on a FIFO")
	}
}

// Names that are not valid UTF-8 cannot be carried by the shared encoder; they are replaced (declared divergence).
func TestNonUTF8LicenseNameIsReplacedNotLost(t *testing.T) {
	home := t.TempDir()
	saWrite(t, filepath.Join(home, "security", "licenses", "bad\xffname.license"), []byte(`smDeveloperMode="true"`))
	c := runAudit(t, home).check(t, "SEC-06")
	if c["verdict"] != "FAIL" || c["note"] != "bad�name.license:smDeveloperMode" {
		t.Errorf("SEC-06 = %v", c)
	}
}
