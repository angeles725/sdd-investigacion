package ghidra

import (
	"strconv"
)

// chain is the Ghidra launch chain: the files whose bytes are authenticated, staged and bound into the sandbox.
// The rest of the Ghidra and JDK trees is mounted read-only and unbound (disclosed in the limitations).
var chain = []string{
	"support/analyzeHeadless",
	"support/launch.sh",
	"support/launch.properties",
	"support/LaunchSupport.jar",
	"Ghidra/Framework/Utility/lib/Utility.jar",
	"Ghidra/application.properties",
}

// Logical (stage-relative) names of the staged files.
const (
	logicalExporter = "script/CuratedEvidenceExporter.java"
	logicalBwrap    = "tool/bwrap"
	logicalJava     = "tool/jdk/bin/java"
)

// Positions in the locked-descriptor list, which is also the order the child inherits them (descriptor 3 + index).
const (
	idxExporter = 0
	idxBwrap    = 1
	idxChain    = 2
)

var (
	idxJava  = idxChain + len(chain)
	idxInput = idxJava + 1
)

// Guest paths inside the sandbox.
const (
	guestRoot  = "/tmp/rsdd"
	guestWork  = guestRoot + "/work"
	guestGhidr = guestRoot + "/ghidra"
	guestJDK   = guestRoot + "/jdk"
)

// envVar is one sandbox environment entry; the order is part of the recorded argv.
type envVar struct{ k, v string }

func envList(env []envVar) []string {
	out := make([]string, len(env))
	for i, e := range env {
		out[i] = e.k + "=" + e.v
	}
	return out
}

// sandbox is the full Bubblewrap invocation.
type sandbox struct {
	command []string // argv[0] is "tool/bwrap" (the staged launcher); the rest is bwrap's flags then inner
	inner   []string // the Ghidra headless command line as the sandbox sees it
	env     []envVar
	bound   []string // stage-relative names of the bound tools, in provenance order, without the launcher
}

// fdPath is the /proc entry through which the child reaches its n-th inherited descriptor (descriptor 3+n).
func fdPath(n int) string { return "/proc/self/fd/" + strconv.Itoa(3+n) }

// buildSandbox assembles the command: no network namespace, a read-only host root, a private tmpfs, the Ghidra
// and JDK trees read-only, the staged files bound by descriptor, the run directories writable and a synthetic
// home/XDG/TMPDIR. ghidra and javaHome are the canonical host directories.
func buildSandbox(cfg config, ghidra, javaHome string) sandbox {
	state := guestWork + "/state"
	env := []envVar{
		{"HOME", state + "/home"}, {"XDG_CACHE_HOME", state + "/cache"}, {"XDG_CONFIG_HOME", state + "/config"},
		{"XDG_DATA_HOME", state + "/data"}, {"TMPDIR", state + "/tmp"}, {"JAVA_HOME", guestJDK},
		{"PATH", guestJDK + "/bin:/usr/bin:/bin"}, {"LANG", "C.UTF-8"}, {"LC_ALL", "C.UTF-8"}, {"TZ", "UTC"},
	}
	cmd := []string{logicalBwrap, "--die-with-parent", "--new-session", "--unshare-net", "--ro-bind", "/", "/",
		"--proc", "/proc", "--dev", "/dev", "--tmpfs", guestRoot, "--dir", guestWork, "--dir", guestGhidr, "--dir", guestJDK,
		"--ro-bind", ghidra, guestGhidr, "--ro-bind", javaHome, guestJDK, "--ro-bind", ".", guestWork}
	for _, dir := range []string{"project", "output", "logs", "state"} {
		cmd = append(cmd, "--bind", dir, guestWork+"/"+dir)
	}
	cmd = append(cmd, "--ro-bind", fdPath(idxInput), guestWork+"/input/target.bin")
	cmd = append(cmd, "--ro-bind", fdPath(idxExporter), guestWork+"/"+logicalExporter)
	for i, item := range chain {
		cmd = append(cmd, "--ro-bind", fdPath(idxChain+i), guestGhidr+"/"+item)
	}
	cmd = append(cmd, "--ro-bind", fdPath(idxJava), guestJDK+"/bin/java")
	bound := []string{logicalExporter}
	for _, item := range chain {
		bound = append(bound, "tool/ghidra/"+item)
	}
	bound = append(bound, logicalJava)
	cmd = append(cmd, "--dir", guestRoot+"/provenance")
	for i, logical := range bound {
		cmd = append(cmd, "--ro-bind", logical, guestRoot+"/provenance/"+strconv.Itoa(i))
	}
	for _, e := range env {
		cmd = append(cmd, "--setenv", e.k, e.v)
	}
	caps := cfg.caps()
	inner := []string{"/usr/bin/env", "GHIDRA_HEADLESS_MAXMEM=" + strconv.Itoa(cfg.heapMB) + "M",
		"GHIDRA_HEADLESS_JAVA_OPTIONS=-Djava.io.tmpdir=" + state + "/tmp",
		"/usr/bin/prlimit", "--cpu=" + strconv.Itoa(cfg.analysisTimeout+5), "--",
		guestGhidr + "/support/analyzeHeadless", guestWork + "/project", "rsdd", "-import", guestWork + "/input/target.bin",
		"-readOnly", "-deleteProject", "-analysisTimeoutPerFile", strconv.Itoa(cfg.analysisTimeout),
		"-max-cpu", strconv.Itoa(cfg.cpus), "-scriptPath", guestWork + "/script", "-postScript",
		"CuratedEvidenceExporter.java", guestWork + "/output/curated.json"}
	for _, name := range capNames {
		inner = append(inner, strconv.Itoa(caps[name]))
	}
	inner = append(inner, "-log", guestWork+"/logs/application.log", "-scriptlog", guestWork+"/logs/script.log")
	cmd = append(cmd, "--chdir", guestWork, "--")
	return sandbox{command: append(cmd, inner...), inner: inner, env: env, bound: bound}
}

// probeCommand is the sandbox command up to --chdir followed by a no-op, proving the sandbox starts.
func (s sandbox) probeCommand() []string {
	i := indexOf(s.command, "--chdir")
	return append(append([]string{}, s.command[:i]...), "--chdir", guestWork, "--", "/bin/true")
}
