package stageissues

import (
	"path/filepath"
	"regexp"
	"strings"
)

// Kit issue repo resolution (kit issues #1037, #1045, #1046). Delta issues MUST land in the KIT repo, never in
// whatever repo the process cwd resolves to, so every gh call carries an explicit --repo resolved once here:
//  1. RESEARCH_SDD_ISSUE_REPO (owner/name), shape-validated;
//  2. `git -C <kit root> remote get-url origin`, only when the kit root IS the checkout root (never an
//     enclosing repo), normalised from https, ssh:// and scp-like forms, then shape-validated.

// repoShape is the only shape ever handed to `gh --repo`: [HOST/]OWNER/REPO, every segment starting with an
// alphanumeric (which alone rejects `.`/`..` and a leading `-`), and a HOST that holds at least one dot (so a
// 3-segment `myorg/myrepo/subpath` is NOT read as HOST/OWNER/REPO).
var repoShape = regexp.MustCompilePOSIX(`^([A-Za-z0-9][A-Za-z0-9-]*(\.[A-Za-z0-9-]+)+/)?[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*$`)

// githubAlias is a host that IS github.com under a www./ssh. prefix or an SSH-config alias suffix (`-work`); the
// suffix may not contain a dot or slash, so `github.com-x.corp` is a different host and is kept verbatim.
var githubAlias = regexp.MustCompilePOSIX(`^(ssh\.|www\.)?github\.com(-[^./]*)?$`)

var (
	reURLRemote = regexp.MustCompilePOSIX(`^(https?|ssh)://([^/@[:space:]]+@)?([^/]+)/(.+)$`)
	// The next char after ':' is not '/': git's own test for scp-like syntax, so file:///x is not read as host "file".
	reSCPRemote = regexp.MustCompilePOSIX(`^([^/@:[:space:]]+@)?([^/@:[:space:]]+):([^/].*)$`)
)

// scpSentinel wraps the host of an untrusted scp-form remote so resolveRepo can name it; it never matches repoShape.
const scpSentinel = "__kit_issue_repo_untrusted_scp_host__"

func validRepoShape(v string) bool { return repoShape.MatchString(v) }

// lowerASCII is `tr 'A-Z' 'a-z'`.
func lowerASCII(s string) string {
	b := []byte(s)
	for i, c := range b {
		if c >= 'A' && c <= 'Z' {
			b[i] = c + 32
		}
	}
	return string(b)
}

// normalizeRemote is _normalize_git_remote_url: the [HOST/]owner/repo candidate of a git remote URL, or the
// sentinel-wrapped host of an scp-form remote that does not look like github.com. An unrecognised scheme comes
// back unchanged and then fails validRepoShape.
func normalizeRemote(url string) string {
	var host, rest string
	isURL := false
	if m := reURLRemote.FindStringSubmatch(url); m != nil {
		host, rest, isURL = m[3], m[4], true
	} else if m := reSCPRemote.FindStringSubmatch(url); m != nil {
		host, rest = m[2], m[3]
	} else {
		return url
	}
	if i := strings.IndexByte(host, ':'); i >= 0 { // a URL-scheme host may carry :port
		host = host[:i]
	}
	rest = strings.TrimSuffix(rest, "/")
	rest = strings.TrimSuffix(rest, ".git")
	rest = strings.TrimSuffix(rest, "/")
	alias := githubAlias.MatchString(lowerASCII(host))
	switch {
	case alias:
		return rest
	case isURL:
		return host + "/" + rest
	}
	return scpSentinel + host
}

// repoResolution is the outcome of resolveRepo: Repo on success, else RC (the typed reason) and the detail the
// message names.
type repoResolution struct {
	Repo     string
	RC       int
	BadValue string // rc 4 and 5: the offending value / the untrusted host
	Toplevel string // rc 3: the enclosing checkout's root
}

// resolveRepo is resolve_kit_issue_repo. RCs: 1 no override and no resolvable remote, 2 git missing, 3 the kit
// root is not the checkout toplevel (an enclosing repo was found), 4 bad shape, 5 untrusted scp host.
func (a *app) resolveRepo() repoResolution {
	if v := a.env("RESEARCH_SDD_ISSUE_REPO"); v != "" {
		if validRepoShape(v) {
			return repoResolution{Repo: v}
		}
		return repoResolution{RC: 4, BadValue: v}
	}
	if !a.hasCommand("git") {
		return repoResolution{RC: 2}
	}
	top, ok := a.gitOut("-C", a.kitRoot, "rev-parse", "--show-toplevel")
	if !ok || top == "" {
		return repoResolution{RC: 1}
	}
	topPhys, err := filepath.EvalSymlinks(top)
	if err != nil {
		return repoResolution{RC: 1}
	}
	kitPhys, err := filepath.EvalSymlinks(a.kitRoot)
	if err != nil {
		return repoResolution{RC: 1}
	}
	if abs, e := filepath.Abs(topPhys); e == nil {
		topPhys = abs
	}
	if topPhys != kitPhys {
		return repoResolution{RC: 3, Toplevel: topPhys}
	}
	url, ok := a.gitOut("-C", a.kitRoot, "remote", "get-url", "origin")
	if !ok || url == "" {
		return repoResolution{RC: 1}
	}
	repo := normalizeRemote(url)
	if strings.HasPrefix(repo, scpSentinel) {
		return repoResolution{RC: 5, BadValue: strings.TrimPrefix(repo, scpSentinel)}
	}
	if !validRepoShape(repo) {
		return repoResolution{RC: 4, BadValue: repo}
	}
	return repoResolution{Repo: repo}
}

// reason is the message text the dry-run line and the --apply refusal both carry.
func (r repoResolution) reason(kitRoot string) string {
	switch r.RC {
	case 2:
		return "git not found on PATH — install git before resolving the kit issue repo"
	case 3:
		return "kit root (" + kitRoot + ") is not the git checkout's toplevel — git found an enclosing checkout rooted at " + r.Toplevel + " instead"
	case 4:
		return "invalid repo shape '" + r.BadValue + "' — expected [HOST/]OWNER/REPO"
	case 5:
		return "scp-style remote host '" + r.BadValue + "' is not a recognized github.com alias — an SSH config Host alias is indistinguishable from a real hostname without calling 'ssh -G', which this script never does; set RESEARCH_SDD_ISSUE_REPO=<owner>/<name> to resolve explicitly"
	}
	return "no RESEARCH_SDD_ISSUE_REPO override and no resolvable git remote 'origin' at " + kitRoot
}
