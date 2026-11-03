//go:build unix

package ghidra

import (
	"errors"
	"io/fs"
	"os"
	"reflect"
	"syscall"
	"testing"
	"time"
)

// fakeInfo is a stat result whose owner and mode the test chooses.
type fakeInfo struct {
	mode fs.FileMode
	uid  int
}

func (f fakeInfo) Name() string       { return "x" }
func (f fakeInfo) Size() int64        { return 0 }
func (f fakeInfo) Mode() fs.FileMode  { return f.mode }
func (f fakeInfo) ModTime() time.Time { return time.Time{} }
func (f fakeInfo) IsDir() bool        { return f.mode.IsDir() }
func (f fakeInfo) Sys() any           { return nil }

// trustRig is one scenario for checkBwrapTrust: a fake filesystem of directories keyed by path.
type trustRig struct {
	t         *testing.T
	selected  bool
	same      bool
	sameErr   error
	dirs      map[string]fakeInfo
	statErrAt string
	visited   []string
}

func newRig(t *testing.T) *trustRig {
	return &trustRig{t: t, selected: true, same: true, dirs: map[string]fakeInfo{}}
}

// root registers root-owned 0755 directories.
func (r *trustRig) root(dirs ...string) {
	for _, d := range dirs {
		r.dirs[d] = fakeInfo{mode: fs.ModeDir | 0o755, uid: 0}
	}
}

func (r *trustRig) check(fi fakeInfo, resolved string) error {
	r.t.Helper()
	old := bwrapTrustOps
	r.t.Cleanup(func() { bwrapTrustOps = old })
	bwrapTrustOps = trustOps{
		selected:     func() (string, bool) { return "/usr/bin/bwrap", r.selected },
		evalSymlinks: func(p string) (string, error) { return p, nil },
		sameFile:     func(a, b string) (bool, error) { return r.same, r.sameErr },
		stat: func(p string) (os.FileInfo, error) {
			r.visited = append(r.visited, p)
			if len(r.visited) > 8 {
				r.t.Fatalf("ancestor walk did not stop: visited %v", r.visited)
			}
			if p == r.statErrAt {
				return nil, syscall.EACCES
			}
			return r.dirs[p], nil
		},
		owner: func(fi os.FileInfo) (int, bool) { return fi.(fakeInfo).uid, true },
	}
	return checkBwrapTrust(fi, resolved)
}

var goodBwrap = fakeInfo{mode: 0o755, uid: 0}

const (
	errMatch    = "Bubblewrap must match trusted PATH-selected bwrap"
	errFile     = "Bubblewrap must be root-owned and non-writable"
	errAncestor = "Bubblewrap ancestor chain is not trusted"
)

func wantErr(t *testing.T, err error, msg string) {
	t.Helper()
	if err == nil || err.Error() != msg {
		t.Fatalf("error = %v, want %q", err, msg)
	}
}

func TestBwrapTrustAcceptsTheRootOwnedChain(t *testing.T) {
	r := newRig(t)
	r.root("/usr/bin", "/usr", "/")
	if err := r.check(goodBwrap, "/usr/bin/bwrap"); err != nil {
		t.Fatal(err)
	}
	if want := []string{"/usr/bin", "/usr", "/"}; !reflect.DeepEqual(r.visited, want) {
		t.Fatalf("walk = %v, want %v", r.visited, want)
	}
}

func TestBwrapTrustRefusesAnUnselectedLauncher(t *testing.T) {
	r := newRig(t)
	r.root("/usr/bin", "/usr", "/")
	r.selected = false
	wantErr(t, r.check(goodBwrap, "/usr/bin/bwrap"), errMatch)
}

func TestBwrapTrustSameFileRule(t *testing.T) {
	cases := []struct {
		name    string
		same    bool
		sameErr error
		refuse  bool
	}{
		{"same file, no error", true, nil, false},
		{"different file", false, nil, true},
		{"same reported with an error", true, errors.New("stat failed"), true},
		{"different with an error", false, errors.New("stat failed"), true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			r := newRig(t)
			r.root("/usr/bin", "/usr", "/")
			r.same, r.sameErr = c.same, c.sameErr
			err := r.check(goodBwrap, "/usr/bin/bwrap")
			if c.refuse {
				wantErr(t, err, errMatch)
			} else if err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestBwrapTrustFileOwnerAndModeRule(t *testing.T) {
	cases := []struct {
		name   string
		fi     fakeInfo
		refuse bool
	}{
		{"root 0755", fakeInfo{mode: 0o755, uid: 0}, false},
		{"root 0700", fakeInfo{mode: 0o700, uid: 0}, false},
		{"root owner-writable 0644", fakeInfo{mode: 0o644, uid: 0}, false},
		{"root 0200", fakeInfo{mode: 0o200, uid: 0}, false},
		{"not root 0755", fakeInfo{mode: 0o755, uid: 1000}, true},
		{"not root, 0755, uid 1", fakeInfo{mode: 0o755, uid: 1}, true},
		{"root group-writable", fakeInfo{mode: 0o775, uid: 0}, true},
		{"root other-writable", fakeInfo{mode: 0o757, uid: 0}, true},
		{"root group-write only", fakeInfo{mode: 0o020, uid: 0}, true},
		{"root other-write only", fakeInfo{mode: 0o002, uid: 0}, true},
		{"not root and writable", fakeInfo{mode: 0o777, uid: 1000}, true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			r := newRig(t)
			r.root("/usr/bin", "/usr", "/")
			err := r.check(c.fi, "/usr/bin/bwrap")
			if c.refuse {
				wantErr(t, err, errFile)
			} else if err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestBwrapTrustAncestorRule(t *testing.T) {
	cases := []struct {
		name   string
		dir    string
		info   fakeInfo
		refuse bool
	}{
		{"sticky root dir 0755", "/usr", fakeInfo{mode: fs.ModeDir | fs.ModeSticky | 0o755, uid: 0}, false},
		{"root dir owner-writable", "/usr", fakeInfo{mode: fs.ModeDir | 0o700, uid: 0}, false},
		{"parent not root-owned", "/usr/bin", fakeInfo{mode: fs.ModeDir | 0o755, uid: 1000}, true},
		{"middle not root-owned", "/usr", fakeInfo{mode: fs.ModeDir | 0o755, uid: 1000}, true},
		{"top not root-owned", "/", fakeInfo{mode: fs.ModeDir | 0o755, uid: 1000}, true},
		{"parent group-writable", "/usr/bin", fakeInfo{mode: fs.ModeDir | 0o775, uid: 0}, true},
		{"middle other-writable", "/usr", fakeInfo{mode: fs.ModeDir | 0o757, uid: 0}, true},
		{"top group-writable", "/", fakeInfo{mode: fs.ModeDir | 0o775, uid: 0}, true},
		{"top other-writable", "/", fakeInfo{mode: fs.ModeDir | 0o757, uid: 0}, true},
		{"middle group-write only", "/usr", fakeInfo{mode: fs.ModeDir | 0o020, uid: 0}, true},
		{"middle other-write only", "/usr", fakeInfo{mode: fs.ModeDir | 0o002, uid: 0}, true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			r := newRig(t)
			r.root("/usr/bin", "/usr", "/")
			r.dirs[c.dir] = c.info
			err := r.check(goodBwrap, "/usr/bin/bwrap")
			if c.refuse {
				wantErr(t, err, errAncestor)
			} else if err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestBwrapTrustAncestorStatErrorIsRefused(t *testing.T) {
	for _, bad := range []string{"/usr/bin", "/usr", "/"} {
		t.Run(bad, func(t *testing.T) {
			r := newRig(t)
			r.root("/usr/bin", "/usr", "/")
			r.statErrAt = bad
			wantErr(t, r.check(goodBwrap, "/usr/bin/bwrap"), osError(syscall.EACCES, bad).Error())
		})
	}
}

func TestBwrapTrustWalkEndsAtRoot(t *testing.T) {
	r := newRig(t)
	r.root("/", "/opt")
	if err := r.check(goodBwrap, "/opt/bwrap"); err != nil {
		t.Fatal(err)
	}
	if want := []string{"/opt", "/"}; !reflect.DeepEqual(r.visited, want) {
		t.Fatalf("walk = %v, want %v", r.visited, want)
	}
}

func TestBwrapTrustWalkEndsAtDotForARelativePath(t *testing.T) {
	r := newRig(t)
	r.root("rel/dir", "rel", ".")
	if err := r.check(goodBwrap, "rel/dir/bwrap"); err != nil {
		t.Fatal(err)
	}
	if want := []string{"rel/dir", "rel", "."}; !reflect.DeepEqual(r.visited, want) {
		t.Fatalf("walk = %v, want %v", r.visited, want)
	}
}

func TestBwrapTrustChecksTheDotAncestorBeforeStopping(t *testing.T) {
	r := newRig(t)
	r.root("rel", ".")
	r.dirs["."] = fakeInfo{mode: fs.ModeDir | 0o777, uid: 0}
	wantErr(t, r.check(goodBwrap, "rel/bwrap"), errAncestor)
}

func TestBwrapTrustDefaultsAreTheRealCalls(t *testing.T) {
	fi, err := bwrapTrustOps.stat("/")
	if err != nil || !fi.IsDir() {
		t.Fatalf("default stat(/) = %v, %v", fi, err)
	}
	if uid, ok := bwrapTrustOps.owner(fi); !ok || uid != 0 {
		t.Fatalf("default owner(/) = %d, %v", uid, ok)
	}
	if got, err := bwrapTrustOps.evalSymlinks("/"); err != nil || got != "/" {
		t.Fatalf("default evalSymlinks(/) = %q, %v", got, err)
	}
	if same, err := bwrapTrustOps.sameFile("/", "/"); err != nil || !same {
		t.Fatalf("default sameFile(/,/) = %v, %v", same, err)
	}
	want, wantOK := lookPath("bwrap", defPath)
	if got, ok := bwrapTrustOps.selected(); got != want || ok != wantOK {
		t.Fatalf("default selected = %q, %v; want %q, %v", got, ok, want, wantOK)
	}
}
