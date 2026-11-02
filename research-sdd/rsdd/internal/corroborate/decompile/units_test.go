package decompile

import (
	"os"
	"path/filepath"
	"regexp"
	"testing"
	"time"
)

func TestMarkerRegexp(t *testing.T) {
	vf := func(s string) string { return "    // $VF: " + s }
	for _, tt := range []struct {
		line string
		want bool
	}{
		// Failure texts, each alternative of the pattern.
		{vf("Couldn't be decompiled"), true},
		{"// $VF: Couldn't be decompiled", true},
		{"\t\t// $VF: Couldn't be decompiled", true},
		{vf("Could not decompile method"), true},
		{vf("Unable to decompile"), true},
		{vf("Failed to decompile"), true},
		{vf("Accidentally destroyed if statement, the decompiled code is not correct"), true},
		{vf("decompiled code is not correct"), true},
		{vf("Invalid label"), true},
		{vf("Made invalid labels"), true},
		{" * Unable to fully structure code", true},
		{"/* Unable to fully decompile class */", true},
		{"    // This method has failed to decompile.  When submitting a bug report", true},
		{"// This method could not be decompiled", true},
		{"/* Exception decompiling", true},
		{"/** Exception decompiling", true},
		{"// COULD NOT DECOMPILE", true},
		{" *   COULD NOT DECOMPILE", true},
		{"//$VF: Invalid label", true},
		{"//   $VF: Invalid label", true},
		{"/*** Unable to fully structure code", true},
		// Informational comments and look-alikes are not failures.
		{"    int x = 1; // $VF: just a trailing comment", false},
		{vf("synthetic class"), false},
		{vf("Extended synchronized range to monitorexit"), false},
		{vf("Could not verify finally blocks. A semaphore variable has been added."), false},
		{vf("Could not properly define all variable types!"), false},
		{vf("Could not handle exception ranges with multiple entries"), false},
		{vf("wow! decompiled code is not correct"), false},
		{`    String s = "// $VF: Couldn't be decompiled";`, false},
		{"$VF: Couldn't be decompiled", false},
		{"/// $VF: Invalid label", false},
		{"# $VF: Invalid label", false},
		{"*/ $VF: Invalid label", false},
		{"// something else: Invalid label", false},
		{"// $VF Invalid label", false},
		{"", false},
		{"    ", false},
	} {
		dir := t.TempDir()
		p := filepath.Join(dir, "X.java")
		os.WriteFile(p, []byte("class X {\n"+tt.line+"\n}"), 0o644)
		got := fileMarker(p) == markerFound
		if got != tt.want {
			t.Errorf("%q: marker = %v, want %v", tt.line, got, tt.want)
		}
	}
}

func TestFileMarker(t *testing.T) {
	dir := t.TempDir()
	write := func(name, body string) string {
		p := filepath.Join(dir, name)
		os.WriteFile(p, []byte(body), 0o644)
		return p
	}
	for _, tt := range []struct {
		name, body string
		want       int
	}{
		{"first line", "// $VF: Invalid label\nclass X {}\n", markerFound},
		{"last line without a newline", "class X {}\n// $VF: Invalid label", markerFound},
		{"CRLF", "class X {\r\n// $VF: Invalid label\r\n}", markerFound},
		{"single line", "// $VF: Invalid label", markerFound},
		{"none", "class X {}\n", markerNone},
		{"empty file", "", markerNone},
		{"a comment lead split from its text by a newline is not a marker", "//\n$VF: Invalid label\n", markerNone},
	} {
		if got := fileMarker(write(tt.name, tt.body)); got != tt.want {
			t.Errorf("%s: fileMarker = %d, want %d", tt.name, got, tt.want)
		}
	}
	if got := fileMarker(filepath.Join(dir, "missing")); got != markerError {
		t.Errorf("unreadable file: %d", got)
	}
}

func TestLayoutKey(t *testing.T) {
	for in, want := range map[string]string{
		"a/A":                                    "a/A",
		"BOOT-INF/classes/a/A":                   "a/A",
		"WEB-INF/classes/a/A":                    "a/A",
		"META-INF/versions/9/a/A":                "a/A",
		"META-INF/versions/17/a/A":               "a/A",
		"META-INF/versions/9":                    "META-INF/versions/9",
		"META-INF/MANIFEST":                      "META-INF/MANIFEST",
		"BOOT-INF/classes/META-INF/versions/9/A": "META-INF/versions/9/A",
		"x/BOOT-INF/classes/A":                   "x/BOOT-INF/classes/A",
		"BOOT-INF/lib/a/A":                       "BOOT-INF/lib/a/A",
		"":                                       "",
	} {
		if got := layoutKey(in); got != want {
			t.Errorf("layoutKey(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestIsUnitClass(t *testing.T) {
	dir := t.TempDir()
	names := []string{
		"Foo", "Foo$Bar", "Foo$Bar$Baz", "$Gson$Types", "$Gson$Types$X", "$Outer", "$Outer$Inner", "Z$", "Z$1",
		"Foo$$EnhancerByCGLIB$$ab", "Foo$$EnhancerByCGLIB$$ab$1", "Bar", "Bar$$FastClassBySpringCGLIB$$cd",
		"Baz", "Baz$$SpringCGLIB$$0", "Qux", "Qux$ByteBuddy$ef", "Zed", "Zed$$KeyFactoryByCGLIB$$ff",
		"Foo$$EnhancerByCGLIB$$", "Foo$ByteBuddy", "Baz$$SpringCGLIB$$x", "Baz$$SpringCGLIB$$", "Qux$ByteBuddy$", "Zed$KeyFactoryByCGLIB$$ff",
		"Orphan$$EnhancerByXYZ$$ab",
	}
	for _, n := range names {
		os.WriteFile(filepath.Join(dir, n+".class"), nil, 0o644)
	}
	os.MkdirAll(filepath.Join(dir, "Dir.class"), 0o755) // a directory is not a class beside which anything is inner
	os.WriteFile(filepath.Join(dir, "Dir$In.class"), nil, 0o644)
	for n, want := range map[string]bool{
		"Foo": true, "Foo$Bar": false, "Foo$Bar$Baz": false, "$Gson$Types": true, "$Gson$Types$X": false,
		"$Outer": true, "$Outer$Inner": false, "Z$": true, "Z$1": true,
		"Foo$$EnhancerByCGLIB$$ab": true, "Foo$$EnhancerByCGLIB$$ab$1": false,
		"Bar$$FastClassBySpringCGLIB$$cd": true, "Baz$$SpringCGLIB$$0": true, "Qux$ByteBuddy$ef": true,
		"Zed$$KeyFactoryByCGLIB$$ff": true,
		// Not generated names: inner of the class they extend.
		"Foo$$EnhancerByCGLIB$$": false, "Foo$ByteBuddy": false, "Baz$$SpringCGLIB$$x": false, "Baz$$SpringCGLIB$$": false,
		"Qux$ByteBuddy$": false, "Zed$KeyFactoryByCGLIB$$ff": false,
		"Orphan$$EnhancerByXYZ$$ab": true, // generated, though its base is not in the jar
		"Dir$In":                    true,
	} {
		if got := isUnitClass(filepath.Join(dir, n+".class")); got != want {
			t.Errorf("isUnitClass(%s) = %v, want %v", n, got, want)
		}
	}
}

func TestCopyTree(t *testing.T) {
	src, dst := t.TempDir(), t.TempDir()
	old := time.Date(2020, 1, 2, 3, 4, 5, 0, time.UTC)
	write := func(p, body string, mode os.FileMode, mt time.Time) {
		os.MkdirAll(filepath.Dir(p), 0o755)
		os.WriteFile(p, []byte(body), mode)
		os.Chmod(p, mode)
		os.Chtimes(p, mt, mt)
	}
	write(filepath.Join(src, "a/b/New.java"), "new", 0o664, old)
	write(filepath.Join(src, "a/Both.java"), "from src", 0o755, old)
	write(filepath.Join(src, "top.java"), "top", 0o644, old)
	write(filepath.Join(dst, "a/Both.java"), "from dst", 0o600, time.Now())
	write(filepath.Join(dst, "a/Keep.java"), "kept", 0o644, time.Now())
	os.Chmod(src, 0o750)
	os.Chmod(filepath.Join(src, "a/b"), 0o700)
	os.Chtimes(src, old.Add(3*time.Hour), old.Add(3*time.Hour))
	os.Chtimes(filepath.Join(src, "a/b"), old.Add(time.Hour), old.Add(time.Hour))
	os.Chtimes(filepath.Join(src, "a"), old.Add(2*time.Hour), old.Add(2*time.Hour))
	if err := copyTree(src, dst); err != nil {
		t.Fatal(err)
	}
	for p, want := range map[string]string{"a/b/New.java": "new", "a/Both.java": "from src", "top.java": "top", "a/Keep.java": "kept"} {
		if b, err := os.ReadFile(filepath.Join(dst, p)); err != nil || string(b) != want {
			t.Errorf("%s = %q, %v; want %q", p, b, err, want)
		}
	}
	for p, want := range map[string]struct {
		mode os.FileMode
		mt   time.Time
	}{
		"a/b/New.java": {0o664, old}, "a/Both.java": {0o755, old}, "top.java": {0o644, old},
		"a/b": {os.ModeDir | 0o700, old.Add(time.Hour)}, "a": {os.ModeDir | 0o755, old.Add(2 * time.Hour)}, ".": {os.ModeDir | 0o750, old.Add(3 * time.Hour)},
	} {
		fi, err := os.Stat(filepath.Join(dst, p))
		if err != nil || fi.Mode() != want.mode || !fi.ModTime().Equal(want.mt) {
			t.Errorf("%s: mode %v mtime %v (%v), want %v %v", p, fi.Mode(), fi.ModTime(), err, want.mode, want.mt)
		}
	}
	// Errors are returned, not swallowed.
	if err := copyTree(src, filepath.Join(dst, "top.java", "under-a-file")); err == nil {
		t.Error("copying below a regular file must fail")
	}
	if err := copyTree(filepath.Join(src, "missing"), dst); err == nil {
		t.Error("copying a missing directory must fail")
	}
	if err := copyFile(filepath.Join(src, "missing"), filepath.Join(dst, "x")); err == nil {
		t.Error("copying a missing file must fail")
	}
	if err := copyFile(filepath.Join(src, "top.java"), filepath.Join(dst, "no-dir", "x")); err == nil {
		t.Error("copying into a missing directory must fail")
	}
	if os.Geteuid() != 0 {
		os.Chmod(filepath.Join(src, "top.java"), 0)
		if err := copyFile(filepath.Join(src, "top.java"), filepath.Join(dst, "x")); err == nil {
			t.Error("copying an unreadable file must fail")
		}
	}
}

func TestHasJava(t *testing.T) {
	dir := t.TempDir()
	if hasJava(dir) {
		t.Error("an empty directory has no source")
	}
	os.MkdirAll(filepath.Join(dir, "a/b"), 0o755)
	os.WriteFile(filepath.Join(dir, "a/b/X.class"), nil, 0o644)
	os.MkdirAll(filepath.Join(dir, "d.java"), 0o755) // a directory is not a source file
	os.Symlink(filepath.Join(dir, "a/b/X.class"), filepath.Join(dir, "L.java"))
	if hasJava(dir) {
		t.Error("only a regular .java file counts")
	}
	os.WriteFile(filepath.Join(dir, "a/b/Y.java"), nil, 0o644)
	if !hasJava(dir) {
		t.Error("a nested .java file counts")
	}
	if hasJava(filepath.Join(dir, "missing")) {
		t.Error("a missing directory has no source")
	}
}

// TestCountResources: the failure path reports the non-class jar entries it did not copy.
func TestCountResources(t *testing.T) {
	for _, tt := range []struct {
		name    string
		listing *string
		rc      int
		want    string
	}{
		{"directories and classes are not resources", str("a/\na/A.class\nMETA-INF/MANIFEST.MF\nx.lexicon\n"), 0, "2"},
		{"nothing to copy", str("a/\na/A.class\n"), 0, "0"},
		{"an empty listing", str(""), 0, "0"},
		{"a class-looking directory", str("a.class/\n"), 0, "0"},
		{"unzip fails", str("a\nb\n"), 9, "unknown"},
		{"unzip warns", str("a\nb\n"), 1, "unknown"},
	} {
		t.Run(tt.name, func(t *testing.T) {
			w := newWorld(t)
			w.listing, w.listingRC = tt.listing, tt.rc
			w.env["STUB_FAIL_WHOLE"] = "1"
			stdout, _, _ := w.exec(w.input("r.jar", jarSpec{entries: []string{"a/A.class"}}), filepath.Join(w.root, "out"))
			got := "0"
			if m := regexp.MustCompile(`resources_not_copied=([^ )]+)`).FindStringSubmatch(stdout); m != nil {
				got = m[1]
			}
			if got != tt.want {
				t.Errorf("resources = %s, want %s\n%s", got, tt.want, stdout)
			}
		})
	}
}

func str(s string) *string { return &s }

// TestUnreadableMarkerScan: a fresh source the scan cannot read is typed, never silently passed.
func TestUnreadableMarkerScan(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root reads every file")
	}
	w := newWorld(t)
	w.hook = func(c Cmd) (Result, bool) {
		w.engine(c)
		os.Chmod(filepath.Join(c.Argv[len(c.Argv)-1], "Test.java"), 0)
		return Result{}, true
	}
	in, out := w.touch("Test.class"), filepath.Join(w.root, "out")
	stdout, _, rc := w.exec(in, out)
	want := "DEGRADED: IN -> OUT  (engine=vineflower units=1)\nUNIT: Test reason=marker-scan-error fallback=none result=kept-primary\n"
	if got := w.norm(stdout, in, out); rc != 4 || got != want {
		t.Errorf("rc %d:\n%s", rc, got)
	}
}
