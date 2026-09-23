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
#                git history (via git rev-list --objects → unique blob dedup → ONE LOOP: git cat-file per
#                unique blob into a temp file, then all HC patterns + advisory grep simultaneously) plus all
#                commit messages. Required by ensure-remote.sh so what is scanned == what git push will send
#                (including secrets deleted from HEAD but still reachable in history). Requires git. Target
#                must be the git repo root — refuses with exit 3 if it is a subdirectory (pathspecs would
#                silently miss files outside the subdir). Uses -a/--text so all files are scanned, including
#                those with NUL bytes.
# Exit: 0 = clean-in-scope (or only advisory WARN) · 1 = a high-confidence secret VALUE leaked ·
#       2 = bad args · 3 = degraded (--committed: git unavailable, not a git repo with commits,
#           target is not the repo root, or rev-list/grep failure).
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
trap 'rm -f "$_rev_obj_tmp" "$_blobs_list" "$_hc_hits_tmp" "$_adv_raw" "$_blob_tmp"' EXIT

# --committed mode: probe git, verify the repo has at least one commit.
if [ "$committed" = 1 ]; then
  command -v git >/dev/null 2>&1 || {
    echo "DEGRADED: git not found — --committed mode requires git" >&2; exit 3; }
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
  # Enumerate all reachable objects; filter unique blobs matching in-scope paths.
  # git rev-list --objects HEAD outputs "<sha40>" (bare commit SHAs) and "<sha40> <path>" (blobs/trees).
  # awk keeps NF>=2 lines (path-bearing blobs/trees) that match our include/exclude rules, then
  # sort|awk deduplicates by blob SHA — same file content (same SHA) scanned exactly once.
  _rev_obj_tmp="$(mktemp)"
  git -C "$target" rev-list --objects HEAD > "$_rev_obj_tmp" 2>/dev/null
  _rev_obj_rc=$?
  if [ "$_rev_obj_rc" -ge 2 ]; then
    echo "DEGRADED: git rev-list --objects failed (rc=$_rev_obj_rc) — cannot enumerate committed blobs" >&2
    exit 3
  fi
  _blobs_list="$(mktemp)"
  awk 'NF>=2 {
    sha=$1; path=substr($0,42)
    inc=0
    if (path ~ /\.md$/) inc=1
    if (path ~ /\.env$/) inc=1
    if (path ~ /(^|\/)(\.env[^\/]+)$/) inc=1
    if (path ~ /\.conf$/) inc=1
    if (path ~ /\.ini$/) inc=1
    if (path ~ /\.properties$/) inc=1
    if (path ~ /\.cfg$/) inc=1
    if (path ~ /(^|\/)config\./) inc=1
    if (path ~ /(^|\/)credentials$/) inc=1
    if (!inc) next
    if (path ~ /\/(node_modules|\.venv|venv|decompiled|vineflower|procyon|cfr|jadx)\//) next
    print sha " " path
  }' "$_rev_obj_tmp" | sort -k1,1 | awk '!seen[$1]++' > "$_blobs_list"
  rm -f "$_rev_obj_tmp"; _rev_obj_tmp=""
  # ONE LOOP: read each unique blob once and run all HC patterns (combined 7-pattern grep) plus the
  # advisory grep simultaneously via a per-blob temp file. 1 git cat-file per blob instead of 8
  # (7 HC passes + 1 advisory), reducing subprocess spawns ~8-fold vs per-pattern loops.
  # Sequential greps on a local temp file — no async/ordering issues.
  # -naE: -n line numbers, -a text mode (catches NUL-byte .md files), -E extended regex.
  # -e for each pattern: required so patterns starting with '-' (e.g. '-----BEGIN') are not parsed
  # as options. -naiP for advisory: case-insensitive PCRE.
  _hc_hits_tmp="$(mktemp)"; _adv_raw="$(mktemp)"; _blob_tmp="$(mktemp)"
  while IFS=' ' read -r bsha bpath; do
    bshort="${bsha:0:7}"
    git -C "$target" cat-file blob "$bsha" 2>/dev/null > "$_blob_tmp"
    grep -naE -e '-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----' \
              -e 'A[KS]IA[0-9A-Z]{16}' \
              -e 'gh[pousr]_[A-Za-z0-9]{36,}' \
              -e 'xox[baprs]-[A-Za-z0-9-]{10,}' \
              -e 'AIza[0-9A-Za-z_-]{35}' \
              -e 'sk-[A-Za-z0-9]{20,}' \
              -e 'eyJ[A-Za-z0-9_=-]{6,}\.eyJ[A-Za-z0-9_=-]{6,}\.[A-Za-z0-9_=-]{6,}' \
              "$_blob_tmp" 2>/dev/null | sed "s|^|${bpath}@${bshort}:|" >> "$_hc_hits_tmp" || :
    grep -naiP -e "${KWID}\s*[=:]" "$_blob_tmp" 2>/dev/null | sed "s|^|${bpath}@${bshort}:|" >> "$_adv_raw" || :
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
    # -E -e: explicit pattern flag required so PEM pattern (-----BEGIN…) is not parsed as an option.
    # Dedup + cap at 50; /dev/null fallback when probe block was skipped (e.g. teeth-deg path).
    while IFS= read -r m; do
      [ -z "$m" ] && continue
      echo "   LEAK!   $label — ${m}"
      rc=1; hits=$((hits+1))
    done < <(grep -E -e "$re" "${_hc_hits_tmp:-/dev/null}" 2>/dev/null | sort -u | head -50)
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
  _adv_dedup="$(mktemp)"
  sed 's/@[0-9a-f][0-9a-f]*:/:/1' "${_adv_raw:-/dev/null}" | sort -u | head -200 > "$_adv_dedup"
  rm -f "$_adv_raw"; _adv_raw=""
else
  _adv_dedup="$(mktemp)"
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
# A secret value typed into a commit message is never removed by a content redaction. Scans all
# commit subjects + bodies reachable from HEAD for the same high-confidence patterns as the file scan.
if [ "$committed" = 1 ]; then
  echo "-- commit messages (full history) --"
  _cmsg_tmp="$(mktemp)"
  git -C "$target" log --format="format:%s%n%b" HEAD > "$_cmsg_tmp" 2>/dev/null
  _cml_rc=$?
  if [ "$_cml_rc" -ge 2 ]; then
    echo "DEGRADED: git log failed (rc=$_cml_rc) — commit message scan incomplete" >&2
    rm -f "$_cmsg_tmp"; exit 3
  fi
  _cmsg_hits=0
  while IFS= read -r m; do
    [ -z "$m" ] && continue
    echo "   LEAK!   [commit msg] $m"
    rc=1; hits=$((hits+1)); _cmsg_hits=$((_cmsg_hits+1))
  done < <(
    grep -naE \
      -e '-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----' \
      -e 'A[KS]IA[0-9A-Z]{16}' \
      -e 'gh[pousr]_[A-Za-z0-9]{36,}' \
      -e 'xox[baprs]-[A-Za-z0-9-]{10,}' \
      -e 'AIza[0-9A-Za-z_-]{35}' \
      -e 'sk-[A-Za-z0-9]{20,}' \
      -e 'eyJ[A-Za-z0-9_=-]{6,}\.eyJ[A-Za-z0-9_=-]{6,}\.[A-Za-z0-9_=-]{6,}' \
      "$_cmsg_tmp" 2>/dev/null | head -20
  )
  [ "$_cmsg_hits" -eq 0 ] && echo "   (none)"
  rm -f "$_cmsg_tmp"
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
  _nul_tmp="$(mktemp)"
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
  rm -f "$_nul_tmp"
fi
[ "${nulls:-0}" -gt 0 ] && echo "-- ⚠ $nulls in-scope file(s) contain a NUL byte and were SKIPPED by the text scan — inspect manually."

echo "-- summary: $hits high-confidence leak(s) · $warns advisory warning(s) · $nulls binary-skipped --"
if [ "$rc" = 0 ] && [ "$hits" -eq 0 ]; then
  echo "   clean IN SCOPE — no secret values in *.md/config files. NOT scanned: non-.md sources/ artifacts"
  echo "   (decompiled code, snapshots) + vendored trees + Bearer/Basic headers + all-alpha literals — judge those yourself."
fi
echo "== exit $rc =="
exit $rc
