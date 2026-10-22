#!/usr/bin/env bash
# stage-libs.test.sh — suite for tests/lib/stage-libs.sh (rsdd_stage_libs) and the lint that retires the
# hand-maintained lib-copy lists in the suites (T12c).
#
# WHY. ~50 suites stage a sandbox toolbelt by copying a hand-picked list of toolbelt/lib files. When a lib grows a
# new dependency, every list that misses it breaks (or, worse, keeps passing against a stale copy). The shared
# helper stages EVERY top-level lib file instead; this suite pins the helper and keeps new hand lists out.
#
# Parts
#   a. behaviour: stages all libs, keeps modes, honours --except, rejects an unknown --except, refuses the live
#      tree, skips directories, fails loudly on an empty source or a failed copy, is silent on success.
#   b. lint: a non-comment line in tests/*.test.sh that copies (cp/ln) `…/lib/<name>.(sh|py)` — a toolbelt lib by
#      literal name, or `lib/$v` where a `for v in …` list names a toolbelt lib — into a `…/lib` destination is a
#      hand list. Exempt a line with a trailing `# stage-libs-ok: <reason of at least three words>`. A source under
#      tests/lib (`$HERE/lib/…`, `tests/lib/…`) is the test helpers, not the toolbelt libs, and is not flagged.
#      RATCHET lists the suites not migrated yet: a flagged suite missing from it fails, and a listed suite the lint
#      no longer flags is STALE and fails too, so the list only shrinks. Remove an entry in the change that migrates
#      the suite. Known limits (stated, not claimed): a copy split over several lines, a source held in a variable
#      that is not a for-loop variable, `rsync`/`install`, and a lib copied to a destination not ending in `lib`.
#
# Env seams: STAGE_LIBS_HELPER (default tests/lib/stage-libs.sh; the teeth point it at a mutant) ·
#   STAGE_LIBS_TOOLBELT (default: ..; the toolbelt whose lib/ is staged and linted for) ·
#   LINT_SCAN_DIR (default: this directory) · LINT_RATCHET=0 (ignore RATCHET, for the planted controls) ·
#   STAGE_LIBS_NESTED=1 (inner runs: skip the end-to-end recursion).
# Usage: stage-libs.test.sh [--prove-teeth]   Exit: 0 held · 1 regression · 2 harness error.
set -uo pipefail
HERE="$(cd -P -- "$(dirname "$0")" && pwd -P)"
SELF="${BASH_SOURCE[0]##*/}"
TB="$(cd -P -- "${STAGE_LIBS_TOOLBELT:-$HERE/..}" && pwd -P)"
HELPER="${STAGE_LIBS_HELPER:-$HERE/lib/stage-libs.sh}"
SCAN_DIR="${LINT_SCAN_DIR:-$HERE}"
[ -d "$TB/lib" ] || { echo "FATAL: toolbelt lib dir not found: $TB/lib" >&2; exit 2; }

# Suites that still hand-copy toolbelt libs (the ratchet: it only shrinks). One suite name per line.
RATCHET="
check-gap-drift
coverage-map
decompile-java
decompile-net
discriminator-parity
enforcement-e2e
ensure-remote
lint-block
migrate-backlogs
reconcile-issues-delta-forms
reconcile-issues-dismissed
research-sdd-archive
research-sdd-init
retro-gate
retro-grammar
run-all
run-all-cache
sessionstart-budget
stage-retro-issues-delta-forms
stage-retro-issues-dismissed
stage-retro-issues-unclassifiable
sweep-audits
sweep-audits-hook
sweep-breakthroughs
sweep-breakthroughs-hook
sweep-retros
sweep-retros-hook
sweep-tools-hook
verify-corrections
verify-corrections-binding
verify-corrections-precision
verify-corrections-residuals
verify-kit-clean-hook
verify-parity
verify-registry
verify-registry-hook
verify-registry-json
verify-registry-wired-exec
verify-skill-drift
verify-skill-drift-hook
verify-state
verify-tool-catalog-hook
"

pass=0; fail=0
ok() { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT

echo "== stage-libs.test.sh =="

# ==========================================================================
# a. behaviour
# ==========================================================================
# shellcheck source=lib/stage-libs.sh
. "$HELPER" 2>/dev/null || no "a0 helper sources cleanly ($HELPER)"

src_names() { local f; for f in "$1"/*; do [ -f "$f" ] && printf '%s\n' "${f##*/}"; done; }
dest_names() { local f; for f in "$1"/* "$1"/.[!.]*; do [ -e "$f" ] && printf '%s\n' "${f##*/}"; done; }
want_all="$(src_names "$TB/lib")"
nlib="$(grep -c . <<<"$want_all")"

# a1 every top-level regular file, byte for byte; a9 silent on success
out="$(rsdd_stage_libs "$W/a1" 2>&1)"; rc=$?
got="$(dest_names "$W/a1/lib")"
if [ "$rc" -eq 0 ] && [ "$got" = "$want_all" ] && [ "$nlib" -gt 1 ]; then
  diffs=0; while IFS= read -r n; do cmp -s "$TB/lib/$n" "$W/a1/lib/$n" || diffs=$((diffs+1)); done <<<"$want_all"
  if [ "$diffs" -eq 0 ]; then ok "a1 stages all $nlib toolbelt/lib files, byte-identical"
  else no "a1 $diffs staged file(s) differ from toolbelt/lib"; fi
else
  no "a1 stages all toolbelt/lib files (rc=$rc, want $nlib, got $(grep -c . <<<"$got"): $(tr '\n' ' ' <<<"$out" | cut -c1-200))"
fi
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then ok "a9 silent on success (no stdout, no stderr)"
else no "a9 expected silence on success, got rc=$rc [$out]"; fi

# a2 modes kept even under a restrictive umask (a plain cp would mask them)
out="$( umask 077; rsdd_stage_libs "$W/a2" 2>&1 )"; rc=$?
bad=""
if [ "$rc" -eq 0 ]; then
  while IFS= read -r n; do
    [ "$(stat -c %a "$TB/lib/$n")" = "$(stat -c %a "$W/a2/lib/$n" 2>/dev/null)" ] || bad="$bad $n"
  done <<<"$want_all"
fi
if [ "$rc" -eq 0 ] && [ -z "$bad" ]; then ok "a2 file modes kept under umask 077"
else no "a2 modes not kept (rc=$rc, differing:${bad:- n/a} $out)"; fi

# a3 --except (repeatable) leaves exactly the named files out
e1="$(sed -n 1p <<<"$want_all")"; e2="$(sed -n 2p <<<"$want_all")"
out="$(rsdd_stage_libs "$W/a3" --except "$e1" --except "$e2" 2>&1)"; rc=$?
got="$(dest_names "$W/a3/lib")"; want="$(grep -vxF -e "$e1" -e "$e2" <<<"$want_all")"
if [ "$rc" -eq 0 ] && [ "$got" = "$want" ]; then ok "a3 --except $e1 --except $e2 leaves exactly those two out"
else no "a3 --except not honoured (rc=$rc: $out)"; fi

# a4 an --except naming no lib file is a typo: rc 2, a message, nothing staged
out="$(rsdd_stage_libs "$W/a4" --except no-such-lib.sh 2>&1 >/dev/null)"; rc=$?
if [ "$rc" -eq 2 ] && grep -q 'no-such-lib.sh' <<<"$out" && [ ! -e "$W/a4" ]; then ok "a4 unknown --except -> rc 2, named on stderr, nothing staged"
else no "a4 unknown --except accepted (rc=$rc, dest $( [ -e "$W/a4" ] && echo created || echo absent): $out)"; fi
rsdd_stage_libs "$W/a4b" --except >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 2 ] && [ ! -e "$W/a4b" ]; then ok "a4 --except without a NAME -> rc 2"; else no "a4 bare --except (rc=$rc)"; fi
rsdd_stage_libs >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 2 ]; then ok "a4 no DEST -> rc 2"; else no "a4 no DEST (rc=$rc)"; fi

# a5 the live toolbelt is refused: itself, a symlink to it, a DEST whose lib is a symlink into it. A path UNDER a
#    toolbelt is pinned on a fixture toolbelt (RSDD_STAGE_LIBS_SRC), so a mutant without the refusal never writes
#    into the live tree. Nothing is written in any refused case.
ln -s "$TB" "$W/tblink"; mkdir -p "$W/a5lnk"; ln -s "$TB/lib" "$W/a5lnk/lib"
mkdir -p "$W/ftb/lib"; printf 'x\n' > "$W/ftb/lib/one.sh"
r1=0; r2=0; r3=0; r4=0; r5=0
rsdd_stage_libs "$TB" >/dev/null 2>&1 || r1=$?
rsdd_stage_libs "$W/tblink" >/dev/null 2>&1 || r2=$?
rsdd_stage_libs "$W/a5lnk" >/dev/null 2>&1 || r3=$?
RSDD_STAGE_LIBS_SRC="$W/ftb/lib" rsdd_stage_libs "$W/ftb/tests/probe" >/dev/null 2>&1 || r4=$?
RSDD_STAGE_LIBS_SRC="$W/ftb/lib" rsdd_stage_libs "$W/ftb" >/dev/null 2>&1 || r5=$?
if [ "$r1$r2$r3$r4$r5" = 22222 ] && [ ! -e "$W/ftb/tests" ]; then
  ok "a5 refuses the live toolbelt (itself, a symlink to it, a lib symlink into it) and a path under a toolbelt, rc 2"
else
  no "a5 live tree not refused (self=$r1 symlink=$r2 libsymlink=$r3 under=$r4 fixture-self=$r5)"
fi

# a6 directories are skipped; a7 a source with no files is rc 2; a8 a failed copy is rc 2
mkdir -p "$W/src6/lib/__pycache__" "$W/src7/lib/sub"
printf 'x\n' > "$W/src6/lib/one.sh"; printf 'y\n' > "$W/src6/lib/__pycache__/one.pyc"
out="$(RSDD_STAGE_LIBS_SRC="$W/src6/lib" rsdd_stage_libs "$W/a6" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(dest_names "$W/a6/lib")" = "one.sh" ]; then ok "a6 skips directories (__pycache__ not staged)"
else no "a6 directories not skipped (rc=$rc, got [$(dest_names "$W/a6/lib" | tr '\n' ' ')] $out)"; fi
out="$(RSDD_STAGE_LIBS_SRC="$W/src7/lib" rsdd_stage_libs "$W/a7" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && [ -n "$out" ]; then ok "a7 a source with no files -> rc 2 with a message (never a silent empty stage)"
else no "a7 empty source accepted (rc=$rc)"; fi
mkdir -p "$W/a8/lib/one.sh"
out="$(RSDD_STAGE_LIBS_SRC="$W/src6/lib" rsdd_stage_libs "$W/a8" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && [ -n "$out" ]; then ok "a8 a failed copy -> rc 2 with a message"
else no "a8 failed copy not reported (rc=$rc)"; fi

# a10 the helper refuses direct execution
out="$(bash "$HELPER" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && grep -q 'source-only' <<<"$out"; then ok "a10 direct execution is refused"
else no "a10 direct execution not refused (rc=$rc)"; fi

# ==========================================================================
# b. lint: hand-maintained lib-copy lists
# ==========================================================================
# The toolbelt lib names the lint knows (.sh/.py, without the extension).
LIB_NAMES="$(for f in "$TB/lib"/*.sh "$TB/lib"/*.py; do [ -f "$f" ] && { n="${f##*/}"; printf '%s ' "${n%.*}"; }; done)"

# lint_files FILE... -> "<suite>:<line>: <text>" per hand-copy line; rc 2 = nothing scanned (never a silent zero).
# This suite and its mutants (*stage-libs*) are skipped: they quote the forms.
lint_files() {
  local f n=0 name
  for f in "$@"; do
    [ -f "$f" ] || continue
    case "${f##*/}" in *stage-libs*) continue ;; esac
    n=$((n+1)); name="${f##*/}"; name="${name%.test.sh}"
    awk -v names="$LIB_NAMES" -v name="$name" '
      BEGIN { k = split(names, nl, " "); for (i = 1; i <= k; i++) lib[nl[i]] = 1 }
      function bare(w) { gsub(/["\047]/, "", w); sub(/^.*\//, "", w); sub(/\.(sh|py)$/, "", w); return w }
      FNR == 1 { pass++ }
      /^[ \t]*#/ { next }
      pass == 1 {
        if (match($0, /for[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]+in[ \t]/)) {
          hd = substr($0, RSTART, RLENGTH); v = hd; sub(/^for[ \t]+/, "", v); sub(/[ \t].*$/, "", v)
          rest = substr($0, RSTART + RLENGTH); sub(/;.*$/, "", rest)
          m = split(rest, wl, /[ \t]+/)
          for (i = 1; i <= m; i++) if (bare(wl[i]) in lib) loopvar[v] = 1   # SENTINEL-LOOPVAR
        }
        next
      }
      {
        line = $0
        if (line ~ /#[ \t]*stage-libs-ok:[ \t]*[^ \t]+[ \t]+[^ \t]+[ \t]+[^ \t]+/) next
        hit = 0; ns = split(line, stmt, /;|&&|\|\|/)   # per statement: a cmp after the cp is not its destination
        for (j = 1; j <= ns && !hit; j++) {
        s = stmt[j]
        if (s !~ /(^|[&|({ \t])(cp|ln)[ \t]/) continue
        while (!hit && match(s, /lib\/[A-Za-z0-9_.${}-]+/)) {
          tok = substr(s, RSTART + 4, RLENGTH - 4); pre = substr(s, 1, RSTART - 1); after = substr(s, RSTART + RLENGTH)
          src = 0
          if (pre !~ /(tests\/|\$HERE\/|\$\{HERE\}\/)$/) {
            t = tok
            if (t ~ /^\$/) { gsub(/[${}]/, "", t); sub(/\..*$/, "", t); if (loopvar[t] == 1) src = 1 }
            else if (t ~ /\.(sh|py)$/) { sub(/\.(sh|py)$/, "", t); if (t in lib) src = 1 }
          }
          if (src && after ~ /\/lib([\/"\047 \t;]|$)/) hit = 1
          s = after
        }
        }
        if (hit) printf "%s:%d: %s\n", name, FNR, $0
      }
    ' "$f" "$f"
  done
  [ "$n" -gt 0 ] || return 2
}
lint_dir() { [ -d "$1" ] || return 2; lint_files "$1"/*.test.sh; }
# SENTINEL-RATCHET-MATCH: the ratchet lookup; the teeth flip its result.
is_ratcheted() { case $'\n'"$RATCHET_LIST" in *$'\n'"$1"$'\n'*) return 0 ;; esac; return 1; }

# ---- b1/b2 the real suites: no un-ratcheted hand list, no stale ratchet entry
if [ "${LINT_RATCHET:-1}" = 0 ]; then RATCHET_LIST=""; else RATCHET_LIST="$RATCHET"; fi
hits="$(lint_dir "$SCAN_DIR")"; lrc=$?
if [ "$lrc" -ne 0 ]; then
  no "b1 scan: no suite found under $SCAN_DIR (absent/empty input, rc=$lrc)"
else
  bad_hits=""; seen=" "
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    s="${line%%:*}"; seen="$seen$s "
    is_ratcheted "$s" || bad_hits="$bad_hits$line"$'\n'
  done <<<"$hits"
  if [ -z "$bad_hits" ]; then ok "b1 no suite hand-copies toolbelt libs outside the ratchet ($(grep -c . <<<"$RATCHET_LIST") listed)"
  else
    no "b1 hand-maintained lib copy (use rsdd_stage_libs from tests/lib/stage-libs.sh, or mark the line # stage-libs-ok: <reason>):"
    printf '%s' "$bad_hits" | sed 's/^/        /'
  fi
  stale=""
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    [[ "$seen" == *" $r "* ]] || stale="$stale $r"
  done <<<"$RATCHET_LIST"
  if [ -z "$stale" ]; then ok "b2 every ratchet entry still hand-copies (none stale)"
  else no "b2 stale ratchet entr(y/ies) -- the suite no longer hand-copies; delete the line:$stale"; fi
fi

# ---- b3 the detector on planted files (both sides)
PLANT="$W/plant"; mkdir -p "$PLANT"
mkp() { printf '%s\n' "$2" > "$PLANT/$1.test.sh"; }
mkp literal    'cp "$HERE/../lib/block-files.sh" "$box/lib/"'
mkp literalto  'mkdir -p "$d/lib" && cp "$TOOLBELT/lib/tool-env.sh" "$d/lib/tool-env.sh"'
mkp lnform     'ln -s "$HERE/../lib/state-files.sh" "$k/toolbelt/lib/state-files.sh"'
mkp pyform     'cp "$TB/lib/adapter_core.py" "$T/toolbelt/lib"'
mkp forloop    'for _l in retro-status target-paths; do cp "$HERE/../lib/$_l.sh" "$box/toolbelt/lib/$_l.sh"; done'
mkp forsplit   $'for l in block-files.sh gap-rows.sh; do\n  cp "$KIT/lib/$l" "$tb/lib/"\ndone'
mkp twolibs    'cp "$HERE/../lib/corpus-markers.sh" "$HERE/../lib/gh-visibility.sh" "$k/toolbelt/lib/"'
mkp comment    '# cp "$HERE/../lib/block-files.sh" "$box/lib/"'
mkp exempt     'cp "$HERE/../lib/block-files.sh" "$box/lib/"   # stage-libs-ok: needs only this one stale copy'
mkp shortok    'cp "$HERE/../lib/block-files.sh" "$box/lib/"   # stage-libs-ok: too short'
mkp testslib   'cp "$HERE/lib/mutant.sh" "$MUT/tests/lib/mutant.sh"'
mkp notalib    'cp "$HERE/../lib/not-a-real-lib.sh" "$box/lib/"'
mkp nolibdest  'cp "$HERE/../lib/block-files.sh" "$box/block-files.sh"'
mkp otherloop  'for f in a b; do cp "$HERE/../lib/$f.sh" "$box/lib/"; done'
mkp stager     'rsdd_stage_libs "$box/toolbelt" --except tool-env.sh'
mkp sourced    '. "$HERE/../lib/block-files.sh"'
mkp cmpafter   'mkdir -p "$1/lib" && cp "$2" "$1/lib/tool-env.sh" && cmp -s "$2" "$1/lib/tool-env.sh"'
mkp_hits="$(lint_dir "$PLANT")"
for s in literal literalto lnform pyform forloop forsplit twolibs shortok; do
  if grep -q "^$s:" <<<"$mkp_hits"; then ok "b3 lint flags the '$s' hand-copy form"
  else no "b3 lint missed the '$s' hand-copy form (hits=[$mkp_hits])"; fi
done
for s in comment exempt testslib notalib nolibdest otherloop stager sourced cmpafter; do
  if grep -q "^$s:" <<<"$mkp_hits"; then no "b3 lint false-positive on '$s' (hits=[$mkp_hits])"
  else ok "b3 lint ignores '$s'"; fi
done

# ---- b4 absent / empty input is a typed failure, not a clean zero
lint_dir "$W/does-not-exist" >/dev/null 2>&1; r_abs=$?
mkdir -p "$W/emptyd"; lint_dir "$W/emptyd" >/dev/null 2>&1; r_emp=$?
if [ "$r_abs" -eq 2 ] && [ "$r_emp" -eq 2 ]; then ok "b4 absent and empty scan dirs both return rc 2 (never a silent zero)"
else no "b4 expected rc 2 for absent/empty dirs (absent=$r_abs empty=$r_emp)"; fi

# ---- b5 end to end: the suite run against the planted hand copies, ratchet off, must fail
if [ -n "${STAGE_LIBS_NESTED:-}" ]; then :
elif STAGE_LIBS_NESTED=1 LINT_SCAN_DIR="$PLANT" LINT_RATCHET=0 bash "$HERE/$SELF" >/dev/null 2>&1; r_plant=$?; [ "$r_plant" -eq 1 ]; then
  ok "b5 suite exits 1 on a directory containing a hand copy (ratchet off)"
else no "b5 expected exit 1 on a planted hand copy, got rc=${r_plant:-?}"; fi

# ==========================================================================
# TEETH (--prove-teeth only)
# ==========================================================================
if [ "${1:-}" = "--prove-teeth" ]; then
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  mutant_bootstrap mutant_chain mutant_tooth mutant_cleanup_register || exit 2
  MT="$(mktemp -d)"
  mutant_cleanup_register "$MT" || { rm -rf "$MT"; echo "FATAL: mutant_cleanup_register refused $MT" >&2; exit 2; }
  REAL_HELPER="$HERE/lib/stage-libs.sh"
  # helper teeth: the nested suite runs against the mutant helper and must fail the named case
  ht() {   # ht LABEL CASE SED_EXPR
    local label="$1" case_id="$2" expr="$3" m="$MT/$4/tests/lib/stage-libs.sh"
    mkdir -p "${m%/*}" || { fail=$((fail+1)); return; }
    if mutant_chain "teeth: $label" "$REAL_HELPER" "$m" "$expr"; then
      if mutant_tooth "teeth: $label" 0 1 "$m" --orig "$REAL_HELPER" --bad-has "FAIL  $case_id " \
           -- env STAGE_LIBS_NESTED=1 RSDD_STAGE_LIBS_SRC="$TB/lib" STAGE_LIBS_HELPER=@SUT@ bash "$HERE/$SELF"; then
        pass=$((pass+1)); else fail=$((fail+1)); fi
    else fail=$((fail+1)); fi
  }
  echo "-- teeth: helper mutants must each turn their pinning case red --"
  ht "helper skips the last file" a1 's/i < \${#_rsl_files\[@\]}; i++/i < ${#_rsl_files[@]} - 1; i++/' h-skiplast
  ht "helper drops cp -p" a2 's/cp -p -- /cp -- /' h-nomode
  ht "helper ignores --except" a3 's/_rsdd_stage_excepted "\$_rsl_b" && continue/:/' h-noexcept
  ht "helper accepts an unknown --except" a4 's/_rsdd_stage_has "\$_rsl_src" "\$_rsl_e" ||/true ||/' h-typo
  ht "helper without the live-tree refusal" a5 's/^\( *\)_rsdd_stage_placement "\$_rsl_dest" "\$_rsl_src" || return 2$/\1:/' h-live
  ht "helper copies directories" a6 's/\[ -f "\$_rsl_f" \] || continue/[ -e "$_rsl_f" ] || continue/' h-dirs

  echo "-- teeth: lint mutants must each turn their pinning check red --"
  lt() {   # lt LABEL EXPR OUT WANT_FAIL_RE [ENV...]
    local label="$1" expr="$2" m="$MT/$3" want="$4"; shift 4
    if mutant_chain "teeth: $label" "$HERE/$SELF" "$m" "$expr"; then
      local mout oout
      mout="$(cd "$MT" && env STAGE_LIBS_NESTED=1 STAGE_LIBS_HELPER="$REAL_HELPER" STAGE_LIBS_TOOLBELT="$TB" LINT_SCAN_DIR="$HERE" "$@" bash "$m" 2>&1)"
      oout="$(env STAGE_LIBS_NESTED=1 STAGE_LIBS_HELPER="$REAL_HELPER" "$@" bash "$HERE/$SELF" 2>&1)"
      if grep -qE "$want" <<<"$oout"; then no "teeth $label: the ORIGINAL already matches '$want' (control proves nothing)"
      elif grep -qE "$want" <<<"$mout"; then ok "teeth $label: $want"
      else no "teeth $label: mutant stayed green (THEATER)"; fi
    else no "teeth $label: could not build mutant (refused by lib/mutant.sh)"; fi
  }
  lt "lint ignores for-loop variables" 's/if (bare(wl\[i\]) in lib) loopvar\[v\] = 1/if (0) loopvar[v] = 1/' \
     stage-libs.MUT1.test.sh "^  FAIL  b3 lint missed the 'forloop'"
  lt "lint ignores literal lib names" 's/if (t in lib) src = 1/if (0) src = 1/' \
     stage-libs.MUT2.test.sh "^  FAIL  b3 lint missed the 'literal'"
  lt "ratchet with an entry that no longer hand-copies" '/^RATCHET="$/s/$/\nnot-a-suite-at-all/' \
     stage-libs.MUT3.test.sh '^  FAIL  b2 stale ratchet'
  lt "ratchet lookup that waives everything" '/^is_ratcheted()/s/return 1; }/return 0; }/' \
     stage-libs.MUT4.test.sh '^  PASS  b1 ' LINT_SCAN_DIR="$PLANT" LINT_RATCHET=0
fi

printf '== %d passed · %d failed ==\n' "$pass" "$fail"
[ "$pass" -gt 0 ] || { echo "FATAL: zero tests executed" >&2; exit 2; }
[ "$fail" -eq 0 ] || exit 1
