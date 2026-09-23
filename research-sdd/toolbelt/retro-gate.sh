#!/usr/bin/env bash
# retro-gate.sh — §18 Stop-hook body: blocks once when research files advanced
# without a conforming retro (U17 / #479 — PR 2 of 2).
#
# Usage: retro-gate.sh <target>
#   Reads Claude Code Stop-hook JSON on stdin. Always exits 0 (hook contract).
#   BLOCK = stdout {"decision":"block","reason":"<actionable text>"}
#   ALLOW = exit 0, no JSON on stdout.
#
# §7: always prints a one-line state summary to STDERR (never silent).
# propose-never-apply: never writes to the target corpus; state files go under .claude/.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
KIT="$(cd "$SELF_DIR/.." && pwd)"

_usage() { printf 'Usage: %s <target>\n' "$(basename "$0")" >&2; }
if [ $# -ne 1 ]; then
  _usage; printf 'retro-gate: ERROR: missing <target>\n' >&2; exit 0
fi
TARGET="$(cd "$1" 2>/dev/null && pwd)" || {
  printf 'retro-gate: ERROR: target not found: %s\n' "$1" >&2; exit 0
}

# ── Load helpers ──────────────────────────────────────────────────────────────
_bf_lib="$SELF_DIR/lib/block-files.sh"
_rs_lib="$SELF_DIR/lib/retro-status.sh"
for _lib in "$_bf_lib" "$_rs_lib"; do
  [ -f "$_lib" ] || { printf 'retro-gate: ERROR: missing helper %s\n' "$_lib" >&2; exit 0; }
done
# shellcheck source=lib/block-files.sh
. "$_bf_lib"
# shellcheck source=lib/retro-status.sh
. "$_rs_lib"
declare -F block_file_filter >/dev/null 2>&1 || { printf 'retro-gate: block_file_filter not defined\n' >&2; exit 0; }
declare -F retro_is_excluded >/dev/null 2>&1 || { printf 'retro-gate: retro_is_excluded not defined\n' >&2; exit 0; }

# ── §18-EN3: auto issue-seeding on session close ──────────────────────────────

# _retro_is_seedable <path>: returns 0 when the retro has open deltas
# (review-status is pending/none/absent, or PARTIAL applied with unshipped rows).
_retro_is_seedable() {
  local rf="$1" sline
  sline="$(grep -m1 'review-status' "$rf" 2>/dev/null || true)"
  case "$sline" in
    *dismissed*) return 1 ;;
    *applied*)
      # PARTIAL applied = some rows still open
      case "$sline" in *PARTIAL*) return 0 ;; *) return 1 ;; esac ;;
    *) return 0 ;;  # pending / no marker = seedable
  esac
}

# SENTINEL-SEEDING-FUNC-START
_run_issue_seeding() {
  local target="$1" kit="$2"
  local seeder="$kit/toolbelt/stage-retro-issues.sh"

  # SENTINEL-GH-PROBE-START
  if ! command -v gh >/dev/null 2>&1; then
    printf 'retro-gate: WARN: gh not found — issue-seeding skipped (run %s <retro> --apply manually)\n' \
      "$seeder" >&2
    return 0
  fi
  if ! gh auth status >/dev/null 2>&1; then
    printf 'retro-gate: WARN: gh not authenticated — issue-seeding skipped (run gh auth login, then %s <retro> --apply manually)\n' \
      "$seeder" >&2
    return 0
  fi
  # SENTINEL-GH-PROBE-END

  if [ ! -f "$seeder" ]; then
    printf 'retro-gate: WARN: stage-retro-issues.sh not found at %s — seeding skipped\n' "$seeder" >&2
    return 0
  fi

  local created=0 skipped=0 failed=0 empty=0 absent=0 ran=0
  local rf seed_out seed_rc _c _s _f _summary _seed_reason _seed_failed _absent_typed
  local failed_list=""
  while IFS= read -r rf; do
    [ -n "$rf" ] || continue
    retro_is_excluded "$rf" && continue
    _retro_is_seedable "$rf" || continue
    ran=$((ran + 1))
    # SENTINEL-SEEDER-RC-START
    seed_out="$(bash "$seeder" "$rf" --apply 2>&1)"
    seed_rc=$?
    _seed_failed=0   # failure count from summary (PR #944 exit-2 format); 0 = use +1 fallback
    # Parse counts from the authoritative summary: line emitted by the seeder at end of --apply
    _summary="$(printf '%s' "$seed_out" | grep '^summary:' | tail -1)"
    if [ -n "$_summary" ]; then
      _c="$(printf '%s' "$_summary" | grep -oE 'created=[0-9]+' | cut -d= -f2)"
      _s="$(printf '%s' "$_summary" | grep -oE 'skipped-duplicate=[0-9]+' | cut -d= -f2)"
      _f="$(printf '%s' "$_summary" | grep -oE 'failed=[0-9]+' | cut -d= -f2)"
      created=$((created + ${_c:-0}))
      skipped=$((skipped + ${_s:-0}))
      _seed_failed="${_f:-0}"
    # SENTINEL-TYPED-OUTCOME-START
    # absent-input: retro file not found — §7 distinct from empty/no-match; checked regardless of rc
    elif printf '%s' "$seed_out" | grep -qE '^absent-input:'; then
      absent=$((absent + 1))
      printf 'retro-gate: WARN: seeder: absent-input for %s (retro not found — verify path)\n' \
        "$(basename "$rf")" >&2
    elif [ "$seed_rc" -eq 0 ]; then
      # Seeder exited 0 with no summary: empty-input (no delta section) or no-match (all shipped)
      if printf '%s' "$seed_out" | grep -qE '^(empty-input|no-match):'; then
        empty=$((empty + 1))
      else
        # Seeder exited 0 with no recognised typed outcome and no summary: line
        printf 'retro-gate: WARN: seeder exited 0 but no summary: line for %s\n' \
          "$(basename "$rf")" >&2
      fi
    # SENTINEL-TYPED-OUTCOME-END
    else
      # No summary: and seeder failed — count ^created: progress lines as fallback (§7)
      _c="$(printf '%s' "$seed_out" | grep -c '^created: ')" || _c=0
      created=$((created + ${_c:-0}))
      printf 'retro-gate: WARN: seeder exited %d for %s: no summary: line — counted %d partial-progress line(s)\n' \
        "$seed_rc" "$(basename "$rf")" "${_c:-0}" >&2
    fi
    _absent_typed=0
    printf '%s' "$seed_out" | grep -qE '^absent-input:' && _absent_typed=1 || true
    if [ "$seed_rc" -ne 0 ] && [ "$_absent_typed" -eq 0 ]; then
      # Use per-issue count from summary (PR #944 exit-2 path) or +1 for the invocation.
      # absent-input: exits non-zero but is already counted in absent — skip here.
      if [ "${_seed_failed:-0}" -gt 0 ]; then
        failed=$((failed + _seed_failed))
      else
        failed=$((failed + 1))
      fi
      failed_list="${failed_list:+$failed_list, }$(basename "$rf")"
      # Last non-progress line of seeder output as reason (bounded to 80 chars)
      _seed_reason="$(printf '%s' "$seed_out" | \
        grep -vE '^(created|skipped-duplicate|skipped-shipped|skipped-wrong-kit|planned-issue|summary|no-match):' | \
        tail -1 | cut -c1-80)"
      if [ -z "$_seed_reason" ]; then _seed_reason="(no output)"; fi
      printf 'retro-gate: WARN: seeder failed (exit %d) for %s: %s\n' \
        "$seed_rc" "$(basename "$rf")" "$_seed_reason" >&2
    fi
    # SENTINEL-SEEDER-RC-END
  # SENTINEL-FIND-STDERR-START
  # stderr not suppressed — traversal errors (permission denied, missing dir) are §7 signals
  done < <(find "$target" -maxdepth 4 -path '*/retros/*.md' \
           -not -path '*/.git/*' -not -iname '*index*.md')
  # SENTINEL-FIND-STDERR-END

  # SENTINEL-AGGREGATE-WARN-START
  if [ "$failed" -gt 0 ]; then
    printf 'retro-gate: WARN: seeding failed for %d retro(s): %s\n' "$failed" "$failed_list" >&2
  fi
  # SENTINEL-AGGREGATE-WARN-END
  printf 'retro-gate: issue-seeding: ran=%d created=%d skipped-dedup=%d empty=%d absent=%d failed=%d target=%s\n' \
    "$ran" "$created" "$skipped" "$empty" "$absent" "$failed" "$(basename "$target")" >&2
}
# SENTINEL-SEEDING-FUNC-END

# ── Pure-bash JSON string escaper (decision channel must not depend on jq) ────
_json_escape_reason() {
  local s="$1"
  local _dq='"'
  s="${s//\\/\\\\}"          # \ → \\  (must be first)
  s="${s//$_dq/\\$_dq}"     # " → \"
  s="${s//$'\n'/\\n}"       # newline → \n
  printf '%s' "$s"
}

# SENTINEL-JQ-PROBE-START
# ── Probe: jq required for JSON parsing ──────────────────────────────────────
if ! command -v jq >/dev/null 2>&1; then
  printf 'retro-gate: state=allow branch=degraded (jq missing — cannot read hook JSON) target=%s\n' \
    "$(basename "$TARGET")" >&2
  exit 0
fi
# SENTINEL-JQ-PROBE-END

# ── Read stdin JSON ───────────────────────────────────────────────────────────
_json=$(cat)
_session_id=$(printf '%s' "$_json" | jq -r '.session_id // empty' 2>/dev/null) || _session_id=""
_stop_hook_active=$(printf '%s' "$_json" | jq -r '.stop_hook_active // false' 2>/dev/null) || _stop_hook_active="false"

# SENTINEL-STOP-HOOK-ACTIVE-START
# ── (1) Loop-safety: check stop_hook_active FIRST ────────────────────────────
if [ "$_stop_hook_active" = "true" ]; then
  printf 'retro-gate: state=allow branch=loop-safety stop_hook_active=true target=%s\n' \
    "$(basename "$TARGET")" >&2
  exit 0
fi
# SENTINEL-STOP-HOOK-ACTIVE-END

_state_dir="$TARGET/.claude"
_blocked_file="$_state_dir/.rsdd-retro-blocked-${_session_id}"

# SENTINEL-BLOCK-ONCE-START
# ── (2) Block-once: allow if already blocked this session ─────────────────────
if [ -n "$_session_id" ] && [ -f "$_blocked_file" ]; then
  printf 'retro-gate: state=allow branch=block-once session=%s target=%s\n' \
    "$_session_id" "$(basename "$TARGET")" >&2
  exit 0
fi
# SENTINEL-BLOCK-ONCE-END

# ── Helper: check if a path is a research file (block/state/catalog/index) ───
_is_research_file() {
  local p="$1" base
  # block file (uses block_file_filter regex)
  if printf '%s\n' "$p" | block_file_filter >/dev/null 2>&1; then return 0; fi
  base="$(basename "$p")"
  case "$base" in
    RESEARCH-STATE*.md|CATALOG.md|INDEX.md) return 0 ;;
  esac
  return 1
}

# ── Session-start sha / file detection ───────────────────────────────────────
_session_file="$_state_dir/.rsdd-session-${_session_id}"
_session_sha=""
_degraded=0
if [ -n "$_session_id" ] && [ -f "$_session_file" ]; then
  _session_sha="$(cat "$_session_file" 2>/dev/null || echo '')"
fi
if [ -z "$_session_sha" ]; then
  printf 'retro-gate: WARN: no session-start sha (session file absent/empty); degraded check\n' >&2
  _degraded=1
fi

# ── Detect changed research files ────────────────────────────────────────────
_has_changed=0
_nb_mtime=0   # newest changed block mtime

# Part A: committed changes since session-start sha
if [ "$_degraded" -eq 0 ] && \
   git -C "$TARGET" rev-parse --verify "$_session_sha" >/dev/null 2>&1; then
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    full="$TARGET/$f"
    if _is_research_file "$full"; then
      _has_changed=1
      m="$(stat -c %Y "$full" 2>/dev/null || echo 0)"
      [ "${m:-0}" -gt "$_nb_mtime" ] && _nb_mtime="$m"
    fi
  done < <(git -C "$TARGET" diff --name-only "${_session_sha}..HEAD" 2>/dev/null)
fi

# Part B: uncommitted research files newer than the session-start state file
if [ -f "$_session_file" ]; then
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if _is_research_file "$f"; then
      _has_changed=1
      m="$(stat -c %Y "$f" 2>/dev/null || echo 0)"
      [ "${m:-0}" -gt "$_nb_mtime" ] && _nb_mtime="$m"
    fi
  done < <(find "$TARGET" -newer "$_session_file" -type f -name '*.md' \
           -not -path '*/.git/*' 2>/dev/null)
fi

# SENTINEL-ALLOW-NO-CHANGE-START
# ── (3) No changed research files and not degraded → allow ───────────────────
if [ "$_degraded" -eq 0 ] && [ "$_has_changed" -eq 0 ]; then
  printf 'retro-gate: state=allow branch=no-change target=%s\n' "$(basename "$TARGET")" >&2
  exit 0
fi
# SENTINEL-ALLOW-NO-CHANGE-END

# In degraded mode: scan all research files for the block mtime reference
if [ "$_degraded" -eq 1 ]; then
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    _is_research_file "$f" || continue
    m="$(stat -c %Y "$f" 2>/dev/null || echo 0)"
    [ "${m:-0}" -gt "$_nb_mtime" ] && _nb_mtime="$m"
  done < <(find "$TARGET" -type f -name '*.md' -not -path '*/.git/*' 2>/dev/null)
fi

# ── Find newest non-excluded retro ───────────────────────────────────────────
_newest_retro=""
_nr_mtime=0
while IFS= read -r rf; do
  [ -n "$rf" ] || continue
  retro_is_excluded "$rf" && continue
  m="$(stat -c %Y "$rf" 2>/dev/null || echo 0)"
  if [ "${m:-0}" -gt "$_nr_mtime" ]; then _nr_mtime="$m"; _newest_retro="$rf"; fi
done < <(find "$TARGET" -maxdepth 4 -path '*/retros/*.md' \
         -not -path '*/.git/*' -not -iname '*index*.md' 2>/dev/null)

_retro_label="${_newest_retro:-(none)}"
_n_changed="$([ "$_degraded" -eq 0 ] && printf '%s changed' "$_has_changed" || printf 'unknown (degraded)')"

# ── Block/allow decision ──────────────────────────────────────────────────────
VERIFY_RETRO="$SELF_DIR/verify-retro.sh"
_block_reason=""
_suggest_path="$TARGET/retros/$(date +%Y-%m-%d)-<focus>.md"

# SENTINEL-BLOCK-START
if [ "$_nr_mtime" -eq 0 ]; then
  # No retro at all
  # SENTINEL-ACTIONABLE-REASON-START
  _block_reason="§18 retro pending for $(basename "$TARGET"): run the SELF-RETROSPECTIVE (fresh-context retro agent) from $KIT/templates/retro.template.md → $_suggest_path, then stop. Checked: research file(s) changed, newest retro: none. Template: $KIT/templates/retro.template.md"
  # SENTINEL-ACTIONABLE-REASON-END
elif [ "$_nb_mtime" -gt "$_nr_mtime" ]; then
  # Newest block is newer than newest retro → retro is stale
  # SENTINEL-ACTIONABLE-REASON-START
  _block_reason="§18 retro pending for $(basename "$TARGET"): newest retro $(basename "$_newest_retro") is OLDER than newest changed block. Run the SELF-RETROSPECTIVE from $KIT/templates/retro.template.md → $_suggest_path, then stop. Template: $KIT/templates/retro.template.md"
  # SENTINEL-ACTIONABLE-REASON-END
else
  # Retro is newer than block — verify conformance
  # SENTINEL-VERIFY-RETRO-START
  if [ -f "$VERIFY_RETRO" ]; then
    _vr_out="$(bash "$VERIFY_RETRO" "$_newest_retro" 2>/dev/null)"
    _vr_rc=$?
    if [ "$_vr_rc" -eq 0 ]; then
      printf 'retro-gate: state=allow branch=retro-conforming retro=%s target=%s\n' \
        "$(basename "$_newest_retro")" "$(basename "$TARGET")" >&2
      # SENTINEL-SEEDING-CALL-START
      _run_issue_seeding "$TARGET" "$KIT"
      # SENTINEL-SEEDING-CALL-END
      exit 0
    fi
    # Non-conforming: embed verify-retro findings as actionable context
    _block_reason="§18 retro pending for $(basename "$TARGET"): $(basename "$_newest_retro") is non-conforming. Fix it (from $KIT/templates/retro.template.md) — missing elements: $_vr_out"
  else
    # verify-retro.sh absent → allow (cannot verify; log degraded)
    printf 'retro-gate: state=allow branch=no-verifier (verify-retro.sh absent) target=%s\n' \
      "$(basename "$TARGET")" >&2
    exit 0
  fi
  # SENTINEL-VERIFY-RETRO-END
fi

if [ -n "$_block_reason" ]; then
  # Write block-once state file
  if [ -n "$_session_id" ]; then
    mkdir -p "$_state_dir" 2>/dev/null || true
    printf '%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$_blocked_file" 2>/dev/null || true
  fi
  printf 'retro-gate: state=block branch=retro-pending changed=%s retro=%s target=%s\n' \
    "$_n_changed" "$(basename "$_retro_label")" "$(basename "$TARGET")" >&2
  # SENTINEL-PURE-BASH-EMITTER-START
  _reason_esc="$(_json_escape_reason "$_block_reason")"
  printf '{"decision":"block","reason":"%s"}\n' "$_reason_esc"
  # SENTINEL-PURE-BASH-EMITTER-END
fi
# SENTINEL-BLOCK-END
