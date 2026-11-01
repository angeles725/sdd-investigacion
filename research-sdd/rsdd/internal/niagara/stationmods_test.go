package niagara

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/niagara/bog"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/niagara/bogtest"
)

// ---- fixtures: every station and install tree of the retired bash suite (tests/station-modules.test.sh), built
// in memory under t.TempDir() ----

// runSM executes station-modules in-process and returns its exit code and streams.
func runSM(args ...string) (code int, stdout, stderr string) {
	var out, errb bytes.Buffer
	s := cli.Stdio{
		In: strings.NewReader(""), Out: &out, Err: &errb,
		Env: func(string) string { return "" }, Clock: time.Now, Cwd: "/work",
	}
	code = RunStationModules(args, s)
	return code, out.String(), errb.String()
}

// smJar is a module JAR the way the retired suite's make_jar built it.
func smJar(moduleName, part string, types ...string) []byte {
	var sb strings.Builder
	sb.WriteString("<?xml version=\"1.0\"?>\n")
	fmt.Fprintf(&sb, "<module name=\"%s\" moduleName=\"%s\" runtimeProfile=\"rt\" vendor=\"Tridium\" vendorVersion=\"4.14.0\">\n", part, moduleName)
	for _, tn := range types {
		fmt.Fprintf(&sb, "  <type name=\"%s\"/>\n", tn)
	}
	sb.WriteString("</module>\n")
	return bogtest.Zip(bogtest.Entry{Name: "META-INF/module.xml", Data: []byte(sb.String())})
}

const (
	smStationXML = `<?xml version='1.0' encoding='UTF-8'?>
<bajaObjectGraph version='4.0'>
 <p n='Station' h='1' t='b:Station' m='b=baja d=testmodule'>
  <p n='Services' h='2' t='b:ServiceContainer'>
   <p n='TestService' h='3' t='d:TestService'/>
  </p>
 </p>
</bajaObjectGraph>`
	smEmptyXML = `<?xml version='1.0' encoding='UTF-8'?>
<bajaObjectGraph version='4.0'>
 <p n='Station' h='1' t='b:Station'>
 </p>
</bajaObjectGraph>`
	smTypeMismatchXML = `<?xml version='1.0' encoding='UTF-8'?>
<bajaObjectGraph version='4.0'>
 <p n='Station' h='1' t='b:Station' m='b=baja'>
  <p n='Test' h='2' t='b:UnknownType'/>
 </p>
</bajaObjectGraph>`
	smHyphenXML = `<?xml version='1.0' encoding='UTF-8'?>
<bajaObjectGraph version='4.0'>
 <p n='Station' h='1' m='b=baja honbac-util=honBACnetUtilities'>
  <p n='Station' h='2' t='b:Station'/>
  <p n='BACnet' h='3' t='honbac-util:BACnetNetwork'/>
 </p>
</bajaObjectGraph>`
)

type smFixtures struct {
	dir     string
	bog     map[string]string // name -> path
	install string            // baja-rt + nre-rt, no testmodule
	empty   string            // modules/ exists and is empty
}

func smWrite(t *testing.T, path string, data []byte) {
	t.Helper()
	saWrite(t, path, data)
}

func smFix(t *testing.T) smFixtures {
	t.Helper()
	dir := t.TempDir()
	fx := smFixtures{dir: dir, bog: map[string]string{}}
	bogs := map[string][]byte{
		"valid.bog":         bogtest.Bog(smStationXML),
		"plaintext.bog":     []byte(smStationXML),
		"empty_station.bog": bogtest.Bog(smEmptyXML),
		"binary.bog":        bytes.Repeat([]byte{0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x01}, 256),
		"corrupt.bog":       bogtest.CorruptDeflate(),
		"type_mismatch.bog": bogtest.Bog(smTypeMismatchXML),
		"hyphen_alias.bog":  bogtest.Bog(smHyphenXML),
	}
	for name, data := range bogs {
		p := filepath.Join(dir, "bogs", name)
		smWrite(t, p, data)
		fx.bog[name] = p
	}
	fx.install = filepath.Join(dir, "fake_install")
	smWrite(t, filepath.Join(fx.install, "modules", "baja-rt.jar"), smJar("baja", "baja-rt", "Station", "ServiceContainer"))
	smWrite(t, filepath.Join(fx.install, "modules", "nre-rt.jar"), smJar("nre", "nre-rt", "NetworkRuntime"))
	fx.empty = filepath.Join(dir, "empty_install")
	saMkdir(t, filepath.Join(fx.empty, "modules"))
	return fx
}

// smRun is one run and the JSON it wrote.
type smRun struct {
	code   int
	stdout string
	stderr string
	out    string
	doc    map[string]any
}

func runModules(t *testing.T, input, install string) smRun {
	t.Helper()
	r := smRun{out: filepath.Join(t.TempDir(), "out.json")}
	r.code, r.stdout, r.stderr = runSM("--input", input, "--install", install, "--output", r.out)
	raw, err := os.ReadFile(r.out)
	if err != nil {
		return r
	}
	if err := json.Unmarshal(raw, &r.doc); err != nil {
		t.Fatalf("output is not JSON: %v\n%s", err, raw)
	}
	return r
}

func (r smRun) obj(t *testing.T, path ...string) map[string]any {
	t.Helper()
	var cur any = r.doc
	for _, p := range path {
		m, ok := cur.(map[string]any)
		if !ok {
			t.Fatalf("%v: not an object at %q (doc %v)", path, p, r.doc)
		}
		cur = m[p]
	}
	m, ok := cur.(map[string]any)
	if !ok {
		t.Fatalf("%v: not an object: %v", path, cur)
	}
	return m
}

func (r smRun) strs(t *testing.T, v any) []string {
	t.Helper()
	items, ok := v.([]any)
	if !ok {
		t.Fatalf("not a list: %#v", v)
	}
	out := make([]string, len(items))
	for i, it := range items {
		out[i] = it.(string)
	}
	return out
}

func (r smRun) num(t *testing.T, key string) int {
	t.Helper()
	return int(r.obj(t, "summary")[key].(float64))
}

// T1: an absent bog is refused (exit 2) and writes nothing.
func TestSMAbsentBogExits2WithoutJSON(t *testing.T) {
	fx := smFix(t)
	missing := filepath.Join(fx.dir, "no-such.bog")
	r := runModules(t, missing, fx.install)
	if r.code != 2 || r.doc != nil || r.stdout != "" {
		t.Errorf("code=%d doc=%v stdout=%q", r.code, r.doc, r.stdout)
	}
	if want := "station-modules: " + missing + ": No such file or directory\n"; r.stderr != want {
		t.Errorf("stderr = %q, want %q", r.stderr, want)
	}
	if _, err := os.Stat(r.out); err == nil {
		t.Error("an output file was created")
	}
}

// T2: a symlink bog is refused (the open does not follow links).
func TestSMSymlinkBogRefused(t *testing.T) {
	fx := smFix(t)
	link := filepath.Join(fx.dir, "sym.bog")
	if err := os.Symlink(fx.bog["valid.bog"], link); err != nil {
		t.Fatal(err)
	}
	r := runModules(t, link, fx.install)
	if r.code != 2 || r.doc != nil {
		t.Errorf("code=%d doc=%v", r.code, r.doc)
	}
	if want := "station-modules: " + link + ": is a symbolic link (rejected)\n"; r.stderr != want {
		t.Errorf("stderr = %q, want %q", r.stderr, want)
	}
}

// T3: an absent install root is refused and writes nothing.
func TestSMAbsentInstallRootExits2(t *testing.T) {
	fx := smFix(t)
	missing := filepath.Join(fx.dir, "no_such_install")
	r := runModules(t, fx.bog["valid.bog"], missing)
	if r.code != 2 || r.doc != nil {
		t.Errorf("code=%d doc=%v", r.code, r.doc)
	}
	if want := fmt.Sprintf("station-modules: install root not found: '%s'\n", missing); r.stderr != want {
		t.Errorf("stderr = %q, want %q", r.stderr, want)
	}
}

// T4: a valid ZIP bog against an install missing one module: complete, the gap is reported, and the counts
// prove the instrument looked.
func TestSMValidBogReportsTheMissingModule(t *testing.T) {
	fx := smFix(t)
	r := runModules(t, fx.bog["valid.bog"], fx.install)
	if r.code != 0 || r.stderr != "" || r.stdout != "" {
		t.Fatalf("code=%d stderr=%q", r.code, r.stderr)
	}
	if r.doc["schema"] != "station-modules.v1" || r.doc["status"] != "complete" {
		t.Errorf("schema/status = %v/%v", r.doc["schema"], r.doc["status"])
	}
	if f := r.obj(t, "input")["format"]; f != "zip-xml" {
		t.Errorf("format = %v", f)
	}
	if r.num(t, "jars_scanned") != 2 || r.num(t, "jars_total") != 2 || r.num(t, "modules_referenced") != 2 || r.num(t, "missing_parts") != 1 {
		t.Errorf("summary = %v", r.obj(t, "summary"))
	}
	want := map[string]any{"testmodule-rt": "module testmodule not installed (type TestService referenced)"}
	if !reflect.DeepEqual(r.obj(t, "missing_parts"), want) {
		t.Errorf("missing_parts = %v, want %v", r.obj(t, "missing_parts"), want)
	}
	if r.doc["truncated"] != false || len(r.strs(t, r.doc["errors"])) != 0 {
		t.Errorf("truncated=%v errors=%v", r.doc["truncated"], r.doc["errors"])
	}
}

// T5: an installed module lists its parts and the types the station references.
func TestSMInstalledModuleListsItsPartsAndTypes(t *testing.T) {
	fx := smFix(t)
	r := runModules(t, fx.bog["valid.bog"], fx.install)
	baja := r.obj(t, "modules", "baja")
	if got := r.strs(t, baja["installed_parts"]); !reflect.DeepEqual(got, []string{"baja-rt"}) {
		t.Errorf("installed_parts = %v", got)
	}
	if got := r.strs(t, baja["types_referenced"]); !reflect.DeepEqual(got, []string{"ServiceContainer", "Station"}) {
		t.Errorf("types_referenced = %v", got)
	}
	if got := r.strs(t, baja["types_unresolved"]); len(got) != 0 {
		t.Errorf("types_unresolved = %v", got)
	}
	tm := r.obj(t, "modules", "testmodule")
	if got := r.strs(t, tm["installed_parts"]); len(got) != 0 {
		t.Errorf("testmodule installed_parts = %v", got)
	}
}

// T6: an empty station is complete with zero modules; the zeros are real (the install was scanned).
func TestSMEmptyStationIsCompleteAndProvesItLooked(t *testing.T) {
	fx := smFix(t)
	r := runModules(t, fx.bog["empty_station.bog"], fx.install)
	if r.code != 0 || r.doc["status"] != "complete" {
		t.Fatalf("code=%d status=%v", r.code, r.doc["status"])
	}
	if r.num(t, "modules_referenced") != 0 || r.num(t, "missing_parts") != 0 || r.num(t, "jars_scanned") != 2 {
		t.Errorf("summary = %v", r.obj(t, "summary"))
	}
}

// T7: a bare XML bog is read as plaintext.
func TestSMPlaintextBog(t *testing.T) {
	fx := smFix(t)
	r := runModules(t, fx.bog["plaintext.bog"], fx.install)
	if r.code != 0 || r.doc["status"] != "complete" || r.obj(t, "input")["format"] != "plaintext-xml" {
		t.Errorf("code=%d doc=%v", r.code, r.doc)
	}
	if r.num(t, "modules_referenced") != 2 {
		t.Errorf("summary = %v", r.obj(t, "summary"))
	}
}

// T8: a bog that is neither ZIP nor XML is a failed document (exit 1).
func TestSMBinaryBogIsAFailedDocument(t *testing.T) {
	fx := smFix(t)
	r := runModules(t, fx.bog["binary.bog"], fx.install)
	if r.code != 1 || r.doc["status"] != "failed" {
		t.Fatalf("code=%d doc=%v", r.code, r.doc)
	}
	if got := r.strs(t, r.doc["errors"]); !reflect.DeepEqual(got, []string{"content is neither a ZIP nor XML"}) {
		t.Errorf("errors = %v", got)
	}
	if f := r.obj(t, "input")["format"]; f != "unknown" {
		t.Errorf("format = %v", f)
	}
	if r.num(t, "jars_scanned") != 0 {
		t.Error("the install was scanned although the bog was unreadable")
	}
}

// T9: a ZIP whose file.xml inflates past 32 MiB fails with truncated true (bounded read).
func TestSMZipBombIsATruncatedFailure(t *testing.T) {
	fx := smFix(t)
	p := filepath.Join(fx.dir, "bomb.bog")
	smWrite(t, p, bogtest.Bomb(bog.MaxInflate))
	r := runModules(t, p, fx.install)
	if r.code != 1 || r.doc["status"] != "failed" || r.doc["truncated"] != true {
		t.Fatalf("code=%d doc=%v", r.code, r.doc)
	}
	want := fmt.Sprintf("bog XML exceeded inflate cap (%d bytes); file.xml was not parsed", bog.MaxInflate)
	if got := r.strs(t, r.doc["errors"]); !reflect.DeepEqual(got, []string{want}) {
		t.Errorf("errors = %v", got)
	}
	if f := r.obj(t, "input")["format"]; f != "zip-xml" {
		t.Errorf("format = %v", f)
	}
}

// T10: a corrupted deflate stream is a failed document with the reason, never a crash.
func TestSMCorruptDeflateIsAFailedDocument(t *testing.T) {
	fx := smFix(t)
	r := runModules(t, fx.bog["corrupt.bog"], fx.install)
	if r.code != 1 || r.doc["status"] != "failed" || r.stderr != "" {
		t.Fatalf("code=%d stderr=%q doc=%v", r.code, r.stderr, r.doc)
	}
	errs := r.strs(t, r.doc["errors"])
	if len(errs) != 1 || !strings.HasPrefix(errs[0], "ZIP entry read error: ") {
		t.Errorf("errors = %v", errs)
	}
}

// T11: an --output symlink is refused and its target is left alone (O_EXCL makes it EEXIST, not ELOOP).
func TestSMOutputSymlinkRefused(t *testing.T) {
	fx := smFix(t)
	victim := filepath.Join(fx.dir, "victim.txt")
	smWrite(t, victim, []byte("victim\n"))
	link := filepath.Join(fx.dir, "out.json")
	if err := os.Symlink(victim, link); err != nil {
		t.Fatal(err)
	}
	code, _, stderr := runSM("--input", fx.bog["valid.bog"], "--install", fx.install, "--output", link)
	if b, _ := os.ReadFile(victim); code != 2 || string(b) != "victim\n" {
		t.Errorf("code=%d victim=%q", code, b)
	}
	if want := "station-modules: output " + link + ": File exists\n"; stderr != want {
		t.Errorf("stderr = %q, want %q", stderr, want)
	}
}

// T12: an existing --output is refused, not overwritten.
func TestSMExistingOutputRefused(t *testing.T) {
	fx := smFix(t)
	out := filepath.Join(fx.dir, "out.json")
	smWrite(t, out, []byte("keep\n"))
	code, _, stderr := runSM("--input", fx.bog["valid.bog"], "--install", fx.install, "--output", out)
	if b, _ := os.ReadFile(out); code != 2 || string(b) != "keep\n" {
		t.Errorf("code=%d file=%q", code, b)
	}
	if want := "station-modules: output " + out + ": File exists\n"; stderr != want {
		t.Errorf("stderr = %q, want %q", stderr, want)
	}
}

// T13: a FIFO as the bog is refused without blocking.
func TestSMFifoBogRefusedWithoutHanging(t *testing.T) {
	fx := smFix(t)
	p := filepath.Join(fx.dir, "pipe.bog")
	if err := syscall.Mkfifo(p, 0o600); err != nil {
		t.Fatal(err)
	}
	done := make(chan smRun, 1)
	go func() { done <- runModules(t, p, fx.install) }()
	select {
	case r := <-done:
		if r.code != 2 || r.doc != nil {
			t.Errorf("code=%d doc=%v", r.code, r.doc)
		}
		if want := "station-modules: " + p + ": not a regular file (rejected)\n"; r.stderr != want {
			t.Errorf("stderr = %q, want %q", r.stderr, want)
		}
	case <-time.After(20 * time.Second):
		t.Fatal("a FIFO bog blocked the run")
	}
}

// T14: the input's digest and size are the file's own.
func TestSMInputMetadataIsTheFilesOwn(t *testing.T) {
	fx := smFix(t)
	for name, p := range fx.bog {
		raw, err := os.ReadFile(p)
		if err != nil {
			t.Fatal(err)
		}
		f, err := bog.ReadFile(p)
		if err != nil {
			t.Fatal(err)
		}
		r := runModules(t, p, fx.install)
		in := r.obj(t, "input")
		if in["sha256"] != f.SHA256 || int(in["size_bytes"].(float64)) != len(raw) {
			t.Errorf("%s: input = %v, want sha %s size %d", name, in, f.SHA256, len(raw))
		}
	}
}

// T15: an install without modules/ is an install error, never an "everything is missing" report.
func TestSMAbsentModulesDirIsAnInstallErrorNotAllMissing(t *testing.T) {
	fx := smFix(t)
	root := filepath.Join(fx.dir, "no_modules")
	saMkdir(t, root)
	r := runModules(t, fx.bog["valid.bog"], root)
	if r.code != 1 || r.doc["status"] != "failed" {
		t.Fatalf("code=%d doc=%v", r.code, r.doc)
	}
	want := fmt.Sprintf("modules/ directory not found in install root: '%s/modules'", root)
	if got := r.strs(t, r.doc["errors"]); !reflect.DeepEqual(got, []string{want}) {
		t.Errorf("errors = %v, want %q", got, want)
	}
	if len(r.obj(t, "missing_parts")) != 0 || len(r.obj(t, "modules")) != 0 || r.num(t, "jars_scanned") != 0 {
		t.Errorf("a false all-missing report: %v", r.doc)
	}
}

// T16: an unreadable modules/ is an install error as well.
func TestSMUnreadableModulesDirIsAnInstallError(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("running as root: chmod 000 does not stop the listing")
	}
	fx := smFix(t)
	root := filepath.Join(fx.dir, "unreadable")
	saMkdir(t, filepath.Join(root, "modules"))
	if err := os.Chmod(filepath.Join(root, "modules"), 0); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(filepath.Join(root, "modules"), 0o700) })
	r := runModules(t, fx.bog["valid.bog"], root)
	if r.code != 1 || r.doc["status"] != "failed" {
		t.Fatalf("code=%d doc=%v", r.code, r.doc)
	}
	want := fmt.Sprintf("modules/ directory unreadable: Permission denied: '%s/modules'", root)
	if got := r.strs(t, r.doc["errors"]); !reflect.DeepEqual(got, []string{want}) {
		t.Errorf("errors = %v, want %q", got, want)
	}
	if len(r.obj(t, "missing_parts")) != 0 {
		t.Error("a false all-missing report")
	}
}

// T17: a modules/ symlink that leaves the install root is an install error, and the outside JARs are not read.
func TestSMModulesSymlinkEscapeIsAnInstallError(t *testing.T) {
	fx := smFix(t)
	root := filepath.Join(fx.dir, "escape")
	saMkdir(t, root)
	if err := os.Symlink(filepath.Join(fx.install, "modules"), filepath.Join(root, "modules")); err != nil {
		t.Fatal(err)
	}
	r := runModules(t, fx.bog["valid.bog"], root)
	if r.code != 1 || r.doc["status"] != "failed" {
		t.Fatalf("code=%d doc=%v", r.code, r.doc)
	}
	want := fmt.Sprintf("modules/ dir resolves outside install root (symlink escape): '%s/modules'", root)
	if got := r.strs(t, r.doc["errors"]); !reflect.DeepEqual(got, []string{want}) {
		t.Errorf("errors = %v, want %q", got, want)
	}
	if r.num(t, "jars_scanned") != 0 || len(r.obj(t, "missing_parts")) != 0 {
		t.Errorf("the outside install was read: %v", r.doc)
	}
}

// T18: a module that is installed but lacks a referenced type is not a missing part: the type is unresolved.
func TestSMInstalledModuleWithAnUnresolvedTypeIsNotMissing(t *testing.T) {
	fx := smFix(t)
	r := runModules(t, fx.bog["type_mismatch.bog"], fx.install)
	if r.code != 0 || r.doc["status"] != "complete" {
		t.Fatalf("code=%d doc=%v", r.code, r.doc)
	}
	if len(r.obj(t, "missing_parts")) != 0 || r.num(t, "types_unresolved") != 1 {
		t.Errorf("missing=%v summary=%v", r.obj(t, "missing_parts"), r.obj(t, "summary"))
	}
	baja := r.obj(t, "modules", "baja")
	if got := r.strs(t, baja["types_unresolved"]); !reflect.DeepEqual(got, []string{"UnknownType"}) {
		t.Errorf("types_unresolved = %v", got)
	}
	if got := r.strs(t, baja["installed_parts"]); !reflect.DeepEqual(got, []string{"baja-rt"}) {
		t.Errorf("installed_parts = %v", got)
	}
}

// T19: an alias with a hyphen resolves, and the module it names is tracked.
func TestSMHyphenatedAliasIsResolved(t *testing.T) {
	fx := smFix(t)
	r := runModules(t, fx.bog["hyphen_alias.bog"], fx.install)
	if r.code != 0 {
		t.Fatalf("code=%d doc=%v", r.code, r.doc)
	}
	m := r.obj(t, "modules", "honBACnetUtilities")
	if got := r.strs(t, m["types_referenced"]); !reflect.DeepEqual(got, []string{"BACnetNetwork"}) {
		t.Errorf("types_referenced = %v", got)
	}
	if r.num(t, "unresolved_aliases") != 0 {
		t.Errorf("unresolved_aliases = %d", r.num(t, "unresolved_aliases"))
	}
	if _, ok := r.obj(t, "missing_parts")["honBACnetUtilities-rt"]; !ok {
		t.Errorf("missing_parts = %v", r.obj(t, "missing_parts"))
	}
}

// T20: a plaintext bog over the 32 MiB read cap fails with truncated true, but exactly at the cap it is read.
func TestSMPlaintextOverTheCapIsATruncatedFailure(t *testing.T) {
	fx := smFix(t)
	at := filepath.Join(fx.dir, "at-cap.xml")
	over := filepath.Join(fx.dir, "over-cap.xml")
	body := "<a>" + strings.Repeat("x", bog.MaxInflate-3)
	smWrite(t, at, []byte(body))
	smWrite(t, over, []byte(body+"x"))

	r := runModules(t, over, fx.install)
	if r.code != 1 || r.doc["status"] != "failed" || r.doc["truncated"] != true {
		t.Fatalf("over: code=%d doc=%v", r.code, r.doc)
	}
	want := fmt.Sprintf("plaintext bog exceeded read cap (%d bytes); file was not parsed", bog.MaxInflate)
	if got := r.strs(t, r.doc["errors"]); !reflect.DeepEqual(got, []string{want}) {
		t.Errorf("errors = %v", got)
	}
	if f := r.obj(t, "input")["format"]; f != "unknown" {
		t.Errorf("format = %v", f)
	}
	if in := r.obj(t, "input"); int(in["size_bytes"].(float64)) != bog.MaxInflate+1 {
		t.Errorf("size_bytes = %v: the digest and size must cover the whole file", in["size_bytes"])
	}

	r = runModules(t, at, fx.install)
	if r.code != 0 || r.doc["status"] != "complete" || r.doc["truncated"] != false {
		t.Errorf("at the cap: code=%d doc=%v", r.code, r.doc)
	}
}

// ---- helpers shared with the edge tests ----

func sortedKeys(m map[string]any) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}
