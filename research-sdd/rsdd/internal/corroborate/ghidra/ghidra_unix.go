//go:build unix

//lint:file-ignore ST1005 the messages are the legacy driver's, kept byte for byte (parity)

package ghidra

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/adapter"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/adapter/helpers"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/fsx"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/jsonout"
)

// deps are the process-wide facts the pipeline reads, injectable so a test needs no particular mount table.
type deps struct {
	mountinfo  func() (string, error)
	uid        int
	afterTrust func(stage string) // test hook: the stage exists, nothing is staged yet; nil in production
	beforeRun  func(stage string) // test hook: staged, locked and probed, right before the Ghidra run; nil in production
}

func realDeps() deps { return deps{mountinfo: adapter.HostMountinfo, uid: os.Getuid()} }

// Run is the Main contract of `rsdd corroborate ghidra`.
func Run(args []string, s cli.Stdio) int { return execute(args, s, realDeps()) }

// job is one invocation: its configuration, ambient dependencies and (once created) its staging directory.
type job struct {
	cfg   config
	s     cli.Stdio
	d     deps
	stage string
	locks []lockedFile
}

func execute(args []string, s cli.Stdio, d deps) int {
	cfg, code, ok := parseArgs(args, s)
	if !ok {
		return code
	}
	j := &job{cfg: cfg, s: s, d: d}
	status, err := j.run()
	if err != nil {
		fmt.Fprintf(s.Err, "corroborate-ghidra: %v\n", err)
		return cli.ExitUsage
	}
	return status
}

var versionRe = regexp.MustCompile(`(?m)^application\.version=([^\r\n]+)$`)

// run is the whole pipeline. It returns the exit status of a published evidence directory (0 complete or partial,
// 1 failed) or an error when nothing was published. The stage is removed on every path that does not publish it, but
// a staging directory somebody else created is never touched.
func (j *job) run() (int, error) {
	c := j.cfg
	if !c.capsValid() {
		return 0, errors.New("caps must be positive and max-files at least 12")
	}
	tl, err := j.resolveTools()
	if err != nil {
		return 0, err
	}
	src, err := identityAs(j.abs(c.input), c.input)
	if err != nil {
		return 0, err
	}
	dest, err := j.destination(src.Resolved)
	if err != nil {
		return 0, err
	}
	javaHome := filepath.Dir(filepath.Dir(tl.java))
	_, analyzeRec, err := trusted(tl.ghidraHome+"/support/analyzeHeadless", tl.ghidraHome+"/support/analyzeHeadless")
	if err != nil {
		return 0, err
	}
	_, javaRec, err := trusted(tl.java, javaHome+"/bin/java")
	if err != nil {
		return 0, err
	}
	bwrapFile, bwrapPath, bwrapRec, err := trustedBwrap(tl.bwrap, c.testOnlyBwrap)
	if err != nil {
		return 0, err
	}
	defer bwrapFile.Close()
	if _, err := identity(tl.exporter); err != nil {
		return 0, err
	}
	stage := dest.stage
	if err := os.Mkdir(stage, 0o700); err != nil {
		return 0, osError(err, stage)
	}
	j.stage = stage
	published := false
	defer func() {
		for _, l := range j.locks {
			_ = l.f.Close()
		}
		if !published {
			_ = os.RemoveAll(stage)
		}
	}()
	if err := j.privateStage(); err != nil {
		return 0, err
	}
	if j.d.afterTrust != nil {
		j.d.afterTrust(stage)
	}

	ev := evidence{cfg: c, isolated: !c.testOnlyBwrap}
	if ev.source, ev.staged, err = stageFile(j.abs(c.input), stage+"/input/target.bin", "input/target.bin", 0o400); err != nil {
		return 0, err
	}
	trust := map[string]fsx.Record{"tool/ghidra/support/analyzeHeadless": analyzeRec, logicalJava: javaRec}
	type pair struct {
		src, logical string
		mode         os.FileMode
	}
	pairs := []pair{{tl.exporter, logicalExporter, 0o400}, {bwrapPath, logicalBwrap, 0o500}}
	for _, item := range chain {
		mode := os.FileMode(0o400)
		if strings.HasSuffix(item, "analyzeHeadless") || strings.HasSuffix(item, "launch.sh") {
			mode = 0o500
		}
		pairs = append(pairs, pair{tl.ghidraHome + "/" + item, "tool/ghidra/" + item, mode})
	}
	pairs = append(pairs, pair{tl.java, logicalJava, 0o500})
	for _, p := range pairs {
		var original, staged fsx.Record
		if p.logical == logicalBwrap {
			original, staged, err = stageOpen(bwrapFile, stage+"/"+p.logical, p.logical, p.mode, bwrapPath)
			if err == nil && (original.Size != bwrapRec.Size || original.SHA256 != bwrapRec.SHA256) {
				err = errors.New("staged Bubblewrap differs from authenticated identity")
			}
			ev.bwrap = staged
		} else {
			original, staged, err = stageFile(p.src, stage+"/"+p.logical, p.logical, p.mode)
			if want, ok := trust[p.logical]; err == nil && ok && original != want {
				err = errors.New("trusted launcher changed before staging")
			}
		}
		if err != nil {
			return 0, err
		}
		ev.provenance = append(ev.provenance, map[string]any{"source": record(original), "staged": record(staged)})
		if err := j.lock(stage+"/"+p.logical, staged); err != nil {
			return 0, err
		}
	}
	if err := j.lock(stage+"/input/target.bin", ev.staged); err != nil {
		return 0, err
	}

	props, err := os.ReadFile(stage + "/tool/ghidra/Ghidra/application.properties")
	if err != nil {
		return 0, osError(err, stage+"/tool/ghidra/Ghidra/application.properties")
	}
	m := versionRe.FindSubmatch(props)
	if m == nil {
		return 0, errors.New("staged application.properties has no version")
	}
	ev.version = string(m[1])

	sb := buildSandbox(c, tl.ghidraHome, javaHome)
	ev.inner = sb.inner
	spec := runSpec{exe: fdPath(idxBwrap), argv: sb.command, env: envList(sb.env), dir: stage, extra: j.files()}
	probeSpec := spec
	probeSpec.argv = sb.probeCommand()
	if rc, err := probeSpec.probe(); err != nil {
		return 0, err
	} else if rc != 0 {
		return 0, errors.New("Bubblewrap isolation probe failed")
	}
	if j.d.beforeRun != nil {
		j.d.beforeRun(stage)
	}
	run, errs, err := j.bounded(spec)
	if err != nil {
		return 0, err
	}
	ev.run = run
	status, verrs := validateCurated(stage+"/output/curated.json", c.caps(), int64(c.maxOutput))
	ev.errs = append(errs, verrs...)
	if err := j.verifyLocks(); err != nil {
		return 0, err
	}
	ev.completeness = status
	if len(ev.errs) > 0 {
		ev.completeness = "failed"
	}
	outputs := []string{"logs/application.log", "logs/script.log"}
	if fi, err := os.Stat(stage + "/output/curated.json"); err == nil && fi.Mode().IsRegular() {
		outputs = append(outputs, "output/curated.json")
	}
	if err := writeCanonical(stage+"/report.json", ev.report()); err != nil {
		return 0, err
	}
	outputs = append(outputs, "report.json")

	name := "bubblewrap-ghidra-static"
	if !ev.isolated {
		name = "test-only-untrusted-bwrap"
	}
	profile, err := adapter.MakeProfile(name, true, !ev.isolated, false)
	if err != nil {
		return 0, err
	}
	if err := writeCanonical(stage+"/manifest-spec.json", manifestSpec(ev, sb, outputs, profile.Map())); err != nil {
		return 0, err
	}
	manifest := stage + "/" + manifestFile
	if err := j.manifest("create", "--root", stage, "--spec", stage+"/manifest-spec.json", "--output", manifest); err != nil {
		return 0, err
	}
	if err := os.Remove(stage + "/manifest-spec.json"); err != nil {
		return 0, osError(err, stage+"/manifest-spec.json")
	}
	if err := j.manifest("validate", manifest); err != nil {
		return 0, err
	}
	if err := j.verifyLocks(); err != nil {
		return 0, err
	}
	if n, err := countFiles(stage); err != nil {
		return 0, err
	} else if n > c.maxFiles {
		return 0, errors.New("evidence file cap exceeded")
	}
	if err := fsx.Publish(stage, dest.path); err != nil {
		return 0, publishError(err, dest.path)
	}
	published = true
	if ev.completeness != "complete" && ev.completeness != "partial" {
		helpers.WarnEvidence(j.s.Err, schema, dest.path, "completeness="+ev.completeness)
		return 1, nil
	}
	return 0, nil
}

// outputPlace is where the evidence goes: the canonical parent, the final path and its staging sibling.
type outputPlace struct{ path, stage string }

// destination validates --output: its parent must already be canonical (no symlink, absolute, normalised) on a
// Linux-private filesystem, the name must be a real entry, and nothing may exist there yet.
func (j *job) destination(source string) (outputPlace, error) {
	parentTyped, name := splitOutput(j.cfg.output)
	parentAbs := j.abs(parentTyped)
	real, err := filepath.EvalSymlinks(parentAbs)
	if err != nil {
		return outputPlace{}, osError(err, parentAbs)
	}
	if parentTyped != real {
		return outputPlace{}, errors.New("output parent must be canonical")
	}
	if name == "" || name == "." || name == ".." {
		return outputPlace{}, errors.New("output name is invalid")
	}
	mountinfo, err := j.d.mountinfo()
	if err != nil {
		return outputPlace{}, err
	}
	if err := adapter.RequirePrivate(real, mountinfo); err != nil {
		return outputPlace{}, err
	}
	dest := real + "/" + name
	if _, err := os.Lstat(dest); err == nil {
		return outputPlace{}, errors.New("output must be new and non-colliding")
	} else if !errors.Is(err, fs.ErrNotExist) && !errors.Is(err, syscall.ENOTDIR) {
		return outputPlace{}, osError(err, dest)
	}
	if source == dest {
		return outputPlace{}, errors.New("output must be new and non-colliding")
	}
	return outputPlace{path: dest, stage: real + "/." + name + ".stage"}, nil
}

// splitOutput is Path(output).parent and .name: duplicate and "." components are dropped, ".." is kept.
func splitOutput(output string) (parent, name string) {
	var parts []string
	for _, p := range strings.Split(output, "/") {
		if p != "" && p != "." {
			parts = append(parts, p)
		}
	}
	abs := strings.HasPrefix(output, "/")
	if len(parts) == 0 {
		if abs {
			return "/", ""
		}
		return ".", ""
	}
	name = parts[len(parts)-1]
	switch dir := strings.Join(parts[:len(parts)-1], "/"); {
	case abs:
		return "/" + dir, name
	case dir == "":
		return ".", name
	default:
		return dir, name
	}
}

// privateStage creates the stage layout and refuses a stage that is not a private 0700 directory of this user.
func (j *job) privateStage() error {
	fi, err := os.Lstat(j.stage)
	if err != nil {
		return osError(err, j.stage)
	}
	owner, _ := ownerUID(fi)
	if !fi.IsDir() || owner != j.d.uid || fi.Mode().Perm()&0o077 != 0 {
		return errors.New("staging directory is not private 0700")
	}
	for _, d := range []string{"input", "script", "tool", "project", "output", "logs", "state/home", "state/cache",
		"state/config", "state/data", "state/tmp"} {
		if err := os.MkdirAll(j.stage+"/"+d, 0o777); err != nil {
			return osError(err, j.stage+"/"+d)
		}
	}
	for _, log := range []string{"application.log", "script.log"} {
		f, err := os.OpenFile(j.stage+"/logs/"+log, os.O_WRONLY|os.O_CREATE, 0o600)
		if err != nil {
			return osError(err, j.stage+"/logs/"+log)
		}
		_ = f.Close()
	}
	return nil
}

// lock opens a staged file and keeps it: the descriptor is what the sandbox binds, and what verifyLocks re-checks.
func (j *job) lock(path string, rec fsx.Record) error {
	f, err := lockStaged(path, rec)
	if err != nil {
		return err
	}
	j.locks = append(j.locks, lockedFile{f: f, path: path, rec: rec})
	return nil
}

func (j *job) files() []*os.File {
	out := make([]*os.File, len(j.locks))
	for i, l := range j.locks {
		out[i] = l.f
	}
	return out
}

func (j *job) verifyLocks() error {
	for _, l := range j.locks {
		if err := l.verify(); err != nil {
			return err
		}
	}
	return nil
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

// countFiles counts every regular file under the stage (symlinks followed): the evidence file cap includes the
// staged tools and the target.
func countFiles(stage string) (int, error) {
	n := 0
	err := filepath.WalkDir(stage, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
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
		return errors.New("RENAME_NOREPLACE is unavailable")
	}
	if e, ok := errno(err); ok {
		return fmt.Errorf("[Errno %d] atomic no-replace publication failed: %s", int(e), reprPath(dest))
	}
	return err
}
