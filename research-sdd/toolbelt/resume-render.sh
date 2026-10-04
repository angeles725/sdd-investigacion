#!/usr/bin/env bash
# resume-render.sh — render the prose resume handoff FROM resume-state JSON (kit issue #1274, slice 2).
#
# Read-only and derived: it consumes a research-sdd.resume-state/v1 document (see resume-state.v1.md) and prints
# concise Markdown. It invents nothing and writes nothing (propose-never-apply). Every null in the document is
# rendered as "unknown", never as 0 or "none": prs null + a non-ok prs_status prints "PR list unknown: <status>".
#
# Usage: resume-render.sh [--json FILE|-] [--cwd DIR] [--base-ref REF] [--no-gh]
#   --json FILE|-   render this document ('-' = stdin); without it the sibling resume-state.sh is run
#   --cwd/--base-ref/--no-gh   forwarded to resume-state.sh (rejected together with --json)
#
# Exit: 0 rendered · 2 usage, absent/empty input, malformed JSON, wrong schema, missing required fields, or
#       resume-state.sh failed · 3 DEGRADED (jq missing, or resume-state.sh reported DEGRADED) — no output.
set -uo pipefail

usage_text="usage: resume-render.sh [--json FILE|-] [--cwd DIR] [--base-ref REF] [--no-gh]"
usage() { echo "$usage_text" >&2; exit 2; }
HERE="$(cd "$(dirname "$0")" && pwd)"
SCHEMA="research-sdd.resume-state/v1"

json_src=""; fwd=()
while [ $# -gt 0 ]; do
  case "$1" in
    --json) [ $# -ge 2 ] || usage; json_src="$2"; shift 2 ;;
    --cwd|--base-ref) [ $# -ge 2 ] || usage; fwd+=("$1" "$2"); shift 2 ;;
    --no-gh) fwd+=("$1"); shift ;;
    -h|--help) echo "$usage_text"; exit 0 ;;
    *) echo "resume-render.sh: unknown argument: $1" >&2; usage ;;
  esac
done
if [ -n "$json_src" ] && [ "${#fwd[@]}" -gt 0 ]; then
  echo "resume-render.sh: --cwd/--base-ref/--no-gh apply to resume-state.sh and cannot be combined with --json" >&2; exit 2
fi

command -v jq >/dev/null 2>&1 || { echo "DEGRADED: jq not found; cannot render the resume handoff" >&2; exit 3; }

tmp="$(mktemp)" || { echo "resume-render.sh: mktemp failed" >&2; exit 2; }
trap 'rm -f "$tmp"' EXIT
if [ -z "$json_src" ]; then
  bash "$HERE/resume-state.sh" ${fwd[@]+"${fwd[@]}"} > "$tmp"; rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "resume-render.sh: resume-state.sh failed (rc $rc)" >&2
    [ "$rc" -eq 3 ] && exit 3
    exit 2
  fi
elif [ "$json_src" = "-" ]; then
  cat > "$tmp"
else
  { [ -f "$json_src" ] && [ -r "$json_src" ]; } || { echo "resume-render.sh: JSON file absent or unreadable: $json_src" >&2; exit 2; }
  cat "$json_src" > "$tmp"
fi

[ -s "$tmp" ] || { echo "resume-render.sh: empty input (no JSON document)" >&2; exit 2; }
jq -e . "$tmp" >/dev/null 2>&1 || { echo "resume-render.sh: malformed JSON input" >&2; exit 2; }
got="$(jq -r '.schema? // "" | tostring' "$tmp" 2>/dev/null)"
[ "$got" = "$SCHEMA" ] || { echo "resume-render.sh: wrong schema: [$got] (want $SCHEMA)" >&2; exit 2; }
jq -e '(.worktrees|type)=="array" and (.branches|type)=="array" and (.base_ref|type)=="string"' "$tmp" >/dev/null 2>&1 \
  || { echo "resume-render.sh: malformed document: worktrees/branches must be arrays and base_ref a string" >&2; exit 2; }

jq -r '
  def cnt(l; v): if v == null then l + " unknown" else l + " " + (v|tostring) end;
  def sha(v): if v == null then "unknown" else (v|tostring|.[0:7]) end;
  def ab(o): cnt("ahead"; o.ahead) + " · " + cnt("behind"; o.behind);
  def wt:
    "- `" + (.path|tostring) + "` — "
    + (if .branch == null then "detached HEAD" else "branch `" + (.branch|tostring) + "`" end)
    + " @ " + sha(.head) + " · "
    + (if .exists == false
       then "DIRECTORY MISSING" + (if .prunable == true then " (prunable: `git worktree prune`)" else "" end)
            + " · dirty unknown · untracked unknown"
       else cnt("dirty"; .dirty) + " · " + cnt("untracked"; .untracked) end)
    + " · " + ab(.);
  def prs:
    if .prs == null or (.prs|type) != "array" or .prs_status != "ok" then
      "PR list unknown: " + ((.prs_status // "prs_status missing")|tostring)
      + (if .prs != null then " (inconsistent: a PR list is present but its status is not ok; not trusted)" else "" end)
    elif (.prs|length) == 0 then "No open PRs (gh answered with an empty list)."
    else ((.prs[] | "- #" + (.number|tostring) + " `" + (.branch|tostring) + "` " + (.state|tostring) + " — " + (.url|tostring)),
          (if .prs_truncated == true then "- PR list truncated at the gh limit: it may be incomplete."
           elif .prs_truncated == null then "- PR list completeness unknown (prs_truncated missing)." else empty end))
    end;
  "# Resume handoff",
  "",
  "Generated " + ((.generated_at // "unknown time")|tostring) + " · repo `" + ((.repo.toplevel // "unknown")|tostring) + "`"
    + " · remote " + (if .repo.remote == null then "none configured" else "`" + (.repo.remote|tostring) + "`" end),
  "Base: `" + .base_ref + "` @ " + sha(.base_sha),
  "",
  "## Worktrees (" + (.worktrees|length|tostring) + ")",
  (if (.worktrees|length) == 0 then "None listed." else (.worktrees[] | wt) end),
  "",
  "## Loose branches (" + (.branches|length|tostring) + ")",
  (if (.branches|length) == 0 then "None: every local branch is checked out in a worktree."
   else (.branches[] | "- `" + (.name|tostring) + "` @ " + sha(.head) + " · " + ab(.)) end),
  "",
  "## Open PRs",
  prs,
  "",
  "## Not derived",
  "Review receipts, in-flight workers and the next task have no git source; state them by hand."
' "$tmp"
