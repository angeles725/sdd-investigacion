// Package kaitai is `rsdd corroborate kaitai`: the port of toolbelt/corroborate_kaitai.py.
//
// Two stages, both in network-denied Bubblewrap sandboxes:
//
//	Stage 1 (JVM): kaitai-struct-compiler turns the .ksy into a Python parser (engine/gen/<meta_id>.py).
//	Stage 2 (Python): lib/kaitai_driver.py, run by the rsdd-kaitai venv, walks SEQ_FIELDS and _debug offsets
//	and prints bounded JSON.
//
// Stage 2 stays Python because ksc emits Python source that only the kaitaistruct runtime can execute (a Go
// target would need a Go toolchain at run time and would change the evidence). The driver is the one inner
// step left outside Go; everything around it (staging, sandboxes, caps, evidence, manifest) is Go. The evidence
// contract is toolbelt/kaitai-evidence.v1.md.
package kaitai

import (
	"bytes"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/adapter"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/adapter/helpers"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/fsx"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kit"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/proc"
)

const (
	schema         = "kaitai-evidence.v1"
	ksyMaxBytes    = 1 << 20
	defaultTimeout = 300
	compileTimeout = 60
	outputCap      = 4 << 20
	compileCap     = 2 << 20
	driverRel      = "toolbelt/lib/kaitai_driver.py"
	inprocManifest = "rsdd-adapter-manifest"
)

const usage = `usage: corroborate-kaitai --input BINARY --ksy STRUCT.ksy --output DIR [--timeout S] [--compile-timeout S]
                         [--max-fields N] [--max-depth N] [--max-value-bytes N] [--max-memory-mb N]

Kaitai Struct binary parsing evidence adapter (kaitai-evidence.v1).
Exit codes: 0 complete, 1 analysis failed (evidence published), 2 fatal (no evidence).
`

// env is everything Run reads from the machine, injected so tests drive every outcome.
type env struct {
	s          cli.Stdio
	cwd, home  string
	host       adapter.Host
	run        func(proc.Spec) (proc.Result, error)
	mountinfo  func() (string, error)
	driverPath func() (string, error)
}

func (e *env) getenv(k string) string { return e.s.Env(k) }

func (e *env) getenvDefault(k, def string) string {
	if v := e.s.Env(k); v != "" {
		return v
	}
	return def
}

func (e *env) abs(p string) string {
	if filepath.IsAbs(p) {
		return filepath.Clean(p)
	}
	return filepath.Join(e.cwd, p)
}

// Run is `rsdd corroborate kaitai`.
func Run(args []string, s cli.Stdio) int {
	e := &env{
		s: s, cwd: s.Cwd, home: s.Env("HOME"),
		host:      adapter.DefaultHost(adapter.CurrentCreds().UID, s.Cwd),
		run:       proc.Run,
		mountinfo: adapter.HostMountinfo,
		driverPath: func() (string, error) {
			p, _, err := kit.ResolveKitScript(driverRel, s.Env)
			return p, err
		},
	}
	return e.main(args)
}

type options struct {
	input, ksy, output                              string
	timeout, compileTimeout                         int
	maxFields, maxDepth, maxValueBytes, maxMemoryMB int
}

func (e *env) parse(args []string) (options, int) {
	o := options{}
	fs := flag.NewFlagSet("corroborate-kaitai", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	fs.StringVar(&o.input, "input", "", "")
	fs.StringVar(&o.ksy, "ksy", "", "")
	fs.StringVar(&o.output, "output", "", "")
	fs.IntVar(&o.timeout, "timeout", defaultTimeout, "")
	fs.IntVar(&o.compileTimeout, "compile-timeout", compileTimeout, "")
	fs.IntVar(&o.maxFields, "max-fields", 2000, "")
	fs.IntVar(&o.maxDepth, "max-depth", 32, "")
	fs.IntVar(&o.maxValueBytes, "max-value-bytes", 64, "")
	fs.IntVar(&o.maxMemoryMB, "max-memory-mb", 256, "")
	var legacy string
	fs.StringVar(&legacy, "manifest-cli", "", "") // accepted and ignored: the manifest CLI runs in-process
	if err := fs.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			_, _ = io.WriteString(e.s.Out, usage)
			return o, 0
		}
		_, _ = io.WriteString(e.s.Err, usage+"corroborate-kaitai: error: "+err.Error()+"\n")
		return o, cli.ExitUsage
	}
	var missing []string
	for _, r := range [][2]string{{"--input", o.input}, {"--ksy", o.ksy}, {"--output", o.output}} {
		if r[1] == "" {
			missing = append(missing, r[0])
		}
	}
	if len(missing) > 0 || fs.NArg() > 0 {
		msg := "the following arguments are required: " + strings.Join(missing, ", ")
		if len(missing) == 0 {
			msg = "unrecognized arguments: " + strings.Join(fs.Args(), " ")
		}
		_, _ = io.WriteString(e.s.Err, usage+"corroborate-kaitai: error: "+msg+"\n")
		return o, cli.ExitUsage
	}
	return o, -1
}

func (e *env) main(args []string) int {
	o, rc := e.parse(args)
	if rc >= 0 {
		return rc
	}
	stage, published, err := "", false, error(nil)
	rc, stage, err = e.pipeline(o, &published)
	if stage != "" && !published {
		_ = os.RemoveAll(stage)
	}
	if err != nil {
		_, _ = fmt.Fprintf(e.s.Err, "corroborate-kaitai: %v\n", err)
		return cli.ExitUsage
	}
	return rc
}

// pyList renders a string list like Python's repr.
func pyList(l []string) string {
	q := make([]string, len(l))
	for i, v := range l {
		q[i] = "'" + v + "'"
	}
	return "[" + strings.Join(q, ", ") + "]"
}

func envPairs(pairs []adapter.EnvVar) ([]string, map[string]string) {
	list := make([]string, len(pairs))
	m := map[string]string{}
	for i, p := range pairs {
		list[i] = p.Key + "=" + p.Value
		m[p.Key] = p.Value
	}
	return list, m
}

func (e *env) pipeline(o options, published *bool) (int, string, error) {
	if o.timeout < 1 || o.compileTimeout < 1 {
		return 0, "", errors.New("timeout values must be positive")
	}
	if o.maxFields < 1 || o.maxDepth < 1 || o.maxValueBytes < 1 {
		return 0, "", errors.New("cap values must be positive")
	}
	out := e.abs(o.output)
	parent, err := resolveStrict(filepath.Dir(out))
	if err != nil {
		return 0, "", err
	}
	mi, err := e.mountinfo()
	if err != nil {
		return 0, "", err
	}
	if err := adapter.RequirePrivate(parent, mi); err != nil {
		return 0, "", err
	}
	name := filepath.Base(out)
	dest := filepath.Join(parent, name)
	if _, err := os.Lstat(dest); err == nil {
		return 0, "", errors.New("output directory must not exist")
	}

	var bwrapCfg *string
	if v := e.getenv("RSDD_BWRAP"); v != "" {
		bwrapCfg = &v
	}
	bwrap, bwrapRec, err := adapter.Executable(e.host, "bwrap", bwrapCfg, e.getenv("PATH"))
	if err != nil {
		return 0, "", err
	}
	ksc, err := e.kscExeFor()
	if err != nil {
		return 0, "", err
	}
	jdkHome, err := e.jdkHomeFor()
	if err != nil {
		return 0, "", err
	}
	kscVer := e.kscVersion(ksc)
	pyRaw := e.getenvDefault("RSDD_KAITAI_PY", "~/.local/share/rsdd-kaitai/bin/python")
	if strings.HasPrefix(pyRaw, "~/") {
		pyRaw = filepath.Join(e.home, pyRaw[2:])
	}
	pyRaw = e.abs(pyRaw)
	if _, err := resolveStrict(pyRaw); err != nil {
		return 0, "", err
	}
	driverLib, err := e.driverPath()
	if err != nil {
		return 0, "", errors.New("kaitai_driver.py not found: " + err.Error())
	}

	stage := filepath.Join(parent, "."+name+".stage")
	if err := os.Mkdir(stage, 0o700); err != nil {
		return 0, "", err
	}
	for _, d := range []string{"input", "engine", "engine/gen"} {
		if err := os.Mkdir(filepath.Join(stage, d), 0o777); err != nil {
			return 0, stage, err
		}
	}
	ksySrc, _, err := fsx.StageFile(e.abs(o.ksy), stage+"/input/struct.ksy", "input/struct.ksy", 0o400, ksyMaxBytes)
	if err != nil {
		return 0, stage, err
	}

	// Stage 1: ksc compile. The untrusted binary is staged only afterwards.
	s1Env := []adapter.EnvVar{
		{Key: "HOME", Value: "/tmp/rsdd/home"}, {Key: "JAVA_HOME", Value: jdkHome},
		{Key: "LANG", Value: "C.UTF-8"}, {Key: "LC_ALL", Value: "C.UTF-8"},
		{Key: "PATH", Value: "/usr/bin:/usr/sbin:/bin:/sbin"},
		{Key: "TMPDIR", Value: "/tmp/rsdd"}, {Key: "TZ", Value: "UTC"},
	}
	if brew, ok := brewRootFor(ksc); ok {
		s1Env[4].Value = brew + "/bin:" + s1Env[4].Value
	}
	prefix1, err := adapter.Sandbox(e.host, bwrap, s1Env, nil)
	if err != nil {
		return 0, stage, err
	}
	genHost := stage + "/engine/gen"
	if prefix1, err = e.bindJVMToolchain(prefix1, ksc, jdkHome, genHost); err != nil {
		return 0, stage, err
	}
	cmd1 := append(append([]string{}, prefix1...), ksc, "--target", "python", "--outdir", "/tmp/rsdd/gen", "--debug", "/tmp/rsdd/work/input/struct.ksy")
	env1, _ := envPairs(s1Env)
	_, s1Errs, _, err := e.runBounded(stage, cmd1, env1, o.compileTimeout, compileCap)
	if err != nil {
		return 0, stage, err
	}
	if len(s1Errs) > 0 {
		stderr, _ := os.ReadFile(stage + "/engine/stderr.txt")
		return 0, stage, fmt.Errorf("ksc compile failed (errors=%s): %s", pyList(s1Errs), strconv.Quote(head500(stderr)))
	}
	for _, n := range []string{"stdout", "stderr"} {
		if err := os.Rename(stage+"/engine/"+n+".txt", stage+"/engine/compile-"+n+".txt"); err != nil {
			return 0, stage, err
		}
	}
	stem, err := genStem(genHost)
	if err != nil {
		return 0, stage, err
	}
	parserID, err := fsx.Identity(genHost+"/"+stem+".py", fsx.NoLimit)
	if err != nil {
		return 0, stage, err
	}

	binSrc, binStaged, err := fsx.StageFile(e.abs(o.input), stage+"/input/binary.bin", "input/binary.bin", 0o400, fsx.NoLimit)
	if err != nil {
		return 0, stage, err
	}
	if _, _, err := fsx.StageFile(driverLib, stage+"/engine/driver.py", "engine/driver.py", 0o500, fsx.NoLimit); err != nil {
		return 0, stage, err
	}

	// Stage 2: the Python driver walks the parsed structure.
	s2Env := []adapter.EnvVar{
		{Key: "HOME", Value: "/tmp/rsdd/home"}, {Key: "LANG", Value: "C.UTF-8"}, {Key: "LC_ALL", Value: "C.UTF-8"},
		{Key: "PATH", Value: "/usr/bin:/usr/sbin:/bin:/sbin"}, {Key: "TMPDIR", Value: "/tmp/rsdd"}, {Key: "TZ", Value: "UTC"},
	}
	prefix2, err := adapter.Sandbox(e.host, bwrap, s2Env, nil)
	if err != nil {
		return 0, stage, err
	}
	if prefix2, err = e.bindKaitaiVenv(prefix2, pyRaw); err != nil {
		return 0, stage, err
	}
	cmd2 := append(append([]string{}, prefix2...), pyRaw, "/tmp/rsdd/work/engine/driver.py",
		"--module-dir", "/tmp/rsdd/work/engine/gen", "--stem", stem, "--input", "/tmp/rsdd/work/input/binary.bin",
		"--max-fields", strconv.Itoa(o.maxFields), "--max-depth", strconv.Itoa(o.maxDepth),
		"--max-value-bytes", strconv.Itoa(o.maxValueBytes), "--max-memory-mb", strconv.Itoa(o.maxMemoryMB))
	env2, env2Map := envPairs(s2Env)
	s2Run, s2Errs, _, err := e.runBounded(stage, cmd2, env2, o.timeout, outputCap)
	if err != nil {
		return 0, stage, err
	}

	driver, parseErr := readDriverJSON(stage + "/engine/stdout.txt")
	lims, errs, truncated := buildLimitationsAndErrors(driver, s2Errs, parseErr)
	structureBlock, runtimeVersion := structure(driver, stem, truncated, parseErr)
	if driver == nil && len(errs) == 0 {
		errs = append(errs, "driver produced no output")
	}

	rec := func(r fsx.Record) map[string]any {
		return map[string]any{"path": r.Path, "size": r.Size, "sha256": r.SHA256}
	}
	profile := adapter.NamedProfiles()["PROFILE_BWRAP_KAITAI_OFFLINE"].Map()
	domain := map[string]any{
		"compile": map[string]any{
			"generated_parser": map[string]any{"path": "engine/gen/" + stem + ".py", "sha256": parserID.SHA256, "size": parserID.Size},
			"ksc_version":      kscVer,
		},
		"ksy_identity":    map[string]any{"sha256": ksySrc.SHA256, "size": ksySrc.Size, "path": ksySrc.Path},
		"runtime_version": runtimeVersion,
		"structure":       structureBlock,
	}
	completeness := "complete"
	if len(errs) > 0 {
		completeness = "failed"
	}
	spec := map[string]any{
		"argv": cmd2, "completeness": completeness, "environment": env2Map, "errors": errs, "findings": []any{},
		"input":             map[string]any{"detected_type": "binary/kaitai-struct-parsed", "path": "input/binary.bin"},
		"isolation_profile": profile, "limitations": lims,
		"outputs": []string{
			schema + ".json", "input/struct.ksy", "engine/driver.py", "engine/gen/" + stem + ".py",
			"engine/compile-stdout.txt", "engine/compile-stderr.txt",
		},
		"run": s2Run, "schema_version": "analysis-manifest.v1",
		"stderr_path": "engine/stderr.txt", "stdout_path": "engine/stdout.txt",
		"tool": map[string]any{"artifacts": []any{}, "executable": bwrap, "name": "kaitai-struct-driver", "version": runtimeVersion},
	}
	err = helpers.EmitEvidence(helpers.EmitConfig{
		Stage: stage, Schema: schema, Domain: domain,
		InputIdentity: map[string]any{"source": rec(binSrc), "staged": rec(binStaged)},
		Isolation:     map[string]any{"launcher": map[string]any{"path": bwrapRec.Path, "sha256": bwrapRec.SHA256}, "profile": profile},
		Limitations:   lims, Errors: errs, ManifestSpec: spec,
		ManifestCLI: []string{inprocManifest}, Destination: dest, Timeout: 60,
		Env: e.s.Environ(), Stdout: e.s.Out, Stderr: e.s.Err, Run: e.runCLI,
	})
	if err != nil {
		return 0, stage, err
	}
	*published = true
	if len(errs) > 0 {
		return 1, stage, nil
	}
	return 0, stage, nil
}

// runCLI serves the manifest CLI in-process (`rsdd adapter manifest`) and every other program as a child.
func (e *env) runCLI(sp proc.Spec) (proc.Result, error) {
	if len(sp.Argv) == 0 || sp.Argv[0] != inprocManifest {
		return e.run(sp)
	}
	var out, errb bytes.Buffer
	rc := adapter.ManifestRun(sp.Argv[1:], cli.Stdio{Out: &out, Err: &errb, Env: e.s.Env, Cwd: e.cwd})
	return proc.Result{Stdout: out.Bytes(), Stderr: errb.Bytes(), ReturnCode: rc}, nil
}

// kscVersion is _ksc_version: best-effort `ksc --version`.
func (e *env) kscVersion(ksc string) string {
	res, err := e.run(proc.Spec{Argv: []string{ksc, "--version"}, Env: e.s.Environ(), Timeout: 30 * time.Second, MaxBytes: 1 << 20})
	if err != nil {
		return "unknown (" + err.Error() + ")"
	}
	out := strings.TrimSpace(string(res.Stdout) + string(res.Stderr))
	if out == "" {
		return "unknown"
	}
	return cut100(out)
}

// runBounded is run_bounded: the output lands in stage/engine/{stdout,stderr}.txt; it returns the run record, the
// error list and the exit code.
func (e *env) runBounded(stage string, argv, envList []string, timeoutSec, maxBytes int) (map[string]any, []string, int, error) {
	res, err := e.run(proc.Spec{Argv: argv, Dir: stage, Env: envList, Timeout: time.Duration(timeoutSec) * time.Second, MaxBytes: maxBytes, Now: e.s.Clock})
	if err != nil {
		return nil, nil, 0, err
	}
	if err := os.WriteFile(stage+"/engine/stdout.txt", res.Stdout, 0o666); err != nil {
		return nil, nil, 0, err
	}
	if err := os.WriteFile(stage+"/engine/stderr.txt", res.Stderr, 0o666); err != nil {
		return nil, nil, 0, err
	}
	record := map[string]any{
		"started_at": isoZ(res.Started), "ended_at": isoZ(res.Ended), "duration_ms": res.Duration.Milliseconds(),
		"exit_code": nil, "signal": nil,
	}
	if res.ReturnCode >= 0 {
		record["exit_code"] = res.ReturnCode
	} else {
		record["signal"] = -res.ReturnCode
	}
	return record, res.Errors(), res.ReturnCode, nil
}

// isoZ is datetime.isoformat() with "+00:00" replaced by "Z" (no fraction when the microseconds are zero).
func isoZ(t time.Time) string {
	t = t.UTC()
	if t.Nanosecond()/1000 == 0 {
		return t.Format("2006-01-02T15:04:05") + "Z"
	}
	return t.Format("2006-01-02T15:04:05.000000") + "Z"
}
