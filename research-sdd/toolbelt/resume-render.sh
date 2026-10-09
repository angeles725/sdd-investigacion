#!/usr/bin/env bash
# resume-render.sh — render the prose resume handoff FROM resume-state JSON (kit issue #1274, slice 2).
#
# Read-only and derived: it consumes a research-sdd.resume-state/v1 document (see resume-state.v1.md) and prints
# concise Markdown. It invents nothing and writes nothing (propose-never-apply). A null or missing value is
# rendered as "unknown", never as 0 or "none": prs null + a non-ok prs_status prints "PR list unknown: <status>".
# Documented exceptions (resume-render.v1.md): an EXPLICIT repo.remote:null renders "none configured" and an
# EXPLICIT worktree branch:null renders "detached HEAD" (that is how resume-state encodes them); a MISSING
# key is always unknown ("remote unknown", "branch unknown").
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
# RSDD-SELF-DIR (kit #1675): own directory from BASH_SOURCE with symlinks followed - never $0 or the caller's cwd.
_rsdd_s="${BASH_SOURCE[0]}"; _rsdd_n=0
while [ -L "$_rsdd_s" ] && [ "$_rsdd_n" -lt 40 ]; do _rsdd_n=$((_rsdd_n + 1)); _rsdd_t="$(readlink -- "$_rsdd_s")" || break; case "$_rsdd_t" in /*) _rsdd_s="$_rsdd_t" ;; *) _rsdd_s="$(dirname -- "$_rsdd_s")/$_rsdd_t" ;; esac; done
_RSDD_SELF="$(cd -- "$(dirname -- "$_rsdd_s")" && pwd -P)"; unset _rsdd_s _rsdd_n _rsdd_t
HERE="$_RSDD_SELF"
SCHEMA="research-sdd.resume-state/v1"

json_src=""; json_given=0; fwd=()
while [ $# -gt 0 ]; do
  case "$1" in
    --json)
      [ $# -ge 2 ] || usage
      [ -n "$2" ] || { echo "resume-render.sh: --json requires a non-empty FILE or '-'" >&2; exit 2; }
      json_given=1; json_src="$2"; shift 2 ;;
    --cwd|--base-ref) [ $# -ge 2 ] || usage; fwd+=("$1" "$2"); shift 2 ;;
    --no-gh) fwd+=("$1"); shift ;;
    -h|--help) echo "$usage_text"; exit 0 ;;
    *) echo "resume-render.sh: unknown argument: $1" >&2; usage ;;
  esac
done
if [ "$json_given" -eq 1 ] && [ "${#fwd[@]}" -gt 0 ]; then
  echo "resume-render.sh: --cwd/--base-ref/--no-gh apply to resume-state.sh and cannot be combined with --json" >&2; exit 2
fi

command -v jq >/dev/null 2>&1 || { echo "DEGRADED: jq not found; cannot render the resume handoff" >&2; exit 3; }

tmp="$(mktemp)" || { echo "resume-render.sh: mktemp failed" >&2; exit 2; }
trap 'rm -f "$tmp"' EXIT
if [ "$json_given" -eq 0 ]; then
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
  cat -- "$json_src" > "$tmp"
fi

[ -s "$tmp" ] || { echo "resume-render.sh: empty input (no JSON document)" >&2; exit 2; }
# Count documents first (-s): a stream ending in null/false would otherwise fail `jq -e .` and read as malformed.
ndocs="$(jq -s length "$tmp" 2>/dev/null)" || { echo "resume-render.sh: malformed JSON input" >&2; exit 2; }
[ "$ndocs" = 0 ] && { echo "resume-render.sh: empty input (no JSON document)" >&2; exit 2; }
[ "$ndocs" = 1 ] || { echo "resume-render.sh: multiple JSON documents in the input (want exactly one)" >&2; exit 2; }
jq -e . "$tmp" >/dev/null 2>&1 || { echo "resume-render.sh: malformed JSON input" >&2; exit 2; }
got="$(jq -r '.schema? // "" | tostring' "$tmp" 2>/dev/null)"
[ "$got" = "$SCHEMA" ] || { echo "resume-render.sh: wrong schema: [$got] (want $SCHEMA)" >&2; exit 2; }
jq -e '(.worktrees|type)=="array" and (.branches|type)=="array" and (.base_ref|type)=="string"
  and all(.worktrees[]; type=="object") and all(.branches[]; type=="object")
  and ((.repo // {})|type)=="object"
  and (.prs==null or ((.prs|type)=="array" and all(.prs[]; type=="object")))' "$tmp" >/dev/null 2>&1 \
  || { echo "resume-render.sh: malformed document: worktrees/branches must be arrays of objects, repo an object, prs null or an array of objects, base_ref a string" >&2; exit 2; }

# Render into a buffer: stdout stays empty on any render failure (rc 2 contract).
out="$(mktemp)" || { echo "resume-render.sh: mktemp failed" >&2; exit 2; }
trap 'rm -f "$tmp" "$out" "$out.err"' EXIT
jq -r '
  def cnt(l; v): if v == null then l + " unknown" else l + " " + (v|tostring) end;
  def or_unknown(v): if v == null then "unknown" else (v|tostring) end;
  def sha(v): if v == null then "unknown" else (v|tostring|.[0:7]) end;
  def ab(o): cnt("ahead"; o.ahead) + " · " + cnt("behind"; o.behind);
  def wt:
    "- `" + or_unknown(.path) + "` — "
    + (if has("branch")|not then "branch unknown"
       elif .branch == null then "detached HEAD" else "branch `" + (.branch|tostring) + "`" end)
    + " @ " + sha(.head) + " · "
    + (if .exists != false and .exists != true then "existence unknown · " else "" end)
    + (if .exists == false
       then "DIRECTORY MISSING" + (if .prunable == true then " (prunable: `git worktree prune`)" else "" end)
            + " · dirty unknown · untracked unknown"
       else cnt("dirty"; .dirty) + " · " + cnt("untracked"; .untracked) end)
    + " · " + ab(.);
  def prs:
    if .prs == null or .prs_status != "ok" then
      "PR list unknown: " + ((.prs_status // "prs_status missing")|tostring)
      + (if .prs != null then " (inconsistent: a PR list is present but its status is not ok; not trusted)" else "" end)
    elif (.prs|length) == 0 then "No open PRs (gh answered with an empty list)."
    else ((.prs[] | "- #" + or_unknown(.number) + " `" + or_unknown(.branch) + "` " + or_unknown(.state) + " — " + or_unknown(.url)),
          (if .prs_truncated == true then "- PR list truncated at the gh limit: it may be incomplete."
           elif .prs_truncated == null then "- PR list completeness unknown (prs_truncated null or missing)." else empty end))
    end;
  "# Resume handoff",
  "",
  "Generated " + ((.generated_at // "unknown time")|tostring) + " · repo `" + ((.repo.toplevel // "unknown")|tostring) + "`"
    + " · remote " + (if ((.repo // {})|has("remote"))|not then "unknown"
       elif .repo.remote == null then "none configured" else "`" + (.repo.remote|tostring) + "`" end),
  "Base: `" + .base_ref + "` @ " + sha(.base_sha),
  "",
  "## Worktrees (" + (.worktrees|length|tostring) + ")",
  (if (.worktrees|length) == 0 then "None listed." else (.worktrees[] | wt) end),
  "",
  "## Loose branches (" + (.branches|length|tostring) + ")",
  (if (.branches|length) == 0 then "None: every local branch is checked out in a worktree."
   else (.branches[] | "- `" + or_unknown(.name) + "` @ " + sha(.head) + " · " + ab(.)) end),
  "",
  "## Open PRs",
  prs,
  "",
  "## Not derived",
  "Review receipts, in-flight workers and the next task have no git source; state them by hand."
' "$tmp" > "$out" 2> "$out.err"; rc=$?
if [ "$rc" -ne 0 ]; then
  echo "resume-render.sh: render failed: $(head -n 1 "$out.err")" >&2; rm -f "$out.err"; exit 2
fi
rm -f "$out.err"
cat "$out"
