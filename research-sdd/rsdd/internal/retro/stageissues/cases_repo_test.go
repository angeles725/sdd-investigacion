package stageissues

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func pathOf() string { return os.Getenv("PATH") }

// gitIn runs git in dir with a hermetic environment; a failure fails the test.
func gitIn(t *testing.T, dir string, args ...string) {
	t.Helper()
	cmd := exec.Command("git", args...)
	cmd.Dir = dir
	cmd.Env = []string{"PATH=" + pathOf(), "HOME=" + dir, "GIT_CONFIG_NOSYSTEM=1", "GIT_CONFIG_GLOBAL=/dev/null"}
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("git %s: %v\n%s", strings.Join(args, " "), err, out)
	}
}

// withRemote initialises the KIT root (the box itself: the script sits at box/research-sdd/toolbelt) as a git
// checkout whose origin is url, and drops the env override so the remote decides.
func withRemote(c dcase, url string) dcase {
	c = c.withEnv("RESEARCH_SDD_ISSUE_REPO", "\x00unset")
	c.prep = func(t *testing.T, b *box) {
		gitIn(t, b.root, "init", "-q", ".")
		gitIn(t, b.root, "remote", "add", "origin", url)
	}
	return c
}

// casesRepo: the kit issue repo resolution (old suite 19-58): override, remote forms, shape validation, git
// missing, an enclosing checkout, and the --apply refusals.
func casesRepo() []dcase {
	one := doc(pending, row("1", "first delta of the retro", "CLAUDE.md", "B1", "fix", "LOW"))
	base := dry("repo/base", one)
	var out []dcase
	for i, url := range []string{
		"https://github.com/o/n.git", "https://github.com/o/n", "https://github.com/o/n/", "https://github.com/o/n.git/",
		"https://www.github.com/o/n.git", "https://github.com-work/o/n.git", "https://github.com:443/o/n.git",
		"https://ghe.example.com/o/n.git", "https://ghe.corp.com:8443/o/n.git", "ssh://git@github.com/o/n.git",
		"ssh://git@github.com:22/o/n.git", "ssh://git@ssh.github.com:443/o/n.git", "ssh://github.com/o/n",
		"git@github.com:o/n.git", "git@github.com:o/n", "github.com:o/n", "git@github.com-alias:o/n.git", "git@ghe.corp.com:o/n.git",
		"work:o/n.git", "file:///srv/git/n.git", "https://github.com-x.corp/o/n.git", "https://github.com-evil.attacker.com/o/n.git",
		"https://GitHub.com/O/N.git", "https://github.com/o.x/n_y.git", "http://github.com/o/n.git", "https://user@github.com/o/n.git",
		"https://github.com/o/n/extra.git", "https://github.com/o", "not a url", "../o/n", "https://github.com/-o/n.git", "https://github.com/o/.git",
		"HTTPS://github.com/o/n.git", "ssh://git@github.com-work:22/o/n.git", "git@GITHUB.COM:o/n.git", "git@github.com.:o/n.git",
	} {
		c := withRemote(base, url)
		c.name = "repo/remote-" + strings.NewReplacer("/", "_", ":", "_", "@", "_", " ", "_").Replace(url) + "-" + string(rune('a'+i%26))
		out = append(out, c)
	}
	for _, v := range []string{
		"o/n", "ghe.corp.com/o/n", "a.b.c/o/n", "bad", "a b/c", "o/n/extra/junk", "myorg/myrepo/subpath", "-o/n", "o/..", "../o/n", "./o/n",
		"o/n.git", "o_x/n-y.z", "ghe.corp.com/o", "9/9", "ghe-1.corp.com/own/rep", "host.-x/o/n", "https://github.com/o/n",
	} {
		c := base.withEnv("RESEARCH_SDD_ISSUE_REPO", v)
		c.name = "repo/override-" + strings.NewReplacer("/", "_", " ", "_", ".", "-").Replace(v)
		out = append(out, c, func() dcase { a := c.withArgs("--apply"); a.name += "-apply"; return a }())
	}
	noRemote := base.withEnv("RESEARCH_SDD_ISSUE_REPO", "\x00unset")
	noRemote.name = "repo/no-remote-no-repo"
	noRemoteRepo := noRemote
	noRemoteRepo.name = "repo/git-init-without-origin"
	noRemoteRepo.prep = func(t *testing.T, b *box) { gitIn(t, b.root, "init", "-q", ".") }
	enclosing := noRemote
	enclosing.name = "repo/enclosing-checkout"
	enclosing.prep = func(t *testing.T, b *box) {
		parent := filepath.Dir(b.root)
		gitIn(t, parent, "init", "-q", ".")
		gitIn(t, parent, "remote", "add", "origin", "https://github.com/enclosing/leak.git")
	}
	noGit := noRemote
	noGit.name, noGit.path = "repo/git-missing", "nogit"
	out = append(out, noRemote, noRemoteRepo, enclosing, noGit,
		func() dcase { a := noRemote.withArgs("--apply"); a.name = "repo/no-remote-apply"; return a }(),
		func() dcase { a := enclosing.withArgs("--apply"); a.name = "repo/enclosing-apply"; return a }(),
		func() dcase { a := noGit.withArgs("--apply"); a.name = "repo/git-missing-apply"; return a }(),
		func() dcase {
			a := withRemote(base, "git@ghe.corp.com:o/n.git").withArgs("--apply")
			a.name = "repo/untrusted-scp-apply"
			return a
		}(),
		func() dcase {
			a := withRemote(base, "https://github.com/o/n.git").withArgs("--apply")
			a.name = "repo/remote-apply-ok"
			return a
		}(),
		base.withEnv("RESEARCH_SDD_ISSUE_REPO", ""),
	)
	last := &out[len(out)-1]
	last.name = "repo/override-empty-string"
	return out
}
