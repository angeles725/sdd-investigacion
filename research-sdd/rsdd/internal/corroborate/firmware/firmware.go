// Package firmware is `rsdd corroborate firmware`: the port of toolbelt/corroborate_firmware.py (schema
// firmware-static.v1, contract toolbelt/firmware-static.v1.md; ported by the Go port of the Python toolbelt).
//
// It produces bounded, non-extracting Binwalk (major 2) evidence for one firmware image. The input and the
// analyzer are copied into a private stage by identity (size and sha256, through one no-follow descriptor each;
// the analyzer's owner and mode are checked on that descriptor), the analyzer is run with a fixed argv inside a
// network-denied, capability-free bubblewrap sandbox under wall-clock, output-size and process-count caps, its
// listing is normalised into signatures and entropy edges, and an analysis manifest is written and verified
// before the stage is published with a no-replace rename. A failed or truncated run is still published, with
// status "failed" or "partial" and exit 1; a refusal publishes nothing and exits 2.
//
// Shared behaviour comes from core: adapter (privilege refusal, private-filesystem check, the analysis
// manifest), fsx (identity, staging, atomic writes, publication), jsonout (canonical JSON), proc (the rlimit
// re-exec helper and the process-group kill guard) and helpers (the stderr pointer to the evidence file).
//
// Intended differences from the script:
//   - the manifest tool is called in process (core/adapter), not through python3; --manifest-cli is accepted and
//     ignored, and a manifest failure prints the tool's own message followed by one line naming the exit status;
//   - the output's mount point is checked with core/adapter.RequirePrivate, which refuses a malformed
//     mountinfo line or a path under no mount instead of skipping it;
//   - the isolation probe's timeout is a plain message, not Python's "Command ... timed out";
//   - OS errors read "[Errno N] text: 'path'" with the C library's wording, not always byte for byte;
//   - an unknown or abbreviated option is a usage error with rsdd's own usage text, not argparse's;
//   - a staged analyzer that fails a later check is removed with the rest of the stage, as before, but a
//     staging copy that fails its re-read is removed at once.
package firmware

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/adapter"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/adapter/helpers"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/fsx"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/proc"
)

const (
	prefix       = "corroborate-firmware: "
	exitPartial  = 1
	exitRefused  = 2
	safePath     = "/usr/bin:/bin"
	defaultBwrap = "/usr/bin/bwrap"
	hostRoot     = "/tmp/rsdd"
	probeTimeout = 5 * time.Second
	versionBound = 5
)

// safeArgs is the analyzer's fixed argument vector: no extraction, no recursion, no colour, entropy on.
var safeArgs = []string{"-B", "-E", "-N", "input/firmware.bin"}

// deps are the ambient facts of a run, injectable so every decision is testable without a real sandbox.
type deps struct {
	creds     func() adapter.Creds
	mountinfo func() (string, error)
	self      func() (string, error)
	safePath  string          // where the sandbox launcher must be found
	bwrapUIDs map[uint64]bool // who may own the sandbox launcher
	hostRoot  string          // the host directory the sandbox mounts a tmpfs over
}

func realDeps() deps {
	return deps{creds: adapter.CurrentCreds, mountinfo: adapter.HostMountinfo, self: os.Executable,
		safePath: safePath, bwrapUIDs: map[uint64]bool{0: true}, hostRoot: hostRoot}
}

// Run is the Main contract of `rsdd corroborate firmware`.
func Run(args []string, s cli.Stdio) int { return execute(args, s, realDeps()) }

func execute(args []string, s cli.Stdio, d deps) int {
	c, outcome := parseArgs(args, s.Out, s.Err)
	switch outcome {
	case helpShown:
		return cli.ExitOK
	case usageError:
		return cli.ExitUsage
	}
	code, stage, destination, err := analyze(c, s, d)
	if stage != "" {
		defer os.RemoveAll(stage)
	}
	if err != nil {
		fmt.Fprintf(s.Err, "%s%v\n", prefix, err)
		return exitRefused
	}
	return finish(code, destination, s)
}

// finish reports a published run: a status other than complete leaves a one-line pointer to the evidence.
func finish(status string, destination string, s cli.Stdio) int {
	if status == "complete" {
		return cli.ExitOK
	}
	helpers.WarnEvidence(s.Err, schema, destination, "status="+status)
	return exitPartial
}

// analyze is the whole run. On success it returns the report status and the published destination; it
// returns the stage still to be removed ("" once published or never created) and the failure, if any.
func analyze(c config, s cli.Stdio, d deps) (status, stage, destination string, err error) {
	if err := adapter.RefusePrivilegedExecution(d.creds()); err != nil {
		return "", "", "", err
	}
	if min(c.timeout, c.maxDiagnostic, c.maxInput, c.maxFindings, c.maxProcs) < 1 || c.maxFiles < 7 {
		return "", "", "", errors.New("caps must be positive and max-files at least 7")
	}
	euid := uint64(d.creds().EUID)
	source, err := fsx.Identity(c.input, c.maxInput)
	if err != nil {
		return "", "", "", err
	}
	parent, name, err := resolveParent(c.output, s.Cwd)
	if err != nil {
		return "", "", "", err
	}
	mount, err := d.mountinfo()
	if err != nil {
		return "", "", "", err
	}
	if err := adapter.RequirePrivate(parent, mount); err != nil {
		return "", "", "", err
	}
	destination = filepath.Join(parent, name)
	if _, lerr := os.Lstat(destination); lerr == nil || source.Resolved == destination {
		return "", "", "", errors.New("output must be a new non-colliding path")
	}
	candidate := filepath.Join(parent, "."+name+".stage")
	if err := os.Mkdir(candidate, 0o700); err != nil {
		return "", "", "", osError(err, candidate)
	}
	stage = candidate
	status, err = collect(c, s, d, stage, destination, euid)
	if err != nil {
		return "", stage, "", err
	}
	if err := fsx.Publish(stage, destination); err != nil {
		return "", stage, "", publishError(err, destination)
	}
	return status, "", destination, nil
}

// publishError renders a failed no-replace publication like the script's OSError.
func publishError(err error, destination string) error {
	if errors.Is(err, fsx.ErrUnavailable) {
		return errors.New("atomic no-replace publication is unavailable")
	}
	var errno syscall.Errno
	if errors.As(err, &errno) {
		return fmt.Errorf("[Errno %d] atomic publication failed: '%s'", int(errno), destination)
	}
	return err
}

// resolveParent is the output's parent with every symlink followed (it must exist) and the output's own name.
func resolveParent(output, cwd string) (parent, name string, err error) {
	var parts []string
	for _, p := range strings.Split(output, "/") {
		if p != "" && p != "." {
			parts = append(parts, p)
		}
	}
	var dirParts []string
	if n := len(parts); n > 0 {
		dirParts, name = parts[:n-1], parts[n-1]
	}
	// No directory part means the working directory, which an empty path resolves to as "." does.
	dir := strings.Join(dirParts, "/")
	if strings.HasPrefix(output, "/") {
		dir = "/" + strings.TrimPrefix(dir, ".")
	}
	parent, err = resolveStrict(dir, cwd)
	return parent, name, err
}

// collect stages the input and the analyzer, runs the analyzer in the sandbox, and writes every evidence file
// under stage. It returns the report status.
func collect(c config, s cli.Stdio, d deps, stage, destination string, euid uint64) (string, error) {
	for _, sub := range []string{"input", "engine"} {
		if err := os.Mkdir(filepath.Join(stage, sub), 0o777); err != nil {
			return "", osError(err, filepath.Join(stage, sub))
		}
	}
	sourceRecord, stagedInput, err := fsx.StageFile(c.input, filepath.Join(stage, "input/firmware.bin"), "input/firmware.bin", 0o400, c.maxInput)
	if err != nil {
		return "", err
	}
	override := s.Env("RSDD_BINWALK_TEST_ONLY") != ""
	an, err := resolveBinwalk(s.Env, s.Cwd, euid)
	if err != nil {
		return "", err
	}
	trust := an.trust
	var stageGate *gate
	if an.gate != nil {
		stageGate = &gate{uids: an.gate.uids} // the staging refusal carries no hint
	}
	var stagedUID uint64
	copied, stagedBinwalk, err := stageTrusted(an.record.Path, filepath.Join(stage, "engine/binwalk"), "engine/binwalk", 0o500, stageGate, &stagedUID)
	if err != nil {
		return "", err
	}
	if an.gate != nil { // the label comes from the bytes that run
		trust = trustUser
		if stagedUID == 0 {
			trust = trustRoot
		}
	}
	if copied != an.record {
		return "", errors.New("analyzer changed before trusted staging")
	}
	bwrap, bwrapRecord, err := sandboxLauncher(s, d)
	if err != nil {
		return "", err
	}
	env := sandboxEnv(safePath)
	prefixCmd, err := sandbox(bwrap, env, d.hostRoot, uint64(d.creds().UID))
	if err != nil {
		return "", err
	}
	self, err := d.self()
	if err != nil {
		return "", err
	}
	if err := isolationProbe(prefixCmd, stage, env); err != nil {
		return "", err
	}
	now := s.Clock
	if now == nil {
		return "", errors.New("no clock available")
	}
	run := func(args []string, timeout time.Duration) (runRecord, []string, error) {
		return runBounded(runSpec{argv: append(append([]string{}, prefixCmd...), args...), dir: stage, env: environ(env), self: self,
			timeout: timeout, maxBytes: c.maxDiagnostic, maxProcs: int(min(c.maxProcs, 1<<30)), now: now})
	}
	version, err := probeVersion(run, stage, min(versionBound, c.timeout), override)
	if err != nil {
		return "", err
	}
	inner := append([]string{"engine/binwalk"}, safeArgs...)
	command := append(append([]string{}, prefixCmd...), inner...)
	rec, errs, err := run(inner, time.Duration(c.timeout)*time.Second)
	if err != nil {
		return "", err
	}
	listing, err := os.ReadFile(filepath.Join(stage, "engine/stdout.txt"))
	if err != nil {
		return "", osError(err, filepath.Join(stage, "engine/stdout.txt"))
	}
	signatures, entropy := parseFindings(string(listing))
	combined := append(append([]finding{}, signatures...), entropy...)
	emitted := combined[:min(int64(len(combined)), c.maxFindings)]
	truncated := len(combined) > len(emitted)
	var sigOut, entOut []finding
	for _, f := range emitted {
		if isEntropy(f) {
			entOut = append(entOut, f)
		} else {
			sigOut = append(sigOut, f)
		}
	}
	if err := writeJSON(filepath.Join(stage, "engine/signatures.json"), findingObjects(sigOut)); err != nil {
		return "", err
	}
	if err := writeJSON(filepath.Join(stage, "engine/entropy.json"), findingObjects(entOut)); err != nil {
		return "", err
	}
	limits := limitationsFor(trust, override)
	status := "complete"
	switch {
	case len(errs) > 0:
		status = "failed"
	case truncated:
		status = "partial"
	}
	profile := adapter.NamedProfiles()["PROFILE_BWRAP_STATIC_NETWORK_DENIED"].Map()
	toolName := "binwalk"
	if override {
		toolName = "binwalk-test-override"
	}
	spec := map[string]any{
		"schema_version": adapter.SchemaVersion,
		"input":          map[string]any{"path": "input/firmware.bin", "detected_type": "firmware or opaque binary"},
		"tool": map[string]any{"name": toolName, "version": version, "executable": bwrap,
			"artifacts": []any{map[string]any{"path": "engine/binwalk", "argv_index": len(prefixCmd)}}},
		"argv": strings2any(command), "environment": envMap(env), "run": rec.manifestRun(),
		"stdout_path": "engine/stdout.txt", "stderr_path": "engine/stderr.txt",
		"outputs":  []any{"engine/signatures.json", "engine/entropy.json"},
		"findings": []any{}, "limitations": strings2any(limits), "errors": strings2any(errs),
		"completeness": status, "isolation_profile": profile,
	}
	identity, err := writeManifest(stage, spec, s)
	if err != nil {
		return "", err
	}
	report := map[string]any{
		"schema": schema, "status": status,
		"input":     map[string]any{"source": recordObject(sourceRecord), "staged": recordObject(stagedInput)},
		"isolation": map[string]any{"launcher": recordObject(bwrapRecord), "profile": profile},
		"engine": map[string]any{
			"name": "binwalk", "version": version, "test_override": override, "trust": trust,
			"launcher": map[string]any{"source": recordObject(an.record), "staged": recordObject(stagedBinwalk)},
			"argv":     strings2any(inner), "run": rec.reportRun(), "manifest": "engine/analysis-manifest.v1.json", "manifest_identity": identity,
		},
		"signatures": findingObjects(sigOut), "entropy": findingObjects(entOut),
		"counts": map[string]any{"signatures_total": len(signatures), "entropy_total": len(entropy),
			"findings_total": len(combined), "findings_emitted": len(emitted)},
		"caps": map[string]any{"timeout_seconds": c.timeout, "max_diagnostic_bytes": c.maxDiagnostic, "max_input_bytes": c.maxInput,
			"max_findings": c.maxFindings, "max_processes": c.maxProcs, "max_files": c.maxFiles},
		"truncated": map[string]any{"findings": truncated}, "limitations": strings2any(limits), "errors": strings2any(errs),
	}
	if err := writeJSON(filepath.Join(stage, schema+".json"), report); err != nil {
		return "", err
	}
	n, err := countFiles(stage)
	if err != nil {
		return "", err
	}
	if n-1 > c.maxFiles {
		return "", errors.New("evidence file cap exceeded")
	}
	return status, nil
}

func isEntropy(f finding) bool { return strings.Contains(strings.ToLower(f.Description), "entropy") }

// countFiles is the number of regular files under dir (links are followed, as is_file does).
func countFiles(dir string) (int64, error) {
	var n int64
	err := filepath.WalkDir(dir, func(p string, e os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if fi, serr := os.Stat(p); serr == nil && fi.Mode().IsRegular() {
			n++
		}
		return nil
	})
	return n, err
}

// writeJSON writes v canonically through a sibling temporary, fsynced and renamed into place.
func writeJSON(path string, v any) error {
	b, err := canonical(v)
	if err != nil {
		return err
	}
	return fsx.WriteAtomic(path, b)
}

// sandboxLauncher finds bubblewrap on the fixed system PATH (RSDD_BWRAP may name it, but it must still be the
// one found there) and requires it to be owned by a trusted user and not group- or world-writable.
func sandboxLauncher(s cli.Stdio, d deps) (string, fsx.Record, error) {
	configured := s.Env("RSDD_BWRAP")
	if configured == "" {
		configured = defaultBwrap
	}
	path, rec, err := executable("bwrap", configured, d.safePath, s.Cwd, nil, true, nil)
	if err != nil {
		return "", fsx.Record{}, err
	}
	fi, err := os.Stat(path)
	if err != nil {
		return "", fsx.Record{}, osError(err, path)
	}
	if uid, ok := owner(fi); !ok || !d.bwrapUIDs[uid] || fi.Mode().Perm()&0o022 != 0 {
		return "", fsx.Record{}, refusal("Bubblewrap must be root-owned and non-writable")
	}
	return path, rec, nil
}

// isolationProbe refuses to go on unless a process started under the sandbox prefix holds no capability.
func isolationProbe(prefixCmd []string, stage string, env []envVar) error {
	res, err := proc.Run(proc.Spec{Argv: append(append([]string{}, prefixCmd...), "/bin/sh", "-c", probeScript), Dir: stage, Env: environ(env),
		Timeout: probeTimeout, MaxBytes: 1 << 16})
	var spawn *proc.SpawnError
	switch {
	case errors.As(err, &spawn):
		return osError(spawn.Err, spawn.Path)
	case err != nil:
		return err
	case res.Reason == proc.ReasonTimeout:
		return errors.New("network-denied zero-capability isolation probe timed out")
	case res.ReturnCode != 0:
		return errors.New("network-denied zero-capability isolation probe failed")
	}
	return nil
}

// probeVersion asks the staged analyzer for its version: --help first (Binwalk 2.x prints it in the banner),
// then --version (3.x has no banner). A test analyzer may announce any version; a real one must be major 2.
func probeVersion(run func([]string, time.Duration) (runRecord, []string, error), stage string, bound int64, override bool) (string, error) {
	for _, flag := range []string{"--help", "--version"} {
		_, errs, err := run([]string{"engine/binwalk", flag}, time.Duration(bound)*time.Second)
		if err != nil {
			return "", err
		}
		if len(errs) > 0 {
			return "", refusal("bounded Binwalk version probe failed: " + strings.Join(errs, ","))
		}
		text, err := os.ReadFile(filepath.Join(stage, "engine/stdout.txt"))
		if err != nil {
			return "", osError(err, filepath.Join(stage, "engine/stdout.txt"))
		}
		if v := binwalkVersion(strings.ToValidUTF8(string(text), "�")); v != "" {
			if !override {
				if err := checkBinwalkVersion(v); err != nil {
					return "", err
				}
			}
			return v, nil
		}
	}
	return "", refusal("Binwalk version is unavailable")
}

// writeManifest has the manifest tool create, validate and verify the analysis manifest of the stage, and
// returns its identity. The tool's own message is forwarded on failure.
func writeManifest(stage string, spec map[string]any, s cli.Stdio) (string, error) {
	specPath := filepath.Join(stage, "engine/manifest-spec.json")
	manifest := filepath.Join(stage, "engine/analysis-manifest.v1.json")
	if err := writeJSON(specPath, spec); err != nil {
		return "", err
	}
	tool := func(args ...string) error {
		var out, errw bytes.Buffer
		code := adapter.ManifestRun(args, cli.Stdio{In: bytes.NewReader(nil), Out: &out, Err: &errw, Env: s.Env, Environ: s.Environ, Clock: s.Clock, Cwd: s.Cwd})
		if code != 0 {
			_, _ = s.Err.Write(errw.Bytes())
			return fmt.Errorf("manifest tool %s failed with exit status %d", args[0], code)
		}
		return nil
	}
	if err := tool("create", "--root", stage, "--spec", specPath, "--output", manifest); err != nil {
		return "", err
	}
	if err := os.Remove(specPath); err != nil {
		return "", osError(err, specPath)
	}
	if err := tool("validate", manifest); err != nil {
		return "", err
	}
	if err := tool("verify", "--root", stage, manifest); err != nil {
		return "", err
	}
	b, err := os.ReadFile(manifest)
	if err != nil {
		return "", osError(err, manifest)
	}
	var doc struct {
		Identity string `json:"identity"`
	}
	if err := json.Unmarshal(b, &doc); err != nil {
		return "", err
	}
	return doc.Identity, nil
}

// refusal is an error whose text is kept exactly as the script printed it (some start with a capital letter).
type refusal string

func (r refusal) Error() string { return string(r) }

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
