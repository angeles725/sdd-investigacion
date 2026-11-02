package adapter

import (
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/fsx"
)

func TestDefaultHostIsTheFixedMountpoint(t *testing.T) {
	h := DefaultHost(7, "/w")
	if h.Root != "/tmp/rsdd" || h.UID != 7 || h.Cwd != "/w" {
		t.Fatalf("DefaultHost = %+v", h)
	}
}

func TestRefusePrivilegedExecutionMessage(t *testing.T) {
	for _, c := range []Creds{{0, 0, 0, 0}, {1, 0, 1, 1}, {1, 2, 1, 1}, {1, 1, 1, 2}} {
		var ae *Error
		if err := RefusePrivilegedExecution(c); !errors.As(err, &ae) || ae.Msg != "refusing root or set-id execution" {
			t.Errorf("%+v: %v", c, err)
		}
	}
	if err := RefusePrivilegedExecution(Creds{5, 5, 6, 6}); err != nil {
		t.Fatal(err)
	}
}

func TestSandboxExactArgv(t *testing.T) {
	root := filepath.Join(t.TempDir(), "rsdd")
	h := Host{Root: root, UID: os.Getuid(), Cwd: "/", Exists: func(p string) bool { return p != "/lib64" && p != "/usr/in" }}
	h2 := h
	h2.Exists = func(p string) bool { return p != "/lib64" }
	got, err := Sandbox(h2, "/b/bwrap", []EnvVar{{"B", "1"}, {"A", "2"}}, []string{"/usr/in"})
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"/b/bwrap", "--die-with-parent", "--new-session", "--unshare-net", "--unshare-pid", "--cap-drop", "ALL",
		"--ro-bind", "/usr", "/usr", "--ro-bind", "/bin", "/bin", "--ro-bind", "/sbin", "/sbin", "--ro-bind", "/lib", "/lib",
		"--ro-bind-try", "/etc/ld.so.cache", "/etc/ld.so.cache", "--ro-bind-try", "/etc/ld.so.conf", "/etc/ld.so.conf",
		"--ro-bind-try", "/etc/ld.so.conf.d", "/etc/ld.so.conf.d", "--ro-bind-try", "/etc/ssl/certs", "/etc/ssl/certs",
		"--ro-bind", "/usr/in", "/usr/in",
		"--proc", "/proc", "--dev", "/dev", "--tmpfs", "/tmp/rsdd",
		"--dir", "/tmp/rsdd/home", "--dir", "/tmp/rsdd/cache", "--dir", "/tmp/rsdd/config", "--dir", "/tmp/rsdd/data", "--dir", "/tmp/rsdd/work",
		"--ro-bind", ".", "/tmp/rsdd/work", "--setenv", "B", "1", "--setenv", "A", "2", "--chdir", "/tmp/rsdd/work", "--"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("argv\n got  %q\n want %q", got, want)
	}
	if _, err := Sandbox(h, "/b", nil, []string{"/usr/in"}); err == nil {
		t.Fatal("a declared input that does not exist must be refused")
	}
	if fi, err := os.Stat(root); err != nil || fi.Mode().Perm() != 0o700 {
		t.Fatalf("mount point not created 0700: %v %v", fi, err)
	}
}

func TestSandboxRefusesUnsafeMountpoint(t *testing.T) {
	base := t.TempDir()
	cases := map[string]func(string){
		"open-mode": func(r string) { _ = os.Mkdir(r, 0o700); _ = os.Chmod(r, 0o750) },
		"symlink":   func(r string) { _ = os.Mkdir(r+".d", 0o700); _ = os.Symlink(r+".d", r) },
	}
	for name, setup := range cases {
		r := filepath.Join(base, name)
		setup(r)
		_, err := Sandbox(Host{Root: r, UID: os.Getuid()}, "/b", nil, nil)
		var ae *Error
		if !errors.As(err, &ae) || ae.Msg != "unsafe Bubblewrap mountpoint" {
			t.Errorf("%s: %v", name, err)
		}
	}
	_, err := Sandbox(Host{Root: filepath.Join(base, "own"), UID: os.Getuid() + 1}, "/b", nil, nil)
	if err == nil || err.Error() != "unsafe Bubblewrap mountpoint" {
		t.Errorf("foreign owner: %v", err)
	}
}

func TestRequirePrivateKeepsTheTypedMessages(t *testing.T) {
	for mi, want := range map[string]string{
		"":                            "output path is under no known mount point",
		"1 0 8:1 / /m rw - 9p x rw\n": "output must reside on a Linux-private filesystem",
		"junk\n":                      "malformed mountinfo line (missing ' - ' separator): 'junk'",
		"1 0 8:1 - tmpfs\n":           "malformed mountinfo line (too few left fields): '1 0 8:1 - tmpfs'",
		"1 0 8:1 / /m rw - \n":        "malformed mountinfo line (empty right side): '1 0 8:1 / /m rw - '",
	} {
		if err := RequirePrivate("/m/x", mi); err == nil || err.Error() != want {
			t.Errorf("%q: %v, want %s", mi, err, want)
		}
	}
	if err := RequirePrivate("/m/x", "1 0 8:1 / /m rw - tmpfs t rw\n"); err != nil {
		t.Fatal(err)
	}
}

func TestExecutableWrapsIdentityFailuresWithTheirKind(t *testing.T) {
	if _, _, err := Executable(Host{}, "sh", nil, ""); err == nil || err.Error() != "PATH-selected sh is missing" {
		t.Fatalf("empty search: %v", err)
	}
	_ = fsx.ErrOpen
}
