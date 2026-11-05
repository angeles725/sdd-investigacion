package place

import (
	"bytes"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/srcregistry"
)

type fx struct {
	p    *Placer
	err  bytes.Buffer
	sdir string
	sub  string
}

func newFx(t *testing.T, replace bool) *fx {
	x := &fx{sdir: filepath.Join(t.TempDir(), "sources")}
	x.sub = x.sdir + "/datasheets"
	if err := os.MkdirAll(x.sub, 0o755); err != nil {
		t.Fatal(err)
	}
	x.p = &Placer{SDir: x.sdir, Replace: replace, Err: &x.err}
	return x
}

func write(t *testing.T, path, body string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

func read(t *testing.T, path string) string {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func register(t *testing.T, x *fx, rel, sha string) {
	t.Helper()
	if err := srcregistry.Append(x.sdir, srcregistry.FormatRow(rel, "datasheets", "http://o", "2026-01-01T00:00:00Z", sha)); err != nil {
		t.Fatal(err)
	}
}

func TestPreflightRefusals(t *testing.T) {
	x := newFx(t, false)
	free := x.sub + "/free.pdf"
	if code := x.p.Preflight(free); code != 0 || x.err.Len() != 0 {
		t.Errorf("free destination: %d %q", code, x.err.String())
	}
	taken := x.sub + "/taken.pdf"
	write(t, taken, "old")
	if code := x.p.Preflight(taken); code != ExitExists || !strings.Contains(x.err.String(), "REFUSED: destination already exists: "+taken) || !strings.HasSuffix(x.err.String(), "nothing fetched\n") {
		t.Errorf("existing: %d %q", code, x.err.String())
	}
	x.err.Reset()
	link := x.sub + "/link.pdf"
	if err := os.Symlink(taken, link); err != nil {
		t.Fatal(err)
	}
	if code := x.p.Preflight(link); code != ExitSymlink || !strings.Contains(x.err.String(), "REFUSED: destination is a symlink: "+link) {
		t.Errorf("symlink: %d %q", code, x.err.String())
	}
	dangling := x.sub + "/dangling.pdf"
	if err := os.Symlink(x.sub+"/nowhere", dangling); err != nil {
		t.Fatal(err)
	}
	if code := x.p.Preflight(dangling); code != ExitSymlink {
		t.Errorf("a dangling symlink is still a symlink: %d", code)
	}
}

func TestPreflightWithReplaceAllowsAnExistingFileButNotASymlink(t *testing.T) {
	x := newFx(t, true)
	taken := x.sub + "/taken.pdf"
	write(t, taken, "old")
	if code := x.p.Preflight(taken); code != 0 {
		t.Errorf("--replace over a file: %d", code)
	}
	link := x.sub + "/l.pdf"
	if err := os.Symlink(taken, link); err != nil {
		t.Fatal(err)
	}
	if code := x.p.Preflight(link); code != ExitSymlink {
		t.Errorf("--replace never writes through a link: %d", code)
	}
}

func TestInstallIsExclusiveWithoutReplace(t *testing.T) {
	x := newFx(t, false)
	dest := x.sub + "/a.pdf"
	part := dest + ".fetchdoc-part.1"
	write(t, part, "NEW")
	if same, code := x.p.Install(part, dest); same || code != 0 || read(t, dest) != "NEW" {
		t.Fatalf("%v %d", same, code)
	}
	if _, err := os.Stat(part); err == nil {
		t.Error("part left behind")
	}
	write(t, part, "NEWER")
	hooked := false
	x.p.Hook = func(string) { hooked = true }
	if same, code := x.p.Install(part, dest); same || code != ExitExists || read(t, dest) != "NEW" || !hooked {
		t.Errorf("a file that appeared during the download must not be overwritten: %v %d %q", same, code, read(t, dest))
	}
	if !strings.Contains(x.err.String(), "REFUSED: destination appeared during the download: "+dest) {
		t.Errorf("%q", x.err.String())
	}
}

func TestInstallHookRunsFirstAndCanRaceTheDestination(t *testing.T) {
	x := newFx(t, false)
	dest := x.sub + "/a.pdf"
	part := dest + ".fetchdoc-part.1"
	write(t, part, "MINE")
	var point string
	x.p.Hook = func(pt string) { point = pt; write(t, dest, "OTHER-RUN") }
	if _, code := x.p.Install(part, dest); code != ExitExists || read(t, dest) != "OTHER-RUN" || point != "install" {
		t.Errorf("code %d dest %q point %q", code, read(t, dest), point)
	}
}

func TestInstallRefusesASymlinkThatAppearedDuringTheDownload(t *testing.T) {
	for _, replace := range []bool{false, true} {
		x := newFx(t, replace)
		dest := x.sub + "/a.pdf"
		part := dest + ".p"
		write(t, part, "MINE")
		target := filepath.Join(filepath.Dir(x.sdir), "elsewhere")
		x.p.Hook = func(string) { _ = os.Symlink(target, dest) }
		if _, code := x.p.Install(part, dest); code != ExitSymlink || !strings.Contains(x.err.String(), "destination became a symlink during the download") {
			t.Errorf("replace=%v: %d %q", replace, code, x.err.String())
		}
		if _, err := os.Stat(target); err == nil {
			t.Error("the install wrote THROUGH the link")
		}
	}
}

func TestReplaceKeepsOldBytesUnderAVersionedNameAndRetargetsTheRow(t *testing.T) {
	x := newFx(t, true)
	dest := x.sub + "/ds.pdf"
	write(t, dest, "OLD")
	oldSHA := srcregistry.SHA256Hex([]byte("OLD"))
	register(t, x, "datasheets/ds.pdf", oldSHA)
	part := dest + ".fetchdoc-part.9"
	write(t, part, "NEW")
	same, code := x.p.Install(part, dest)
	if same || code != 0 {
		t.Fatalf("%v %d %q", same, code, x.err.String())
	}
	v := x.sub + "/ds." + oldSHA[:12] + ".pdf"
	if read(t, dest) != "NEW" || read(t, v) != "OLD" {
		t.Errorf("dest %q versioned %q", read(t, dest), read(t, v))
	}
	md := read(t, x.sdir+"/SOURCES.md")
	if !strings.Contains(md, "| datasheets/ds."+oldSHA[:12]+".pdf | datasheets |") || strings.Contains(md, "| datasheets/ds.pdf |") {
		t.Errorf("row not retargeted:\n%s", md)
	}
	if want := "fetch-doc: replaced " + dest + "; old bytes kept as ds." + oldSHA[:12] + ".pdf\n"; x.err.String() != want {
		t.Errorf("%q", x.err.String())
	}
}

func TestReplaceWithoutExtensionAndWithHiddenName(t *testing.T) {
	for _, c := range []struct{ base, want string }{{"README", "README.%s"}, {"a.tar.gz", "a.tar.%s.gz"}, {".env", ".%s.env"}} {
		got := versionedName(c.base, strings.Repeat("ab", 32))
		if want := strings.Replace(c.want, "%s", "abababababab", 1); got != want {
			t.Errorf("%s: got %q want %q", c.base, got, want)
		}
	}
}

func TestReplaceIdenticalBytesAlreadyRegisteredAddsNothing(t *testing.T) {
	x := newFx(t, true)
	dest := x.sub + "/ds.pdf"
	write(t, dest, "SAME")
	register(t, x, "datasheets/ds.pdf", srcregistry.SHA256Hex([]byte("SAME")))
	part := dest + ".fetchdoc-part.9"
	write(t, part, "SAME")
	same, code := x.p.Install(part, dest)
	if !same || code != 0 {
		t.Fatalf("%v %d", same, code)
	}
	if _, err := os.Stat(part); err == nil {
		t.Error("part left behind")
	}
	if want := "fetch-doc: identical bytes already registered for datasheets/ds.pdf; nothing replaced, no new row\n"; x.err.String() != want {
		t.Errorf("%q", x.err.String())
	}
}

func TestReplaceIdenticalBytesWithoutARowStillInstalls(t *testing.T) {
	x := newFx(t, true)
	dest := x.sub + "/ds.pdf"
	write(t, dest, "SAME")
	part := dest + ".fetchdoc-part.9"
	write(t, part, "SAME")
	if same, code := x.p.Install(part, dest); same || code != 0 || read(t, dest) != "SAME" {
		t.Errorf("an unregistered file must get its row: %v %d", same, code)
	}
}

func TestReplaceRefusesAVersionedNameHoldingDifferentBytes(t *testing.T) {
	x := newFx(t, true)
	dest := x.sub + "/ds.pdf"
	write(t, dest, "OLD")
	oldSHA := srcregistry.SHA256Hex([]byte("OLD"))
	v := x.sub + "/ds." + oldSHA[:12] + ".pdf"
	write(t, v, "SOMETHING-ELSE")
	part := dest + ".fetchdoc-part.9"
	write(t, part, "NEW")
	if _, code := x.p.Install(part, dest); code != 1 || read(t, dest) != "OLD" || read(t, v) != "SOMETHING-ELSE" {
		t.Errorf("code %d dest %q v %q", code, read(t, dest), read(t, v))
	}
	if !strings.Contains(x.err.String(), "REFUSED: versioned name already holds DIFFERENT bytes: "+v+" — the current bytes are kept") {
		t.Errorf("%q", x.err.String())
	}
}

func TestReplaceReusesAnAlreadyArchivedVersion(t *testing.T) {
	x := newFx(t, true)
	dest := x.sub + "/ds.pdf"
	write(t, dest, "OLD")
	oldSHA := srcregistry.SHA256Hex([]byte("OLD"))
	v := x.sub + "/ds." + oldSHA[:12] + ".pdf"
	write(t, v, "OLD") // A->B->A->B: the bytes are already archived there
	part := dest + ".fetchdoc-part.9"
	write(t, part, "NEW")
	if _, code := x.p.Install(part, dest); code != 0 || read(t, dest) != "NEW" || read(t, v) != "OLD" {
		t.Errorf("code %d dest %q v %q err %q", code, read(t, dest), read(t, v), x.err.String())
	}
}

func TestReplaceRefusesAVersionedNameThatIsASymlink(t *testing.T) {
	x := newFx(t, true)
	dest := x.sub + "/ds.pdf"
	write(t, dest, "OLD")
	oldSHA := srcregistry.SHA256Hex([]byte("OLD"))
	v := x.sub + "/ds." + oldSHA[:12] + ".pdf"
	if err := os.Symlink(x.sub+"/nowhere", v); err != nil {
		t.Fatal(err)
	}
	part := dest + ".fetchdoc-part.9"
	write(t, part, "NEW")
	if _, code := x.p.Install(part, dest); code != 1 || read(t, dest) != "OLD" || !strings.Contains(x.err.String(), "REFUSED: versioned name is a symlink: "+v) {
		t.Errorf("code %d %q", code, x.err.String())
	}
}

func TestReplaceWarnsAboutRowsWithAnotherShaAndLeavesThem(t *testing.T) {
	x := newFx(t, true)
	dest := x.sub + "/ds.pdf"
	write(t, dest, "OLD")
	oldSHA := srcregistry.SHA256Hex([]byte("OLD"))
	register(t, x, "datasheets/ds.pdf", oldSHA)
	register(t, x, "datasheets/ds.pdf", "legacy-sha")
	part := dest + ".fetchdoc-part.9"
	write(t, part, "NEW")
	if _, code := x.p.Install(part, dest); code != 0 {
		t.Fatal(code)
	}
	if !strings.Contains(x.err.String(), "fetch-doc: WARNING: 1 other row(s) for datasheets/ds.pdf carry a different sha256 than the archived bytes and were left untouched\n") {
		t.Errorf("%q", x.err.String())
	}
	if !strings.Contains(read(t, x.sdir+"/SOURCES.md"), "| datasheets/ds.pdf | datasheets | http://o | 2026-01-01T00:00:00Z | legacy-sha |") {
		t.Error("the other row was touched")
	}
}

func TestSweepStaleRemovesOnlyDeadUnregisteredParts(t *testing.T) {
	x := newFx(t, false)
	dead := x.sub + "/a.pdf.fetchdoc-part.111"
	live := x.sub + "/b.pdf.fetchdoc-part.222"
	registered := x.sub + "/spec.fetchdoc-part.333" // a document legitimately named like a part file
	plain := x.sub + "/c.part.444"
	hidden := x.sub + "/.d.fetchdoc-part.555"
	nonNum := x.sub + "/e.fetchdoc-part.12x"
	for _, f := range []string{dead, live, registered, plain, hidden, nonNum} {
		write(t, f, "x")
	}
	register(t, x, "datasheets/spec.fetchdoc-part.333", "sha")
	x.p.SweepStale(x.sub, func(pid string) bool { return pid == "222" })
	for f, want := range map[string]bool{dead: false, live: true, registered: true, plain: true, hidden: true, nonNum: true} {
		if _, err := os.Stat(f); (err == nil) != want {
			t.Errorf("%s exists=%v want %v", filepath.Base(f), err == nil, want)
		}
	}
	if want := "fetch-doc: removed stale part file from dead pid 111: a.pdf.fetchdoc-part.111\n"; x.err.String() != want {
		t.Errorf("%q", x.err.String())
	}
}

func TestSweepStaleOnAMissingDirectoryIsQuiet(t *testing.T) {
	x := newFx(t, false)
	x.p.SweepStale(x.sub+"/none", nil)
	if x.err.Len() != 0 {
		t.Errorf("%q", x.err.String())
	}
}

func TestAliveUsesProc(t *testing.T) {
	if !Alive(strconv.Itoa(os.Getpid())) {
		t.Error("this process is alive")
	}
	if Alive("2147483646") {
		t.Error("an unused pid is dead")
	}
}
