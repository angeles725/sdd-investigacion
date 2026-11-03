package fsview

import (
	"os"
	"path/filepath"
	"testing"
)

func TestView(t *testing.T) {
	d := t.TempDir()
	if err := os.WriteFile(filepath.Join(d, "f"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(filepath.Join(d, "sub"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("f", filepath.Join(d, "ln")); err != nil {
		t.Fatal(err)
	}
	v := View{Cwd: d}
	if got := v.At("f"); got != d+"/f" {
		t.Errorf("At(f) = %q", got)
	}
	for _, p := range []string{"", "/abs"} {
		if got := v.At(p); got != p {
			t.Errorf("At(%q) = %q, want it unchanged", p, got)
		}
	}
	for _, c := range []struct {
		p                                string
		dir, file, link, readable, exist bool
	}{
		{"f", false, true, false, true, true},
		{"sub", true, false, false, true, true},
		{"ln", false, true, true, true, true},
		{"missing", false, false, false, false, false},
	} {
		if v.IsDir(c.p) != c.dir || v.IsFile(c.p) != c.file || v.IsSymlink(c.p) != c.link || v.Readable(c.p) != c.readable {
			t.Errorf("%s: dir=%v file=%v link=%v readable=%v, want %v %v %v %v", c.p,
				v.IsDir(c.p), v.IsFile(c.p), v.IsSymlink(c.p), v.Readable(c.p), c.dir, c.file, c.link, c.readable)
		}
		if _, err := v.Stat(c.p); (err == nil) != c.exist {
			t.Errorf("Stat(%s) err=%v, want exist=%v", c.p, err, c.exist)
		}
	}
	if b, err := v.Read("ln"); err != nil || string(b) != "x" {
		t.Errorf("Read(ln) = %q, %v", b, err)
	}
	if _, err := v.Read("missing"); err == nil {
		t.Error("Read(missing) must fail")
	}
}
