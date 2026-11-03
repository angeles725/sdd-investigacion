package gitfixture

import (
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestEnv(t *testing.T) {
	for _, c := range []struct {
		name string
		base []string
		want []string
	}{
		{"no prior config", []string{"A=1"}, []string{"A=1",
			"GIT_CONFIG_KEY_0=maintenance.auto", "GIT_CONFIG_VALUE_0=false", "GIT_CONFIG_KEY_1=gc.auto", "GIT_CONFIG_VALUE_1=0",
			"GIT_CONFIG_COUNT=2"}},
		{"an existing count is extended", []string{"GIT_CONFIG_COUNT=1", "GIT_CONFIG_KEY_0=user.name", "GIT_CONFIG_VALUE_0=t"},
			[]string{"GIT_CONFIG_KEY_0=user.name", "GIT_CONFIG_VALUE_0=t",
				"GIT_CONFIG_KEY_1=maintenance.auto", "GIT_CONFIG_VALUE_1=false", "GIT_CONFIG_KEY_2=gc.auto", "GIT_CONFIG_VALUE_2=0",
				"GIT_CONFIG_COUNT=3"}},
		{"the last count entry wins", []string{"GIT_CONFIG_COUNT=5", "GIT_CONFIG_COUNT=0"}, []string{
			"GIT_CONFIG_KEY_0=maintenance.auto", "GIT_CONFIG_VALUE_0=false", "GIT_CONFIG_KEY_1=gc.auto", "GIT_CONFIG_VALUE_1=0",
			"GIT_CONFIG_COUNT=2"}},
		{"an empty non-nil base", []string{}, []string{
			"GIT_CONFIG_KEY_0=maintenance.auto", "GIT_CONFIG_VALUE_0=false", "GIT_CONFIG_KEY_1=gc.auto", "GIT_CONFIG_VALUE_1=0",
			"GIT_CONFIG_COUNT=2"}},
	} {
		t.Run(c.name, func(t *testing.T) {
			in := append([]string{}, c.base...)
			if got := Env(c.base); !reflect.DeepEqual(got, c.want) {
				t.Errorf("got %q\nwant %q", got, c.want)
			}
			if !reflect.DeepEqual(c.base, in) {
				t.Errorf("the input was modified: %q", c.base)
			}
		})
	}
}

func TestEnvPanics(t *testing.T) {
	for _, base := range [][]string{nil, {"GIT_CONFIG_COUNT=x"}, {"GIT_CONFIG_COUNT=-1"}} {
		func() {
			defer func() {
				if recover() == nil {
					t.Errorf("Env(%q) did not panic", base)
				}
			}()
			Env(base)
		}()
	}
}

// Through Env, a traced commit spawns no maintenance child, and an existing config entry is still honoured.
func TestEnvStopsBackgroundMaintenance(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git not on PATH")
	}
	d := t.TempDir()
	base := []string{"PATH=" + os.Getenv("PATH"), "HOME=" + d, "GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_NOSYSTEM=1",
		"GIT_CONFIG_COUNT=2", "GIT_CONFIG_KEY_0=user.name", "GIT_CONFIG_VALUE_0=tester",
		"GIT_CONFIG_KEY_1=user.email", "GIT_CONFIG_VALUE_1=t@example.com"}
	run := func(env []string, args ...string) string {
		c := exec.Command("git", append([]string{"-C", d}, args...)...)
		c.Env = env
		out, err := c.CombinedOutput()
		if err != nil {
			t.Fatalf("git %v: %v: %s", args, err, out)
		}
		return string(out)
	}
	env := Env(base)
	run(env, "init", "-q")
	if err := os.WriteFile(filepath.Join(d, "f"), []byte("x\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	run(env, "add", "f")
	if out := run(append(env, "GIT_TRACE=1"), "commit", "-q", "-m", "m"); strings.Contains(out, "maintenance run") {
		t.Errorf("a commit through Env started background maintenance:\n%s", out)
	}
	if who := strings.TrimSpace(run(env, "log", "-1", "--format=%an")); who != "tester" {
		t.Errorf("the caller's GIT_CONFIG entry was lost: author %q", who)
	}
}
