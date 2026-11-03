//go:build unix

package formats

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
	"unicode/utf8"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/adapter"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/fsx"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/jsonout"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/proc"
)

// Differences from squashfs_extract.py, all stricter or crash-free (documented in squashfs-extract.v1.md):
//   - A symlink to a directory is refused where it first appears ("symlink in extracted tree (rejected)").
//     The script's os.walk filed it under dirnames, so walk_tree never saw it and the refusal came later from a
//     chmod through the link (a Python-version-dependent "Operation not permitted").
//   - A directory the walk cannot list, or a missing extraction directory, is an error. os.walk skipped both
//     silently, which could publish an incomplete tree as complete.
//   - A stage directory that already exists (another run in flight, or a leftover) is never deleted by the
//     run that failed to create it; the script's cleanup removed it.
//   - A FIFO as the input is refused ("source is not a regular file") instead of blocking on open.
//   - The manifest's launcher is the rsdd binary (argv: rsdd formats squashfs-extract ...), with no script
//     artifact, where the script recorded python plus squashfs_extract.py.
//   - The sandbox child gets a minimal environment (PATH only) instead of the caller's.
//   - A manifest tool failure prints that tool's own output and "squashfs-extract: manifest <create|verify>
//     failed (exit N)" where the script printed Python's CalledProcessError text.
//   - An extracted file name that is not valid UTF-8 is refused (the evidence is UTF-8 JSON).

// Seams the tests replace.
var (
	bwrapSearchPath      = "/usr/bin:/bin"
	unsquashfsSearchPath = "/usr/bin:/usr/sbin:/bin:/sbin"
	currentCreds         = func() creds { return creds{os.Getuid(), os.Geteuid(), os.Getgid(), os.Getegid()} }
	readMountinfo        = func() (string, error) { b, err := os.ReadFile("/proc/self/mountinfo"); return string(b), err }
	executablePath       = os.Executable
	hashHook             func() // called after every hashed chunk
)

type creds struct{ uid, euid, gid, egid int }

// privateFS is the whitelist of Linux filesystem types accepted as private; anything else, unknown types
// included, is rejected (fail closed). It is adapter_core.PRIVATE_FS; a domain cannot import internal/adapter.
var privateFS = map[string]bool{
	"btrfs": true, "ext2": true, "ext3": true, "ext4": true, "f2fs": true, "jfs": true, "nilfs2": true,
	"overlay": true, "ramfs": true, "reiserfs": true, "tmpfs": true, "ubifs": true, "xfs": true, "zfs": true,
}

// ---------------------------------------------------------------- tree validation

type treeEntry struct {
	Path   string
	Type   string // "file" | "directory"
	Mode   int
	Size   int64
	SHA256 string // "sha256:<hex>", files only
}

func (e treeEntry) toMap() map[string]any {
	m := map[string]any{"path": e.Path, "type": e.Type, "mode": e.Mode}
	if e.Type == "file" {
		m["size"], m["sha256"] = e.Size, e.SHA256
	}
	return m
}

func statOf(fi os.FileInfo) *syscall.Stat_t { st, _ := fi.Sys().(*syscall.Stat_t); return st }

// walkTree walks the extracted tree without following links and refuses symlinks, special files and
// hardlinks, hashing every regular file through one descriptor. It returns the entries sorted by path.
// A directory contributes its own entry, then its files in name order, then its subdirectories.
func walkTree(root string, maxEntries int, maxBytes int64) ([]treeEntry, error) {
	var entries []treeEntry
	var total int64
	atCap := func() error {
		if len(entries) >= maxEntries {
			return sqfsErrf("entries exceed max-entries (%d)", maxEntries)
		}
		return nil
	}
	var visit func(dir, rel string) error
	visit = func(dir, rel string) error {
		if rel != "" {
			if err := atCap(); err != nil {
				return err
			}
			fi, err := os.Lstat(dir)
			if err != nil {
				return err
			}
			entries = append(entries, treeEntry{Path: rel, Type: "directory", Mode: int(statOf(fi).Mode & 0o7777)})
		}
		list, err := os.ReadDir(dir)
		if err != nil {
			return err
		}
		var subdirs []string
		for _, d := range list { // ReadDir sorts by name
			if d.Type()&fs.ModeType == fs.ModeDir {
				subdirs = append(subdirs, d.Name())
				continue
			}
			if err := atCap(); err != nil {
				return err
			}
			childRel := d.Name()
			if rel != "" {
				childRel = rel + "/" + d.Name()
			}
			e, size, err := hashEntry(filepath.Join(dir, d.Name()), childRel, total, maxBytes)
			if err != nil {
				return err
			}
			total += size
			entries = append(entries, e)
		}
		for _, name := range subdirs {
			childRel := name
			if rel != "" {
				childRel = rel + "/" + name
			}
			if err := visit(filepath.Join(dir, name), childRel); err != nil {
				return err
			}
		}
		return nil
	}
	if err := visit(root, ""); err != nil {
		return nil, err
	}
	for _, e := range entries {
		if !utf8.ValidString(e.Path) {
			return nil, sqfsErrf("extracted path is not valid UTF-8: %s", pyRepr(e.Path))
		}
	}
	slices.SortStableFunc(entries, func(a, b treeEntry) int { return strings.Compare(a.Path, b.Path) })
	return entries, nil
}

// hashEntry classifies one non-directory name and, for a regular file, hashes it. total is the bytes counted
// so far; the returned size is this file's.
func hashEntry(full, rel string, total, maxBytes int64) (treeEntry, int64, error) {
	fi, err := os.Lstat(full)
	if err != nil {
		return treeEntry{}, 0, sqfsErrf("cannot stat: %s", rel)
	}
	st := statOf(fi)
	switch fi.Mode() & fs.ModeType {
	case fs.ModeSymlink:
		return treeEntry{}, 0, sqfsErrf("symlink in extracted tree (rejected): %s", rel)
	case 0:
	default:
		return treeEntry{}, 0, sqfsErrf("special file in extracted tree (rejected): %s", rel)
	}
	if uint64(st.Nlink) != 1 {
		return treeEntry{}, 0, sqfsErrf("hardlinked file in extracted tree: %s", rel)
	}
	if total+fi.Size() > maxBytes {
		return treeEntry{}, 0, sqfsErrf("extracted bytes exceed max-extracted-bytes (%d)", maxBytes)
	}
	sum, err := hashNoFollow(full, rel)
	if err != nil {
		return treeEntry{}, 0, err
	}
	return treeEntry{Path: rel, Type: "file", Mode: int(st.Mode & 0o7777), Size: fi.Size(), SHA256: sum}, fi.Size(), nil
}

// hashNoFollow hashes the file through one O_NOFOLLOW descriptor and refuses one that changed meanwhile
// (device, inode, size and mtime must match before and after).
func hashNoFollow(full, rel string) (string, error) {
	f, err := os.OpenFile(full, os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_CLOEXEC, 0)
	if err != nil {
		return "", err
	}
	defer f.Close()
	ident := func() ([4]int64, error) {
		fi, err := f.Stat()
		if err != nil {
			return [4]int64{}, err
		}
		st := statOf(fi)
		return [4]int64{int64(st.Dev), int64(st.Ino), fi.Size(), fi.ModTime().UnixNano()}, nil
	}
	before, err := ident()
	if err != nil {
		return "", err
	}
	h := sha256.New()
	buf := make([]byte, 1<<20)
	for {
		n, err := f.Read(buf)
		h.Write(buf[:n])
		if n > 0 && hashHook != nil {
			hashHook()
		}
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return "", err
		}
	}
	after, err := ident()
	if err != nil {
		return "", err
	}
	if before != after {
		return "", sqfsErrf("file changed while hashing: %s", rel)
	}
	return "sha256:" + hex.EncodeToString(h.Sum(nil)), nil
}

// validateClosed verifies that stage holds exactly the expected files and directories, all owned by the
// caller, directories 0700 and everything else 0400, with no hardlink or special file.
func validateClosed(stage string, expectedFiles, expectedDirs map[string]bool) error {
	seenFiles, seenDirs := map[string]bool{}, map[string]bool{}
	uid := uint32(os.Getuid())
	err := filepath.WalkDir(stage, func(p string, _ fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if p == stage {
			return nil
		}
		fi, err := os.Lstat(p)
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(stage, p)
		st := statOf(fi)
		want := uint32(0o400)
		if fi.IsDir() {
			want = 0o700
		}
		if st.Uid != uid || uint32(st.Mode)&0o7777 != want {
			return sqfsErrf("output mode/ownership violation: %s", rel)
		}
		switch {
		case fi.Mode().IsRegular():
			if uint64(st.Nlink) != 1 {
				return sqfsErrf("hardlinked output file: %s", rel)
			}
			seenFiles[rel] = true
		case fi.IsDir():
			seenDirs[rel] = true
		default:
			return sqfsErrf("unexpected type in output tree: %s", rel)
		}
		return nil
	})
	if err != nil {
		return err
	}
	if !sameSet(seenFiles, expectedFiles) || !sameSet(seenDirs, expectedDirs) {
		return sqfsErrf("output tree is not closed")
	}
	return nil
}

// ---------------------------------------------------------------- host checks

// requirePrivate is adapter_core.require_private: the deepest mount point containing path (by path
// components; the first wins on a tie) must be a privateFS type. A malformed line is an error, never a panic.
func requirePrivate(path, mountinfo string) error {
	target := splitNonEmpty(path, '/')
	selDepth, selFS := -1, ""
	for _, line := range strings.Split(strings.ReplaceAll(mountinfo, "\r\n", "\n"), "\n") {
		if line == "" {
			continue
		}
		left, right, ok := strings.Cut(line, " - ")
		if !ok {
			return sqfsErrf("malformed mountinfo line (missing ' - ' separator): %s", pyRepr(line))
		}
		lf := strings.Fields(left)
		if len(lf) < 5 {
			return sqfsErrf("malformed mountinfo line (too few left fields): %s", pyRepr(line))
		}
		enc := strings.ReplaceAll(lf[4], `\040`, " ")
		enc = strings.ReplaceAll(enc, `\011`, "\t")
		enc = strings.ReplaceAll(enc, `\134`, `\`)
		mount := splitNonEmpty(enc, '/')
		rf := strings.Fields(right)
		if len(rf) == 0 {
			return sqfsErrf("malformed mountinfo line (empty right side): %s", pyRepr(line))
		}
		if len(mount) > len(target) || !hasPrefix(target, mount) {
			continue
		}
		if len(mount) > selDepth {
			selDepth, selFS = len(mount), rf[0]
		}
	}
	if selDepth == -1 {
		return sqfsErrf("output path is under no known mount point")
	}
	if !privateFS[selFS] {
		return sqfsErrf("output must reside on a Linux-private filesystem")
	}
	return nil
}

func hasPrefix(path, prefix []string) bool {
	for i, p := range prefix {
		if path[i] != p {
			return false
		}
	}
	return true
}

// whichIn is shutil.which(name, path=search): the first directory holding an executable regular file.
func whichIn(name, search string) (string, bool) {
	for _, d := range strings.Split(search, ":") {
		if d == "" {
			continue
		}
		p := d + "/" + name
		if fi, err := os.Stat(p); err == nil && !fi.IsDir() && syscall.Access(p, 1) == nil {
			return p, true
		}
	}
	return "", false
}

// errText renders an error the way the script's handlers print it: a refusal as is, an OS error as Python's
// "[Errno N] strerror: 'file'".
func errText(err error) string {
	var se *sqfsError
	if errors.As(err, &se) {
		return se.msg
	}
	var fe *fsx.Error
	if errors.As(err, &fe) {
		return fe.Error()
	}
	var pe *os.PathError
	if errors.As(err, &pe) {
		if en, ok := errnoOf(pe.Err); ok {
			return osErrorText(en, pe.Path)
		}
	}
	var le *os.LinkError
	if errors.As(err, &le) {
		if en, ok := errnoOf(le.Err); ok {
			return osErrorText(en, le.New)
		}
	}
	if en, ok := errnoOf(err); ok {
		return osErrorText(en, "")
	}
	return err.Error()
}

// ---------------------------------------------------------------- unsquashfs under bubblewrap

func bwrapArgv(bwrap, unsquashfs, stage string, offset int64) []string {
	argv := []string{bwrap, "--die-with-parent", "--new-session", "--unshare-net", "--unshare-pid", "--cap-drop", "ALL"}
	for _, d := range []string{"/usr", "/bin", "/sbin", "/lib", "/lib64"} {
		if _, err := os.Stat(d); err == nil {
			argv = append(argv, "--ro-bind", d, d)
		}
	}
	for _, etc := range []string{"/etc/ld.so.cache", "/etc/ld.so.conf", "/etc/ld.so.conf.d"} {
		argv = append(argv, "--ro-bind-try", etc, etc)
	}
	argv = append(argv, "--dir", "/work", "--bind", stage, "/work", "--proc", "/proc", "--dev", "/dev", "--tmpfs", "/tmp",
		"--setenv", "PATH", "/usr/bin:/usr/sbin:/bin:/sbin", "--setenv", "HOME", "/tmp", "--setenv", "TMPDIR", "/tmp", "--")
	argv = append(argv, unsquashfs, "-no-progress", "-quiet", "-d", "/work/extracted")
	if offset > 0 {
		argv = append(argv, "-offset", fmt.Sprint(offset)) // skip N bytes before the header
	}
	return append(argv, "/work/input.sqfs")
}

// treeBytes sums the sizes of the non-directory entries under root; unreadable entries count as zero.
func treeBytes(root string, over int64) int64 {
	var total int64
	_ = filepath.WalkDir(root, func(_ string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if !d.IsDir() {
			if fi, err := d.Info(); err == nil {
				total += fi.Size()
			}
		}
		if total > over {
			return fs.SkipAll
		}
		return nil
	})
	return total
}

// overCap reports whether the tree under root holds more than limit bytes (exactly limit is within the cap).
func overCap(root string, limit int64) bool { return treeBytes(root, limit) > limit }

// runUnsquashfs runs unsquashfs inside a minimal bwrap: a wall-clock timeout, a per-file RLIMIT_FSIZE (set
// by the rlimit helper, i.e. this binary re-executed as `rsdd __exec`) and a watchdog that kills the process
// group when the aggregate bytes on disk pass the cap (~250 ms poll). stderr goes to stage/stderr.txt.
func runUnsquashfs(bwrap, unsquashfs, stage string, offset int64, timeoutSeconds, maxExtracted int64) error {
	helper, err := executablePath()
	if err != nil {
		return err
	}
	stderrFile, err := os.OpenFile(filepath.Join(stage, "stderr.txt"), os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return err
	}
	argv := bwrapArgv(bwrap, unsquashfs, stage, offset)
	limits := fmt.Sprintf("core=0,fsize=%d", maxExtracted)
	// The rsdd binary re-executes itself as the rlimit helper: `rsdd __exec LIMITS PATH ARGV0 [ARG...]`.
	cmd := exec.Command(helper, append([]string{proc.HelperCommand, limits, bwrap}, argv...)...)
	cmd.Dir = stage
	cmd.Env = []string{"PATH=/usr/bin:/usr/sbin:/bin:/sbin"}
	cmd.Stderr = stderrFile
	proc.SetNewGroup(cmd)
	if err := cmd.Start(); err != nil {
		stderrFile.Close()
		return err
	}
	var grp proc.Group
	grp.Record(cmd.Process.Pid)
	pid := cmd.Process.Pid
	kill := func() { _ = grp.Signal(pid, syscall.SIGKILL) }

	done := make(chan struct{})
	go func() { _ = cmd.Wait(); close(done) }()

	var fired atomic.Bool
	stopWatchdog := make(chan struct{})
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		tick := time.NewTicker(250 * time.Millisecond)
		defer tick.Stop()
		for {
			select {
			case <-stopWatchdog:
				return
			case <-tick.C:
				if overCap(filepath.Join(stage, "extracted"), maxExtracted) {
					fired.Store(true)
					kill()
					return
				}
			}
		}
	}()

	timer := time.NewTimer(time.Duration(clampSeconds(timeoutSeconds)) * time.Second)
	defer timer.Stop()
	reason := ""
	select {
	case <-done:
	case <-timer.C:
		reason = "timeout"
		kill()
	}
	// A timeout and a fired watchdog have already signalled the whole process group (kill is a group-wide
	// SIGKILL), so no second signal is sent here.
	<-done
	close(stopWatchdog)
	wg.Wait()
	stderrFile.Close()

	if fired.Load() {
		return sqfsErrf("extraction killed: on-disk size exceeded max-extracted-bytes (%d) during extraction", maxExtracted)
	}
	if reason != "" {
		return sqfsErrf("%s", reason)
	}
	if cmd.ProcessState.ExitCode() != 0 { // -1 when a signal ended it
		raw, _ := os.ReadFile(filepath.Join(stage, "stderr.txt"))
		if snippet := snippetOf(raw); snippet != "" {
			return sqfsErrf("unsquashfs failed: %s", snippet)
		}
		return sqfsErrf("unsquashfs failed")
	}
	return nil
}

// snippetOf is read_text(errors="replace")[:512].strip(): the first 512 characters, each undecodable byte
// one U+FFFD, trimmed.
func snippetOf(raw []byte) string {
	var b strings.Builder
	n := 0
	for i := 0; i < len(raw) && n < 512; n++ {
		r, w := utf8.DecodeRune(raw[i:])
		b.WriteRune(r) // an undecodable byte decodes to RuneError, which is U+FFFD
		i += w
	}
	return strings.TrimSpace(b.String())
}

// ---------------------------------------------------------------- the command

// SquashfsExtract is `rsdd formats squashfs-extract`.
func SquashfsExtract(args []string, s cli.Stdio) int {
	a, code, done := parseSquashfsArgs(args, s)
	if done {
		return code
	}
	startedAt := s.Clock()
	stage := ""
	err := extractSquashfs(a, s, startedAt, &stage)
	if stage != "" {
		_ = os.RemoveAll(stage)
	}
	if err != nil {
		fmt.Fprintf(s.Err, "squashfs-extract: %s\n", errText(err))
		return 2
	}
	return 0
}

func isoZ(t time.Time) string {
	t = t.UTC()
	if t.Nanosecond()/1000 == 0 {
		return t.Format("2006-01-02T15:04:05") + "Z"
	}
	return t.Format("2006-01-02T15:04:05.000000") + "Z"
}

// outputPlan is the lexical analysis of --output: the normalized path parts (Path.parts, without the root).
func outputParts(output string) []string { return splitNonEmptyDot(output) }

func splitNonEmptyDot(p string) []string {
	var out []string
	for _, part := range splitNonEmpty(p, '/') {
		if part != "." {
			out = append(out, part)
		}
	}
	return out
}

func extractSquashfs(a squashfsOpts, s cli.Stdio, startedAt time.Time, stagePath *string) error {
	if c := currentCreds(); c.euid == 0 || c.uid != c.euid || c.gid != c.egid {
		return sqfsErrf("refusing root or set-id execution")
	}
	if !capsPositive(a) {
		return sqfsErrf("caps must be positive")
	}
	parts := outputParts(a.output)
	for _, p := range parts {
		if p == ".." {
			return sqfsErrf("output must be a canonical path")
		}
	}
	if strings.Contains(a.output, `\`) {
		return sqfsErrf("output must be a canonical path")
	}
	name := ""
	parentParts := parts
	if len(parts) > 0 {
		name, parentParts = parts[len(parts)-1], parts[:len(parts)-1]
	}
	var lexParts []string
	if !strings.HasPrefix(a.output, "/") {
		lexParts = splitNonEmptyDot(filepath.Clean(s.Cwd))
	}
	lexParts = append(lexParts, parentParts...)
	lexical := "/" + strings.Join(lexParts, "/")
	probe, firstMissing := "", ""
	for _, part := range lexParts {
		probe += "/" + part
		fi, err := os.Lstat(probe)
		if err != nil {
			if firstMissing == "" {
				firstMissing = probe
			}
			continue
		}
		if fi.Mode()&fs.ModeSymlink != 0 {
			return sqfsErrf("output parent links are not allowed")
		}
	}
	if firstMissing != "" {
		_, err := os.Lstat(firstMissing)
		return err
	}
	parent := lexical
	mi, err := readMountinfo()
	if err != nil {
		var pe *os.PathError
		if errors.As(err, &pe) {
			return err
		}
		if en, ok := errnoOf(err); ok {
			return &os.PathError{Op: "open", Path: "/proc/self/mountinfo", Err: en}
		}
		return err
	}
	if err := requirePrivate(parent, mi); err != nil {
		return err
	}
	meta, err := os.Stat(parent)
	if err != nil {
		return err
	}
	destination := filepath.Join(parent, name)
	_, existsErr := os.Stat(destination)
	lfi, lerr := os.Lstat(destination)
	if !meta.IsDir() || int(statOf(meta).Uid) != os.Getuid() || meta.Mode().Perm()&0o022 != 0 ||
		name == "" || name == "." || name == ".." || existsErr == nil || (lerr == nil && lfi.Mode()&fs.ModeSymlink != 0) {
		return sqfsErrf("unsafe output destination")
	}
	bwrapPath, ok := whichIn("bwrap", bwrapSearchPath)
	if !ok {
		return sqfsErrf("bwrap is required")
	}
	bwrap, err := filepath.EvalSymlinks(bwrapPath)
	if err != nil {
		return err
	}
	unsqPath, ok := whichIn("unsquashfs", unsquashfsSearchPath)
	if !ok {
		return sqfsErrf("unsquashfs is required")
	}
	unsquashfs, err := filepath.EvalSymlinks(unsqPath)
	if err != nil {
		return err
	}

	stage := filepath.Join(parent, "."+name+".stage")
	if err := os.Mkdir(stage, 0o700); err != nil {
		return err
	}
	*stagePath = stage // from here on the stage is ours and is removed on any failure
	srcRec, _, err := fsx.StageFile(pyPathJoin(s.Cwd, a.input), filepath.Join(stage, "input.sqfs"), "input.sqfs", 0o400, a.maxInput)
	if err != nil {
		return err
	}
	// Validate the superblock in the staged copy, which closes the time-of-check gap.
	offset, err := stagedOffset(filepath.Join(stage, "input.sqfs"))
	if err != nil {
		return err
	}
	if err := runUnsquashfs(bwrap, unsquashfs, stage, offset, a.timeoutSeconds, a.maxExtracted); err != nil {
		return err
	}
	if err := os.Remove(filepath.Join(stage, "input.sqfs")); err != nil {
		return err
	}
	entries, err := walkTree(filepath.Join(stage, "extracted"), int(min(a.maxEntry, int64(^uint(0)>>1))), a.maxExtracted)
	if err != nil {
		return err
	}
	var fileEntries, dirEntries []treeEntry
	var totalBytes int64
	entryMaps := make([]any, 0, len(entries))
	for _, e := range entries {
		entryMaps = append(entryMaps, e.toMap())
		if e.Type == "file" {
			fileEntries = append(fileEntries, e)
			totalBytes += e.Size
		} else {
			dirEntries = append(dirEntries, e)
		}
	}
	limitations := []any{
		"Tree validation rejects symlinks, special files, and hardlinks; semantic content is not analyzed.",
		"Bubblewrap is defense in depth; use a disposable VM for actively hostile firmware.",
	}
	report := map[string]any{
		"schema":          sqfsSchema,
		"input":           map[string]any{"path": srcRec.Path, "size": srcRec.Size, "sha256": srcRec.SHA256},
		"squashfs_offset": offset, "entries": entryMaps,
		"entry_counts":          map[string]any{"files": len(fileEntries), "directories": len(dirEntries)},
		"total_extracted_bytes": totalBytes,
		"caps": map[string]any{"max_input_bytes": a.maxInput, "max_extracted_bytes": a.maxExtracted,
			"max_entries": a.maxEntry, "timeout_seconds": a.timeoutSeconds},
		"isolation":          map[string]any{"bubblewrap": true, "network_access": false, "payload_execution": false, "static_only": true},
		"limitations":        limitations,
		"validation_verdict": "pass",
	}
	if err := writeCanonical(filepath.Join(stage, sqfsSchema+".json"), report); err != nil {
		return err
	}
	if err := createEmpty(filepath.Join(stage, "stdout.txt")); err != nil {
		return err
	}
	endedAt := s.Clock()
	launcher, err := executablePath()
	if err != nil {
		return err
	}
	if launcher, err = filepath.EvalSymlinks(launcher); err != nil {
		return err
	}
	outputs := make([]any, 0, len(fileEntries))
	for _, e := range fileEntries {
		outputs = append(outputs, "extracted/"+e.Path)
	}
	us := endedAt.Sub(startedAt).Microseconds()
	spec := map[string]any{
		"schema_version": "analysis-manifest.v1",
		"input":          map[string]any{"path": sqfsSchema + ".json", "detected_type": "SquashFS v4 LE extraction report with source SHA-256"},
		"tool":           map[string]any{"name": "squashfs-extract", "version": "1", "executable": launcher, "artifacts": []any{}},
		"argv":           []any{launcher, "formats", "squashfs-extract", "--input", srcRec.Path, "--output", destination},
		"environment":    map[string]any{},
		"run": map[string]any{"started_at": isoZ(startedAt), "ended_at": isoZ(endedAt),
			"duration_ms": int64(float64(us) / 1e6 * 1000), "exit_code": 0, "signal": nil},
		"stdout_path": "stdout.txt", "stderr_path": "stderr.txt", "outputs": outputs, "findings": []any{},
		"limitations": limitations, "errors": []any{}, "completeness": "complete",
		"isolation_profile": map[string]any{"name": "bwrap-unsquashfs", "static_only": true, "network_access": false, "target_execution": false},
	}
	specPath := filepath.Join(stage, "manifest-spec.json")
	if err := writeCanonical(specPath, spec); err != nil {
		return err
	}
	manifestPath := filepath.Join(stage, "analysis-manifest.v1.json")
	if err := runManifestTool(s, "create", "--root", stage, "--spec", specPath, "--output", manifestPath); err != nil {
		return err
	}
	if err := os.Remove(specPath); err != nil {
		return err
	}
	if err := runManifestTool(s, "verify", "--root", stage, manifestPath); err != nil {
		return err
	}
	if err := lockModes(stage); err != nil {
		return err
	}
	expectedFiles := map[string]bool{sqfsSchema + ".json": true, "analysis-manifest.v1.json": true, "stdout.txt": true, "stderr.txt": true}
	for _, e := range fileEntries {
		expectedFiles["extracted/"+e.Path] = true
	}
	expectedDirs := map[string]bool{"extracted": true}
	for _, e := range dirEntries {
		expectedDirs["extracted/"+e.Path] = true
	}
	if err := validateClosed(stage, expectedFiles, expectedDirs); err != nil {
		return err
	}
	if err := fsx.Publish(stage, destination); err != nil {
		var le *os.LinkError
		if errors.As(err, &le) {
			if en, ok := errnoOf(le.Err); ok {
				return &sqfsError{fmt.Sprintf("[Errno %d] atomic publication failed: %s", int(en), pyRepr(destination))}
			}
		}
		return err
	}
	*stagePath = "" // published: nothing to clean up
	return nil
}

// stagedOffset opens the staged copy without following links and returns its superblock offset.
func stagedOffset(path string) (int64, error) {
	fd, st, err := fsx.OpenRO(path)
	if err != nil {
		return 0, err
	}
	f := os.NewFile(uintptr(fd), path)
	defer f.Close()
	if st.Size < sqfsSBSize {
		return 0, sqfsErrf("input too small for a SquashFS superblock")
	}
	return findSquashfsOffset(f, st.Size)
}

// writeCanonical creates path exclusively (never through a link) with canonical JSON, fsynced.
func writeCanonical(path string, v any) error {
	body, err := jsonout.Canonical(v)
	if err != nil {
		return err
	}
	fd, err := fsx.OpenWONew(path)
	if err != nil {
		return err
	}
	return writeSyncClose(os.NewFile(uintptr(fd), path), body)
}

// syncWriteCloser is the part of *os.File writeSyncClose uses (a seam for the failure paths).
type syncWriteCloser interface {
	io.Writer
	Sync() error
	Close() error
}

// writeSyncClose writes body, fsyncs and closes f; the file is closed on every path and the first failure wins.
func writeSyncClose(f syncWriteCloser, body []byte) error {
	if _, err := f.Write(body); err != nil {
		f.Close()
		return err
	}
	if err := f.Sync(); err != nil {
		f.Close()
		return err
	}
	return f.Close()
}

func createEmpty(path string) error {
	fd, err := fsx.OpenWONew(path)
	if err != nil {
		return err
	}
	return os.NewFile(uintptr(fd), path).Close()
}

// lockModes makes every directory 0700 and everything else 0400, top-down. A link is refused rather than
// chmod'ed through.
func lockModes(stage string) error {
	return filepath.WalkDir(stage, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if p == stage {
			return nil
		}
		rel, _ := filepath.Rel(stage, p)
		if d.Type()&fs.ModeSymlink != 0 {
			return sqfsErrf("unexpected type in output tree: %s", rel)
		}
		mode := os.FileMode(0o400)
		if d.IsDir() {
			mode = 0o700
		}
		return os.Chmod(p, mode)
	})
}

// runManifestTool runs one analysis-manifest verb in process (core/adapter) and relays its output. The
// --manifest-cli argument is accepted and ignored.
func runManifestTool(s cli.Stdio, verb string, rest ...string) error {
	if rc := adapter.ManifestRun(append([]string{verb}, rest...), s); rc != 0 {
		return sqfsErrf("manifest %s failed (exit %d)", verb, rc)
	}
	return nil
}
