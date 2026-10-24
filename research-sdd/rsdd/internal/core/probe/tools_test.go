//go:build unix

package probe

import "testing"

func TestR2AndILSpy(t *testing.T) {
	d := t.TempDir()
	onPath := exe(t, d, "p/r2", "")
	exe(t, d, "p/ilspycmd", "")
	brewR2 := exe(t, d, "brew/opt/radare2/bin/r2", "")
	usr := exe(t, d, "usr/r2", "")
	dotnet := exe(t, d, "h/.dotnet/tools/ilspycmd", "")
	ok := []struct {
		name string
		res  func(*Prober) (string, error)
		env  []string
		want string
	}{
		{"R2 override", (*Prober).R2, []string{"R2=" + usr, "PATH=" + d + "/p"}, usr},
		{"r2 on PATH", (*Prober).R2, []string{"PATH=" + d + "/p", "RSDD_BREW_PREFIX=" + d + "/brew"}, onPath},
		{"r2 brew", (*Prober).R2, []string{"RSDD_BREW_PREFIX=" + d + "/brew", "RSDD_R2_USRBIN=" + usr}, brewR2},
		{"r2 usrbin knob", (*Prober).R2, []string{"RSDD_R2_USRBIN=" + usr}, usr},
		{"ILSPYCMD override", (*Prober).ILSpy, []string{"ILSPYCMD=" + dotnet, "PATH=" + d + "/p"}, dotnet},
		{"ilspycmd on PATH", (*Prober).ILSpy, []string{"PATH=" + d + "/p", "HOME=" + d + "/h"}, d + "/p/ilspycmd"},
		{"ilspycmd dotnet tools", (*Prober).ILSpy, []string{"HOME=" + d + "/h"}, dotnet},
	}
	for _, c := range ok {
		t.Run(c.name, func(t *testing.T) {
			got, err := c.res(prober(t.TempDir(), d, c.env...))
			wantPath(t, got, err, c.want)
		})
	}
	t.Run("default /usr/bin/r2", func(t *testing.T) {
		root := t.TempDir()
		got, err := prober(root, d, "RSDD_R2_USRBIN=").R2()
		wantDegraded(t, got, err, "r2", ErrNotFound)
		r2 := exe(t, root, "usr/bin/r2", "")
		got, err = prober(root, d, "RSDD_R2_USRBIN=").R2()
		wantPath(t, got, err, r2)
	})
	got, err := prober(t.TempDir(), d, "R2=", "PATH="+d+"/p").R2()
	wantDegraded(t, got, err, "r2", ErrOverrideUnusable)
	got, err = prober(t.TempDir(), d, "ILSPYCMD="+put(t, d, "ne/ilspycmd", "", 0o644), "PATH="+d+"/p").ILSpy()
	wantDegraded(t, got, err, "ilspycmd", ErrOverrideUnusable)
	got, err = prober(t.TempDir(), d, "HOME="+d+"/none").ILSpy()
	wantDegraded(t, got, err, "ilspycmd", ErrNotFound)
}

func TestSystemPkgConfigPath(t *testing.T) {
	root := t.TempDir()
	if got, ok := prober(root, "/", "RSDD_SYSTEM_PKGCONFIG_PATH=/x:/y").SystemPkgConfigPath(); !ok || got != "/x:/y" {
		t.Fatalf("knob: %q %v", got, ok)
	}
	if got, ok := prober(root, "/").SystemPkgConfigPath(); ok || got != "" {
		t.Fatalf("none: %q %v", got, ok)
	}
	mkdir(t, root, "usr/lib/x86_64-linux-gnu/pkgconfig")
	mkdir(t, root, "usr/lib/aarch64-linux-gnu/pkgconfig")
	mkdir(t, root, "usr/lib/i386-linux-gnu") // no pkgconfig
	put(t, root, "usr/lib/pkgconfig", "", 0o644)
	mkdir(t, root, "usr/share/pkgconfig")
	want := root + "/usr/lib/aarch64-linux-gnu/pkgconfig:" + root + "/usr/lib/x86_64-linux-gnu/pkgconfig:" + root + "/usr/share/pkgconfig"
	if got, ok := prober(root, "/", "RSDD_SYSTEM_PKGCONFIG_PATH=").SystemPkgConfigPath(); !ok || got != want {
		t.Fatalf("got %q %v\nwant %q", got, ok, want)
	}
}
