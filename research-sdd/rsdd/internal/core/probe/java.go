package probe

import (
	"bytes"
	"fmt"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
)

// BrewPrefix is rsdd_brew_prefix: RSDD_BREW_PREFIX, HOMEBREW_PREFIX, `brew --prefix` stdout (its exit code
// ignored, trailing newlines cut), then /home/linuxbrew/.linuxbrew when it is a directory.
func (p *Prober) BrewPrefix() (string, bool) {
	for _, k := range []string{"RSDD_BREW_PREFIX", "HOMEBREW_PREFIX"} {
		if v := p.get(k); v != "" {
			return v, true
		}
	}
	if brew, ok := p.commandV("brew"); ok {
		out, _ := p.command(brew, "--prefix").Output()
		v := strings.TrimRight(string(out), "\n")
		return v, v != ""
	}
	if lb := p.root + "/home/linuxbrew/.linuxbrew"; p.isDir(lb) {
		return lb, true
	}
	return "", false
}

// brewPath is "${brew:+$brew<suffix>}": empty without a brew prefix.
func (p *Prober) brewPath(suffix string) string {
	if brew, ok := p.BrewPrefix(); ok {
		return brew + suffix
	}
	return ""
}

// command is an exec.Cmd running in the Prober's environment and working directory.
func (p *Prober) command(name string, args ...string) *exec.Cmd {
	cmd := exec.Command(p.abs(name), args...)
	cmd.Env, cmd.Dir = p.environ, p.cwd
	return cmd
}

// JavaHome is rsdd_resolve_java_home: the first usable Java 21+ home among JAVA_HOME,
// RESEARCH_SDD_JAVA_HOME, the brew openjdk@21, the two Debian names, then the java-21-openjdk-* entries.
func (p *Prober) JavaHome() (string, error) {
	jvm := p.root + "/usr/lib/jvm/"
	cands := []string{
		p.get("JAVA_HOME"), p.get("RESEARCH_SDD_JAVA_HOME"), p.brewPath("/opt/openjdk@21"),
		jvm + "java-21-openjdk-amd64", jvm + "java-21-openjdk",
	}
	for _, c := range cands {
		if c != "" && p.java21Usable(c) {
			return c, nil
		}
	}
	for _, c := range p.globNames(jvm, "java-21-openjdk-", "") {
		if p.isDir(c) && p.java21Usable(c) {
			return c, nil
		}
	}
	return "", &Degraded{Tool: "java 21"}
}

var javaVersion = regexp.MustCompile(`.*version "([0-9]+)(\.[0-9]+)?.*`)

// java21Usable is rsdd_java_21_usable: java and javap executable, and `timeout T java -version` (2>&1)
// exits 0 with a first line naming a major version >= 21.
func (p *Prober) java21Usable(home string) bool {
	java := home + "/bin/java"
	if !p.isExec(java) || !p.isExec(home+"/bin/javap") {
		return false
	}
	timeout, ok := p.commandV("timeout")
	if !ok {
		return false
	}
	t := p.get("RSDD_PROBE_TIMEOUT")
	if t == "" {
		t = "10"
	}
	var out bytes.Buffer
	cmd := p.command(timeout, t, java, "-version")
	cmd.Stdout, cmd.Stderr = &out, &out
	if cmd.Run() != nil {
		return false
	}
	first, _, _ := strings.Cut(strings.TrimRight(out.String(), "\n"), "\n")
	m := javaVersion.FindStringSubmatch(first)
	if m == nil {
		return false
	}
	major, err := strconv.Atoi(m[1])
	return err == nil && major >= 21
}

// jarVars maps a decompiler to its override and legacy override variables.
var jarVars = map[string][2]string{
	"vineflower": {"VINEFLOWER_JAR", "VINEFLOWER"},
	"cfr":        {"CFR_JAR", "CFR"},
	"procyon":    {"PROCYON_JAR", "PROCYON"},
}

// JavaJar is rsdd_resolve_java_jar: an override (NAME_JAR, then the legacy NAME) is authoritative and must
// be a regular file; otherwise $RESEARCH_SDD_TOOL_HOME/java/<name>.jar, then (vineflower only) the brew jar.
func (p *Prober) JavaJar(name string) (string, error) {
	vars, ok := jarVars[name]
	if !ok {
		return "", fmt.Errorf("%w: %q", ErrUnknownTool, name)
	}
	for _, k := range vars {
		if v, set := p.lookup(k); set {
			if p.isFile(v) {
				return v, nil
			}
			return "", &Degraded{Tool: name, Override: k}
		}
	}
	home := p.get("RESEARCH_SDD_TOOL_HOME")
	if home == "" {
		home = p.get("HOME") + "/.local/share/research-sdd-tools"
	}
	cands := []string{home + "/java/" + name + ".jar"}
	if name == "vineflower" {
		cands = append(cands, p.brewPath("/opt/vineflower/libexec/vineflower.jar"))
	}
	for _, c := range cands {
		if p.isFile(c) {
			return c, nil
		}
	}
	return "", &Degraded{Tool: name}
}
