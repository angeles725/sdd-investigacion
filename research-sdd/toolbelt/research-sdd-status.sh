#!/usr/bin/env bash
# research-sdd-status.sh — structured status + deterministic next-gap for a Research-SDD corpus.
#
# WHY: RESUME was PROSE ("read RESEARCH-STATE, start from the next not-covered gap"). A human/agent
# re-derived "what's next" by eye each iteration. This mechanizes it: `status` renders the state, and
# `--next` resolves the next gap DETERMINISTICALLY (highest-priority pending gap that is not blocked),
# so the loop never guesses. Models sdd-status / sdd-continue, kept to the continuous research loop.
#
# Usage:
#   research-sdd-status.sh <target-dir>            structured status report (default)
#   research-sdd-status.sh <target-dir> --sync-state  (re-)seed the research-state.v1 envelope IN PLACE
#        from ground truth (idempotent; a second run is byte-identical). This is what verify-state.sh
#        validates against — run it after editing the backlog so --next never returns STALE on stale ints.
#   research-sdd-status.sh <target-dir> --next     print ONE machine-readable next-step line:
#        NEXT | <priority> | <gap>     — investigate this gap next
#        STOP | <reason>               — read-only-investigable exhausted (METHODOLOGY §8)
#        STALE | <reason>              — RESEARCH-STATE is internally inconsistent; run --sync-state, reconcile, retry
#        BOOTSTRAP | <reason>          — no RESEARCH-STATE yet → run research-sdd-init.sh
#   (NONE is no longer emitted: an empty eligible-backlog means derived investigable=0 → STOP by construction.)
# Exit: 0 ok · 2 bad args. (malformed backlog rows are WARNed to stderr, never silently dropped.)
set -uo pipefail

target="${1:-}"; mode="${2:-status}"
[ -d "$target" ] || { echo "usage: research-sdd-status.sh <target-dir> [--next]" >&2; exit 2; }

state="$(find "$target" -maxdepth 3 -name 'RESEARCH-STATE*.md' -not -name '*.template.md' -not -path '*/.git/*' 2>/dev/null | sort | head -1)"
if [ ! -f "$state" ]; then
  [ "$mode" = "--next" ] && echo "BOOTSTRAP | no RESEARCH-STATE under $target" || echo "no RESEARCH-STATE under $target — run research-sdd-init.sh"
  exit 0
fi
corpus="$(dirname "$state")"
here="$(cd "$(dirname "$0")" && pwd)"

# --- section extractors (scope numeric/list greps to their section — never whole-file) ----------
section() { awk -v h="$1" 'index($0,h)==1{f=1;next} /^## /{f=0} f' "$state"; }   # body of "## <h>..."
stopctl()      { section '## Stop control'; }
blocked_body() { section '## Blocked gaps'; }
inv_count()    { stopctl | grep -iE 'read-only investigable' | grep -oE '[0-9]+' | head -1; }

# Corpus-level contradictions ledger(s) (informational — see METHODOLOGY §14). Optional file(s); ALL
# matching files are counted (never head-1-dropped), and >1 is WARNed to stderr like backlog_rows does.
contra_ledgers() { find "$corpus" -maxdepth 1 -name 'CONTRADICTIONS*.md' 2>/dev/null | sort; }
# Count ledger rows with an OPEN STATUS cell. Template columns: `| id | claim A | claim B | status | note |`
# → the STATUS cell is the 4th (column-scoped, mirroring backlog_rows gating on a fixed column). A row
# counts only when a[4] equals "open" exactly (lowercased) — a note/header/other cell saying "open", the
# "status" header, and the "---" separator never count. Sums across all files passed. Emits a bare integer.
count_open_contra() {
  awk '
    { line=$0; gsub(/^[ \t]+|[ \t]+$/,"",line)
      if (line !~ /\|/) next
      sub(/^\|/,"",line); sub(/\|$/,"",line)
      n=split(line,a,"|"); if (n<4) next
      gsub(/^[ \t]+|[ \t]+$/,"",a[4]); if (tolower(a[4])=="open") c++ }
    END { print c+0 }' "$@"
}

# Iteration-history "New gaps uncovered" rows → "iter#<TAB>new-gaps", ONE line per DATA row whose
# `#` (col 1) AND New-gaps (col 6 == LAST cell) are BOTH real integers. The header row ("#"), the
# "---" separator, and any `<n>` template placeholder are non-integer → skipped. Scoped to the bounded
# `## Iteration history` section only (never whole-file), mirroring the section()/backlog_rows idioms.
iter_gaps_rows() {
  section '## Iteration history' | awk '
    { line=$0; gsub(/^[ \t]+|[ \t]+$/,"",line)
      if (line !~ /\|/) next
      sub(/^\|/,"",line); sub(/\|$/,"",line)
      n=split(line,a,"|"); if (n<2) next
      idx=a[1]; gsub(/^[ \t]+|[ \t]+$/,"",idx)
      ng=a[n];  gsub(/^[ \t]+|[ \t]+$/,"",ng)
      if (idx !~ /^[0-9]+$/) next                    # data rows only (skips header + "---" separator)
      if (ng  !~ /^[0-9]+$/) next                    # New-gaps must be a real integer (skips <n>)
      print idx "\t" ng }'
}

# SATURATION signal — INFORMATIONAL ONLY (a soft REVIEW prompt, NOT an auto-STOP). §8's read-only
# exhaustion stays the terminal trigger; exit codes, resolve_next, and the --next contract are UNTOUCHED
# (mirrors how contradictions are surfaced above). Over the LAST 3 numeric iterations (ordered by #):
#   THRESHOLD = the window sums to EXACTLY 0 new gaps → SATURATED (review); any positive sum → active.
# <3 numeric rows → insufficient history; the section absent → (no iteration history). Never errors.
saturation_line() {
  local pad='  saturation      : '
  grep -qF '## Iteration history' "$state" || { echo "${pad}(no iteration history)"; return; }
  local rows n sum
  rows="$(iter_gaps_rows | sort -t$'\t' -k1,1n)"
  n="$(printf '%s' "$rows" | grep -c .)"
  if [ "$n" -lt 3 ]; then echo "${pad}insufficient history ($n iterations)"; return; fi
  sum="$(printf '%s\n' "$rows" | tail -n 3 | awk -F'\t' '{s+=$2} END{print s+0}')"
  if [ "$sum" -eq 0 ]; then
    echo "${pad}SATURATED (review) — last 3 iterations netted 0 new gaps"
  else
    echo "${pad}active ($sum new gaps in last 3 iter)"
  fi
}

# Blocked gap NAMES (one trimmed name per "- <name> — needs: ..." line) — matched EXACTLY, never as
# a substring of free prose (a pending gap "hardware" must not be killed by "- x — needs: hardware").
blocked_names() {
  blocked_body | sed -n 's/^[[:space:]]*-[[:space:]]*//p' \
    | sed -E 's/[[:space:]]*[-–—]+[[:space:]]*needs:.*$//I; s/[[:space:]]*needs:.*$//I' \
    | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | grep -v '^$'
}
is_blocked() { local g="$1" b; while IFS= read -r b; do [ "$b" = "$g" ] && return 0; done < <(blocked_names); return 1; }

# Backlog rows: STRICT 4-column table (`| p | gap | type | status |` → 6 pipe-fields). A gap cell
# containing a pipe yields NF!=6 → WARN (never a silent drop / mis-field). Emits "priority<TAB>gap<TAB>status".
backlog_rows() {
  # Normalize the row so both bounded (`| p | g | t | s |`) and outer-pipe-less GFM (`p | g | t | s`)
  # rows parse to exactly 4 cells; a pipe INSIDE a cell yields n!=4 → WARN (never a silent drop).
  awk '
    { line=$0; gsub(/^[ \t]+|[ \t]+$/,"",line)
      if (line !~ /\|/) next
      sub(/^\|/,"",line); sub(/\|$/,"",line)
      n=split(line,a,"|"); for(k=1;k<=n;k++) gsub(/^[ \t]+|[ \t]+$/,"",a[k])
      p=tolower(a[1])
      if (p!="high" && p!="medium" && p!="low") next
      if (n!=4) { print "WARN: malformed backlog row (" n " cells, expected 4 — a cell may contain a pipe): " $0 > "/dev/stderr"; next }
      print p "\t" a[2] "\t" tolower(a[4]) }
  ' "$state"
}

resolve_next() {
  local rows; rows="$(backlog_rows)"             # compute ONCE — else the WARN fires per priority tier
  local prio pri gap st
  for prio in high medium low; do
    while IFS=$'\t' read -r pri gap st; do
      [ -z "$gap" ] && continue
      [ "${st%% *}" = "pending" ] || continue     # LEADING-TOKEN — bare `pending` or decorated `pending (uncovered by B7)`; NOT "not pending" / "blocked (pending review)"
      is_blocked "$gap" && continue
      printf 'NEXT | %s | %s\n' "$pri" "$gap"; return 0
    done < <(printf '%s\n' "$rows" | awk -F'\t' -v P="$prio" '$1==P')
  done
  # The walk above found NO eligible (pending, non-blocked) gap, so the DERIVED investigable count is 0 BY
  # CONSTRUCTION — the exact number verify-state.sh gates as the envelope's investigable_open, and the --next
  # STALE-gate already ensured the envelope agrees with this derivation before we got here. STOP on that, NOT
  # on the hand-authored `## Stop control` prose (which --sync-state never rewrites and verify-state never
  # gates): reading that prose here would resurrect the stale-mirror class the envelope was built to kill.
  echo "STOP | read-only-investigable exhausted (0)"
}

# --- envelope seeder (--sync-state) --------------------------------------------------------------
# derived investigable_open, reusing THIS script's backlog_rows/is_blocked — IDENTICAL to resolve_next's
# NEXT-eligibility set (single source of truth), and to what verify-state.sh recomputes.
count_investigable() {
  local gap st n=0
  while IFS=$'\t' read -r _ gap st; do          # field 1 (priority) unused here → discard into _
    [ -z "$gap" ] && continue
    [ "${st%% *}" = "pending" ] || continue
    is_blocked "$gap" && continue
    n=$((n+1))
  done < <(backlog_rows 2>/dev/null)
  echo "$n"
}
# read a field from the CURRENT envelope (for carry-forward of declared-only fields we cannot parse fresh).
env_get() { awk -v k="$1" '/<!-- research-state.v1 -->/{b=1;next} /<!-- \/research-state.v1 -->/{b=0} b && $1==k":"{v=$2; sub(/\r$/,"",v); print v; exit}' "$state"; }  # strip trailing CR (CRLF-safe)
# pick <parsed> <previous> — prefer a freshly-parsed integer, else carry the previous envelope value, else
# 0. NEVER invent: an unparseable declared field falls back to what was already recorded, not a guess.
pick() { case "$1" in ''|*[!0-9]*) case "$2" in ''|*[!0-9]*) echo 0;; *) echo "$2";; esac;; *) echo "$1";; esac; }

if [ "$mode" = "--sync-state" ]; then
  # Seed the research-state.v1 envelope in EVERY RESEARCH-STATE*.md of the corpus. §16 multi-focus corpora
  # keep ONE state file per focus, each with its OWN backlog. Seeding only the head-1 file (as this did before)
  # left sibling foci envelope-less, and verify-state.sh — which lints ALL of them (its line ~19) — then FAILs,
  # BRICKING the whole corpus under the --next STALE-gate. ALL envelope fields are derived PER STATE FILE:
  # investigable_open / blocked_open / coverage from each focus's own backlog, and covered_blocks from that
  # file's OWN directory — recomputed INSIDE the loop with the SAME strict discriminator + dirname scoping that
  # verify-state.sh:101 uses. A once-at-$corpus cb would disagree with verify-state for any focus file living in
  # a subdirectory (verify-state recomputes ondisk per dirname($state)), FAILing the envelope we just wrote.
  render_envelope() {   # reads the per-file globals set in the loop below (cb/io/bo/gc/kg/req)
    printf '<!-- research-state.v1 -->\n'
    printf 'schema: research-state.v1\n'
    printf 'covered_blocks: %s\n' "$cb"
    printf 'gaps_closed: %s\n' "$gc"
    printf 'known_gaps: %s\n' "$kg"
    printf 'investigable_open: %s\n' "$io"
    printf 'requires_execution_open: %s\n' "$req"
    printf 'blocked_open: %s\n' "$bo"
    printf '<!-- /research-state.v1 -->'
  }
  # Reassigning the global `state` per iteration is deliberate: section/backlog_rows/blocked_body/env_get all
  # read $state at call time, so each focus derives from its OWN file (single source of truth, same helpers).
  mapfile -t _states < <(find "$corpus" -maxdepth 3 -name 'RESEARCH-STATE*.md' -not -name '*.template.md' -not -path '*/.git/*' 2>/dev/null | sort)
  for state in "${_states[@]}"; do
    # Write THROUGH a symlinked state file to its real path (else the mv below would replace the symlink
    # with a regular file, silently breaking a shared/canonical state). readlink -f also canonicalizes a
    # plain path harmlessly. The temp then lives in the target's OWN directory so mv is a same-filesystem
    # atomic rename (a bare mktemp lands in TMPDIR, and a cross-device mv is a non-atomic copy+unlink).
    state="$(readlink -f "$state" 2>/dev/null || printf '%s' "$state")"
    # covered_blocks from THIS file's own directory — identical discriminator + dirname scoping to
    # verify-state.sh:101, so declared cb can never disagree with the ondisk count verify-state recomputes.
    cb="$(find "$(dirname "$state")" -maxdepth 1 -type f -name '*.md' 2>/dev/null | grep -E '/[^/]+-(block|bloque)[0-9]+(-[[:alnum:]_-]+)?\.md$' | wc -l | tr -d ' ')"
    io="$(count_investigable)"
    bo="$(blocked_body | grep -icE '^[[:space:]]*-[[:space:]].*needs:')"
    # declared-only figures from THIS file's prose (coverage metric X/Y, requires-execution), carrying the
    # previous envelope value when a figure is absent/unparseable (never invent — see pick()).
    cov="$(section '## Coverage' | grep -iE 'coverage metric' | grep -oE '[0-9]+[[:space:]]*/[[:space:]]*[0-9]+' | head -1 | tr -d ' ')"
    gc="$(pick "${cov%%/*}" "$(env_get gaps_closed)")"
    kg="$(pick "${cov##*/}" "$(env_get known_gaps)")"
    req="$(pick "$(stopctl | grep -iE 'requires-execution' | grep -oE '[0-9]+' | head -1)" "$(env_get requires_execution_open)")"
    repl="$(render_envelope)"
    tmp="$(mktemp "$(dirname "$state")/.rsdd-sync.XXXXXX")"
    if grep -q '<!-- research-state.v1 -->' "$state"; then
      # fence EXISTS → replace ONLY between the markers (idempotent; surrounding prose untouched).
      awk -v repl="$repl" '
        $0 ~ /<!-- research-state.v1 -->/ { print repl; skip=1; next }
        skip && $0 ~ /<!-- \/research-state.v1 -->/ { skip=0; next }
        skip { next }
        { print }' "$state" > "$tmp"
    else
      # fence ABSENT → insert right after the top intro blockquote (the first contiguous run of `>` lines);
      # if there is no blockquote, append at EOF. Either way a SECOND run finds the fence → byte-identical.
      awk -v repl="$repl" '
        { line=$0
          if (!done) {
            if (line ~ /^>/) inbq=1
            else if (inbq) { print repl; print ""; done=1 }
          }
          print line }
        END { if (!done) { print ""; print repl } }' "$state" > "$tmp"
    fi
    mv "$tmp" "$state"
    echo "sync-state: $(basename "$state") → covered_blocks=$cb gaps_closed=$gc known_gaps=$kg investigable_open=$io requires_execution_open=$req blocked_open=$bo"
  done
  exit 0
fi

if [ "$mode" = "--next" ]; then
  # Refuse to hand out work on an internally inconsistent state (summary claims done while backlog
  # lists pending — verify-state.sh exits 1 on that). An agent trusting --next alone must reconcile first.
  if ! "$here/verify-state.sh" "$corpus" >/dev/null 2>&1; then
    echo "STALE | RESEARCH-STATE inconsistent — reconcile first: research-sdd-status.sh $target"
    exit 0
  fi
  resolve_next; exit 0
fi

# --- default: structured status report ---------------------------------------------------------
rel="${corpus#"$target"}"; rel="${rel#/}"; [ -z "$rel" ] && rel="(flat)"
metric="$(section '## Coverage' | grep -iE 'coverage metric' | grep -oE '[0-9]+[[:space:]]*/[[:space:]]*[0-9]+' | head -1 | tr -d ' ')"
covered="$(section '## Coverage' | grep -iE 'covered blocks' | grep -oE '[0-9]+' | head -1)"
ondisk="$(find "$corpus" -maxdepth 1 -type f -name '*.md' 2>/dev/null | grep -E '/[^/]+-(block|bloque)[0-9]+(-[[:alnum:]_-]+)?\.md$' | wc -l | tr -d ' ')"   # strict discriminator (gen-catalog.py BLOCK_RE)
inv="$(inv_count)"
req="$(stopctl | grep -iE 'requires-execution' | grep -oE '[0-9]+' | head -1)"
blk="$(stopctl | grep -iE 'blocked' | grep -oE '[0-9]+' | head -1)"
ph=$(backlog_rows 2>/dev/null | awk -F'\t' '$3=="pending"{n[$1]++} END{printf "high=%d medium=%d low=%d", n["high"], n["medium"], n["low"]}')

echo "== research-sdd-status: $(basename "$target")  ·  corpus: $rel =="
echo "  coverage metric : ${metric:-<none>}"
echo "  covered blocks  : ${covered:-<none>} claimed · ${ondisk} on disk"
echo "  pending backlog : $ph"
echo "  stop-control    : investigable=${inv:-?} · requires-execution=${req:-?} · blocked=${blk:-?}"
mapfile -t ledgers < <(contra_ledgers)
if [ "${#ledgers[@]}" -eq 0 ]; then
  echo "  contradictions  : (no ledger)"
else
  [ "${#ledgers[@]}" -gt 1 ] && echo "WARN: multiple CONTRADICTIONS*.md ledgers under $corpus — counting all ${#ledgers[@]}" >&2
  nopen="$(count_open_contra "${ledgers[@]}")"
  [ "$nopen" -gt 0 ] && echo "  contradictions  : ${nopen} open" || echo "  contradictions  : (none)"
fi
saturation_line
printf '  next step       : '; resolve_next
echo "  --- consistency (verify-state.sh) ---"
"$here/verify-state.sh" "$corpus" 2>&1 | sed -n '/summary\|FAIL\|WARN\|ok /p' | sed 's/^/  /'
exit 0   # a stale-mirror FAIL is REPORTED in the consistency line above; it must not become our exit code (contract: 0 ok / 2 bad args)
