// Package carve is `rsdd corroborate carve`: the port of toolbelt/firmware_carve.py (kit issue #2053; ported
// by the Go port of the Python toolbelt). It carves only validated uImage and SquashFS v4 little-endian byte
// ranges out of a firmware image, deterministically, into a new directory published atomically.
//
// The parent half validates the arguments and the output location, stages the input read-only, launches the
// worker inside a bubblewrap sandbox (no network, no capabilities, bounded wall clock, process tree and
// address space), then checks everything the worker left behind before publishing the directory with a
// no-replace rename. The worker is this same binary started as `rsdd corroborate carve --worker ...`.
// The report schema, file names, modes, exit codes (0, 2, 3) and the messages of the script are kept; the
// contract is toolbelt/firmware-carve.v1.md.
//
// Shared behaviour comes from core: adapter (privilege refusal, private-filesystem check), fsx (input staging,
// no-replace publish, directory sync), jsonout (canonical report), proc (the rlimit re-exec helper and the
// process-group kill guard).
//
// Intended differences from the script, none visible in a successful carve:
//   - the input is read with bounded reads (a sliding magic search, a streamed CRC) instead of an mmap of the
//     whole file, so an input near max-input-bytes no longer needs that much address space;
//   - an unreadable or malformed worker report is a Go JSON error text, not Python's;
//   - OS errors read "[Errno N] text: 'path'" with the C library's wording, not always byte for byte;
//   - exit 3 (published, the parent directory could not be synced) prints a leading "DEGRADED:" marker, which
//     the rsdd process contract requires of every exit 3;
//   - the worker's address-space limit is --max-memory-bytes plus 1 GiB for the Go runtime's own reservation
//     (the report records --max-memory-bytes unchanged);
//   - the worker's stderr is drained without limit but only its first 4 KiB is reported (the script's pipe
//     could fill and stall the worker until the timeout);
//   - an unknown or abbreviated option is a usage error with rsdd's own usage text, not argparse's.
package carve

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/adapter"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/fsx"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/jsonout"
)

// runtimeAddressSpace is added to --max-memory-bytes when the worker's address-space limit is set. The Go
// runtime reserves roughly 0.5-0.8 GiB of address space before it allocates anything, which the Python worker
// did not; without the allowance the default 1.25 GiB limit made the worker die at random with "out of memory".
// The report still records the caps as given.
const runtimeAddressSpace = 1 << 30

const (
	schema = "firmware-carve.v1"
	prefix = "firmware-carve: "

	exitFailed   = 2
	exitUnsynced = 3
)

// deps are the ambient facts and the sandbox launch, injectable so every decision is testable without
// bubblewrap.
type deps struct {
	creds     func() adapter.Creds
	mountinfo func() (string, error)
	bwrap     func() (path, digest string, err error)
	launch    func(launchSpec) error
	syncDir   func(string) error
	self      func() (string, error)
}

func realDeps() deps {
	return deps{
		creds: adapter.CurrentCreds, mountinfo: adapter.HostMountinfo, bwrap: trustedBwrap,
		launch: launchWorker, syncDir: fsx.SyncDir, self: os.Executable,
	}
}

// launchSpec is one sandboxed worker run.
type launchSpec struct {
	argv     []string // the whole command: bubblewrap, its flags, "--", the worker
	dir      string
	env      []string // nil inherits the caller's environment
	self     string   // this binary: it serves the rlimit re-exec helper
	timeout  time.Duration
	maxProcs int
	memory   uint64 // RLIMIT_AS of the worker tree
	now      func() time.Time
}

// Run is the Main contract of `rsdd corroborate carve`.
func Run(args []string, s cli.Stdio) int { return execute(args, s, realDeps()) }

func execute(args []string, s cli.Stdio, d deps) int {
	c, outcome := parseArgs(args, s.Out, s.Err)
	switch outcome {
	case helpShown:
		return cli.ExitOK
	case usageError:
		return cli.ExitUsage
	}
	if err := adapter.RefusePrivilegedExecution(d.creds()); err != nil {
		return fail(s, err)
	}
	if c.worker {
		if err := runWorker(c, uint64(d.creds().EUID)); err != nil {
			return fail(s, err)
		}
		return cli.ExitOK
	}
	stage, err := carve(c, s, d)
	if stage != "" {
		defer os.RemoveAll(stage)
	}
	var unsynced *unsyncedError
	switch {
	case errors.As(err, &unsynced):
		fmt.Fprintf(s.Err, "DEGRADED: %spublished with uncertain durability: %v\n", prefix, unsynced)
		return exitUnsynced
	case err != nil:
		return fail(s, err)
	}
	return cli.ExitOK
}

func fail(s cli.Stdio, err error) int {
	fmt.Fprintf(s.Err, "%s%v\n", prefix, err)
	return exitFailed
}

// unsyncedError is a published output whose parent directory could not be synced.
type unsyncedError struct{ destination string }

func (e *unsyncedError) Error() string {
	return "output exists at " + e.destination + ", but parent-directory sync failed"
}

// carve is the parent half. It returns the stage directory still to be removed ("" once published or never
// created) and the failure, if any.
func carve(c config, s cli.Stdio, d deps) (stage string, err error) {
	if min(c.maxInput, c.maxOutput, c.maxCarves, c.maxFiles, c.timeout, c.maxProcs, c.maxMemory) < 1 {
		return "", errors.New("caps must be positive")
	}
	euid := uint64(d.creds().EUID)
	destination, err := checkOutput(c.output, s.Cwd, euid, d)
	if err != nil {
		return "", err
	}
	candidate := filepath.Join(filepath.Dir(destination), "."+filepath.Base(destination)+".stage")
	if err := os.Mkdir(candidate, 0o700); err != nil {
		return "", osError(err, candidate)
	}
	stage = candidate
	rec, err := stageInput(c.input, filepath.Join(stage, "input.bin"), c.maxInput)
	if err != nil {
		return stage, err
	}
	bwrap, digest, err := d.bwrap()
	if err != nil {
		return stage, err
	}
	self, err := d.self()
	if err != nil {
		return stage, err
	}
	argv := append(sandbox(bwrap, stage, self), workerArgs(workerGuest, c, rec, bwrap, digest)...)
	spec := launchSpec{argv: argv, dir: stage, self: self, timeout: time.Duration(c.timeout) * time.Second,
		maxProcs: int(min(c.maxProcs, 1<<30)), memory: uint64(c.maxMemory) + runtimeAddressSpace, now: s.Clock}
	if s.Environ != nil {
		spec.env = s.Environ()
	}
	if err := d.launch(spec); err != nil {
		return stage, err
	}
	raw, err := readStaged(filepath.Join(stage, schema+".json"), euid)
	if err != nil {
		return stage, err
	}
	report, err := decodeReport(raw)
	if err != nil {
		return stage, err
	}
	want := map[string]any{
		"input": rec.object(), "caps": capsObject(c), "isolation": isolation(),
		"isolation_artifact": map[string]any{"path": bwrap, "sha256": digest},
	}
	if err := checkContract(report, want); err != nil {
		return stage, err
	}
	if err := validateTree(stage, report, euid); err != nil {
		return stage, err
	}
	if err := fsx.Publish(stage, destination); err != nil {
		return stage, errors.New("atomic no-replace publication failed")
	}
	stage = ""
	if err := d.syncDir(filepath.Dir(destination)); err != nil {
		return "", &unsyncedError{destination}
	}
	return "", nil
}

// stageInput copies the input into the stage through one no-follow descriptor, read-only, with its identity.
func stageInput(input, target string, limit int64) (inputRecord, error) {
	src, _, err := fsx.StageFile(input, target, "input.bin", 0o400, limit)
	switch {
	case errors.Is(err, fsx.ErrSourceOpen):
		return inputRecord{}, errors.New("input must be a regular non-symlink file")
	case errors.Is(err, fsx.ErrSourceNotRegular):
		return inputRecord{}, errors.New("input is not a regular file")
	case errors.Is(err, fsx.ErrTooLarge):
		return inputRecord{}, errors.New("input exceeds max-input-bytes")
	case errors.Is(err, fsx.ErrSourceChanged):
		return inputRecord{}, errors.New("input changed while staging")
	case err != nil:
		return inputRecord{}, err
	}
	return inputRecord{Path: src.Path, Size: src.Size, SHA256: src.SHA256}, nil
}

// checkOutput validates the requested output path and returns the destination in the resolved parent. The
// output must be a new, canonical name (no "..", no backslash) in a private-filesystem directory the caller
// owns and nobody else can write, reached through no symlink.
func checkOutput(output, cwd string, euid uint64, d deps) (string, error) {
	parts := pathParts(output)
	if slicesContains(parts, "..") || strings.Contains(output, "\\") {
		return "", errors.New("output must be a new canonical path")
	}
	name := ""
	if len(parts) > 0 {
		name = parts[len(parts)-1]
	}
	parent := lexicalParent(output, parts, cwd)
	if err := noLinks(parent); err != nil {
		return "", err
	}
	if _, err := os.Lstat(parent); err != nil {
		return "", osError(err, parent)
	}
	info, err := os.Stat(parent)
	if err != nil {
		return "", osError(err, parent)
	}
	mount, err := d.mountinfo()
	if err != nil {
		return "", err
	}
	if err := adapter.RequirePrivate(parent, mount); err != nil {
		return "", err
	}
	uid, _, ok := owner(info)
	destination := filepath.Join(parent, name)
	_, lerr := os.Lstat(destination)
	if !info.IsDir() || !ok || uid != euid || info.Mode().Perm()&0o022 != 0 || name == "" || name == "." || name == ".." || lerr == nil {
		return "", errors.New("output must be a new canonical path in a private owned directory")
	}
	return destination, nil
}

// pathParts is pathlib's parts of a relative or absolute path: components with "" and "." dropped.
func pathParts(p string) []string {
	var parts []string
	for _, c := range strings.Split(p, "/") {
		if c != "" && c != "." {
			parts = append(parts, c)
		}
	}
	return parts
}

// lexicalParent is os.path.abspath of the output's parent.
func lexicalParent(output string, parts []string, cwd string) string {
	var dir []string
	if len(parts) > 0 {
		dir = parts[:len(parts)-1]
	}
	p := strings.Join(dir, "/")
	if strings.HasPrefix(output, "/") {
		p = "/" + p
	} else {
		p = filepath.Join(cwd, p)
	}
	return filepath.Clean(p)
}

// noLinks refuses a path any of whose components, from the root down, is a symlink.
func noLinks(path string) error {
	probe := "/"
	for _, part := range pathParts(path) {
		probe = filepath.Join(probe, part)
		if fi, err := os.Lstat(probe); err == nil && fi.Mode()&os.ModeSymlink != 0 {
			return errors.New("output parent links are not allowed")
		}
	}
	return nil
}

func slicesContains(s []string, v string) bool {
	for _, x := range s {
		if x == v {
			return true
		}
	}
	return false
}

// osError renders an operating-system failure like Python's OSError: "[Errno N] text: 'path'".
func osError(err error, path string) error {
	var errno syscall.Errno
	if errors.As(err, &errno) {
		text := errno.Error()
		if text != "" {
			text = strings.ToUpper(text[:1]) + text[1:]
		}
		return fmt.Errorf("[Errno %d] %s: '%s'", int(errno), text, path)
	}
	return err
}

// workerGuest is where the worker binary is bound inside the sandbox (under its private /tmp).
const workerGuest = "/tmp/rsdd-worker"

// sandbox is the bubblewrap prefix: no network, no capabilities, a read-only view of the host, a private /tmp
// holding only the stage mounted read-write and this binary bound read-only at workerGuest (a host binary under
// /tmp is hidden by the tmpfs), and a fixed environment.
func sandbox(bwrap, stage, self string) []string {
	env := [][2]string{{"PATH", "/usr/bin:/bin"}, {"LANG", "C.UTF-8"}, {"LC_ALL", "C.UTF-8"}, {"TZ", "UTC"}, {"HOME", "/tmp/home"}, {"TMPDIR", "/tmp"}}
	cmd := []string{bwrap, "--die-with-parent", "--new-session", "--unshare-net", "--unshare-pid", "--cap-drop", "ALL",
		"--ro-bind", "/", "/", "--tmpfs", "/tmp", "--dir", "/tmp/home", "--dir", "/tmp/work", "--bind", stage, "/tmp/work",
		"--ro-bind", self, workerGuest,
		"--proc", "/proc", "--dev", "/dev"}
	for _, kv := range env {
		cmd = append(cmd, "--setenv", kv[0], kv[1])
	}
	return append(cmd, "--")
}

// workerArgs is the worker's command line: this binary re-run in worker mode against the sandboxed stage.
func workerArgs(self string, c config, rec inputRecord, bwrap, digest string) []string {
	record, _ := jsonout.Canonical(rec.object())
	args := []string{self, "corroborate", "carve", "--worker", "--input", "/tmp/work/input.bin", "--output", "/tmp/work/output",
		"--stage", "/tmp/work", "--input-record", strings.TrimSuffix(string(record), "\n"), "--bwrap-path", bwrap, "--bwrap-sha256", digest}
	for _, kv := range []struct {
		name string
		v    int64
	}{{"max-input-bytes", c.maxInput}, {"max-output-bytes", c.maxOutput}, {"max-carves", c.maxCarves}, {"max-files", c.maxFiles},
		{"timeout-seconds", c.timeout}, {"max-processes", c.maxProcs}, {"max-memory-bytes", c.maxMemory}} {
		args = append(args, "--"+kv.name, fmt.Sprint(kv.v))
	}
	return args
}

// trustedBwrap finds bubblewrap on the fixed system PATH and requires it to be a root-owned regular file
// nobody else can write, returning its resolved path and sha256 identity.
func trustedBwrap() (string, string, error) {
	for _, dir := range []string{"/usr/bin", "/bin"} {
		p := filepath.Join(dir, "bwrap")
		if fi, err := os.Stat(p); err == nil && fi.Mode().IsRegular() && fi.Mode().Perm()&0o111 != 0 {
			resolved, err := filepath.EvalSymlinks(p)
			if err != nil {
				return "", "", osError(err, p)
			}
			fi, err := os.Stat(resolved)
			if err != nil {
				return "", "", osError(err, resolved)
			}
			uid, _, ok := owner(fi)
			if !fi.Mode().IsRegular() || !ok || uid != 0 || fi.Mode().Perm()&0o022 != 0 {
				return "", "", refusal("Bubblewrap must be root-owned and non-writable")
			}
			id, err := fsx.Identity(resolved, fsx.NoLimit)
			if err != nil {
				return "", "", err
			}
			return resolved, id.SHA256, nil
		}
	}
	return "", "", refusal("Bubblewrap is required")
}

// refusal is an error whose text is kept exactly as the script printed it (some start with a capital letter).
type refusal string

func (r refusal) Error() string { return string(r) }
