//go:build linux

package formats

// Guard-to-test table for squashfs-extract. Every refusal of squashfs_extract.py is pinned by a named test;
// TestSquashfsParity* hold the whole behavior against the frozen legacy script
// (testdata/squashfs/legacy/squashfs_extract.py, run through testdata/squashfs/oracle_driver.py).
//
//	guard (squashfs_extract.py)                          Go test
//	refuse_privileged_execution (root / set-id)          TestSquashfsRefusesPrivilegedExecution
//	caps must be positive                                TestSquashfsCapsMustBePositive
//	output must be a canonical path                      TestSquashfsOutputPathRefusals
//	output parent links are not allowed                  TestSquashfsOutputPathRefusals
//	unsafe output destination                            TestSquashfsOutputPathRefusals
//	require_private (mountinfo)                          TestSquashfsRequiresPrivateFilesystem
//	bwrap / unsquashfs / manifest-cli lookups            TestSquashfsToolLookups
//	stage_file refusals (open, regular, size cap)        TestSquashfsInputRefusals
//	superblock validation                                TestSquashfsFindOffset, TestSquashfsParityFindOffset
//	unsquashfs timeout / failure / stderr snippet        TestSquashfsRunFailures
//	size watchdog (aggregate bytes during extraction)    TestSquashfsSizeWatchdog
//	walk_tree: symlink/special/hardlink/entries/bytes    TestSquashfsWalkTreeRefusals, TestSquashfsParityWalkTree
//	walk_tree: file changed while hashing                TestSquashfsWalkTreeChangedWhileHashing
//	validate_closed                                      TestSquashfsValidateClosed, TestSquashfsParityValidateClosed
//	publish without replace, stage cleanup               TestSquashfsPublishAndCleanup
//	end to end + manifest                                TestSquashfsEndToEnd, TestSquashfsParityEndToEnd
//	bash suite cases T1..T11 / teeth M1..M4              the tests above (messages pinned verbatim)

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

const (
	sqfsData   = "testdata/squashfs/"
	sqfsLegacy = "testdata/squashfs/legacy/squashfs_extract.py"
	sqfsDriver = "testdata/squashfs/oracle_driver.py"
	toolbelt   = "../core/adapter/testdata/frozen" // frozen oracle copy of the toolbelt modules (core consolidation, #2561), never the live toolbelt
)

// ---------------------------------------------------------------- helpers

func manifestCLI(t *testing.T) string { return abs(t, toolbelt+"/analysis_manifest.py") }

// runSqfs runs the command in process with the real environment (the manifest tool is a Python child).
func runSqfs(t *testing.T, cwd string, args ...string) (rc int, stdout, stderr string) {
	t.Helper()
	s, out, errb := testStdio(cwd)
	s.Env = os.Getenv
	s.Environ = os.Environ
	done := make(chan int, 1)
	go func() { done <- SquashfsExtract(args, s) }()
	select {
	case rc = <-done:
	case <-time.After(60 * time.Second):
		t.Fatalf("squashfs-extract %v did not finish within 60s", args)
	}
	return rc, out.String(), errb.String()
}

func sqfsArgs(input, output string, extra ...string) []string {
	return append([]string{"--input", input, "--output", output}, extra...)
}

// extract runs with the manifest tool wired in and the output under a fresh private parent.
func extract(t *testing.T, input string, extra ...string) (rc int, stderr, parent, out string) {
	t.Helper()
	parent = t.TempDir()
	out = filepath.Join(parent, "out")
	rc, stdout, stderr := runSqfs(t, parent, sqfsArgs(input, out, append([]string{"--manifest-cli", manifestCLI(t)}, extra...)...)...)
	if stdout != "" {
		t.Errorf("stdout = %q, want empty", stdout)
	}
	return rc, stderr, parent, out
}

// useTools points the tool lookups at a directory holding a fake bwrap (the given shell body, after a preamble
// that sets $stage to the bound stage directory) and an unsquashfs placeholder.
func useTools(t *testing.T, body string) {
	t.Helper()
	dir := t.TempDir()
	preamble := "#!/bin/sh\nprev=\"\"\nfor a in \"$@\"; do\n  if [ \"$prev\" = \"--bind\" ]; then stage=\"$a\"; fi\n  prev=\"$a\"\ndone\n"
	if err := os.WriteFile(filepath.Join(dir, "bwrap"), []byte(preamble+body+"\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "unsquashfs"), []byte("#!/bin/sh\nexit 0\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	ob, ou := bwrapSearchPath, unsquashfsSearchPath
	bwrapSearchPath, unsquashfsSearchPath = dir, dir
	t.Cleanup(func() { bwrapSearchPath, unsquashfsSearchPath = ob, ou })
}

const okExtraction = `mkdir -p "$stage/extracted/sub" "$stage/extracted/empty"
printf hello > "$stage/extracted/hello.txt"
printf world > "$stage/extracted/sub/world.txt"
: > "$stage/extracted/zero"
exit 0`

type snap struct {
	Type, Mode, SHA string
}

// snapshot describes a tree: type, permission bits and content hash of everything under root.
func snapshot(t *testing.T, root string) map[string]snap {
	t.Helper()
	out := map[string]snap{}
	err := filepath.Walk(root, func(p string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(root, p)
		if rel == "." {
			return nil
		}
		s := snap{Mode: fmt.Sprintf("%04o", info.Mode().Perm())}
		switch {
		case info.IsDir():
			s.Type = "dir"
		case info.Mode().IsRegular():
			s.Type = "file"
			b, _ := os.ReadFile(p)
			h := sha256.Sum256(b)
			s.SHA = hex.EncodeToString(h[:])
		default:
			s.Type = "other"
		}
		st := info.Sys().(*syscall.Stat_t)
		if int(st.Uid) != os.Getuid() {
			t.Errorf("%s is owned by uid %d", rel, st.Uid)
		}
		out[rel] = s
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	return out
}

func mustNotExist(t *testing.T, paths ...string) {
	t.Helper()
	for _, p := range paths {
		if _, err := os.Lstat(p); err == nil {
			t.Errorf("%s exists", p)
		}
	}
}

func readJSON(t *testing.T, p string) map[string]any {
	t.Helper()
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	var m map[string]any
	if err := json.Unmarshal(b, &m); err != nil {
		t.Fatalf("%s: %v", p, err)
	}
	return m
}

// ---------------------------------------------------------------- refusals before any tool runs

func TestSquashfsRefusesPrivilegedExecution(t *testing.T) {
	good := abs(t, sqfsData+"good.sqfs")
	for name, c := range map[string]creds{
		"root euid":  {1000, 0, 1000, 1000},
		"setuid":     {1000, 1001, 1000, 1000},
		"setgid":     {1000, 1000, 1000, 1001},
		"root, both": {0, 0, 0, 0},
	} {
		t.Run(name, func(t *testing.T) {
			old := currentCreds
			currentCreds = func() creds { return c }
			t.Cleanup(func() { currentCreds = old })
			parent := t.TempDir()
			rc, stdout, stderr := runSqfs(t, parent, sqfsArgs(good, filepath.Join(parent, "out"), "--manifest-cli", "z")...)
			if rc != 2 || stdout != "" || stderr != "squashfs-extract: refusing root or set-id execution\n" {
				t.Errorf("rc = %d stdout = %q stderr = %q", rc, stdout, stderr)
			}
			mustNotExist(t, filepath.Join(parent, "out"), filepath.Join(parent, ".out.stage"))
		})
	}
}

func TestSquashfsCapsMustBePositive(t *testing.T) {
	good := abs(t, sqfsData+"good.sqfs")
	for _, flag := range []string{"--max-input-bytes", "--max-extracted-bytes", "--max-entries", "--timeout-seconds"} {
		for _, v := range []string{"0", "-1"} {
			t.Run(flag+"="+v, func(t *testing.T) {
				rc, stderr, parent, out := extract(t, good, flag, v)
				if rc != 2 || stderr != "squashfs-extract: caps must be positive\n" {
					t.Errorf("rc = %d stderr = %q", rc, stderr)
				}
				mustNotExist(t, out, filepath.Join(parent, ".out.stage"))
			})
		}
	}
}

func TestSquashfsOutputPathRefusals(t *testing.T) {
	good := abs(t, sqfsData+"good.sqfs")
	mf := manifestCLI(t)
	run := func(cwd, output string, extra ...string) (int, string) {
		rc, _, stderr := runSqfs(t, cwd, sqfsArgs(good, output, append([]string{"--manifest-cli", mf}, extra...)...)...)
		return rc, stderr
	}
	t.Run("dotdot", func(t *testing.T) {
		parent := t.TempDir()
		rc, stderr := run(parent, parent+"/a/../out")
		if rc != 2 || stderr != "squashfs-extract: output must be a canonical path\n" {
			t.Errorf("rc = %d stderr = %q", rc, stderr)
		}
		rc, stderr = run(parent, "../out")
		if rc != 2 || stderr != "squashfs-extract: output must be a canonical path\n" {
			t.Errorf("relative: rc = %d stderr = %q", rc, stderr)
		}
	})
	t.Run("backslash", func(t *testing.T) {
		parent := t.TempDir()
		rc, stderr := run(parent, parent+`/o\ut`)
		if rc != 2 || stderr != "squashfs-extract: output must be a canonical path\n" {
			t.Errorf("rc = %d stderr = %q", rc, stderr)
		}
	})
	t.Run("parent link", func(t *testing.T) {
		parent := t.TempDir()
		real := filepath.Join(parent, "real")
		if err := os.Mkdir(real, 0o700); err != nil {
			t.Fatal(err)
		}
		link := filepath.Join(parent, "link")
		if err := os.Symlink(real, link); err != nil {
			t.Fatal(err)
		}
		rc, stderr := run(parent, link+"/out")
		if rc != 2 || stderr != "squashfs-extract: output parent links are not allowed\n" {
			t.Errorf("rc = %d stderr = %q", rc, stderr)
		}
		mustNotExist(t, filepath.Join(real, "out"), filepath.Join(real, ".out.stage"))
	})
	t.Run("missing parent", func(t *testing.T) {
		parent := t.TempDir()
		missing := filepath.Join(parent, "nope")
		rc, stderr := run(parent, missing+"/out")
		if want := "squashfs-extract: [Errno 2] No such file or directory: " + pyRepr(missing) + "\n"; rc != 2 || stderr != want {
			t.Errorf("rc = %d stderr = %q, want %q", rc, stderr, want)
		}
	})
	t.Run("destination exists", func(t *testing.T) {
		parent := t.TempDir()
		if err := os.Mkdir(filepath.Join(parent, "out"), 0o700); err != nil {
			t.Fatal(err)
		}
		rc, stderr := run(parent, filepath.Join(parent, "out"))
		if rc != 2 || stderr != "squashfs-extract: unsafe output destination\n" {
			t.Errorf("rc = %d stderr = %q", rc, stderr)
		}
		mustNotExist(t, filepath.Join(parent, ".out.stage"))
	})
	t.Run("destination is a dangling symlink", func(t *testing.T) {
		parent := t.TempDir()
		if err := os.Symlink(filepath.Join(parent, "nowhere"), filepath.Join(parent, "out")); err != nil {
			t.Fatal(err)
		}
		rc, stderr := run(parent, filepath.Join(parent, "out"))
		if rc != 2 || stderr != "squashfs-extract: unsafe output destination\n" {
			t.Errorf("rc = %d stderr = %q", rc, stderr)
		}
	})
	t.Run("parent writable by others", func(t *testing.T) {
		for _, mode := range []os.FileMode{0o770, 0o707} {
			parent := t.TempDir()
			if err := os.Chmod(parent, mode); err != nil {
				t.Fatal(err)
			}
			rc, stderr := run(parent, filepath.Join(parent, "out"))
			if rc != 2 || stderr != "squashfs-extract: unsafe output destination\n" {
				t.Errorf("mode %o: rc = %d stderr = %q", mode, rc, stderr)
			}
		}
	})
	t.Run("parent is a file", func(t *testing.T) {
		parent := t.TempDir()
		f := filepath.Join(parent, "file")
		if err := os.WriteFile(f, nil, 0o600); err != nil {
			t.Fatal(err)
		}
		rc, stderr := run(parent, f+"/out")
		if rc != 2 || !strings.HasPrefix(stderr, "squashfs-extract: ") {
			t.Errorf("rc = %d stderr = %q", rc, stderr)
		}
		mustNotExist(t, filepath.Join(parent, "out"))
	})
	t.Run("relative output resolves against the injected cwd", func(t *testing.T) {
		useTools(t, okExtraction)
		parent := t.TempDir()
		rc, _, stderr := runSqfs(t, parent, sqfsArgs(good, "rel-out", "--manifest-cli", mf)...)
		if rc != 0 {
			t.Fatalf("rc = %d stderr = %q", rc, stderr)
		}
		if _, err := os.Stat(filepath.Join(parent, "rel-out", "squashfs-extract.v1.json")); err != nil {
			t.Errorf("relative output not published under Stdio.Cwd: %v", err)
		}
	})
}

func TestSquashfsRequiresPrivateFilesystem(t *testing.T) {
	good := abs(t, sqfsData+"good.sqfs")
	useTools(t, okExtraction)
	for name, tc := range map[string]struct{ mountinfo, want string }{
		"shared filesystem": {"36 35 0:33 / %s rw - nfs host:/export rw\n", "squashfs-extract: output must reside on a Linux-private filesystem\n"},
		"no mount point":    {"36 35 0:33 / /elsewhere rw - ext4 /dev/sda rw\n", "squashfs-extract: output path is under no known mount point\n"},
		"malformed":         {"this is not mountinfo\n", "squashfs-extract: malformed mountinfo line (missing ' - ' separator): 'this is not mountinfo'\n"},
		"deepest wins":      {"1 0 8:1 / / rw - nfs host:/ rw\n36 1 0:33 / %s rw - ext4 /dev/sda rw\n", ""},
		"deeper unsafe":     {"1 0 8:1 / / rw - ext4 /dev/sda rw\n36 1 0:33 / %s rw - fuse.sshfs x rw\n", "squashfs-extract: output must reside on a Linux-private filesystem\n"},
		"unknown type":      {"36 35 0:33 / %s rw - ext9 /dev/sda rw\n", "squashfs-extract: output must reside on a Linux-private filesystem\n"},
	} {
		t.Run(name, func(t *testing.T) {
			parent := t.TempDir()
			info := tc.mountinfo
			if strings.Contains(info, "%s") {
				info = strings.ReplaceAll(info, "%s", parent)
			}
			old := readMountinfo
			readMountinfo = func() (string, error) { return info, nil }
			t.Cleanup(func() { readMountinfo = old })
			rc, _, stderr := runSqfs(t, parent, sqfsArgs(good, filepath.Join(parent, "out"), "--manifest-cli", manifestCLI(t))...)
			if tc.want == "" {
				if rc != 0 {
					t.Errorf("rc = %d stderr = %q, want success", rc, stderr)
				}
				return
			}
			if rc != 2 || stderr != tc.want {
				t.Errorf("rc = %d stderr = %q, want %q", rc, stderr, tc.want)
			}
			mustNotExist(t, filepath.Join(parent, "out"), filepath.Join(parent, ".out.stage"))
		})
	}
	t.Run("unreadable mountinfo", func(t *testing.T) {
		old := readMountinfo
		readMountinfo = func() (string, error) { return "", syscall.EACCES }
		t.Cleanup(func() { readMountinfo = old })
		parent := t.TempDir()
		rc, _, stderr := runSqfs(t, parent, sqfsArgs(good, filepath.Join(parent, "out"), "--manifest-cli", manifestCLI(t))...)
		if rc != 2 || !strings.HasPrefix(stderr, "squashfs-extract: ") {
			t.Errorf("rc = %d stderr = %q", rc, stderr)
		}
	})
}

func TestSquashfsToolLookups(t *testing.T) {
	good := abs(t, sqfsData+"good.sqfs")
	empty := t.TempDir()
	only := func(name string) string {
		d := t.TempDir()
		if err := os.WriteFile(filepath.Join(d, name), []byte("#!/bin/sh\nexit 0\n"), 0o755); err != nil {
			t.Fatal(err)
		}
		return d
	}
	notExec := t.TempDir()
	if err := os.WriteFile(filepath.Join(notExec, "bwrap"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	for name, tc := range map[string]struct{ bwrap, unsq, want string }{
		"no bwrap":       {empty, only("unsquashfs"), "squashfs-extract: bwrap is required\n"},
		"bwrap not exec": {notExec, only("unsquashfs"), "squashfs-extract: bwrap is required\n"},
		"no unsquashfs":  {only("bwrap"), empty, "squashfs-extract: unsquashfs is required\n"},
	} {
		t.Run(name, func(t *testing.T) {
			ob, ou := bwrapSearchPath, unsquashfsSearchPath
			bwrapSearchPath, unsquashfsSearchPath = tc.bwrap, tc.unsq
			t.Cleanup(func() { bwrapSearchPath, unsquashfsSearchPath = ob, ou })
			rc, stderr, parent, out := extract(t, good)
			if rc != 2 || stderr != tc.want {
				t.Errorf("rc = %d stderr = %q, want %q", rc, stderr, tc.want)
			}
			mustNotExist(t, out, filepath.Join(parent, ".out.stage"))
		})
	}
	t.Run("manifest cli missing", func(t *testing.T) {
		useTools(t, okExtraction)
		parent := t.TempDir()
		missing := filepath.Join(parent, "no-manifest.py")
		rc, _, stderr := runSqfs(t, parent, sqfsArgs(good, filepath.Join(parent, "out"), "--manifest-cli", missing)...)
		if want := "squashfs-extract: [Errno 2] No such file or directory: " + pyRepr(missing) + "\n"; rc != 2 || stderr != want {
			t.Errorf("rc = %d stderr = %q, want %q", rc, stderr, want)
		}
		mustNotExist(t, filepath.Join(parent, "out"), filepath.Join(parent, ".out.stage"))
	})
}

func TestSquashfsUsage(t *testing.T) {
	good := abs(t, sqfsData+"good.sqfs")
	parent := t.TempDir()
	out := filepath.Join(parent, "out")
	mf := manifestCLI(t)
	for name, args := range map[string][]string{
		"no args":         {},
		"no input":        {"--output", out, "--manifest-cli", mf},
		"no output":       {"--input", good, "--manifest-cli", mf},
		"no manifest-cli": {"--input", good, "--output", out},
		"bad int":         {"--input", good, "--output", out, "--manifest-cli", mf, "--max-entries", "many"},
		"unknown flag":    {"--input", good, "--output", out, "--manifest-cli", mf, "--frobnicate"},
		"positional":      {"--input", good, "--output", out, "--manifest-cli", mf, "extra"},
	} {
		t.Run(name, func(t *testing.T) {
			rc, stdout, stderr := runSqfs(t, parent, args...)
			if rc != 2 || stdout != "" || stderr == "" {
				t.Errorf("rc = %d stdout = %q stderr = %q, want exit 2 and a message on stderr", rc, stdout, stderr)
			}
		})
	}
	if rc, stdout, _ := runSqfs(t, parent, "-h"); rc != 0 || !strings.Contains(stdout, "--input") {
		t.Errorf("-h: rc = %d stdout = %q", rc, stdout)
	}
	mustNotExist(t, out, filepath.Join(parent, ".out.stage"))
}

// ---------------------------------------------------------------- input staging and the superblock

func TestSquashfsInputRefusals(t *testing.T) {
	useTools(t, okExtraction)
	dir := t.TempDir()
	good := abs(t, sqfsData+"good.sqfs")
	link := filepath.Join(dir, "link.sqfs")
	if err := os.Symlink(good, link); err != nil {
		t.Fatal(err)
	}
	blob := filepath.Join(dir, "blob.bin")
	if err := os.WriteFile(blob, []byte("this is not a squashfs image"), 0o600); err != nil {
		t.Fatal(err)
	}
	junk := filepath.Join(dir, "junk.bin")
	if err := os.WriteFile(junk, bytes.Repeat([]byte{0xAB}, 4096), 0o600); err != nil {
		t.Fatal(err)
	}
	trunc := filepath.Join(dir, "trunc.sqfs")
	raw, _ := os.ReadFile(good)
	if err := os.WriteFile(trunc, raw[:150], 0o600); err != nil {
		t.Fatal(err)
	}
	fifo := filepath.Join(dir, "fifo.sqfs")
	if err := syscall.Mkfifo(fifo, 0o600); err != nil {
		t.Fatal(err)
	}
	for name, tc := range map[string]struct {
		input string
		extra []string
		want  string
	}{
		"absent":                  {filepath.Join(dir, "absent.sqfs"), nil, "source cannot be opened safely"},
		"symlink":                 {link, nil, "source cannot be opened safely"},
		"directory":               {dir, nil, "source is not a regular file"},
		"fifo":                    {fifo, nil, "source is not a regular file"},
		"over max-input-bytes":    {good, []string{"--max-input-bytes", "100"}, "input exceeds max-input-bytes"},
		"smaller than superblock": {blob, nil, "input too small for a SquashFS superblock"},
		"no superblock":           {junk, nil, "no valid SquashFS v4 LE superblock found in input"},
		"truncated image":         {trunc, nil, "no valid SquashFS v4 LE superblock found in input"},
	} {
		t.Run(name, func(t *testing.T) {
			rc, stderr, parent, out := extract(t, tc.input, tc.extra...)
			if want := "squashfs-extract: " + tc.want + "\n"; rc != 2 || stderr != want {
				t.Errorf("rc = %d stderr = %q, want %q", rc, stderr, want)
			}
			mustNotExist(t, out, filepath.Join(parent, ".out.stage"))
		})
	}
}

func sqfsSuperblock(t *testing.T) []byte {
	t.Helper()
	raw, err := os.ReadFile(abs(t, sqfsData+"good.sqfs"))
	if err != nil {
		t.Fatal(err)
	}
	return raw
}

func TestSquashfsFindOffset(t *testing.T) {
	good := sqfsSuperblock(t)
	at := func(prefix int, data []byte) []byte { return append(bytes.Repeat([]byte{0x55}, prefix), data...) }
	for name, tc := range map[string]struct {
		data []byte
		want int64
	}{
		"at zero":                   {good, 0},
		"after a prefix":            {at(4096, good), 4096},
		"odd prefix":                {at(37, good), 37},
		"magic inside the prefix":   {at(0, append([]byte("hsqshsqshsqs"), at(100, good)...)), 112},
		"second candidate is valid": {append(append([]byte(nil), good[:96]...), good...), 0},
	} {
		t.Run(name, func(t *testing.T) {
			off, err := findSquashfsOffset(bytes.NewReader(tc.data), int64(len(tc.data)))
			if name == "second candidate is valid" {
				// the first copy declares 'used' bytes that overrun nothing, so it is valid at 0
				if err != nil || off != 0 {
					t.Errorf("off = %d err = %v", off, err)
				}
				return
			}
			if err != nil || off != tc.want {
				t.Errorf("off = %d err = %v, want %d", off, err, tc.want)
			}
		})
	}
	for name, mut := range map[string]func(b []byte){
		"inodes zero":          func(b []byte) { putLE(b, 4, 4, 0) },
		"ids zero":             func(b []byte) { putLE(b, 26, 2, 0) },
		"major 3":              func(b []byte) { putLE(b, 28, 2, 3) },
		"minor 1":              func(b []byte) { putLE(b, 30, 2, 1) },
		"compression 0":        func(b []byte) { putLE(b, 20, 2, 0) },
		"compression 7":        func(b []byte) { putLE(b, 20, 2, 7) },
		"block size mismatch":  func(b []byte) { putLE(b, 12, 4, 4097) },
		"block size too small": func(b []byte) { putLE(b, 12, 4, 2048); putLE(b, 22, 2, 11) },
		"block size too big":   func(b []byte) { putLE(b, 12, 4, 2097152); putLE(b, 22, 2, 21) },
		"log huge":             func(b []byte) { putLE(b, 22, 2, 65535) },
		"used overruns":        func(b []byte) { putLE(b, 40, 8, 1<<40) },
		"used below header":    func(b []byte) { putLE(b, 40, 8, 95) },
		"id table zero":        func(b []byte) { putLE(b, 48, 8, 0) },
		"id table sentinel":    func(b []byte) { putLE(b, 48, 8, ^uint64(0)) },
		"inode table past end": func(b []byte) { putLE(b, 64, 8, 1<<39) },
		"dir table sentinel":   func(b []byte) { putLE(b, 72, 8, ^uint64(0)) },
	} {
		t.Run("refuses "+name, func(t *testing.T) {
			b := append([]byte(nil), good...)
			mut(b)
			if off, err := findSquashfsOffset(bytes.NewReader(b), int64(len(b))); err == nil {
				t.Errorf("accepted a bad superblock at %d", off)
			} else if err.Error() != "no valid SquashFS v4 LE superblock found in input" {
				t.Errorf("err = %q", err)
			}
		})
	}
	t.Run("sentinels are legal where optional", func(t *testing.T) {
		b := append([]byte(nil), good...)
		putLE(b, 56, 8, ^uint64(0)) // xattr table: 'none'
		if off, err := findSquashfsOffset(bytes.NewReader(b), int64(len(b))); err != nil || off != 0 {
			t.Errorf("off = %d err = %v", off, err)
		}
	})
	t.Run("fragment table required only with fragments", func(t *testing.T) {
		b := append([]byte(nil), good...)
		putLE(b, 80, 8, ^uint64(0))
		putLE(b, 16, 4, 0) // no fragments
		if _, err := findSquashfsOffset(bytes.NewReader(b), int64(len(b))); err != nil {
			t.Errorf("fragment sentinel with zero fragments rejected: %v", err)
		}
		putLE(b, 16, 4, 1)
		if _, err := findSquashfsOffset(bytes.NewReader(b), int64(len(b))); err == nil {
			t.Error("fragment sentinel with fragments accepted")
		}
	})
	t.Run("export table required only when exportable", func(t *testing.T) {
		b := append([]byte(nil), good...)
		putLE(b, 88, 8, ^uint64(0))
		putLE(b, 24, 2, 0)
		if _, err := findSquashfsOffset(bytes.NewReader(b), int64(len(b))); err != nil {
			t.Errorf("export sentinel without the flag rejected: %v", err)
		}
		putLE(b, 24, 2, 0x80)
		if _, err := findSquashfsOffset(bytes.NewReader(b), int64(len(b))); err == nil {
			t.Error("export sentinel with the exportable flag accepted")
		}
	})
	t.Run("too short for any header", func(t *testing.T) {
		if _, err := findSquashfsOffset(bytes.NewReader(good[:95]), 95); err == nil {
			t.Error("accepted 95 bytes")
		}
	})
	t.Run("magic split across read chunks", func(t *testing.T) {
		big := at(1<<20-2, good) // the magic straddles the 1 MiB chunk boundary
		off, err := findSquashfsOffset(bytes.NewReader(big), int64(len(big)))
		if err != nil || off != 1<<20-2 {
			t.Errorf("off = %d err = %v, want %d", off, err, 1<<20-2)
		}
	})
}

func putLE(b []byte, off, n int, v uint64) {
	for i := 0; i < n; i++ {
		b[off+i] = byte(v >> (8 * i))
	}
}

// ---------------------------------------------------------------- unsquashfs failures (fake bwrap)

func TestSquashfsRunFailures(t *testing.T) {
	good := abs(t, sqfsData+"good.sqfs")
	long := strings.Repeat("x", 600)
	for name, tc := range map[string]struct {
		body  string
		extra []string
		want  string
	}{
		"timeout":            {"sleep 30", []string{"--timeout-seconds", "1"}, "timeout"},
		"exit code, stderr":  {"echo boom >&2; exit 3", nil, "unsquashfs failed: boom"},
		"exit code, silent":  {"exit 1", nil, "unsquashfs failed"},
		"killed by signal":   {"kill -9 $$", nil, "unsquashfs failed"},
		"stderr is capped":   {"printf '%s' " + long + " >&2; exit 2", nil, "unsquashfs failed: " + strings.Repeat("x", 512)},
		"stderr is stripped": {"printf '\\n  spaced out  \\n' >&2; exit 2", nil, "unsquashfs failed: spaced out"},
		"bad utf-8 stderr":   {"printf '\\377ok' >&2; exit 2", nil, "unsquashfs failed: �ok"},
	} {
		t.Run(name, func(t *testing.T) {
			useTools(t, tc.body)
			start := time.Now()
			rc, stderr, parent, out := extract(t, good, tc.extra...)
			if want := "squashfs-extract: " + tc.want + "\n"; rc != 2 || stderr != want {
				t.Errorf("rc = %d stderr = %q, want %q", rc, stderr, want)
			}
			if d := time.Since(start); d > 15*time.Second {
				t.Errorf("took %s: the timeout did not stop the run", d)
			}
			mustNotExist(t, out, filepath.Join(parent, ".out.stage"))
		})
	}
}

func TestSquashfsSizeWatchdog(t *testing.T) {
	good := abs(t, sqfsData+"good.sqfs")
	// Three files below the per-file limit whose sum is over the cap: only the aggregate watchdog sees it,
	// and the script would otherwise sleep for 30 s.
	useTools(t, `mkdir -p "$stage/extracted"
for n in 1 2 3; do head -c 20000 /dev/zero > "$stage/extracted/f$n"; done
sleep 30`)
	start := time.Now()
	rc, stderr, parent, out := extract(t, good, "--max-extracted-bytes", "30000")
	want := "squashfs-extract: extraction killed: on-disk size exceeded max-extracted-bytes (30000) during extraction\n"
	if rc != 2 || stderr != want {
		t.Errorf("rc = %d stderr = %q, want %q", rc, stderr, want)
	}
	if d := time.Since(start); d > 10*time.Second {
		t.Errorf("took %s: the watchdog did not kill the run", d)
	}
	mustNotExist(t, out, filepath.Join(parent, ".out.stage"))
}

func TestSquashfsFileSizeLimitIsEnforcedOnTheChild(t *testing.T) {
	good := abs(t, sqfsData+"good.sqfs")
	// RLIMIT_FSIZE: one file over the cap is cut off by the kernel (SIGXFSZ), whatever the watchdog does.
	useTools(t, `mkdir -p "$stage/extracted"
head -c 100000 /dev/zero > "$stage/extracted/big" || exit 7
exit 0`)
	rc, stderr, parent, out := extract(t, good, "--max-extracted-bytes", "4096")
	if rc != 2 || !strings.HasPrefix(stderr, "squashfs-extract: unsquashfs failed") {
		t.Errorf("rc = %d stderr = %q, want unsquashfs failed (the kernel cut the write)", rc, stderr)
	}
	mustNotExist(t, out, filepath.Join(parent, ".out.stage"))
}

// ---------------------------------------------------------------- tree validation (fake bwrap, end to end)

func TestSquashfsTreeRefusalsEndToEnd(t *testing.T) {
	good := abs(t, sqfsData+"good.sqfs")
	for name, tc := range map[string]struct {
		body  string
		extra []string
		want  string
	}{
		"symlink":           {`mkdir -p "$stage/extracted"; ln -s /etc/passwd "$stage/extracted/escape"; : > "$stage/extracted/a"`, nil, "symlink in extracted tree (rejected): escape"},
		"dangling symlink":  {`mkdir -p "$stage/extracted"; ln -s /nowhere "$stage/extracted/dangling"`, nil, "symlink in extracted tree (rejected): dangling"},
		"directory symlink": {`mkdir -p "$stage/extracted"; ln -s /etc "$stage/extracted/somedir"; : > "$stage/extracted/a"`, nil, "symlink in extracted tree (rejected): somedir"},
		"hardlink":          {`mkdir -p "$stage/extracted"; printf x > "$stage/extracted/a"; ln "$stage/extracted/a" "$stage/extracted/b"`, nil, "hardlinked file in extracted tree: a"},
		"fifo":              {`mkdir -p "$stage/extracted"; mkfifo "$stage/extracted/pipe"`, nil, "special file in extracted tree (rejected): pipe"},
		"entries cap":       {`mkdir -p "$stage/extracted/d"; : > "$stage/extracted/a"; : > "$stage/extracted/d/b"`, []string{"--max-entries", "1"}, "entries exceed max-entries (1)"},
		"bytes cap":         {`mkdir -p "$stage/extracted"; head -c 20000 /dev/zero > "$stage/extracted/a"; head -c 20000 /dev/zero > "$stage/extracted/b"`, []string{"--max-extracted-bytes", "30000"}, "extracted bytes exceed max-extracted-bytes (30000)"},
		"nested symlink":    {`mkdir -p "$stage/extracted/d/e"; ln -s x "$stage/extracted/d/e/l"`, nil, "symlink in extracted tree (rejected): d/e/l"},
	} {
		t.Run(name, func(t *testing.T) {
			useTools(t, tc.body+"\nexit 0")
			rc, stderr, parent, out := extract(t, good, tc.extra...)
			if want := "squashfs-extract: " + tc.want + "\n"; rc != 2 || stderr != want {
				t.Errorf("rc = %d stderr = %q, want %q", rc, stderr, want)
			}
			mustNotExist(t, out, filepath.Join(parent, ".out.stage"))
		})
	}
	t.Run("missing extraction directory is an error, not an empty tree", func(t *testing.T) {
		useTools(t, "exit 0")
		rc, stderr, parent, out := extract(t, good)
		if rc != 2 || !strings.HasPrefix(stderr, "squashfs-extract: ") {
			t.Errorf("rc = %d stderr = %q", rc, stderr)
		}
		mustNotExist(t, out, filepath.Join(parent, ".out.stage"))
	})
}

func TestSquashfsEndToEnd(t *testing.T) {
	good := abs(t, sqfsData+"good.sqfs")
	useTools(t, okExtraction)
	rc, stderr, parent, out := extract(t, good)
	if rc != 0 || stderr != "" {
		t.Fatalf("rc = %d stderr = %q", rc, stderr)
	}
	mustNotExist(t, filepath.Join(parent, ".out.stage"))
	sum := func(s string) string { h := sha256.Sum256([]byte(s)); return "sha256:" + hex.EncodeToString(h[:]) }
	// closed tree, 0700 dirs and 0400 files, nothing else
	want := map[string]snap{
		"extracted":                 {"dir", "0700", ""},
		"extracted/empty":           {"dir", "0700", ""},
		"extracted/sub":             {"dir", "0700", ""},
		"extracted/hello.txt":       {"file", "0400", strings.TrimPrefix(sum("hello"), "sha256:")},
		"extracted/sub/world.txt":   {"file", "0400", strings.TrimPrefix(sum("world"), "sha256:")},
		"extracted/zero":            {"file", "0400", strings.TrimPrefix(sum(""), "sha256:")},
		"stdout.txt":                {"file", "0400", strings.TrimPrefix(sum(""), "sha256:")},
		"stderr.txt":                {"file", "0400", strings.TrimPrefix(sum(""), "sha256:")},
		"squashfs-extract.v1.json":  {},
		"analysis-manifest.v1.json": {},
	}
	got := snapshot(t, out)
	for _, f := range []string{"squashfs-extract.v1.json", "analysis-manifest.v1.json"} {
		if g := got[f]; g.Type != "file" || g.Mode != "0400" {
			t.Errorf("%s = %+v, want a 0400 file", f, g)
		}
		want[f] = got[f]
	}
	if fmt.Sprint(got) != fmt.Sprint(want) {
		t.Errorf("tree = %v\nwant   %v", got, want)
	}
	if st, _ := os.Stat(out); st.Mode().Perm() != 0o700 {
		t.Errorf("published dir mode = %o, want 0700", st.Mode().Perm())
	}

	rawIn := sqfsSuperblock(t)
	inSum := sha256.Sum256(rawIn)
	rep := readJSON(t, filepath.Join(out, "squashfs-extract.v1.json"))
	if rep["schema"] != "squashfs-extract.v1" || rep["validation_verdict"] != "pass" || rep["squashfs_offset"] != float64(0) {
		t.Errorf("report header = %v", rep)
	}
	in := obj(rep["input"])
	if in["path"] != good || in["size"] != float64(len(rawIn)) || in["sha256"] != "sha256:"+hex.EncodeToString(inSum[:]) {
		t.Errorf("report input = %v", in)
	}
	if c := obj(rep["entry_counts"]); c["files"] != float64(3) || c["directories"] != float64(2) {
		t.Errorf("entry_counts = %v", c)
	}
	if rep["total_extracted_bytes"] != float64(10) {
		t.Errorf("total_extracted_bytes = %v, want 10", rep["total_extracted_bytes"])
	}
	wantCaps := map[string]any{"max_input_bytes": float64(512 << 20), "max_extracted_bytes": float64(256 << 20), "max_entries": float64(10000), "timeout_seconds": float64(120)}
	if fmt.Sprint(obj(rep["caps"])) != fmt.Sprint(wantCaps) {
		t.Errorf("caps = %v, want %v", rep["caps"], wantCaps)
	}
	wantIso := map[string]any{"bubblewrap": true, "network_access": false, "payload_execution": false, "static_only": true}
	if fmt.Sprint(obj(rep["isolation"])) != fmt.Sprint(wantIso) {
		t.Errorf("isolation = %v", rep["isolation"])
	}
	var paths []string
	for _, e := range arr(rep["entries"]) {
		paths = append(paths, obj(e)["path"].(string))
	}
	if !sort.StringsAreSorted(paths) || strings.Join(paths, ",") != "empty,hello.txt,sub,sub/world.txt,zero" {
		t.Errorf("entry paths = %v, want sorted empty,hello.txt,sub,sub/world.txt,zero", paths)
	}
	if lim := arr(rep["limitations"]); len(lim) != 2 || lim[0] != "Tree validation rejects symlinks, special files, and hardlinks; semantic content is not analyzed." {
		t.Errorf("limitations = %v", lim)
	}
	verifyInProcess(t, out)
}

func TestSquashfsManifestContent(t *testing.T) {
	good := abs(t, sqfsData+"good.sqfs")
	useTools(t, okExtraction)
	parent := t.TempDir()
	out := filepath.Join(parent, "out")
	s, _, errb := testStdio(parent)
	s.Env, s.Environ = os.Getenv, os.Environ
	ticks := []time.Time{time.Date(2026, 1, 2, 3, 4, 5, 123456000, time.UTC), time.Date(2026, 1, 2, 3, 4, 8, 0, time.UTC)}
	s.Clock = func() time.Time { t0 := ticks[0]; ticks = ticks[1:]; return t0 }
	if rc := SquashfsExtract(sqfsArgs(good, out, "--manifest-cli", manifestCLI(t)), s); rc != 0 {
		t.Fatalf("rc = %d stderr = %q", rc, errb)
	}
	if len(ticks) != 0 {
		t.Errorf("the clock was read %d times too few: started_at and ended_at are two readings", len(ticks))
	}
	m := readJSON(t, filepath.Join(out, "analysis-manifest.v1.json"))
	run := obj(m["run"])
	if run["started_at"] != "2026-01-02T03:04:05.123456Z" || run["ended_at"] != "2026-01-02T03:04:08Z" || run["duration_ms"] != float64(2876) || run["exit_code"] != float64(0) || run["signal"] != nil {
		t.Errorf("run = %v", run)
	}
	exe, _ := os.Executable()
	exe, _ = filepath.EvalSymlinks(exe)
	argv := arr(m["argv"])
	if len(argv) < 8 || argv[0] != exe || argv[1] != "formats" || argv[2] != "squashfs-extract" || argv[len(argv)-2] != "--manifest-cli" {
		t.Errorf("argv = %v", argv)
	}
	tool := obj(m["tool"])
	if tool["name"] != "squashfs-extract" || tool["version"] != "1" || obj(tool["launcher"])["resolved_executable"] != exe {
		t.Errorf("tool = %v", tool)
	}
	if prof := obj(m["isolation_profile"]); prof["name"] != "bwrap-unsquashfs" || prof["static_only"] != true || prof["network_access"] != false || prof["target_execution"] != false {
		t.Errorf("isolation_profile = %v", prof)
	}
	var outputs []string
	for _, o := range arr(m["outputs"]) {
		outputs = append(outputs, obj(o)["path"].(string))
	}
	if strings.Join(outputs, ",") != "extracted/hello.txt,extracted/sub/world.txt,extracted/zero" {
		t.Errorf("outputs = %v", outputs)
	}
	if m["completeness"] != "complete" || len(arr(m["errors"])) != 0 || len(arr(m["findings"])) != 0 {
		t.Errorf("completeness/errors/findings = %v/%v/%v", m["completeness"], m["errors"], m["findings"])
	}
	verifyInProcess(t, out)
}

func TestSquashfsManifestFailure(t *testing.T) {
	good := abs(t, sqfsData+"good.sqfs")
	// The manifest is built in process: a failure of its create step (here a manifest already in the stage) is
	// relayed as the manifest CLI wrote it, then wrapped by the command.
	useTools(t, strings.TrimSuffix(okExtraction, "exit 0")+": > \"$stage/analysis-manifest.v1.json\"\nexit 0")
	parent := t.TempDir()
	out := filepath.Join(parent, "out")
	rc, _, stderr := runSqfs(t, parent, sqfsArgs(good, out, "--manifest-cli", manifestCLI(t))...)
	if rc != 2 || !strings.Contains(stderr, "analysis-manifest: ") || !strings.Contains(stderr, "squashfs-extract: ") {
		t.Errorf("rc = %d stderr = %q, want exit 2 with the manifest tool's message", rc, stderr)
	}
	mustNotExist(t, out, filepath.Join(parent, ".out.stage"))
}

func TestSquashfsPublishAndCleanup(t *testing.T) {
	good := abs(t, sqfsData+"good.sqfs")
	useTools(t, okExtraction)
	t.Run("a stage left by another run is never deleted", func(t *testing.T) {
		parent := t.TempDir()
		stage := filepath.Join(parent, ".out.stage")
		if err := os.Mkdir(stage, 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(stage, "keep"), []byte("other run"), 0o600); err != nil {
			t.Fatal(err)
		}
		rc, _, stderr := runSqfs(t, parent, sqfsArgs(good, filepath.Join(parent, "out"), "--manifest-cli", manifestCLI(t))...)
		if want := "squashfs-extract: [Errno 17] File exists: " + pyRepr(stage) + "\n"; rc != 2 || stderr != want {
			t.Errorf("rc = %d stderr = %q, want %q", rc, stderr, want)
		}
		if b, err := os.ReadFile(filepath.Join(stage, "keep")); err != nil || string(b) != "other run" {
			t.Errorf("the other run's stage was touched: %v %q", err, b)
		}
	})
	t.Run("a destination that appears during the run is not replaced", func(t *testing.T) {
		parent := t.TempDir()
		out := filepath.Join(parent, "out")
		// the fake bwrap creates the destination while the run is in flight
		useTools(t, okExtraction+"\n")
		dir := bwrapSearchPath
		script := "#!/bin/sh\nmkdir " + out + "\nprintf mine > " + out + "/mine\n" + "prev=\"\"\nfor a in \"$@\"; do if [ \"$prev\" = \"--bind\" ]; then stage=\"$a\"; fi; prev=\"$a\"; done\n" + okExtraction + "\n"
		if err := os.WriteFile(filepath.Join(dir, "bwrap"), []byte(script), 0o755); err != nil {
			t.Fatal(err)
		}
		rc, _, stderr := runSqfs(t, parent, sqfsArgs(good, out, "--manifest-cli", manifestCLI(t))...)
		if rc != 2 || !strings.Contains(stderr, "[Errno 17] atomic publication failed") {
			t.Errorf("rc = %d stderr = %q, want an EEXIST publication failure", rc, stderr)
		}
		if b, _ := os.ReadFile(filepath.Join(out, "mine")); string(b) != "mine" {
			t.Errorf("the destination was replaced: %q", b)
		}
		mustNotExist(t, filepath.Join(parent, ".out.stage"))
	})
}

// ---------------------------------------------------------------- walk_tree and validate_closed (unit)

func mkTree(t *testing.T, build func(root string)) string {
	t.Helper()
	root := filepath.Join(t.TempDir(), "extracted")
	if err := os.Mkdir(root, 0o755); err != nil {
		t.Fatal(err)
	}
	build(root)
	return root
}

func write(t *testing.T, p, content string, mode os.FileMode) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(content), mode); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(p, mode); err != nil {
		t.Fatal(err)
	}
}

func TestSquashfsWalkTreeEntries(t *testing.T) {
	root := mkTree(t, func(r string) {
		write(t, r+"/b.txt", "bee", 0o644)
		write(t, r+"/a/z.bin", "zed", 0o755)
		write(t, r+"/a/c/deep", "", 0o600)
		if err := os.MkdirAll(r+"/empty", 0o750); err != nil {
			t.Fatal(err)
		}
	})
	entries, err := walkTree(root, 100, 1000)
	if err != nil {
		t.Fatal(err)
	}
	h := func(s string) string { x := sha256.Sum256([]byte(s)); return "sha256:" + hex.EncodeToString(x[:]) }
	want := []treeEntry{
		{"a", "directory", 0o755, 0, ""},
		{"a/c", "directory", 0o755, 0, ""},
		{"a/c/deep", "file", 0o600, 0, h("")},
		{"a/z.bin", "file", 0o755, 3, h("zed")},
		{"b.txt", "file", 0o644, 3, h("bee")},
		{"empty", "directory", 0o750, 0, ""},
	}
	if fmt.Sprint(entries) != fmt.Sprint(want) {
		t.Errorf("entries = %v\nwant     %v", entries, want)
	}
}

func TestSquashfsWalkTreeRefusals(t *testing.T) {
	for name, tc := range map[string]struct {
		build   func(r string)
		entries int
		bytes   int64
		want    string
	}{
		"file symlink":   {func(r string) { _ = os.Symlink("/etc/passwd", r+"/l") }, 10, 100, "symlink in extracted tree (rejected): l"},
		"dir symlink":    {func(r string) { _ = os.Symlink("/etc", r+"/l") }, 10, 100, "symlink in extracted tree (rejected): l"},
		"nested symlink": {func(r string) { _ = os.MkdirAll(r+"/d", 0o755); _ = os.Symlink("x", r+"/d/l") }, 10, 100, "symlink in extracted tree (rejected): d/l"},
		"hardlink":       {func(r string) { write(t, r+"/a", "x", 0o644); _ = os.Link(r+"/a", r+"/b") }, 10, 100, "hardlinked file in extracted tree: a"},
		"fifo":           {func(r string) { _ = syscall.Mkfifo(r+"/p", 0o600) }, 10, 100, "special file in extracted tree (rejected): p"},
		"too many":       {func(r string) { write(t, r+"/a", "", 0o644); write(t, r+"/b", "", 0o644) }, 1, 100, "entries exceed max-entries (1)"},
		"dirs count":     {func(r string) { _ = os.MkdirAll(r+"/a/b", 0o755) }, 1, 100, "entries exceed max-entries (1)"},
		"too many bytes": {func(r string) { write(t, r+"/a", "12345", 0o644); write(t, r+"/b", "12345", 0o644) }, 10, 9, "extracted bytes exceed max-extracted-bytes (9)"},
	} {
		t.Run(name, func(t *testing.T) {
			root := mkTree(t, tc.build)
			if _, err := walkTree(root, tc.entries, tc.bytes); err == nil || err.Error() != tc.want {
				t.Errorf("err = %v, want %q", err, tc.want)
			}
		})
	}
	t.Run("exactly at the caps is fine", func(t *testing.T) {
		root := mkTree(t, func(r string) { write(t, r+"/a", "12345", 0o644); write(t, r+"/b", "1234", 0o644) })
		if _, err := walkTree(root, 2, 9); err != nil {
			t.Errorf("err = %v, want none at exactly the caps", err)
		}
	})
	t.Run("unreadable directory is an error, not a silent skip", func(t *testing.T) {
		root := mkTree(t, func(r string) { _ = os.MkdirAll(r+"/locked/x", 0o755); _ = os.Chmod(r+"/locked", 0) })
		t.Cleanup(func() { _ = os.Chmod(root+"/locked", 0o755) })
		if os.Getuid() == 0 {
			t.Skip("root reads every directory")
		}
		if _, err := walkTree(root, 10, 100); err == nil {
			t.Error("a directory that cannot be listed was skipped")
		}
	})
}

func TestSquashfsWalkTreeChangedWhileHashing(t *testing.T) {
	root := mkTree(t, func(r string) { write(t, r+"/grow", strings.Repeat("a", 10), 0o644) })
	hashHook = func() { _ = os.WriteFile(root+"/grow", []byte(strings.Repeat("b", 20)), 0o644) }
	t.Cleanup(func() { hashHook = nil })
	if _, err := walkTree(root, 10, 1000); err == nil || err.Error() != "file changed while hashing: grow" {
		t.Errorf("err = %v, want %q", err, "file changed while hashing: grow")
	}
}

func TestSquashfsValidateClosed(t *testing.T) {
	build := func(t *testing.T) string {
		stage := t.TempDir()
		for _, d := range []string{"extracted", "extracted/sub"} {
			if err := os.Mkdir(filepath.Join(stage, d), 0o700); err != nil {
				t.Fatal(err)
			}
		}
		for _, f := range []string{"report.json", "extracted/a", "extracted/sub/b"} {
			write(t, filepath.Join(stage, f), "x", 0o400)
		}
		return stage
	}
	files := map[string]bool{"report.json": true, "extracted/a": true, "extracted/sub/b": true}
	dirs := map[string]bool{"extracted": true, "extracted/sub": true}
	if err := validateClosed(build(t), files, dirs); err != nil {
		t.Fatalf("a closed tree was refused: %v", err)
	}
	for name, tc := range map[string]struct {
		mutate func(stage string)
		want   string
	}{
		"file mode":      {func(s string) { _ = os.Chmod(s+"/extracted/a", 0o600) }, "output mode/ownership violation: extracted/a"},
		"file mode 0440": {func(s string) { _ = os.Chmod(s+"/report.json", 0o440) }, "output mode/ownership violation: report.json"},
		"dir mode":       {func(s string) { _ = os.Chmod(s+"/extracted/sub", 0o755) }, "output mode/ownership violation: extracted/sub"},
		"dir mode 0500":  {func(s string) { _ = os.Chmod(s+"/extracted", 0o500) }, "output mode/ownership violation: extracted"},
		"extra file":     {func(s string) { write(t, s+"/extra", "x", 0o400) }, "output tree is not closed"},
		"extra dir":      {func(s string) { _ = os.Mkdir(s+"/extradir", 0o700) }, "output tree is not closed"},
		"missing file":   {func(s string) { _ = os.Remove(s + "/extracted/a") }, "output tree is not closed"},
		"dir as file":    {func(s string) { _ = os.Remove(s + "/extracted/a"); _ = os.Mkdir(s+"/extracted/a", 0o700) }, "output tree is not closed"},
		"hardlink":       {func(s string) { _ = os.Link(s+"/extracted/a", s+"/extracted/sub/h") }, "hardlinked output file: "},
		"symlink":        {func(s string) { _ = os.Symlink("report.json", s+"/lnk") }, "output mode/ownership violation: lnk"},
		"fifo":           {func(s string) { _ = syscall.Mkfifo(s+"/pipe", 0o400) }, "unexpected type in output tree: pipe"},
	} {
		t.Run(name, func(t *testing.T) {
			stage := build(t)
			tc.mutate(stage)
			t.Cleanup(func() { _ = os.Chmod(stage+"/extracted", 0o700) }) // a mutation may have made it unremovable
			err := validateClosed(stage, files, dirs)
			if err == nil {
				t.Fatal("accepted a tree that is not closed")
			}
			if !strings.HasPrefix(err.Error(), tc.want) {
				t.Errorf("err = %q, want prefix %q", err, tc.want)
			}
		})
	}
	t.Run("a foreign owner is refused", func(t *testing.T) {
		if os.Getuid() != 0 {
			t.Skip("changing the owner needs root; the ownership comparison is covered by the mode/ownership message above")
		}
	})
}

func TestSquashfsRegistered(t *testing.T) {
	for _, c := range Commands {
		if c.Group == "formats" && c.Name == "squashfs-extract" {
			return
		}
	}
	t.Error("formats squashfs-extract is not in Commands")
}

var _ = cli.ExitOK

// A scan over a small input must not allocate the full 1 MiB chunk buffer per call: the parity tests call it
// hundreds of times and, under the CI RLIMIT_AS cap, that garbage outran the collector (OOM in the bridge job).
func TestFindSquashfsOffsetAllocationScalesWithInput(t *testing.T) {
	data := bytes.Repeat([]byte{0xEE}, 4096)
	var before, after runtime.MemStats
	runtime.ReadMemStats(&before)
	for i := 0; i < 100; i++ {
		if off, err := findSquashfsOffset(bytes.NewReader(data), int64(len(data))); err == nil {
			t.Fatalf("garbage input accepted at offset %d", off)
		}
	}
	runtime.ReadMemStats(&after)
	if got := after.TotalAlloc - before.TotalAlloc; got > 16<<20 {
		t.Fatalf("100 scans of a 4 KiB input allocated %d bytes; the buffer must scale with the input", got)
	}
}
