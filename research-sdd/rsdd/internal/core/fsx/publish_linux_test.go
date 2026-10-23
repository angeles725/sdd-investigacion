//go:build linux

package fsx

import (
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"syscall"
	"testing"
	"time"
)

func read(t *testing.T, p string) string {
	t.Helper()
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func mustWrite(t *testing.T, p, s string) {
	t.Helper()
	if err := os.WriteFile(p, []byte(s), 0o644); err != nil {
		t.Fatal(err)
	}
}

func exists(p string) bool { _, err := os.Lstat(p); return err == nil }

func TestWriteAtomicCreatesAndReplaces(t *testing.T) {
	old := syscall.Umask(0o022)
	defer syscall.Umask(old)
	dir := t.TempDir()
	p := filepath.Join(dir, "out.json")
	if err := WriteAtomic(p, []byte("one")); err != nil {
		t.Fatal(err)
	}
	if err := WriteAtomic(p, []byte("two!")); err != nil {
		t.Fatal(err)
	}
	if read(t, p) != "two!" {
		t.Fatal("not replaced")
	}
	if st, _ := os.Stat(p); st.Mode().Perm() != 0o644 {
		t.Fatalf("mode %v (want 0666 &^ umask)", st.Mode().Perm())
	}
	if e, _ := os.ReadDir(dir); len(e) != 1 {
		t.Fatalf("temp file left behind: %v", e)
	}
	if err := WriteAtomic(p, nil); err != nil || read(t, p) != "" {
		t.Fatalf("empty write: %v", err)
	}
}

func TestWriteAtomicOverwritesStaleTemp(t *testing.T) {
	dir := t.TempDir()
	mustWrite(t, filepath.Join(dir, ".out.tmp"), "stale stale stale")
	p := filepath.Join(dir, "out")
	if err := WriteAtomic(p, []byte("ok")); err != nil || read(t, p) != "ok" {
		t.Fatalf("err %v", err)
	}
}

func TestWriteAtomicFailureLeavesNothing(t *testing.T) {
	if err := WriteAtomic(filepath.Join(t.TempDir(), "no", "dir", "f"), []byte("x")); err == nil {
		t.Fatal("missing parent must fail")
	}
	dir := t.TempDir()
	target := filepath.Join(dir, "t") // a non-empty directory: the final rename fails
	_ = os.Mkdir(target, 0o755)
	mustWrite(t, filepath.Join(target, "f"), "x")
	if err := WriteAtomic(target, []byte("x")); err == nil {
		t.Fatal("rename over a directory must fail")
	}
	if exists(filepath.Join(dir, ".t.tmp")) {
		t.Fatal("temp file not cleaned after a failed rename")
	}
}

func TestRenameNoReplaceMovesAndRefusesExisting(t *testing.T) {
	dir := t.TempDir()
	a, b := filepath.Join(dir, "a"), filepath.Join(dir, "b")
	mustWrite(t, a, "A")
	if err := RenameNoReplace(a, b); err != nil {
		t.Fatal(err)
	}
	if exists(a) || read(t, b) != "A" {
		t.Fatal("not moved")
	}
	mustWrite(t, a, "A2")
	err := RenameNoReplace(a, b)
	if !errors.Is(err, fs.ErrExist) || !errors.Is(err, syscall.EEXIST) || errors.Is(err, ErrUnavailable) {
		t.Fatalf("want plain EEXIST, got %v", err)
	}
	var le *os.LinkError
	if !errors.As(err, &le) || le.Old != a || le.New != b {
		t.Fatalf("want *os.LinkError naming both paths, got %#v", err)
	}
	if read(t, a) != "A2" || read(t, b) != "A" {
		t.Fatal("a refused rename must leave both files untouched")
	}
}

func TestRenameNoReplaceMissingSourceAndDirs(t *testing.T) {
	dir := t.TempDir()
	if err := RenameNoReplace(filepath.Join(dir, "x"), filepath.Join(dir, "y")); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("missing source: %v", err)
	}
	d1, d2 := filepath.Join(dir, "d1"), filepath.Join(dir, "d2")
	_ = os.Mkdir(d1, 0o755)
	_ = os.Mkdir(d2, 0o755)
	if err := RenameNoReplace(d1, d2); !errors.Is(err, syscall.EEXIST) {
		t.Fatalf("existing empty dir must not be replaced: %v", err)
	}
	d3 := filepath.Join(dir, "d3")
	if err := RenameNoReplace(d1, d3); err != nil || !exists(d3) {
		t.Fatalf("dir move: %v", err)
	}
}

func TestRenameExchangeSwaps(t *testing.T) {
	dir := t.TempDir()
	a, b := filepath.Join(dir, "a"), filepath.Join(dir, "b")
	mustWrite(t, a, "A")
	mustWrite(t, b, "B")
	if err := RenameExchange(a, b); err != nil {
		t.Fatal(err)
	}
	if read(t, a) != "B" || read(t, b) != "A" {
		t.Fatal("not swapped")
	}
	d1, d2 := filepath.Join(dir, "d1"), filepath.Join(dir, "d2")
	_ = os.Mkdir(d1, 0o755)
	_ = os.Mkdir(d2, 0o755)
	mustWrite(t, filepath.Join(d1, "m"), "1")
	if err := RenameExchange(d1, d2); err != nil || !exists(filepath.Join(d2, "m")) || exists(filepath.Join(d1, "m")) {
		t.Fatalf("dir swap: %v", err)
	}
}

func TestRenameExchangeRequiresBothToExist(t *testing.T) {
	dir := t.TempDir()
	a, b := filepath.Join(dir, "a"), filepath.Join(dir, "b")
	mustWrite(t, a, "A")
	if err := RenameExchange(a, b); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("got %v", err)
	}
	if read(t, a) != "A" || exists(b) {
		t.Fatal("a failed exchange must not create or move anything")
	}
}

func TestRenameat2WithDirFDs(t *testing.T) {
	dir := t.TempDir()
	mustWrite(t, filepath.Join(dir, "s"), "S")
	fd, err := sysOpenDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer syscall.Close(fd)
	if err := Renameat2(fd, "s", fd, "d", FlagNoReplace); err != nil {
		t.Fatal(err)
	}
	if read(t, filepath.Join(dir, "d")) != "S" {
		t.Fatal("dirfd-relative rename failed")
	}
}

func TestRenameat2InvalidFlagsAreUnavailable(t *testing.T) {
	dir := t.TempDir()
	a, b := filepath.Join(dir, "a"), filepath.Join(dir, "b")
	mustWrite(t, a, "A")
	for name, flags := range map[string]uint{"unknown bit": 0x80, "both flags": FlagNoReplace | FlagExchange} {
		err := Renameat2(AtFDCWD, a, AtFDCWD, b, flags)
		if !errors.Is(err, ErrUnavailable) || !errors.Is(err, syscall.EINVAL) {
			t.Fatalf("%s: want ErrUnavailable wrapping EINVAL, got %v", name, err)
		}
	}
	if exists(b) || read(t, a) != "A" {
		t.Fatal("nothing may move on an unavailable error")
	}
}

func TestPublishNeverFallsBackToPlainRename(t *testing.T) {
	for _, errno := range []syscall.Errno{syscall.ENOSYS, syscall.EINVAL} {
		dir := t.TempDir()
		stage, dest := filepath.Join(dir, "stage"), filepath.Join(dir, "dest")
		mustWrite(t, stage, "S")
		orig := renameat2Fn
		renameat2Fn = func(int, string, int, string, uint) error { return errno }
		err := Publish(stage, dest)
		renameat2Fn = orig
		if !errors.Is(err, ErrUnavailable) || !errors.Is(err, errno) {
			t.Fatalf("%v: got %v", errno, err)
		}
		if !exists(stage) || exists(dest) {
			t.Fatalf("%v: fell back to a rename", errno)
		}
	}
}

func TestRenameat2OtherErrnosStayLinkErrors(t *testing.T) {
	orig := renameat2Fn
	defer func() { renameat2Fn = orig }()
	renameat2Fn = func(int, string, int, string, uint) error { return syscall.EACCES }
	err := RenameNoReplace("a", "b")
	var le *os.LinkError
	if !errors.As(err, &le) || errors.Is(err, ErrUnavailable) || le.Op != "renameat2" || !errors.Is(err, syscall.EACCES) {
		t.Fatalf("got %#v", err)
	}
}

func TestRenameat2PassesFlagsAndPaths(t *testing.T) {
	orig := renameat2Fn
	defer func() { renameat2Fn = orig }()
	var got []any
	renameat2Fn = func(o int, op string, n int, np string, f uint) error {
		got = []any{o, op, n, np, f}
		return nil
	}
	_ = RenameNoReplace("a", "b")
	_ = RenameExchange("c", "d")
	_ = Publish("e", "f")
	if want := []any{AtFDCWD, "e", AtFDCWD, "f", uint(FlagNoReplace)}; len(got) != 5 || got[0] != want[0] || got[1] != want[1] || got[2] != want[2] || got[3] != want[3] || got[4] != want[4] {
		t.Fatalf("Publish called %v", got)
	}
	_ = RenameExchange("c", "d")
	if got[1] != "c" || got[3] != "d" || got[4] != uint(FlagExchange) {
		t.Fatalf("RenameExchange called %v", got)
	}
}

func TestRenameat2NULInPathIsNotUnavailable(t *testing.T) {
	err := RenameNoReplace("a\x00b", "c")
	if err == nil || errors.Is(err, ErrUnavailable) {
		t.Fatalf("got %v", err)
	}
}

func TestPublishRefusesExistingDest(t *testing.T) {
	dir := t.TempDir()
	stage, dest := filepath.Join(dir, "stage"), filepath.Join(dir, "dest")
	mustWrite(t, stage, "S")
	mustWrite(t, dest, "D")
	if err := Publish(stage, dest); !errors.Is(err, fs.ErrExist) {
		t.Fatalf("got %v", err)
	}
	if read(t, dest) != "D" || !exists(stage) {
		t.Fatal("existing dest must survive")
	}
	_ = os.Remove(dest)
	if err := Publish(stage, dest); err != nil || read(t, dest) != "S" || exists(stage) {
		t.Fatalf("publish: %v", err)
	}
}

func TestSyncDir(t *testing.T) {
	dir := t.TempDir()
	if err := SyncDir(dir); err != nil {
		t.Fatal(err)
	}
	if err := SyncDir(filepath.Join(dir, "nope")); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("missing: %v", err)
	}
	f := filepath.Join(dir, "f")
	mustWrite(t, f, "x")
	if err := SyncDir(f); !errors.Is(err, syscall.ENOTDIR) {
		t.Fatalf("file is not a directory: %v", err)
	}
}

func TestStageFileCopiesAndRecords(t *testing.T) {
	big := make([]byte, 3<<20)
	for i := range big {
		big[i] = byte(i * 13)
	}
	for name, data := range map[string][]byte{"empty": {}, "small": []byte("hello"), "3MiB": big} {
		t.Run(name, func(t *testing.T) {
			dir := t.TempDir()
			src, dst := filepath.Join(dir, "src"), filepath.Join(dir, "dst")
			_ = os.WriteFile(src, data, 0o644)
			s, d, err := StageFile(src, dst, "input/target.bin", 0o400, NoLimit)
			if err != nil {
				t.Fatal(err)
			}
			wantSrc, _ := filepath.EvalSymlinks(src)
			if s != (Record{wantSrc, int64(len(data)), "sha256:" + sum(data)}) {
				t.Fatalf("source record %+v", s)
			}
			if d != (Record{"input/target.bin", int64(len(data)), "sha256:" + sum(data)}) {
				t.Fatalf("staged record %+v", d)
			}
			if got := read(t, dst); got != string(data) {
				t.Fatal("copy differs")
			}
			if st, _ := os.Stat(dst); st.Mode().Perm() != 0o400 {
				t.Fatalf("mode %v", st.Mode().Perm())
			}
		})
	}
}

func TestStageFileRefusals(t *testing.T) {
	dir := t.TempDir()
	reg := filepath.Join(dir, "reg")
	mustWrite(t, reg, "x")
	link := filepath.Join(dir, "link")
	_ = os.Symlink(reg, link)
	fifo := filepath.Join(dir, "fifo")
	_ = syscall.Mkfifo(fifo, 0o600)
	cases := []struct {
		name, src string
		want      error
		msg       string
	}{
		{"symlink", link, ErrSourceOpen, "source cannot be opened safely"},
		{"missing", filepath.Join(dir, "nope"), ErrSourceOpen, "source cannot be opened safely"},
		{"dir", dir, ErrSourceNotRegular, "source is not a regular file"},
		{"fifo", fifo, ErrSourceNotRegular, "source is not a regular file"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			dst := filepath.Join(dir, "dst-"+c.name)
			_, _, err := StageFile(c.src, dst, "l", 0o600, NoLimit)
			if !errors.Is(err, c.want) || err.Error() != c.msg {
				t.Fatalf("got %v", err)
			}
			if exists(dst) {
				t.Fatal("target created for a refused source")
			}
		})
	}
}

func TestStageFileExistingTargetIsKept(t *testing.T) {
	dir := t.TempDir()
	src, dst := filepath.Join(dir, "src"), filepath.Join(dir, "dst")
	mustWrite(t, src, "new")
	mustWrite(t, dst, "precious")
	_, _, err := StageFile(src, dst, "l", 0o600, NoLimit)
	if !errors.Is(err, ErrStageIO) || !errors.Is(err, fs.ErrExist) || err.Error() != "I/O error while staging source" {
		t.Fatalf("got %v", err)
	}
	if read(t, dst) != "precious" {
		t.Fatal("a pre-existing target must never be unlinked or overwritten")
	}
}

func TestStageFileSizeCap(t *testing.T) {
	dir := t.TempDir()
	src, dst := filepath.Join(dir, "src"), filepath.Join(dir, "dst")
	mustWrite(t, src, "12345")
	if _, _, err := StageFile(src, dst, "l", 0o600, 4); !errors.Is(err, ErrTooLarge) || exists(dst) {
		t.Fatalf("declared size over cap: %v exists=%v", err, exists(dst))
	}
	if _, _, err := StageFile(src, dst, "l", 0o600, 5); err != nil {
		t.Fatalf("size == cap: %v", err)
	}
	_ = os.Remove(dst)
	// the declared size is judged before the target is touched: an existing
	// target stays and the error is the cap, not EEXIST
	mustWrite(t, dst, "keep")
	if _, _, err := StageFile(src, dst, "l", 0o600, 4); !errors.Is(err, ErrTooLarge) || read(t, dst) != "keep" {
		t.Fatalf("oversize source with existing target: %v", err)
	}
	_ = os.Remove(dst)
	// growth past the cap while copying: error AND the partial target is removed
	dst2 := filepath.Join(dir, "dst2")
	n := 0
	setHook(t, func() {
		if n++; n == 1 {
			appendTo(t, src, []byte("6789"))
		}
	})
	if _, _, err := StageFile(src, dst2, "l", 0o600, 5); !errors.Is(err, ErrTooLarge) || exists(dst2) {
		t.Fatalf("cap hit mid-copy: %v exists=%v", err, exists(dst2))
	}
}

func TestStageFileDetectsSourceChangeAndRemovesTarget(t *testing.T) {
	dir := t.TempDir()
	src, dst := filepath.Join(dir, "src"), filepath.Join(dir, "dst")
	_ = os.WriteFile(src, make([]byte, 3<<20), 0o644)
	n := 0
	setHook(t, func() {
		if n++; n == 1 {
			appendTo(t, src, []byte("more"))
		}
	})
	_, _, err := StageFile(src, dst, "l", 0o600, NoLimit)
	if !errors.Is(err, ErrSourceChanged) || err.Error() != "source changed while staging" {
		t.Fatalf("got %v", err)
	}
	if exists(dst) {
		t.Fatal("partial target must be unlinked")
	}
}

func TestStageFileDetectsStagedMismatch(t *testing.T) {
	dir := t.TempDir()
	src, dst := filepath.Join(dir, "src"), filepath.Join(dir, "dst")
	mustWrite(t, src, "abc")
	orig := identityFn
	defer func() { identityFn = orig }()
	identityFn = func(p string, m int64) (Ident, error) {
		id, err := orig(p, m)
		id.SHA256 = "sha256:bad"
		return id, err
	}
	_, _, err := StageFile(src, dst, "l", 0o600, NoLimit)
	if !errors.Is(err, ErrStagedMismatch) || err.Error() != "staged identity mismatch" {
		t.Fatalf("got %v", err)
	}
	// An unverified target must not survive: a later Publish could move it into place, and a
	// retry would hit EEXIST. (Python's adapter_core.stage_file leaves it; this is deliberate.)
	if _, err := os.Lstat(dst); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("digest mismatch left the unverified target behind: %v", err)
	}
	identityFn = func(p string, m int64) (Ident, error) {
		id, err := orig(p, m)
		id.Size++
		return id, err
	}
	if _, _, err := StageFile(src, dst, "l", 0o600, NoLimit); !errors.Is(err, ErrStagedMismatch) {
		t.Fatalf("size mismatch: %v", err)
	}
	if _, err := os.Lstat(dst); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("size mismatch left the unverified target behind: %v", err)
	}
	reread := errors.New("re-read failed")
	identityFn = func(string, int64) (Ident, error) { return Ident{}, reread }
	if _, _, err := StageFile(src, dst, "l", 0o600, NoLimit); !errors.Is(err, reread) {
		t.Fatalf("re-read failure: %v", err)
	}
	if _, err := os.Lstat(dst); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("a failed re-read left the unverified target behind: %v", err)
	}
}

func TestStageFileDoesNotLeakFds(t *testing.T) {
	dir := t.TempDir()
	src := filepath.Join(dir, "src")
	mustWrite(t, src, "abc")
	before := fdCount(t)
	_, _, _ = StageFile(src, filepath.Join(dir, "ok"), "l", 0o600, NoLimit)
	_, _, _ = StageFile(src, filepath.Join(dir, "ok"), "l", 0o600, NoLimit) // target exists
	_, _, _ = StageFile(dir, filepath.Join(dir, "x"), "l", 0o600, NoLimit)
	_, _, _ = StageFile(src, filepath.Join(dir, "big"), "l", 0o600, 1)
	if fdCount(t) != before {
		t.Fatal("fd leaked")
	}
}

func TestStageFileDetectsMtimeOnlyChange(t *testing.T) {
	dir := t.TempDir()
	src, dst := filepath.Join(dir, "src"), filepath.Join(dir, "dst")
	mustWrite(t, src, "abc")
	n := 0
	setHook(t, func() {
		if n++; n == 1 {
			_ = os.Chtimes(src, time.Unix(1000000000, 0), time.Unix(1000000000, 0))
		}
	})
	if _, _, err := StageFile(src, dst, "l", 0o600, NoLimit); !errors.Is(err, ErrSourceChanged) || exists(dst) {
		t.Fatalf("got %v exists=%v", err, exists(dst))
	}
}

// /proc/self/cmdline stats as size 0 and stays fstat-stable, so only the
// bytes-copied == size check notices the content does not match.
func TestStageFileDetectsCopiedSizeMismatch(t *testing.T) {
	dst := filepath.Join(t.TempDir(), "dst")
	if _, _, err := StageFile("/proc/self/cmdline", dst, "l", 0o600, NoLimit); !errors.Is(err, ErrSourceChanged) || exists(dst) {
		t.Fatalf("got %v exists=%v", err, exists(dst))
	}
}
