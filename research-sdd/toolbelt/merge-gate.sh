#!/usr/bin/env bash
# merge-gate.sh — pre-merge check: never merge a review-due candidate before its review (kit issue #1272).
#
# Reads gentle-ai's OWN answer (`gentle-ai review assess --committed-only --json`) for the range
# <merge-base(HEAD, base-ref)>..HEAD of a worktree (assessed from the merge-base, never a moving ref) and refuses when `review_due` is true. gentle-ai already folds
# "this exact range was acknowledged" into its answer (`review_due=false`,
# `review_due_reason=already_reviewed`), so this script re-implements none of that logic.
#
# Usage:
#   merge-gate.sh --cwd <repo|worktree> --base-ref <ref> [--head <sha>] [--pr <PR#> | --merge <PR#>] [--required-checks <a,b,...>] [--no-closure-evidence]
#
# TRUST ASSUMPTION: a run without --pr/--merge is RANGE-ONLY. It trusts the caller's --base-ref and
# --head and says so on its allow line; it does NOT prove the range is the whole PR. Use `--pr N`
# (check-only) or `--merge N` to bind the range to the PR (head equality + the assessed range must
# start at or before the PR branch point). Merge only on a PR-bound allow.
#
# Typed stdout, one verdict line per run (`merged:` follows an allow under --merge):
#   merge-gate: allow: <passive|already_reviewed|under_budget> (head=<sha> base=<ref> merge_base=<sha>) (range-only … | bound to PR #N …)   exit 0
#   merge-gate: refuse: review_due (<reason>) ...                                        exit 1
#   merge-gate: refuse: head_mismatch ...                                                exit 1
#   merge-gate: refuse: base_excludes_pr_commits ... (--pr/--merge only)                 exit 1
#   merge-gate: refuse: ci_pending|ci_failed|ci_missing (<checks>) ... (--merge only)   exit 1
#   merge-gate: degraded: <why>                                                          exit 3
#   merge-gate: usage: <why>                                                             exit 2
#   merge-gate: merged: PR #N (head=<sha> cwd=<dir>)                                     exit 0
#   merge-gate: closure-evidence: posted|not posted|none|skipped|degraded: ...           (after `merged:`; never changes the exit)
#
# A broken instrument NEVER allows (CLAUDE.md §7): missing git/jq/gentle-ai, a failing assess, an
# unparseable or off-schema answer, an unknown not-due reason and an unreadable PR head are all
# `degraded` (exit 3), never `allow`.
#
# The default run is a PURE check: no gh call, no review start, no repository write. `--pr N` adds
# read-only PR binding (one `gh api repos/{owner}/{repo}/pulls/N` inside --cwd). `--merge N` binds
# the same way, then runs `gh pr merge N --squash --match-head-commit <head>` after an allow.
# Never calls `gentle-ai review start`.
#
# CI GATE (kit issue #1426, --merge only): after the review allow and BEFORE `gh pr merge`, the check
# runs of the EXACT head sha are read (one read-only `gh api repos/{owner}/{repo}/commits/<head>/check-runs
# --paginate` inside --cwd) and the merge is refused unless every reported check is green and every
# required check is present. Required set: --required-checks <a,b,...>, else env
# MERGE_GATE_REQUIRED_CHECKS, else the default `shellcheck,toolbelt-tests`. An explicitly EMPTY list
# (flag or env) is the opt-out for path-filtered doc-only PRs whose CI never runs those two jobs; it
# waives only the required-NAME check, every reported check must still be green and at least one must be
# reported. Why REST by sha and not `gh pr checks`: `gh pr checks` resolves the PR's CURRENT head (it can
# differ from the head we verified and merge with), and gh 2.45 has no `--json` there. Refusals, in
# precedence order: ci_failed (failure/cancelled/timed_out/action_required/... conclusion), ci_pending
# (any run not completed, or no run reported at all), ci_missing (a required name absent). Reported
# checks other than success/skipped/neutral are failed. Unreadable/off-shape check data is degraded.
# LATEST RUN PER (name, app.id): a rerun or relabel leaves an older run next to the newer one on the same
# head (e.g. a failed and a later green "Check Issue Has status:approved"), so before judging, only the
# newest run per (check name, app id) is kept. Latest = HIGHEST check-run id (ids increase with creation,
# so a rerun always gets a higher id). started_at is deliberately NOT used: a freshly queued rerun has a
# null started_at and would lose to an older, finished run, allowing a merge while CI is pending.
# Same name from two different apps stays two checks.
# DOC-ONLY PRs (only PR Validation runs, no shellcheck/toolbelt-tests) need `--required-checks ""`, and
# still need every PR Validation check green.
# CLOSURE EVIDENCE (kit issue #1812, --merge only): after a SUCCESSFUL `gh pr merge`, ONE comment is posted on
# each issue the PR closes, in the grammar reconcile-issues.sh accepts as shipped evidence (kit issue #1709): a
# `- commit: <merge sha>` line and one `- test: <path>` line per test file the PR changed
# (research-sdd/**/tests/*.test.sh, from the paginated PR files list, removed files excluded).
# reconcile-issues.sh trusts comments only from OWNER/MEMBER/COLLABORATOR authors, so the comment must be posted
# from a maintainer's gh session.
# THE CLOSING-ISSUE LIST COMES FROM GITHUB, never from parsing the PR body: ONE bounded `gh api graphql` read
# (lib/gh-visibility.sh gh_bounded_run, bound RSDD-style via MERGE_GATE_GH_TIMEOUT, default 30 s) of the merged PR's
# `closingIssuesReferences(first:50)`, the same source GitHub itself uses to auto-close. The same answer must say
# `merged == true`, `state == "MERGED"` and carry a 40-hex `mergeCommit.oid` (that oid is the sha in the comment);
# otherwise `closure-evidence: degraded: ...` and nothing is posted. Only nodes whose repository.nameWithOwner is
# THIS repo are posted on; a cross-repo node gets a `closure-evidence: note: ...` and is never commented. A
# `totalCount` above 50 prints a typed degraded note naming the overflow and still posts the 50 read.
# ONE REPOSITORY for the whole step: the one `gh pr merge` used, i.e. GH_REPO when set, else the cwd remote
# (`gh repo view`, bounded). It is passed explicitly to the GraphQL read (owner/name, never the {owner}/{repo}
# placeholders), to the PR files read and as `--repo` to every comment; a GraphQL answer whose nameWithOwner differs
# (case-insensitive) is `degraded` and nothing is posted.
# A PR that changes no test file posts NOTHING (`closure-evidence: not posted: ...`): a commit without a test only
# reads as borderline in reconcile-issues.sh. At most 10 test files are listed (CAP); files beyond it print
# `closure-evidence: note: N test file(s) beyond cap 10 not listed`. When some comments fail, a final
# `degraded: not posted for issues: #a #b` line names them for a manual backfill.
# The step can never fail the run: any gh failure after the merge prints `closure-evidence: degraded: ...` and the
# exit stays 0. `--no-closure-evidence` opts out (`closure-evidence: skipped`). Without --merge no gh call is made
# for this step (a default or --pr run is a pure check).
# KNOWN GAP: legacy commit statuses (/status) are not read, only check runs.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

say() { printf 'merge-gate: %s\n' "$*"; }
usage() { say "usage: $*"; echo "usage: merge-gate.sh --cwd <dir> --base-ref <ref> [--head <sha>] [--pr <PR#> | --merge <PR#>] [--required-checks <a,b,...>] [--no-closure-evidence]" >&2; exit 2; }
degraded() { say "degraded: $*"; exit 3; }

cwd="" base="" want_head="" pr="" do_merge="" no_evidence=""
required="shellcheck,toolbelt-tests"
[ -z "${MERGE_GATE_REQUIRED_CHECKS+x}" ] || required="$MERGE_GATE_REQUIRED_CHECKS"   # set-but-empty = opt-out
while [ $# -gt 0 ]; do
  case "$1" in
    --pr) [ $# -ge 2 ] || usage "--pr needs a PR number"; pr="$2"; shift 2 ;;
    --cwd) [ $# -ge 2 ] || usage "--cwd needs a value"; cwd="$2"; shift 2 ;;
    --base-ref) [ $# -ge 2 ] || usage "--base-ref needs a value"; base="$2"; shift 2 ;;
    --head) [ $# -ge 2 ] || usage "--head needs a value"; want_head="$2"; shift 2 ;;
    --merge) [ $# -ge 2 ] || usage "--merge needs a PR number"; pr="$2"; do_merge=1; shift 2 ;;
    --no-closure-evidence) no_evidence=1; shift ;;
    --required-checks) [ $# -ge 2 ] || usage "--required-checks needs a value (use \"\" to opt out)"; required="$2"; shift 2 ;;
    *) usage "unknown argument: $1" ;;
  esac
done
[ -n "$cwd" ] || usage "--cwd is required"
[ -n "$base" ] || usage "--base-ref is required"
case "$pr" in ''|*[!0-9]*) [ -z "$pr" ] || usage "--pr/--merge needs a numeric PR number, got: $pr" ;; esac

# Probes: every runtime dependency is checked up front (typed degraded, never a silent pass).
command -v git >/dev/null 2>&1 || degraded "git not found on PATH"
command -v jq >/dev/null 2>&1 || degraded "jq not found on PATH"
command -v gentle-ai >/dev/null 2>&1 || degraded "gentle-ai not found on PATH"
if [ -n "$pr" ]; then command -v gh >/dev/null 2>&1 || degraded "gh not found on PATH (needed for --pr/--merge)"; fi

ghr() { (cd "$cwd" && gh "$@"); }   # gh bound to the repo under test, never the caller's cwd

git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1 || degraded "--cwd is not a git repo/worktree: $cwd"
head="$(git -C "$cwd" rev-parse --verify HEAD 2>/dev/null)" || degraded "cannot resolve HEAD in $cwd"
git -C "$cwd" rev-parse --verify --quiet "${base}^{commit}" >/dev/null || degraded "base-ref does not resolve to a commit: $base"

if [ -n "$want_head" ]; then
  want_full="$(git -C "$cwd" rev-parse --verify --quiet "${want_head}^{commit}")" || degraded "--head does not resolve to a commit: $want_head"
  if [ "$want_full" != "$head" ]; then
    say "refuse: head_mismatch (--head $want_full != worktree HEAD $head)"
    exit 1
  fi
fi

# Assess from the MERGE-BASE, never a moving ref: base-ref may have advanced past the branch point
# with unrelated changes, which would make the assessed range include commits that are not ours.
mb="$(git -C "$cwd" merge-base HEAD "$base" 2>/dev/null)" || degraded "no common ancestor between HEAD and base-ref: $base"
[ -n "$mb" ] || degraded "no common ancestor between HEAD and base-ref: $base"
ahead="$(git -C "$cwd" rev-list --count "$mb..HEAD" 2>/dev/null)" || degraded "cannot count commits in $mb..HEAD"
case "$ahead" in ''|*[!0-9]*) degraded "cannot count commits in $mb..HEAD" ;; esac
[ "$ahead" -gt 0 ] || degraded "empty range (nothing to merge): $mb..HEAD has 0 commits"

# --merge: bind the assessed range to the PR. The caller-chosen base must start at or before the
# PR's branch point, otherwise a narrow base would hide unreviewed commits of the same PR.
if [ -n "$pr" ]; then
  # REST, not `gh pr view --json`: baseRefOid is not a pr-view field in gh 2.45 (kit issue #1272 F1).
  pr_json="$(ghr api "repos/{owner}/{repo}/pulls/$pr" --jq '{headRefOid:.head.sha, baseRefOid:.base.sha, baseRefName:.base.ref}' 2>/dev/null)" || pr_json=""
  [ -n "$pr_json" ] || degraded "cannot read PR #$pr (gh api failed)"
  pr_head="$(printf '%s' "$pr_json" | jq -r '.headRefOid // empty' 2>/dev/null)"
  [ -n "$pr_head" ] || degraded "cannot read PR #$pr head (no headRefOid)"
  if [ "$pr_head" != "$head" ]; then
    say "refuse: head_mismatch (PR #$pr head $pr_head != checked HEAD $head)"
    exit 1
  fi
  pr_base="$(printf '%s' "$pr_json" | jq -r '.baseRefOid // empty' 2>/dev/null)"
  [ -n "$pr_base" ] || degraded "cannot read PR #$pr base (no baseRefOid)"
  git -C "$cwd" cat-file -e "${pr_base}^{commit}" 2>/dev/null || degraded "PR #$pr base $pr_base is not present locally (git fetch first)"
  pr_mb="$(git -C "$cwd" merge-base HEAD "$pr_base" 2>/dev/null)" || degraded "no common ancestor between HEAD and PR #$pr base"
  if ! git -C "$cwd" merge-base --is-ancestor "$mb" "$pr_mb"; then
    say "refuse: base_excludes_pr_commits (assessed range starts at $mb, after the PR branch point $pr_mb) — use the PR base as --base-ref"
    exit 1
  fi
fi

# CAVEAT (kit issue #1367, unobserved): assessing a whole branch from its branch point after it was
# reviewed slice by slice may return high_risk instead of already_reviewed. That is a false refuse
# (safe direction); if it is ever observed, file it against gentle-ai — this gate does not second-guess it.
# Ask gentle-ai. Capture stdout and the exit status separately; a non-zero assess is degraded
# even when its stdout happens to look like an allow.
err_file="$(mktemp 2>/dev/null)" || degraded "mktemp failed"
trap 'rm -f "$err_file"' EXIT
assess_out="$(gentle-ai review assess --cwd "$cwd" --base-ref "$mb" --committed-only --json 2>"$err_file")"
assess_rc=$?
if [ "$assess_rc" -ne 0 ]; then
  # Surface gentle-ai's own first error line, plus our own hint for the common untracked-files cause.
  err_line="$(head -n 1 "$err_file" 2>/dev/null | cut -c1-200)"
  hint=""
  if grep -qi 'untracked' "$err_file" 2>/dev/null; then hint=" — clean or ignore untracked files in $cwd and retry"; fi
  degraded "gentle-ai review assess failed (exit $assess_rc)${err_line:+: $err_line}$hint"
fi
head_after="$(git -C "$cwd" rev-parse --verify HEAD 2>/dev/null)" || head_after=""
[ "$head_after" = "$head" ] || degraded "HEAD moved during assess ($head -> ${head_after:-unknown}); rerun"

printf '%s' "$assess_out" | jq -e . >/dev/null 2>&1 || degraded "assess output is unparseable JSON"
schema="$(printf '%s' "$assess_out" | jq -r '.schema // empty')"
[ "$schema" = "gentle-ai.review-assessment/v1" ] || degraded "unexpected assess schema: ${schema:-<none>}"
due="$(printf '%s' "$assess_out" | jq -r 'if (.review_due | type) == "boolean" then .review_due else "invalid" end')"
case "$due" in true|false) ;; *) degraded "assess review_due is missing or not a boolean" ;; esac
reason="$(printf '%s' "$assess_out" | jq -r '.review_due_reason // empty')"
[ -n "$reason" ] || degraded "assess review_due_reason is missing"

if [ "$due" = "true" ]; then
  say "refuse: review_due ($reason) (head=$head base=$base merge_base=$mb) — review this exact head before merging"
  exit 1
fi
case "$reason" in
  passive|already_reviewed|under_budget) ;;
  *) degraded "unknown not-due reason from gentle-ai: $reason (refusing to guess)" ;;
esac

# CI gate (see header): --merge only, after the review verdict and before any allow/merge output.
if [ -n "$do_merge" ]; then
  ci_raw="$(ghr api "repos/{owner}/{repo}/commits/$head/check-runs?per_page=100" --paginate 2>"$err_file")" || {
    # Surface gh's own error (bounded, single line) instead of a generic message.
    ci_err="$(tr '\n' ' ' <"$err_file" 2>/dev/null | cut -c1-300)"
    degraded "cannot read check runs for head $head (gh api failed${ci_err:+: $ci_err})"
  }
  # --paginate prints one JSON object per page: slurp, require every page to carry a check_runs array of named, statused runs.
  ci_norm="$(printf '%s' "$ci_raw" | jq -c -s 'if length > 0 and all(.[]; type == "object" and (.check_runs | type) == "array") then [.[].check_runs[]] else error("shape") end | if all(.[]; type == "object" and (.name | type) == "string" and (.status | type) == "string") then . else error("shape") end
    | map({name, status, conclusion, app_id: (.app.id? // null), id: (.id? // 0)})
    | group_by([.name, .app_id]) | map(max_by(.id))' 2>/dev/null)" || degraded "check runs for head $head are unparseable or off-schema"
  ci_req="$(jq -cn --arg s "$required" '$s | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))' 2>/dev/null)" || degraded "cannot parse --required-checks list"
  ci_verdict="$(printf '%s' "$ci_norm" | jq -r --argjson req "$ci_req" '
    (map(select(.status == "completed" and ((.conclusion // "") | IN("success", "skipped", "neutral") | not)) | .name) | unique) as $failed
    | (map(select(.status != "completed") | .name) | unique) as $pending
    | ([.[].name] as $seen | $req | map(select(. as $r | $seen | index($r) | not))) as $missing
    | if ($failed | length) > 0 then "ci_failed (\($failed | join(",")))"
      elif ($pending | length) > 0 then "ci_pending (\($pending | join(",")))"
      elif length == 0 then "ci_pending (no check runs reported)"
      elif ($missing | length) > 0 then "ci_missing (\($missing | join(",")))"
      else "ok" end' 2>/dev/null)" || degraded "cannot evaluate check runs for head $head"
  [ -n "$ci_verdict" ] || degraded "cannot evaluate check runs for head $head"
  if [ "$ci_verdict" != "ok" ]; then
    say "refuse: $ci_verdict (head=$head) — CI for this exact head must be green before merging"
    exit 1
  fi
fi

if [ -z "$pr" ]; then
  say "allow: $reason (head=$head base=$base merge_base=$mb) (range-only; not bound to a PR — use --pr N or --merge N)"
  exit 0
fi
say "allow: $reason (head=$head base=$base merge_base=$mb) (bound to PR #$pr: head equal, range starts at or before the PR branch point)"

[ -n "$do_merge" ] || exit 0

merge_out="$(ghr pr merge "$pr" --squash --match-head-commit "$head" 2>&1)"
merge_rc=$?
if [ "$merge_rc" -ne 0 ]; then
  # Skip gh deprecation/warning noise so it cannot replace the real error.
  merge_line="$(printf '%s\n' "$merge_out" | grep -Evi 'deprecat|^warning' | head -n 1 | cut -c1-200)"
  if grep -Eqi 'head branch was modified|match-head-commit|head sha' <<<"$merge_out"; then  # MERGE-GATE-HEAD-REJECT
    say "refuse: head_mismatch (PR #$pr head changed before merge: $merge_line)"
    exit 1
  fi
  degraded "gh pr merge failed for PR #$pr${merge_line:+: $merge_line}"
fi
say "merged: PR #$pr (head=$head cwd=$cwd)"

# Closure evidence (see header). Every failure prints a typed line and returns 0: the merge already happened.
closure_evidence() {
  local ev="closure-evidence" lib="${MERGE_GATE_LIB:-$HERE/lib/gh-visibility.sh}" gq gj grc verdict msha repo owner name got_repo total issues cross
  local files test_files n_all n_tests tline issue text rc failed=""
  if [ -n "$no_evidence" ]; then say "$ev: skipped: --no-closure-evidence"; return 0; fi
  # shellcheck source=lib/gh-visibility.sh
  . "$lib" 2>/dev/null || { say "$ev: degraded: lib/gh-visibility.sh not found (needed for the bounded GraphQL read); nothing posted"; return 0; }
  # ONE repository for the whole step: the one `gh pr merge` just used (GH_REPO when set, else the cwd remote). It is
  # passed explicitly to the read, the files read and every comment, so they can never resolve to different repos
  # (gh_bounded_run runs gh with GH_REPO unset, which would silently re-resolve from the cwd remote).
  if [ -n "${GH_REPO:-}" ]; then
    name="${GH_REPO##*/}"; owner="${GH_REPO%/*}"; owner="${owner##*/}"; repo="$owner/$name"
  else
    repo="$(cd "$cwd" && GHV_BOUND_ENV=MERGE_GATE_GH_TIMEOUT GHV_BOUND_DEFAULT=30 gh_bounded_run gh repo view --json nameWithOwner -q .nameWithOwner 2>"$err_file")" \
      || { say "$ev: degraded: cannot resolve the repository the merge used (gh repo view: $(head -n 1 "$err_file" 2>/dev/null | cut -c1-200)); nothing posted"; return 0; }
    owner="${repo%%/*}"; name="${repo#*/}"
  fi
  if ! [[ "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then say "$ev: degraded: cannot resolve the repository the merge used (got '$repo'); nothing posted"; return 0; fi
  gq='query($owner:String!,$name:String!,$pr:Int!){repository(owner:$owner,name:$name){nameWithOwner pullRequest(number:$pr){merged state mergeCommit{oid} closingIssuesReferences(first:50){totalCount nodes{number repository{nameWithOwner}}}}}}'
  gj="$(cd "$cwd" && GHV_BOUND_ENV=MERGE_GATE_GH_TIMEOUT GHV_BOUND_DEFAULT=30 gh_bounded_run gh api graphql -F owner="$owner" -F name="$name" -F pr="$pr" -f query="$gq" 2>"$err_file")"; grc=$?
  if [ "$grc" -eq 124 ]; then say "$ev: degraded: GraphQL read of PR #$pr timed out (bound MERGE_GATE_GH_TIMEOUT, default 30 s); nothing posted"; return 0; fi
  if [ "$grc" -ne 0 ]; then say "$ev: degraded: cannot read the closing issues of PR #$pr (gh api graphql exit $grc: $(head -n 1 "$err_file" 2>/dev/null | cut -c1-200)); nothing posted"; return 0; fi
  verdict="$(printf '%s' "$gj" | jq -r '
    .data.repository as $r | $r.pullRequest as $p
    | if ($r.nameWithOwner | type) != "string" or ($p | type) != "object" or ($p.closingIssuesReferences.nodes | type) != "array" or ($p.closingIssuesReferences.totalCount | type) != "number" then "shape"
      elif $p.merged != true or $p.state != "MERGED" then "notmerged"
      elif ((($p.mergeCommit.oid // "") | tostring | test("^[0-9a-fA-F]{40}$")) | not) then "nooid"
      else "ok" end' 2>/dev/null)"
  case "$verdict" in
    ok) ;;
    notmerged) say "$ev: degraded: PR #$pr is not reported merged (merged!=true or state!=MERGED); nothing posted"; return 0 ;;
    nooid) say "$ev: degraded: PR #$pr has no usable 40-hex merge commit oid; nothing posted"; return 0 ;;
    *) say "$ev: degraded: the GraphQL answer for PR #$pr is unparseable or off-schema; nothing posted"; return 0 ;;
  esac
  got_repo="$(printf '%s' "$gj" | jq -r '.data.repository.nameWithOwner')"
  if [ "$(printf '%s' "$got_repo" | tr '[:upper:]' '[:lower:]')" != "$(printf '%s' "$repo" | tr '[:upper:]' '[:lower:]')" ]; then
    say "$ev: degraded: the GraphQL answer is for repository $got_repo but the merge used $repo; nothing posted"; return 0
  fi
  msha="$(printf '%s' "$gj" | jq -r '.data.repository.pullRequest.mergeCommit.oid')"
  total="$(printf '%s' "$gj" | jq -r '.data.repository.pullRequest.closingIssuesReferences.totalCount')"
  # Same-repo nodes only (GitHub names are case-insensitive); integer numbers >= 1.
  issues="$(printf '%s' "$gj" | jq -r --arg r "$repo" '.data.repository.pullRequest.closingIssuesReferences.nodes[]
    | select((.repository.nameWithOwner | tostring | ascii_downcase) == ($r | ascii_downcase) and (.number | type) == "number" and .number >= 1 and (.number | floor) == .number) | .number' 2>/dev/null | sort -un)"
  cross="$(printf '%s' "$gj" | jq -r --arg r "$repo" '.data.repository.pullRequest.closingIssuesReferences.nodes[]
    | select((.repository.nameWithOwner | tostring | ascii_downcase) != ($r | ascii_downcase)) | "\(.repository.nameWithOwner)#\(.number)"' 2>/dev/null)"
  while IFS= read -r issue; do
    [ -z "$issue" ] || say "$ev: note: PR #$pr also closes $issue in another repository; no evidence posted there"
  done <<<"$cross"
  if [ "$total" -gt 50 ]; then say "$ev: degraded: PR #$pr closes $total issues but only the first 50 were read; backfill the other $((total - 50)) by hand"; fi
  if [ -z "$issues" ]; then say "$ev: none: PR #$pr closes no issue in $repo (closingIssuesReferences has none)"; return 0; fi
  files="$(ghr api "repos/$repo/pulls/$pr/files?per_page=100" --paginate 2>/dev/null)" || { say "$ev: degraded: cannot read the files of PR #$pr (gh api failed)"; return 0; }
  # --paginate prints one JSON array per page: slurp and require every page to be an array.
  test_files="$(printf '%s' "$files" | jq -r -s 'if length > 0 and all(.[]; type == "array") then .[][] | select(.status != "removed") | .filename else error("shape") end' 2>/dev/null)" \
    || { say "$ev: degraded: files of PR #$pr are unparseable or off-schema"; return 0; }
  test_files="$(printf '%s\n' "$test_files" | grep -E '^research-sdd/(.+/)?tests/[^/]+\.test\.sh$' | sort -u)"
  if [ -z "$test_files" ]; then say "$ev: not posted: PR #$pr changes no test file (research-sdd/**/tests/*.test.sh); a commit without a test is not shipped evidence"; return 0; fi
  n_all="$(printf '%s\n' "$test_files" | grep -c .)"
  n_tests="$n_all"
  if [ "$n_all" -gt 10 ]; then
    n_tests=10
    say "$ev: note: $((n_all - 10)) test file(s) beyond cap 10 not listed"
  fi
  tline="$(printf '%s\n' "$test_files" | head -n 10 | sed 's/^/- test: /')"
  text="Closure evidence (merge-gate, PR #$pr):
- commit: $msha
$tline"
  for issue in $issues; do
    ghr issue comment "$issue" --repo "$repo" --body "$text" >/dev/null 2>"$err_file"; rc=$?
    if [ "$rc" -eq 0 ]; then say "$ev: posted: issue #$issue (commit=$msha tests=$n_tests)"
    else say "$ev: degraded: could not comment on issue #$issue (gh exit $rc: $(head -n 1 "$err_file" 2>/dev/null | cut -c1-200))"; failed="$failed #$issue"; fi
  done
  if [ -n "$failed" ]; then say "$ev: degraded: not posted for issues:$failed (backfill by hand)"; fi
  return 0
}
closure_evidence
exit 0
