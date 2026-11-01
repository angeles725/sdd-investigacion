package skilldrift

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// The kit-staleness fixtures (kit issue #2130): real repositories, a local bare "origin" plus a clone, under one scratch root
// shared by every hook case (read-only for the commands). HOME of the kit cases is this root, so the fix command reads
// `git -C ~/k25 ...` whatever TMPDIR is.

var (
	fixOnce  sync.Once
	fixRoot  string
	fixBuild sync.Once
	fixErr   error
	fixBehnd = map[string]int{}
)

func fixRootPath() string {
	fixOnce.Do(func() {
		d, err := os.MkdirTemp("", "skdfix")
		if err != nil {
			panic(err)
		}
		if fixRoot, err = filepath.EvalSymlinks(d); err != nil {
			panic(err)
		}
	})
	return fixRoot
}

func gitIn(dir string, args ...string) error {
	full := append([]string{"-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", "-c", "init.defaultBranch=main",
		"-c", "gc.auto=0", "-c", "maintenance.auto=false"}, args...)
	c := exec.Command("git", full...)
	c.Dir = dir
	c.Env = append(dropKey(dropKey(os.Environ(), "HOME"), "GIT_DIR"), "HOME="+fixRootPath(), "GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_SYSTEM=/dev/null")
	if out, err := c.CombinedOutput(); err != nil {
		return fmt.Errorf("git %s: %v: %s", strings.Join(args, " "), err, out)
	}
	return nil
}

func mkOrigin(root, name string, commits int) error {
	if err := gitIn(root, "init", "-q", "--bare", name+".git"); err != nil {
		return err
	}
	if err := gitIn(root, "clone", "-q", name+".git", name+".seed"); err != nil {
		return err
	}
	seed := filepath.Join(root, name+".seed")
	for i := 1; i <= commits; i++ {
		if err := os.WriteFile(filepath.Join(seed, "f"), []byte(fmt.Sprint(i, "\n")), 0o644); err != nil {
			return err
		}
		if err := gitIn(seed, "add", "f"); err != nil {
			return err
		}
		if err := gitIn(seed, "commit", "-q", "-m", fmt.Sprint("c", i)); err != nil {
			return err
		}
	}
	return gitIn(seed, "push", "-q", "origin", "HEAD:main")
}

// mkKit makes a clone of name (at dest, default <root>/name), then n more upstream commits fetched into it: n behind.
func mkKit(root, name string, n int, dest string) error {
	if dest == "" {
		dest = filepath.Join(root, name)
	}
	if err := mkOrigin(root, name, 1); err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(dest), 0o755); err != nil {
		return err
	}
	if err := gitIn(root, "clone", "-q", "-b", "main", name+".git", dest); err != nil {
		return err
	}
	seed := filepath.Join(root, name+".seed")
	for i := 1; i <= n; i++ {
		if err := os.WriteFile(filepath.Join(seed, "g"), []byte(fmt.Sprint("u", i, "\n")), 0o644); err != nil {
			return err
		}
		if err := gitIn(seed, "add", "g"); err != nil {
			return err
		}
		if err := gitIn(seed, "commit", "-q", "-m", fmt.Sprint("u", i)); err != nil {
			return err
		}
	}
	if n > 0 {
		if err := gitIn(seed, "push", "-q", "origin", "HEAD:main"); err != nil {
			return err
		}
		if err := gitIn(dest, "fetch", "-q", "origin"); err != nil {
			return err
		}
	}
	fixBehnd[dest] = n
	return nil
}

// fixtures builds the kit fixtures once and returns their root.
func fixtures(t testing.TB) string {
	t.Helper()
	needTool(t, "git", "RSDD_REQUIRE_GIT")
	root := fixRootPath()
	fixBuild.Do(func() { fixErr = buildFixtures(root) })
	if fixErr != nil {
		t.Fatalf("cannot build the kit fixtures: %v", fixErr)
	}
	return root
}

func buildFixtures(root string) error {
	for _, k := range []struct {
		name string
		n    int
	}{{"k0", 0}, {"k3", 3}, {"k25", 25}, {"kfb", 3}} {
		if err := mkKit(root, k.name, k.n, ""); err != nil {
			return err
		}
	}
	// no @{upstream}, but origin/main exists: the advice cannot be `pull`
	if err := gitIn(filepath.Join(root, "kfb"), "branch", "--unset-upstream"); err != nil {
		return err
	}
	// a repository nested one level and two levels below the checkout root
	for _, d := range []string{"k25/research-sdd", "k25/deep/er"} {
		if err := os.MkdirAll(filepath.Join(root, d), 0o755); err != nil {
			return err
		}
	}
	// a real-like path under a custom HOME, and a very long one
	if err := mkKit(root, "khome", 25, filepath.Join(root, "homefix", "investigacion", "sdd-investigacion")); err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Join(root, "homefix", "investigacion", "sdd-investigacion", "research-sdd"), 0o755); err != nil {
		return err
	}
	if err := mkKit(root, "k25-"+strings.Repeat("x", 150), 25, ""); err != nil {
		return err
	}
	// a never-fetched clone of a quiet (2020) upstream
	if err := gitIn(root, "init", "-q", "--bare", "kquiet.git"); err != nil {
		return err
	}
	if err := gitIn(root, "clone", "-q", "kquiet.git", "kquiet.seed"); err != nil {
		return err
	}
	seed := filepath.Join(root, "kquiet.seed")
	if err := os.WriteFile(filepath.Join(seed, "f"), []byte("q\n"), 0o644); err != nil {
		return err
	}
	if err := gitIn(seed, "add", "f"); err != nil {
		return err
	}
	old := "2020-01-01T00:00:00"
	c := exec.Command("git", "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", "commit", "-q", "-m", "old")
	c.Dir = seed
	c.Env = append(dropKey(os.Environ(), "HOME"), "HOME="+root, "GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_SYSTEM=/dev/null", "GIT_AUTHOR_DATE="+old, "GIT_COMMITTER_DATE="+old)
	if out, err := c.CombinedOutput(); err != nil {
		return fmt.Errorf("old commit: %v: %s", err, out)
	}
	if err := gitIn(seed, "push", "-q", "origin", "HEAD:main"); err != nil {
		return err
	}
	if err := gitIn(root, "clone", "-q", "-b", "main", "kquiet.git", "kquiet"); err != nil {
		return err
	}
	if err := os.Remove(filepath.Join(root, "kquiet", ".git", "FETCH_HEAD")); err != nil && !os.IsNotExist(err) {
		return err
	}
	// the same quiet clone with a 10-day-old .git/config: the config mtime is not an age source (any `git config` write resets it)
	if err := gitIn(root, "clone", "-q", "-b", "main", "kquiet.git", "kquiet2"); err != nil {
		return err
	}
	if err := os.Remove(filepath.Join(root, "kquiet2", ".git", "FETCH_HEAD")); err != nil && !os.IsNotExist(err) {
		return err
	}
	oldCfg := time.Now().Add(-10 * 24 * time.Hour)
	if err := os.Chtimes(filepath.Join(root, "kquiet2", ".git", "config"), oldCfg, oldCfg); err != nil {
		return err
	}
	// a repository with no remote, and a plain directory
	if err := gitIn(root, "init", "-q", "norem"); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(root, "norem", "f"), []byte("x\n"), 0o644); err != nil {
		return err
	}
	if err := gitIn(filepath.Join(root, "norem"), "add", "f"); err != nil {
		return err
	}
	if err := gitIn(filepath.Join(root, "norem"), "commit", "-q", "-m", "c"); err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Join(root, "plain"), 0o755); err != nil {
		return err
	}
	// a clone whose FETCH_HEAD is ten days old (current with its upstream)
	if err := mkKit(root, "kold", 0, ""); err != nil {
		return err
	}
	fh := filepath.Join(root, "kold", ".git", "FETCH_HEAD")
	if _, err := os.Stat(fh); err != nil {
		if err := os.WriteFile(fh, nil, 0o644); err != nil {
			return err
		}
	}
	ten := time.Now().Add(-10 * 24 * time.Hour)
	return os.Chtimes(fh, ten, ten)
}

// kitStubOut is the install --verify stub output of the kit cases: MATCH, plus an install-style behind line when the fixture is
// behind its upstream (the real install prints one for ANY behind > 0).
func kitStubOut(dir string, n int) string {
	if n <= 0 {
		return matchOut
	}
	return matchOut + "\n" + fmt.Sprintf("verify kit status=behind ref=origin/main behind=%d (local ref, no fetch — may understate) fix: git -C %s pull --ff-only", n, dir)
}

const (
	matchOut  = "verify harness=claude status=match bundle_sha256=abc files=3\nverify harness=pi status=absent (not installed)\nverify kit status=current ref=origin/main behind=0 (local ref, no fetch)"
	behindOut = "verify kit status=behind ref=origin/main behind=47 (local ref, no fetch — may understate) fix: git -C /k pull --ff-only"
)
