# --- ISSUES-DUE gate (--next terminal) ---------------------------------------------------------
# When the NEXT-resolution loop yields STOP (no investigable gaps), probe each retro under
# the target for untracked deltas via reconcile-issues.sh.  If any exist, emit ISSUES-DUE
# instead of STOP so the caller knows to seed them as GitHub issues.
# Enumeration: matches sweep-retros.sh idiom (maxdepth 4, */retros/*.md, no .git, no *index*,
#              -type f) so nested corpus layouts (corpus/retros/, research/retros/) are visible.
# Anti-silent-zero §7: "couldn't look" (find error) is distinct from "found zero".
# Early-exit (R4-budget): on first untracked retro, emit ISSUES-DUE immediately and return —
#                 do NOT probe remaining retros; do NOT report a fleet-wide denominator.
#                 The count and path in the output are scoped to that one retro only.
# Aggregate budget: probing all clean retros is bounded by _IDG_AGGREGATE_BUDGET_SECS (default
#                 60s). If exceeded before all-clean is confirmed, emit the unverified marker.
# Degraded probe: reconcile-issues.sh ^degraded: on stderr → WARN, set unverified flag, continue;
#                 never break on one retro's error.
# Timeout (R4-SERIAL): each reconcile call is wrapped in `timeout` (or `gtimeout` on macOS;
#                 _IDG_RECONCILE_TIMEOUT_SECS, default 15s); exit 124 → unverified, WARN, continue.
#                 If neither `timeout` nor `gtimeout` is present, FAIL CLOSED for liveness: mark
#                 coverage unverified and skip ALL probes (unbounded calls risk --next never returning).
#                 _IDG_TIMEOUT_BIN (test hook): when set (even to empty), overrides auto-detection.
# Stdout contract: verified-clean → bare STOP; unverified-coverage (any cause) → STOP
#                 with the generic suffix `[issue-coverage: unverified]` (R4-DEGRADED); the
#                 specific cause is reported on stderr by the branch that set _idg_had_unverified.
# Operational failure: non-degraded reconcile error → DISTINCT WARN naming the real failure.
# PERF: retros with applied/dismissed marker are skipped (zero gh calls per such retro).
issues_due_gate() {
  local -a _idg_retros
  local _idg_had_unverified _idg_total _idg_can_probe
  local _ri _ri_out _ri_rc _n _n_rc _n_rev _ri_rev_out _ri_rev_rc _idg_retro _find_rc _sort_rc
  local _idg_cache_file _idg_gh_fetch_rc _idg_gh_fetch_out
  local _ri_err_content _find_out_tmp _find_err_tmp _ri_err_tmp _rs_tok
  local _idg_timeout_secs _idg_timeout_bin _idg_aggr_budget _idg_aggr_start
  _idg_had_unverified=0; _idg_can_probe=1; _idg_total=0

  # F3: enumerate retros using sweep-retros.sh idiom — maxdepth 4, */retros/*.md, no .git,
  # no *index*.md, -type f — so nested layouts (corpus/retros/, research/retros/) are visible.
  # F4 (§7): completeness is decided by find EXIT STATUS, not stderr-non-empty.
  # Harden mktemp: if it fails → unverified coverage; skip probing (redirections would fail).
  _find_out_tmp="$(mktemp)" || { _idg_had_unverified=1; _idg_can_probe=0  # IDG-ENUM-MKTEMP-GUARD
    printf 'WARN: mktemp failed for retro enumeration — marking coverage unverified\n' >&2; }
  _find_err_tmp=""
  if [ "$_idg_can_probe" -eq 1 ]; then
    _find_err_tmp="$(mktemp)" || { _idg_had_unverified=1; _idg_can_probe=0
      rm -f "$_find_out_tmp"
      printf 'WARN: mktemp failed for retro enumeration stderr — marking coverage unverified\n' >&2; }
  fi
  if [ "$_idg_can_probe" -eq 1 ]; then
    # IDG-ENUM-PRED: predicate is INTENTIONALLY IDENTICAL to sweep-retros.sh (same -maxdepth 4,
    # -path '*/retros/*.md', same exclusions); -type f is an additional safety guard not present
    # in sweep-retros.sh's loop (which naturally ignores non-files in its read body). "0 retros
    # found" here means the same as "0 retros" in the fleet enumerator — not a gate-specific
    # blind spot.
    find "$target" -maxdepth 4 -path '*/retros/*.md' \
      -not -path '*/.git/*' -not -iname '*index*.md' -type f \
      >"$_find_out_tmp" 2>"$_find_err_tmp"
    _find_rc=$?
    sort -o "$_find_out_tmp" "$_find_out_tmp"   # IDG-SORT-IN-PLACE
    _sort_rc=$?
    mapfile -t _idg_retros < "$_find_out_tmp"
    rm -f "$_find_out_tmp" "$_find_err_tmp"
    # F4 (§7): partial visibility (find exited non-zero) → unverified; DO NOT discard listed retros —
    # those paths ARE visible and must still be probed.  Stderr noise on a clean exit is not an error.
    if [ "$_find_rc" -ne 0 ]; then
      _idg_had_unverified=1  # IDG-FIND-EXIT-UNVERIFIED
      printf 'WARN: retro enumeration incomplete (find exit %s) — treating coverage as unverified\n' \
        "$_find_rc" >&2
    fi
    # R4-sort-silent-zero: sort failure (TMPDIR full, OOM, sort absent) may produce a truncated array;
    # the find-exit check above does not cover the sort stage.  Treat any non-zero sort exit as unverified.
    if [ "$_sort_rc" -ne 0 ]; then
      _idg_had_unverified=1  # IDG-SORT-EXIT-UNVERIFIED
      printf 'WARN: retro enumeration sort failed (exit %s) — treating coverage as unverified\n' \
        "$_sort_rc" >&2
    fi
    # absent-input or empty-input: no retros found → nothing to probe; fall through to unified decision.
    if [ "${#_idg_retros[@]}" -eq 0 ]; then
      _idg_can_probe=0
    fi
  fi

  if [ "$_idg_can_probe" -eq 1 ]; then
    _ri="$here/reconcile-issues.sh"
    if [ ! -x "$_ri" ]; then
      _idg_had_unverified=1  # reconcile unavailable → unverified coverage, not bare STOP
      _idg_can_probe=0
      printf 'WARN: reconcile-issues.sh not executable at %s — skipping issues gate\n' "$_ri" >&2
    fi
  fi

  if [ "$_idg_can_probe" -eq 1 ]; then
    # R4-SERIAL: probe for timeout binary once; use _IDG_RECONCILE_TIMEOUT_SECS env override (default 15s).
    _idg_timeout_secs="${_IDG_RECONCILE_TIMEOUT_SECS:-15}"
    _idg_timeout_bin=""
    if [ "${_IDG_TIMEOUT_BIN+x}" = "x" ]; then
      _idg_timeout_bin="$_IDG_TIMEOUT_BIN"  # IDG-TIMEOUT-BIN-OVERRIDE (test hook)
    elif command -v timeout >/dev/null 2>&1; then
      _idg_timeout_bin="timeout"  # IDG-TIMEOUT-AVAIL-CHECK
    elif command -v gtimeout >/dev/null 2>&1; then
      _idg_timeout_bin="gtimeout"  # IDG-GTIMEOUT-AVAIL-CHECK
    fi
    if [ -z "$_idg_timeout_bin" ]; then
      _idg_had_unverified=1  # IDG-TIMEOUT-ABSENT-FAIL-CLOSED
      printf 'WARN: timeout(1)/gtimeout not available — cannot bound reconcile calls; marking coverage unverified\n' >&2
    fi

    # R4-AGGREGATE-BUDGET: bound total wall time for verifying all retros are clean.
    # Started BEFORE the batch fetch so the batch fetch is within the bounded region.
    # The early-exit path (IDG-EARLY-EXIT) fires on the first untracked retro and returns immediately;
    # this budget gates only the all-clean verification path where every retro must be probed.
    # Override via _IDG_AGGREGATE_BUDGET_SECS (default 60s).
    _idg_aggr_budget="${_IDG_AGGREGATE_BUDGET_SECS:-60}"  # IDG-AGGREGATE-BUDGET
    _idg_aggr_start="$SECONDS"

    # BATCH PREFETCH (fast path): fetch all open issue bodies ONCE per --next terminal.
    # The batch gh call is timeout-wrapped (same per-call bound as per-retro probes), and the
    # aggregate budget starts above so the batch fetch is within the bounded region.
    # Bounded by --limit (default 5000; override via _IDG_BATCH_LIMIT) to cap page size.
    # On batch failure (any non-zero exit, including timeout exit 124): cache stays empty;
    # the loop below uses the per-retro FALLBACK path (each retro does its own bounded gh probe).
    # A stale cache is impossible: _idg_cache_file is a tmpfile created here and deleted after the loop.
    _idg_cache_file=""
    if [ -n "$_idg_timeout_bin" ]; then
      _idg_cache_file="$(mktemp)" || {
        _idg_had_unverified=1
        printf 'WARN: mktemp failed for issue-cache — marking coverage unverified\n' >&2
      }
      if [ -n "$_idg_cache_file" ]; then
        # IDG-BATCH-GH-CALL: one gh issue list call covers ALL retros in this --next terminal.
        # IDG-BATCH-GH-TIMEOUT-WRAP: batch call timeout-wrapped (same per-call bound as per-retro probes).
        _idg_gh_fetch_out="$("$_idg_timeout_bin" "$_idg_timeout_secs" gh issue list \
            --repo "angeles725/sdd-investigacion" \
            --state open \
            --json body \
            --limit "${_IDG_BATCH_LIMIT:-5000}" \
            --jq '.[].body' 2>/dev/null)"  # IDG-BATCH-LIMIT-PRESENT
        _idg_gh_fetch_rc=$?
        if [ "$_idg_gh_fetch_rc" -ne 0 ]; then
          # IDG-BATCH-FAILURE: any non-zero rc (incl. timeout 124) → clear cache; per-retro fallback.
          rm -f "$_idg_cache_file"; _idg_cache_file=""
          printf 'WARN: batch issue prefetch failed (exit %s) — falling back to per-retro reconcile\n' \
            "$_idg_gh_fetch_rc" >&2
        else
          printf '%s\n' "$_idg_gh_fetch_out" > "$_idg_cache_file"
        fi
      fi
    fi

    # PERF: source retro-status lib for pre-filtering applied/dismissed retros (avoids gh call).
    _rs_lib="$here/lib/retro-status.sh"
    if [ -f "$_rs_lib" ]; then
      # shellcheck source=lib/retro-status.sh
      . "$_rs_lib"
    fi

    _idg_total="${#_idg_retros[@]}"
    # Harden mktemp: if it fails we cannot safely capture stderr per-retro; mark coverage unverified.
    _ri_err_tmp="$(mktemp)" || { _idg_had_unverified=1; _ri_err_tmp=""; printf 'WARN: mktemp failed — cannot capture reconcile stderr; marking coverage unverified\n' >&2; }
    for _idg_retro in "${_idg_retros[@]}"; do
      # PERF: skip retros whose marker is applied/dismissed — no gh call needed.
      if declare -F retro_review_status >/dev/null 2>&1; then
        _rs_tok="$(retro_review_status "$_idg_retro")"
        case "$_rs_tok" in applied|dismissed) continue ;; esac
      fi

      # Guard: skip reconcile call if mktemp failed (stderr cannot be safely redirected).
      if [ -z "$_ri_err_tmp" ]; then continue; fi

      # R4-AGGREGATE-BUDGET: stop probing when wall budget is exceeded before confirming all-clean.
      # On first untracked retro, IDG-EARLY-EXIT returns immediately so this check is only
      # reached on the clean path where every retro needs to be verified.
      if (( (SECONDS - _idg_aggr_start) >= _idg_aggr_budget )); then  # IDG-AGGREGATE-EXCEEDED
        _idg_had_unverified=1
        printf 'WARN: aggregate reconcile budget (%ss) exceeded — marking coverage unverified\n' \
          "$_idg_aggr_budget" >&2
        break
      fi

      # F4/F5: capture reconcile stderr; do NOT discard into /dev/null.
      # R4-SERIAL: when no timeout binary is available, skip this probe (fail-closed for liveness);
      # _idg_had_unverified was already set in the availability check above.
      [ -z "$_idg_timeout_bin" ] && continue  # IDG-TIMEOUT-ABSENT-SKIP
      # IDG-BATCH-FALLBACK: on batch failure (_idg_cache_file empty) → per-retro gh probe (no SPOF).
      # IDG-BATCH-PASS-CACHE: on batch success (_idg_cache_file set) → use pre-fetched cache.
      if [ -n "$_idg_cache_file" ]; then
        # IDG-BATCH-PASS-CACHE: pass pre-fetched issue bodies; reconcile reads cache, no per-retro gh call.
        _ri_out="$("$_idg_timeout_bin" "$_idg_timeout_secs" "$_ri" --issues-cache "$_idg_cache_file" "$_idg_retro" 2>"$_ri_err_tmp")"  # IDG-TIMEOUT-WRAP
      else
        # IDG-BATCH-FALLBACK-PER-RETRO: batch failed; each retro does its own bounded gh probe.
        _ri_out="$("$_idg_timeout_bin" "$_idg_timeout_secs" "$_ri" "$_idg_retro" 2>"$_ri_err_tmp")"  # IDG-TIMEOUT-WRAP
      fi
      _ri_rc=$?
      _ri_err_content="$(cat "$_ri_err_tmp")"
      : > "$_ri_err_tmp"  # clear for next iteration

      if [ "$_ri_rc" -ne 0 ]; then
        if [ "$_ri_rc" -eq 124 ]; then
          # R4-SERIAL: reconcile timed out → unverified coverage; WARN, continue
          _idg_had_unverified=1
          printf 'WARN: reconcile-issues.sh timed out for %s — treating as unverified\n' \
            "$(basename "$_idg_retro")" >&2
        elif grep -qE '^degraded:' <<<"$_ri_err_content"; then
          # F5a: gh degraded → WARN + continue (fall through; don't break, don't block offline)
          _idg_had_unverified=1
          printf 'WARN: could not verify issue coverage (gh degraded) — seed manually\n' >&2
        else
          # F5b: operational failure — any non-zero exit not covered above is also unverified coverage.
          _idg_had_unverified=1  # IDG-OPFAIL-SENTINEL
          printf 'WARN: reconcile-issues.sh failed for %s (exit %s) — %s\n' \
            "$(basename "$_idg_retro")" "$_ri_rc" "${_ri_err_content:-no stderr}" >&2
        fi
        continue  # F5c: never break; accumulate from remaining retros
      fi
      # kit issue #1130 finding 1: reconcile-issues.sh's out-of-scope-marker guard now exits 0
      # (a corpus finding — the retro's own marker is mispositioned — not an operational failure
      # of the instrument, per CLAUDE.md §8). But rc=0 with zero ^untracked: lines would
      # otherwise fall through to the clean count below and read as "verified clean" — the exact
      # silent-zero shape §7 forbids, since this retro's rows were never actually classified.
      # Treat it as unverified coverage, the same bucket as an operational failure.
      if grep -qE '^out-of-scope-marker:' <<<"$_ri_err_content"; then
        _idg_had_unverified=1  # IDG-OOS-SENTINEL
        printf 'WARN: reconcile-issues.sh reported an out-of-scope review-status marker for %s — treating as unverified\n' \
          "$(basename "$_idg_retro")" >&2
        continue
      fi
      _n="$(printf '%s\n' "$_ri_out" | awk '/^untracked:/{n++} END{print n+0}')"  # IDG-UNTRACKED-PATTERN
      _n_rc=$?
      # Sweep: awk failure (OOM, absent) → count unreliable; treat as unverified, never as clean.
      if [ "$_n_rc" -ne 0 ]; then
        _idg_had_unverified=1  # IDG-AWK-COUNT-FAIL
        printf 'WARN: awk untracked-count failed for %s (exit %s) — treating as unverified\n' \
          "$(basename "$_idg_retro")" "$_n_rc" >&2
        continue
      fi
      # IDG-BATCH-UNTRACKED-REVERIFY: when the batch cache was used and this retro came back untracked,
      # a truncated/empty/rate-limited batch (or a page hitting the --limit cap) can produce a false
      # negative. Positive evidence (tracked) from the batch is trustworthy; negative evidence is not.
      # Re-verify with one per-retro narrowed gh query before emitting ISSUES-DUE.
      if [ "${_n:-0}" -gt 0 ] && [ -n "$_idg_cache_file" ]; then  # IDG-BATCH-UNTRACKED-REVERIFY
        _ri_rev_out="$("$_idg_timeout_bin" "$_idg_timeout_secs" "$_ri" "$_idg_retro" 2>"$_ri_err_tmp")"  # IDG-REVERIFY-TIMEOUT-WRAP
        _ri_rev_rc=$?
        _ri_err_content="$(cat "$_ri_err_tmp")"
        : > "$_ri_err_tmp"
        if [ "$_ri_rev_rc" -ne 0 ]; then
          if [ "$_ri_rev_rc" -eq 124 ]; then
            _idg_had_unverified=1
            printf 'WARN: re-verify timed out for %s — treating as unverified\n' \
              "$(basename "$_idg_retro")" >&2
          elif grep -qE '^degraded:' <<<"$_ri_err_content"; then
            _idg_had_unverified=1
            printf 'WARN: could not re-verify issue coverage (gh degraded) — seed manually\n' >&2
          else
            _idg_had_unverified=1
            printf 'WARN: re-verify failed for %s (exit %s) — %s\n' \
              "$(basename "$_idg_retro")" "$_ri_rev_rc" "${_ri_err_content:-no stderr}" >&2
          fi
          continue
        fi
        _n_rev="$(printf '%s\n' "$_ri_rev_out" | awk '/^untracked:/{n++} END{print n+0}')"
        if [ "${_n_rev:-0}" -eq 0 ]; then
          # Per-retro re-verify says tracked → batch was a false negative (truncation/lag) → not untracked.
          continue  # IDG-BATCH-REVERIFY-CLEAN
        fi
        # Both batch and re-verify say untracked → genuinely untracked → proceed to ISSUES-DUE.
        _n="$_n_rev"  # use the re-verified count
      fi
      if [ "${_n:-0}" -gt 0 ]; then  # ISSUES-DUE-GATE-COND
        # IDG-EARLY-EXIT: first retro with untracked deltas → emit ISSUES-DUE immediately and stop.
        # Do NOT probe remaining retros; do NOT report _idg_total as a denominator (includes
        # unprobed retros). Count and path are scoped to THIS retro only.
        [ -n "$_ri_err_tmp" ] && rm -f "$_ri_err_tmp"
        [ -n "$_idg_cache_file" ] && rm -f "$_idg_cache_file"
        printf 'ISSUES-DUE | %s untracked delta(s) in %s — seed: stage-retro-issues.sh %s --apply\n' \
          "$_n" "$_idg_retro" "$_idg_retro"
        return  # IDG-EARLY-EXIT
      fi
    done
    [ -n "$_ri_err_tmp" ] && rm -f "$_ri_err_tmp"
    [ -n "$_idg_cache_file" ] && rm -f "$_idg_cache_file"
  fi

  # Unified decision: unverified wins over verified-clean; verified-clean last.
  # Note: ISSUES-DUE is emitted early-exit (IDG-EARLY-EXIT) inside the loop above; it never
  # reaches this point.
  # R4-DEGRADED: distinguish unverified-coverage (degraded or timeout) from verified-clean.
  # Untracked wins over unverified (ISSUES-DUE already returned above when >0).
  if [ "$_idg_had_unverified" -gt 0 ]; then
    printf 'STOP | read-only-investigable exhausted (0) [issue-coverage: unverified]%s\n' "$_BU_SUFFIX"  # IDG-UNVERIFIED-MARKER
    terminal_clean_warn  # TC-WARN-CALL-UNVERIFIED
    return
  fi
  # no-match: retros exist, all deltas tracked (or empty retros with clean find) → verified-clean STOP
  _stop_exhausted
  terminal_clean_warn  # TC-WARN-CALL
}
