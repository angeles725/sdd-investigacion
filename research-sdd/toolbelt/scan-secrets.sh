#!/usr/bin/env bash
# scan-secrets.sh — leaked-secret-VALUE scanner for a Research-SDD corpus (kit-audit #4).
#
# WHY: the SECRETS DISCIPLINE (PROMPT-LOOP, live-install targets) is a HARD invariant — cite a secret's
# STRUCTURE (where it lives, its format), NEVER its VALUE; a secret-bearing body is backed up to scratchpad
# and cited by `sha256` + byte-count. That was PROSE. This mechanizes the check: it greps the corpus's
# AUTHORED content for high-confidence secret VALUES that leaked in, WITHOUT crying wolf on the compliant
# convention — a `sha256`/hash citation is exempted BY CONTEXT (a bare hex value is only ignored when its
# line cites it as a hash), so a real hex-shaped token is not silently swallowed.
#
# SCOPE: authored Markdown (`*.md`) + high-risk CONFIG files (`.env*`, `*.conf/.ini/.properties/.cfg`,
# `config.*`, `credentials`) — the surfaces a researcher WRITES / drops a credential onto. It EXCLUDES
# vendored trees (node_modules/.venv) and decompiled-artifact trees (decompiled/vineflower/procyon/cfr/jadx):
# those are the OBJECT of study (decompiled protocol code legitimately contains `password`/`token`
# identifiers) or third-party code, where scanning is all false positives (empirically 14→1 on niagara).
# KNOWN GAPS (documented, not covered): other non-.md/non-config sources artifacts, `Authorization:
# Bearer/Basic` header shapes, and — in the ADVISORY tier only — all-alpha or all-digit literal passwords.
#
# Usage: scan-secrets.sh [--committed] <target-dir>
#   --committed  Scan ALL committed content reachable from HEAD: every unique file version across the full
#                git history (via rev-list|diff-tree → (blob, path) pairs → unique blob dedup → ONE LOOP:
#                git cat-file per unique blob into a temp file, then all HC patterns + advisory grep
#                simultaneously) plus all commit messages. Required by ensure-remote.sh so what is scanned
#                == what git push will send (including secrets deleted from HEAD but still reachable in
#                history). Requires git. Target must be the git repo root — refuses with exit 3 if it is a
#                subdirectory (pathspecs would silently miss files outside the subdir). Uses -a/--text so
#                all files are scanned, including those with NUL bytes. Uses --no-replace-objects so
#                refs/replace cannot hide secret commits from the scan (M1).
# Exit: 0 = clean-in-scope (or only advisory WARN) · 1 = a high-confidence secret VALUE leaked ·
#       2 = bad args · 3 = degraded (--committed: git/awk unavailable, not a git repo with commits,
#           target is not the repo root, mktemp failed, rev-list/log/cat-file failure, or 0 in-scope
#           blobs despite objects being listed).
set -uo pipefail
committed=0
if [ "${1:-}" = "--committed" ]; then
  committed=1
  shift
fi
target="${1:-}"
[ -n "$target" ] && [ -d "$target" ] || { echo "usage: scan-secrets.sh [--committed] <target-dir>" >&2; exit 2; }
here="$(cd "$(dirname "$0")" && pwd)"; KIT="$(cd "$here/.." && pwd)"

# Advisory keyword boundary pattern (PCRE). Defined here so the committed-mode probe block's
# ONE LOOP can use it; also used in the advisory section and default-mode grep.
# Boundaries: lookbehind excludes alnum (allows _), lookahead forbids a letter immediately after —
# snake_case names (aws_secret_access_key) are caught; camelCase substrings (saltedPassword) are not.
KWID='(?<![A-Za-z0-9])(?:password|passwd|secret|api[_-]?key|apikey|token)(?![A-Za-z])[A-Za-z0-9_]*'

# Temp files — cleaned on any exit.
_rev_obj_tmp=""; _blobs_list=""; _hc_hits_tmp=""; _adv_raw=""; _blob_tmp=""
_adv_dedup=""; _cmsg_tmp=""; _cmsg_hits_tmp=""; _nul_tmp=""
trap 'rm -f "$_rev_obj_tmp" "$_blobs_list" "$_hc_hits_tmp" "$_adv_raw" "$_blob_tmp" "$_adv_dedup" "$_cmsg_tmp" "$_cmsg_hits_tmp" "$_nul_tmp"' EXIT

# --committed mode: probe git and awk, verify the repo has at least one commit.
if [ "$committed" = 1 ]; then
  command -v git >/dev/null 2>&1 || {
    echo "DEGRADED: git not found — --committed mode requires git" >&2; exit 3; }
  # B3: probe awk before the filter pipeline so absence is caught with a typed message.
  command -v awk >/dev/null 2>&1 || {
    echo "DEGRADED: awk not found — --committed mode requires awk" >&2; exit 3; }
  git -C "$target" rev-parse --git-dir >/dev/null 2>&1 || {
    echo "DEGRADED: $target is not a git repository — --committed mode requires a git repo" >&2; exit 3; }
  git -C "$target" rev-parse --verify HEAD >/dev/null 2>&1 || {
    echo "DEGRADED: $target has no commits — --committed mode requires at least one commit" >&2; exit 3; }
  # MAJOR3: refuse when target is a subdirectory of its git repo. git pathspecs are resolved relative
  # to the working dir set by -C; a subdir target silently misses all committed files outside it.
  _toplevel="$(git -C "$target" rev-parse --show-toplevel 2>/dev/null)"
  _target_real="$(cd "$target" && pwd -P)"
  _toplevel_real="$(cd "$_toplevel" && pwd -P)"
  if [ "$_target_real" != "$_toplevel_real" ]; then
    echo "DEGRADED: $target is a subdirectory of its git repo (repo root: $_toplevel_real)." >&2
    echo "          Pass the repo root to scan the full committed history — pathspecs evaluated" >&2
    echo "          from a subdirectory silently miss all files outside $_target_real." >&2
    exit 3
  fi

  # Graft file check: M2: .git/info/grafts rewrites commit parentage, so the history visible to
  # this scan diverges from what git push will send (grafted commits may be hidden or reachable
  # commits excluded). Refuse rather than silently scan a subset.
  # M4: use --git-common-dir so the grafts file is found correctly in worktrees (where .git is a
  # file, not a directory) and repos with a custom GIT_DIR; the common dir is shared across worktrees.
  _git_common_dir="$(git -C "$target" rev-parse --git-common-dir 2>/dev/null)" || _git_common_dir=""
  # Absolutize: --git-common-dir returns an absolute path on git ≥ 2.7.0, but may be relative on
  # older versions. Prefix with the real target path when not already absolute.
  case "$_git_common_dir" in
    /*) ;;
    "") ;;
    *)  _git_common_dir="${_toplevel_real}/${_git_common_dir}" ;;
  esac
  if [ -n "$_git_common_dir" ] && [ -s "${_git_common_dir}/info/grafts" ]; then
    echo "DEGRADED: .git/info/grafts is non-empty — scan scope may diverge from what git push will send." >&2
    echo "          Remove or empty .git/info/grafts before scanning." >&2
    exit 3
  fi
  # M5: GIT_GRAFT_FILE env overrides the default grafts file location; if set, the info/grafts check
  # above is bypassed by git itself, so the scan scope may still diverge. Refuse when set.
  if [ -n "${GIT_GRAFT_FILE:-}" ]; then
    echo "DEGRADED: GIT_GRAFT_FILE is set — scan scope may diverge from what git push will send." >&2
    echo "          Unset GIT_GRAFT_FILE before scanning." >&2
    exit 3
  fi

  # B1+M1+M4: Enumerate ALL (blob, path) pairs across the full history using plumbing:
  #   git rev-list HEAD | git diff-tree --stdin -r -m --root --no-renames --no-abbrev -z --no-commit-id
  # This outputs, for each file change: ":<old-mode> <new-mode> <old-sha> <new-sha> <status>\0<path>\0"
  # RS="\0" in awk reads these NUL-terminated records directly (B5/NUL-safe: no tr '\0' '\n' needed).
  # M4 (plumbing enumeration): rev-list and diff-tree are plumbing commands — they ignore all log.*
  # user config (log.showSignature, log.diffMerges, etc.) that can inject noise into porcelain
  # git log output. This closes two fail-open leaks:
  #   log.showSignature=true: injects GPG verification text into git log output, which the awk
  #     state machine misreads as a path, causing the following real path to be dropped.
  #   log.diffMerges=off|combined|dense-combined: suppresses or changes merge-commit diff format
  #     in git log, hiding secrets added only in merge commits (evil-merge pattern).
  # -m on diff-tree: generates one diff per parent for merge commits, so evil-merge content (changes
  #   present in the merge commit but not in any parent) is covered via the parent-by-parent diffs.
  # --no-commit-id: suppresses the per-commit SHA header; output is only the diff entry pairs.
  # --no-replace-objects: refs/replace cannot hide secret commits from the scan (M1 fix).
  # B1 fix: unlike rev-list --objects, this emits every (blob, path) pair so an in-scope path
  #   alias for a blob first seen under an excluded path is never missed.
  # B3: mktemp checked; non-zero from either rev-list or diff-tree → DEGRADED.
  _rev_obj_tmp="$(mktemp)" || {
    echo "DEGRADED: mktemp failed — cannot create temp file for object list" >&2; exit 3; }
  git --no-replace-objects -C "$target" rev-list HEAD 2>/dev/null \
    | git --no-replace-objects -C "$target" \
        diff-tree --stdin -r -m --root --no-renames --no-abbrev -z --no-commit-id 2>/dev/null \
    > "$_rev_obj_tmp"
  _rev_obj_pstat=("${PIPESTATUS[@]}")
  # B3: any non-zero from rev-list or diff-tree is a failure.
  if [ "${_rev_obj_pstat[0]:-0}" -ne 0 ] || [ "${_rev_obj_pstat[1]:-0}" -ne 0 ]; then
    echo "DEGRADED: rev-list|diff-tree enumeration failed (rc=${_rev_obj_pstat[*]}) — cannot enumerate committed blobs" >&2
    exit 3
  fi
  # B5/NUL-safe: count NUL-terminated records (RS="\0") — avoids wc -l which splits on newlines,
  # breaking for paths with embedded newlines.
  _raw_lines="$(awk 'BEGIN{RS="\0"} END{print NR}' "$_rev_obj_tmp")"

  # Filter (blob, path) pairs by in-scope rules and dedup by blob sha (keep first in-scope path).
  # RS="\0": reads NUL-terminated records from diff-tree -z output directly (B5: NUL-safe).
  # State machine (A: leading-':' path fix + gitlink 160000 skip):
  #   Headers ("/^:/" with expect_path=0) carry the new-mode and new-side blob sha.
  #   Gitlink headers (new-mode 160000) are submodule commit SHAs — skip them (sha="").
  #   expect_path=1 after every header: the next non-empty record is ALWAYS the path, even if it
  #   starts with ':' (e.g. a file named ':notes.md' or ':dir/x.md').
  #   All-zero sha = deletion; skip it (blob no longer exists).
  # M4 (fail-closed awk): Rule 2 validates the header format; Rule 3 rejects any non-empty record
  #   that is neither a path (Rule 1) nor a valid header (Rule 2) — exits non-zero so the PIPESTATUS
  #   check below converts it to DEGRADED. With plumbing enumeration this should never fire in normal
  #   operation; it provides defense-in-depth if any config-injected noise were to slip through.
  _blobs_list="$(mktemp)" || {
    echo "DEGRADED: mktemp failed — cannot create blobs list temp file" >&2; exit 3; }
  awk '
BEGIN{RS="\0"; sha=""; expect_path=0}
# Rule 1: path record — when expect_path=1, the NEXT non-empty record is ALWAYS a path,
# even if it starts with ":" (e.g., a file named ":notes.md" or ":dir/x.md").
# This is the state-machine fix (A): rely on position not first character.
expect_path && length($0) > 0 {
  expect_path = 0
  if (sha == "") next   # gitlink (mode 160000) — sha cleared in Rule 2; skip path too
  path = $0; sha_cur = sha; sha = ""
  if (sha_cur ~ /^0+$/) next
  inc = 0
  if (path ~ /\.md$/) inc = 1
  if (path ~ /\.env$/) inc = 1
  if (path ~ /(^|\/)(\.env[^\/]+)$/) inc = 1
  if (path ~ /\.conf$/) inc = 1
  if (path ~ /\.ini$/) inc = 1
  if (path ~ /\.properties$/) inc = 1
  if (path ~ /\.cfg$/) inc = 1
  if (path ~ /(^|\/)config\./) inc = 1
  if (path ~ /(^|\/)credentials$/) inc = 1
  if (!inc) next
  # Exclude vendored/decompiled trees — nested OR top-level (minor m1 fix).
  if (path ~ /(^|\/)(node_modules|\.venv|venv|decompiled|vineflower|procyon|cfr|jadx)\//) next
  # B5/NUL-safe: escape embedded newlines in path before printing so the output is a single line
  # per entry — prevents the sort/dedup pipeline from splitting the path across two lines.
  gsub(/\n/, "\\n", path)
  print sha_cur " " path
  next
}
# Rule 2: diff header record — only reached when expect_path=0 (not waiting for a path).
# Format: ":old-mode new-mode old-sha new-sha status" — field 2=new-mode, field 4=new-side sha.
# Gitlink entries (new-mode 160000) are submodule commit SHAs, NOT blob SHAs — skip them (A).
# M4 fail-closed: validate the header format; a /^:/ record that does not match the expected
# 6-digit modes + 40-64 hex sha + status format is unexpected — exit non-zero for PIPESTATUS.
/^:/ {
  if (!/^:[0-7]{6} [0-7]{6} [0-9a-f]{40,64} [0-9a-f]{40,64} [A-Z][0-9]*$/) {
    print "DEGRADED: malformed diff-tree header: " substr($0, 1, 80) > "/dev/stderr"
    exit 1
  }
  if ($2 == "160000") { sha = ""; expect_path = 1; next }   # gitlink: clear sha, skip path
  sha = $4
  expect_path = 1
  next
}
# Rule 3: fail-closed — any non-empty record that reached here was neither consumed as a path
# (Rule 1 did not fire: expect_path was 0) nor as a valid header (Rule 2 did not fire: not /^:/).
# With rev-list|diff-tree plumbing this must never happen; if it does, exit non-zero for PIPESTATUS.
length($0) > 0 {
  print "DEGRADED: unexpected non-header record in diff-tree output: " substr($0, 1, 80) > "/dev/stderr"
  exit 1
}
' "$_rev_obj_tmp" | sort -k1,1 | awk '!seen[$1]++' > "$_blobs_list"
  # B3: check the filter pipeline's exit codes (awk/sort/dedup).
  _frc=("${PIPESTATUS[@]}")
  if [ "${_frc[0]:-0}" -ne 0 ] || [ "${_frc[1]:-0}" -ne 0 ] || [ "${_frc[2]:-0}" -ne 0 ]; then
    echo "DEGRADED: blob filter pipeline failed (rc=${_frc[*]}) — blob enumeration unreliable" >&2
    exit 3
  fi
  rm -f "$_rev_obj_tmp"; _rev_obj_tmp=""

  _total_blobs="$(wc -l < "$_blobs_list")"
  # B3: 0 in-scope blobs while the raw log produced output → pipeline likely failed silently.
  if [ "$_total_blobs" -eq 0 ] && [ "${_raw_lines:-0}" -gt 0 ]; then
    echo "DEGRADED: 0 in-scope blobs found but rev-list|diff-tree produced output — filter pipeline may have failed silently" >&2
    exit 3
  fi

  # ONE LOOP: read each unique blob once and run all HC patterns (combined 7-pattern grep) plus the
  # advisory grep simultaneously via a per-blob temp file. 1 git cat-file per blob instead of 8
  # (7 HC passes + 1 advisory), reducing subprocess spawns ~8-fold vs per-pattern loops.
  # Sequential greps on a local temp file — no async/ordering issues.
  # -naE: -n line numbers, -a text mode (catches NUL-byte .md files, and invalid-UTF-8 lines — B4),
  #       -E extended regex.
  # -e for each pattern: required so patterns starting with '-' (e.g. '-----BEGIN') are not parsed
  # as options. -naiP for advisory: case-insensitive PCRE.
  # B5: use awk via ENVIRON for path prefixing instead of sed "s|^|${bpath}…|" — sed is vulnerable
  # to paths containing the delimiter '|' or backreferences '\1'.  ENVIRON is safe for all chars.
  # B2: check git cat-file exit code; any failure → DEGRADED (empty content reads as clean otherwise).
  _hc_hits_tmp="$(mktemp)" || {
    echo "DEGRADED: mktemp failed — cannot create HC hits temp file" >&2; exit 3; }
  _adv_raw="$(mktemp)" || {
    echo "DEGRADED: mktemp failed — cannot create advisory raw temp file" >&2; exit 3; }
  _blob_tmp="$(mktemp)" || {
    echo "DEGRADED: mktemp failed — cannot create blob temp file" >&2; exit 3; }
  while IFS=' ' read -r bsha bpath; do
    bshort="${bsha:0:7}"
    # B2: check cat-file exit — a corrupt/missing blob must not silently read as empty (clean).
    if ! git --no-replace-objects -C "$target" cat-file blob "$bsha" > "$_blob_tmp" 2>/dev/null; then
      echo "DEGRADED: git cat-file blob ${bshort} failed — committed blob scan aborted" >&2
      exit 3
    fi
    # B4: -naE already includes -a (text mode), which treats the file as text and scans lines with
    # invalid UTF-8 bytes (Latin-1 \xf1, CRLF+\xe9) that grep -E without -a would silently drop.
    # B5: prefix via ENVIRON — safe for paths with '|', '\1', or other sed-special chars.
    grep -naE \
              -e '-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----' \
              -e 'A[KS]IA[0-9A-Z]{16}' \
              -e 'gh[pousr]_[A-Za-z0-9]{36,}' \
              -e 'xox[baprs]-[A-Za-z0-9-]{10,}' \
              -e 'AIza[0-9A-Za-z_-]{35}' \
              -e 'sk-[A-Za-z0-9]{20,}' \
              -e 'eyJ[A-Za-z0-9_=-]{6,}\.eyJ[A-Za-z0-9_=-]{6,}\.[A-Za-z0-9_=-]{6,}' \
              "$_blob_tmp" 2>/dev/null \
      | _SS_PFX="${bpath}@${bshort}:" awk 'BEGIN{p=ENVIRON["_SS_PFX"]}{print p $0}' \
      >> "$_hc_hits_tmp"
    # B3: PIPESTATUS[0]=grep (0=hit, 1=no-match are fine; ≥2=error); PIPESTATUS[1]=awk (nonzero=write/awk-error).
    _hc_pstat=("${PIPESTATUS[@]}")
    if [ "${_hc_pstat[0]:-0}" -ge 2 ] || [ "${_hc_pstat[1]:-0}" -ne 0 ]; then
      echo "DEGRADED: HC grep/awk pipeline failed (rc=${_hc_pstat[*]}) for blob ${bshort} — scan aborted" >&2
      exit 3
    fi
    grep -naiP -e "${KWID}\s*[=:]" "$_blob_tmp" 2>/dev/null \
      | _SS_PFX="${bpath}@${bshort}:" awk 'BEGIN{p=ENVIRON["_SS_PFX"]}{print p $0}' \
      >> "$_adv_raw"
    # B3: PIPESTATUS check for advisory grep/awk pipeline.
    _adv_pstat=("${PIPESTATUS[@]}")
    if [ "${_adv_pstat[0]:-0}" -ge 2 ] || [ "${_adv_pstat[1]:-0}" -ne 0 ]; then
      echo "DEGRADED: advisory grep/awk pipeline failed (rc=${_adv_pstat[*]}) for blob ${bshort} — scan aborted" >&2
      exit 3
    fi
  done < "$_blobs_list"
  rm -f "$_blob_tmp"; _blob_tmp=""
fi

# Corpus root (mirror verify-sources.sh): prefer the target root when it directly holds blocks, else the
# shallowest subdir that does (deterministic: depth, then lexical).
# In --committed mode the narrowing is SKIPPED — we scan the entire committed repo at HEAD.
corpus="$target"
if [ "$committed" = 0 ]; then
  # pipefail-audit: external `find` producer. Fleet max unobserved (root is usually empty or has 1
  # block file — output <200 B). Race onset for external producers: ~64 KB. Measured 0/400 trials
  # (200 quiet + 200 under load). A race would invert ! to TRUE, descending when blocks ARE at root.
  # verify-sources.sh:24 fixed the identical pattern with -print -quit; no fix here — unproven.
  if ! find "$target" -maxdepth 1 -type f \( -iname '*block*.md' -o -iname '*bloque*.md' \) -not -name '*.template.md' 2>/dev/null | grep -q .; then
    anchor="$(find "$target" -maxdepth 3 -type f \( -iname '*block*.md' -o -iname '*bloque*.md' \) -not -name '*.template.md' -not -path '*/.git/*' 2>/dev/null \
              | awk '{print gsub(/\//,"/") "\t" $0}' | sort -t"$(printf '\t')" -k1,1n -k2,2 | head -1 | cut -f2-)"
    [ -n "$anchor" ] && corpus="$(dirname "$anchor")"
  fi
fi

# File scope — grep flags for default mode. --committed mode uses the awk filter in the probe block.
INCL=(--include='*.md' --include='*.env' --include='.env*' --include='*.conf' --include='*.ini'
      --include='*.properties' --include='*.cfg' --include='config.*' --include='credentials')
EXCL=(--exclude-dir=.git --exclude-dir=node_modules --exclude-dir=.venv --exclude-dir=venv
      --exclude-dir=decompiled --exclude-dir=vineflower --exclude-dir=procyon --exclude-dir=cfr --exclude-dir=jadx)

if [ "$committed" = 1 ]; then
  echo "== scan-secrets --committed: $(basename "$target") =="
  echo "-- mode: committed — scanning ALL committed history reachable from HEAD (files + commit messages)"
else
  echo "== scan-secrets: $(basename "$target") =="
  [ "$corpus" != "$target" ] && echo "-- corpus root: ${corpus#"$target"/}/"
fi
# pipefail-audit: external `grep` producer on TARGETS.md. Fleet max 2,007 B (TRANE; 2 rows).
# Race onset for external producers: ~64 KB. Measured 0/200 trials. A race would silently skip
# the live-install notice (advisory only, not a gate). No fix — not reproduced.
if grep -iE "\b$(basename "$target")\b" "$KIT/TARGETS.md" 2>/dev/null | grep -qi 'live-install'; then
  echo "-- target registered LIVE-INSTALL: SECRETS DISCIPLINE is a hard invariant here (zero secrets exfiltrated)."
fi

rc=0; hits=0

# --- HIGH-CONFIDENCE secret VALUES (exit 1) -------------------------------------------------------
# Each pattern is specific enough to be near-zero false-positive; none matches a bare hex hash / sha256
# citation / byte dump, the load-bearing anti-FP.
echo "-- high-confidence secret values --"
scan() {  # <label> <extended-regex>
  local label="$1" re="$2" m
  if [ "$committed" = 1 ]; then
    # Filter pre-computed HC hits file (all 7 HC patterns scanned in the probe block ONE LOOP).
    # -aE: -a required so lines with invalid UTF-8 bytes (B4) are not dropped by grep under a
    # UTF-8 locale. The _hc_hits_tmp file was written with -naE (already UTF-8 safe), but the
    # re-filter here also needs -a for the same reason.
    # -e: explicit pattern flag required so PEM pattern (-----BEGIN…) is not parsed as an option.
    # Dedup + cap at 50; /dev/null fallback when probe block was skipped (e.g. teeth-deg path).
    while IFS= read -r m; do
      [ -z "$m" ] && continue
      echo "   LEAK!   $label — ${m}"
      rc=1; hits=$((hits+1))
    done < <(grep -aE -e "$re" "${_hc_hits_tmp:-/dev/null}" 2>/dev/null | sort -u | head -50)
  else
    while IFS= read -r m; do
      [ -z "$m" ] && continue
      echo "   LEAK!   $label — ${m}"
      rc=1; hits=$((hits+1))
    done < <(grep -rnoIE "${INCL[@]}" "${EXCL[@]}" -e "$re" "$corpus" 2>/dev/null | head -50)
  fi
}
scan "PEM PRIVATE KEY block"       '-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----'
scan "AWS access/session key id"   'A[KS]IA[0-9A-Z]{16}'
scan "GitHub token"                'gh[pousr]_[A-Za-z0-9]{36,}'
scan "Slack token"                 'xox[baprs]-[A-Za-z0-9-]{10,}'
scan "Google API key"              'AIza[0-9A-Za-z_-]{35}'
scan "OpenAI-style key"            'sk-[A-Za-z0-9]{20,}'
scan "JWT"                         'eyJ[A-Za-z0-9_=-]{6,}\.eyJ[A-Za-z0-9_=-]{6,}\.[A-Za-z0-9_=-]{6,}'
[ "$hits" -eq 0 ] && echo "   (none)"

# --- ADVISORY: credential assignments with a real-looking literal value (never changes exit) ------
# A leak the high-confidence patterns can't shape-match. Boundary is underscore-tolerant (PCRE lookbehind)
# so snake_case names (aws_secret_access_key, db_password) — the most common real convention — are caught,
# while camelCase substrings (saltedPassword) are not. Value extraction is non-greedy (\K, stops at ;,) so a
# multi-assignment line (password=X;timeout=30) keeps X, not 30. Deliberately conservative filters keep
# decompiled code from drowning the signal; reported as WARN only — a guess must never block the pipeline.
echo "-- possible credential assignments (advisory) --"
# Boundaries both sides of the keyword: a lookbehind that excludes alnum but allows `_`, and a lookahead
# `(?![A-Za-z])` that forbids a LETTER immediately after — so a secret word EMBEDDED in a snake_case name
# (aws_SECRET_access_key, DB_PASSWORD_value) is caught up to its `=`, while a camelCase substring
# (saltedPassword — `d` before it) OR an ordinary superstring word (tokenizer, secretariat, passwordless —
# a letter right after) is NOT. The trailing `[A-Za-z0-9_]*` then consumes the rest of the identifier.
# KWID is defined at the top of this script (before the probe block) so the ONE LOOP can use it.
warns=0
# In --committed mode output is deduplicated path:lineno:content (bshort stripped during dedup).
# In default mode grep output is path:lineno:content.
# Both: strip two colon-delimited fields (path:lineno:) to extract content.
if [ "$committed" = 1 ]; then
  # Advisory hits pre-computed in the probe block ONE LOOP (_adv_raw). Dedup here: strip @bshort so
  # same path:lineno:content across multiple blob versions deduplicates to one entry; cap at 200.
  # /dev/null fallback when probe block was skipped (e.g. teeth-deg path).
  _adv_dedup="$(mktemp)" || { echo "DEGRADED: mktemp failed — cannot create advisory dedup temp file" >&2; exit 3; }
  sed 's/@[0-9a-f][0-9a-f]*:/:/1' "${_adv_raw:-/dev/null}" | sort -u | head -200 > "$_adv_dedup"
  rm -f "$_adv_raw"; _adv_raw=""
else
  _adv_dedup="$(mktemp)" || { echo "DEGRADED: mktemp failed — cannot create advisory dedup temp file" >&2; exit 3; }
  grep -rniIP "${INCL[@]}" "${EXCL[@]}" -e "${KWID}\s*[=:]" "$corpus" 2>/dev/null | head -200 > "$_adv_dedup"
fi
while IFS= read -r line; do
  content="${line#*:*:}"
  val="$(printf '%s' "$content" | grep -oiP "${KWID}\s*[=:]\s*[\"']?\K[^\"';,\s]+" | head -1)"
  [ -z "$val" ] && continue
  case "$val" in '<'*|'$'*|'{'*|'*'*|'%'*) continue;; esac                       # placeholder / var / format
  case "$val" in *...*|*…*) continue;; esac                                      # truncated illustration (abc123…)
  # pipefail-audit (lines here through the hex check): all printf calls are single-arg bash
  # builtins. Bash-builtin single-arg printf is structurally immune to the SIGPIPE race — the
  # write completes before grep can exit, regardless of variable size (0/30 at 1 MB). No fix
  # needed for any of these sites. $content at line below is one grep output line (fleet max
  # 3,776 B in niagara-research) — still size-immune because it is a builtin printf arg.
  # Failure direction for line 107: suppressed continue → false ADVISORY WARN (noisy, not silent).
  printf '%s' "$val" | grep -q '[][()#]' && continue                             # markdown link / code structure
  printf '%s' "$val" | grep -qiE '^(x{3,}|redacted|changeme|example|placeholder|none|null|test|todo|your[_-]?)' && continue
  [ "${#val}" -ge 8 ] || continue                                                # too short to be a real secret
  printf '%s' "$val" | grep -qE '[A-Za-z]' && printf '%s' "$val" | grep -qE '[0-9]' || continue   # must mix (documented gap: all-alpha)
  # A bare hex value is a hash ONLY when its line cites it as one; otherwise a hex-shaped token is suspect.
  if printf '%s' "$val" | grep -qiE '^[0-9a-f]{32,64}$'; then
    printf '%s' "$content" | grep -qiE 'sha[0-9]*|md5|hash|checksum|digest|fingerprint' && continue
  fi
  echo "   WARN    $line"
  warns=$((warns+1))
done < "$_adv_dedup"
rm -f "$_adv_dedup"
[ "$warns" -eq 0 ] && echo "   (none)"

# --- COMMIT MESSAGES (full history, --committed mode only) -----------------------------------------
# A secret value typed into a commit message (or author/committer field) is never removed by a content
# redaction. Scans raw commit objects reachable from HEAD for the same high-confidence patterns.
# M1: --no-replace-objects ensures refs/replace cannot hide commit objects from the scan.
# M5: scan raw commit objects via rev-list|cat-file --batch instead of git log:
#   1. Immune to i18n.logOutputEncoding: git log re-encodes output (e.g. UTF-16), breaking grep on
#      ASCII patterns. cat-file returns the stored bytes directly, bypassing all output encoding.
#   2. Immune to i18n.commitEncoding: git log attempts to decode the stored encoding header and
#      produces garbage for unrecognised/mismatched encodings. cat-file returns the raw stored bytes,
#      which contain the token as written regardless of the declared encoding. (Closes #987 item 1.)
#   3. Covers author name, committer name, and all extra commit-object headers — git log --format=%s%n%b
#      omits these fields entirely, creating a gap for secrets typed into author/committer metadata.
if [ "$committed" = 1 ]; then
  echo "-- commit messages (full history) --"
  _cmsg_tmp="$(mktemp)" || { echo "DEGRADED: mktemp failed — cannot create commit message temp file" >&2; exit 3; }
  git --no-replace-objects -C "$target" rev-list HEAD 2>/dev/null \
    | git --no-replace-objects -C "$target" cat-file --batch 2>/dev/null \
    > "$_cmsg_tmp"
  _cmsg_rev_pstat=("${PIPESTATUS[@]}")
  # B3: any non-zero from rev-list or cat-file is a failure.
  if [ "${_cmsg_rev_pstat[0]:-0}" -ne 0 ] || [ "${_cmsg_rev_pstat[1]:-0}" -ne 0 ]; then
    echo "DEGRADED: rev-list|cat-file commit scan failed (rc=${_cmsg_rev_pstat[*]}) — commit scan incomplete" >&2
    rm -f "$_cmsg_tmp"; exit 3
  fi
  # M4 (retained): run grep to a temp file so its rc can be checked independently.
  # Previously the grep ran inside < <(... | head -20), where its exit code was unchecked —
  # a grep error (rc ≥ 2, e.g. invalid regex or read error) would silently produce no matches,
  # making the scan report "(none)" instead of DEGRADED.
  _cmsg_hits_tmp="$(mktemp)" || {
    echo "DEGRADED: mktemp failed — cannot create commit message hits temp file" >&2
    rm -f "$_cmsg_tmp"; exit 3; }
  grep -naE \
    -e '-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----' \
    -e 'A[KS]IA[0-9A-Z]{16}' \
    -e 'gh[pousr]_[A-Za-z0-9]{36,}' \
    -e 'xox[baprs]-[A-Za-z0-9-]{10,}' \
    -e 'AIza[0-9A-Za-z_-]{35}' \
    -e 'sk-[A-Za-z0-9]{20,}' \
    -e 'eyJ[A-Za-z0-9_=-]{6,}\.eyJ[A-Za-z0-9_=-]{6,}\.[A-Za-z0-9_=-]{6,}' \
    "$_cmsg_tmp" > "$_cmsg_hits_tmp" 2>/dev/null
  _cmsg_grep_rc=$?
  if [ "$_cmsg_grep_rc" -ge 2 ]; then
    echo "DEGRADED: commit message grep failed (rc=$_cmsg_grep_rc) — commit message scan incomplete" >&2
    rm -f "$_cmsg_tmp" "$_cmsg_hits_tmp"; exit 3
  fi
  _cmsg_hits=0
  while IFS= read -r m; do
    [ -z "$m" ] && continue
    echo "   LEAK!   [commit msg] $m"
    rc=1; hits=$((hits+1)); _cmsg_hits=$((_cmsg_hits+1))
  done < <(head -20 "$_cmsg_hits_tmp")
  [ "$_cmsg_hits" -eq 0 ] && echo "   (none)"
  rm -f "$_cmsg_tmp"; _cmsg_tmp=""
  rm -f "$_cmsg_hits_tmp"; _cmsg_hits_tmp=""
fi

# --- BINARY-SKIP report: a stray NUL byte makes grep -I skip a whole file silently. Surface it. ----
# In --committed mode -a/--text is used; all files are scanned regardless of NUL bytes — no blind spot.
# In default mode, detect NUL-bearing files that grep would silently skip.
nulls=0
if [ "$committed" = 1 ]; then
  echo "-- binary files: -a/--text flag used — all committed files scanned regardless of NUL bytes --"
else
  # `\x00` here is the literal 4-char PCRE escape (a bash $'\x00' arg would collapse to an empty pattern that
  # matches every file). `-a` is REQUIRED: without it GNU grep refuses to match inside a file it deems binary,
  # so the NUL never gets found and the count is a false 0. `-a` forces the text match so the NUL is detected.
  if ! _nul_tmp="$(mktemp)"; then
    echo "   WARN: NUL-byte scan SKIPPED — mktemp failed; binary-skip detection incomplete."
    nulls=0
  else
    grep -ralP "${INCL[@]}" "${EXCL[@]}" '\x00' "$corpus" 2>/dev/null > "$_nul_tmp"
    _nul_rc=$?
    if [ "$_nul_rc" -ge 2 ]; then
      echo "   WARN: NUL-byte scan FAILED (grep exit $_nul_rc) — binary-skip detection incomplete; inspect corpus manually."
      nulls=0
    else
      # No '|| true': grep -c exits 1 on empty file (benign, count=0); exit ≥2 (ENOMEM/SIGPIPE)
      # must surface as WARN, not collapse to a silent confident 0 — §7.
      nulls=$(grep -c . < "$_nul_tmp")
      _vsec_nulls_rc=$?
      if [ "$_vsec_nulls_rc" -ge 2 ]; then
        printf '   WARN: NUL-byte count FAILED (grep exit %d) — count unavailable\n' "$_vsec_nulls_rc"
        nulls=0
      fi
    fi
    rm -f "$_nul_tmp"; _nul_tmp=""
  fi
fi
[ "${nulls:-0}" -gt 0 ] && echo "-- ⚠ $nulls in-scope file(s) contain a NUL byte and were SKIPPED by the text scan — inspect manually."

echo "-- summary: $hits high-confidence leak(s) · $warns advisory warning(s) · $nulls binary-skipped --"
if [ "$rc" = 0 ] && [ "$hits" -eq 0 ]; then
  echo "   clean IN SCOPE — no secret values in *.md/config files. NOT scanned: non-.md sources/ artifacts"
  echo "   (decompiled code, snapshots) + vendored trees + Bearer/Basic headers + all-alpha literals — judge those yourself."
fi
echo "== exit $rc =="
exit $rc
