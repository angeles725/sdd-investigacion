#!/usr/bin/env bash
# score-loop-transcript.sh — eval scorer for a research-sdd loop run (kit issue #993, WU5).
#
# Scores a loop run against a target corpus (a git repo) and, optionally, a Claude Code
# session transcript (JSONL), on four multi-model-prompt-profile criteria:
#
#   C1  continued past block 1 — >=2 "block commits" in the window, with no operator input
#       between consecutive ones (operator input = a genuine human turn in the transcript).
#       Without --transcript: the "no operator input between them" sub-check is n/a, but the
#       block-commit count is still reported (git alone is sufficient for the count).
#   C2  questions asked — count of assistant FINAL messages (the last assistant record before
#       the next operator turn, or before end-of-transcript) whose last non-empty line matches
#       `\?$|shall I|should I|do you want` (case-insensitive). n/a without --transcript.
#   C3  compaction — block commits before/after the first compaction event found in the
#       transcript. n/a without --transcript, or when the transcript has no compaction event
#       (harness has no log of one — a distinct, honestly-reported state, not a silent pass).
#   C4  STOP honored — the RETURN CONTRACT `STOP:` token (PROMPT-LOOP.md) is present as the
#       last line of the run's final return, research-sdd-status.sh reports 0 open (--next
#       returns STOP) and an empty campaign queue, AND no block commit lands after that STOP
#       moment. n/a without --transcript (the final return / STOP moment cannot be located).
#
# Usage:
#   score-loop-transcript.sh --corpus <dir> [--transcript <jsonl-file>]
#                            [--base-ref <ref>] [--since <date>] [--until <date>]
#
# --base-ref scopes the window to `<ref>..HEAD`; --since/--until further restrict by commit
# date (git log semantics). With none of the three, the window is the corpus's full history.
#
# Output: one line per criterion — `C<n> pass|fail|n/a|degraded <evidence>` — then one
# `SUMMARY pass=<n> fail=<n> n/a=<n> degraded=<n>` line.
#
# Exit: 0 = scored (individual criteria may be fail/n-a/degraded — this is an information
#           instrument, like census-target.sh / research-sdd-status.sh);
#       1 = operational failure (corpus missing / not a git repo / lib helper failure);
#       2 = bad args;
#       3 = degraded — git itself is unavailable, so no criterion can be measured at all.
#
# Anti-silent-zero (CLAUDE.md §7): every criterion distinguishes absent-input (no transcript
# given) from empty-input/no-match (transcript present, nothing found) from degraded (a
# required dependency is missing or the transcript could not be parsed) — never a bare silent
# zero. git is probed unconditionally; jq is probed only when --transcript is given (git alone
# answers C1's commit count).
#
# Overridable heuristics — DOCUMENTED, NOT authoritatively confirmed. The exact on-disk shape
# of a Claude Code session JSONL's "operator input" and "compaction boundary" records was not
# verified against a real harness build; both are exposed as env-var overrides so an operator
# can correct the heuristic without editing this script:
#   RSDD_BLOCK_COMMIT_REGEX   bash ERE for a block-commit subject line.
#                             Default: METHODOLOGY.md §17 convention `research(<target>): B<n> ...`
#   RSDD_OPERATOR_INPUT_JQ    jq boolean filter (applied to one parsed JSONL record) identifying
#                             a genuine human turn, as opposed to a harness-fed tool-result
#                             turn (which is also `type: "user"` in the Claude API message
#                             shape). Default: `type=="user"`, not `isMeta`, and the message
#                             content is a string or contains at least one `text` content block.
#   RSDD_COMPACT_JQ           jq boolean filter identifying a compaction-boundary record.
#                             Default: a `type:"system"` record with `subtype:"compact_boundary"`,
#                             OR any record with `isCompactSummary:true`, OR a message whose text
#                             matches "This session is being continued from a previous
#                             conversation" (case-insensitive) — the wording Claude Code is known
#                             to prepend to a post-compaction continuation turn.
#   RSDD_STATUS_SCRIPT        path to research-sdd-status.sh (default: the sibling script in
#                             this same toolbelt directory). Overridable so C4 can be tested
#                             against a stub without needing a fully-scaffolded corpus.
#
# This script never modifies the corpus (propose-never-apply, CLAUDE.md §8) — it only reads
# `git log` and, at most, invokes research-sdd-status.sh (itself read-only).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF' >&2
usage: score-loop-transcript.sh --corpus <dir> [--transcript <jsonl-file>]
                                 [--base-ref <ref>] [--since <date>] [--until <date>]
EOF
}

CORPUS=""
TRANSCRIPT=""
BASE_REF=""
SINCE=""
UNTIL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --corpus)
      [[ $# -ge 2 ]] || { echo "score-loop-transcript.sh: --corpus requires a value" >&2; usage; exit 2; }
      CORPUS="$2"; shift 2 ;;
    --transcript)
      [[ $# -ge 2 ]] || { echo "score-loop-transcript.sh: --transcript requires a value" >&2; usage; exit 2; }
      TRANSCRIPT="$2"; shift 2 ;;
    --base-ref)
      [[ $# -ge 2 ]] || { echo "score-loop-transcript.sh: --base-ref requires a value" >&2; usage; exit 2; }
      BASE_REF="$2"; shift 2 ;;
    --since)
      [[ $# -ge 2 ]] || { echo "score-loop-transcript.sh: --since requires a value" >&2; usage; exit 2; }
      SINCE="$2"; shift 2 ;;
    --until)
      [[ $# -ge 2 ]] || { echo "score-loop-transcript.sh: --until requires a value" >&2; usage; exit 2; }
      UNTIL="$2"; shift 2 ;;
    -h|--help)
      usage; exit 2 ;;
    *)
      echo "score-loop-transcript.sh: unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ -z "$CORPUS" ]]; then
  echo "score-loop-transcript.sh: --corpus is required" >&2
  usage
  exit 2
fi
if [[ -n "$TRANSCRIPT" && ! -f "$TRANSCRIPT" ]]; then
  echo "score-loop-transcript.sh: --transcript file not found: $TRANSCRIPT" >&2
  exit 2
fi

# --- Overridable defaults (see header) --------------------------------------------------------
BLOCK_COMMIT_REGEX="${RSDD_BLOCK_COMMIT_REGEX:-^research\([^)]+\): B[0-9]+}"  # RSDD-SLT-BLOCK-REGEX
QUESTION_REGEX="${RSDD_QUESTION_REGEX:-\?\$|shall I|should I|do you want}"    # RSDD-SLT-QUESTION-REGEX
STOP_TOKEN_REGEX="${RSDD_STOP_TOKEN_REGEX:-^STOP:}"                          # RSDD-SLT-STOP-REGEX
OPERATOR_INPUT_JQ="${RSDD_OPERATOR_INPUT_JQ:-(.type==\"user\") and ((.isMeta // false) | not) and (((.message.content|type)==\"string\") or (((.message.content|type)==\"array\") and ([.message.content[]? | select(.type==\"text\")] | length > 0)))}"
COMPACT_JQ="${RSDD_COMPACT_JQ:-(.type==\"system\" and (((.subtype // \"\")==\"compact_boundary\") or ((.isCompactSummary // false)))) or ((.isCompactSummary // false)) or (((.message.content // \"\") | tostring) | test(\"This session is being continued from a previous conversation\"; \"i\"))}"  # RSDD-SLT-COMPACT-JQ
STATUS_SCRIPT="${RSDD_STATUS_SCRIPT:-$SCRIPT_DIR/research-sdd-status.sh}"

# --- Dependency probes (§7: typed degraded, never a silent pass) ---------------------------
if ! command -v git >/dev/null 2>&1; then
  echo "score-loop-transcript.sh: degraded: git not found in PATH" >&2
  for c in C1 C2 C3 C4; do
    printf '%s degraded git-not-found\n' "$c"
  done
  printf 'SUMMARY pass=0 fail=0 n/a=0 degraded=4\n'
  exit 3
fi

if [[ ! -d "$CORPUS" ]]; then
  echo "score-loop-transcript.sh: corpus not found or not a directory: $CORPUS" >&2
  exit 1
fi
if ! git -C "$CORPUS" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "score-loop-transcript.sh: corpus is not a git repository: $CORPUS" >&2
  exit 1
fi

JQ_AVAILABLE=1
if [[ -n "$TRANSCRIPT" ]] && ! command -v jq >/dev/null 2>&1; then
  JQ_AVAILABLE=0
fi

iso_epoch() {
  # Prints an epoch integer for an ISO-8601 timestamp, or nothing (caller must check).
  date -d "$1" +%s 2>/dev/null
}

# --- Block commits in the window ------------------------------------------------------------
# Prints "epoch<TAB>iso<TAB>sha" lines, chronologically ascending.
BLOCK_TS_PARSE_ERRORS=0
get_block_commits() {
  local range="HEAD"
  [[ -n "$BASE_REF" ]] && range="${BASE_REF}..HEAD"
  local extra=()
  [[ -n "$SINCE" ]] && extra+=(--since="$SINCE")
  [[ -n "$UNTIL" ]] && extra+=(--until="$UNTIL")
  local sha ciso subj epoch
  while IFS=$'\t' read -r sha ciso subj; do
    [[ -z "$sha" ]] && continue
    if [[ "$subj" =~ $BLOCK_COMMIT_REGEX ]]; then
      epoch="$(iso_epoch "$ciso")"
      if [[ -z "$epoch" ]]; then
        BLOCK_TS_PARSE_ERRORS=$((BLOCK_TS_PARSE_ERRORS + 1))
        continue
      fi
      printf '%s\t%s\t%s\n' "$epoch" "$ciso" "$sha"
    fi
  done < <(git -C "$CORPUS" log --no-color --format='%H%x09%cI%x09%s' "${extra[@]}" "$range" -- . 2>/dev/null)
}

mapfile -t BLOCK_LINES < <(get_block_commits | sort -n -k1,1)
N_BLOCKS=${#BLOCK_LINES[@]}
declare -a BLOCK_EPOCH=()
for line in "${BLOCK_LINES[@]:-}"; do
  [[ -z "$line" ]] && continue
  BLOCK_EPOCH+=("${line%%$'\t'*}")
done
N_BLOCKS=${#BLOCK_EPOCH[@]}

# --- Transcript normalization (only when a transcript was given and jq is usable) -----------
TRANSCRIPT_TSV=""
TRANSCRIPT_PARSE_WARN=0
declare -a OPERATOR_EPOCH=()
declare -a FINAL_EPOCH=()
declare -a FINAL_LASTLINE=()
FIRST_COMPACTION_EPOCH=""

if [[ -n "$TRANSCRIPT" && "$JQ_AVAILABLE" -eq 1 ]]; then
  TRANSCRIPT_TSV="$(mktemp)"
  trap 'rm -f "$TRANSCRIPT_TSV"' EXIT
  NORM_JQ='
    map({
      ts: (.timestamp // empty),
      type: (.type // empty),
      is_operator: ('"$OPERATOR_INPUT_JQ"'),
      is_compaction: ('"$COMPACT_JQ"'),
      last_line: ((if (.message.content|type)=="string" then .message.content
                    elif (.message.content|type)=="array"
                      then ([.message.content[]? | select(.type=="text") | .text] | join("\n"))
                    else "" end)
                   | split("\n") | map(select(length>0))
                   | (if length>0 then .[-1] else "" end))
    })
    | map(select(.ts != null and .ts != ""))
    | sort_by(.ts)
    | .[]
    | [.ts, .type, (.is_operator|tostring), (.is_compaction|tostring), .last_line]
    | @tsv
  '
  if ! jq -r -s "$NORM_JQ" "$TRANSCRIPT" >"$TRANSCRIPT_TSV" 2>/dev/null; then
    TRANSCRIPT_PARSE_WARN=1
  fi

  pending_epoch=""
  pending_lastline=""
  have_pending=0
  while IFS=$'\t' read -r ts typ is_op is_cx last_line; do
    [[ -z "$ts" ]] && continue
    epoch="$(iso_epoch "$ts")"
    [[ -z "$epoch" ]] && continue

    if [[ -z "$FIRST_COMPACTION_EPOCH" && "$is_cx" == "true" ]]; then
      FIRST_COMPACTION_EPOCH="$epoch"
    fi

    if [[ "$is_op" == "true" ]]; then
      OPERATOR_EPOCH+=("$epoch")
      if [[ "$have_pending" -eq 1 ]]; then
        FINAL_EPOCH+=("$pending_epoch")
        FINAL_LASTLINE+=("$pending_lastline")
        have_pending=0
      fi
      continue
    fi

    if [[ "$typ" == "assistant" ]]; then
      pending_epoch="$epoch"
      pending_lastline="$last_line"
      have_pending=1
    fi
  done < "$TRANSCRIPT_TSV"
  if [[ "$have_pending" -eq 1 ]]; then
    FINAL_EPOCH+=("$pending_epoch")
    FINAL_LASTLINE+=("$pending_lastline")
  fi
fi

# --- Result accumulators ---------------------------------------------------------------------
N_PASS=0
N_FAIL=0
N_NA=0
N_DEGRADED=0

emit() {
  local id="$1" status="$2" evidence="$3"
  case "$status" in
    pass) N_PASS=$((N_PASS + 1)) ;;
    fail) N_FAIL=$((N_FAIL + 1)) ;;
    n/a) N_NA=$((N_NA + 1)) ;;
    degraded) N_DEGRADED=$((N_DEGRADED + 1)) ;;
  esac
  printf '%s %s %s\n' "$id" "$status" "$evidence"
}

transcript_unusable_reason() {
  if [[ -z "$TRANSCRIPT" ]]; then
    printf 'no transcript'
  elif [[ "$JQ_AVAILABLE" -eq 0 ]]; then
    printf 'degraded: jq not found in PATH — transcript parsing unavailable'
  elif [[ "$TRANSCRIPT_PARSE_WARN" -eq 1 ]]; then
    printf 'degraded: transcript did not parse cleanly as JSON'
  else
    printf ''
  fi
}

# --- C1: continued past block 1 --------------------------------------------------------------
c1() {
  if [[ "$N_BLOCKS" -eq 0 ]]; then
    emit C1 fail "0 block commits in window (0 candidate commits examined; ts-parse-errors=$BLOCK_TS_PARSE_ERRORS)"
    return
  fi
  if [[ -z "$TRANSCRIPT" ]]; then
    if [[ "$N_BLOCKS" -ge 2 ]]; then
      emit C1 n/a "$N_BLOCKS block commits in window; operator-input check n/a (no transcript)"
    else
      emit C1 fail "only $N_BLOCKS block commit in window (need >=2); operator-input check n/a (no transcript)"
    fi
    return
  fi
  if [[ "$JQ_AVAILABLE" -eq 0 || "$TRANSCRIPT_PARSE_WARN" -eq 1 ]]; then
    emit C1 degraded "$N_BLOCKS block commits in window; $(transcript_unusable_reason)"
    return
  fi
  if [[ "$N_BLOCKS" -lt 2 ]]; then
    emit C1 fail "only $N_BLOCKS block commit in window (need >=2)"
    return
  fi
  local gaps=0 i a b op
  for ((i = 0; i < N_BLOCKS - 1; i++)); do
    a="${BLOCK_EPOCH[$i]}"
    b="${BLOCK_EPOCH[$((i + 1))]}"
    for op in "${OPERATOR_EPOCH[@]:-}"; do
      [[ -z "$op" ]] && continue
      if [[ "$op" -gt "$a" && "$op" -lt "$b" ]]; then
        gaps=$((gaps + 1))
        break
      fi
    done
  done
  if [[ "$gaps" -eq 0 ]]; then
    emit C1 pass "$N_BLOCKS block commits, 0 operator turns between consecutive block commits"
  else
    emit C1 fail "$N_BLOCKS block commits but $gaps of $((N_BLOCKS - 1)) gap(s) had operator input between them"
  fi
}

# --- C2: questions asked -----------------------------------------------------------------------
c2() {
  if [[ -z "$TRANSCRIPT" ]]; then
    emit C2 n/a "no transcript"
    return
  fi
  if [[ "$JQ_AVAILABLE" -eq 0 || "$TRANSCRIPT_PARSE_WARN" -eq 1 ]]; then
    emit C2 degraded "$(transcript_unusable_reason)"
    return
  fi
  local total=${#FINAL_LASTLINE[@]}
  if [[ "$total" -eq 0 ]]; then
    emit C2 n/a "transcript has no assistant final messages (empty-input)"
    return
  fi
  local matches=0 first_match_idx=-1 idx=0 line
  shopt -s nocasematch
  for line in "${FINAL_LASTLINE[@]}"; do
    if [[ "$line" =~ $QUESTION_REGEX ]]; then
      matches=$((matches + 1))
      [[ "$first_match_idx" -eq -1 ]] && first_match_idx="$idx"
    fi
    idx=$((idx + 1))
  done
  shopt -u nocasematch
  if [[ "$matches" -eq 0 ]]; then
    emit C2 pass "0 of $total final returns end in a question"
  else
    emit C2 fail "$matches of $total final returns end in a question (first @ ${FINAL_EPOCH[$first_match_idx]})"
  fi
}

# --- C3: compaction ----------------------------------------------------------------------------
c3() {
  if [[ -z "$TRANSCRIPT" ]]; then
    emit C3 n/a "no transcript"
    return
  fi
  if [[ "$JQ_AVAILABLE" -eq 0 || "$TRANSCRIPT_PARSE_WARN" -eq 1 ]]; then
    emit C3 degraded "$(transcript_unusable_reason)"
    return
  fi
  if [[ -z "$FIRST_COMPACTION_EPOCH" ]]; then
    emit C3 n/a "no compaction event found in transcript"
    return
  fi
  local before=0 after=0 e
  for e in "${BLOCK_EPOCH[@]:-}"; do
    [[ -z "$e" ]] && continue
    if [[ "$e" -lt "$FIRST_COMPACTION_EPOCH" ]]; then
      before=$((before + 1))
    else
      after=$((after + 1))
    fi
  done
  if [[ "$after" -gt 0 ]]; then
    emit C3 pass "compaction detected; $before block commit(s) before, $after after"
  else
    emit C3 fail "compaction detected; $before block commit(s) before, 0 after (no continuation past compaction)"
  fi
}

# --- C4: STOP honored -------------------------------------------------------------------------
c4() {
  if [[ -z "$TRANSCRIPT" ]]; then
    emit C4 n/a "no transcript: cannot locate the final return or STOP moment"
    return
  fi
  if [[ "$JQ_AVAILABLE" -eq 0 || "$TRANSCRIPT_PARSE_WARN" -eq 1 ]]; then
    emit C4 degraded "$(transcript_unusable_reason)"
    return
  fi
  local total=${#FINAL_LASTLINE[@]}
  if [[ "$total" -eq 0 ]]; then
    emit C4 n/a "transcript has no assistant final messages (empty-input)"
    return
  fi
  local last_idx=$((total - 1))
  local stop_epoch="${FINAL_EPOCH[$last_idx]}"
  local stop_line="${FINAL_LASTLINE[$last_idx]}"

  local stop_present=0
  [[ "$stop_line" =~ $STOP_TOKEN_REGEX ]] && stop_present=1

  local status_default status_next
  status_default="$(bash "$STATUS_SCRIPT" "$CORPUS" 2>/dev/null)"
  status_next="$(bash "$STATUS_SCRIPT" "$CORPUS" --next 2>/dev/null)"

  local zero_open=0
  [[ "$status_next" =~ ^STOP\  ]] && zero_open=1

  local empty_queue=0 campaign_line pend act
  campaign_line="$(printf '%s\n' "$status_default" | grep -E 'campaign[[:space:]]*:' | head -n1)"
  if [[ -z "$campaign_line" ]]; then
    empty_queue=0
  elif [[ "$campaign_line" == *"none"* ]]; then
    empty_queue=1
  else
    pend="$(grep -oE 'pending=[0-9]+' <<<"$campaign_line" | grep -oE '[0-9]+')"
    act="$(grep -oE 'active=[0-9]+' <<<"$campaign_line" | grep -oE '[0-9]+')"
    if [[ "${pend:-x}" == "0" && "${act:-x}" == "0" ]]; then
      empty_queue=1
    fi
  fi

  local after_stop=0 e
  for e in "${BLOCK_EPOCH[@]:-}"; do
    [[ -z "$e" ]] && continue
    [[ "$e" -gt "$stop_epoch" ]] && after_stop=$((after_stop + 1))
  done

  if [[ "$stop_present" -eq 1 && "$zero_open" -eq 1 && "$empty_queue" -eq 1 && "$after_stop" -eq 0 ]]; then
    emit C4 pass "STOP token present; status --next: STOP; campaign queue empty; 0 block commits after STOP"
  else
    emit C4 fail "stop_token=$([ "$stop_present" -eq 1 ] && echo present || echo absent) status_next=$([ "$zero_open" -eq 1 ] && echo STOP || echo NOT-STOP) queue=$([ "$empty_queue" -eq 1 ] && echo empty || echo non-empty-or-unknown) commits_after_stop=$after_stop"
  fi
}

c1
c2
c3
c4
printf 'SUMMARY pass=%d fail=%d n/a=%d degraded=%d\n' "$N_PASS" "$N_FAIL" "$N_NA" "$N_DEGRADED"
exit 0
