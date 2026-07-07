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
# Usage: scan-secrets.sh <target-dir>
# Exit: 0 = clean-in-scope (or only advisory WARN) · 1 = a high-confidence secret VALUE leaked · 2 = bad args.
set -uo pipefail
target="${1:-}"
[ -n "$target" ] && [ -d "$target" ] || { echo "usage: scan-secrets.sh <target-dir>" >&2; exit 2; }
here="$(cd "$(dirname "$0")" && pwd)"; KIT="$(cd "$here/.." && pwd)"

# Corpus root (mirror verify-sources.sh): prefer the target root when it directly holds blocks, else the
# shallowest subdir that does (deterministic: depth, then lexical).
corpus="$target"
if ! find "$target" -maxdepth 1 -type f \( -iname '*block*.md' -o -iname '*bloque*.md' \) 2>/dev/null | grep -q .; then
  anchor="$(find "$target" -maxdepth 3 -type f \( -iname '*block*.md' -o -iname '*bloque*.md' \) -not -path '*/.git/*' 2>/dev/null \
            | awk '{print gsub(/\//,"/") "\t" $0}' | sort -t"$(printf '\t')" -k1,1n -k2,2 | head -1 | cut -f2-)"
  [ -n "$anchor" ] && corpus="$(dirname "$anchor")"
fi

# File scope (shared by both tiers).
INCL=(--include='*.md' --include='*.env' --include='.env*' --include='*.conf' --include='*.ini'
      --include='*.properties' --include='*.cfg' --include='config.*' --include='credentials')
EXCL=(--exclude-dir=.git --exclude-dir=node_modules --exclude-dir=.venv --exclude-dir=venv
      --exclude-dir=decompiled --exclude-dir=vineflower --exclude-dir=procyon --exclude-dir=cfr --exclude-dir=jadx)

echo "== scan-secrets: $(basename "$target") =="
[ "$corpus" != "$target" ] && echo "-- corpus root: ${corpus#"$target"/}/"
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
  while IFS= read -r m; do
    [ -z "$m" ] && continue
    echo "   LEAK!   $label — ${m}"
    rc=1; hits=$((hits+1))
  done < <(grep -rnoIE "${INCL[@]}" "${EXCL[@]}" -e "$re" "$corpus" 2>/dev/null | head -50)
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
KWID='(?<![A-Za-z0-9])(?:password|passwd|secret|api[_-]?key|apikey|token)(?![A-Za-z])[A-Za-z0-9_]*'
warns=0
while IFS= read -r line; do
  content="${line#*:*:}"
  val="$(printf '%s' "$content" | grep -oiP "${KWID}\s*[=:]\s*[\"']?\K[^\"';,\s]+" | head -1)"
  [ -z "$val" ] && continue
  case "$val" in '<'*|'$'*|'{'*|'*'*|'%'*) continue;; esac                       # placeholder / var / format
  case "$val" in *...*|*…*) continue;; esac                                      # truncated illustration (abc123…)
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
done < <(grep -rniIP "${INCL[@]}" "${EXCL[@]}" -e "${KWID}\s*[=:]" "$corpus" 2>/dev/null | head -200)
[ "$warns" -eq 0 ] && echo "   (none)"

# --- BINARY-SKIP report: a stray NUL byte makes grep -I skip a whole file silently. Surface it. ----
# `\x00` here is the literal 4-char PCRE escape (a bash $'\x00' arg would collapse to an empty pattern that
# matches every file). `-a` is REQUIRED: without it GNU grep refuses to match inside a file it deems binary,
# so the NUL never gets found and the count is a false 0. `-a` forces the text match so the NUL is detected.
nulls=$(grep -ralP "${INCL[@]}" "${EXCL[@]}" '\x00' "$corpus" 2>/dev/null | grep -c . || true)
[ "${nulls:-0}" -gt 0 ] && echo "-- ⚠ $nulls in-scope file(s) contain a NUL byte and were SKIPPED by the text scan — inspect manually."

echo "-- summary: $hits high-confidence leak(s) · $warns advisory warning(s) · $nulls binary-skipped --"
if [ "$rc" = 0 ] && [ "$hits" -eq 0 ]; then
  echo "   clean IN SCOPE — no secret values in *.md/config files. NOT scanned: non-.md sources/ artifacts"
  echo "   (decompiled code, snapshots) + vendored trees + Bearer/Basic headers + all-alpha literals — judge those yourself."
fi
echo "== exit $rc =="
exit $rc
