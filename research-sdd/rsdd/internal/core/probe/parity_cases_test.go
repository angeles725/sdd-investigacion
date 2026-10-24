//go:build unix

package probe

import (
	"os"
	"os/exec"
	"testing"
)

// hostTools is a PATH entry with the host tools tool-env.sh itself runs (and nothing it resolves).
func hostTools(t *testing.T, d string) string {
	t.Helper()
	dir := mkdir(t, d, "hosttools")
	for _, name := range []string{"sed", "dirname", "basename", "sort", "timeout"} {
		real, err := exec.LookPath(name)
		if err != nil {
			t.Fatalf("%s is required by tool-env.sh: %v", name, err)
		}
		if err := os.Symlink(real, dir+"/"+name); err != nil {
			t.Fatal(err)
		}
	}
	return dir
}

// parityCases builds the fixtures under one temp dir. Every case pins RSDD_BREW_PREFIX (or a fake brew)
// and RSDD_R2_USRBIN so no host tool is executed, and every java case ends in a usable fixture JDK so the
// search never reaches a host JVM.
func parityCases(t *testing.T) []pcase {
	d := t.TempDir()
	path := "PATH=" + hostTools(t, d)
	nobrew := "RSDD_BREW_PREFIX=" + d + "/nobrew"
	base := []string{path, nobrew, "HOME=" + d + "/home", "RSDD_R2_USRBIN=" + d + "/none"}
	env := func(kv ...string) []string { return append(append([]string(nil), base...), kv...) }
	cs := []pcase{}
	add := func(name, mode, arg string, kv ...string) {
		cs = append(cs, pcase{name: name, mode: mode, arg: arg, cwd: d, env: env(kv...)})
	}

	// command -v
	put(t, d, "a/foo", "x", 0o644)
	exe(t, d, "b/foo", "")
	mkdir(t, d, "c/foo")
	for name, p := range map[string]string{
		"exec over earlier non-exec": d + "/a:" + d + "/b", "dir skipped": d + "/c:" + d + "/b",
		"non-exec fallback": d + "/a", "trailing slash": d + "/b/", "double slash": d + "/b//",
		"empty element": d + "/a::", "relative element": "b", "dotdot element": "../" + posixBase(d) + "/b",
		"miss": d + "/c",
	} {
		cs = append(cs, pcase{name: name, mode: "cmdv", arg: "foo", cwd: d, env: []string{"PATH=" + p}})
	}
	cs = append(cs,
		pcase{name: "empty PATH", mode: "cmdv", arg: "foo", cwd: d + "/b", env: []string{"PATH="}},
		pcase{name: "unset PATH", mode: "cmdv", arg: "foo", cwd: d + "/b", unsetPath: true},
		pcase{name: "slash name", mode: "cmdv", arg: "b/foo", cwd: d, env: []string{"PATH=/none"}},
		pcase{name: "slash non-exec", mode: "cmdv", arg: "a/foo", cwd: d, env: []string{"PATH=/none"}},
		pcase{name: "slash dir", mode: "cmdv", arg: "c/foo", cwd: d, env: []string{"PATH=/none"}})

	// brew prefix
	exe(t, d, "fakebrew/brew", `[ "$1" = --prefix ] && printf '/from/brew\n\n'; exit 3`)
	exe(t, d, "silentbrew/brew", "exit 0")
	cs = append(cs,
		pcase{name: "RSDD_BREW_PREFIX", mode: "brew", cwd: d, env: []string{"RSDD_BREW_PREFIX=/r", "HOMEBREW_PREFIX=/h"}},
		pcase{name: "HOMEBREW_PREFIX", mode: "brew", cwd: d, env: []string{"RSDD_BREW_PREFIX=", "HOMEBREW_PREFIX=/h"}},
		pcase{name: "brew --prefix", mode: "brew", cwd: d, env: []string{"PATH=" + d + "/fakebrew"}},
		pcase{name: "silent brew", mode: "brew", cwd: d, env: []string{"PATH=" + d + "/silentbrew"}})

	// java home: each candidate below is tried first, the good JDK is the fallback
	good := jdk(t, d, "good", `openjdk version "21.0.2" 2024-01-16`, 0)
	for name, banner := range map[string]string{
		"21": `openjdk version "21"`, "20": `openjdk version "20.0.1"`, "leading zero": `java version "021"`,
		"last on line wins": `version "17" version "22.1"`, "last on line old": `version "21" version "17"`,
		"second line": `x\nopenjdk version "25"`, "1.8": `java version "1.8.0_392"`, "garbage": "garbage",
		"huge major": `version "99999999999999999999"`, "no quote": `version 21`,
	} {
		add(name, "java", "", "JAVA_HOME="+jdk(t, d, "j/"+name, banner, 0), "RESEARCH_SDD_JAVA_HOME="+good)
	}
	add("non-zero exit", "java", "", "JAVA_HOME="+jdk(t, d, "rc1", `version "21"`, 1), "RESEARCH_SDD_JAVA_HOME="+good)
	add("bad timeout", "java", "", "JAVA_HOME="+jdk(t, d, "bt", `version "22"`, 0), "RSDD_PROBE_TIMEOUT=abc", "RESEARCH_SDD_JAVA_HOME="+good)
	add("brew openjdk", "java", "", "RSDD_BREW_PREFIX="+d+"/jb", "JAVA_HOME="+jdk(t, d, "jb/opt/openjdk@21", `version "23"`, 0)+"x", "RESEARCH_SDD_JAVA_HOME="+good)

	// decompiler jars
	th := d + "/th"
	for _, n := range []string{"vineflower", "cfr", "procyon"} {
		put(t, d, "th/java/"+n+".jar", "j", 0o644)
		add(n+" tool home", "jar", n, "RESEARCH_SDD_TOOL_HOME="+th)
		add(n+" absent", "jar", n, "RESEARCH_SDD_TOOL_HOME="+d+"/none")
	}
	other := put(t, d, "other.jar", "j", 0o644)
	put(t, d, "home/.local/share/research-sdd-tools/java/cfr.jar", "j", 0o644)
	put(t, d, "vb/opt/vineflower/libexec/vineflower.jar", "j", 0o644)
	add("override", "jar", "cfr", "CFR_JAR="+other, "RESEARCH_SDD_TOOL_HOME="+th)
	add("legacy override", "jar", "procyon", "PROCYON="+other, "RESEARCH_SDD_TOOL_HOME="+th)
	add("empty override", "jar", "vineflower", "VINEFLOWER_JAR=", "RESEARCH_SDD_TOOL_HOME="+th)
	add("dir override", "jar", "cfr", "CFR_JAR="+d, "RESEARCH_SDD_TOOL_HOME="+th)
	add("HOME default", "jar", "cfr", "RESEARCH_SDD_TOOL_HOME=")
	add("brew vineflower", "jar", "vineflower", "RSDD_BREW_PREFIX="+d+"/vb", "RESEARCH_SDD_TOOL_HOME="+d+"/none")
	add("unknown", "jar", "jadx")

	// ghidra
	exe(t, d, "g1/support/analyzeHeadless", "")
	exe(t, d, "gb/opt/ghidra/libexec/support/analyzeHeadless", "")
	ns := exe(t, d, "bin/analyzeHeadless", "")
	add("ANALYZE_HEADLESS", "ghidra", "", "ANALYZE_HEADLESS="+d+"/g1/support/analyzeHeadless")
	add("ANALYZE_HEADLESS relative", "ghidra", "", "ANALYZE_HEADLESS=g1/support/analyzeHeadless")
	add("ANALYZE_HEADLESS outside support", "ghidra", "", "ANALYZE_HEADLESS="+ns, "GHIDRA_HOME="+d+"/g1")
	add("ANALYZE_HEADLESS trailing slash", "ghidra", "", "ANALYZE_HEADLESS="+d+"/g1/support/analyzeHeadless/")
	add("GHIDRA_HOME as given", "ghidra", "", "GHIDRA_HOME="+d+"//g1/", "GHIDRA_INSTALL_DIR="+d+"/none")
	add("empty GHIDRA_HOME", "ghidra", "", "GHIDRA_HOME=", "GHIDRA_INSTALL_DIR="+d+"/g1")
	add("GHIDRA_INSTALL_DIR", "ghidra", "", "GHIDRA_INSTALL_DIR="+d+"/g1")
	add("PATH support", "ghidra", "", path+":"+d+"/g1/support")
	add("PATH outside support, brew", "ghidra", "", path+":"+d+"/bin", "RSDD_BREW_PREFIX="+d+"/gb")

	// r2 and ilspycmd
	r2 := exe(t, d, "p/r2", "")
	exe(t, d, "p/ilspycmd", "")
	exe(t, d, "rb/opt/radare2/bin/r2", "")
	exe(t, d, "home/.dotnet/tools/ilspycmd", "")
	add("R2 override", "r2", "", "R2="+r2)
	add("empty R2", "r2", "", "R2=", path+":"+d+"/p")
	add("r2 PATH", "r2", "", path+":"+d+"/p")
	add("r2 brew", "r2", "", "RSDD_BREW_PREFIX="+d+"/rb")
	add("r2 usrbin", "r2", "", "RSDD_R2_USRBIN="+r2)
	add("r2 absent", "r2", "")
	add("ILSPYCMD override", "ilspy", "", "ILSPYCMD="+d+"/p/ilspycmd")
	add("ILSPYCMD non-exec", "ilspy", "", "ILSPYCMD="+other)
	add("ilspycmd PATH", "ilspy", "", path+":"+d+"/p")
	add("ilspycmd dotnet tools", "ilspy", "")
	add("ilspycmd absent", "ilspy", "", "HOME="+d+"/none")

	// system pkg-config path (host directories are only stat'ed)
	add("knob", "pkgcfg", "", "RSDD_SYSTEM_PKGCONFIG_PATH=/x:/y")
	add("host", "pkgcfg", "", "RSDD_SYSTEM_PKGCONFIG_PATH=")
	return cs
}
