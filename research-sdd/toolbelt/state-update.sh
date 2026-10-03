#!/usr/bin/env bash
# state-update.sh — propose-never-apply updater for the research-state envelope counters (kit issue #1284).
#
# Prints a unified diff that would bring each RESEARCH-STATE*.md envelope in line with what
# verify-state.sh recomputes from the corpus. It NEVER writes to the target: the human (or a reviewed
# `patch`) applies the diff.
#
# Owned fields (see state-update.v1.md): covered_blocks, investigable_open, blocked_open,
# requires_execution_open, deferred_open (the envelope counters verify-state CHECK A/B/C/E/F recompute from
# disk) and the number in the Stop-control prose line "read-only investigable: N" (SC-CROSS-CHECK). Every
# other line — hand-set envelope fields, known_gaps / gaps_closed, all prose — is never touched.
#
# HOW: the derivation is verify-state.sh ITSELF, not a copy. Its FAIL/WARN lines already carry the
# recomputed value (`envelope investigable_open=49 != 47 NEXT-eligible ...`); this script runs verify-state
# once over the target, parses exactly those lines, and substitutes the recomputed value into the ORIGINAL
# file (other lines keep their text and position). The proposal therefore cannot disagree with the lint, and
# a counter verify-state does not flag (e.g. a shared-global focus it reports INFO "unverifiable") is never
# proposed. The cost is a contract on verify-state's message wording; the suite pins every parsed form.
# (research-sdd-status.sh --sync-state was evaluated as the engine and rejected: it re-derives known_gaps /
# gaps_closed from the backlog table, which undercounts closed gaps tracked in prose — 65 -> 35 on a real
# focus — and seeds covered_blocks=0 for shared-global focuses, where verify-state certifies nothing.)
#
# Usage: state-update.sh <target-dir>
# Exit: 0 = no change proposed · 1 = change proposed (diff on stdout) · 2 = usage / no state file
#       3 = DEGRADED (takes precedence over 1; any diff already found is still printed): verify-state could not be
#           run / exited >= 2 / said nothing about a state file; a required tool (diff mktemp awk cmp) is missing or
#           errored; the state-file listing failed; two state files share a basename; a rewrite failed; or every
#           state file was skipped (nothing examined)
# stderr always ends with `checked= skipped= changed= degraded= unproposed=`: `unproposed` counts verify-state
# FAIL lines this tool does not own (it proposes nothing for them — exit 0 does NOT mean verify-state passes).
# Env: STATE_UPDATE_VERIFY overrides the path of verify-state.sh (test hook).
set -uo pipefail

checked=0; skipped=0; changed=0; degraded=0; unproposed=0; work=""
# SU-SUMMARY-TRAP: the summary is emitted on EVERY exit path (usage, absent, early DEGRADED, normal) and is
# always the LAST stderr line, because it is printed by the EXIT trap after every other message.
_summary() {
  printf 'state-update: checked=%s skipped=%s changed=%s degraded=%s unproposed=%s (propose-never-apply: nothing was written)\n' \
    "$checked" "$skipped" "$changed" "$degraded" "$unproposed" >&2
  [ -n "$work" ] && rm -rf "$work"
}
trap _summary EXIT

here="$(cd "$(dirname "$0")" && pwd)"
verify_sh="${STATE_UPDATE_VERIFY:-$here/verify-state.sh}"

target="${1:-}"
if [ "$#" -ne 1 ] || [ ! -d "$target" ]; then
  echo "usage: state-update.sh <target-dir>" >&2; exit 2
fi

_SFLIB="$here/lib/state-files.sh"
[ -f "$_SFLIB" ] || { echo "state-update: cannot find helper $_SFLIB" >&2; exit 3; }
# shellcheck source=lib/state-files.sh
. "$_SFLIB"
declare -F list_state_files >/dev/null 2>&1 || { echo "state-update: helper $_SFLIB failed to define list_state_files" >&2; exit 3; }

# SU-DEP-PROBE: a missing tool is a typed DEGRADED, never a silent "no change".
for _t in diff mktemp awk cmp; do
  command -v "$_t" >/dev/null 2>&1 || { echo "state-update: DEGRADED — required tool '$_t' not found" >&2; exit 3; }
done

_FPLIB="$here/lib/focus-prefix.sh"
[ -f "$_FPLIB" ] || { echo "state-update: cannot find helper $_FPLIB" >&2; exit 3; }
# shellcheck source=lib/focus-prefix.sh
. "$_FPLIB"
declare -F derive_focus_prefix >/dev/null 2>&1 || { echo "state-update: helper $_FPLIB failed to define derive_focus_prefix" >&2; exit 3; }

target="${target%/}"
# SU-LIST-FAIL: a failing listing helper or an untraversable target must not read as "no state files".
listing="$(list_state_files "$target")"; lrc=$?
if [ "$lrc" -ne 0 ] || [ ! -r "$target" ] || [ ! -x "$target" ]; then
  echo "state-update: DEGRADED — could not enumerate state files under $target (helper rc=$lrc)" >&2; exit 3
fi
states=()
[ -n "$listing" ] && mapfile -t states <<<"$listing"
if [ "${#states[@]}" -eq 0 ]; then
  echo "state-update: no RESEARCH-STATE*.md under $target" >&2; exit 2
fi

work="$(mktemp -d)" || { work=""; echo "state-update: DEGRADED — mktemp failed" >&2; exit 3; }

if [ ! -f "$verify_sh" ]; then
  echo "state-update: DEGRADED — cannot find $verify_sh" >&2; exit 3
fi
bash "$verify_sh" "$target" > "$work/verify.out" 2> "$work/verify.err"; vrc=$?
if [ "$vrc" -ge 2 ]; then   # SU-VERIFY-FAIL: 0 = consistent, 1 = findings; anything else is not a verdict
  echo "state-update: DEGRADED — verify-state exited $vrc: $(head -3 "$work/verify.err" | tr '\n' ' ')" >&2; exit 3
fi

# Parse verify-state's per-state sections into directives: SEEN/NOENV/UNPROPOSED <file>; SET <file> <key> <n>;
# PROSE <file> <n>. Only the exact forms below are owned (SU-PARSE); a FAIL line of any other shape is counted
# as UNPROPOSED, a WARN line of another shape is ignored.
awk '
  /^== verify-state: / { f=$0; sub(/^== verify-state: /,"",f); sub(/ \(target: .*$/,"",f); print "SEEN\t" f; next }
  f == "" { next }
  /no research-state\.v1 envelope/ { print "NOENV\t" f; next }
  $1 == "FAIL" || $1 == "WARN" {
    # envelope <key>=<declared> != <derived> ...   (CHECK A shared-global / per-focus, B, C, E-WARN, F)
    if ($2 == "envelope" && $4 == "!=" && $5 ~ /^[0-9]+$/) {
      split($3, kv, "=")
      if (kv[1]=="covered_blocks" || kv[1]=="investigable_open" || kv[1]=="blocked_open" || kv[1]=="requires_execution_open" || kv[1]=="deferred_open") { print "SET\t" f "\t" kv[1] "\t" $5; next }
    }
    # CHECK E FAIL: requires_execution_open=0 while N open requires-execution backlog gap(s) remain
    if ($1 == "FAIL" && $2 == "envelope" && $3 == "requires_execution_open=0" && match($0, / while [0-9]+ open requires-execution/)) {
      s=substr($0, RSTART, RLENGTH); sub(/^ while /, "", s); sub(/ .*/, "", s); print "SET\t" f "\trequires_execution_open\t" s; next }
    # CHECK F legacy: deferred_open missing while N deferred backlog gap(s) found
    if ($1 == "WARN" && $2 == "envelope" && $3 == "deferred_open" && $4 == "missing" && match($0, / while [0-9]+ deferred backlog/)) {
      s=substr($0, RSTART, RLENGTH); sub(/^ while /, "", s); sub(/ .*/, "", s); print "SET\t" f "\tdeferred_open\t" s; next }
    # SC-CROSS-CHECK: stop-control prose N, backlog derives M investigable gap(s)
    if ($1 == "FAIL" && $2 == "stop-control" && match($0, /backlog derives [0-9]+ investigable/)) {
      s=substr($0, RSTART, RLENGTH); sub(/^backlog derives /, "", s); sub(/ .*/, "", s); print "PROSE\t" f "\t" s; next }
    if ($1 == "FAIL") print "UNPROPOSED\t" f
  }' "$work/verify.out" > "$work/directives" || { echo "state-update: DEGRADED — parsing verify-state output failed" >&2; exit 3; }

# SU-DUP-BASENAME: verify-state names sections by basename; two state files sharing one cannot be told apart.
dups="$(for _s in "${states[@]}"; do printf '%s\n' "${_s##*/}"; done | sort | uniq -d)"
if [ -n "$dups" ]; then
  echo "state-update: DEGRADED — two state files share a basename; verify-state sections are ambiguous" >&2; exit 3
fi

for s in "${states[@]}"; do
  rel="${s#"$target"/}"
  base="$(basename "$s")"
  if ! grep -qxF "SEEN	$base" "$work/directives"; then   # SU-ABSENT-SECTION: verify-state said nothing about this file
    echo "state-update: DEGRADED — $rel: verify-state printed no section for it (not examined)" >&2
    degraded=$((degraded+1)); continue
  fi
  if grep -qxF "NOENV	$base" "$work/directives"; then   # SU-NO-ENVELOPE
    echo "state-update: SKIP $rel — no research-state.v1 envelope (seeding is research-sdd-status.sh --sync-state's job)" >&2
    skipped=$((skipped+1)); continue
  fi
  checked=$((checked+1))
  u="$(grep -cxF "UNPROPOSED	$base" "$work/directives")"
  if [ "$u" -gt 0 ]; then
    echo "state-update: NOTE [$rel] $u verify-state FAIL line(s) are not recomputable counters — nothing proposed for them" >&2
    unproposed=$((unproposed+u))
  fi
  sets="$(awk -F'\t' -v f="$base" '$1=="SET" && $2==f { printf "%s=%s ", $3, $4 }' "$work/directives")"
  prose="$(awk -F'\t' -v f="$base" '$1=="PROSE" && $2==f { print $3; exit }' "$work/directives")"
  # SU-ROOT-CORPUS-WIDE (kit #906): the un-suffixed RESEARCH-STATE.md of a multi-state corpus with no block
  # prefix for it in FOCUSES.md is "counted" by verify-state against EVERY block file in its directory — the
  # corpus-wide number, not this focus's. Writing it would satisfy the lint with a value that is not the
  # focus's count (fleet-measured: 266 -> 1193 on a 90-focus corpus), so covered_blocks is withheld.
  if [ "$base" = "RESEARCH-STATE.md" ] && [ "${#states[@]}" -gt 1 ] && [ -z "$(derive_focus_prefix "$s")" ] \
     && ! grep -Eq '^[ \t]*block_scope:[ \t]*shared-global' "$s" && [[ " $sets" == *" covered_blocks="* ]]; then
    sets="$(printf '%s' "$sets" | tr ' ' '\n' | grep -v '^covered_blocks=' | tr '\n' ' ')"
    unproposed=$((unproposed+1))   # SU-WITHHELD-COUNTED: verify-state flagged it and nothing is proposed for it
    echo "state-update: NOTE [$rel] covered_blocks withheld: un-suffixed root of a multi-state corpus with no FOCUSES.md block prefix (verify-state counts the corpus-wide total)" >&2
  fi
  [ -n "$sets$prose" ] || continue
  # SU-REBUILD: substitute in place; every other line keeps its text and position. An owned key that is
  # absent from the fence is appended before the closing fence (the verify-state "missing" form).
  awk -v sets="$sets" -v prose="$prose" '
    BEGIN { n=split(sets, kvs, " "); for (i=1;i<=n;i++) { split(kvs[i], p, "="); nv[p[1]]=p[2]; order[i]=p[1] } }
    /<!-- research-state.v1 -->/  { inb=1; print; next }
    /<!-- \/research-state.v1 -->/ { for (i=1;i<=n;i++) if (!(order[i] in seen)) print order[i] ": " nv[order[i]]; inb=0; print; next }
    inb { c=index($0,":"); if (c) { k=substr($0,1,c-1); gsub(/^[ \t]+|[ \t]+$/,"",k)
            if (k in nv) { seen[k]=1; cr=($0 ~ /\r$/) ? "\r" : ""; print substr($0,1,c) " " nv[k] cr; next } } }
    prose != "" && !pdone && tolower($0) ~ /read-only investigable\*?\*?:[ \t]*\*?\*?[0-9]+/ {
      if (match(tolower($0), /investigable\*?\*?:[ \t]*\*?\*?[0-9]+/)) {
        pre=substr($0,1,RSTART-1); seg=substr($0,RSTART,RLENGTH); post=substr($0,RSTART+RLENGTH)
        sub(/[0-9]+$/, prose, seg); $0=pre seg post; pdone=1 } }
    { print }
    END { if (prose != "" && !pdone) print "PROSE-UNMATCHED" > "/dev/stderr" }' "$s" > "$work/proposed" 2> "$work/awk.err" \
    || { echo "state-update: DEGRADED — $rel: rewriting failed" >&2; degraded=$((degraded+1)); continue; }
  # SU-PROSE-UNMATCHED: verify-state flagged the stop-control number but no line could be rewritten; that is
  # an unproposed finding, never a silent drop.
  if grep -qx 'PROSE-UNMATCHED' "$work/awk.err"; then
    echo "state-update: NOTE [$rel] stop-control prose is stale (backlog derives $prose) but no rewritable 'read-only investigable: N' line was found — nothing proposed for it" >&2
    unproposed=$((unproposed+1))
  fi
  # SU-CMP-DIFF-RC: cmp 0 = same, 1 = differ; diff -u must then exit 1. Any other code is a tool error, never
  # "no change" and never an empty proposal.
  cmp -s "$s" "$work/proposed"; crc=$?
  if [ "$crc" -eq 1 ]; then
    diff -u --label "a/$rel" --label "b/$rel" "$s" "$work/proposed" > "$work/diff.out" 2> "$work/diff.err"; drc=$?
    if [ "$drc" -ne 1 ]; then
      echo "state-update: DEGRADED — $rel: diff failed (rc=$drc): $(head -3 "$work/diff.err" | tr '\n' ' ')" >&2
      degraded=$((degraded+1)); continue
    fi
    cat "$work/diff.out"
    changed=$((changed+1))
  elif [ "$crc" -ne 0 ]; then
    echo "state-update: DEGRADED — $rel: cmp failed (rc=$crc)" >&2
    degraded=$((degraded+1))
  fi
done

if [ "$degraded" -gt 0 ]; then exit 3; fi   # SU-DEGRADED-EXIT
if [ "$checked" -eq 0 ]; then   # SU-NOTHING-CHECKED: every state file was skipped — no evidence was taken
  echo "state-update: DEGRADED — no state file with an envelope was examined" >&2; exit 3
fi
[ "$changed" -eq 0 ] || exit 1
exit 0
