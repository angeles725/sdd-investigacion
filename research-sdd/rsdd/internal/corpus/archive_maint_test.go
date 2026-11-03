package corpus

import (
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

// A git commit in a fixture repository must not start background maintenance: `git maintenance run --auto --detach`
// takes .git/objects/maintenance.lock and removes it later, and a `cp -a` of the case tree that lists the lock and
// then finds it gone fails the case (kit issue #2624). The fixture env turns maintenance.auto and gc.auto off, and
// a traced commit through it spawns no maintenance child.
func TestArchiveFixtureGitStartsNoBackgroundMaintenance(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git not on PATH")
	}
	f := &archiveFx{t: t, root: t.TempDir()}
	d := filepath.Join(f.root, "repo")
	f.gitInit(d)
	if err := os.WriteFile(filepath.Join(d, "f"), []byte("x\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	f.git(d, "add", "f")
	c := exec.Command("git", "-C", d, "commit", "-q", "-m", "m")
	c.Env = append(f.gitEnv("2026-06-01T00:00:00"), "GIT_TRACE=1")
	out, err := c.CombinedOutput()
	if err != nil {
		t.Fatalf("commit: %v: %s", err, out)
	}
	if strings.Contains(string(out), "maintenance run") {
		t.Errorf("a fixture commit started background maintenance:\n%s", out)
	}
}

// The commands under test run with the base env, so it carries the same settings.
func TestArchiveBaseEnvTurnsBackgroundMaintenanceOff(t *testing.T) {
	env := archiveBaseEnv(t, t.TempDir())
	for _, kv := range []string{"GIT_CONFIG_KEY_0=maintenance.auto", "GIT_CONFIG_VALUE_0=false", "GIT_CONFIG_KEY_1=gc.auto",
		"GIT_CONFIG_VALUE_1=0", "GIT_CONFIG_COUNT=2"} {
		if !slices.Contains(env, kv) {
			t.Errorf("base env lacks %q: %q", kv, env)
		}
	}
}
