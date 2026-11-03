# _read_focuses_tok — read and validate the leading status token for a focus from FOCUSES.md.
# This is the FIRST checker to read the focus-status cell (METHODOLOGY §16).
# Args: $1=FOCUSES.md path  $2=state-file basename (e.g. RESEARCH-STATE-alpha.md)
# Stdout: validated leading token (lowercased), or empty when absent/not-found/non-conforming.
# Grammar: active|paused|stopped|planned|bootstrapping|reopened|document (METHODOLOGY §16).
# closed is NOT a valid token; regional variants are non-conforming (METHODOLOGY §16).
# Columns recognised by header: Focus (identity), Status|Estado (status), Research-State|State file (identity).
# Cell decoration stripped before matching: `backtick-wrap` and **bold-wrap** (BOLD-STRIP).
# WARNs to stderr: token outside closed vocabulary, or state file absent from the index.
#
# Memoized per (ffile, sbase): the default report reads the token once per state file from the campaign block
# AND again from the next-step block, and the awk scan emits its WARNs, so an unmemoized read would print every
# nonconforming-row WARN twice. The token is still computed once, from the same file, by the same logic; only
# the second and later reads within one run are served from the cache.
#
# The cache is an in-process array and the reader is called as a PLAIN statement (never inside `$(...)`), so
# nothing is forked, nothing is written to a shared or world-readable location, and the cache only ever holds
# values this process computed itself. A file-backed cache would be attacker-influenceable (symlink clobber, a
# planted "<key>\tstopped" line forcing a false STOP — a silent zero, CLAUDE.md §7). The next-step `( … )`
# subshell inherits a COPY of the array at fork time, so entries the campaign block populated are hits there.
#
# Requires bash >= 4 (`declare -A`).
# SENTINEL-RFT-HARNESS-BEGIN (the shadowing test extracts exactly the code between BEGIN and END)
declare -A _RSDD_FOC_TOK_CACHE=()  # W2-NO-PROBE-WRITE-ANCHOR
# Every local is prefixed `__rft_` on purpose. `printf -v "$__rft_target"` assigns to a variable NAME the caller
# supplies; if that name equalled one of this function's own locals, `printf -v` would resolve to the local
# (locals shadow) and leave the caller's variable unset or stale. The prefix makes such a collision require a
# call site that deliberately picks a `__rft_`-prefixed name.
_read_focuses_tok_into() {
  local __rft_target="$1" __rft_ffile="$2" __rft_sbase="$3"
  local __rft_cache_key
  __rft_cache_key="${__rft_ffile}$(printf '\x1e')${__rft_sbase}"
  if [ "${_RSDD_FOC_TOK_CACHE[$__rft_cache_key]+_set}" = "_set" ]; then  # W2-DEDUP-CACHE-ANCHOR
    printf -v "$__rft_target" '%s' "${_RSDD_FOC_TOK_CACHE[$__rft_cache_key]}"
    return
  fi
  local __rft_tok
  __rft_tok="$(_read_focuses_tok_uncached "$__rft_ffile" "$__rft_sbase")"
  _RSDD_FOC_TOK_CACHE[$__rft_cache_key]="$__rft_tok"
  printf -v "$__rft_target" '%s' "$__rft_tok"
}

_read_focuses_tok_uncached() {
  local ffile="$1" sbase="$2"
  [ -f "$ffile" ] || return  # N194-FOCUSES-SKIP-FN
  local fslug="${sbase#RESEARCH-STATE-}"; fslug="${fslug%.md}"
  awk -v sbase="$sbase" -v fslug="$fslug" '
    function trim(s)  { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    function strip_markup(s,   r) {
      r = s
      if (r ~ /^\[[^]]*\]\([^)]*\)$/) { sub(/^\[/, "", r); sub(/\]\(.*\)$/, "", r) }  # link [text](url) — LINK-STRIP
      if (r ~ /^`[^`]*`$/)            { sub(/^`/, "", r); sub(/`$/, "", r) }            # backtick-wrap
      sub(/^\*\*/, "", r); sub(/\*\*/, "", r)                                            # BOLD-STRIP + §8b half-bold
      return r
    }
    function lead_tok(s,   t) {
      t = strip_markup(s); sub(/[[:space:]].*$/, "", t); return tolower(t)
    }
    BEGIN { hdone=0; fcol=0; scol=0; sfcol=0; found=0 }
    {
      if (index($0, "|") == 0) next
      line = $0
      gsub(/\\\|/,"\001",line)  # GFM-EP-FOCTOK (#2161): `\|` inside a cell is a literal pipe; restored after the split
      sub(/^\|/, "", line); sub(/\|$/, "", line)
      n = split(line, a, "|"); for (k=1; k<=n; k++) { a[k] = trim(a[k]); gsub(/\001/, "|", a[k]) }
      issep=1; for (k=1; k<=n; k++) { if (a[k] !~ /^:?-+:?$/) { issep=0; break } }
      if (issep) next
      if (!hdone) {
        hdone = 1
        for (k=1; k<=n; k++) {
          h = tolower(a[k])
          if (h == "focus")                                fcol  = k
          if (h == "status" || h == "estado")              scol  = k
          if (h == "research-state" || h == "state file") sfcol = k
        }
        if (scol == 0 && fcol > 0) scol = fcol + 1  # fallback: column after Focus
        next
      }
      # identity match: Focus column and state-file column only (D4 — no any-cell hazard)
      matched = 0
      if (fcol > 0 && fcol <= n) {
        cv = strip_markup(a[fcol])
        if (cv == sbase || cv == fslug) matched = 1
      }
      if (!matched && sfcol > 0 && sfcol <= n) {
        cv = strip_markup(a[sfcol])
        if (cv == sbase || cv == fslug) matched = 1
      }
      if (!matched) next
      # row found — validate status cell
      found = 1
      if (scol == 0 || scol > n) {
        print "WARN: FOCUSES.md row " fslug ": no status column found" > "/dev/stderr"
        exit
      }
      tok = lead_tok(a[scol])
      if (tok == "active"   || tok == "paused"       || tok == "stopped" ||
          tok == "planned"  || tok == "bootstrapping" || tok == "reopened" ||
          tok == "document") {
        print tok; exit
      }
      # token outside closed vocabulary → WARN, return empty (no skip triggered)
      print "WARN: FOCUSES.md row " fslug ": unreadable/nonconforming status token [" strip_markup(a[scol]) "]" > "/dev/stderr"
      exit
    }
    END {
      # FOCUSES.md present with a table but no matching row → drift WARN
      if (hdone && !found) {
        print "WARN: FOCUSES.md has no row for " sbase > "/dev/stderr"
      }
    }
  ' "$ffile"
}
# SENTINEL-RFT-HARNESS-END
