#!/usr/bin/env bash
# stage-retro-issues.sh — propose (or create with --apply) GitHub issues for OPEN
# kit deltas in ONE §18 retro file (issue #792; backlog-first rollout #557).
#
# An OPEN delta is one whose review-status is pending/none/absent, OR whose retro
# carries a PARTIAL applied marker and the row's ID is NOT in the shipped set.
# Shipped/applied/dismissed rows are skipped. propose-never-apply is the DEFAULT.
#
# Usage: stage-retro-issues.sh <retro.md> [--apply]
#   Default:  dry-run — print planned issues (title, labels, body) to stdout.
#   --apply:  run `gh issue create` for each open delta, with dedup check.
#
# Anti-silent-zero: four states are distinguished and named (kit issue #1111 added the 4th):
#   absent-input     retro file not found
#   empty-input      retro found but has no delta section AND no proposal-like heading at all
#   unclassifiable   a delta/canonical section (or a proposal-like heading, e.g. a hyphenated
#                     "kit-delta" mid-heading or a standalone "### Proposals") was found but
#                     is not in a form this parser can count/stage — needs manual review;
#                     never conflated with empty-input, which would silently hide it
#   no-match         delta section found; all rows shipped/applied
#
# §7 degraded probe: if --apply and `gh` is absent or not authenticated,
# emit a typed `degraded:` line to stderr and exit non-zero.
#
# Kit issue repo (kit issue #1037; hardened by #1045, then #1046 round 2):
# delta issues MUST land in the KIT repo, never whatever repo the process cwd
# happens to resolve to. Under the retro-gate.sh Stop hook, cwd is the TARGET
# directory (a foreign repo, or no repo at all) — an unqualified `gh issue
# list`/`gh issue create` would silently resolve the WRONG repo, or fail
# outright. Every gh call below carries an explicit --repo, resolved ONCE, in
# this order:
#   1. RESEARCH_SDD_ISSUE_REPO env override (owner/name) — wins unconditionally,
#      but is STILL shape-validated (F2) before use.
#   2. `git -C "$KIT_ROOT" remote get-url origin`, but ONLY when KIT_ROOT is
#      ITSELF the git checkout root (F1: physical `rev-parse --show-toplevel`
#      compared against KIT_ROOT) — never an enclosing repo that git's own
#      upward search happens to find when KIT_ROOT is not a checkout at all.
#      The URL is normalized (https, ssh://, scp-like git@host:owner/name AND
#      bare host:owner/name forms; trailing `/` stripped BEFORE the trailing
#      `.git` suffix — F3). A URL-scheme host (https://, ssh://) is KEPT as
#      `HOST/owner/repo` (gh accepts that form) UNLESS it is a `:port` suffix
#      or a github.com alias/prefix (`ssh.`/`www.`/`github.com-<anything>`,
#      kit issue #1046 round 2 items 1-2), in which case it is dropped like
#      plain github.com. An scp-like host ([user@]host:owner/repo) is ALWAYS
#      dropped: an SSH config Host alias is indistinguishable from a real
#      hostname without `ssh -G`, which this script never calls.
# The final value (override or derived) is validated against a tightened
# `[HOST/]OWNER/REPO` shape (F2, F4: each segment must START with an
# alphanumeric — this alone rejects `.`/`..` segments, a leading `-`, and any
# extra path component) — anything else (a bare word, a value with spaces,
# `owner/repo/extra/junk`, a `file://` URL that leaked through unnormalized,
# `../o/n`, `-o/n`, `o/..`, …) is unresolved, never passed to gh.
# Dry-run prints the resolved value as `kit-issue-repo: <owner>/<name>` or
# `kit-issue-repo: unresolved (<reason>)` — dry-run works either way, and the
# reason names what actually blocked resolution (missing git, an enclosing
# repo, an invalid shape, no override and no remote). --apply refuses (typed
# `degraded:` line naming the same reason, exit 1) BEFORE any gh call when the
# repo cannot be resolved — it never falls back to the cwd/target repo.
#
# Exit codes:
#   0   dry-run success, or --apply with 0 create failures
#   1   absent-input, degraded (missing gh / unauthenticated / unresolved kit issue
#       repo under --apply), or missing dependencies
#   2   --apply completed but one or more `gh issue create` calls failed (failed > 0)
#       Callers must treat exit 2 as a partial failure: the summary line carries
#       'failed=N' at the END of the summary so existing parsers remain unaffected.
#       A failed create whose issue a re-run dedup search then finds is NOT counted failed: it is
#       reported `unknown-outcome: …` and tallied in the `unknown-outcome=N` field just before failed=.

set -uo pipefail

# ---------------------------------------------------------------------------
# Arguments
retro="${1:-}"
apply=0
for _a in "$@"; do [ "$_a" = "--apply" ] && apply=1; done

# ---------------------------------------------------------------------------
# Runtime dependency probes
_missing=""
for _dep in awk grep sed; do
  command -v "$_dep" >/dev/null 2>&1 || _missing="$_missing $_dep"
done
if [ $apply -eq 1 ]; then
  if ! command -v gh >/dev/null 2>&1; then
    echo "degraded: gh not found on PATH — install gh CLI before using --apply" >&2
    exit 1
  fi
  if ! gh auth status >/dev/null 2>&1; then
    echo "degraded: gh is not authenticated — run 'gh auth login' before using --apply" >&2
    exit 1
  fi
fi
if [ -n "$_missing" ]; then
  echo "degraded: missing runtime dependencies:$_missing" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Validate retro path (absent-input)
if [ -z "$retro" ] || [ ! -f "$retro" ]; then
  echo "absent-input: retro not found: ${retro:-<no path given>}" >&2
  exit 1
fi
# STAGE_RETRO_ISSUES_UNREADABLE (R3-unreadable-silent-zero): exists but unreadable is not empty - typed.
if [ ! -r "$retro" ]; then
  echo "degraded: retro not readable: $retro" >&2
  exit 1
fi
retro="$(cd "$(dirname "$retro")" && pwd)/$(basename "$retro")"

# ---------------------------------------------------------------------------
# Kit layout — KIT_ROOT is two dirs up from toolbelt/ (the script's own dir).
# -P/pwd -P (PHYSICAL resolution) is required here, not the default -L logical mode: this script
# is invoked as $KIT/toolbelt/stage-retro-issues.sh where $KIT can be a per-profile RENDER dir
# whose toolbelt/ is a SYMLINK to the real kit's toolbelt/ (kit issue #993 WU2 install-time
# profile rendering + #1024 F1 render-dir completion). Bash's default (-L) $PWD tracking resolves
# ".." against the STRING it cd'd into, never spending the symlink component — so the second ".."
# here cancelled it out lexically and landed one level short of the real kit root, inside
# .../research-sdd/profile/ instead of .../research-sdd/ (kit issue #1024 round 3, MEDIUM;
# reproduced: TARGETS_MD pointed at a nonexistent path, so the per-retro target lookup silently
# fell back to a basename guess). -P forces the kernel's physical path at each step, so both cd's
# walk the REAL directory tree regardless of how many symlinks were traversed to invoke this
# script.
_SCRIPT_DIR="$(cd -P "$(dirname "$0")" && pwd -P)"
KIT_ROOT="$(cd -P "$_SCRIPT_DIR/../.." && pwd -P)"
TARGETS_MD="$KIT_ROOT/research-sdd/TARGETS.md"

# ---------------------------------------------------------------------------
# Kit issue repo resolution (kit issue #1037; hardened by #1045) — see header
# comment for the resolution order and the reason every gh call below must
# carry --repo.

# _KIT_ISSUE_REPO_SHAPE_RE (F2; tightened by kit issue #1046 round 2 item 4, then #1046
# round 2 (RDD) item c): the only shape ever handed to `gh --repo`. Every segment (the
# optional leading HOST, OWNER, REPO) must START with an alphanumeric — that single rule
# also rejects a bare `.`/`..` segment (both start with `.`) and a leading `-` (e.g. `-o/n`),
# with no separate check needed. The optional leading group is a non-github.com HOST (kept
# for GHE, F3); gh itself accepts `HOST/OWNER/REPO`.
#
# The leading HOST group MUST contain at least one literal dot (one or more `.label`
# continuations after the first label) — a real hostname is always a dotted FQDN in this
# context (GHE hosts like `ghe.corp.com`). Without this, a plain 3-segment value like
# `myorg/myrepo/subpath` (no host at all — an owner/repo typo with a stray extra path
# component, or a copy-pasted URL fragment) would be silently accepted as
# HOST=myorg/OWNER=myrepo/REPO=subpath instead of being rejected outright. Requiring a dot in
# the HOST position closes that: `myorg` has no dot, so the 3-segment form no longer matches
# with OR without the optional group, and the value is correctly unresolved.
# Anything else — a bare word, embedded whitespace, more than one extra path segment, a
# leaked URL scheme/colon — fails this and is unresolved, never passed to gh.
_KIT_ISSUE_REPO_SHAPE_RE='^([A-Za-z0-9][A-Za-z0-9-]*(\.[A-Za-z0-9-]+)+/)?[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*$'

# _validate_repo_shape <value>: returns 0 when <value> matches the
# "[HOST/]owner/repo" shape above, 1 otherwise. No output, no side effects.
_validate_repo_shape() {
  [[ "$1" =~ $_KIT_ISSUE_REPO_SHAPE_RE ]]
}

# _KIT_GITHUB_HOST_ALIAS_RE (kit issue #1046 round 2 item 1; tightened by the RDD follow-up
# item b): a host that IS github.com under a "www."/"ssh." prefix, or under an SSH config Host
# alias SUFFIX (e.g. "github.com-work", "github.com-personal"). These must still drop the
# host: gh needs the REAL "github.com", and an alias hostname does not resolve on its own
# ("Error connecting to github.com-alias").
#
# The alias suffix is `-[^./]*` — NO DOT ALLOWED — not the earlier `-[^/]*`. An SSH config
# Host alias is a single bare label a person chose locally (e.g. "-work", "-personal"); it is
# never itself a dotted subdomain. Without this restriction, `github.com-x.corp` and
# `github.com-evil.attacker.com` both matched as "github.com plus an alias suffix" and were
# silently treated as the real github.com — a spoofed or unrelated host wearing a
# `github.com-`-prefixed name would resolve to whatever repo an attacker chose. Excluding the
# dot means any host with FURTHER structure after the "github.com-" prefix is a genuinely
# DIFFERENT host and is KEPT verbatim by the caller (same as any other non-alias HOST/owner/repo
# — see `_normalize_git_remote_url`), never silently collapsed to bare "owner/repo".
_KIT_GITHUB_HOST_ALIAS_RE='^(ssh\.|www\.)?github\.com(-[^./]*)?$'

# _normalize_git_remote_url <url> (F3; hardened by kit issue #1046 round 2, then the RDD
# follow-up item a): prints the normalized "[HOST/]owner/repo" candidate for a git remote URL,
# OR the untrusted-scp sentinel (see below) for an scp-form remote whose host does not look like
# github.com. Handles:
#   https://github.com/o/n(.git)?(/)?     -> o/n            (github.com host dropped)
#   https://www.github.com/o/n.git        -> o/n            (alias prefix dropped)
#   https://github.com-work/o/n.git       -> o/n            (SSH-config alias host dropped)
#   https://github.com:443/o/n.git        -> o/n            (:port stripped, then alias-matched)
#   https://ghe.example.com/o/n.git       -> ghe.example.com/o/n  (real non-github HOST KEPT)
#   ssh://git@github.com/o/n.git          -> o/n
#   ssh://git@github.com:22/o/n.git       -> o/n            (:port stripped)
#   git@github.com:o/n(.git)?             -> o/n            (scp form, user@, github.com host)
#   github.com:o/n                        -> o/n            (scp form, NO user@, github.com host)
#   git@github.com-alias:o/n.git          -> o/n            (scp form, github.com ALIAS host)
#   git@ghe.corp.com:o/n.git              -> sentinel(ghe.corp.com)  (scp form, NON-github host)
#   work:o/n.git                          -> sentinel(work)          (scp form, NON-github host)
# The host is kept ONLY for a URL-SCHEME remote (https://, ssh://) whose host
# (after stripping a trailing :port) does not match _KIT_GITHUB_HOST_ALIAS_RE.
#
# An scp-like remote ([user@]host:owner/repo) drops its host ONLY when that host matches
# _KIT_GITHUB_HOST_ALIAS_RE (real github.com, or a github.com-* SSH config alias — RDD follow-up
# item a; previously EVERY scp-form host was dropped unconditionally). Any OTHER scp host is
# printed wrapped in the `_KIT_ISSUE_REPO_SCP_SENTINEL` marker instead of being silently kept as
# a bare "owner/repo" or silently dropped: an SSH config Host alias (e.g. a personal "work" alias
# pointing at some unrelated remote) is indistinguishable from a real hostname without resolving
# it via `ssh -G`, which this script never calls, so a non-github scp host is untrustworthy
# either way. The OLD behaviour (always drop) could silently construct a --repo value for the
# WRONG repository whenever a non-github scp host happened to be configured; the new behaviour
# fails CLOSED — resolve_kit_issue_repo() turns the sentinel into an unresolved reason that
# names the untrusted host and tells the caller to set RESEARCH_SDD_ISSUE_REPO explicitly.
# Trailing slash is stripped BEFORE the trailing .git suffix, so a URL like
# "o/n.git/" normalizes to "o/n", not the stray "o/n.git" a naive single-pass
# strip would leave behind. No shape validation here — callers run
# _validate_repo_shape on the result; an unrecognized scheme (e.g. file://) is
# returned unchanged and reliably fails that validation instead of being
# guessed at.
#
# _KIT_ISSUE_REPO_SCP_SENTINEL: prefix used to wrap an untrusted scp host so resolve_kit_issue_repo
# (the caller, NOT this function — see the _KIT_ISSUE_REPO_RESULT comment on why globals set
# inside a `$(...)` subshell are lost) can detect it and report a typed, host-naming reason
# instead of the generic "invalid repo shape" message. Never matches _KIT_ISSUE_REPO_SHAPE_RE
# (no '/'), so even if a caller forgot to check for it, the value would fail shape validation
# and stay unresolved rather than being passed to gh — belt AND suspenders.
_KIT_ISSUE_REPO_SCP_SENTINEL='__kit_issue_repo_untrusted_scp_host__'
_normalize_git_remote_url() {
  local url="$1" host rest is_url_scheme
  if [[ "$url" =~ ^(https?|ssh)://([^/@[:space:]]+@)?([^/]+)/(.+)$ ]]; then
    host="${BASH_REMATCH[3]}"
    rest="${BASH_REMATCH[4]}"
    is_url_scheme=1
  elif [[ "$url" =~ ^([^/@:[:space:]]+@)?([^/@:[:space:]]+):([^/].*)$ ]]; then
    # The "next char after ':' is not '/'" guard is what git itself uses to
    # disambiguate scp-like syntax from a URL scheme: without it, an
    # unrecognized scheme like "file:///srv/git/n.git" would mis-parse its
    # own scheme name ("file") as an scp host. Falling through to `else`
    # instead leaves it unchanged, which then reliably fails shape validation.
    host="${BASH_REMATCH[2]}"
    rest="${BASH_REMATCH[3]}"
    is_url_scheme=0
  else
    printf '%s' "$url"
    return 0
  fi
  # STAGE_RETRO_ISSUES_HOST_PORT_STRIP (kit issue #1046 round 2 item 2): a
  # URL-scheme host may carry ":port" (e.g. "github.com:22"); strip it before
  # the alias check below, or a ported github.com host would be wrongly KEPT
  # (and then fail shape validation, since ':' is not a legal host character).
  host="${host%%:*}"
  rest="${rest%/}"
  rest="${rest%.git}"
  rest="${rest%/}"
  if [ "$is_url_scheme" -eq 1 ]; then
    # STAGE_RETRO_ISSUES_HOST_ALIAS_CHECK (kit issue #1046 round 2 item 1): a
    # github.com alias/prefix host is dropped exactly like plain github.com;
    # any other URL-scheme host (a real GHE hostname) is kept.
    if [[ "$(printf '%s' "$host" | tr 'A-Z' 'a-z')" =~ $_KIT_GITHUB_HOST_ALIAS_RE ]]; then
      printf '%s' "$rest"
    else
      printf '%s/%s' "$host" "$rest"
    fi
  else
    # STAGE_RETRO_ISSUES_SCP_HOST_DROP (RDD follow-up item a): scp form drops its host ONLY
    # when it matches the github.com alias pattern — see the docstring above for why any OTHER
    # scp host is wrapped in the sentinel (fail closed) rather than dropped unconditionally.
    if [[ "$(printf '%s' "$host" | tr 'A-Z' 'a-z')" =~ $_KIT_GITHUB_HOST_ALIAS_RE ]]; then
      printf '%s' "$rest"
    else
      printf '%s%s' "$_KIT_ISSUE_REPO_SCP_SENTINEL" "$host"
    fi
  fi
}

# Set by resolve_kit_issue_repo() only on a shape-validation failure (F2), so
# callers can name the exact offending value in their degraded/unresolved
# message without re-deriving it.
_KIT_ISSUE_REPO_BAD_VALUE=""
# Set by resolve_kit_issue_repo() only on an F1 toplevel mismatch (return 3),
# so callers can name the ENCLOSING checkout's real root (kit issue #1046
# round 2 item 5 — the reason text must say what was actually found).
_KIT_ISSUE_REPO_TOPLEVEL=""
# The resolved value (kit issue #1046 round 2 item 3): resolve_kit_issue_repo()
# is called DIRECTLY below, never through `$(...)`. A command-substitution
# subshell would silently discard every global assignment made inside the
# function — which is exactly how _KIT_ISSUE_REPO_BAD_VALUE went missing
# before (the degraded/unresolved message always read "invalid repo shape
# ''", because the assignment lived only in the subshell that printed the
# function's stdout and vanished the instant that subshell exited).
_KIT_ISSUE_REPO_RESULT=""

# resolve_kit_issue_repo: sets _KIT_ISSUE_REPO_RESULT to "[HOST/]owner/name"
# and returns 0 on success. On failure _KIT_ISSUE_REPO_RESULT is empty and the
# return code is a TYPED reason so callers can report WHY, not just that it
# failed (anti-silent-zero, §7):
#   1  no override and no resolvable git remote (or empty remote URL)
#   2  git is not on PATH
#   3  F1: KIT_ROOT is not the git checkout's toplevel — git found an
#      ENCLOSING checkout instead (_KIT_ISSUE_REPO_TOPLEVEL names its root);
#      never used
#   4  F2: the override or derived value does not match the required shape
#      (_KIT_ISSUE_REPO_BAD_VALUE names the offending value)
#   5  the git remote is an scp-style URL whose host is NOT a recognized
#      github.com alias — untrustworthy either way without `ssh -G` (RDD
#      follow-up item a; _KIT_ISSUE_REPO_BAD_VALUE names the untrusted host)
# MUST be called directly — never as `KIT_ISSUE_REPO="$(resolve_kit_issue_repo)"`
# — see the _KIT_ISSUE_REPO_RESULT comment above. Never exits the process.
resolve_kit_issue_repo() {
  _KIT_ISSUE_REPO_RESULT=""
  _KIT_ISSUE_REPO_BAD_VALUE=""
  _KIT_ISSUE_REPO_TOPLEVEL=""
  if [ -n "${RESEARCH_SDD_ISSUE_REPO:-}" ]; then
    if _validate_repo_shape "$RESEARCH_SDD_ISSUE_REPO"; then
      _KIT_ISSUE_REPO_RESULT="$RESEARCH_SDD_ISSUE_REPO"
      return 0
    fi
    _KIT_ISSUE_REPO_BAD_VALUE="$RESEARCH_SDD_ISSUE_REPO"
    return 4
  fi
  command -v git >/dev/null 2>&1 || return 2
  local _top _top_phys _kit_phys _url _repo
  _top="$(git -C "$KIT_ROOT" rev-parse --show-toplevel 2>/dev/null)" || return 1
  [ -n "$_top" ] || return 1
  # STAGE_RETRO_ISSUES_F1_TOPLEVEL_CHECK (kit issue #1045 F1): KIT_ROOT must BE
  # the checkout root, physically — never an enclosing repo that git's own
  # upward remote search happens to find when KIT_ROOT holds no .git of its own.
  _top_phys="$(cd -P "$_top" 2>/dev/null && pwd -P)" || return 1
  _kit_phys="$(cd -P "$KIT_ROOT" 2>/dev/null && pwd -P)" || return 1
  if [ "$_top_phys" != "$_kit_phys" ]; then
    _KIT_ISSUE_REPO_TOPLEVEL="$_top_phys"
    return 3
  fi
  _url="$(git -C "$KIT_ROOT" remote get-url origin 2>/dev/null)" || return 1
  [ -n "$_url" ] || return 1
  _repo="$(_normalize_git_remote_url "$_url")"
  # STAGE_RETRO_ISSUES_SCP_SENTINEL_CHECK (RDD follow-up item a): an untrusted scp host comes
  # back wrapped in the sentinel — detect it BEFORE shape validation (it would fail shape
  # validation anyway, since it has no '/', but this gives a typed, host-naming reason instead
  # of the generic "invalid repo shape" message).
  if [[ "$_repo" == "${_KIT_ISSUE_REPO_SCP_SENTINEL}"* ]]; then
    _KIT_ISSUE_REPO_BAD_VALUE="${_repo#"$_KIT_ISSUE_REPO_SCP_SENTINEL"}"
    return 5
  fi
  # STAGE_RETRO_ISSUES_F2_SHAPE_CHECK (kit issue #1045 F2): the derived value
  # must also match the required shape — a URL scheme/host our normalizer
  # doesn't recognize (e.g. file://) must not pass through to gh unchecked.
  if ! _validate_repo_shape "$_repo"; then
    _KIT_ISSUE_REPO_BAD_VALUE="$_repo"
    return 4
  fi
  _KIT_ISSUE_REPO_RESULT="$_repo"
  return 0
}

resolve_kit_issue_repo
_kit_issue_repo_rc=$?
KIT_ISSUE_REPO="$_KIT_ISSUE_REPO_RESULT"

_kit_issue_repo_reason=""
if [ -z "$KIT_ISSUE_REPO" ]; then
  case "$_kit_issue_repo_rc" in
    2) _kit_issue_repo_reason="git not found on PATH — install git before resolving the kit issue repo" ;;
    3) _kit_issue_repo_reason="kit root ($KIT_ROOT) is not the git checkout's toplevel — git found an enclosing checkout rooted at ${_KIT_ISSUE_REPO_TOPLEVEL} instead" ;;
    4) _kit_issue_repo_reason="invalid repo shape '${_KIT_ISSUE_REPO_BAD_VALUE}' — expected [HOST/]OWNER/REPO" ;;
    5) _kit_issue_repo_reason="scp-style remote host '${_KIT_ISSUE_REPO_BAD_VALUE}' is not a recognized github.com alias — an SSH config Host alias is indistinguishable from a real hostname without calling 'ssh -G', which this script never does; set RESEARCH_SDD_ISSUE_REPO=<owner>/<name> to resolve explicitly" ;;
    *) _kit_issue_repo_reason="no RESEARCH_SDD_ISSUE_REPO override and no resolvable git remote 'origin' at $KIT_ROOT" ;;
  esac
fi

# STAGE_RETRO_ISSUES_REPO_GUARD: anchor for T9 teeth proof — refuses to create
# against an unresolved kit issue repo rather than falling back to the cwd's repo.
if [ $apply -eq 1 ] && [ -z "$KIT_ISSUE_REPO" ]; then
  echo "degraded: cannot resolve kit issue repo ($_kit_issue_repo_reason) — set RESEARCH_SDD_ISSUE_REPO=<owner>/<name>, or configure a git remote 'origin' at $KIT_ROOT — refusing to create issues against an unresolved/foreign repo" >&2
  exit 1
fi
if [ $apply -eq 0 ]; then
  if [ -n "$KIT_ISSUE_REPO" ]; then
    printf 'kit-issue-repo: %s\n' "$KIT_ISSUE_REPO"
  else
    printf 'kit-issue-repo: unresolved (%s)\n' "$_kit_issue_repo_reason"
  fi
fi

# ---------------------------------------------------------------------------
# Source shared helpers (fail-closed)
_RS_LIB="$_SCRIPT_DIR/lib/retro-status.sh"
if [ ! -f "$_RS_LIB" ]; then
  echo "stage-retro-issues: cannot find helper $_RS_LIB" >&2; exit 1
fi
# shellcheck source=lib/retro-status.sh
. "$_RS_LIB"
declare -F retro_marker_scope_line >/dev/null 2>&1 \
  || { echo "stage-retro-issues: helper lib/retro-status.sh failed to define retro_marker_scope_line" >&2; exit 1; }
declare -F retro_status_from_marker_line >/dev/null 2>&1 \
  || { echo "stage-retro-issues: helper lib/retro-status.sh failed to define retro_status_from_marker_line" >&2; exit 1; }
declare -F retro_marker_is_partial >/dev/null 2>&1 \
  || { echo "stage-retro-issues: helper lib/retro-status.sh failed to define retro_marker_is_partial" >&2; exit 1; }
declare -F retro_marker_shipped_ids >/dev/null 2>&1 \
  || { echo "stage-retro-issues: helper lib/retro-status.sh failed to define retro_marker_shipped_ids" >&2; exit 1; }
declare -F retro_marker_out_of_scope >/dev/null 2>&1 \
  || { echo "stage-retro-issues: helper lib/retro-status.sh failed to define retro_marker_out_of_scope" >&2; exit 1; }

_RG_LIB="$_SCRIPT_DIR/lib/retro-grammar.sh"
if [ ! -f "$_RG_LIB" ]; then
  echo "stage-retro-issues: cannot find helper $_RG_LIB" >&2; exit 1
fi
# shellcheck source=lib/retro-grammar.sh
. "$_RG_LIB"
declare -F retro_grammar_delta_info >/dev/null 2>&1 \
  || { echo "stage-retro-issues: helper lib/retro-grammar.sh failed to define retro_grammar_delta_info" >&2; exit 1; }
declare -F retro_grammar_has_honesty >/dev/null 2>&1 \
  || { echo "stage-retro-issues: helper lib/retro-grammar.sh failed to define retro_grammar_has_honesty" >&2; exit 1; }
declare -F retro_grammar_entry_rows >/dev/null 2>&1 \
  || { echo "stage-retro-issues: helper lib/retro-grammar.sh failed to define retro_grammar_entry_rows" >&2; exit 1; }
declare -F retro_grammar_entry_warn >/dev/null 2>&1 \
  || { echo "stage-retro-issues: helper lib/retro-grammar.sh failed to define retro_grammar_entry_warn" >&2; exit 1; }
declare -F retro_grammar_defenced >/dev/null 2>&1 \
  || { echo "stage-retro-issues: helper lib/retro-grammar.sh failed to define retro_grammar_defenced" >&2; exit 1; }

# STAGE_RETRO_ISSUES_LIST_LIMIT (kit issue #1369 c): every dedup `gh issue list` carries an explicit
# --limit (gh's own default is 30, which silently truncated a busy repo). 1000 is GitHub search's
# practical ceiling; the env override exists so a test can fill a page without 1000 fixtures. A reply
# that FILLS the limit may be truncated, so it is a typed failure, never "no match" (see _list_filled).
_LIST_LIMIT="${STAGE_RETRO_ISSUES_LIST_LIMIT:-1000}"
case "$_LIST_LIMIT" in
  ''|*[!0-9]*|0) echo "degraded: STAGE_RETRO_ISSUES_LIST_LIMIT must be a positive integer (got '$_LIST_LIMIT')" >&2; exit 1 ;;
esac

_TP_LIB="$_SCRIPT_DIR/lib/target-paths.sh"
if [ ! -f "$_TP_LIB" ]; then
  echo "stage-retro-issues: cannot find helper $_TP_LIB" >&2; exit 1
fi
# shellcheck source=lib/target-paths.sh
. "$_TP_LIB"
declare -F target_paths_pairs >/dev/null 2>&1 \
  || { echo "stage-retro-issues: helper lib/target-paths.sh failed to define target_paths_pairs" >&2; exit 1; }
declare -F target_name_for_retro >/dev/null 2>&1 \
  || { echo "stage-retro-issues: helper lib/target-paths.sh failed to define target_name_for_retro" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Derive target name from the retro's directory hierarchy (kit issues #1169, #1287).
# The walk-up + name lookup lives in lib/target-paths.sh (target_name_for_retro) so that this
# writer, reconcile-issues.sh and stage-retro.sh cannot drift apart: the `Source retro:` signature
# stamped below is the one reconcile searches for. It takes the NEAREST registered ancestor
# (flat <target>/retros, nested <target>/corpus/retros, deeper <target>/<sub>/retros) and returns
# the registered Target NAME (row cell 2, what the `target:<name>` labels are named after).
#   rc 1 -> operational failure (TARGETS.md absent/unreadable/zero rows): exit 1, never a guess
#   rc 2 -> TARGETS.md fine but no ancestor registered: legacy WARN + basename fallback for the
#           flat layout; a structural dir (corpus|retros) is refused up front.
_retro_dir="$(cd "$(dirname "$retro")" && pwd)"
_target_dir="$(cd "$(dirname "$_retro_dir")" && pwd)"   # legacy flat-layout guess (fallback + legacy dedup signature)
target_name="$(target_name_for_retro "$TARGETS_MD" "$retro")"
_tnr_rc=$?
if [ "$_tnr_rc" -eq 1 ]; then
  echo "stage-retro-issues: cannot resolve target for '$retro' — operational failure reading $TARGETS_MD (see message above)" >&2
  exit 1
fi

_target_registered=1
if [ "$_tnr_rc" -ne 0 ] || [ -z "$target_name" ]; then
  target_name="$(basename "$_target_dir")"
  # A structural directory name is never a registered target label: fail up front rather than
  # plan issues whose `target:<name>` label cannot exist (anti-silent-zero).
  case "$target_name" in
    corpus|retros)
      echo "stage-retro-issues: cannot resolve target for '$retro' — no ancestor directory is registered in $TARGETS_MD (basename '$target_name' is a structural directory, not a target)" >&2
      exit 1 ;;
  esac
  _target_registered=0
  echo "WARN: target directory '$_target_dir' not found in $TARGETS_MD — using basename '$target_name'" >&2
fi
# Pre-#1286 issues carry the legacy `<path basename>/retros/<file>` signature; remember it so the
# --apply dedup can search it too when the registered name differs from the basename (#1287).
_legacy_target_name="$(basename "$_target_dir")"
# A structural old name (<t>/corpus/retros -> `corpus`) never matched a real signature — the old code
# refused it up front — so a lookup for it is a pointless gh call. Treat it as "no legacy name".
case "$_legacy_target_name" in
  corpus|retros) _legacy_target_name="$target_name" ;;
esac

# ---------------------------------------------------------------------------
# Parse review-status and detect PARTIAL applied markers.
# STAGE_RETRO_ISSUES_SCOPE_SHARED (kit issue #945): retro_marker_scope_line (lib/retro-status.sh)
# is the ONE marker scope reconcile-issues.sh, stage-retro-issues.sh (this script), retro-gate.sh,
# and sweep-retros.sh now share — the leading block, tolerating exactly one H1 line at the top
# (real-corpus layout: H1 line 1, blank line 2, marker line 3 in *-closure.md retros). Both the
# status word and the PARTIAL/shipped inspection are derived from this one call.
# Format: <!-- review-status: applied · sha · PARTIAL — shipped: 1, 2; deferred: 3 -->
#
# Before #945 this script used retro_marker_line's WHOLE-FILE scan, which is MORE permissive
# than the shared scope: a marker anywhere in the retro body — after a second heading, or even
# quoted inside a fenced example — would gate the seeder. That over-permissiveness disagreed
# with reconcile-issues.sh and sweep-retros.sh, which only ever honored the leading block; #945
# unifies all four on retro_marker_scope_line instead.
_marker_line="$(retro_marker_scope_line "$retro")"

# STAGE_RETRO_ISSUES_OUT_OF_SCOPE_GUARD (kit issue #1099): an empty scope-scan result does NOT
# necessarily mean "no marker" — a whole-file scan may still find one outside the leading-block
# scope (YAML frontmatter, a multi-line comment run before it, a marker after a second heading,
# a BOM the scope-scan no longer trips over but an even earlier obstruction still does, …).
# Conflating that with "genuinely absent" was the #1048-#1089 fail-open shape: status read as ""
# (pending/open), so every row was seeded. Fail CLOSED instead: refuse to seed and say why.
if [ -z "$_marker_line" ] && retro_marker_out_of_scope "$retro"; then
  echo "out-of-scope-marker: a review-status marker exists but sits outside the leading-block scope in $(basename "$retro") — refusing to seed (kit issue #1099); move the marker into the leading block" >&2
  exit 0
fi

# Extract the status word via retro_status_from_marker_line (lib/retro-status.sh).
# R2-001: this is the SINGLE extraction point — the pipeline lives only in that lib function.
# If no marker was found, status is empty (treated as pending/open below).
status="$(retro_status_from_marker_line "$_marker_line")"

is_partial=0
shipped_ids=""
# STAGE_RETRO_ISSUES_PARTIAL_CHECK (kit issue #1090): PARTIAL is a STATUS TOKEN, detected only
# in the marker's STRUCTURED segment (before the first free-text separator) via the shared
# retro_marker_is_partial helper — never a case-insensitive whole-line grep, which let prose
# like "(P1 partial)" false-positive. 'shipped:' is still extracted separately below, but only
# when the structured PARTIAL token was actually found.
if retro_marker_is_partial "$_marker_line"; then
  is_partial=1
  _shipped_raw="$(printf '%s' "$_marker_line" \
    | grep -oiE 'shipped:[^;>]*' \
    | head -1 \
    | sed -E 's/^[Ss]hipped:[[:space:]]*//')"
  if [ -n "$_shipped_raw" ]; then
    shipped_ids="$(retro_marker_shipped_ids "$_shipped_raw")"
  fi
fi

# ---------------------------------------------------------------------------
# Early exit for fully applied/dismissed with no PARTIAL marker (no-match)
# STAGE_RETRO_ISSUES_NOMATCH_GUARD: this single compound statement is the anchor
# for the T1 teeth proof — removing it causes rows to be emitted for applied retros.
# STAGE_RETRO_ISSUES_DISMISSED_WINS (kit issue #1090): 'dismissed' ALWAYS means zero open
# rows — it never falls through to the is_partial check the way 'applied' does. A dismissed
# retro's shipped-work explanation lives in free text the PARTIAL detector already ignores, but
# this is a second, independent guard: even a structured PARTIAL token on a dismissed marker
# (which should never happen, but must not be trusted blindly) cannot reopen its rows.
case "$status" in
  dismissed)
    echo "no-match: retro is 'dismissed' — all rows shipped" >&2; exit 0
    ;;
  applied)
    [ $is_partial -eq 0 ] && { echo "no-match: retro is 'applied' — all rows shipped" >&2; exit 0; }
    ;;
  pending|none|"")
    : ;;  # All rows open
  *)
    echo "WARN: unrecognised review-status '$status' — treating all rows as open" >&2 ;;
esac

# ---------------------------------------------------------------------------
# Check for a delta section (empty-input vs unclassifiable — kit issue #1111)
_grammar_info="$(retro_grammar_delta_info "$retro")"
_found_field="$(printf '%s' "$_grammar_info" | cut -d '' -f1 | cut -d: -f1)"
if [ "$_found_field" != "1" ]; then
  # unrec_found (field 3 of retro_grammar_delta_info's \001-separated output): the shared
  # grammar's own unrecognised-delta-intent-heading detector (Rules 1-4). A retro whose
  # only proposal-like heading the parser cannot classify (e.g. a hyphenated "kit-delta"
  # mid-heading, or a standalone "### Proposals") must never be reported as a confident
  # empty-input — that silently hides real proposals from the backlog. Report it typed
  # instead: unclassifiable, needs manual review, no auto-staged issue.
  _temp_depr="${_grammar_info#*$'\001'}"
  _temp_unrec="${_temp_depr#*$'\001'}"
  _unrec_found="${_temp_unrec%%$'\001'*}"
  if [ "$_unrec_found" = "1" ]; then
    echo "unclassifiable: proposal-like heading found but not in a countable delta form in $retro — needs manual review, no issue auto-staged" >&2
  else
    echo "empty-input: no delta section found in $retro" >&2
  fi
  unset _temp_depr _temp_unrec _unrec_found
  exit 0
fi

# ---------------------------------------------------------------------------
# Parse delta rows from the canonical/deprecated section
retro_file="$retro"
retro_basename="$(basename "$retro")"

_rows="$(_RG_QUIET_FENCE=1 retro_grammar_defenced "$retro_file" | awk '
  BEGIN { in_sec=0 }
  {
    low = tolower($0)
    if (low ~ /^## ([0-9]+\. )?proposed kit delta[s]?([[:space:]]|$)/ ||
        low ~ /^## proposed delta/ ||
        low ~ /^## delta proposals/ ||
        low ~ /^## deltas nuevos/ ||
        low ~ /^## propuesta de deltas al kit([[:space:]]|$)/ ||
        low ~ /^## summary of proposed delta/ ||
        low ~ /^## summary of new deltas/ ||
        low ~ /^## delta details([[:space:]]|$)/) {
      in_sec = 1; prev = ""; ct = 0; next
    }
    if (/^##[^#]/) { in_sec = 0; next }
    # STAGE_RETRO_ISSUES_HEADER_MAP (kit issue #1260): the row directly above a table separator is
    # that table'"'"'s HEADER. Its cells are mapped by NAME to the title/target/evidence/type/priority
    # roles; a header naming no title column leaves ct = 0 = the old positional reading (cells 2..6).
    if (in_sec && /^\|[-: |]+\|?[[:space:]]*$/) {
      if (prev != "") {
        hl = tolower(prev)
        sub(/^\|[[:space:]]*/, "", hl); sub(/[[:space:]]*\|[[:space:]]*$/, "", hl)
        hn = split(hl, h, /[[:space:]]*\|[[:space:]]*/)
        ct = cg = ce = cy = cp = 0
        for (k = 2; k <= hn; k++) {
          if (!ct && h[k] ~ /^(proposed change|proposed delta|proposal|title|delta|gist|change|rule \/ change|delta propuesto)/) ct = k
          else if (!cg && h[k] ~ /(target|kit file)/) cg = k
          else if (!ce && h[k] ~ /^(evidence|why$)/) ce = k
          else if (!cy && h[k] ~ /^type/) cy = k
          else if (!cp && h[k] ~ /^(priority|prioridad)/) cp = k
        }
        if (!ct) cg = ce = cy = cp = 0
        else {
          # Per role: a header-name match wins, else the role keeps its POSITIONAL column (3..6) when the
          # header has that cell and no other role claimed it (a partly-named header is not a regression).
          used[ct] = 1
          if (cg) used[cg] = 1
          if (ce) used[ce] = 1
          if (cy) used[cy] = 1
          if (cp) used[cp] = 1
          if (!cg && 3 <= hn && !used[3]) { cg = 3; used[3] = 1 }
          if (!ce && 4 <= hn && !used[4]) { ce = 4; used[4] = 1 }
          if (!cy && 5 <= hn && !used[5]) { cy = 5; used[5] = 1 }
          if (!cp && 6 <= hn && !used[6]) { cp = 6; used[6] = 1 }
          for (k in used) delete used[k]
        }
      }
      prev = ""; next
    }
    if (in_sec && /^\|/) {
      prev = $0
      line = $0
      sub(/^\|[[:space:]]*/, "", line)
      sub(/[[:space:]]*\|[[:space:]]*$/, "", line)
      n = split(line, f, /[[:space:]]*\|[[:space:]]*/)
      rid = f[1]; gsub(/[[:space:]]/, "", rid)
      if (rid ~ /^[-:]+$/) next
      if (rid ~ /^[[:alpha:]#][^0-9]*$/ && rid !~ /^[A-Z][0-9]/) next
      if (ct) {
        printf "%s\037%s\037%s\037%s\037%s\037%s\n", f[1], f[ct],
          (cg ? f[cg] : ""), (ce ? f[ce] : ""), (cy ? f[cy] : ""), (cp ? f[cp] : "")
      } else {
        printf "%s\037%s\037%s\037%s\037%s\037%s\n",
          (n>=1 ? f[1] : ""), (n>=2 ? f[2] : ""), (n>=3 ? f[3] : ""),
          (n>=4 ? f[4] : ""), (n>=5 ? f[5] : ""), (n>=6 ? f[6] : "")
      }
    }
  }
')"

# STAGE_RETRO_ISSUES_ENTRY_FORM (kit issue #1332 N1): no table rows -> the doctrine-valid
# `### D<N> —` entry form. retro_grammar_entry_rows (the shared grammar lib — the parser
# reconcile-issues.sh takes its IDs from) yields records in the table-row shape, so the loop below
# is unchanged and the issue signature carries the same `· D<N>` row id reconcile matches.
if [ -z "$_rows" ]; then
  _rows="$(retro_grammar_entry_rows "$retro_file")"
  # STAGE_RETRO_ISSUES_ENTRY_GAP_WARN (kit issue #1332 N6): entries whose heading token is not a usable ID.
  [ -z "$_rows" ] || retro_grammar_entry_warn "$retro_file" >&2
fi

if [ -z "$_rows" ]; then
  # kit issue #1129 finding 2: check for an HONEST §18 zero FIRST. A canonical section whose
  # only body content is the accepted honesty phrase (retro_grammar_has_honesty — the same
  # fail-safe purity check sweep-retros.sh's WARN-A path already uses) has genuinely nothing to
  # count: it is a correct declared zero, not an ambiguous non-table-row shape. Real fleet
  # counterexample: niagara-research/retros/2026-09-17-tools-search-innovation.md (a
  # header+separator-only table followed by the bare honesty line) was misreported
  # "unclassifiable — needs manual review" before this check.
  if retro_grammar_has_honesty "$retro"; then
    echo "empty-input: delta section found but contains no data rows (honest §18 zero) in $retro" >&2
    exit 0
  fi
  # A canonical/deprecated section WAS found — this is not "empty" (kit issue #1111): the
  # section exists but is not in the table-row form this parser can auto-stage issues from
  # (e.g. numbered-list entries under ### sub-headings, per the Spanish-alias real fleet
  # form), and it is not a declared honest zero either. Typed distinctly from the found=0
  # empty-input case above.
  echo "unclassifiable: delta section found but contains neither row-table rows nor '### D<N> —' entries in $retro — needs manual review, no issue auto-staged" >&2
  exit 0
fi

# ---------------------------------------------------------------------------
# Helpers

# is_shipped <row_id>: true when ID is in the shipped set of a PARTIAL marker
is_shipped() {
  [ $is_partial -eq 1 ] || return 1
  grep -qxF "$1" <<<"$shipped_ids"
}

# map_type <type_cell>: prints "feature" | "bug" | "docs"
map_type() {
  local t
  t="$(printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -d '[:space:]')"
  case "$t" in
    doc|docs|documentation|doc-fix|docfix) printf 'docs' ;;
    bug|fix|bugfix|defect|regression)      printf 'bug'  ;;
    *)                                      printf 'feature' ;;
  esac
}

# map_priority <priority_cell>: prints "high"|"medium"|"low" or "" to omit
map_priority() {
  local p
  p="$(printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -d '[:space:]')"
  case "$p" in
    high)   printf 'high'   ;;
    medium) printf 'medium' ;;
    low)    printf 'low'    ;;
    *)      printf ''       ;;
  esac
}

# is_wrong_kit <target_cell>: true if the cell names another kit
# STAGE_RETRO_ISSUES_WRONGKIT_GUARD: this is the anchor for T2 teeth proof.
is_wrong_kit() {
  grep -qiE '[-a-zA-Z0-9]+-kit[:/]' <<<"$1"
}

# strip_md_bold: if the cell opens with a bold lead-in (**phrase**), return just
# the bolded phrase as the title (the author's own one-line summary).  Otherwise
# fall back to stripping surrounding ** markers.
# STAGE_RETRO_ISSUES_BOLD_LEAD: this sed branch is the T4 teeth anchor; replacing
# it with the old s/^\*\*// expression re-introduces the stray-** bug.
strip_md_bold() {
  printf '%s' "$1" | sed -E 's/^\*\*([^*]+)\*\*.*/\1/;t;s/^\*\*//;s/\*\*$//'
}

# _exact_sig_matches <signature>   (reads a `gh issue list --json state,body` reply on stdin)
#   Kit issue #1304 item 1. GitHub's search is a fuzzy WORD match: searching the phrase
#   "Source retro: research/retros/f.md · 3" also returned a different target's issue
#   (niagara-research) and an issue for row 30 when asked for row 3, so "the search returned
#   something" is NOT "this row already has an issue" — treating it so skipped genuinely new rows
#   (a silent loss, the opposite direction of a duplicate). This keeps only the issues whose BODY
#   carries the signature as one WHOLE LINE (the seeder stamps it on its own line), after trimming
#   trailing whitespace/CR, and prints the kept issues as a compact array of {"state":"…"} objects
#   so the OPEN/CLOSED checks downstream read it exactly like a plain state-only reply.
#   Pure awk (no jq dependency, no gawk extension): a small JSON reader that tracks strings,
#   escapes and brace depth, so a '},{' or a quoted '"state":"OPEN"' INSIDE a body can never be
#   mistaken for structure. Exit 3 (and no output) on a reply it cannot parse to the end (an
#   unterminated string, unbalanced brackets) — the caller counts that as a failed lookup, never as
#   "no match". STAGE_RETRO_ISSUES_EXACT_SIG: anchor for the exact-match teeth proofs.
_exact_sig_matches() {
  _XSIG="$1" awk '
    function hexval(h,   k, v, d) {
      v = 0
      for (k = 1; k <= length(h); k++) {
        d = index("0123456789abcdef", tolower(substr(h, k, 1)))
        if (d == 0) return -1
        v = v * 16 + d - 1
      }
      return v
    }
    function process_object(   nl, lines, j, ln, hit) {
      hit = 0
      nl = split(body, lines, "\n")
      for (j = 1; j <= nl; j++) {
        ln = lines[j]
        sub(/[ \t\r]+$/, "", ln)
        if (ln == sig) { hit = 1; break }   # STAGE_RETRO_ISSUES_EXACT_SIG_EQ
      }
      ntotal++
      if (hit) { out = out (nout++ ? "," : "") "{\"state\":\"" state "\"}" }
    }
    BEGIN { sig = ENVIRON["_XSIG"]; depth = 0; vmode = 0; nout = 0; ntotal = 0; out = ""; s = "" }
    { s = s $0 "\n" }
    END {
      n = length(s); i = 1
      while (i <= n) {
        c = substr(s, i, 1)
        if (c == "\"") {
          str = ""; i++; closed = 0
          while (i <= n) {
            c = substr(s, i, 1)
            if (c == "\\") {
              e = substr(s, i + 1, 1)
              if (e == "n") str = str "\n"
              else if (e == "r") str = str "\r"
              else if (e == "t") str = str "\t"
              else if (e == "u") {
                cp = hexval(substr(s, i + 2, 4))
                if (cp >= 0 && cp < 128) str = str sprintf("%c", cp)
                else if (cp == 183) str = str "·"
                else str = str "?"
                i += 4
              } else str = str e
              i += 2; continue
            }
            if (c == "\"") { closed = 1; break }
            str = str c; i++
          }
          if (!closed) exit 3
          i++
          if (depth == 2) {
            if (vmode) {
              if (key == "body") body = str
              else if (key == "state") state = str
              vmode = 0
            } else key = str
          }
          continue
        }
        if (c == "{" || c == "[") { depth++; if (c == "{" && depth == 2) { body = ""; state = ""; key = ""; vmode = 0 } }
        else if (c == "}" || c == "]") {
          if (c == "}" && depth == 2) process_object()
          depth--
          if (depth < 0) exit 3
        }
        else if (c == ":" && depth == 2) vmode = 1
        else if (c == "," && depth == 2) vmode = 0
        i++
      }
      if (depth != 0) exit 3
      printf "[%s]\n", out
      printf "total=%d\n", ntotal      # STAGE_RETRO_ISSUES_TOTAL_LINE: how many issues the reply held (see _list_filled)
    }
  '
}

# _list_filled <reply-from-_exact_sig_matches>: true when the reply held >= the --limit issues. Such a
# reply may have been cut off by the limit, so "no exact match in it" proves nothing. An output with
# no `total=` line is not a trustworthy reading either: treated as filled (fail closed).
_list_filled() {
  local _t
  _t="$(printf '%s\n' "$1" | sed -n 's/^total=\([0-9][0-9]*\)$/\1/p' | head -n 1)"
  [ -n "$_t" ] || return 0
  [ "$_t" -ge "$_LIST_LIMIT" ]    # STAGE_RETRO_ISSUES_LIST_FILLED
}

# ---------------------------------------------------------------------------
# STAGE_RETRO_ISSUES_LABEL_PROBE (kit issue #1332 item 1): every issue is created with a
# `target:<name>` label, and `gh issue create` REJECTS a label that does not exist on the repo.
# A registered target whose label was never created therefore failed once PER ROW (N identical
# errors, failed=N). Probe it ONCE, lazily right before the first create:
#   exists  -> proceed
#   missing -> create it with the fleet convention (description `Fleet target: <name>`, color
#              d4c5f9 — the shape of every existing target:* label), then proceed
#   probe/create failure, or an unusable probe reply -> ONE typed `degraded:` line, exit 1,
#              before any issue create (an instrument that cannot tell whether the label exists
#              must not guess it does — anti-silent-zero, CLAUDE.md §7).
# `gh label list --search` is a fuzzy word match, so the reply is checked for the EXACT name.
_label_ready=0
# _label_present <name>: 0 = present, 1 = absent; a probe that cannot answer exits degraded (the
# caller never guesses). Names compare CASE-INSENSITIVELY — GitHub label names are (kit issue #1332 N2).
_label_present() {
  local _lname="$1" _lout _lrc _lname_lc
  _lout="$(gh label list --repo "$KIT_ISSUE_REPO" --search "$_lname" --limit 100 --json name 2>&1)"
  _lrc=$?
  if [ "$_lrc" -ne 0 ]; then
    echo "degraded: could not probe label '$_lname' on $KIT_ISSUE_REPO (gh label list exit $_lrc): $_lout — no issue was created" >&2
    exit 1
  fi
  if ! grep -q '^[[:space:]]*\[' <<<"$_lout"; then
    echo "degraded: gh label list returned an unexpected reply for '$_lname' on $KIT_ISSUE_REPO (expected a JSON array): $_lout — no issue was created" >&2
    exit 1
  fi
  _lname_lc="$(printf '%s' "$_lname" | tr 'A-Z' 'a-z')"
  grep -qF "\"name\":\"${_lname_lc}\"" < <(printf '%s' "$_lout" | tr -d '[:space:]' | tr 'A-Z' 'a-z')
}
ensure_target_label() {
  [ "$_label_ready" -eq 1 ] && return 0
  local _lname="target:${target_name}" _cout
  # STAGE_RETRO_ISSUES_UNREGISTERED_GUARD (kit issue #1332 NB1): only a target registered in
  # TARGETS.md may have its label auto-created. The basename fallback (no row for this retro's
  # directory — possibly ANOTHER kit's retro) must not mint a `target:<dir>` label and its issues
  # in this repo: refuse loudly, once, before any create.
  if [ "$_target_registered" -ne 1 ]; then
    echo "degraded: target '${target_name}' is unregistered in $TARGETS_MD (basename fallback) — refusing to create label '$_lname' or any issue on $KIT_ISSUE_REPO; register the target or run from the owning kit" >&2
    exit 1
  fi
  if ! _label_present "$_lname"; then
    if ! _cout="$(gh label create "$_lname" --repo "$KIT_ISSUE_REPO" \
        --description "Fleet target: ${target_name}" --color d4c5f9 2>&1)"; then
      # STAGE_RETRO_ISSUES_LABEL_REPROBE (kit issue #1332 N3): a concurrent run may have created
      # the label between our probe and our create — look once more before declaring degraded.
      if ! _label_present "$_lname"; then
        echo "degraded: label '$_lname' is missing on $KIT_ISSUE_REPO and could not be created: $_cout — no issue was created" >&2
        exit 1
      fi
    fi
  fi
  _label_ready=1
}

# ---------------------------------------------------------------------------
# Main loop
open_count=0; skipped_shipped=0; skipped_wrong_kit=0
skipped_dedup=0; created=0; failed=0; unknown_outcome=0; unclassifiable=0

# title_is_unusable <title>: true for a bare priority/type token (the length clause of #1260 is deferred:
# ~25 fixtures use 1-11 char titles and the fleet minimum is 19 chars, so it would change no real output).
title_is_unusable() {
  local t
  t="$(printf '%s' "$1" | tr 'A-Z' 'a-z' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  case "$t" in
    critical|medium|high|low|bug|fix|feature|docs|documentation|regression|enhancement) return 0 ;;
  esac
  return 1
}

# _recheck_exists <signature>: return 0 when an exact-signature issue (any state) exists NOW, 1 when
# the lookup succeeded and found none, 2 when the lookup itself failed or could not be parsed.
_recheck_exists() {
  local _r
  _r="$(gh issue list --state all --repo "$KIT_ISSUE_REPO" \
    --limit "$_LIST_LIMIT" --search "\"$1\"" --json state,body 2>/dev/null)" || return 2
  grep -q '^[[:space:]]*\[' <<<"$_r" || return 2
  _r="$(printf '%s' "$_r" | _exact_sig_matches "$1")" || return 2
  grep -q '"state":[[:space:]]*"\(OPEN\|CLOSED\)"' <<<"$_r"
}

while IFS=$'\037' read -r _rid _delta _target_cell _evidence _type_cell _priority_cell; do
  _rid="$(printf '%s' "$_rid" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  _delta="$(printf '%s' "$_delta" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  _target_cell="$(printf '%s' "$_target_cell" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  _evidence="$(printf '%s' "$_evidence" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  _type_cell="$(printf '%s' "$_type_cell" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  _priority_cell="$(printf '%s' "$_priority_cell" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [ -z "$_rid" ] && continue

  # Skip shipped rows for PARTIAL applied retros; all rows open otherwise.
  # (Fully applied/dismissed without PARTIAL already exited above.)
  if [ $is_partial -eq 1 ] && is_shipped "$_rid"; then
    skipped_shipped=$((skipped_shipped+1)); continue
  fi

  # Wrong-kit check: skip rows targeting a different kit
  if is_wrong_kit "$_target_cell"; then
    echo "skipped-wrong-kit: row $_rid targets another kit ('$_target_cell') — skipping" >&2
    skipped_wrong_kit=$((skipped_wrong_kit+1)); continue
  fi

  open_count=$((open_count+1))

  # Build issue fields
  _title="$(strip_md_bold "$_delta")"
  if [ "${#_title}" -gt 120 ]; then _title="${_title:0:117}..."; fi
  # STAGE_RETRO_ISSUES_TITLE_GUARD (kit issue #1260): a bare priority/type token
  # is a mis-read column (issue #1248 was titled `LOW`), never a real delta summary.
  # Not created, not silently dropped: typed `unclassifiable-row:` line + summary count, exit 0.
  if title_is_unusable "$_title"; then
    echo "unclassifiable-row: row $_rid has no usable title (got '$_title': a bare priority/type token) — needs manual review, no issue staged" >&2
    open_count=$((open_count-1)); unclassifiable=$((unclassifiable+1)); continue
  fi

  _type_label="$(map_type "$_type_cell")"
  _priority_label="$(map_priority "$_priority_cell")"

  _source_line="Source retro: ${target_name}/retros/${retro_basename} · ${_rid}"
  _rollout_line="Part of backlog-first rollout #557"

  _body="$(printf '%s\n\n**Target:** %s\n**Evidence:** %s\n\n---\n%s\n%s' \
    "$_delta" "$_target_cell" "$_evidence" "$_source_line" "$_rollout_line")"

  _labels="status:needs-review,target:${target_name},type:${_type_label}"
  if [ -n "$_priority_label" ]; then _labels="${_labels},priority:${_priority_label}"; fi

  if [ $apply -eq 0 ]; then
    printf 'planned-issue: %s\n' "$_title"
    printf '  labels: %s\n' "$_labels"
    printf '  body:\n'
    printf '%s\n' "$_body" | sed 's/^/    /'
    printf '\n'
  else
    # Dedup: search ALL states (open + closed) for the exact source signature (kit issue #949
    # item 2). A closed issue for this row must still suppress a re-create — a false issue that
    # gets manually closed used to be silently re-seeded on the next --apply because only OPEN
    # issues were ever searched. --json state lets one gh call classify a match's state without
    # a jq dependency (grep on the raw JSON text is enough; state is always OPEN or CLOSED).
    # STAGE_RETRO_ISSUES_DEDUP_STATE_ALL: anchor for the state=all teeth proof.
    _search_sig="${_source_line}"
    _existing="$(gh issue list --repo "$KIT_ISSUE_REPO" --state all \
      --limit "$_LIST_LIMIT" --search "\"$_search_sig\"" --json state,body 2>&1)"
    _dedup_rc=$?
    # STAGE_RETRO_ISSUES_DEDUP_LIST_FAILURE_GUARD (kit issue #949 item 2): a failed list call
    # (non-zero exit — network error, bad gh invocation, rate limit, …) must NOT fall through to
    # create: that would risk a duplicate the very check exists to prevent. Count it as failed
    # for this row instead, exactly like a failed `gh issue create` below.
    if [ "$_dedup_rc" -ne 0 ]; then
      echo "ERROR: gh issue list (dedup) failed for row $_rid: $_existing" >&2
      failed=$((failed+1)); continue
    fi
    # STAGE_RETRO_ISSUES_DEDUP_EMPTY_REPLY_GUARD (kit issue #1093 item 1): `gh issue list` can
    # exit 0 with EMPTY stdout instead of the '[]' a genuinely empty JSON array reply would carry
    # (observed: a transient gh/API hiccup that still exits 0). The OPEN/CLOSED greps below both
    # silently fail to match on an empty string, so without this guard an empty reply fell through
    # as "no match" and proceeded straight to gh issue create — exactly the duplicate this dedup
    # check exists to prevent. Require the reply to actually start with '[' (a JSON array, empty
    # or not) before trusting a "no match" reading; anything else is a failure, not a no-match.
    if ! grep -q '^[[:space:]]*\[' <<<"$_existing"; then
      echo "ERROR: gh issue list (dedup) returned an unexpected reply for row $_rid (expected a JSON array): $_existing" >&2
      failed=$((failed+1)); continue
    fi
    # STAGE_RETRO_ISSUES_DEDUP_EXACT (kit issue #1304 item 1): keep only the hits whose body
    # carries THIS exact signature line — the search itself is a fuzzy word match.
    _raw_existing="$_existing"
    _existing="$(printf '%s' "$_raw_existing" | _exact_sig_matches "$_search_sig")" || {
      echo "ERROR: gh issue list (dedup) reply could not be parsed for row $_rid: $_raw_existing" >&2
      failed=$((failed+1)); continue
    }
    # A full page is only a problem when NO exact match was found in it (a match is a match however
    # many other issues the page holds), so the verdict is deferred to just before the create below.
    _page_filled=""   # empty, or the name of the lookup whose page filled the --limit
    if _list_filled "$_existing"; then _page_filled="primary"; fi
    if grep -q '"state":[[:space:]]*"OPEN"' <<<"$_existing"; then
      echo "skipped-duplicate: issue for row $_rid already exists (open; search matched '$_search_sig')"
      skipped_dedup=$((skipped_dedup+1)); continue
    fi
    # STAGE_RETRO_ISSUES_DEDUP_CHECK: anchor for T3 teeth proof — skip create when match found.
    if grep -q '"state":[[:space:]]*"CLOSED"' <<<"$_existing"; then
      echo "skipped-duplicate: issue for row $_rid already exists (closed; search matched '$_search_sig')"
      skipped_dedup=$((skipped_dedup+1)); continue
    fi
    # STAGE_RETRO_ISSUES_DEDUP_LEGACY_SIG (kit issue #1287 item 2): issues created before #1286
    # carry the legacy `<path basename>/retros/<file>` signature (e.g. `cloudflare/retros/...`,
    # today's key is `cloudflare-tunnels/retros/...`). When the registered name differs from the
    # basename, search that signature too (all states, same failure guards as above) so a
    # re-marked pending retro cannot duplicate on --apply. Skipped when they are equal: one
    # lookup, no extra gh traffic for the common case.
    if [ "$_legacy_target_name" != "$target_name" ]; then
      _legacy_sig="Source retro: ${_legacy_target_name}/retros/${retro_basename} · ${_rid}"
      _legacy_existing="$(gh issue list --repo "$KIT_ISSUE_REPO" --state all \
        --limit "$_LIST_LIMIT" --search "\"$_legacy_sig\"" --json state,body 2>&1)"
      _legacy_rc=$?
      if [ "$_legacy_rc" -ne 0 ]; then
        echo "ERROR: gh issue list (legacy-signature dedup) failed for row $_rid: $_legacy_existing" >&2
        failed=$((failed+1)); continue
      fi
      if ! grep -q '^[[:space:]]*\[' <<<"$_legacy_existing"; then
        echo "ERROR: gh issue list (legacy-signature dedup) returned an unexpected reply for row $_rid (expected a JSON array): $_legacy_existing" >&2
        failed=$((failed+1)); continue
      fi
      # Same exact-signature filter as the primary lookup (kit issue #1304 item 1): the legacy
      # signature is the one whose fuzzy search can hit ANOTHER target's issue (three.js's legacy
      # name `research` matches every `*-research` target's issue for the same file and row).
      _legacy_raw="$_legacy_existing"
      _legacy_existing="$(printf '%s' "$_legacy_raw" | _exact_sig_matches "$_legacy_sig")" || {
        echo "ERROR: gh issue list (legacy-signature dedup) reply could not be parsed for row $_rid: $_legacy_raw" >&2
        failed=$((failed+1)); continue
      }
      if _list_filled "$_legacy_existing"; then _page_filled="legacy-signature"; fi
      if grep -q '"state":[[:space:]]*"OPEN"' <<<"$_legacy_existing"; then
        echo "skipped-duplicate: issue for row $_rid already exists (open; legacy signature matched '$_legacy_sig')"
        skipped_dedup=$((skipped_dedup+1)); continue
      fi
      if grep -q '"state":[[:space:]]*"CLOSED"' <<<"$_legacy_existing"; then
        echo "skipped-duplicate: issue for row $_rid already exists (closed; legacy signature matched '$_legacy_sig')"
        skipped_dedup=$((skipped_dedup+1)); continue
      fi
    fi

    # STAGE_RETRO_ISSUES_LIST_CAP_GUARD (kit issue #1369 c): no exact match, but a lookup filled its
    # --limit, so the match may have been cut off. Not "no match": a typed failure, nothing created.
    if [ -n "$_page_filled" ]; then
      echo "ERROR: gh issue list (dedup) returned $_LIST_LIMIT results = the --limit $_LIST_LIMIT cap" \
           "for row $_rid ($_page_filled lookup) — the result may be truncated, refusing to create" \
           "(raise STAGE_RETRO_ISSUES_LIST_LIMIT or narrow the repo)" >&2
      failed=$((failed+1)); continue
    fi

    ensure_target_label   # STAGE_RETRO_ISSUES_LABEL_PROBE_CALL: once, before the first create
    _label_flags=""
    IFS=',' read -ra _lbl_arr <<< "$_labels"
    for _lbl in "${_lbl_arr[@]}"; do
      _label_flags="$_label_flags --label $(printf '%s' "$_lbl" | sed "s/'/'\\\\''/g")"
    done

    # shellcheck disable=SC2086
    _url="$(gh issue create --repo "$KIT_ISSUE_REPO" \
      --title "$_title" \
      $_label_flags \
      --body "$_body" 2>&1)" || {
        # STAGE_RETRO_ISSUES_UNKNOWN_OUTCOME (kit issue #1261): a failed create can still have written
        # the issue (timeout after the write). Re-run the exact-signature lookup before counting a
        # failure: a hit is `unknown-outcome` (the issue exists, nothing to retry); no hit stays
        # `failed`; a lookup that itself fails leaves the outcome unprovable, so it also stays `failed`.
        if _recheck_exists "$_search_sig"; then
          echo "unknown-outcome: gh issue create failed for row $_rid but a re-run dedup search found the issue (search matched '$_search_sig'): $_url" >&2
          unknown_outcome=$((unknown_outcome+1)); continue
        fi
        echo "ERROR: gh issue create failed for row $_rid: $_url" >&2
        failed=$((failed+1)); continue
      }
    echo "created: $_url (row $_rid)"
    created=$((created+1))
  fi
done <<< "$_rows"

# Summary and no-match detection when all rows were shipped
if [ "$open_count" -eq 0 ] && [ "$skipped_shipped" -gt 0 ] && [ "$skipped_wrong_kit" -eq 0 ]; then
  echo "no-match: delta section found but all rows are shipped (skipped: $skipped_shipped)" >&2
fi

if [ $apply -eq 1 ]; then
  # 'failed=' is appended LAST so existing parsers that read the earlier fields are unaffected.
  # STAGE_RETRO_ISSUES_SUMMARY: anchor for T5 teeth proof — the failed= field at the end.
  printf 'summary: created=%d skipped-duplicate=%d skipped-shipped=%d skipped-wrong-kit=%d unclassifiable=%d unknown-outcome=%d failed=%d\n' \
    "$created" "$skipped_dedup" "$skipped_shipped" "$skipped_wrong_kit" "$unclassifiable" "$unknown_outcome" "$failed"
fi

# Exit 2 when any create failed (§7 anti-silent-zero: partial failure must not look like success).
# Exit 0 on dry-run or a clean --apply run.
[ "$failed" -gt 0 ] && exit 2
exit 0
