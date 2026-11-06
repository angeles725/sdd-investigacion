package show

// The remote-visibility group (kit #1245, #1820): the block reads back the visibility of each git remote through a
// bounded gh probe and reports it. PUBLIC is a WARN, PRIVATE and INTERNAL are silent, every other answer is a typed
// `degraded:` line (and sets the reason-codes footer). The fake gh answers spec/gh.{out,rc,sleep}.

const (
	pubWarn   = "WARN public-remote: origin is PUBLIC — METHODOLOGY §15: a corpus remote is NEVER public;"
	reasonFtr = "  reason codes    : each typed degraded state in this report"
)

func s6Visibility() []s6Scenario {
	var scs []s6Scenario
	base := st6(1, "", row("high", "H1", "pending"))
	gh := func(out string, more ...string) files { return spec(append([]string{"gh.out", out}, more...)...) }
	vis := func(name, want string, repo, sp files, env map[string]string) {
		scs = append(scs, os6(name, want, base, merge(repo, sp), env))
	}
	origin := func(url string) files { return gitRepo("origin", url) }
	const gh1 = "https://github.com/o/r.git"
	vis("v-no-git-is-silent", hdrOne, nil, gh("PUBLIC"), nil)
	vis("v-git-without-remotes-is-silent", hdrOne, gitRepo(), gh("PUBLIC"), nil)
	vis("v-public-warns", pubWarn, origin(gh1), gh("PUBLIC"), nil)
	vis("v-private-is-silent", hdrOne, origin(gh1), gh("PRIVATE"), nil)
	vis("v-internal-is-silent", hdrOne, origin(gh1), gh("INTERNAL"), nil)
	vis("v-answer-is-upper-cased", pubWarn, origin(gh1), gh("public"), nil)
	vis("v-answer-trailing-newlines-are-cut", pubWarn, origin(gh1), gh("Public\n\n\n"), nil)
	vis("v-unrecognised-answer", "degraded: remote-visibility: unrecognised gh answer [SOMETHING ELSE] for remote origin — visibility unverified", origin(gh1), gh("something else"), nil)
	vis("v-empty-answer", "degraded: remote-visibility: unrecognised gh answer [] for remote origin — visibility unverified", origin(gh1), gh(""), nil)
	vis("v-answer-with-a-suffix-is-not-public", "unrecognised gh answer [PUBLIC REPO]", origin(gh1), gh("public repo"), nil)
	vis("v-gh-error-reports-its-code", "degraded: remote-visibility: gh failed (rc=1) for remote origin — visibility unverified", origin(gh1), gh("", "gh.rc", "1"), nil)
	vis("v-gh-error-with-another-code", "gh failed (rc=4) for remote origin", origin(gh1), gh("PUBLIC", "gh.rc", "4"), nil)
	vis("v-gh-timeout", "degraded: remote-visibility: gh timed out for remote origin — visibility unverified", origin(gh1), gh("", "gh.sleep", "30"), map[string]string{"RSDD_GH_TIMEOUT": "1"})
	vis("v-gh-timeout-skips-the-later-remotes", "degraded: remote-visibility: skipped after timeout for remote upstream — visibility unverified",
		gitRepo("origin", gh1, "upstream", "https://github.com/o/u.git", "zeta", "https://github.com/o/z.git"), gh("", "gh.sleep", "30"), map[string]string{"RSDD_GH_TIMEOUT": "1"})
	vis("v-gh-missing", "degraded: remote-visibility: gh not found — cannot verify the visibility of remote origin", origin(gh1), gh("PUBLIC"), map[string]string{"RSDD_GH_BIN": "no-such-gh-binary"})
	vis("v-gh-missing-names-every-remote", "gh not found — cannot verify the visibility of remote upstream", gitRepo("origin", gh1, "upstream", "https://gitlab.com/o/r"), gh("PUBLIC"), map[string]string{"RSDD_GH_BIN": "no-such-gh-binary"})
	vis("v-gh-missing-hides-the-url-checks", "gh not found — cannot verify the visibility of remote origin", origin("https://gitlab.com/o/r"), gh("PUBLIC"), map[string]string{"RSDD_GH_BIN": "no-such-gh-binary"})
	vis("v-gh-bin-with-a-slash-that-is-not-there", "gh not found", origin(gh1), gh("PUBLIC"), map[string]string{"RSDD_GH_BIN": "/nonexistent/dir/gh"})
	vis("v-gh-bin-not-executable", "gh not found", origin(gh1), merge(gh("PUBLIC"), files{"corpus/not-exec": "#!/bin/sh\n"}), map[string]string{"RSDD_GH_BIN": "corpus/not-exec"})
	vis("v-gh-bin-override-is-used", pubWarn, origin(gh1), gh("PUBLIC"), map[string]string{"RSDD_GH_BIN": "gh"})
	vis("v-non-github-remote", "degraded: remote-visibility: origin not a github owner/repo — visibility unverified", origin("https://gitlab.com/o/r.git"), gh("PUBLIC"), nil)
	vis("v-local-path-remote", "origin not a github owner/repo", origin("/srv/git/r.git"), gh("PUBLIC"), nil)
	vis("v-github-host-lookalike", "origin not a github owner/repo", origin("https://github.com.evil.org/o/r"), gh("PUBLIC"), nil)
	vis("v-github-url-without-a-repo", "origin not a github owner/repo", origin("https://github.com/o"), gh("PUBLIC"), nil)
	vis("v-github-url-with-a-subpath", "origin not a github owner/repo", origin("https://github.com/o/r/tree/main"), gh("PUBLIC"), nil)
	vis("v-ssh-scp-form", pubWarn, origin("git@github.com:o/r.git"), gh("PUBLIC"), nil)
	vis("v-ssh-url-form", pubWarn, origin("ssh://git@github.com/o/r"), gh("PUBLIC"), nil)
	vis("v-git-protocol-form", pubWarn, origin("git://github.com/o/r.git"), gh("PUBLIC"), nil)
	vis("v-https-trailing-slash", pubWarn, origin("https://github.com/o/r/"), gh("PUBLIC"), nil)
	vis("v-https-credentials-never-reach-gh", pubWarn, origin("https://user:s3cret@github.com/o/r.git"), gh("PUBLIC"), nil)
	vis("v-no-scheme-host-form", pubWarn, origin("github.com/o/r"), gh("PUBLIC"), nil)
	vis("v-colon-and-slash-runs", pubWarn, origin("github.com:/o/r"), gh("PUBLIC"), nil)
	vis("v-dot-git-suffix-removed-once", pubWarn, origin("https://github.com/o/r.git.git"), gh("PUBLIC"), nil)
	vis("v-owner-and-repo-punctuation", pubWarn, origin("https://github.com/My-Org.x/some_repo-1.2"), gh("PUBLIC"), nil)
	vis("v-owner-must-start-alphanumeric", "origin not a github owner/repo", origin("https://github.com/-o/r"), gh("PUBLIC"), nil)
	vis("v-remote-without-a-url", "degraded: remote-visibility: ghost not a github owner/repo — visibility unverified", files{"corpus/.git/HEAD": "ref: refs/heads/main\n", "corpus/.git/objects/": "", "corpus/.git/refs/": "", "corpus/.git/config": "[remote \"ghost\"]\n\tfetch = +refs/heads/*:refs/remotes/ghost/*\n"}, gh("PUBLIC"), nil)
	vis("v-remotes-in-git-order", "WARN public-remote: a is PUBLIC", gitRepo("b", "https://github.com/o/b", "a", "https://github.com/o/a"), gh("PUBLIC"), nil)
	vis("v-three-remotes-three-answers", "b not a github owner/repo", gitRepo("a", gh1, "b", "https://gitlab.com/o/r", "c", "https://github.com/o/c"), gh("PUBLIC"), nil)
	vis("v-git-dir-that-is-a-file-is-silent", hdrOne, files{"corpus/.git": "gitdir: /nonexistent\n"}, gh("PUBLIC"), nil)
	vis("v-git-dir-that-is-not-a-repository-is-silent", hdrOne, files{"corpus/.git/": ""}, gh("PUBLIC"), nil)
	vis("v-degraded-line-sets-the-footer", reasonFtr, origin("https://gitlab.com/o/r"), gh("PUBLIC"), nil)
	vis("v-public-alone-does-not-set-the-footer", pubWarn, origin(gh1), gh("PUBLIC"), nil)
	vis("v-visibility-block-comes-after-the-campaign-block", "campaign        : none (1 active focus, 0 with a queue)", origin(gh1), gh("PUBLIC"), nil)
	return scs
}
