// Package capa is `rsdd corroborate capa`: a bounded, offline capability inventory of a PE/ELF/.NET binary
// from FLARE capa, run inside a network-denied Bubblewrap sandbox (capa-evidence.v1, see
// research-sdd/toolbelt/capa-evidence.v1.md).
//
// The package is split by concern: args/usage (the argparse-compatible command line), rules (the --rules
// validation and sandbox bind), run (the bounded sandbox run), pyjson/inventory (capa's JSON and the bounded
// capability list) and this file (the orchestration and the evidence document).
package capa

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math/big"
	"os"
	"strings"
	"syscall"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/adapter"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/adapter/helpers"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/fsx"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/proc"
)

const (
	schema  = "capa-evidence.v1"
	profile = "PROFILE_BWRAP_CAPA_OFFLINE"
)

// limitations are the fixed disclaimers every report carries.
var limitations = []string{
	"capa performs static analysis using the vivisect backend; results vary by " +
		"binary format (PE, ELF, .NET) and may miss capabilities requiring dynamic analysis.",
	"Only capabilities matched by the supplied rule set are reported; the installed " +
		"capa version is captured dynamically in capabilities.capa_version.",
	"Bubblewrap on WSL2 provides network isolation but is not a full hostile-parser " +
		"security boundary; use a disposable VM for actively hostile samples.",
	"Caps (--max-capabilities, --timeout) and output/process limits bound resource " +
		"use; any cap that fires is reported in limitations and truncated is set " +
		"true — never silent.",
}

// Run is `rsdd corroborate capa`. Exit codes: 0 complete, 1 evidence published with status=failed (or an
// internal error), 2 a fail-closed refusal or a usage error.
func Run(args []string, s cli.Stdio) int {
	opts, err := parseArgs(args)
	var ae *argError
	switch {
	case errors.Is(err, errHelp):
		_, _ = io.WriteString(s.Out, helpText(terminalWidth(s.Env("COLUMNS"))))
		return cli.ExitOK
	case errors.As(err, &ae):
		_, _ = io.WriteString(s.Err, usageText(terminalWidth(s.Env("COLUMNS"))))
		fmt.Fprintf(s.Err, "%s: error: %s\n", prog, ae.msg)
		return cli.ExitUsage
	}
	code, err := execute(opts, s)
	var c *crash
	switch {
	case errors.As(err, &c):
		fmt.Fprintf(s.Err, "%s: internal error: %s\n", prog, c.msg)
		return cli.ExitOperational
	case err != nil:
		fmt.Fprintf(s.Err, "%s: %s\n", prog, err)
		return cli.ExitUsage
	}
	return code
}

// lookupEnv distinguishes an unset variable from an empty one, which Stdio.Env cannot.
func lookupEnv(s cli.Stdio, key string) (string, bool) {
	if s.Environ == nil {
		v := s.Env(key)
		return v, v != ""
	}
	prefix := key + "="
	for _, kv := range s.Environ() {
		if strings.HasPrefix(kv, prefix) {
			return kv[len(prefix):], true
		}
	}
	return "", false
}

// asFail turns an error from core into the one-line failure the legacy main() prints.
func asFail(err error) error {
	var f *fail
	var c *crash
	if errors.As(err, &f) || errors.As(err, &c) {
		return err
	}
	return &fail{err.Error()}
}

func record(r fsx.Record) map[string]any {
	return map[string]any{"path": r.Path, "size": r.Size, "sha256": r.SHA256}
}

// execute is the body of the legacy main(): validate, stage, run capa in the sandbox, publish.
func execute(opts options, s cli.Stdio) (code int, err error) {
	one := big.NewInt(1)
	if opts.timeout.Cmp(one) < 0 {
		return 0, failf("--timeout must be >= 1")
	}
	if opts.maxCapabilities.Cmp(one) < 0 {
		return 0, failf("--max-capabilities must be >= 1")
	}
	for _, part := range pyParts(opts.output) {
		if part == ".." {
			return 0, failf("output must be a canonical path")
		}
	}
	if strings.Contains(opts.output, "\\") {
		return 0, failf("output must be a canonical path")
	}
	parent, err := resolve(pyParent(opts.output), true, s.Cwd)
	if err != nil {
		return 0, &fail{relativeFailure(err, pyParent(opts.output), s.Cwd)}
	}
	mountinfo, err := adapter.HostMountinfo()
	if err != nil {
		return 0, &fail{osErrorText(err, "/proc/self/mountinfo")}
	}
	if err := adapter.RequirePrivate(parent, mountinfo); err != nil {
		return 0, asFail(err)
	}
	destination := joinPath(parent, pyName(opts.output))
	for _, check := range []func(string) (os.FileInfo, error){os.Stat, os.Lstat} {
		if _, serr := check(destination); serr == nil {
			return 0, failf("output must be a new non-colliding path")
		} else if !errors.Is(serr, os.ErrNotExist) && !errors.Is(serr, syscall.ENOTDIR) && !errors.Is(serr, syscall.ELOOP) {
			return 0, &fail{osErrorText(serr, destination)}
		}
	}
	if _, err := resolve(opts.manifestCLI, true, s.Cwd); err != nil {
		return 0, &fail{relativeFailure(err, opts.manifestCLI, s.Cwd)}
	}

	home := func() (string, bool) { return lookupEnv(s, "HOME") }
	renv := rulesEnv{cwd: s.Cwd, home: home}
	resolvedRules, err := validateRulesDir(renv, opts.rules)
	if err != nil {
		return 0, err
	}

	searchPath, _ := lookupEnv(s, "PATH")
	host := adapter.DefaultHost(os.Getuid(), s.Cwd)
	bwrapExe, bwrapRec, err := executable(host, s, "bwrap", "RSDD_BWRAP", searchPath)
	if err != nil {
		return 0, err
	}
	capaExe, capaRec, err := executable(host, s, "capa", "RSDD_CAPA", searchPath)
	if err != nil {
		return 0, err
	}
	capaVer := capaVersion(capaExe, s.Environ(), s.Cwd, s.Clock)
	rulesID, err := rulesPathDigest(resolvedRules)
	if err != nil {
		return 0, err
	}

	stage := parent + "/." + pyName(opts.output) + ".stage"
	defer func() {
		if stage != "" {
			if _, serr := os.Stat(stage); serr == nil {
				_ = os.RemoveAll(stage)
			}
		}
	}()
	for _, d := range []struct {
		path string
		perm os.FileMode
	}{{stage, 0o700}, {stage + "/input", 0o777}, {stage + "/engine", 0o777}} {
		if err := os.Mkdir(d.path, d.perm); err != nil {
			return 0, &fail{osErrorText(err, d.path)}
		}
	}
	input := opts.input
	if !strings.HasPrefix(input, "/") {
		input = strings.TrimRight(s.Cwd, "/") + "/" + input
	}
	sourceRec, stagedRec, err := fsx.StageFile(input, stage+"/input/binary.bin", "input/binary.bin", 0o400, fsx.NoLimit)
	if err != nil {
		return 0, asFail(err)
	}

	env := sandboxEnv()
	prefix, err := adapter.Sandbox(host, bwrapExe, env, nil)
	if err != nil {
		return 0, asFail(err)
	}
	prefix, err = helpers.BindVenv(helpers.Env{Cwd: s.Cwd, Home: renv.homeDir()}, prefix, capaExe, []string{"/etc/passwd", "/etc/group"}, nil)
	if err != nil {
		return 0, asFail(err)
	}
	if prefix, err = bindRules(prefix, resolvedRules); err != nil {
		return 0, err
	}

	capaArgv := []string{capaExe, "-r", sandboxRulesPath, "-j", "/tmp/rsdd/work/input/binary.bin"}
	cmd := append(append([]string{}, prefix...), capaArgv...)
	capaIdx := len(prefix)

	envList := make([]string, len(env))
	for i, e := range env {
		envList[i] = e.Key + "=" + e.Value
	}
	run, runErrors, err := runBounded(cmd, stage, envList, opts.timeout, maxOutputBytes, s.Clock)
	if err != nil {
		return 0, err
	}
	capaJSON, parseErr, err := readStdoutJSON(stage + "/engine/stdout.txt")
	if err != nil {
		return 0, err
	}
	inv, invLimitations, err := buildInventory(capaJSON, opts.maxCapabilities)
	if err != nil {
		return 0, err
	}
	runTrunc, truncLimitations := helpers.RunTruncation(runErrors, "capa")
	allLimitations := append(append(append([]string{}, limitations...), invLimitations...), truncLimitations...)
	allErrors := append([]string{}, runErrors...)
	if parseErr != "" {
		allErrors = append(allErrors, parseErr)
	}

	prof := adapter.NamedProfiles()[profile].Map()
	capabilities := map[string]any{
		"items": inv.items, "total_count": inv.totalCount, "total_sampled": inv.totalSampled,
		"truncated":    inv.truncated || runTrunc,
		"argv":         capaArgv,
		"caps":         map[string]any{"max_capabilities": bigNumber(opts.maxCapabilities), "timeout": bigNumber(opts.timeout)},
		"capa_version": capaVer, "rules_path_digest": rulesID, "tool": record(capaRec),
	}
	spec := map[string]any{
		"argv": cmd, "completeness": completeness(allErrors), "environment": envMap(env), "errors": allErrors,
		"findings":          []any{},
		"input":             map[string]any{"detected_type": "PE/ELF/.NET binary", "path": "input/binary.bin"},
		"isolation_profile": prof, "limitations": allLimitations, "outputs": []string{schema + ".json"},
		"run": run, "schema_version": "analysis-manifest.v1",
		"stderr_path": "engine/stderr.txt", "stdout_path": "engine/stdout.txt",
		"tool": map[string]any{
			"artifacts":  []any{map[string]any{"argv_index": capaIdx, "path": capaExe}},
			"executable": bwrapExe, "name": "capa", "version": capaVer,
		},
	}
	err = helpers.EmitEvidence(helpers.EmitConfig{
		Stage: stage, Schema: schema, Domain: map[string]any{"capabilities": capabilities},
		InputIdentity: map[string]any{"source": record(sourceRec), "staged": record(stagedRec)},
		Isolation:     map[string]any{"launcher": record(bwrapRec), "profile": prof},
		Limitations:   allLimitations, Errors: allErrors, ManifestSpec: spec,
		ManifestCLI: []string{inProcess, "manifest"}, Destination: destination, Timeout: 60,
		Env: s.Environ(), Stdout: s.Out, Stderr: s.Err, Run: manifestRunner(s),
	})
	if err != nil {
		return 0, asFail(err)
	}
	stage = ""
	if len(allErrors) > 0 {
		return cli.ExitOperational, nil
	}
	return cli.ExitOK, nil
}

func completeness(errs []string) string {
	if len(errs) > 0 {
		return "failed"
	}
	return "complete"
}

func bigNumber(n *big.Int) any { return json.Number(n.String()) }

// sandboxEnv is the fixed environment of the sandboxed run, in the legacy tool's order.
func sandboxEnv() []adapter.EnvVar {
	return []adapter.EnvVar{
		{Key: "HOME", Value: "/tmp/rsdd/home"}, {Key: "LANG", Value: "C.UTF-8"}, {Key: "LC_ALL", Value: "C.UTF-8"},
		{Key: "PATH", Value: "/usr/bin:/usr/sbin:/bin:/sbin"}, {Key: "TMPDIR", Value: "/tmp/rsdd"}, {Key: "TZ", Value: "UTC"},
		{Key: "XDG_CACHE_HOME", Value: "/tmp/rsdd/cache"}, {Key: "XDG_CONFIG_HOME", Value: "/tmp/rsdd/config"},
		{Key: "XDG_DATA_HOME", Value: "/tmp/rsdd/data"},
	}
}

func envMap(env []adapter.EnvVar) map[string]any {
	m := make(map[string]any, len(env))
	for _, e := range env {
		m[e.Key] = e.Value
	}
	return m
}

// executable is adapter_core.executable with the configured override read from the environment.
func executable(host adapter.Host, s cli.Stdio, name, envKey, searchPath string) (string, fsx.Record, error) {
	var configured *string
	if v, ok := lookupEnv(s, envKey); ok {
		configured = &v
	}
	path, rec, err := adapter.Executable(host, name, configured, searchPath)
	if err != nil {
		return "", fsx.Record{}, asFail(err)
	}
	return path, rec, nil
}

// inProcess marks the manifest "CLI" that EmitEvidence invokes: the manifest steps run inside this process
// through core/adapter (the --manifest-cli path is validated but not executed).
const inProcess = "rsdd-in-process"

// manifestRunner executes the analysis-manifest verbs in-process.
func manifestRunner(s cli.Stdio) func(proc.Spec) (proc.Result, error) {
	return func(spec proc.Spec) (proc.Result, error) {
		var out, errb bytes.Buffer
		inner := s
		inner.In, inner.Out, inner.Err = strings.NewReader(""), &out, &errb
		rc := adapter.ManifestRun(spec.Argv[2:], inner)
		return proc.Result{Stdout: out.Bytes(), Stderr: errb.Bytes(), ReturnCode: rc}, nil
	}
}

// joinPath is parent / name.
func joinPath(parent, name string) string {
	if name == "" {
		return parent
	}
	return strings.TrimRight(parent, "/") + "/" + name
}

// relativeFailure prints a strict-resolve failure the way posixpath.realpath does for a relative input:
// the failing component relative to the working directory.
func relativeFailure(err error, p, cwd string) string {
	msg := err.Error()
	if !strings.HasPrefix(p, "/") && cwd != "" {
		prefix := strings.TrimRight(cwd, "/") + "/"
		msg = strings.Replace(msg, "'"+prefix, "'", 1)
	}
	return msg
}
