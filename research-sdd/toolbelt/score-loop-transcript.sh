#!/usr/bin/env bash
# score-loop-transcript.sh — eval scorer for a research-sdd loop run (kit issue #993, WU5).
# Round 3 (Opus re-review confirmed 9/10 round-1 items fixed; RDD approved round 2 with
# warnings; this round closes the remaining BLOCKER plus the RDD warnings and Opus minors):
# the operator-input filter, transcript-span handling, C3/C4 semantics, and the block-commit
# regex were recalibrated against three real Claude Code transcripts + corpora (niagara-
# research, blender-llm) and one real Codex rollout, all inspected read-only — see the PR.
#
# Scores a loop run against a target corpus (a git repo) and, optionally, a session transcript
# (JSONL), on four multi-model-prompt-profile criteria:
#
#   C1  continued past block 1 — >=2 "block commits" (weighted: a commit whose subject cites a
#       B<n>-B<m> range counts as (m-n+1) blocks, capped — see "Range weight cap" below) in the
#       window, with no operator input between consecutive block COMMITS (operator input = a
#       genuine human turn in the transcript, see "Operator input" below). Without --transcript:
#       the "no operator input between them" sub-check is n/a, but the block-commit count is
#       still reported (git alone answers it). degraded when any in-window block commit falls
#       outside the transcript's own time span (see "Transcript span" below), or when the
#       transcript's shape is unrecognized (see "Unrecognized transcript shape" below).
#   C2  questions asked — count of assistant FINAL messages (the last assistant record before
#       the next operator turn, or before end-of-transcript) whose FINAL PARAGRAPH (the last
#       contiguous run of non-empty lines) contains a question: any line matching
#       `\?[*_\x60]*$|shall I|should I|do you want` (case-insensitive, tolerating a markdown
#       emphasis/code-span closer right after the `?`), or a `¿...?` pair anywhere in that
#       paragraph. n/a without --transcript. degraded on an unrecognized transcript shape.
#       KNOWN LIMIT: a rhetorical question ("Is that surprising?") reads identically to a
#       genuine ask — this criterion cannot tell intent apart from phrasing, only phrasing.
#   C3  compaction — block commits before/after the first STRUCTURAL compaction event found in
#       the transcript (a `type:"system"`/`subtype:"compact_boundary"` record, or any record
#       with `isCompactSummary:true` — see "Compaction detection" below; free-text scanning for
#       the human-readable continuation banner was tried and dropped: the structural fields are
#       what real transcripts actually carry and free text is a second, redundant path to the
#       same signal). NO compaction found is the BEST outcome (nothing to survive) and reports
#       `pass (no compaction, N block(s))`, not n/a. n/a without --transcript. degraded when any
#       in-window block commit falls outside the transcript's own time span, or on an
#       unrecognized transcript shape.
#   C4  STOP honored — the RETURN CONTRACT `STOP:` token (PROMPT-LOOP.md) is present as the last
#       line of the run's final return (tolerating a leading backtick/`*`/`_`/`>` markdown
#       wrapper), research-sdd-status.sh reports 0 open (--next returns `STOP | ...`) and an
#       empty campaign queue, AND no block commit lands after that STOP moment. n/a without
#       --transcript (the final return / STOP moment cannot be located). degraded when
#       research-sdd-status.sh is missing, fails, or reports `STALE` (its own state is not
#       trustworthy enough to answer "0 open"), or on an unrecognized transcript shape. KNOWN
#       LIMIT (two-part): (1) the RETURN CONTRACT this token belongs to is defined by
#       PROMPT-LOOP.md's orchestrated `/loop` mode ONLY — an interactive chat session has no
#       reason to ever emit a literal `STOP:` line, so C4 is meaningful only for a run driven in
#       orchestrated mode. Measured on real transcripts: 0 of 1,650 text-bearing assistant
#       records' last-lines across three real sessions started with `STOP:`, even though two of
#       those three were self-paced `/loop` runs — see "C4 and delegated sub-agents" below for
#       why. (2) In orchestrated mode with a delegated sub-agent (PROMPT-LOOP.md's SubagentHandback
#       pattern), the RETURN-CONTRACT token typically lands in the SUB-AGENT's report, which
#       arrives in the main transcript as a `tool_result` block, not as the driver's own
#       assistant text — C4 only scans the driver's own final assistant message. See
#       `research-sdd/evals/profile-ab/PROTOCOL.md` for the chosen resolution (a driver
#       requirement, not a scorer change — see below).
#
# Operator input: a genuine human turn is `.type=="user"` with `.origin.kind=="human"` — the
# real, structural field Claude Code stamps on it. Everything else that is ALSO `type:"user"` in
# the Claude API message shape is explicitly NOT operator input: a tool-result feedback turn
# (`origin` absent/null — the overwhelming majority of `type:"user"` records in a real
# transcript), a background `task-notification`, a `peer` relay from another session, a `/loop`
# re-fire (`<command-message>loop</command-message>`), a built-in slash-command echo such as
# `/compact` or `/model` (also `origin:null`, same as a tool-result turn), and other hook/harness
# feedback such as `<local-command-stdout>`/`<bash-stdout>` wrapper tags — all of these have
# `origin.kind` unequal to `"human"` in real data, so the single `origin.kind=="human"`
# condition excludes all of them by construction; no per-category special-casing is needed or
# present. Round-1 measured this at ~60-70% of a real run's C1 "gaps" being false positives from
# exactly this confusion (the prior heuristic keyed on message-content shape, which tool-result/
# notification/hook turns share with genuine human turns).
#
# Unrecognized transcript shape (round 3, Opus-confirmed BLOCKER): a transcript from a harness
# that does not use the `.origin` field convention at all (a real Codex/`reasonix` rollout under
# `~/.codex/sessions/...` uses `.type=="response_item"` with a NESTED `.payload.role`, never a
# top-level `.origin`; `jq -c 'del(.origin)'` reproduces the same failure mode on a Claude Code
# transcript) makes `.origin.kind=="human"` false for EVERY record — every candidate operator
# turn silently reads as "not human", so C1's gap check finds zero gaps and C2's question scan
# starts from a wrongly-large "final messages" set, both scoring a clean, WRONG pass instead of
# refusing to score. Guard: if no record in the whole transcript carries a non-null `.origin`
# key at all, OR the transcript has zero recognized operator turns AND zero recognized assistant
# records (the second condition alone already catches a Codex rollout, whose top-level `.type`
# never equals `"user"`/`"assistant"`), every criterion reports `degraded unrecognized
# transcript shape` instead of scoring on data it cannot actually interpret. This is deliberately
# a BROAD refusal (any one of the two conditions is enough) — CLAUDE.md §7's "could it see what
# it was looking at" question, not just "did it look".
#
# Transcript span: the transcript's own [first_ts, last_ts] is the earliest and latest
# `.timestamp` across EVERY record it contains (any type — assistant, user, system boundary
# markers, attachments, ...), not just the operator/assistant subset. A block commit outside
# that span was not witnessed by this transcript at all — the transcript cannot answer "was
# there operator input near it" or "was it before/after compaction" for a commit it never saw,
# so C1/C3 report `degraded`, not a false pass or fail, whenever that happens, with the
# out-of-span count as evidence. Since round 3, [first_ts, last_ts] is ALSO the DEFAULT git log
# window when a transcript is given and none of --base-ref/--since/--until were passed (see
# "Usage" below) — so on a default invocation, an out-of-span commit is usually excluded by
# `git log` itself before the degrade check ever runs, and the check mainly fires when an
# operator EXPLICITLY widens the window (e.g. to also check for a block commit landing after
# the transcript ended — see "Usage" for that tradeoff).
#
# Compaction detection: STRUCTURAL fields only (see C3 above) — RSDD_COMPACT_JQ, overridable.
#
# Block-commit regex: subjects use METHODOLOGY.md §17's `research(<target>): ...` convention or
# the `block(<focus>): ...` convention (both accepted, round 3 — measured 35 real `block(...)`
# subjects in niagara-research, none of them retro/citation noise). A `docs(<x>): B<n> ...`
# subject is DELIBERATELY NOT accepted, even though real corpora use it for genuine block
# commits too (51 real occurrences in niagara-research): `docs(retros): B65-B69 §18
# retrospective — ...` is a retro SUMMARY citing an already-closed range, and unlike the
# `research(...)`/`block(...)` retro-summary case (see below), a `docs(retros): B<n>-B<m> ...`
# subject puts that range immediately after the prefix with no delimiter in between, so the
# region-cut heuristic below cannot tell it apart from a genuine multi-block `docs(...)` commit.
# Accepting `docs(` would have re-introduced exactly the miscounting bug the region cut exists
# to prevent; the match-rate figures in this header count only `research(`/`block(` subjects.
# The block reference does not always sit immediately after the colon (`research(niagara-
# research/wb-vendor-ux): bootstrap focus + B1054 ...` is a real subject) and a commit
# occasionally cites more than one block, either as an explicit range (`B1161-B1163`, weight 3,
# capped — see "Range weight cap" below) or as a bare mention elsewhere in the subject. This
# script accepts a `research(<scope>): `/`block(<scope>): ` prefix (RSDD_BLOCK_COMMIT_REGEX) and
# then looks for the block reference (RSDD_BLOCK_ID_REGEX, default `B([0-9]+)(-B([0-9]+))?`)
# only in the region of the subject BEFORE its first `(`, `—` (em dash), or `→` (arrow) —
# whichever comes first. That delimiter reliably separates "what was committed" from "the
# descriptive title/citations", which is what keeps a `§18 retro ... closes B867-B891` summary
# commit (a citation of blocks committed elsewhere, not a new 25-block commit) from being
# miscounted: its block range sits inside a trailing parenthetical, past the cut. Measured on
# real data (read-only): niagara-research 794/960 (82.7%) -> 811/960 (84.5%, round 2,
# `research(` only) -> 845/995 (84.9%, round 3, `research(`+`block(` combined); blender-llm
# 93/102 (91.2%) -> 97/102 (95.1%, round 2; no `block(`/`docs(` subjects observed there).
# KNOWN LIMIT: a
# citation-only commit that mentions an EXISTING block before any delimiter (e.g. "align B505
# CERT-web source citation with SOURCES.md") is indistinguishable from a real block commit by
# this heuristic and will be counted; this is a precision/recall tradeoff, not a bug, and is
# reported honestly here rather than claimed away.
#
# Range weight cap: a `B<n>-B<m>` range with `m-n > 50` is almost certainly not a real per-block
# range (a typo, a non-block numeric range, or a different citation shape this heuristic
# misread) — it is capped to weight 1 (counted as ONE block, not `m-n+1`) with a WARN on stderr
# naming the commit, rather than silently letting one malformed subject dominate N_BLOCKS.
#
# C4 and delegated sub-agents: this script deliberately does NOT scan `tool_result` blocks for
# the RETURN CONTRACT token (a sub-agent's report arrives in the driver's transcript as a
# `tool_result`, indistinguishable at a glance from a Bash/Read tool result without correlating
# `tool_use_id` back to a `Task`-shaped tool call — not a cheap check, and easy to get wrong on
# a transcript this script has not seen). Instead, `evals/profile-ab/PROTOCOL.md` REQUIRES the
# orchestrating driver's own final assistant message to repeat the token verbatim, never just
# relay/summarize the sub-agent's report. This is documented explicitly rather than silently
# assumed.
#
# Usage:
#   score-loop-transcript.sh --corpus <dir> [--transcript <jsonl-file>]
#                            [--base-ref <ref>] [--since <date>] [--until <date>]
#
# --base-ref scopes the window to `<ref>..HEAD`; --since/--until further restrict by commit
# date (git log semantics). With NONE of the three AND a transcript given, the window defaults
# to the transcript's own [first_ts, last_ts] span (round 3) — pass --since/--until explicitly
# (e.g. wider than the transcript) to also check for a block commit landing before/after the
# transcript's own coverage; that is now an opt-in widening, not the default. With none of the
# three and NO transcript, the window is the corpus's full history (unchanged).
#
# Output: one line per criterion — `C<n> pass|fail|n/a|degraded <evidence>` — then one
# `SUMMARY pass=<n> fail=<n> n/a=<n> degraded=<n>` line.
#
# Exit: 0 = scored (individual criteria may be fail/n-a/degraded — this is an information
#           instrument, like census-target.sh / research-sdd-status.sh);
#       1 = operational failure (corpus missing / not a git repo / `git log` itself failed,
#           e.g. a bad --base-ref — the failure is reported, never silently swallowed);
#       2 = bad args;
#       3 = degraded — a dependency this whole instrument needs (git, or a `date` that supports
#           `date -d <ISO-8601>`) is unavailable, so no criterion can be measured at all.
#
# Anti-silent-zero (CLAUDE.md §7): every criterion distinguishes absent-input (no transcript
# given) from empty-input/no-match (transcript present, nothing found) from degraded (a required
# dependency is missing, the transcript could not be parsed or its shape is unrecognized, a
# block commit falls outside the transcript's span, or research-sdd-status.sh itself is
# unusable) — never a bare silent zero. git and `date -d` are probed unconditionally; jq is
# probed only when --transcript is given (git alone answers C1's raw commit count). The number
# of candidate commits `git log` actually returned for the window is always reported (never a
# hardcoded literal), so "0 block commits" distinguishes an empty window from a populated one
# whose subjects simply did not match.
#
# Overridable heuristics — DOCUMENTED, NOT authoritatively confirmed for every harness. The
# Claude Code JSONL shapes below WERE verified read-only against three real session transcripts
# (see the PR); a different harness (e.g. Codex/`reasonix`) uses a different shape entirely (see
# "Unrecognized transcript shape" above) and these overrides will not make it recognized — they
# exist for a harness close enough to Claude Code's shape to need only a field-name correction:
#   RSDD_BLOCK_COMMIT_REGEX   bash ERE, TWO capture groups: 1 = the matched prefix keyword
#                             (`research`/`block`), 2 = everything after the `<prefix>(...): `
#                             colon. Default: `^(research|block)\([^)]+\): (.*)$`
#   RSDD_BLOCK_ID_REGEX       bash ERE applied to the cut region (see "Block-commit regex"
#                             above); capture group 1 = start block number, group 3 = end block
#                             number for a range. Default: `B([0-9]+)(-B([0-9]+))?`
#   RSDD_OPERATOR_INPUT_JQ    jq boolean filter (applied to one parsed JSONL record) identifying
#                             a genuine human turn. Default: `.type=="user" and
#                             ((.origin.kind // "")=="human")` — see "Operator input" above.
#   RSDD_COMPACT_JQ           jq boolean filter identifying a compaction-boundary record.
#                             Default: `(.type=="system" and (.subtype // "")=="compact_boundary")
#                             or (.isCompactSummary // false)` — see "Compaction detection" above.
#   RSDD_QUESTION_REGEX       bash ERE (case-insensitive) tested against each line of the final
#                             paragraph. Default: `\?[*_\x60]*$|shall I|should I|do you want`
#   RSDD_STOP_TOKEN_REGEX     bash ERE tested against the STOP line after stripping a leading
#                             markdown wrapper. Default: `^STOP:`
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
# Remember whether the caller set a window explicitly, BEFORE any auto-default below touches
# these variables — the auto-default (transcript span) only applies when none of the three were
# given (see "Transcript span" / "Usage" above).
WINDOW_EXPLICIT=0
[[ -n "$BASE_REF" || -n "$SINCE" || -n "$UNTIL" ]] && WINDOW_EXPLICIT=1

# --- Overridable defaults (see header) --------------------------------------------------------
BLOCK_COMMIT_REGEX="${RSDD_BLOCK_COMMIT_REGEX:-^(research|block)\([^)]+\): (.*)$}"  # RSDD-SLT-BLOCK-REGEX
BLOCK_ID_REGEX="${RSDD_BLOCK_ID_REGEX:-B([0-9]+)(-B([0-9]+))?}"                # RSDD-SLT-BLOCKID-REGEX
QUESTION_REGEX="${RSDD_QUESTION_REGEX:-\?[*_\`]*\$|shall I|should I|do you want}"  # RSDD-SLT-QUESTION-REGEX
STOP_TOKEN_REGEX="${RSDD_STOP_TOKEN_REGEX:-^STOP:}"                            # RSDD-SLT-STOP-REGEX
OPERATOR_INPUT_JQ="${RSDD_OPERATOR_INPUT_JQ:-(.type==\"user\") and ((.origin.kind // \"\")==\"human\")}"  # RSDD-SLT-OPERATOR-JQ
COMPACT_JQ="${RSDD_COMPACT_JQ:-(.type==\"system\" and (.subtype // \"\")==\"compact_boundary\") or (.isCompactSummary // false)}"  # RSDD-SLT-COMPACT-JQ
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
if [[ "$(date -d "1970-01-01T00:00:00Z" +%s 2>/dev/null)" != "0" ]]; then
  echo "score-loop-transcript.sh: degraded: 'date -d <ISO-8601>' is not supported by the date on PATH" >&2
  for c in C1 C2 C3 C4; do
    printf '%s degraded date-not-supported\n' "$c"
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

# --- block_id_region <rest-of-subject> ---------------------------------------------------------
# Prints the portion of <rest-of-subject> BEFORE its first '(', em dash '—', or arrow '→',
# whichever comes first (or the whole string, if none appear). See "Block-commit regex" above.
block_id_region() {
  local rest="$1" cut="${#1}" i
  i="${rest%%(*}";  [[ "$i" != "$rest" && ${#i} -lt "$cut" ]] && cut=${#i}
  i="${rest%%—*}";  [[ "$i" != "$rest" && ${#i} -lt "$cut" ]] && cut=${#i}
  i="${rest%%→*}";  [[ "$i" != "$rest" && ${#i} -lt "$cut" ]] && cut=${#i}
  printf '%s' "${rest:0:cut}"
}

# --- Transcript normalization (only when a transcript was given and jq is usable) -----------
# Runs BEFORE block-commit loading (round 3) so the default window (transcript span, see header)
# is known before `git log` runs.
TRANSCRIPT_TSV=""
TRANSCRIPT_PARSE_WARN=0
declare -a OPERATOR_EPOCH=()
declare -a FINAL_EPOCH=()
declare -a FINAL_PARA=()
FIRST_COMPACTION_EPOCH=""
TRANSCRIPT_FIRST_EPOCH=""
TRANSCRIPT_LAST_EPOCH=""
TRANSCRIPT_FIRST_ISO=""
TRANSCRIPT_LAST_ISO=""
ANY_ORIGIN_PRESENT=1

if [[ -n "$TRANSCRIPT" && "$JQ_AVAILABLE" -eq 1 ]]; then
  TRANSCRIPT_TSV="$(mktemp)"
  trap 'rm -f "$TRANSCRIPT_TSV"' EXIT
  # last_para is emitted as @base64, not @tsv-escaped raw text: @tsv's own escaping (\t/\n/\r/\\
  # as two-character sequences) cannot be reversed unambiguously in bash for text that itself
  # contains a literal backslash next to one of those letters (a real "\n" typed by a model, a
  # Windows path with a literal backslash) — base64 round-trips the exact bytes with no such
  # ambiguity, at the cost of one extra decode step below.
  NORM_JQ='
    def last_paragraph:
      split("\n") as $lines
      | ($lines | length) as $n
      | if $n == 0 then ""
        else
          (reduce range($n - 1; -1; -1) as $i
            ({done: false, acc: []};
              if .done then .
              elif ($lines[$i] | length) == 0 then
                (if (.acc | length) > 0 then .done = true else . end)
              else .acc = [$lines[$i]] + .acc
              end)
          ).acc | join("\n")
        end;
    map({
      ts: (.timestamp // empty),
      type: (.type // empty),
      is_operator: ('"$OPERATOR_INPUT_JQ"'),
      is_compaction: ('"$COMPACT_JQ"'),
      last_para_b64: ((if (.message.content|type)=="string" then .message.content
                    elif (.message.content|type)=="array"
                      then ([.message.content[]? | select(.type=="text") | .text] | join("\n"))
                    else "" end) | last_paragraph | @base64)
    })
    | map(select(.ts != null and .ts != ""))
    | sort_by(.ts)
    | .[]
    | [.ts, .type, (.is_operator|tostring), (.is_compaction|tostring), .last_para_b64]
    | @tsv
  '
  if ! jq -r -s "$NORM_JQ" "$TRANSCRIPT" >"$TRANSCRIPT_TSV" 2>/dev/null; then
    TRANSCRIPT_PARSE_WARN=1
  fi

  pending_epoch=""
  pending_para=""
  have_pending=0
  while IFS=$'\t' read -r ts typ is_op is_cx last_para_b64; do
    [[ -z "$ts" ]] && continue
    epoch="$(iso_epoch "$ts")"
    [[ -z "$epoch" ]] && continue
    last_para="$(printf '%s' "$last_para_b64" | base64 -d 2>/dev/null)"

    [[ -z "$TRANSCRIPT_FIRST_EPOCH" ]] && { TRANSCRIPT_FIRST_EPOCH="$epoch"; TRANSCRIPT_FIRST_ISO="$ts"; }
    TRANSCRIPT_LAST_EPOCH="$epoch"
    TRANSCRIPT_LAST_ISO="$ts"

    if [[ -z "$FIRST_COMPACTION_EPOCH" && "$is_cx" == "true" ]]; then
      FIRST_COMPACTION_EPOCH="$epoch"
    fi

    if [[ "$is_op" == "true" ]]; then
      OPERATOR_EPOCH+=("$epoch")
      if [[ "$have_pending" -eq 1 ]]; then
        FINAL_EPOCH+=("$pending_epoch")
        FINAL_PARA+=("$pending_para")
        have_pending=0
      fi
      continue
    fi

    if [[ "$typ" == "assistant" ]]; then
      pending_epoch="$epoch"
      pending_para="$last_para"
      have_pending=1
    fi
  done < "$TRANSCRIPT_TSV"
  if [[ "$have_pending" -eq 1 ]]; then
    FINAL_EPOCH+=("$pending_epoch")
    FINAL_PARA+=("$pending_para")
  fi

  if [[ "$TRANSCRIPT_PARSE_WARN" -eq 0 ]]; then
    if ! jq -e -s 'any(.[]; has("origin") and (.origin != null))' "$TRANSCRIPT" >/dev/null 2>&1; then
      ANY_ORIGIN_PRESENT=0
    fi
  fi
fi

# --- Unrecognized transcript shape (round 3 BLOCKER fix) -------------------------------------
# See header. Computed once here; every criterion checks it before scoring.
UNRECOGNIZED_SHAPE=0
if [[ -n "$TRANSCRIPT" && "$JQ_AVAILABLE" -eq 1 && "$TRANSCRIPT_PARSE_WARN" -eq 0 ]]; then
  if [[ "$ANY_ORIGIN_PRESENT" -eq 0 ]]; then
    UNRECOGNIZED_SHAPE=1
  elif [[ "${#OPERATOR_EPOCH[@]}" -eq 0 && "${#FINAL_PARA[@]}" -eq 0 ]]; then
    UNRECOGNIZED_SHAPE=1
  fi
fi

# --- Default window = transcript span (round 3) -----------------------------------------------
if [[ "$WINDOW_EXPLICIT" -eq 0 && -n "$TRANSCRIPT_FIRST_ISO" ]]; then
  SINCE="$TRANSCRIPT_FIRST_ISO"
  UNTIL="$TRANSCRIPT_LAST_ISO"
fi

# --- Block commits in the window ------------------------------------------------------------
# Populates BLOCK_EPOCH (one entry per BLOCK — a B<n>-B<m> range contributes (m-n+1) copies of
# its commit's epoch, capped — see "Range weight cap" above — chronologically ascending after
# the final sort), CANDIDATE_COMMITS_EXAMINED (every commit git log returned for the window,
# matched or not — proves the instrument looked, CLAUDE.md §7), and BLOCK_TS_PARSE_ERRORS. Exits
# 1 (with git's own stderr) if `git log` itself fails, e.g. a bad --base-ref — never swallowed.
CANDIDATE_COMMITS_EXAMINED=0
BLOCK_TS_PARSE_ERRORS=0
declare -a BLOCK_EPOCH=()

load_block_commits() {
  local range="HEAD"
  [[ -n "$BASE_REF" ]] && range="${BASE_REF}..HEAD"
  local extra=()
  [[ -n "$SINCE" ]] && extra+=(--since="$SINCE")
  [[ -n "$UNTIL" ]] && extra+=(--until="$UNTIL")

  local git_out git_err rc
  git_out="$(mktemp)"; git_err="$(mktemp)"
  git -C "$CORPUS" log --no-color --format='%H%x09%cI%x09%s' "${extra[@]}" "$range" -- . >"$git_out" 2>"$git_err"
  rc=$?
  if [[ "$rc" -ne 0 ]]; then
    echo "score-loop-transcript.sh: git log failed (exit $rc) for window '$range': $(tr '\n' ' ' < "$git_err")" >&2
    rm -f "$git_out" "$git_err"
    exit 1
  fi
  rm -f "$git_err"

  local sha ciso subj rest region start end span weight epoch w
  while IFS=$'\t' read -r sha ciso subj; do
    [[ -z "$sha" ]] && continue
    CANDIDATE_COMMITS_EXAMINED=$((CANDIDATE_COMMITS_EXAMINED + 1))
    [[ "$subj" =~ $BLOCK_COMMIT_REGEX ]] || continue
    rest="${BASH_REMATCH[2]}"
    region="$(block_id_region "$rest")"
    [[ "$region" =~ $BLOCK_ID_REGEX ]] || continue
    start="${BASH_REMATCH[1]}"
    end="${BASH_REMATCH[3]:-$start}"
    span=$(( 10#$end - 10#$start ))
    if [[ "$span" -gt 50 ]]; then
      echo "score-loop-transcript.sh: WARN: implausible block range B$start-B$end in commit $sha (span >50) — counting as 1 block" >&2
      weight=1
    elif [[ "$span" -lt 0 ]]; then
      weight=1
    else
      weight=$((span + 1))
    fi
    epoch="$(iso_epoch "$ciso")"
    if [[ -z "$epoch" ]]; then
      BLOCK_TS_PARSE_ERRORS=$((BLOCK_TS_PARSE_ERRORS + 1))
      continue
    fi
    for ((w = 0; w < weight; w++)); do
      BLOCK_EPOCH+=("$epoch")
    done
  done < "$git_out"
  rm -f "$git_out"

  if [[ ${#BLOCK_EPOCH[@]} -gt 0 ]]; then
    mapfile -t BLOCK_EPOCH < <(printf '%s\n' "${BLOCK_EPOCH[@]}" | sort -n)
  fi
}
load_block_commits
N_BLOCKS=${#BLOCK_EPOCH[@]}

# --- out_of_span_count — block commits the transcript never witnessed -----------------------
out_of_span_count() {
  [[ -z "$TRANSCRIPT_FIRST_EPOCH" ]] && { printf '0'; return; }
  local n=0 e
  for e in "${BLOCK_EPOCH[@]:-}"; do
    [[ -z "$e" ]] && continue
    if [[ "$e" -lt "$TRANSCRIPT_FIRST_EPOCH" || "$e" -gt "$TRANSCRIPT_LAST_EPOCH" ]]; then
      n=$((n + 1))
    fi
  done
  printf '%s' "$n"
}

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

# --- strip_md_wrap <line> — strip a leading markdown emphasis/quote/code-span wrapper --------
strip_md_wrap() {
  local s="$1"
  [[ "$s" =~ ^[\`\*_\>[:space:]]*(.*)$ ]] && s="${BASH_REMATCH[1]}"
  printf '%s' "$s"
}

# --- C1: continued past block 1 --------------------------------------------------------------
c1() {
  # Unrecognized shape takes priority over every other C1 outcome, including an empty
  # block-commit window — a shape the scorer cannot interpret is not evidence of anything,
  # zero commits included (round 3 BLOCKER fix: this ordering matters on a real Codex rollout
  # scoped to a window with 0 candidate commits, which used to slip past the guard below and
  # report a plain "0 block commits" fail instead of the honest "cannot interpret this shape").
  if [[ "$UNRECOGNIZED_SHAPE" -eq 1 ]]; then
    emit C1 degraded "unrecognized transcript shape"
    return
  fi
  if [[ "$N_BLOCKS" -eq 0 ]]; then
    emit C1 fail "0 block commits in window ($CANDIDATE_COMMITS_EXAMINED candidate commit(s) examined; ts-parse-errors=$BLOCK_TS_PARSE_ERRORS)"
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
  local oos
  oos="$(out_of_span_count)"
  if [[ "$oos" -gt 0 ]]; then
    emit C1 degraded "$oos of $N_BLOCKS block commit(s) outside transcript span [$TRANSCRIPT_FIRST_ISO,$TRANSCRIPT_LAST_ISO]; cannot assess operator-input gaps for them"
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
  if [[ "$UNRECOGNIZED_SHAPE" -eq 1 ]]; then
    emit C2 degraded "unrecognized transcript shape"
    return
  fi
  local total=${#FINAL_PARA[@]}
  if [[ "$total" -eq 0 ]]; then
    emit C2 n/a "transcript has no assistant final messages (empty-input)"
    return
  fi
  local matches=0 first_match_idx=-1 idx=0 para line is_q
  shopt -s nocasematch
  for para in "${FINAL_PARA[@]}"; do
    is_q=0
    if [[ "$para" =~ ¿[^¿]*\? ]]; then
      is_q=1
    else
      while IFS= read -r line; do
        if [[ "$line" =~ $QUESTION_REGEX ]]; then
          is_q=1
          break
        fi
      done <<<"$para"
    fi
    if [[ "$is_q" -eq 1 ]]; then
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
  if [[ "$UNRECOGNIZED_SHAPE" -eq 1 ]]; then
    emit C3 degraded "unrecognized transcript shape"
    return
  fi
  local oos
  oos="$(out_of_span_count)"
  if [[ "$oos" -gt 0 ]]; then
    emit C3 degraded "$oos of $N_BLOCKS block commit(s) outside transcript span [$TRANSCRIPT_FIRST_ISO,$TRANSCRIPT_LAST_ISO]; cannot assess compaction timing for them"
    return
  fi
  if [[ -z "$FIRST_COMPACTION_EPOCH" ]]; then
    emit C3 pass "no compaction, $N_BLOCKS block(s)"
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
  if [[ "$UNRECOGNIZED_SHAPE" -eq 1 ]]; then
    emit C4 degraded "unrecognized transcript shape"
    return
  fi
  local total=${#FINAL_PARA[@]}
  if [[ "$total" -eq 0 ]]; then
    emit C4 n/a "transcript has no assistant final messages (empty-input)"
    return
  fi
  if [[ ! -r "$STATUS_SCRIPT" ]]; then
    emit C4 degraded "research-sdd-status.sh not found or not readable at $STATUS_SCRIPT"
    return
  fi

  local last_idx=$((total - 1))
  local stop_epoch="${FINAL_EPOCH[$last_idx]}"
  local stop_line
  stop_line="$(printf '%s\n' "${FINAL_PARA[$last_idx]}" | tail -n1)"
  stop_line="$(strip_md_wrap "$stop_line")"

  local stop_present=0
  [[ "$stop_line" =~ $STOP_TOKEN_REGEX ]] && stop_present=1

  # stdout and stderr are captured SEPARATELY (round 3 RDD fix): status_default/status_next
  # must be pure stdout, or a stderr WARN line landing before the real "STOP | ..."/"STALE | ..."
  # line in an interleaved capture would break the ^STOP/^STALE anchors below even though the
  # status script's actual answer is correct.
  local status_default status_next rc_default rc_next
  local c4_err
  c4_err="$(mktemp)"
  status_default="$(bash "$STATUS_SCRIPT" "$CORPUS" 2>"$c4_err")"; rc_default=$?
  status_next="$(bash "$STATUS_SCRIPT" "$CORPUS" --next 2>>"$c4_err")"; rc_next=$?
  rm -f "$c4_err"
  if [[ "$rc_default" -ne 0 || "$rc_next" -ne 0 ]]; then
    emit C4 degraded "research-sdd-status.sh failed (default exit=$rc_default, --next exit=$rc_next)"
    return
  fi
  if [[ "$status_next" =~ ^STALE ]]; then
    emit C4 degraded "research-sdd-status.sh --next reports STALE: $status_next"
    return
  fi

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
