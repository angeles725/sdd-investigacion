package native

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/adapter"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/adapter/helpers"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/fsx"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/jsonout"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/proc"
)

// deps are the process-wide facts the pipeline reads, injectable so a test needs no root-owned Bubblewrap, no
// real /tmp/rsdd and no particular mount table.
type deps struct {
	run       func(proc.Spec) (proc.Result, error)
	mountinfo func() (string, error)
	mountRoot string                  // the host directory Bubblewrap mounts a tmpfs over
	uid       int                     // the owner the mount root must have
	bwrapOK   func(os.FileInfo) error // the launcher's trust check
	beforeRun func(stage string)      // test hook: called right before the analyzer run, nil in production
}

func realDeps() deps {
	return deps{run: proc.Run, mountinfo: adapter.HostMountinfo, mountRoot: guestRoot, uid: os.Getuid(), bwrapOK: bwrapRootOwned}
}

// Run is the Main contract of `rsdd corroborate native`.
func Run(args []string, s cli.Stdio) int { return execute(args, s, realDeps()) }

// job is one invocation: its configuration, ambient dependencies and (once created) its staging directory.
type job struct {
	cfg   config
	s     cli.Stdio
	d     deps
	stage string
}

func execute(args []string, s cli.Stdio, d deps) int {
	cfg, code, ok := parseArgs(args, s)
	if !ok {
		return code
	}
	j := &job{cfg: cfg, s: s, d: d}
	status, err := j.publish()
	if err != nil {
		fmt.Fprintf(s.Err, "corroborate-native: %v\n", err)
		return cli.ExitUsage
	}
	return status
}

// publish runs the whole pipeline. It returns the exit status of a published evidence directory (0 complete,
// 1 partial or failed) or an error when nothing was published. The stage is removed on every path that does not
// publish it, but a staging directory somebody else created is never touched.
func (j *job) publish() (status int, err error) {
	c := j.cfg
	if min(c.timeout, c.maxBytes, c.maxFunctions) < 1 || c.maxFiles < minFiles {
		return 0, errors.New("caps must be positive and max-files at least 6")
	}
	id, err := j.identity(c.input)
	if err != nil {
		return 0, err
	}
	source := id.Resolved
	parent, name, err := j.outputPlace(c.output)
	if err != nil {
		return 0, err
	}
	mountinfo, err := j.d.mountinfo()
	if err != nil {
		return 0, err
	}
	if err := adapter.RequirePrivate(parent, mountinfo); err != nil {
		return 0, err
	}
	dest := filepath.Join(parent, name)
	if err := requireNew(dest, source); err != nil {
		return 0, err
	}
	stage := filepath.Join(parent, "."+name+".stage")
	if err := os.Mkdir(stage, 0o700); err != nil {
		return 0, osError(err, stage)
	}
	j.stage = stage
	published := false
	defer func() {
		if !published {
			_ = os.RemoveAll(stage)
		}
	}()
	for _, d := range []string{"input", "engine"} {
		if err := os.Mkdir(filepath.Join(stage, d), 0o777); err != nil {
			return 0, osError(err, filepath.Join(stage, d))
		}
	}
	ev, spec, err := j.analyze()
	if err != nil {
		return 0, err
	}
	if err := j.seal(ev, spec); err != nil {
		return 0, err
	}
	if n, err := countEvidence(stage); err != nil {
		return 0, err
	} else if n > c.maxFiles {
		return 0, errors.New("evidence file cap exceeded")
	}
	if err := fsx.Publish(stage, dest); err != nil {
		return 0, publishError(err, dest)
	}
	published = true
	if len(ev.errs) > 0 || ev.truncated {
		helpers.WarnEvidence(j.s.Err, schema, dest, strings.Join(ev.errs, ", "))
		return 1, nil
	}
	return 0, nil
}

// analyze stages the input and the analyzer, runs radare2 in the sandbox and gathers what it found.
func (j *job) analyze() (evidence, manifestSpec, error) {
	c, stage := j.cfg, j.stage
	ev := evidence{cfg: c}
	var spec manifestSpec
	var err error
	if ev.source, ev.staged, err = j.stageFile(j.abs(c.input), stage+"/input/target.bin", "input/target.bin", 0o400); err != nil {
		return ev, spec, err
	}
	r2, r2Record, err := j.executable("r2", "RSDD_R2", j.s.Env("PATH"))
	if err != nil {
		return ev, spec, err
	}
	ev.r2Source, ev.r2Staged, err = j.stageFile(r2, stage+"/engine/r2", "engine/r2", 0o500)
	if err != nil {
		return ev, spec, err
	}
	if ev.r2Source != r2Record {
		return ev, spec, errors.New("analyzer changed before trusted staging")
	}
	r2Dir := filepath.Dir(r2)
	env := sandboxEnv(r2Dir)
	bwrap, bwrapRecord, err := j.executable("bwrap", "RSDD_BWRAP", r2Dir+":/usr/bin:/bin")
	if err != nil {
		return ev, spec, err
	}
	ev.bwrap = bwrapRecord
	fi, err := os.Stat(bwrap)
	if err != nil {
		return ev, spec, osError(err, bwrap)
	}
	if err := j.d.bwrapOK(fi); err != nil {
		return ev, spec, err
	}
	if err := checkMountpoint(j.d.mountRoot, j.d.uid); err != nil {
		return ev, spec, err
	}
	prefix := sandboxPrefix(bwrap, env)
	if ev.version, err = j.sandboxChecks(prefix, env); err != nil {
		return ev, spec, err
	}
	ev.inner = append([]string{"engine/r2"}, safeR2...)
	command := append(append([]string{}, prefix...), ev.inner...)
	if j.d.beforeRun != nil {
		j.d.beforeRun(stage)
	}
	stdout, stderr, run, errs, err := j.bounded(command, env)
	if err != nil {
		return ev, spec, err
	}
	ev.run, ev.errs = run, errs
	if stdout, err = j.writeStreams(stdout, stderr); err != nil {
		return ev, spec, err
	}
	if len(ev.errs) == 0 {
		if ev.functions, err = parseFunctions(stdout); err != nil {
			ev.errs = append(ev.errs, err.Error())
			ev.functions = nil
		}
	}
	ev.total = len(ev.functions)
	if ev.total > c.maxFunctions {
		ev.functions = ev.functions[:c.maxFunctions]
	}
	if ev.functions == nil {
		ev.functions = []map[string]any{}
	}
	ev.truncated = ev.total > len(ev.functions)
	ev.profile = adapter.NamedProfiles()["PROFILE_BWRAP_STATIC_NETWORK_DENIED"].Map()
	spec = manifestSpec{version: ev.version, bwrap: bwrap, command: command, env: env, run: run, errs: ev.errs,
		completeness: outcome(ev.errs, ev.truncated), r2ArgvIndex: len(prefix), isolationName: ev.profile}
	return ev, spec, nil
}

// sandboxChecks proves the sandbox works (a no-op command succeeds) and asks the staged radare2 for its version.
func (j *job) sandboxChecks(prefix []string, env []envVar) (string, error) {
	res, err := j.probe(append(append([]string{}, prefix...), "/bin/true"), env)
	if err != nil {
		return "", err
	}
	if res.Reason != "" || res.ReturnCode != 0 {
		return "", errors.New("network-denied isolation probe failed")
	}
	res, err = j.probe(append(append([]string{}, prefix...), "engine/r2", "-v"), env)
	if err != nil {
		return "", err
	}
	if res.Reason != "" || res.ReturnCode != 0 {
		return "", fmt.Errorf("radare2 version probe failed: %s", exitText(res))
	}
	version := firstLine(strings.ToValidUTF8(string(res.Stdout), "�"))
	if version == "" {
		return "", errors.New("radare2 version probe printed no version")
	}
	return version, nil
}

func exitText(res proc.Result) string {
	switch {
	case res.Reason != "":
		return res.Reason
	case res.ReturnCode < 0:
		return fmt.Sprintf("signal %d", -res.ReturnCode)
	}
	return fmt.Sprintf("exit status %d", res.ReturnCode)
}

// writeStreams stores radare2's output under engine/ with the staging path scrubbed and returns the scrubbed
// stdout for parsing.
func (j *job) writeStreams(stdout, stderr []byte) ([]byte, error) {
	scrub := func(b []byte) []byte { return bytes.ReplaceAll(b, []byte(j.stage), []byte("<STAGING_ROOT>")) }
	stdout, stderr = scrub(stdout), scrub(stderr)
	for name, data := range map[string][]byte{"stdout.txt": stdout, "stderr.txt": stderr} {
		if err := os.WriteFile(filepath.Join(j.stage, "engine", name), data, 0o666); err != nil {
			return nil, osError(err, filepath.Join(j.stage, "engine", name))
		}
	}
	return stdout, nil
}

// seal writes functions.json, creates and validates the analysis manifest, then writes the report that binds
// the manifest's identity. The order matters: the report names the identity of a manifest that already exists.
func (j *job) seal(ev evidence, spec manifestSpec) error {
	stage := j.stage
	if err := writeCanonical(stage+"/engine/functions.json", ev.functions); err != nil {
		return err
	}
	specFile := stage + "/engine/manifest-spec.json"
	if err := writeCanonical(specFile, spec.value()); err != nil {
		return err
	}
	manifest := stage + "/" + manifestPath
	if err := j.manifest("create", "--root", stage, "--spec", specFile, "--output", manifest); err != nil {
		return err
	}
	if err := os.Remove(specFile); err != nil {
		return osError(err, specFile)
	}
	if err := j.manifest("validate", manifest); err != nil {
		return err
	}
	raw, err := os.ReadFile(manifest)
	if err != nil {
		return osError(err, manifest)
	}
	var doc struct {
		Identity any `json:"identity"`
	}
	if err := json.Unmarshal(raw, &doc); err != nil {
		return err
	}
	ev.identity = doc.Identity
	return writeCanonical(stage+"/"+schema+".json", ev.value())
}

// manifest runs one subcommand of the analysis-manifest CLI port in-process; its own diagnostics reach stderr.
func (j *job) manifest(args ...string) error {
	if rc := adapter.ManifestRun(args, j.s); rc != 0 {
		return fmt.Errorf("analysis-manifest %s failed (exit %d)", args[0], rc)
	}
	return nil
}

// writeCanonical writes v as canonical JSON through a sibling temp file and an atomic rename.
func writeCanonical(path string, v any) error {
	b, err := jsonout.Canonical(v)
	if err != nil {
		return err
	}
	if err := fsx.WriteAtomic(path, b); err != nil {
		return osError(err, path)
	}
	return nil
}

// countEvidence counts the regular files of the stage other than the staged target (symlinks are followed).
func countEvidence(stage string) (int, error) {
	n := 0
	target := filepath.Join(stage, "input/target.bin")
	err := filepath.WalkDir(stage, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() || p == target {
			return nil
		}
		if fi, serr := os.Stat(p); serr == nil && fi.Mode().IsRegular() {
			n++
		}
		return nil
	})
	return n, err
}

// publishError is the text of a failed no-replace publication.
func publishError(err error, dest string) error {
	if errors.Is(err, fsx.ErrUnavailable) {
		return errors.New(fsx.ErrUnavailable.Error())
	}
	if e, ok := errno(err); ok {
		return fmt.Errorf("[Errno %d] atomic publication failed: %s", int(e), reprPath(dest))
	}
	return err
}
