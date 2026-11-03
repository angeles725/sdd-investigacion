package java

import (
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/proc"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/corroborate/classfile"
)

// outcome is what run_adapter reports about one engine run.
type outcome struct {
	status               string
	returncode           int
	diagnosticsTruncated bool
	startedAt, endedAt   string
	durationMS           int64
}

// isoZ is datetime.isoformat() with "+00:00" replaced by "Z" (no fraction when the microseconds are zero).
func isoZ(t time.Time) string {
	t = t.UTC()
	if t.Nanosecond()/1000 == 0 {
		return t.Format("2006-01-02T15:04:05") + "Z"
	}
	return t.Format("2006-01-02T15:04:05.000000") + "Z"
}

// isolationPrefix is isolation_prefix: the Bubblewrap argv that ends in "--". The stage is mounted read-only as the
// sandbox root, writable only below writable; trusted is a (host path, sandbox path) read-only bind of a decompiler
// JAR.
func isolationPrefix(bwrap, writable string, trusted *[2]string) []string {
	cmd := []string{bwrap, "--die-with-parent", "--new-session", "--unshare-net",
		"--ro-bind", "/", "/", "--proc", "/proc", "--dev", "/dev", "--tmpfs", "/tmp/rsdd",
		"--dir", "/tmp/rsdd/home", "--dir", "/tmp/rsdd/tmp", "--dir", "/tmp/rsdd/cache",
		"--dir", "/tmp/rsdd/config", "--dir", "/tmp/rsdd/data", "--dir", sandboxRoot,
		"--ro-bind", ".", sandboxRoot}
	if trusted != nil {
		cmd = append(cmd, "--dir", "/tmp/rsdd/tools", "--ro-bind", trusted[0], trusted[1])
	}
	if writable != "" {
		cmd = append(cmd, "--bind", writable, sandboxRoot+"/"+writable)
	}
	return append(cmd, "--setenv", "HOME", "/tmp/rsdd/home", "--setenv", "XDG_CACHE_HOME", "/tmp/rsdd/cache",
		"--setenv", "XDG_CONFIG_HOME", "/tmp/rsdd/config", "--setenv", "XDG_DATA_HOME", "/tmp/rsdd/data",
		"--setenv", "TMPDIR", "/tmp/rsdd/tmp", "--chdir", sandboxRoot, "--")
}

// whichIn is shutil.which(name, path=pathValue): the first directory entry holding an executable regular file.
func whichIn(name, pathValue string) (string, bool) {
	for _, dir := range strings.Split(pathValue, ":") {
		if dir == "" {
			continue
		}
		p := filepath.Join(dir, name)
		if fi, err := os.Stat(p); err == nil && !fi.IsDir() && canExec(p) {
			return p, true
		}
	}
	return "", false
}

// requireIsolation is require_isolation: the configured launcher must be the one the sandbox PATH finds, the
// private mount point must be safe, and a network-denied sandbox must start and run /bin/true.
func (e *env) requireIsolation(bwrap, stage string, environment []string) error {
	pathValue := ""
	for _, kv := range environment {
		if v, ok := strings.CutPrefix(kv, "PATH="); ok {
			pathValue = v
		}
	}
	system, ok := whichIn("bwrap", pathValue)
	if !ok {
		return fail("configured isolation launcher does not match system Bubblewrap")
	}
	resolved, err := canonicalLauncher(system)
	if err != nil {
		return err
	}
	a, aerr := os.Stat(bwrap)
	b, berr := os.Stat(resolved)
	if aerr != nil || berr != nil || !os.SameFile(a, b) {
		return fail("configured isolation launcher does not match system Bubblewrap")
	}
	const cannot = "network-denied isolation cannot be established"
	if err := os.Mkdir(e.mountRoot, 0o700); err != nil && !os.IsExist(err) {
		return fail(cannot)
	}
	fi, err := os.Lstat(e.mountRoot)
	if err != nil {
		return fail(cannot)
	}
	if st, serr := os.Stat(e.mountRoot); serr != nil || !st.IsDir() {
		return fail(cannot) // exist_ok only forgives a directory
	}
	uid, known := e.owner(fi)
	if fi.Mode()&os.ModeSymlink != 0 || !known || uid != e.uid || fi.Mode().Perm()&0o077 != 0 {
		return fail("unsafe bubblewrap temporary mountpoint")
	}
	res, err := e.run(proc.Spec{
		Argv: append(isolationPrefix(bwrap, "", nil), "/bin/true"), Dir: stage, Env: environment,
		Timeout: 5 * time.Second, MaxBytes: 1 << 16,
	})
	if err != nil || res.ReturnCode != 0 || res.Reason != "" {
		return fail(cannot)
	}
	return nil
}

// engineInput is what runEngine needs besides the engine's name.
type engineInput struct {
	o                         options
	stage                     string
	bwrap, java, javap, jdeps string
	environment               []string
	jar                       *inventory
	trusted                   map[string]any // the staged decompiler JAR's record, nil when unavailable
	isJarTool                 bool
}

// firstIndex is command.index(value): the first position holding value.
func firstIndex(command []string, value string) int {
	for i, c := range command {
		if c == value {
			return i
		}
	}
	return -1
}

// runEngine runs one adapter and returns its report record and output inventory.
func (e *env) runEngine(name string, in engineInput) (map[string]any, []outputRecord, error) {
	o, stage := in.o, in.stage
	root := stage + "/engines/" + name
	output := root + "/output"
	if err := os.MkdirAll(output, 0o777); err != nil {
		return nil, nil, osFailure(err, output)
	}
	writable := "engines/" + name + "/output"
	var inner []string
	var artifact string
	var bind *[2]string
	switch {
	case in.isJarTool && in.trusted != nil:
		artifact = in.trusted["staged"].(map[string]any)["path"].(string)
		sandboxJar := "/tmp/rsdd/tools/" + name + ".jar"
		bind = &[2]string{artifact, sandboxJar}
		inner = []string{in.java, "-Xmx" + o.maxHeap, "-jar", sandboxJar}
		switch name {
		case "vineflower":
			inner = append(inner, "--thread-count=1", "input/target.jar", writable)
		case "cfr":
			inner = append(inner, "input/target.jar", "--outputdir", writable)
		default:
			inner = append(inner, "-jar", "input/target.jar", "-o", writable)
		}
	case name == "javap":
		inner = append([]string{in.javap, "-J-Xmx" + o.maxHeap, "-p", "-s", "-classpath", "input/target.jar"}, in.jar.expectedClasses...)
	case name == "jdeps":
		inner = []string{in.jdeps, "-J-Xmx" + o.maxHeap, "--multi-release", "base", "-verbose:class", "input/target.jar"}
	}
	unavailable := in.isJarTool && in.trusted == nil

	var command []string
	var out outcome
	if unavailable {
		now := e.isoNow()
		if err := os.WriteFile(root+"/stdout.raw.txt", nil, 0o666); err != nil {
			return nil, nil, osFailure(err, root)
		}
		if err := os.WriteFile(root+"/stderr.raw.txt", []byte("analyzer JAR unavailable\n"), 0o666); err != nil {
			return nil, nil, osFailure(err, root)
		}
		out = outcome{status: "unavailable", returncode: 127, startedAt: now, endedAt: now}
	} else {
		command = append(isolationPrefix(in.bwrap, writable, bind), inner...)
		var err error
		if out, err = e.runAdapter(command, stage, root, in.environment, o.timeoutSeconds, o.maxFiles, o.maxBytes); err != nil {
			return nil, nil, err
		}
	}
	hasBytes, err := outputContainsBytes(output)
	if err != nil {
		return nil, nil, err
	}
	diagnosticLimit := o.maxBytes
	if hasBytes {
		diagnosticLimit--
	}
	diagnosticRemaining, finalizationTruncated, err := normalizeDiagnostics(root, stage, diagnosticLimit)
	if err != nil {
		return nil, nil, err
	}
	remaining := o.maxBytes - (diagnosticLimit - diagnosticRemaining)
	diagnosticsTruncated := out.diagnosticsTruncated || finalizationTruncated
	inventory, outputsTruncated, err := e.outputInventory(stage, output, o.maxFiles, remaining)
	if err != nil {
		return nil, nil, err
	}
	if (diagnosticsTruncated || outputsTruncated) && (out.status == "success" || out.status == "failed") {
		out.status = "cap_exceeded"
	}
	var manifestPath, identity any
	if !unavailable {
		bound := []boundArtifact{{path: inner[0], argvIndex: firstIndex(command, inner[0])}}
		var evidence []string
		if in.trusted != nil {
			rel := "engines/" + name + "/trusted-source.json"
			payload, err := canonicalBytes(in.trusted)
			if err != nil {
				return nil, nil, err
			}
			if err := atomicWriteNew(stage+"/"+rel, payload); err != nil {
				return nil, nil, err
			}
			evidence = append(evidence, rel)
			bound = append(bound, boundArtifact{path: artifact, argvIndex: firstIndex(command, artifact)})
		}
		mp, id, err := e.makeManifest(stage, manifestInput{
			name: name, command: command, artifacts: bound, evidence: evidence, outcome: out, outputs: inventory,
		})
		if err != nil {
			return nil, nil, err
		}
		manifestPath, identity = mp, id
	}
	records := make([]map[string]any, len(inventory))
	for i, r := range inventory {
		records[i] = r.asMap()
	}
	var exitCode, signal any
	if out.returncode >= 0 {
		exitCode = out.returncode
	} else {
		signal = -out.returncode
	}
	var trusted any
	if in.trusted != nil {
		trusted = in.trusted
	}
	return map[string]any{
		"status": out.status, "exit_code": exitCode, "signal": signal,
		"manifest": manifestPath, "manifest_identity": identity, "output_inventory": records,
		"trusted_source": trusted,
		"diagnostics":    map[string]any{"stdout": "engines/" + name + "/stdout.txt", "stderr": "engines/" + name + "/stderr.txt"},
		"truncated":      map[string]any{"diagnostics": diagnosticsTruncated, "outputs": outputsTruncated},
	}, inventory, nil
}

// openStaged opens the staged input for the class-facts pass.
func openStaged(path string) (*classfile.Jar, error) {
	jar, err := classfile.OpenJar(path)
	if err != nil {
		return nil, archiveFailure(err)
	}
	return jar, nil
}

// classFacts reads the facts of every class entry through the shared classfile reader. The per-class byte limit
// is read from RSDD_CLASSFACTS_MAX_CLASS_BYTES at the first class, so a malformed value warns exactly once.
func (e *env) classFacts(jar *classfile.Jar, entries []string) ([]map[string]any, map[string]any, error) {
	var limit uint64
	records := make([]classfile.Fact, 0, len(entries))
	facts := make([]map[string]any, 0, len(entries))
	for i, name := range entries {
		if i == 0 {
			limit = classfile.EnvLimit(e.s, classfile.MaxClassBytesVar, classfile.DefaultMaxClassBytes)
		}
		f, err := jar.Facts(name, limit)
		if err != nil {
			return nil, nil, err
		}
		records = append(records, f)
		facts = append(facts, f.Map(name))
	}
	return facts, classfile.Summarize(records), nil
}
