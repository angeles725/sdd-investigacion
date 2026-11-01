package formats

import (
	"fmt"
	"io"
	"io/fs"
	"math/big"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
	"unicode"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/fsx"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/proc"
)

// The helpers below are what zip_metadata.py and zip_stored.py each carried a private copy of: the output
// path policy, the staged closed tree, the analysis-manifest hand-off and the no-replace publication.

// zipCreds are the process ids the privilege guard reads; a test replaces it.
var zipCreds = func() (uid, euid, gid, egid int) {
	return os.Getuid(), os.Geteuid(), os.Getgid(), os.Getegid()
}

// zipRefusePrivileged is adapter_core.refuse_privileged_execution: root and set-id execution are refused.
func zipRefusePrivileged() error {
	uid, euid, gid, egid := zipCreds()
	if euid == 0 || uid != euid || gid != egid {
		return &ZipError{Msg: "refusing root or set-id execution"}
	}
	return nil
}

// zipPrivateFS is the allowlist of Linux-private filesystems an output may live on.
var zipPrivateFS = map[string]bool{
	"btrfs": true, "ext2": true, "ext3": true, "ext4": true, "f2fs": true, "jfs": true, "nilfs2": true, "overlay": true,
	"ramfs": true, "reiserfs": true, "tmpfs": true, "ubifs": true, "xfs": true, "zfs": true,
}

// zipMountinfo reads the mount table; a test replaces it.
var zipMountinfo = func() (string, error) {
	b, err := os.ReadFile("/proc/self/mountinfo")
	return string(b), err
}

// pathParts is pathlib's parts of an absolute-or-relative path: "." and empty components are dropped,
// ".." is kept.
func pathParts(p string) (abs bool, parts []string) {
	abs = strings.HasPrefix(p, "/")
	for _, c := range strings.Split(p, "/") {
		if c != "" && c != "." {
			parts = append(parts, c)
		}
	}
	return abs, parts
}

func joinParts(abs bool, parts []string) string {
	switch {
	case abs:
		return "/" + strings.Join(parts, "/")
	case len(parts) == 0:
		return "."
	}
	return strings.Join(parts, "/")
}

// pyName is Path(p).name.
func pyName(p string) string {
	_, parts := pathParts(p)
	if len(parts) == 0 {
		return ""
	}
	return parts[len(parts)-1]
}

// pyParent is Path(p).parent.
func pyParent(p string) string {
	abs, parts := pathParts(p)
	if len(parts) > 0 {
		parts = parts[:len(parts)-1]
	}
	out := joinParts(abs, parts)
	if strings.HasPrefix(p, "//") && !strings.HasPrefix(p, "///") {
		out = "/" + out // POSIX keeps exactly two leading slashes, and so does pathlib
	}
	return out
}

// zipPrivateFSCheck is private_fs: the deepest mount that contains path decides, by filesystem type.
// A line without " - " or with fewer than five left fields does not describe a mount and is skipped.
func zipPrivateFSCheck(path, mountinfo string) error {
	_, target := pathParts(path)
	depth, fstype := -1, ""
	for _, line := range strings.Split(mountinfo, "\n") {
		left, right, ok := strings.Cut(line, " - ")
		if !ok {
			continue
		}
		lf := strings.Fields(left)
		if len(lf) < 5 {
			continue
		}
		mabs, mount := pathParts(lf[4])
		if !mabs && len(mount) > 0 || !underParts(target, mount) {
			continue
		}
		rf := strings.Fields(right)
		if len(rf) == 0 {
			return &ZipError{Msg: "malformed mountinfo line"}
		}
		if len(mount)+1 > depth {
			depth, fstype = len(mount)+1, rf[0]
		}
	}
	if !zipPrivateFS[fstype] {
		return &ZipError{Msg: "output must reside on a Linux-private filesystem"}
	}
	return nil
}

func underParts(path, mount []string) bool {
	if len(mount) > len(path) {
		return false
	}
	for i := range mount {
		if path[i] != mount[i] {
			return false
		}
	}
	return true
}

// zipOutputParent resolves the directory the output goes into: no symlinked component, an existing
// directory, on a private filesystem. It returns the resolved parent.
func zipOutputParent(output, cwd string) (string, error) {
	lexical := pyParent(output)
	if !strings.HasPrefix(lexical, "/") {
		lexical = cwd + "/" + lexical
	}
	lexical = filepath.Clean(lexical)
	probe := ""
	_, parts := pathParts(lexical)
	for _, part := range parts {
		probe += "/" + part
		if fi, err := os.Lstat(probe); err == nil && fi.Mode()&fs.ModeSymlink != 0 {
			return "", &ZipError{Msg: "output parent links are unsupported"}
		}
	}
	parent, err := filepath.EvalSymlinks(lexical)
	if err != nil {
		return "", err
	}
	mi, err := zipMountinfo()
	if err != nil {
		return "", err
	}
	if err := zipPrivateFSCheck(parent, mi); err != nil {
		return "", err
	}
	return parent, nil
}

// zipOwnedParent reports whether parent is a directory owned by this user that neither group nor world may
// write to.
func zipOwnedParent(parent string) (bool, error) {
	fi, err := os.Stat(parent)
	if err != nil {
		return false, err
	}
	uid, _, ok := zipOwnerOf(fi)
	return fi.IsDir() && ok && int(uid) == zipGetuid() && fi.Mode().Perm()&0o022 == 0, nil
}

// zipExists is Path.exists() or Path.is_symlink(): anything at the path, a dangling link included.
func zipExists(path string) bool {
	_, err := os.Lstat(path)
	return err == nil
}

// zipStage creates the staging directory next to the destination. An existing path of that name is never
// adopted: Mkdir fails.
func zipStage(parent, name string) (stage string, root *os.Root, err error) {
	stage = parent + "/." + name + ".stage"
	if err := os.Mkdir(stage, 0o700); err != nil {
		return "", nil, err
	}
	root, err = os.OpenRoot(stage)
	if err != nil {
		_ = os.RemoveAll(stage)
		return "", nil, err
	}
	return stage, root, nil
}

// zipCreate writes data to a new owner-read-only file, exclusively, and syncs it.
func zipCreate(root *os.Root, name string, data []byte) error {
	f, err := root.OpenFile(name, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o400)
	if err != nil {
		return err
	}
	if _, err := f.Write(data); err != nil {
		_ = f.Close()
		return err
	}
	if err := f.Sync(); err != nil {
		_ = f.Close()
		return err
	}
	return f.Close()
}

// zipISONow is datetime.now(timezone.utc).isoformat() with "+00:00" replaced by "Z": microsecond precision,
// the fraction omitted when it is zero.
func zipISONow(t time.Time) string {
	t = t.UTC()
	s := t.Format("2006-01-02T15:04:05")
	if us := t.Nanosecond() / 1000; us != 0 {
		s += fmt.Sprintf(".%06d", us)
	}
	return s + "Z"
}

// zipRunManifest runs `python3 <manifest-cli> <verb> ...` (the trusted analysis_manifest tool). Its output
// is relayed; a non-zero exit is an error.
func zipRunManifest(s cli.Stdio, manifestCLI string, args ...string) error {
	env := s.Environ()
	argv := append([]string{"python3", manifestCLI}, args...)
	res, err := proc.Run(proc.Spec{Argv: argv, Dir: s.Cwd, Env: env, Timeout: 10 * time.Minute, MaxBytes: 16 << 20})
	if err != nil {
		return err
	}
	_, _ = s.Out.Write(res.Stdout)
	_, _ = s.Err.Write(res.Stderr)
	if res.Reason != "" || res.ReturnCode != 0 {
		return fmt.Errorf("analysis manifest %s failed (exit status %d, stop reason %q)", verbOf(args), res.ReturnCode, res.Reason)
	}
	return nil
}

func verbOf(args []string) string {
	if len(args) > 0 {
		return args[0]
	}
	return ""
}

// zipFinalize runs create then verify of the analysis manifest, locks the tree (0700 directories, 0400
// files) and returns. The spec file is removed between the two.
func zipFinalize(s cli.Stdio, manifestCLI, stage string, stageRoot *os.Root, spec []byte) error {
	if err := zipCreate(stageRoot, "manifest-spec.json", spec); err != nil {
		return err
	}
	manifest := stage + "/analysis-manifest.v1.json"
	if err := zipRunManifest(s, manifestCLI, "create", "--root", stage, "--spec", stage+"/manifest-spec.json", "--output", manifest); err != nil {
		return err
	}
	if err := os.Remove(stage + "/manifest-spec.json"); err != nil {
		return err
	}
	if err := zipRunManifest(s, manifestCLI, "verify", "--root", stage, manifest); err != nil {
		return err
	}
	return filepath.WalkDir(stage, func(path string, d fs.DirEntry, err error) error {
		if err != nil || path == stage {
			return err
		}
		mode := os.FileMode(0o400)
		if d.IsDir() {
			mode = 0o700
		}
		return os.Chmod(path, mode)
	})
}

// zipValidateTree checks the closed output tree: everything owned by this user, directories 0700, files
// 0400 with a single link, nothing but regular files and directories, and exactly the expected set. A nil
// expectedDirs leaves the directory set unchecked. Directories are then synced, deepest first.
func zipValidateTree(stage string, expectedFiles, expectedDirs map[string]bool) error {
	files, dirs := map[string]bool{}, map[string]bool{}
	err := filepath.WalkDir(stage, func(path string, d fs.DirEntry, err error) error {
		if err != nil || path == stage {
			return err
		}
		fi, err := os.Lstat(path)
		if err != nil {
			return err
		}
		want := os.FileMode(0o400)
		if fi.IsDir() {
			want = 0o700
		}
		uid, nlink, ok := zipOwnerOf(fi)
		if !ok || int(uid) != zipGetuid() || fi.Mode().Perm() != want || fi.Mode()&(fs.ModeSetuid|fs.ModeSetgid|fs.ModeSticky) != 0 {
			return &ZipError{Msg: "output ownership or mode violation"}
		}
		rel, _ := filepath.Rel(stage, path)
		switch {
		case fi.Mode().IsRegular():
			if nlink != 1 {
				return &ZipError{Msg: "output file has external hardlinks"}
			}
			files[rel] = true
		case fi.IsDir():
			dirs[rel] = true
		default:
			return &ZipError{Msg: "output tree contains a link or special file"}
		}
		return nil
	})
	if err != nil {
		return err
	}
	if !sameSet(files, expectedFiles) || (expectedDirs != nil && !sameSet(dirs, expectedDirs)) {
		return &ZipError{Msg: "output tree is not closed"}
	}
	order := make([]string, 0, len(dirs))
	for d := range dirs {
		order = append(order, d)
	}
	sort.Slice(order, func(i, j int) bool { return strings.Count(order[i], "/") > strings.Count(order[j], "/") })
	for _, d := range order {
		if err := fsx.SyncDir(stage + "/" + d); err != nil {
			return err
		}
	}
	return fsx.SyncDir(stage)
}

func sameSet(a, b map[string]bool) bool {
	if len(a) != len(b) {
		return false
	}
	for k := range a {
		if !b[k] {
			return false
		}
	}
	return true
}

// zipPublish renames stage onto destination without replacing anything. It reports whether the rename
// happened: a sync failure after it is returned with renamed true (uncertain durability).
func zipPublish(stage, destination, parent string) (renamed bool, err error) {
	if err := fsx.Publish(stage, destination); err != nil {
		return false, &ZipError{Msg: "atomic no-replace publication failed"}
	}
	return true, zipSyncDir(parent)
}

// zipSyncDir syncs the parent after a publication; a test replaces it to force the uncertain-durability path.
var zipSyncDir = fsx.SyncDir

// zipStatEqual is the legacy ensure_stable comparison.
func zipStatEqual(a, b fsx.Stat) bool { return a == b }

// pyInt parses a command-line integer like Python's int(): surrounding Unicode whitespace, an optional sign
// and decimal digits (any script) with single underscores between them. Values beyond int64 are rejected.
func pyInt(s string) (int64, error) {
	bad := fmt.Errorf("invalid int value: %s", strconv.Quote(s))
	t := strings.TrimSpace(s)
	neg := false
	if t != "" && (t[0] == '+' || t[0] == '-') {
		neg, t = t[0] == '-', t[1:]
	}
	if t == "" || strings.HasPrefix(t, "_") || strings.HasSuffix(t, "_") || strings.Contains(t, "__") {
		return 0, bad
	}
	n := new(big.Int)
	ten := big.NewInt(10)
	for _, r := range t {
		if r == '_' {
			continue
		}
		d, ok := decimalDigit(r)
		if !ok {
			return 0, bad
		}
		n.Mul(n, ten).Add(n, big.NewInt(int64(d)))
	}
	if neg {
		n.Neg(n)
	}
	if !n.IsInt64() {
		return 0, bad
	}
	return n.Int64(), nil
}

// decimalDigit is the value of a Unicode decimal digit (category Nd): digits come in runs of ten starting at
// a zero, so the value is the offset from the start of the contiguous run modulo ten.
func decimalDigit(r rune) (int, bool) {
	if !unicode.IsDigit(r) {
		return 0, false
	}
	start := r
	for unicode.IsDigit(start - 1) {
		start--
	}
	return int(r-start) % 10, true
}

// intFlag is a flag.Value holding a Python-style integer.
type intFlag struct{ v *int64 }

func (f intFlag) String() string {
	if f.v == nil {
		return ""
	}
	return strconv.FormatInt(*f.v, 10)
}

func (f intFlag) Set(s string) error {
	n, err := pyInt(s)
	if err != nil {
		return err
	}
	*f.v = n
	return nil
}

// copyAll copies src to dst in 1 MiB chunks.
func copyAll(dst io.Writer, src io.Reader) (int64, error) {
	return io.CopyBuffer(dst, src, make([]byte, 1<<20))
}
