// Package java is `rsdd corroborate java`: the port of toolbelt/corroborate_java.py, bounded multi-engine Java
// corroboration (java-corroboration.v1, toolbelt/java-corroboration.v1.md).
//
// The input JAR is copied into a private stage next to the output root, inventoried (size, entry count, unsafe or
// duplicate entries, a full CRC read), and handed, read-only, to five non-executing engines inside network-denied
// Bubblewrap sandboxes: the Vineflower, CFR and Procyon decompiler JARs (each copied through one descriptor and
// kept only if it matches its trusted SHA-256 pin) and the JDK's javap and jdeps. Every engine's output is
// capped, inventoried and given an analysis manifest; the report compares the decompilers and carries the
// class-file facts read by internal/corroborate/classfile. The stage is published atomically (a new root with
// RENAME_NOREPLACE, an existing one with RENAME_EXCHANGE under --overwrite), and a failed run leaves nothing
// behind. The analyzed classes are never executed.
//
// Differences from the script, each pinned by a test:
//   - the manifest builder, verifier and canonical writer run in-process (internal/core/adapter) instead of
//     being loaded from the module --manifest-module names; the flag is still required and its path is still
//     protected from the output root;
//   - the argument parser is the stdlib flag package: abbreviated long options are not accepted, and the usage
//     text names corroborate-java;
//   - the classfile-facts subcommand is `rsdd corroborate classfile`;
//   - messages that quote a Python exception (a damaged central directory, an OS error) carry the same facts in
//     Go's words;
//   - a missing JAVA_HOME is a typed refusal (exit 2), where the script died with a KeyError traceback.
package java

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/adapter/helpers"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/proc"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/corroborate/classfile"
)

const (
	schema      = "java-corroboration.v1"
	sandboxRoot = "/tmp/rsdd/analysis"
)

// engineNames are the five adapters in the order they run.
var engineNames = []string{"vineflower", "cfr", "procyon", "javap", "jdeps"}

// env is everything Run reads from the machine, injected so tests drive every outcome.
type env struct {
	s         cli.Stdio
	run       func(proc.Spec) (proc.Result, error) // the isolation probe
	helper    func() (string, error)               // the rsdd binary that lowers the adapter's file size limit; nil: no limit
	mountRoot string                               // the private /tmp/rsdd mount point
	uid       int
	owner     func(os.FileInfo) (int, bool)
	runEnv    map[string]string // the environment recorded in every manifest
}

// Run is `rsdd corroborate java`.
func Run(args []string, s cli.Stdio) int { return newEnv(s).main(args) }

// newEnv is the production wiring; tests replace its seams.
func newEnv(s cli.Stdio) *env {
	return &env{s: s, run: proc.Run, helper: os.Executable, mountRoot: "/tmp/rsdd", uid: os.Getuid(), owner: ownerUID}
}

// lookup reports an environment variable and whether it is set at all (an empty value is set).
func (e *env) lookup(key string) (string, bool) {
	if e.s.Environ != nil {
		for _, kv := range e.s.Environ() {
			if v, ok := strings.CutPrefix(kv, key+"="); ok {
				return v, true
			}
		}
		return "", false
	}
	v := e.s.Env(key)
	return v, v != ""
}

func (e *env) main(args []string) int {
	o, rc := e.parse(args)
	if rc >= 0 {
		return rc
	}
	var st state
	rc, err := e.pipeline(o, &st)
	if st.stage != "" && !st.published {
		_ = removePrivateTree(st.stage)
	}
	if st.lock != nil {
		_ = st.lock.Close()
	}
	if err != nil {
		_, _ = fmt.Fprintf(e.s.Err, "corroborate-java: %v\n", err)
		var typed *failure
		if !errors.As(err, &typed) {
			return cli.ExitOperational // what the script's uncaught exceptions (a traceback) came to
		}
		return cli.ExitUsage
	}
	return rc
}

// state is what the cleanup in main needs after the pipeline returns.
type state struct {
	stage     string
	published bool
	lock      *os.File
}

// canonicalLauncher is canonical_launcher: a path that resolves to an executable regular file.
func canonicalLauncher(p string) (string, error) {
	resolved, err := filepath.EvalSymlinks(p)
	if err != nil {
		return "", fail("launcher cannot be resolved: %s", p)
	}
	if fi, err := os.Stat(resolved); err != nil || !fi.Mode().IsRegular() || !canExec(resolved) {
		return "", fail("launcher is not an executable file: %s", resolved)
	}
	return resolved, nil
}

// isoNow is datetime.now(timezone.utc).isoformat() with the Z spelling.
func (e *env) isoNow() string { return isoZ(e.s.Clock()) }

func (e *env) pipeline(o options, st *state) (int, error) {
	cwd := e.s.Cwd
	inputPath, size, digest, err := fileIdentity(absolute(o.input, cwd), "")
	if err != nil {
		return 0, err
	}
	destination, err := canonicalDestination(o.output, e.s.Env("HOME"), cwd)
	if err != nil {
		return 0, err
	}
	javaHomeRaw := e.s.Env("JAVA_HOME")
	if javaHomeRaw == "" {
		return 0, fail("JAVA_HOME is not set")
	}
	javaHome := resolveLoose(absolute(javaHomeRaw, cwd))
	wrapper, err := resolveStrict(absolute(o.decompileWrapper, cwd))
	if err != nil {
		return 0, err
	}
	java, err := canonicalLauncher(javaHome + "/bin/java")
	if err != nil {
		return 0, err
	}
	javap, err := canonicalLauncher(javaHome + "/bin/javap")
	if err != nil {
		return 0, err
	}
	jdeps, err := canonicalLauncher(javaHome + "/bin/jdeps")
	if err != nil {
		return 0, err
	}
	bwrapValue, set := e.lookup("RSDD_BWRAP")
	if !set {
		bwrapValue = "/usr/bin/bwrap"
	}
	if bwrapValue == "" {
		return 0, fail("bubblewrap is required for analyzer isolation")
	}
	bwrap, err := canonicalLauncher(absolute(bwrapValue, cwd))
	if err != nil {
		return 0, err
	}
	bfi, err := os.Stat(bwrap)
	if err != nil {
		return 0, osFailure(err, bwrap)
	}
	if uid, ok := e.owner(bfi); !ok || uid != 0 || bfi.Mode().Perm()&0o022 != 0 {
		return 0, fail("bubblewrap launcher must be root-owned and non-writable")
	}
	toolSources := map[string]string{
		"vineflower": e.s.Env("RSDD_CORROBORATE_VINEFLOWER"),
		"cfr":        e.s.Env("RSDD_CORROBORATE_CFR"),
		"procyon":    e.s.Env("RSDD_CORROBORATE_PROCYON"),
	}
	protected := []string{inputPath, wrapper, resolveLoose(absolute(o.manifestModule, cwd)), bwrap, java, javap, jdeps}
	if err := protectDestination(destination, protected); err != nil {
		return 0, err
	}
	if st.lock, err = lockParent(filepath.Dir(destination)); err != nil {
		return 0, err
	}
	if st.stage, err = prepareStage(destination); err != nil {
		return 0, err
	}
	stage := st.stage
	if pathExists(destination) && !o.overwrite {
		return 0, fail("output root exists; pass --overwrite")
	}

	if err := os.Mkdir(stage+"/input", 0o777); err != nil {
		return 0, osFailure(err, stage+"/input")
	}
	if err := copyFile(inputPath, stage+"/input/target.jar"); err != nil {
		return 0, err
	}
	_, copiedSize, copiedDigest, err := fileIdentity(stage+"/input/target.jar", stage)
	if err != nil {
		return 0, err
	}
	if copiedSize != size || copiedDigest != digest {
		return 0, fail("input changed while staging")
	}
	inv, err := jarInventory(stage+"/input/target.jar", o.maxFiles, o.maxBytes, o.maxClasses)
	if err != nil {
		return 0, err
	}
	if err := os.Mkdir(stage+"/trusted-tools", 0o700); err != nil {
		return 0, osFailure(err, stage+"/trusted-tools")
	}
	toolJars := map[string]map[string]any{}
	for _, name := range engineNames[:3] {
		if toolJars[name], err = e.stageTrustedArtifact(name, toolSources[name], stage); err != nil {
			return 0, err
		}
	}
	if err := os.Chmod(stage+"/trusted-tools", 0o500); err != nil {
		return 0, osFailure(err, stage+"/trusted-tools")
	}
	extra := protected
	for _, name := range engineNames[:3] {
		if rec := toolJars[name]; rec != nil {
			extra = append(extra, rec["source"].(map[string]any)["path"].(string))
		}
	}
	if err := protectDestination(destination, extra); err != nil {
		return 0, err
	}

	e.runEnv = map[string]string{
		"HOME": "/tmp/rsdd/home", "XDG_CACHE_HOME": "/tmp/rsdd/cache", "XDG_CONFIG_HOME": "/tmp/rsdd/config",
		"XDG_DATA_HOME": "/tmp/rsdd/data", "TMPDIR": "/tmp/rsdd/tmp", "JAVA_HOME": javaHome, "LANG": "C.UTF-8",
		"LC_ALL": "C.UTF-8", "PATH": javaHome + "/bin:/usr/bin:/bin", "TZ": "UTC", "RSDD_DECOMPILE_MAX_HEAP": o.maxHeap,
	}
	environment := make([]string, 0, len(e.runEnv))
	for _, k := range []string{"HOME", "XDG_CACHE_HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "TMPDIR", "JAVA_HOME", "LANG", "LC_ALL", "PATH", "TZ", "RSDD_DECOMPILE_MAX_HEAP"} {
		environment = append(environment, k+"="+e.runEnv[k])
	}
	if err := e.requireIsolation(bwrap, stage, environment); err != nil {
		return 0, err
	}

	engines := map[string]map[string]any{}
	inventories := map[string][]outputRecord{}
	statuses := map[string]string{}
	for _, name := range engineNames {
		rec, inventory, err := e.runEngine(name, engineInput{
			o: o, stage: stage, bwrap: bwrap, java: java, javap: javap, jdeps: jdeps,
			environment: environment, jar: inv, trusted: toolJars[name], isJarTool: name != "javap" && name != "jdeps",
		})
		if err != nil {
			return 0, err
		}
		engines[name], inventories[name], statuses[name] = rec, inventory, rec["status"].(string)
	}

	jar, err := openStaged(stage + "/input/target.jar")
	if err != nil {
		return 0, err
	}
	facts, summary, err := e.classFacts(jar, inv.classEntries)
	jar.Close()
	if err != nil {
		return 0, err
	}
	expected := inv.expectedClasses
	coverageMap := map[string]any{}
	for _, name := range engineNames[:3] {
		coverageMap[name] = coverage(expected, inventories[name])
	}
	var failures, errs []string
	for _, name := range engineNames {
		if statuses[name] != "success" {
			failures = append(failures, name)
			errs = append(errs, name+": "+statuses[name])
		}
	}
	status := "complete"
	if len(failures) > 0 {
		status = "partial"
	}
	adapterCaps := false
	for _, rec := range engines {
		t := rec["truncated"].(map[string]any)
		adapterCaps = adapterCaps || t["diagnostics"].(bool) || t["outputs"].(bool)
	}
	sigs, err := signatures(stage + "/engines/javap/stdout.txt")
	if err != nil {
		return 0, err
	}
	deps, err := dependencyLines(stage + "/engines/jdeps/stdout.txt")
	if err != nil {
		return 0, err
	}
	agreements := comparisons(inventories)
	if errs == nil {
		errs = []string{}
	}
	report := map[string]any{
		"schema": schema, "status": status,
		"input": map[string]any{"path": inputPath, "size": size, "sha256": digest,
			"entry_count": inv.entryCount, "expanded_bytes": inv.expandedBytes},
		"class_entries": inv.classEntries, "expected_classes": expected,
		"expected_class_count": inv.expectedTotal, "multi_release": inv.multiRelease,
		"class_facts": facts, "class_facts_summary": summary,
		"engines": engines, "javap_signatures": sigs, "jdeps": deps, "class_coverage": coverageMap,
		"agreements": agreements, "disagreements": disagreements(agreements),
		"truncated": map[string]any{"classes": inv.classesTruncated, "adapter_caps": adapterCaps},
		"errors":    errs,
		"limitations": []string{
			"Decompiler outputs are compared only by observable path and byte-hash inventories; source equivalence is not claimed.",
			"Multi-release class entries are inventoried, but javap coverage uses base classes only.",
			fmt.Sprintf("class_facts.resugar_risk flags every class with major >= %d: decompiled syntax needs bytecode (javap -c -p) evidence; it does not mean the output is wrong.", classfile.ResugarMinMajor),
			"JDK runtime behavior and target class initialization are not executed.",
			"WSL2 is not a security boundary; use a disposable VM for hostile artifacts.",
		},
	}
	payload, err := canonicalBytes(report)
	if err != nil {
		return 0, err
	}
	if err := atomicWriteNew(stage+"/"+schema+".json", payload); err != nil {
		return 0, err
	}
	if err := publish(stage, destination, o.overwrite); err != nil {
		return 0, err
	}
	st.published = true
	if len(failures) > 0 {
		helpers.WarnEvidence(e.s.Err, schema, destination, strings.Join(failures, ", "))
		return 1, nil
	}
	return 0, nil
}

// copyFile is shutil.copyfile: the bytes of src in a new dst (a default-mode file, never replacing one).
func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return osFailure(err, src)
	}
	defer in.Close()
	out, err := os.OpenFile(dst, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o666)
	if err != nil {
		return osFailure(err, dst)
	}
	if _, err := io.Copy(out, in); err != nil {
		_ = out.Close()
		return osFailure(err, dst)
	}
	if err := out.Close(); err != nil {
		return osFailure(err, dst)
	}
	return nil
}
