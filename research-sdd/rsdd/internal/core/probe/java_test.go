//go:build unix

package probe

import (
	"errors"
	"math"
	"os"
	"strconv"
	"testing"
	"time"
)

// tools is a PATH entry holding the one host tool the java probe execs.
func tools(t *testing.T, d string) string {
	t.Helper()
	real, err := (&Prober{env: map[string]string{"PATH": os.Getenv("PATH")}}).LookPath("timeout")
	if err != nil {
		t.Fatalf("timeout(1) is required by the java probe: %v", err)
	}
	dir := mkdir(t, d, "tools")
	if err := os.Symlink(real, dir+"/timeout"); err != nil {
		t.Fatal(err)
	}
	return dir
}

// jdk writes a fake JDK home whose java prints banner on stderr and exits rc.
func jdk(t *testing.T, d, rel, banner string, rc int) string {
	t.Helper()
	exe(t, d, rel+"/bin/javap", "")
	exe(t, d, rel+"/bin/java", "printf '%b\\n' '"+banner+"' >&2; exit "+strconv.Itoa(rc))
	return d + "/" + rel
}

func TestBrewPrefix(t *testing.T) {
	d := t.TempDir()
	brew := mkdir(t, d, "brewbin")
	exe(t, d, "brewbin/brew", `[ "$1" = --prefix ] && printf '/from/brew\n\n'; exit 3`)
	mkdir(t, d, "home/linuxbrew/.linuxbrew")
	cases := []struct {
		name string
		env  []string
		want string
	}{
		{"RSDD_BREW_PREFIX first", []string{"RSDD_BREW_PREFIX=/r", "HOMEBREW_PREFIX=/h", "PATH=" + brew}, "/r"},
		{"empty RSDD_BREW_PREFIX is skipped", []string{"RSDD_BREW_PREFIX=", "HOMEBREW_PREFIX=/h"}, "/h"},
		{"brew --prefix stdout, trailing newlines cut, rc ignored", []string{"PATH=" + brew}, "/from/brew"},
		{"linuxbrew directory last", []string{"PATH=" + d + "/none"}, d + "/home/linuxbrew/.linuxbrew"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, ok := prober(d, d, c.env...).BrewPrefix()
			if !ok || got != c.want {
				t.Fatalf("got %q %v, want %q", got, ok, c.want)
			}
		})
	}
	if got, ok := prober(t.TempDir(), d, "PATH="+d+"/none").BrewPrefix(); ok || got != "" {
		t.Fatalf("no brew: got %q %v", got, ok)
	}
}

// A hung brew is bounded by RSDD_PROBE_TIMEOUT, as the java -version probe is: BrewPrefix then
// reports no prefix instead of blocking every resolver that consults it.
func TestBrewPrefixHungBrewIsBounded(t *testing.T) {
	d := t.TempDir()
	brew := mkdir(t, d, "brewbin")
	exe(t, d, "brewbin/brew", `/bin/sleep 30; echo /late`)
	start := time.Now()
	got, ok := prober(t.TempDir(), d, "PATH="+brew, "RSDD_PROBE_TIMEOUT=1").BrewPrefix()
	if ok || got != "" {
		t.Fatalf("hung brew: got %q %v, want no prefix", got, ok)
	}
	if el := time.Since(start); el > 10*time.Second {
		t.Fatalf("hung brew took %s, want about RSDD_PROBE_TIMEOUT=1s", el)
	}
}

func TestJavaHome(t *testing.T) {
	d := t.TempDir()
	path := "PATH=" + tools(t, d)
	good := jdk(t, d, "good", `openjdk version "21.0.2" 2024-01-16`, 0)
	old := jdk(t, d, "old", `openjdk version "17.0.9" 2023-10-17`, 0)
	cases := []struct {
		name string
		env  []string
		want string
	}{
		{"JAVA_HOME first", []string{path, "JAVA_HOME=" + good, "RESEARCH_SDD_JAVA_HOME=" + old}, good},
		{"unusable JAVA_HOME falls through", []string{path, "JAVA_HOME=" + old, "RESEARCH_SDD_JAVA_HOME=" + good}, good},
		{"leading zero major", []string{path, "JAVA_HOME=" + jdk(t, d, "z", `java version "021"`, 0)}, d + "/z"},
		{"last version on the first line counts", []string{path, "JAVA_HOME=" + jdk(t, d, "l", `version "17" version "22.1"`, 0)}, d + "/l"},
		{"brew openjdk@21", []string{path, "RSDD_BREW_PREFIX=" + d + "/brew"}, jdk(t, d, "brew/opt/openjdk@21", `version "21"`, 0)},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, err := prober(t.TempDir(), d, c.env...).JavaHome()
			wantPath(t, got, err, c.want)
		})
	}
	bad := map[string]string{
		"major 20":             jdk(t, d, "b20", `openjdk version "20.0.1"`, 0),
		"non-zero exit":        jdk(t, d, "rc", `openjdk version "21"`, 1),
		"no version line":      jdk(t, d, "nv", `garbage`, 0),
		"version on line two":  jdk(t, d, "l2", `x\nopenjdk version "21"`, 0),
		"later version is old": jdk(t, d, "lo", `version "21" version "17"`, 0),
		"missing javap": func() string {
			h := jdk(t, d, "nojavap", `version "21"`, 0)
			os.Remove(h + "/bin/javap")
			return h
		}(),
	}
	for name, home := range bad {
		t.Run(name, func(t *testing.T) {
			got, err := prober(t.TempDir(), d, path, "JAVA_HOME="+home).JavaHome()
			wantDegraded(t, got, err, "java 21", ErrNotFound)
		})
	}
	t.Run("no timeout(1) on PATH makes java unusable", func(t *testing.T) {
		got, err := prober(t.TempDir(), d, "PATH="+d+"/none", "JAVA_HOME="+good).JavaHome()
		wantDegraded(t, got, err, "java 21", ErrNotFound)
	})
	t.Run("host jvm paths, fixed before glob, glob in name order", func(t *testing.T) {
		root := t.TempDir()
		jdk(t, root, "usr/lib/jvm/java-21-openjdk-b", `version "21"`, 0)
		jdk(t, root, "usr/lib/jvm/java-21-openjdk-a", `version "21"`, 0)
		got, err := prober(root, d, path).JavaHome()
		wantPath(t, got, err, root+"/usr/lib/jvm/java-21-openjdk-a")
		jdk(t, root, "usr/lib/jvm/java-21-openjdk", `version "21"`, 0)
		got, err = prober(root, d, path).JavaHome()
		wantPath(t, got, err, root+"/usr/lib/jvm/java-21-openjdk")
		jdk(t, root, "usr/lib/jvm/java-21-openjdk-amd64", `version "21"`, 0)
		got, err = prober(root, d, path).JavaHome()
		wantPath(t, got, err, root+"/usr/lib/jvm/java-21-openjdk-amd64")
	})
}

func TestJavaJar(t *testing.T) {
	d := t.TempDir()
	th := d + "/th"
	vf := put(t, d, "th/java/vineflower.jar", "j", 0o644)
	cfr := put(t, d, "th/java/cfr.jar", "j", 0o644)
	pro := put(t, d, "th/java/procyon.jar", "j", 0o644)
	brewVF := put(t, d, "brew/opt/vineflower/libexec/vineflower.jar", "j", 0o644)
	other := put(t, d, "other.jar", "j", 0o644)
	ok := []struct {
		name, tool string
		env        []string
		want       string
	}{
		{"override wins", "vineflower", []string{"VINEFLOWER_JAR=" + other, "VINEFLOWER=" + vf, "RESEARCH_SDD_TOOL_HOME=" + th}, other},
		{"legacy override", "cfr", []string{"CFR=" + other, "RESEARCH_SDD_TOOL_HOME=" + th}, other},
		{"tool home", "procyon", []string{"RESEARCH_SDD_TOOL_HOME=" + th}, pro},
		{"tool home cfr", "cfr", []string{"RESEARCH_SDD_TOOL_HOME=" + th}, cfr},
		{"HOME default tool home", "vineflower", []string{"HOME=" + d + "/h", "RESEARCH_SDD_TOOL_HOME="}, put(t, d, "h/.local/share/research-sdd-tools/java/vineflower.jar", "j", 0o644)},
		{"brew vineflower after tool home", "vineflower", []string{"RESEARCH_SDD_TOOL_HOME=" + d + "/none", "RSDD_BREW_PREFIX=" + d + "/brew"}, brewVF},
	}
	for _, c := range ok {
		t.Run(c.name, func(t *testing.T) {
			got, err := prober(t.TempDir(), d, c.env...).JavaJar(c.tool)
			wantPath(t, got, err, c.want)
		})
	}
	over := []struct{ name, tool, env string }{
		{"empty override does not fall through", "vineflower", "VINEFLOWER_JAR="},
		{"directory override", "procyon", "PROCYON_JAR=" + d},
		{"legacy directory override", "procyon", "PROCYON=" + d},
	}
	for _, c := range over {
		t.Run(c.name, func(t *testing.T) {
			got, err := prober(t.TempDir(), d, c.env, "RESEARCH_SDD_TOOL_HOME="+th).JavaJar(c.tool)
			wantDegraded(t, got, err, c.tool, ErrOverrideUnusable)
		})
	}
	for _, tool := range []string{"cfr", "procyon"} {
		got, err := prober(t.TempDir(), d, "RESEARCH_SDD_TOOL_HOME="+d+"/none", "RSDD_BREW_PREFIX="+d+"/brew").JavaJar(tool)
		wantDegraded(t, got, err, tool, ErrNotFound)
	}
	if got, err := prober(t.TempDir(), d).JavaJar("jadx"); got != "" || !errors.Is(err, ErrUnknownTool) {
		t.Fatalf("unknown: %q %v", got, err)
	}
}

// timeoutDuration reads RSDD_PROBE_TIMEOUT with timeout(1)'s grammar, so brew and java -version honor one
// setting the same way: a float with an optional s/m/h/d unit, 0 meaning no limit.
func TestTimeoutDuration(t *testing.T) {
	cases := []struct {
		in   string
		want time.Duration
		ok   bool
	}{
		{"1", time.Second, true},
		{"1.5", 1500 * time.Millisecond, true},
		{"2s", 2 * time.Second, true},
		{"2m", 2 * time.Minute, true},
		{"1h", time.Hour, true},
		{"1d", 24 * time.Hour, true},
		{"0", 0, true},
		{"1e300", math.MaxInt64, true},
		{"", 0, false},
		{"x", 0, false},
		{"5q", 0, false},
		{"-1", 0, false},
		{"inf", 0, false},
		{"nan", 0, false},
	}
	for _, c := range cases {
		if got, ok := timeoutDuration(c.in); got != c.want || ok != c.ok {
			t.Errorf("timeoutDuration(%q) = %v, %v; want %v, %v", c.in, got, ok, c.want, c.ok)
		}
	}
}
