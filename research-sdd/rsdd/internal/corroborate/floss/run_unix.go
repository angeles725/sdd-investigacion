//go:build unix

package floss

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"math/big"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"
	"unicode/utf8"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/adapter"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/adapter/helpers"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/fsx"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/proc"
)

// Differences from corroborate_floss.py, all stricter or crash-free (documented in floss-evidence.v1.md):
//   - A stage directory that already exists (another run in flight, or a leftover) is never deleted by the run
//     that failed to create it; the script's cleanup removed it.
//   - floss output the script would crash on (a document that is not an object, a category that is not an
//     array, entries that are not objects, a non-string "string", a non-numeric "offset"), bytes that are not
//     UTF-8 JSON text and lone surrogates end the run with "corroborate-floss: <reason>" and exit 2, where the
//     script printed a traceback and exited 1 (or, for a lone surrogate, published evidence).
//   - NaN, Infinity and a float beyond the double range inside floss output are refused where the script would
//     have carried them through or printed Infinity.
//   - The manifest steps run in process (core/adapter), not through python3; --manifest-cli is accepted for
//     compatibility and ignored.
//   - An integer option beyond 4300 digits is a usage error, as in Python 3.12.

// Seams the tests replace.
var (
	executablePath = os.Executable
	readMountinfo  = adapter.HostMountinfo
)

const (
	schema = "floss-evidence.v1"
	// maxOutputBytes caps stdout+stderr of the sandboxed run (4 MiB is generous for floss JSON output).
	maxOutputBytes = 4 * 1024 * 1024
	versionTimeout = 15 * time.Second
	manifestWait   = 60
)

// limitations are the fixed statements every evidence carries.
var limitations = []string{
	"floss performs static + emulation-based string recovery; results vary by binary " +
		"format and obfuscation technique.",
	"Stack string, tight string, and decoded string extraction requires PE format; ELF " +
		"and other formats yield static strings only — a non-zero exit is recorded as an " +
		"error and evidence is published with status=failed.",
	"Bubblewrap on WSL2 provides network isolation but is not a full hostile-parser " +
		"security boundary; use a disposable VM for actively hostile samples.",
	"Caps (--max-strings, --max-string-len, --timeout) and output/process limits bound " +
		"resource use; any cap that fires is reported in limitations and truncated is set " +
		"true — never silent.",
}

// Run is `rsdd corroborate floss --input FILE --output NEWDIR [--timeout S] [--max-strings N]
// [--max-string-len N] [--manifest-cli ignored]`: a bounded, offline obfuscated-string inventory of
// a binary, produced by floss inside a network-denied Bubblewrap sandbox (floss-evidence.v1).
//
// Exit codes: 0 complete, 1 evidence published with errors (status=failed), 2 a refusal or usage error.
func Run(args []string, s cli.Stdio) int {
	opts, code, done := parseArgs(args, terminalWidth(s), s.Out, s.Err)
	if done {
		return code
	}
	var stage string
	exit, err := run(opts, s, &stage)
	if stage != "" {
		_ = os.RemoveAll(stage)
	}
	if err != nil {
		fmt.Fprintf(s.Err, "corroborate-floss: %s\n", errorText(err))
		return cli.ExitUsage
	}
	return exit
}

// terminalWidth is argparse's formatter width: COLUMNS (when a positive int, else 80) minus 2.
func terminalWidth(s cli.Stdio) int {
	if n, ok := parsePyInt(s.Env("COLUMNS")); ok && n.Sign() > 0 && n.IsInt64() && n.Int64() < 1<<20 {
		return int(n.Int64()) - 2
	}
	return 78
}

// run does the work. stage is set as soon as the stage directory is ours, so the caller removes it on any
// return. It returns the process exit code (0 or 1) or an error for exit 2.
func run(o options, s cli.Stdio, stage *string) (int, error) {
	if o.timeout.Cmp(big.NewInt(1)) < 0 {
		return 0, flossErr("--timeout must be >= 1")
	}
	if o.maxStrings.Cmp(big.NewInt(1)) < 0 {
		return 0, flossErr("--max-strings must be >= 1")
	}
	if o.maxStringLen.Cmp(big.NewInt(1)) < 0 {
		return 0, flossErr("--max-string-len must be >= 1")
	}
	// Output path safety.
	outParts := pathParts(o.output)
	for _, p := range outParts {
		if p == ".." {
			return 0, flossErr("output must be a canonical path")
		}
	}
	if strings.Contains(o.output, `\`) {
		return 0, flossErr("output must be a canonical path")
	}
	name, parentArg := splitPath(o.output)
	parent, err := resolveStrict(s.Cwd, parentArg)
	if err != nil {
		return 0, err
	}
	mi, err := readMountinfo()
	if err != nil {
		return 0, mountinfoError(err)
	}
	if err := adapter.RequirePrivate(parent, mi); err != nil {
		return 0, err
	}
	destination := parent
	if name != "" {
		destination = filepath.Join(parent, name)
	}
	if _, err := os.Stat(destination); err == nil {
		return 0, flossErr("output must be a new non-colliding path")
	}
	if _, err := os.Lstat(destination); err == nil {
		return 0, flossErr("output must be a new non-colliding path")
	}

	// Resolve tools.
	host := adapter.DefaultHost(os.Getuid(), s.Cwd)
	search := s.Env("PATH")
	bwrapExe, bwrapRec, err := adapter.Executable(host, "bwrap", configured(s, "RSDD_BWRAP"), search)
	if err != nil {
		return 0, err
	}
	flossExe, flossRec, err := adapter.Executable(host, "floss", configured(s, "RSDD_FLOSS"), search)
	if err != nil {
		return 0, err
	}
	flossVersion := probeVersion(s, flossExe)

	// Staging directory.
	st := filepath.Join(parent, "."+filepath.Base(destination)+".stage")
	if err := os.Mkdir(st, 0o700); err != nil {
		return 0, err
	}
	*stage = st
	for _, d := range []string{"input", "engine"} {
		if err := os.Mkdir(filepath.Join(st, d), 0o777); err != nil {
			return 0, err
		}
	}
	srcRec, stagedRec, err := fsx.StageFile(joinCwd(s.Cwd, o.input), filepath.Join(st, "input", "binary.bin"), "input/binary.bin", 0o400, fsx.NoLimit)
	if err != nil {
		return 0, err
	}

	// Sandbox: the hardened bwrap prefix plus the floss venv, bound read-only. /etc/passwd and /etc/group are
	// the one narrow exception: vivisect calls getpass.getuser() -> pwd.getpwuid().
	env := []adapter.EnvVar{
		{Key: "HOME", Value: "/tmp/rsdd/home"}, {Key: "LANG", Value: "C.UTF-8"}, {Key: "LC_ALL", Value: "C.UTF-8"},
		{Key: "PATH", Value: "/usr/bin:/usr/sbin:/bin:/sbin"}, {Key: "TMPDIR", Value: "/tmp/rsdd"}, {Key: "TZ", Value: "UTC"},
		{Key: "XDG_CACHE_HOME", Value: "/tmp/rsdd/cache"}, {Key: "XDG_CONFIG_HOME", Value: "/tmp/rsdd/config"},
		{Key: "XDG_DATA_HOME", Value: "/tmp/rsdd/data"},
	}
	prefix, err := adapter.Sandbox(host, bwrapExe, env, nil)
	if err != nil {
		return 0, err
	}
	prefix, err = helpers.BindVenv(helpers.Env{Cwd: s.Cwd, Home: homeDir(s)}, prefix, flossExe, []string{"/etc/passwd", "/etc/group"}, nil)
	if err != nil {
		return 0, err
	}
	// The argv recorded in the evidence uses fixed in-sandbox paths, so identical runs with different output
	// names stay byte-identical.
	const inputInSandbox = "/tmp/rsdd/work/input/binary.bin"
	flossArgv := []string{flossExe, "-j", inputInSandbox}
	cmd := append(append([]string{}, prefix...), flossArgv...)
	flossIdx := len(prefix)

	helper, err := executablePath()
	if err != nil {
		return 0, err
	}
	res, err := proc.Run(proc.Spec{
		Argv: cmd, Dir: st, Env: envList(env),
		Timeout: clampSeconds(o.timeout), MaxBytes: maxOutputBytes,
		Limits: []proc.Limit{{Resource: "fsize", Value: maxOutputBytes}}, Helper: helper,
		Now: s.Clock,
	})
	if err != nil {
		return 0, err
	}
	for name, data := range map[string][]byte{"stdout.txt": res.Stdout, "stderr.txt": res.Stderr} {
		if err := os.WriteFile(filepath.Join(st, "engine", name), data, 0o666); err != nil {
			return 0, err
		}
	}
	runRecord := runRecordOf(res)
	runErrors := res.Errors()

	// Read floss's JSON from the captured stdout with O_NOFOLLOW protection.
	parsed, parseErr, err := readStdoutJSON(filepath.Join(st, "engine", "stdout.txt"))
	if err != nil {
		return 0, err
	}
	inv, invLimitations, err := buildInventory(parsed, invCaps{
		MaxStrings: clampBig(o.maxStrings), MaxStringLen: clampBig(o.maxStringLen),
		MaxStringsText: o.maxStrings.String(), MaxStringLenText: o.maxStringLen.String(),
	})
	if err != nil {
		return 0, err
	}
	// Any cap that fired (timeout, output-cap, process-cap) makes the inventory visibly incomplete.
	runTrunc, truncLimitations := helpers.RunTruncation(runErrors, "floss")
	inv["truncated"] = inv["truncated"].(bool) || runTrunc

	allLimitations := append(append(append([]string{}, limitations...), invLimitations...), truncLimitations...)
	allErrors := append([]string{}, runErrors...)
	if parseErr != "" {
		allErrors = append(allErrors, parseErr)
	}

	inv["argv"] = flossArgv
	inv["caps"] = map[string]any{
		"max_string_len": bigNumber(o.maxStringLen), "max_strings": bigNumber(o.maxStrings), "timeout": bigNumber(o.timeout),
	}
	inv["floss_version"] = flossVersion
	inv["tool"] = recordMap(flossRec)

	profile := profileMap()
	completeness := completenessOf(allErrors)
	spec := map[string]any{
		"argv": cmd, "completeness": completeness, "environment": envMap(env), "errors": allErrors, "findings": []any{},
		"input":             map[string]any{"detected_type": "PE/ELF binary", "path": "input/binary.bin"},
		"isolation_profile": profile, "limitations": allLimitations, "outputs": []string{schema + ".json"},
		"run": runRecord, "schema_version": "analysis-manifest.v1",
		"stderr_path": "engine/stderr.txt", "stdout_path": "engine/stdout.txt",
		"tool": map[string]any{
			"artifacts":  []any{map[string]any{"argv_index": flossIdx, "path": flossExe}},
			"executable": bwrapExe, "name": "floss", "version": flossVersion,
		},
	}
	err = helpers.EmitEvidence(helpers.EmitConfig{
		Stage: st, Schema: schema, Domain: map[string]any{"strings": inv},
		InputIdentity: map[string]any{"source": recordMap(srcRec), "staged": recordMap(stagedRec)},
		Isolation:     map[string]any{"launcher": recordMap(bwrapRec), "profile": profile},
		Limitations:   allLimitations, Errors: allErrors, ManifestSpec: spec,
		ManifestCLI: []string{inProcess, "manifest"}, Destination: destination, Timeout: manifestWait,
		Env: s.Environ(), Stdout: s.Out, Stderr: s.Err, Run: manifestRunner(s),
	})
	if err != nil {
		return 0, err
	}
	*stage = "" // published: nothing to clean up
	if len(allErrors) > 0 {
		return cli.ExitOperational, nil
	}
	return cli.ExitOK, nil
}

// probeVersion is _version: the first line of `floss --version` (stdout, else stderr), or "unknown" when the
// probe cannot run, times out or prints text that is not UTF-8.
func probeVersion(s cli.Stdio, flossExe string) string {
	res, err := proc.Run(proc.Spec{Argv: []string{flossExe, "--version"}, Dir: s.Cwd, Env: s.Environ(), Timeout: versionTimeout, MaxBytes: 64 << 20})
	if err != nil || res.Reason != "" || !utf8.Valid(res.Stdout) || !utf8.Valid(res.Stderr) {
		return "unknown"
	}
	line := pyStrip(string(res.Stdout))
	if line == "" {
		line = pyStrip(string(res.Stderr))
	}
	if line == "" {
		return "unknown"
	}
	return pyFirstLine(line)
}

// runRecordOf is the run record of the evidence: exit_code for a normal exit, signal for a death by signal.
func runRecordOf(res proc.Result) map[string]any {
	rec := map[string]any{
		"started_at": isoZ(res.Started), "ended_at": isoZ(res.Ended), "duration_ms": res.Duration.Milliseconds(),
		"exit_code": nil, "signal": nil,
	}
	if res.ReturnCode >= 0 {
		rec["exit_code"] = res.ReturnCode
	} else {
		rec["signal"] = -res.ReturnCode
	}
	return rec
}

func completenessOf(errs []string) string {
	if len(errs) > 0 {
		return "failed"
	}
	return "complete"
}

func configured(s cli.Stdio, key string) *string {
	if v := s.Env(key); v != "" {
		return &v
	}
	return nil
}

func envList(env []adapter.EnvVar) []string {
	out := make([]string, 0, len(env))
	for _, e := range env {
		out = append(out, e.Key+"="+e.Value)
	}
	return out
}

func envMap(env []adapter.EnvVar) map[string]any {
	out := make(map[string]any, len(env))
	for _, e := range env {
		out[e.Key] = e.Value
	}
	return out
}

func profileMap() map[string]any {
	return adapter.NamedProfiles()["PROFILE_BWRAP_FLOSS_OFFLINE"].Map()
}

func recordMap(r fsx.Record) map[string]any {
	return map[string]any{"path": r.Path, "size": r.Size, "sha256": r.SHA256}
}

func bigNumber(n *big.Int) json.Number { return json.Number(n.String()) }

// clampBig and clampSeconds bring Python's unbounded ints into the range the run logic uses.
func clampBig(n *big.Int) int64 {
	if !n.IsInt64() {
		if n.Sign() < 0 {
			return -1 << 63
		}
		return 1<<63 - 1
	}
	return n.Int64()
}

func clampSeconds(n *big.Int) time.Duration {
	const max = int64(100 * 365 * 24 * 3600)
	if !n.IsInt64() {
		return time.Duration(max) * time.Second
	}
	return time.Duration(min(n.Int64(), max)) * time.Second
}

// isoZ is datetime.isoformat().replace("+00:00", "Z") for a UTC time: microseconds only when non-zero.
func isoZ(t time.Time) string {
	if t.IsZero() {
		return "0001-01-01T00:00:00Z"
	}
	t = t.UTC()
	if us := t.Nanosecond() / 1000; us != 0 {
		return t.Format("2006-01-02T15:04:05") + fmt.Sprintf(".%06dZ", us)
	}
	return t.Format("2006-01-02T15:04:05Z")
}

func homeDir(s cli.Stdio) string {
	home := strings.TrimRight(s.Env("HOME"), "/")
	if home == "" {
		return "/"
	}
	return home
}

// ---------------------------------------------------------------- pathlib

// pathParts is PurePosixPath(p).parts without the root: empty and "." components are dropped.
func pathParts(p string) []string {
	var out []string
	for _, c := range strings.Split(p, "/") {
		if c != "" && c != "." {
			out = append(out, c)
		}
	}
	return out
}

// splitPath is (Path(p).name, str(Path(p).parent)).
func splitPath(p string) (name, parent string) {
	parts := pathParts(p)
	abs := strings.HasPrefix(p, "/")
	if len(parts) > 0 {
		name, parts = parts[len(parts)-1], parts[:len(parts)-1]
	}
	parent = strings.Join(parts, "/")
	switch {
	case abs:
		parent = "/" + parent
	case parent == "":
		parent = "."
	}
	return name, parent
}

func joinCwd(cwd, p string) string {
	if strings.HasPrefix(p, "/") || cwd == "" {
		return p
	}
	return strings.TrimRight(cwd, "/") + "/" + p
}

// resolveStrict is Path(p).resolve(strict=True): absolute, symlinks followed, every component must exist.
func resolveStrict(cwd, p string) (string, error) {
	abs := joinCwd(cwd, p)
	if !strings.HasPrefix(abs, "/") {
		abs = "/" + abs
	}
	real, err := filepath.EvalSymlinks(filepath.Clean(abs))
	if err != nil {
		return "", err
	}
	return filepath.Clean(real), nil
}

// inProcess marks the manifest "CLI" that EmitEvidence invokes: the manifest steps run inside this process through
// core/adapter, so there is no interpreter and no script to resolve.
const inProcess = "rsdd-in-process"

// manifestRunner executes the analysis-manifest verbs in process; the verb and its arguments follow the marker.
func manifestRunner(s cli.Stdio) func(proc.Spec) (proc.Result, error) {
	return func(spec proc.Spec) (proc.Result, error) {
		var out, errb bytes.Buffer
		inner := s
		inner.In, inner.Out, inner.Err = strings.NewReader(""), &out, &errb
		rc := adapter.ManifestRun(spec.Argv[2:], inner)
		return proc.Result{Stdout: out.Bytes(), Stderr: errb.Bytes(), ReturnCode: rc}, nil
	}
}

// mountinfoError is the OSError Python raises when /proc/self/mountinfo cannot be read.
func mountinfoError(err error) error {
	var pe *fs.PathError
	if errors.As(err, &pe) {
		return err
	}
	if en, ok := errnoOf(err); ok {
		return &fs.PathError{Op: "open", Path: "/proc/self/mountinfo", Err: en}
	}
	return err
}

// errorText is str(exc) of the failure the script would have caught and printed. Only a bare operating system
// error is spelled as Python's OSError; typed failures (fsx, adapter, helpers) already carry the script's text.
func errorText(err error) string {
	switch e := err.(type) {
	case *fs.PathError:
		if en, ok := errnoOf(e.Err); ok {
			return osErrorText(en, e.Path)
		}
	case *os.LinkError:
		if en, ok := errnoOf(e.Err); ok {
			return osErrorText(en, e.Old)
		}
	case *proc.SpawnError:
		if en, ok := errnoOf(e.Err); ok {
			return osErrorText(en, e.Path)
		}
	case syscall.Errno:
		return osErrorText(e, "")
	}
	return err.Error()
}
