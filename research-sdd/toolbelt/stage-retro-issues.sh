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
# Anti-silent-zero: three states are distinguished and named:
#   absent-input   retro file not found
#   empty-input    retro found but has no delta section
#   no-match       delta section found; all rows shipped/applied
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

_TP_LIB="$_SCRIPT_DIR/lib/target-paths.sh"
if [ ! -f "$_TP_LIB" ]; then
  echo "stage-retro-issues: cannot find helper $_TP_LIB" >&2; exit 1
fi
# shellcheck source=lib/target-paths.sh
. "$_TP_LIB"
declare -F target_paths_all >/dev/null 2>&1 \
  || { echo "stage-retro-issues: helper lib/target-paths.sh failed to define target_paths_all" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Derive target name from the retro's directory hierarchy
# Retro is at <target_dir>/retros/<file>; target_dir = dirname(dirname(retro))
_retro_dir="$(dirname "$retro")"
_target_dir="$(cd "$(dirname "$_retro_dir")" && pwd)"
target_name=""

if [ -f "$TARGETS_MD" ]; then
  while IFS= read -r _path; do
    _exp="$(cd "$_path" 2>/dev/null && pwd)" || continue
    if [ "$_exp" = "$_target_dir" ]; then
      target_name="$(basename "$_path")"
      break
    fi
  done < <(target_paths_all "$TARGETS_MD" 2>/dev/null)
fi

if [ -z "$target_name" ]; then
  target_name="$(basename "$_target_dir")"
  echo "WARN: target directory '$_target_dir' not found in $TARGETS_MD — using basename '$target_name'" >&2
fi

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
# Check for a delta section (empty-input)
_grammar_info="$(retro_grammar_delta_info "$retro")"
_found_field="$(printf '%s' "$_grammar_info" | cut -d '' -f1 | cut -d: -f1)"
if [ "$_found_field" != "1" ]; then
  echo "empty-input: no delta section found in $retro" >&2
  exit 0
fi

# ---------------------------------------------------------------------------
# Parse delta rows from the canonical/deprecated section
retro_file="$retro"
retro_basename="$(basename "$retro")"

_rows="$(awk '
  BEGIN { in_sec=0 }
  {
    low = tolower($0)
    if (low ~ /^## ([0-9]+\. )?proposed kit delta[s]?([[:space:]]|$)/ ||
        low ~ /^## proposed delta/ ||
        low ~ /^## delta proposals/ ||
        low ~ /^## deltas nuevos/ ||
        low ~ /^## summary of proposed delta/ ||
        low ~ /^## summary of new deltas/ ||
        low ~ /^## delta details([[:space:]]|$)/) {
      in_sec = 1; next
    }
    if (/^##[^#]/) { in_sec = 0; next }
    if (in_sec && /^\|/ && $0 !~ /^\|[-: |]+\|?[[:space:]]*$/) {
      line = $0
      sub(/^\|[[:space:]]*/, "", line)
      sub(/[[:space:]]*\|[[:space:]]*$/, "", line)
      n = split(line, f, /[[:space:]]*\|[[:space:]]*/)
      rid = f[1]; gsub(/[[:space:]]/, "", rid)
      if (rid ~ /^[-:]+$/) next
      if (rid ~ /^[[:alpha:]#][^0-9]*$/ && rid !~ /^[A-Z][0-9]/) next
      printf "%s\037%s\037%s\037%s\037%s\037%s\n",
        (n>=1 ? f[1] : ""), (n>=2 ? f[2] : ""), (n>=3 ? f[3] : ""),
        (n>=4 ? f[4] : ""), (n>=5 ? f[5] : ""), (n>=6 ? f[6] : "")
    }
  }
' "$retro_file")"

if [ -z "$_rows" ]; then
  echo "empty-input: delta section found but contains no data rows in $retro" >&2
  exit 0
fi

# ---------------------------------------------------------------------------
# Helpers

# is_shipped <row_id>: true when ID is in the shipped set of a PARTIAL marker
is_shipped() {
  [ $is_partial -eq 1 ] || return 1
  printf '%s\n' "$shipped_ids" | grep -qxF "$1"
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
  printf '%s' "$1" | grep -qiE '[-a-zA-Z0-9]+-kit[:/]'
}

# strip_md_bold: if the cell opens with a bold lead-in (**phrase**), return just
# the bolded phrase as the title (the author's own one-line summary).  Otherwise
# fall back to stripping surrounding ** markers.
# STAGE_RETRO_ISSUES_BOLD_LEAD: this sed branch is the T4 teeth anchor; replacing
# it with the old s/^\*\*// expression re-introduces the stray-** bug.
strip_md_bold() {
  printf '%s' "$1" | sed -E 's/^\*\*([^*]+)\*\*.*/\1/;t;s/^\*\*//;s/\*\*$//'
}

# ---------------------------------------------------------------------------
# Main loop
open_count=0; skipped_shipped=0; skipped_wrong_kit=0
skipped_dedup=0; created=0; failed=0

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
      --search "\"$_search_sig\"" --json state 2>&1)"
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
    if ! printf '%s' "$_existing" | grep -q '^[[:space:]]*\['; then
      echo "ERROR: gh issue list (dedup) returned an unexpected reply for row $_rid (expected a JSON array): $_existing" >&2
      failed=$((failed+1)); continue
    fi
    if printf '%s' "$_existing" | grep -q '"state":[[:space:]]*"OPEN"'; then
      echo "skipped-duplicate: issue for row $_rid already exists (open; search matched '$_search_sig')"
      skipped_dedup=$((skipped_dedup+1)); continue
    fi
    # STAGE_RETRO_ISSUES_DEDUP_CHECK: anchor for T3 teeth proof — skip create when match found.
    if printf '%s' "$_existing" | grep -q '"state":[[:space:]]*"CLOSED"'; then
      echo "skipped-duplicate: issue for row $_rid already exists (closed; search matched '$_search_sig')"
      skipped_dedup=$((skipped_dedup+1)); continue
    fi

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
  printf 'summary: created=%d skipped-duplicate=%d skipped-shipped=%d skipped-wrong-kit=%d failed=%d\n' \
    "$created" "$skipped_dedup" "$skipped_shipped" "$skipped_wrong_kit" "$failed"
fi

# Exit 2 when any create failed (§7 anti-silent-zero: partial failure must not look like success).
# Exit 0 on dry-run or a clean --apply run.
[ "$failed" -gt 0 ] && exit 2
exit 0
