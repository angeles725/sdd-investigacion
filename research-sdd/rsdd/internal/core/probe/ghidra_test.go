package probe

import "testing"

func TestPosixDirBase(t *testing.T) {
	for _, c := range []struct{ in, dir, base string }{
		{"/g/support/analyzeHeadless", "/g/support", "analyzeHeadless"},
		{"support/x", "support", "x"},
		{"support", ".", "support"},
		{"a/b/", "a", "b"},
		{"/a", "/", "a"},
		{"/", "/", "/"},
		{"//a//b//", "//a", "b"},
		{"", ".", ""},
	} {
		if d, b := posixDir(c.in), posixBase(c.in); d != c.dir || b != c.base {
			t.Errorf("%q: dir %q base %q, want %q %q", c.in, d, b, c.dir, c.base)
		}
	}
}

func TestFilevercmp(t *testing.T) {
	for _, c := range []struct {
		a, b string
		sign int
	}{
		{"/opt/ghidra_10.4", "/opt/ghidra_9.2", 1},
		{"/opt/ghidra_11.0.3_PUBLIC", "/opt/ghidra_11.0.10_PUBLIC", -1},
		{"/opt/ghidra_011", "/opt/ghidra_11", 0},
		{"/opt/ghidra~rc", "/opt/ghidra", -1},
		{"/opt/ghidraa", "/opt/ghidra_", -1},
		{"/opt/ghidra1", "/opt/ghidra", 1},
		{"/opt/ghidra.tar", "/opt/ghidra.zip", -1},
		{"/opt/ghidra1.tar", "/opt/ghidra2.a", -1},
		{"/opt/ghidra", "/opt/ghidra", 0},
	} {
		got := filevercmp(c.a, c.b)
		if (got > 0) != (c.sign > 0) || (got < 0) != (c.sign < 0) {
			t.Errorf("filevercmp(%q, %q) = %d, want sign %d", c.a, c.b, got, c.sign)
		}
	}
}

func TestGhidraHome(t *testing.T) {
	d := t.TempDir()
	ah := func(home string) string { return exe(t, d, home+"/support/analyzeHeadless", "") }
	ah("g1")
	ah("pathg")
	ah("brew/opt/ghidra/libexec")
	notSupport := exe(t, d, "bin/analyzeHeadless", "")
	ok := []struct {
		name string
		env  []string
		want string
	}{
		{"ANALYZE_HEADLESS wins", []string{"ANALYZE_HEADLESS=" + d + "/g1/support/analyzeHeadless", "GHIDRA_HOME=" + d + "/pathg"}, d + "/g1"},
		{"GHIDRA_HOME printed as given", []string{"GHIDRA_HOME=" + d + "/g1/", "GHIDRA_INSTALL_DIR=" + d + "/pathg"}, d + "/g1/"},
		{"GHIDRA_INSTALL_DIR", []string{"GHIDRA_INSTALL_DIR=" + d + "/pathg"}, d + "/pathg"},
		{"PATH analyzeHeadless under support", []string{"PATH=" + d + "/pathg/support", "RSDD_BREW_PREFIX=" + d + "/brew"}, d + "/pathg"},
		{"PATH hit outside support falls to brew", []string{"PATH=" + d + "/bin", "RSDD_BREW_PREFIX=" + d + "/brew"}, d + "/brew/opt/ghidra/libexec"},
	}
	for _, c := range ok {
		t.Run(c.name, func(t *testing.T) {
			got, err := prober(t.TempDir(), d, c.env...).GhidraHome()
			wantPath(t, got, err, c.want)
		})
	}
	over := []struct{ name, env, override string }{
		{"ANALYZE_HEADLESS outside support", "ANALYZE_HEADLESS=" + notSupport, "ANALYZE_HEADLESS"},
		{"ANALYZE_HEADLESS not executable", "ANALYZE_HEADLESS=" + put(t, d, "ne/support/analyzeHeadless", "", 0o644), "ANALYZE_HEADLESS"},
		{"empty GHIDRA_HOME", "GHIDRA_HOME=", "GHIDRA_HOME"},
		{"GHIDRA_HOME without launcher", "GHIDRA_HOME=" + d, "GHIDRA_HOME"},
	}
	for _, c := range over {
		t.Run(c.name, func(t *testing.T) {
			got, err := prober(t.TempDir(), d, c.env, "GHIDRA_INSTALL_DIR="+d+"/pathg").GhidraHome()
			wantDegraded(t, got, err, "ghidra", ErrOverrideUnusable)
		})
	}
	t.Run("/opt/ghidra* newest version first", func(t *testing.T) {
		root := t.TempDir()
		exe(t, root, "opt/ghidra_9.2/support/analyzeHeadless", "")
		exe(t, root, "opt/ghidra_10.4/support/analyzeHeadless", "")
		mkdir(t, root, "opt/ghidra_11.0") // newest, but no launcher
		got, err := prober(root, d, "PATH="+d+"/none").GhidraHome()
		wantPath(t, got, err, root+"/opt/ghidra_10.4")
	})
	got, err := prober(t.TempDir(), d, "PATH="+d+"/none").GhidraHome()
	wantDegraded(t, got, err, "ghidra", ErrNotFound)
}
