#!/usr/bin/env bash
# research-sdd-install.test.sh — RED-FIRST harness for the multi-harness kit installer.
#
# The discriminating behaviour: ONE table-driven install loop surfaces the neutral SKILL.md +
# a launcher into every harness's own paths (claude / pi / gentle-shell), WITHOUT any per-harness
# branching in the loop. --dry-run must print a deterministic plan (locked by committed goldens);
# apply must be idempotent (re-running never duplicates the marked prompt section).
#
# Usage: research-sdd-install.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression · 2 setup.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../research-sdd-install.sh"
GOLD="$HERE/golden"
KITROOT="$(cd "$HERE/../.." && pwd)"  # LINT-CD-PHYSICAL-OK: test driver locating its SUT; tests run from the kit checkout, never through a rendered/symlinked toolbelt (kit issue #1024 round 5)
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
# Mutants and drivers are built in a TEMP COPY of the install dir, never beside the live SUT
# (kit issue #1156): the copy keeps the relative layout (SELF-based adapters.sh lookup, KIT=SELF/..),
# every other kit entry is symlinked read-only from the live kit. Everything dies with $TMP, so no
# per-mutant cleanup list is needed and a SIGKILL leaves nothing in the working tree.
# shellcheck source=../../toolbelt/tests/lib/mutant.sh
. "$HERE/../../toolbelt/tests/lib/mutant.sh" || { echo "FATAL: mutant helper missing" >&2; exit 2; }
MK="$TMP/mkkit"; MKI="$MK/install"
mkdir -p "$MKI" || { echo "FATAL: cannot create $MKI" >&2; exit 2; }
for _f in "$KITROOT/install"/*; do
  [ "$_f" = "$KITROOT/install/tests" ] && continue
  cp -R "$_f" "$MKI/" || { echo "FATAL: cannot copy $_f into the temp install copy" >&2; exit 2; }
done
# Dotfiles included (kit issue #1299 item 7): "$KITROOT"/* alone skips them. `.[!.]*` excludes . and ..;
# an unmatched glob stays literal, hence the existence guard.
for _f in "$KITROOT"/* "$KITROOT"/.[!.]*; do
  [ -e "$_f" ] || [ -L "$_f" ] || continue
  [ "$_f" = "$KITROOT/install" ] && continue
  ln -s "$_f" "$MK/$(basename "$_f")" || { echo "FATAL: cannot link $_f into the temp kit copy" >&2; exit 2; }
done
[ -f "$MKI/research-sdd-install.sh" ] && [ -f "$MKI/adapters.sh" ] \
  || { echo "FATAL: temp install copy is incomplete: $MKI" >&2; exit 2; }
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

# --- Live-tree hermeticity (kit issue #1156) ---------------------------------------------------
# This suite used to write its mutants and drivers INTO research-sdd/install/ (beside the SUT),
# so a concurrent shellcheck of install/**/*.sh saw transient files and a SIGKILL left them behind.
# Every mutant and driver now lives in a temp copy of the install dir. The snapshot below is taken
# before anything runs and compared at the END of the suite, before the EXIT trap removes anything
# — so a file the suite wrote into the live tree and has not yet cleaned is still seen.
# Tracked: path + content checksum (POSIX cksum) of every file, path of every directory, and path +
# target of every symlink under research-sdd/install (tests/ included). No GNU `find -printf` (kit
# issue #1299 item 7: a BSD find rejects it, which made the suite FATAL there). Content, not mtime:
# an identical-bytes rewrite is not a change (the run-all kit-tree guard uses the same rule).
# Absent-input guard: a snapshot that is empty or whose find failed would read as "unchanged".
_install_tree_snapshot() {
  local root="${1:-$KITROOT/install}" dirs files links
  dirs="$(find "$root" -mindepth 1 -type d)" || return 1
  files="$(find "$root" -mindepth 1 -type f -exec cksum {} +)" || return 1
  links="$(find "$root" -mindepth 1 -type l -exec sh -c 'for p; do printf "%s\tlink:%s\n" "$p" "$(readlink "$p")"; done' sh {} +)" || return 1
  [ -n "$dirs$files$links" ] || return 1
  {
    # Directories by existence only: a directory's mtime moves on any entry change inside it.
    printf '%s\n' "$dirs" | awk -v pre="$root/" 'NF { if (index($0, pre) == 1) $0 = substr($0, length(pre) + 1); print $0 "\td" }'
    printf '%s\n' "$files" | awk -v pre="$root/" 'NF >= 3 { c = $1 ":" $2; sub(/^[^ ]+ [^ ]+ /, ""); if (index($0, pre) == 1) $0 = substr($0, length(pre) + 1); print $0 "\t" c }'
    printf '%s\n' "$links" | awk -F'\t' -v pre="$root/" 'NF >= 2 { if (index($1, pre) == 1) $1 = substr($1, length(pre) + 1); print $1 "\t" $2 }'
  } | LC_ALL=C sort
}
INSTALL_SNAP_BEFORE="$(_install_tree_snapshot)" \
  || { echo "FATAL: cannot snapshot $KITROOT/install (find failed or tree empty)" >&2; exit 2; }

# Normalise a per-run tmp home to a stable placeholder so goldens are machine-independent.
norm(){ sed "s|$1|{HOME}|g"; }
# Normalise the (machine-specific) kit root so the planned plugin symlink source is portable too.
# The installer persists the PHYSICALLY resolved kit path (cd -P / pwd -P), while KITROOT above is the LOGICAL
# path the suite was invoked through — they differ whenever the suite is reached through a symlink anywhere on
# its path (kit issue #1349: `dry-run plan (claude|codex) drifted from golden`, `Kit path: {KIT}` vs an
# absolute path). Normalise BOTH forms, regex-escaped so a '.', '[' or '&' in the path is literal.
KITROOT_P="$(cd -P "$KITROOT" && pwd -P)"
_sed_lit(){ printf '%s' "$1" | sed 's/[][\\.*^$|&]/\\&/g'; }
# _normkit_for <logical> <physical> — stdin→stdout; the LONGER form is substituted first so a prefix
# relationship cannot split it, in either direction: logical a prefix of physical (the usual case — the
# suite reached through a symlinked parent) or physical a prefix of logical (a symlink pointing up,
# e.g. /r/a/link -> /r; kit issue #1472). Equal lengths mean the same string.
_normkit_for(){
  local l p
  l="$(_sed_lit "$1")"; p="$(_sed_lit "$2")"
  if [ "${#2}" -ge "${#1}" ]; then sed -e "s|$p|{KIT}|g" -e "s|$l|{KIT}|g"
  else sed -e "s|$l|{KIT}|g" -e "s|$p|{KIT}|g"; fi
}
normkit(){ _normkit_for "$KITROOT" "$KITROOT_P"; }

# _direct_clean_profile_dir <dir> <config_root> — invokes _rsdd_clean_profile_dir DIRECTLY (never
# through the full install flow, so this exercises the guard in isolation regardless of what any
# earlier validation layer would have caught). Sources the real, UNMUTATED SUT's functions via a
# throwaway driver placed BESIDE it — SELF-based adapters.sh lookup inside research-sdd-install.sh
# needs $0 to resolve to that directory (same technique test 58 already established). Prints
# "RC=<n>" plus any stderr from the call; the caller greps the result.
_direct_clean_profile_dir() {
  local dir="$1" config_root="$2" driver
  driver="$MKI/research-sdd-install-direct-clean.$$.sh"
  printf '#!/usr/bin/env bash\nset -uo pipefail\n. "$(dirname "$0")/research-sdd-install.sh" --help >/dev/null 2>&1\n_rsdd_clean_profile_dir "$1" "$2"\necho "RC=$?"\n' > "$driver"
  bash "$driver" "$dir" "$config_root" 2>&1
  rm -f "$driver"
}

# _direct_dry_skill_plan <src> <dest> <force> <label> <marker> [profile] — invokes
# _rsdd_dry_skill_plan DIRECTLY on caller-supplied synthetic files (never real kit content), via
# the same throwaway driver technique — sources the real, UNMUTATED SUT's functions. [profile] is
# optional (kit issue #1024 round 4, item 4 — RDD R4-001 preview); omit it for a case that does
# not care about the profile-switch WARN.
_direct_dry_skill_plan() {
  local src="$1" dest="$2" force="$3" label="$4" marker="$5" profile="${6:-}" driver
  driver="$MKI/research-sdd-install-direct-plan.$$.sh"
  printf '#!/usr/bin/env bash\nset -uo pipefail\n. "$(dirname "$0")/research-sdd-install.sh" --help >/dev/null 2>&1\n_rsdd_dry_skill_plan "$1" "$2" "$3" "$4" "$5" "$6"\n' > "$driver"
  bash "$driver" "$src" "$dest" "$force" "$label" "$marker" "$profile" 2>&1
  rm -f "$driver"
}

# _extract_kit_refs <file> — every literal `$KIT/<path>` reference in <file>, one per line,
# normalized (a single trailing "." is end-of-sentence punctuation in this kit's prose — no real
# kit path ends in a bare ".", so it is always safe to strip). Two token shapes are EXCLUDED BY
# NAME, never silently dropped (anti-silent-zero, CLAUDE.md §7):
#   "..."     — a prose ellipsis ("every $KIT/... reference below"), not a path at all.
#   "retros/" — an explicit NEGATIVE example in SKILL.md ("...not `$KIT/retros/`"): kit doctrine
#               is that retros/ lives at the REPO ROOT, not under $KIT; asserting it exists under
#               the kit would assert the opposite of what that sentence says.
_extract_kit_refs() {
  local f="$1" tok
  grep -ohE '\$KIT/[A-Za-z0-9_./*-]+' "$f" | sed 's/^\$KIT\///' | sort -u | while IFS= read -r tok; do
    while [ "${tok%.}" != "$tok" ]; do tok="${tok%.}"; done
    case "$tok" in
      "...") continue ;;
      "retros/") continue ;;
    esac
    printf '%s\n' "$tok"
  done
}

# _assert_kit_refs_resolve <root> <file> — for every $KIT/<path> extracted from <file>, assert it
# resolves under <root>: a real file/dir for a literal token, or AT LEAST ONE glob match for a
# token containing "*" (e.g. toolbelt/corroborate-*.sh). Prints one "MISSING..." line per miss to
# stdout and exits nonzero if anything is missing; silent + exit 0 when everything resolves.
_assert_kit_refs_resolve() {
  local root="$1" file="$2" tok all_ok=0
  while IFS= read -r tok; do
    [ -z "$tok" ] && continue
    case "$tok" in
      *'*'*)
        # Deliberate glob expansion against the render root (checks for ANY match).
        # shellcheck disable=SC2086
        set -- "$root"/$tok
        if [ ! -e "$1" ]; then echo "MISSING(glob): $tok"; all_ok=1; fi
        ;;
      *)
        if [ ! -e "$root/$tok" ]; then echo "MISSING: $tok"; all_ok=1; fi
        ;;
    esac
  done < <(_extract_kit_refs "$file")
  return "$all_ok"
}

echo "== research-sdd-install.test.sh =="

# 1..3 — dry-run plan per harness matches its committed golden (locks WHERE + WHAT is written).
# (opencode dropped 2026-09-23 #954 — plan-opencode.txt deleted)
for h in claude pi gentle-shell; do
  home="$TMP/dry-$h"
  out="$(bash "$SUT" --dry-run --home "$home" --harness "$h" 2>&1 | norm "$home" | normkit)"
  g="$GOLD/plan-$h.txt"
  if [ ! -f "$g" ]; then no "golden missing: plan-$h.txt"; continue; fi
  if [ "$out" = "$(cat "$g")" ]; then ok "dry-run plan ($h) matches golden"
  else no "dry-run plan ($h) drifted from golden"; diff <(cat "$g") <(printf '%s\n' "$out") | head -20; fi
done

# 4 — dry-run writes NOTHING (pure planning).
home="$TMP/nowrite"; bash "$SUT" --dry-run --home "$home" --harness all >/dev/null 2>&1
[ ! -e "$home" ] && ok "dry-run creates no files" || no "dry-run mutated the filesystem under $home"

# 5 — apply installs the neutral SKILL.md into the harness's own skills dir (claude leg preserved).
home="$TMP/apply"; bash "$SUT" --home "$home" --harness all >/dev/null 2>&1
skill="$home/.claude/skills/research-sdd/SKILL.md"
if [ -f "$skill" ] && grep -q 'Research-SDD launcher' "$skill"; then ok "apply installs neutral SKILL.md (claude)"
else no "SKILL.md not installed for claude at $skill"; fi
[ -f "$home/.pi/agent/skills/research-sdd/SKILL.md" ] && ok "apply installs SKILL.md (pi leg)" || no "pi SKILL.md missing"
[ -f "$home/.gentle-shell/agent/skills/research-sdd/SKILL.md" ] && ok "apply installs SKILL.md (gentle-shell leg)" || no "gentle-shell SKILL.md missing"
# 6 — apply is idempotent: run twice, exactly ONE marked section in the prompt file.
home="$TMP/idem"
bash "$SUT" --home "$home" --harness claude >/dev/null 2>&1
bash "$SUT" --home "$home" --harness claude >/dev/null 2>&1
pf="$home/.claude/CLAUDE.md"
n="$(grep -c '<!-- research-sdd:start -->' "$pf" 2>/dev/null || echo 0)"
[ "$n" = 1 ] && ok "idempotent: exactly one marked section after two applies" || no "idempotency broken: $n marked sections in $pf"

# 7 — apply preserves pre-existing prompt-file content (markdown-sections splice, not clobber).
home="$TMP/preserve"; mkdir -p "$home/.claude"; printf '# my own notes\nkeep me\n' > "$home/.claude/CLAUDE.md"
bash "$SUT" --home "$home" --harness claude >/dev/null 2>&1
grep -q 'keep me' "$home/.claude/CLAUDE.md" && ok "markdown-sections preserves existing content" || no "existing CLAUDE.md content clobbered"

# 8 — pi leg documents the manual session-start sweep (no hook fires there); claude does NOT.
home="$TMP/sweep"; bash "$SUT" --home "$home" --harness all >/dev/null 2>&1
cx="$home/.pi/agent/AGENTS.md"; cl="$home/.claude/CLAUDE.md"
if grep -q 'sweep-retros.sh' "$cx" && grep -q 'verify-registry.sh' "$cx"; then ok "pi AGENTS.md documents the manual sweep fallback"
else no "pi sweep-fallback doc missing in $cx"; fi
grep -q 'sweep-retros.sh' "$cl" && no "claude section wrongly carries sweep fallback (has a hook)" || ok "claude section omits sweep fallback (hook fires instead)"

# 8b — kit issue #1110: pi + gentle-shell get MANDATORY session-start and session-end steps (they have no
#      hooks), and the text says enforcement is Claude-only; claude (hooked) carries none of it.
for pair in "pi:.pi/agent" "gentle-shell:.gentle-shell/agent"; do
  h8="${pair%%:*}"; pf8="$home/${pair#*:}/AGENTS.md"
  if grep -q 'MANDATORY' "$pf8" && grep -qF 'toolbelt/sweep-all.sh' "$pf8" \
     && grep -qF 'toolbelt/stage-retro-issues.sh <retro> --apply' "$pf8" \
     && grep -q 'Claude Code only' "$pf8"; then ok "$h8 AGENTS.md carries mandatory session-start + session-end steps (Claude-only enforcement stated)"
  else no "$h8 AGENTS.md lacks mandatory session-start/session-end steps (#1110) in $pf8"; fi
done
grep -q 'stage-retro-issues.sh' "$cl" && no "claude section wrongly carries manual session-end step (Stop hook fires)" || ok "claude section omits manual session-end step"
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: pi/gentle-shell mandatory session-end step (kit issue #1110) --"
  MSE="$MKI/adapters.MUTANT-SESSIONEND.$$.sh"
  if mutant_chain "teeth: SESSIONEND" "$HERE/../adapters.sh" "$MSE" '/Session-end retro (MANDATORY/,/stage-retro-issues.sh <retro> --apply/d'; then
    out_se="$(bash -c '. "$1"; rsdd_render_section pi /h /h/kit' _ "$MSE" 2>&1)"
    <<<"$out_se" grep -q 'stage-retro-issues.sh' \
      && no "teeth: session-end-less mutant still renders the step — check is THEATER" \
      || ok "teeth: removing the session-end step makes the rendered AGENTS.md lose stage-retro-issues.sh → the 8b assertion bites"
  fi
fi

# 10 — the install loop carries ZERO per-harness case arms (all divergence lives in the adapter table).
#      A case arm is a harness name at a statement boundary followed by `|` or `)` (e.g. `claude)`);
#      prose mentions like "(opencode)" in a comment are ignored.
if grep -Eq '^[[:space:]]*(claude|pi|gentle-shell)[|)]' "$SUT"; then no "installer has a per-harness case arm (should be table-driven)"
else ok "install loop has no per-harness branching"; fi

# 12 — CRITICAL 2: an orphaned start marker (no matching end, hand-edited file) in a MARKDOWN prompt file
#      must NOT drop every trailing user line to EOF. Dropping user content is the real risk, so the
#      contract here is PRESERVE + APPEND: trailing user content survives AND a fresh marked section
#      is appended.
home="$TMP/orphan"; mkdir -p "$home/.claude"
printf '# top\n<!-- research-sdd:start -->\nstale body\nIMPORTANT user tail line\n' > "$home/.claude/CLAUDE.md"
bash "$SUT" --home "$home" --harness claude >/dev/null 2>&1
pf="$home/.claude/CLAUDE.md"
ends="$(grep -c '<!-- research-sdd:end -->' "$pf" 2>/dev/null || echo 0)"
if grep -q 'IMPORTANT user tail line' "$pf" && [ "$ends" = 1 ] && grep -q '## Research-SDD' "$pf"; then
  ok "orphaned start marker (markdown): trailing user content preserved AND fresh section appended (append, not skip)"
else no "orphaned markdown marker mishandled (tail preserved? end markers=$ends — expected preserve+append)"; fi

# 13 — CRITICAL 3: on a partial failure (one harness's config-root non-writable), overall exit
#      MUST be nonzero AND the still-writable harnesses must still be installed.
#      (OpenCode dropped #954; codex and reasonix dropped #1471; now blocks .pi and checks claude +
#      gentle-shell still install.)
if [ "$(id -u)" -eq 0 ]; then ok "exit-code aggregation test skipped (running as root, chmod is a no-op)"
else
  home="$TMP/aggr"; mkdir -p "$home/.pi"; chmod 000 "$home/.pi"
  bash "$SUT" --home "$home" --harness all >/dev/null 2>&1; rc=$?
  chmod 755 "$home/.pi"
  [ "$rc" -ne 0 ] && ok "partial failure yields nonzero overall exit" || no "partial failure silently exited 0 (rc=$rc)"
  if [ -f "$home/.claude/skills/research-sdd/SKILL.md" ] && [ -f "$home/.gentle-shell/agent/skills/research-sdd/SKILL.md" ]; then
    ok "partial failure still installs the writable harnesses (claude + gentle-shell)"
  else no "writable harnesses not installed after a mid-loop failure"; fi
fi

# 14 — WARNING 1: a symlinked prompt-file target must be written THROUGH (link preserved, real target
#      updated), never replaced by a plain file (which would sever the link / clobber the wrong path).
home="$TMP/symlink"; mkdir -p "$home/.claude"
# Pre-seed the REAL target with an existing marked section so the re-splice takes the rewrite path
# (not the fresh-append path) — that is the path that historically severed the link via `mv`.
printf '# real target\nuser data line\n<!-- research-sdd:start -->\nold section\n<!-- research-sdd:end -->\n' \
  > "$home/.claude/real-notes.md"
ln -s real-notes.md "$home/.claude/CLAUDE.md"
bash "$SUT" --home "$home" --harness claude >/dev/null 2>&1
if [ -L "$home/.claude/CLAUDE.md" ] && grep -q 'user data line' "$home/.claude/real-notes.md" \
   && grep -q '<!-- research-sdd:start -->' "$home/.claude/real-notes.md"; then
  ok "symlinked prompt file written through (link preserved, target spliced)"
else no "symlinked prompt file was severed/replaced instead of written through"; fi

# 15 — ITEM 1: re-splicing an existing section MUST insert exactly ONE blank line between preserved
#      user content and the marked section (never glue the marker onto the prior line), and stay
#      byte-idempotent across further re-runs. Seed a file whose section abuts user content with NO
#      separator — the historically-glued rewrite path.
home="$TMP/blank-sep"; mkdir -p "$home/.claude"
printf '# top\nuser tail line\n<!-- research-sdd:start -->\nstale\n<!-- research-sdd:end -->\n' > "$home/.claude/CLAUDE.md"
bash "$SUT" --home "$home" --harness claude >/dev/null 2>&1
pf="$home/.claude/CLAUDE.md"
sep_ok=0
ln="$(grep -n '<!-- research-sdd:start -->' "$pf" | head -1 | cut -d: -f1)"
if [ -n "$ln" ] && [ "$ln" -ge 3 ]; then
  above="$(sed -n "$((ln-1))p" "$pf")"; above2="$(sed -n "$((ln-2))p" "$pf")"
  [ -z "$above" ] && [ -n "$above2" ] && sep_ok=1
fi
[ "$sep_ok" = 1 ] && ok "re-splice inserts exactly one blank-line separator before the marker" \
  || no "re-splice glued the marker onto the preceding user line (no blank separator)"
# idempotent: two more applies must leave byte-identical output (no growth).
bash "$SUT" --home "$home" --harness claude >/dev/null 2>&1; cp "$pf" "$TMP/blank-run2"
bash "$SUT" --home "$home" --harness claude >/dev/null 2>&1
diff -q "$TMP/blank-run2" "$pf" >/dev/null 2>&1 && ok "re-splice is byte-idempotent across re-runs" \
  || no "re-splice not idempotent (file grew/changed on a later run)"

# 31 — dry-run on an IDENTICAL deployed skill prints [up-to-date], not a plain INSTALL.
#      The §7 three-state rule applied to the plan: identical state must be distinguishable from absent.
home="$TMP/dryrun-identical"
bash "$SUT" --home "$home" --harness claude >/dev/null 2>&1              # seed: real install
out="$(bash "$SUT" --dry-run --home "$home" --harness claude 2>&1)"      # second run: identical
if <<<"$out" grep -q 'INSTALL.*\[up-to-date\]'; then
  ok "dry-run identical: shows [up-to-date] (absent vs identical distinguishable)"
else no "dry-run identical: missing [up-to-date] (got: $(printf '%s\n' "$out" | grep INSTALL || true))"; fi

# 32 — dry-run on a DIVERGED deployed skill prints SKIP and names --force-skill as the remedy.
#      The plan must not promise an install it will then refuse to perform.
home="$TMP/dryrun-diverged"; mkdir -p "$home/.claude/skills/research-sdd"
printf '# custom deployed content — not kit source\n' > "$home/.claude/skills/research-sdd/SKILL.md"
out="$(bash "$SUT" --dry-run --home "$home" --harness claude 2>&1)"
if <<<"$out" grep -q 'INSTALL.*SKIP.*--force-skill'; then
  ok "dry-run diverged: shows SKIP and names --force-skill remedy"
else no "dry-run diverged: plan wrong (got: $(printf '%s\n' "$out" | grep INSTALL || true))"; fi
[ ! -f "$home/.claude/skills/research-sdd/SKILL.md.local-backup" ] \
  && ok "dry-run diverged: no backup created" \
  || no "dry-run diverged: backup created unexpectedly"

# 33 — dry-run on a NOT-READABLE deployed skill prints SKIP (not INSTALL), naming permissions.
#      Mirrors the real-run guard at line ~228 so the plan and real behavior agree.
if [ "$(id -u)" -eq 0 ]; then
  ok "dry-run unreadable SKILL.md check skipped (running as root — chmod 000 is a no-op)"
else
  home="$TMP/dryrun-unreadable"; mkdir -p "$home/.claude/skills/research-sdd"
  printf '# some content\n' > "$home/.claude/skills/research-sdd/SKILL.md"
  chmod 000 "$home/.claude/skills/research-sdd/SKILL.md"
  out="$(bash "$SUT" --dry-run --home "$home" --harness claude 2>&1)"
  chmod 644 "$home/.claude/skills/research-sdd/SKILL.md"
  if <<<"$out" grep -q 'INSTALL.*SKIP.*not readable'; then
    ok "dry-run unreadable: shows SKIP for permissions issue (not a plain INSTALL)"
  else no "dry-run unreadable: wrong plan (got: $(printf '%s\n' "$out" | grep INSTALL || true))"; fi
fi

# 34 — --force-skill overwrites a diverged SKILL.md after backing it up to <path>.local-backup.
#      The backup must contain the original content so the operator can recover any deltas.
home="$TMP/force-overwrite"; mkdir -p "$home/.claude/skills/research-sdd"
printf '# custom local content — NOT kit source\nmy local delta\n' \
  > "$home/.claude/skills/research-sdd/SKILL.md"
bash "$SUT" --force-skill --home "$home" --harness claude >/dev/null 2>&1
sf="$home/.claude/skills/research-sdd/SKILL.md"
bak_fo="$home/.claude/skills/research-sdd/SKILL.md.local-backup"
if grep -q 'Research-SDD launcher' "$sf"; then
  ok "--force-skill installs kit source over diverged SKILL.md"
else no "--force-skill did not install kit source (still diverged or missing)"; fi
if [ -f "$bak_fo" ] && grep -q 'my local delta' "$bak_fo"; then
  ok "--force-skill backs up diverged content before overwriting"
else no "--force-skill backup missing or does not contain original content"; fi

# 35 — --force-skill + --dry-run plans the overwrite (with backup path) but writes nothing.
#      Exercises the compose requirement: force and dry-run must compose cleanly.
home="$TMP/force-dry"; mkdir -p "$home/.claude/skills/research-sdd"
printf '# custom\n' > "$home/.claude/skills/research-sdd/SKILL.md"
out="$(bash "$SUT" --force-skill --dry-run --home "$home" --harness claude 2>&1)"
sf="$home/.claude/skills/research-sdd/SKILL.md"
bak_fd="$home/.claude/skills/research-sdd/SKILL.md.local-backup"
if <<<"$out" grep -q 'INSTALL.*will overwrite.*backup'; then
  ok "--force-skill + dry-run: plans overwrite and names backup path"
else no "--force-skill + dry-run: plan wrong (got: $(printf '%s\n' "$out" | grep INSTALL || true))"; fi
if grep -q '# custom' "$sf" && [ ! -f "$bak_fd" ]; then
  ok "--force-skill + dry-run: writes nothing (file unchanged, no backup created)"
else no "--force-skill + dry-run: mutated the filesystem"; fi
# 3b — kit issue #1349: the suite reached through a SYMLINKED kit path. The installer renders the physical
#      path; the logical (symlink) path must not survive normalisation. RED against the old logical-only
#      normkit: `Kit path: <physical>` stayed in the output and the golden diff failed.
# A failed symlink creation skips THIS case only (typed, reasoned, never a silent pass) — it must not abort
# the suite and with it every later assertion, the hermeticity snapshot and the footer.
rm -rf "$TMP/kitlink"
KITLINK_OK=0
if ln -s "$KITROOT_P" "$TMP/kitlink" 2>"$TMP/kitlink.err" && [ -L "$TMP/kitlink" ]; then KITLINK_OK=1; fi
home="$TMP/dry-symlinked"
if [ "$KITLINK_OK" = 0 ]; then
  printf '  SKIP  dry-run plan via a symlinked kit path (#1349): cannot create %s -> %s (%s)\n' "$TMP/kitlink" "$KITROOT_P" "$(head -c 300 "$TMP/kitlink.err" 2>/dev/null)"
else
out="$(bash "$TMP/kitlink/install/research-sdd-install.sh" --dry-run --home "$home" --harness claude 2>&1 | norm "$home" | _normkit_for "$TMP/kitlink" "$KITROOT_P")"
if [ "$out" = "$(cat "$GOLD/plan-claude.txt")" ]; then ok "dry-run plan via a symlinked kit path normalises to the golden (#1349)"
else no "dry-run plan via a symlinked kit path drifted from golden (#1349; logical=$TMP/kitlink physical=$KITROOT_P)"; diff <(cat "$GOLD/plan-claude.txt") <(printf '%s\n' "$out") | head -20; fi
fi

# 35b — _normkit_for with the PHYSICAL path a strict prefix of the LOGICAL one (kit issue #1472): a
#       symlink that points UP (/r/a/link -> /r) makes physical=/r a prefix of logical=/r/a/link. The
#       longer form must be replaced first, otherwise the shorter one splits it ("{KIT}/a/link").
_nk_in="see /r/a/link/install/x and /r/other"
_nk_got="$(printf '%s\n' "$_nk_in" | _normkit_for "/r/a/link" "/r")"
if [ "$_nk_got" = "see {KIT}/install/x and {KIT}/other" ]; then ok "_normkit_for: physical a strict prefix of logical normalises both without splitting (#1472)"
else no "_normkit_for: physical-prefix-of-logical split the logical path (#1472; got: $_nk_got)"; fi
# and the common direction (logical a strict prefix of physical) keeps working
_nk_got="$(printf '%s\n' "see /r/real/install/x and /r/other" | _normkit_for "/r" "/r/real")"
if [ "$_nk_got" = "see {KIT}/install/x and {KIT}/other" ]; then ok "_normkit_for: logical a strict prefix of physical normalises both (#1472)"
else no "_normkit_for: logical-prefix-of-physical regressed (#1472; got: $_nk_got)"; fi
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: _normkit_for must order by length (always-physical-first mutant, in a subshell) --"
  # Mutant: the length test is forced true → physical is always substituted first (the pre-#1472 shape).
  _nk_m="$( eval "$(declare -f _normkit_for | sed 's/\[ "\${#2}" -ge "\${#1}" \]/true/')"
            printf '%s\n' "$_nk_in" | _normkit_for "/r/a/link" "/r" )"
  if [ "$_nk_m" != "see {KIT}/install/x and {KIT}/other" ] && [ -n "$_nk_m" ]; then
    ok "teeth: an always-physical-first _normkit_for splits the logical path → the #1472 fixture bites"
  else no "teeth: the always-physical-first mutant still normalised correctly (or did not run: [$_nk_m]) — #1472 fixture is THEATER"; fi
fi

# 36 — --help block integrity (kit issue #1024 round 4, item 5): usage() no longer prints a
#      hardcoded `sed -n 'A,Bp'` line range (which had to be hand-recomputed every time a
#      paragraph was added or removed — a repeated maintenance paper cut across rounds 2/3); it
#      now prints exactly the text between the `# HELP-START` / `# HELP-END` sentinel comments.
#      Assert the printed help: starts with "Usage:" (not a stray blank line), contains
#      --force-skill (inside the bracket), never leaks "set -uo pipefail" (outside the bracket)
#      NOR the sentinel comment lines themselves (review bookkeeping must never reach the user),
#      and ends at the managed-overwrite paragraph's last line (added kit issue #1024 round 3
#      item 2).
help_out="$(bash "$SUT" --help 2>&1)"
help_first="$(printf '%s\n' "$help_out" | head -1)"
help_last="$(printf '%s\n' "$help_out" | grep . | tail -1)"
help_ok=1
<<<"$help_out" grep -q -- '--force-skill'     || help_ok=0  # in range
<<<"$help_out" grep -q 'set -uo pipefail' && help_ok=0      # must stay outside range
<<<"$help_out" grep -qi 'HELP-START\|HELP-END' && help_ok=0  # sentinels never leak
[ "$help_first" = "Usage:" ]                                || help_ok=0  # starts at Usage:, no stray blank
<<<"$help_last" grep -q "must never report success" || help_ok=0  # last content line
[ "$help_ok" = 1 ] \
  && ok "--help: marker-delimited block correct (--force-skill present, no pipefail/sentinel leak, first/last lines match)" \
  || { no "--help: marker-delimited block wrong (lines=$(printf '%s\n' "$help_out"|wc -l), force-skill=$(printf '%s\n' "$help_out"|grep -c -- '--force-skill'), pipefail=$(printf '%s\n' "$help_out"|grep -c 'pipefail'), first='$help_first', last='$help_last') — full output follows (#1349)"
       printf '%s\n' "$help_out" | sed 's/^/    | /' | head -60
       printf '    (SUT=%s size=%s bytes)\n' "$SUT" "$(wc -c < "$SUT" 2>/dev/null)"; }

# 37 — unknown flag still returns exit 2 after the --force-skill case arm was added.
#      Regression guard: the new arm must not accidentally absorb or reroute unknown flags.
bash "$SUT" --unknown-arg-xyz 2>/dev/null; rc_unk=$?
[ "$rc_unk" -eq 2 ] \
  && ok "unknown flag still returns exit 2 (regression guard for new --force-skill case arm)" \
  || no "unknown flag returned $rc_unk after --force-skill was added (expected 2)"

# 38 — B1: --force-skill refuses (rc≠0) when .local-backup already exists.
#      A backup that exists may be the ONLY copy of deltas from a prior --force-skill run.
#      The operator resolves it by hand; the installer must not silently destroy it.
#      Also: the deployed file must remain unchanged, the backup must be preserved intact,
#      and the error message must name the backup so the operator knows what to act on.
home="$TMP/force-bak-exists"; mkdir -p "$home/.claude/skills/research-sdd"
printf '# diverged content\nDELTA-1\n' > "$home/.claude/skills/research-sdd/SKILL.md"
printf '# stale backup — contains deltas\n' > "$home/.claude/skills/research-sdd/SKILL.md.local-backup"
err_b1="$(bash "$SUT" --force-skill --home "$home" --harness claude 2>&1 >/dev/null)"; rc_b1=$?
sf_b1="$home/.claude/skills/research-sdd/SKILL.md"
bak_b1="$home/.claude/skills/research-sdd/SKILL.md.local-backup"
[ "$rc_b1" -ne 0 ] && ok "B1: --force-skill refuses (rc≠0) when backup already exists" \
  || no "B1: --force-skill exited 0 when backup exists — data loss possible"
grep -q 'DELTA-1' "$sf_b1" && ok "B1: deployed file untouched when backup guard fires" \
  || no "B1: deployed file overwritten even though backup guard should have refused"
grep -q 'stale backup' "$bak_b1" && ok "B1: existing backup preserved (not clobbered by cp)" \
  || no "B1: existing backup was clobbered"
<<<"$err_b1" grep -qi 'ERROR\|already exists' \
  && ok "B1: error message names the already-existing backup" \
  || no "B1: no error message about existing backup (operator has no signal)"

# 39 — B1: dry-run + --force-skill with existing backup shows SKIP (not 'will overwrite').
#      The plan must match what the real run will do — it would refuse, so the plan must say so.
home="$TMP/force-dry-bak"; mkdir -p "$home/.claude/skills/research-sdd"
printf '# diverged content\n' > "$home/.claude/skills/research-sdd/SKILL.md"
printf '# stale backup\n' > "$home/.claude/skills/research-sdd/SKILL.md.local-backup"
out="$(bash "$SUT" --force-skill --dry-run --home "$home" --harness claude 2>&1)"
if <<<"$out" grep -q 'INSTALL.*SKIP.*already exists'; then
  ok "B1: dry-run + --force-skill + existing backup: shows SKIP with backup name"
else no "B1: dry-run + --force-skill + existing backup: wrong plan (got: $(printf '%s\n' "$out" | grep INSTALL || true))"; fi

# 40 — B3: source SKILL.md unreadable — classified correctly in both branches.
#      cmp -s exits 2 ("trouble") on an unreadable source; the old code read that as "differs"
#      and produced a wrong "diverged" diagnosis. The new code must catch unreadable source
#      before cmp -s, make it its own state in dry-run, refuse (rc≠0) in real-run without
#      leaving a stray backup.
#      Uses a fake kit (symlink + copy of adapters.sh) so the real kit is never modified.
if [ "$(id -u)" -eq 0 ]; then
  ok "B3 dry-run source-unreadable check skipped (running as root — chmod 000 is a no-op)"
  ok "B3 dry-run no-diverged-label check skipped (root)"
  ok "B3 force-skill real-run source-unreadable check skipped (root)"
  ok "B3 no-stray-backup check skipped (root)"
else
  b3kit="$TMP/b3-fake-kit"
  mkdir -p "$b3kit/install" "$b3kit/skills/research-sdd"
  cp "$HERE/../adapters.sh" "$b3kit/install/adapters.sh"
  ln -sf "$SUT" "$b3kit/install/research-sdd-install.sh"
  printf 'fake source\n' > "$b3kit/skills/research-sdd/SKILL.md"
  chmod 000 "$b3kit/skills/research-sdd/SKILL.md"
  b3sut="$b3kit/install/research-sdd-install.sh"
  # Dry-run: existing deployed file + unreadable source → "source not readable", NOT "diverged"
  home="$TMP/b3-dry"; mkdir -p "$home/.claude/skills/research-sdd"
  printf '# deployed content\n' > "$home/.claude/skills/research-sdd/SKILL.md"
  out="$(bash "$b3sut" --dry-run --home "$home" --harness claude 2>&1)"
  if <<<"$out" grep -q 'INSTALL.*SKIP.*source.*not readable'; then
    ok "B3 dry-run: source unreadable classified correctly (distinct from diverged)"
  else no "B3 dry-run: wrong plan (got: $(printf '%s\n' "$out" | grep INSTALL || true))"; fi
  if <<<"$out" grep -q 'diverged'; then
    no "B3 dry-run: 'diverged' mis-diagnosis leaked through (cmp -s exit 2 not caught)"
  else ok "B3 dry-run: no 'diverged' label when source is unreadable"; fi
  # Real run + --force-skill: must fail without leaving a stray backup
  home="$TMP/b3-real"; mkdir -p "$home/.claude/skills/research-sdd"
  printf '# deployed content\n' > "$home/.claude/skills/research-sdd/SKILL.md"
  bash "$b3sut" --force-skill --home "$home" --harness claude >/dev/null 2>&1; rc_b3=$?
  bak_b3="$home/.claude/skills/research-sdd/SKILL.md.local-backup"
  [ "$rc_b3" -ne 0 ] && ok "B3 force-skill: refuses (rc≠0) when source is unreadable" \
    || no "B3 force-skill: exited 0 with unreadable source"
  [ ! -f "$bak_b3" ] && ok "B3 force-skill: no stray backup created when source is unreadable" \
    || no "B3 force-skill: stray backup left behind after failed source read"
  chmod 644 "$b3kit/skills/research-sdd/SKILL.md"
fi

# 41 — dest is a DIRECTORY (not a regular file): dry-run shows SKIP, real run warns, dir intact.
#      mkdir -p on a home with a directory at the skill path proceeds silently (parent exists),
#      then cp would copy INTO the directory as SKILL.md/SKILL.md — the harness silently never
#      loads the skill. Guard this in both branches.
home="$TMP/dir-at-dest"
mkdir -p "$home/.claude/skills/research-sdd/SKILL.md"  # SKILL.md is a directory
out="$(bash "$SUT" --dry-run --home "$home" --harness claude 2>&1)"
sf_dir="$home/.claude/skills/research-sdd/SKILL.md"
if <<<"$out" grep -q 'INSTALL.*SKIP.*not a regular file'; then
  ok "dir-at-dest dry-run: shows SKIP when skill_path is a directory"
else no "dir-at-dest dry-run: wrong plan (got: $(printf '%s\n' "$out" | grep INSTALL || true))"; fi
err_dir="$(bash "$SUT" --home "$home" --harness claude 2>&1 >/dev/null)"
if [ -d "$sf_dir" ] && ! [ -f "$sf_dir/SKILL.md" ] \
   && <<<"$err_dir" grep -qi 'WARNING.*not a regular file'; then
  ok "dir-at-dest real run: directory preserved, warned, no file created inside"
else no "dir-at-dest real run: wrong behavior (is dir? $([ -d "$sf_dir" ] && echo yes || echo no), inner-file? $([ -f "$sf_dir/SKILL.md" ] && echo yes || echo no))"; fi

# NEGATIVE CONTROL — neuter the idempotent splice (force blind append); two applies must then
# leave TWO marked sections, proving test 6's idempotency assertion has teeth.
if [ "${1:-}" = "--prove-teeth" ]; then
  if [ "$KITLINK_OK" = 0 ]; then printf '  SKIP  teeth: symlinked-kit normalisation tooth (no kitlink)\n'; else
  echo "-- teeth: logical-only kit normalisation (the pre-#1349 normkit) must leave the physical path behind --"
  old_out="$(bash "$TMP/kitlink/install/research-sdd-install.sh" --dry-run --home "$TMP/dry-symlinked" --harness claude 2>&1 | norm "$TMP/dry-symlinked" | sed "s|$TMP/kitlink|{KIT}|g")"
  if [ "$old_out" != "$(cat "$GOLD/plan-claude.txt")" ] && <<<"$old_out" grep -qF "Kit path: $KITROOT_P"; then
    ok "teeth: logical-only normalisation leaves 'Kit path: <physical>' → the #1349 case has teeth"
  else no "teeth: logical-only normalisation still matched the golden — the #1349 case is THEATER"; fi
  fi

  echo "-- teeth: neuter the marker-aware splice, expect duplicate sections on re-apply --"
  # Live beside the real SUT so the mutant still resolves adapters.sh + the kit's source SKILL.md.
  MUTANT="$MKI/research-sdd-install.MUTANT.$$.sh"
  # Break the "does the file already carry our marker?" guard so splice always appends.
  mutant_sed "$SUT" "$MUTANT" 's/grep -Fq -- "\$start" "\$file"/false/' \
    || no "teeth: MUTANT could not be built (refused by the mutant helper — see above)"
  bash -n "$MUTANT" 2>/dev/null \
    && ok "teeth: MUTANT1 parses (bash -n)" \
    || no "teeth: MUTANT1 is a syntax error — mutation is theater"
  home="$TMP/teeth"
  bash "$MUTANT" --home "$home" --harness claude >/dev/null 2>&1
  bash "$MUTANT" --home "$home" --harness claude >/dev/null 2>&1
  n="$(grep -c '<!-- research-sdd:start -->' "$home/.claude/CLAUDE.md" 2>/dev/null || echo 0)"
  [ "$n" -ge 2 ] && ok "teeth: append-only mutant duplicates the section → idempotency check has teeth" \
    || no "teeth: mutant did not duplicate ($n) — idempotency check is THEATER"

  echo "-- teeth: collapse dry-run diverged label, expect test 32 [SKIP+--force-skill] check to fail --"
  # Break the diverged dry-run branch by replacing the [SKIP label with a neutral string, so the
  # grep for 'INSTALL.*SKIP.*--force-skill' no longer matches — test 32 goes red.
  MUTANT4="$MKI/research-sdd-install.MUTANT4.$$.sh"
  mutant_sed "$SUT" "$MUTANT4" 's/SKIP — diverged; use --force-skill to overwrite/up-to-date/' \
    || no "teeth: MUTANT4 could not be built (refused by the mutant helper — see above)"
  bash -n "$MUTANT4" 2>/dev/null \
    && ok "teeth: MUTANT4 parses (bash -n)" \
    || no "teeth: MUTANT4 is a syntax error — mutation is theater"
  home="$TMP/teeth-dryrun-diverged"; mkdir -p "$home/.claude/skills/research-sdd"
  printf '# custom deployed content\n' > "$home/.claude/skills/research-sdd/SKILL.md"
  out_m4="$(bash "$MUTANT4" --dry-run --home "$home" --harness claude 2>&1)"
  if <<<"$out_m4" grep -q 'INSTALL.*SKIP.*--force-skill'; then
    no "teeth: mutant still matched [SKIP+--force-skill] — dry-run diverged check is THEATER"
  else
    ok "teeth: diverged-label mutant breaks [SKIP+--force-skill] match → dry-run diverged check has teeth"
  fi

  echo "-- teeth: disable backup cp in --force-skill (FIXED: uses elif false, not line delete) --"
  # Replace the backup cp condition with false so the backup step always skips, but the rest of
  # the elif chain is syntactically intact. The SUT still parses; the overwrite runs but no backup
  # is created. Test 34's "backup contains original content" check then fails — proving it bites.
  MUTANT5="$MKI/research-sdd-install.MUTANT5.$$.sh"
  mutant_sed "$SUT" "$MUTANT5" 's/elif ! cp "\$dest" "\$bak"; then/elif false; then/' \
    || no "teeth: MUTANT5 could not be built (refused by the mutant helper — see above)"
  bash -n "$MUTANT5" 2>/dev/null \
    && ok "teeth: MUTANT5 parses (bash -n)" \
    || no "teeth: MUTANT5 is a syntax error — mutation is theater"
  home="$TMP/teeth-force-backup"; mkdir -p "$home/.claude/skills/research-sdd"
  printf '# custom local content\nmy local delta\n' > "$home/.claude/skills/research-sdd/SKILL.md"
  bash "$MUTANT5" --force-skill --home "$home" --harness claude >/dev/null 2>&1
  bak_t5="$home/.claude/skills/research-sdd/SKILL.md.local-backup"
  if [ -f "$bak_t5" ] && grep -q 'my local delta' "$bak_t5"; then
    no "teeth: backup-less mutant still produced a backup — force-skill backup check is THEATER"
  else
    ok "teeth: backup-less mutant has no backup → force-skill backup check has teeth"
  fi

  echo "-- teeth: disable B1 backup-exists guard, expect test 38 refuse check to fail --"
  # Replace the backup-exists guard with false so --force-skill runs even when backup exists.
  # Test 38's "rc≠0" assertion then fails — proving the guard is what makes the test bite.
  MUTANT6="$MKI/research-sdd-install.MUTANT6.$$.sh"
  mutant_sed "$SUT" "$MUTANT6" 's/if \[ -e "\$bak" \]; then/if false; then/' \
    || no "teeth: MUTANT6 could not be built (refused by the mutant helper — see above)"
  bash -n "$MUTANT6" 2>/dev/null \
    && ok "teeth: MUTANT6 parses (bash -n)" \
    || no "teeth: MUTANT6 is a syntax error — mutation is theater"
  home_m6="$TMP/teeth-b1-exists"; mkdir -p "$home_m6/.claude/skills/research-sdd"
  printf '# diverged\nDELTA-1\n' > "$home_m6/.claude/skills/research-sdd/SKILL.md"
  printf '# stale backup — DELTA-1 only copy\n' > "$home_m6/.claude/skills/research-sdd/SKILL.md.local-backup"
  bash "$MUTANT6" --force-skill --home "$home_m6" --harness claude >/dev/null 2>&1; rc_m6=$?
  [ "$rc_m6" -eq 0 ] \
    && ok "teeth: MUTANT6 (no backup-guard) exits 0 → B1 refuse check has teeth" \
    || no "teeth: MUTANT6 still refused — B1 refuse check is THEATER"

  echo "-- teeth: disable B3 source-unreadable check, expect test 40 to fail --"
  # Replace the source-unreadable guards (both branches) with false so an unreadable source falls
  # through to cmp -s (exits 2 = trouble, read as differs) → wrong "diverged" output in dry-run.
  if [ "$(id -u)" -eq 0 ]; then
    ok "teeth: MUTANT7 parse check skipped (root — chmod 000 is a no-op)"
    ok "teeth: MUTANT7 B3 check skipped (root)"
  else
    MUTANT7="$MKI/research-sdd-install.MUTANT7.$$.sh"
    mutant_sed "$SUT" "$MUTANT7" 's/elif \[ ! -r "\$src" \]; then/elif false; then/g' \
      || no "teeth: MUTANT7 could not be built (refused by the mutant helper — see above)"
    bash -n "$MUTANT7" 2>/dev/null \
      && ok "teeth: MUTANT7 parses (bash -n)" \
      || no "teeth: MUTANT7 is a syntax error — mutation is theater"
    m7kit="$TMP/teeth-b3-kit"
    mkdir -p "$m7kit/install" "$m7kit/skills/research-sdd"
    cp "$HERE/../adapters.sh" "$m7kit/install/adapters.sh"
    ln -sf "$MUTANT7" "$m7kit/install/research-sdd-install.sh"
    printf 'fake source\n' > "$m7kit/skills/research-sdd/SKILL.md"
    chmod 000 "$m7kit/skills/research-sdd/SKILL.md"
    m7sut="$m7kit/install/research-sdd-install.sh"
    home_m7="$TMP/teeth-b3"; mkdir -p "$home_m7/.claude/skills/research-sdd"
    printf '# deployed content\n' > "$home_m7/.claude/skills/research-sdd/SKILL.md"
    out_m7="$(bash "$m7sut" --dry-run --home "$home_m7" --harness claude 2>&1)"
    if <<<"$out_m7" grep -q 'INSTALL.*SKIP.*source.*not readable'; then
      no "teeth: MUTANT7 still shows 'source not readable' — B3 check is THEATER"
    else
      ok "teeth: MUTANT7 hides 'source not readable' → B3 check has teeth"
    fi
    chmod 644 "$m7kit/skills/research-sdd/SKILL.md"
  fi

  echo "-- teeth: remove 'Kit path:' from adapters.sh; expect test-52 'Kit path:' check to fail --"
  # Strip the Kit path: printf line from adapters.sh so the rendered section no longer carries the
  # fast-path anchor. Test 52's 'Kit path:' grep must then fail — proving the emit is what bites.
  MUTANT12="$MKI/adapters.MUTANT12.$$.sh"
  mutant_sed "$HERE/../adapters.sh" "$MUTANT12" '/printf.*Kit path:/d' \
    || no "teeth: MUTANT12 could not be built (refused by the mutant helper — see above)"
  bash -n "$MUTANT12" 2>/dev/null \
    && ok "teeth: MUTANT12 parses (bash -n)" \
    || no "teeth: MUTANT12 is a syntax error — mutation is theater"
  m12kit="$TMP/m12-fake-kit"
  mkdir -p "$m12kit/install" "$m12kit/skills/research-sdd"
  cp "$HERE/../research-sdd-install.sh" "$m12kit/install/research-sdd-install.sh"
  cp "$MUTANT12" "$m12kit/install/adapters.sh"
  printf '# placeholder skill\n' > "$m12kit/skills/research-sdd/SKILL.md"
  home_m12="$TMP/teeth-m12-kitpath"
  out_m12="$(bash "$m12kit/install/research-sdd-install.sh" --dry-run --home "$home_m12" --harness claude 2>&1)"
  if <<<"$out_m12" grep -q 'Kit path:'; then
    no "teeth: MUTANT12 still emits 'Kit path:' — test-52 Kit path check is THEATER"
  else
    ok "teeth: MUTANT12 omits 'Kit path:' → test-52 Kit path check has teeth"
  fi

  echo "-- teeth: re-add codex / reasonix to the adapter table; expect the dropped-harness checks (#1471) to fail --"
  # Mutant A re-adds codex to RESEARCH_SDD_HARNESSES (so the supported list and the unknown-harness
  # message name it). Mutant B re-registers reasonix's config root, so `--harness reasonix` no longer
  # hits the unknown-harness exit 2. Each is run through the same assertions as the live checks.
  MUTANT30A="$MKI/adapters.MUTANT30A.$$.sh"
  mutant_sed "$HERE/../adapters.sh" "$MUTANT30A" 's/^RESEARCH_SDD_HARNESSES="claude pi gentle-shell"/RESEARCH_SDD_HARNESSES="claude codex pi gentle-shell"/' \
    || no "teeth: MUTANT30A could not be built (refused by the mutant helper — see above)"
  # Mutant B is a COMPLETE re-registration of reasonix (every adapter table, default profile "claude"
  # so the fake kit needs no profile files), so the only thing that normally blocks it is the table.
  MUTANT30B="$MKI/adapters.MUTANT30B.$$.sh"
  mutant_sed "$HERE/../adapters.sh" "$MUTANT30B" 's/^declare -A _RSDD_CONFIG_ROOT_REL=($/&\n  [reasonix]=".reasonix"/;s/^declare -A _RSDD_PROMPT_FILE_NAME=($/&\n  [reasonix]="AGENTS.md"/;s/^declare -A _RSDD_PROMPT_STRATEGY=($/&\n  [reasonix]="markdown-sections"/;s/^declare -A _RSDD_SUPPORTS_SLASH=($/&\n  [reasonix]="false"/;s/^declare -A _RSDD_NEEDS_SWEEP=($/&\n  [reasonix]="true"/;s/^declare -A _RSDD_SKILL_SRC_RELKIT=($/&\n  [reasonix]="skills\/research-sdd\/SKILL.md"/;s/^declare -A _RSDD_DEFAULT_PROFILE=($/&\n  [reasonix]="claude"/' \
    || no "teeth: MUTANT30B could not be built (refused by the mutant helper — see above)"
  m30kit="$TMP/m30-fake-kit"
  mkdir -p "$m30kit/install" "$m30kit/skills/research-sdd"
  cp "$HERE/../research-sdd-install.sh" "$m30kit/install/research-sdd-install.sh"
  printf '# placeholder skill\n' > "$m30kit/skills/research-sdd/SKILL.md"
  cp "$MUTANT30A" "$m30kit/install/adapters.sh"
  err_m30a="$(bash "$m30kit/install/research-sdd-install.sh" --harness bogus --home "$TMP/m30a-home" 2>&1)"
  if <<<"$err_m30a" grep -q 'known: claude pi gentle-shell all'; then
    no "teeth: codex-re-added mutant still reports the exact supported list — the supported-list check is THEATER"
  else ok "teeth: re-adding codex to RESEARCH_SDD_HARNESSES changes the supported list → the supported-list check has teeth"; fi
  cp "$MUTANT30B" "$m30kit/install/adapters.sh"
  bash "$m30kit/install/research-sdd-install.sh" --harness reasonix --home "$TMP/m30b-home" >/dev/null 2>&1; rc_m30b=$?
  if [ "$rc_m30b" -eq 0 ] && [ -f "$TMP/m30b-home/.reasonix/skills/research-sdd/SKILL.md" ] \
     && grep -q '<!-- research-sdd:start -->' "$TMP/m30b-home/.reasonix/AGENTS.md" 2>/dev/null; then
    ok "teeth: a complete reasonix registration installs it (rc 0, SKILL.md + launcher written) → the adapter table is what blocks the dropped harness"
  else no "teeth: reasonix re-registered but not installed (rc=$rc_m30b) — the dropped-harness check is THEATER"; fi

fi

# 27 — DATA-LOSS REGRESSION: installing over a DIVERGED deployed SKILL.md must NOT clobber it.
#      The installer must preserve the deployed file and emit a WARNING naming the file.
#      (Regression guard for the unconditional `cp` bug that destroyed retro-applied deltas.)
home="$TMP/skill-diverge"; mkdir -p "$home/.claude/skills/research-sdd"
printf '# custom deployed content — not kit source\n' \
  > "$home/.claude/skills/research-sdd/SKILL.md"
err="$(bash "$SUT" --home "$home" --harness claude 2>&1 >/dev/null)"
sf="$home/.claude/skills/research-sdd/SKILL.md"
if grep -q 'custom deployed content' "$sf" && <<<"$err" grep -qi 'WARNING.*SKILL\.md'; then
  ok "SKILL.md diverged: deployed file preserved and warned (data-loss regression fixed)"
else
  no "SKILL.md diverged: deployed file was CLOBBERED (DATA LOSS — defining regression)"
fi

# 28 — SKILL.md identical to kit source: no spurious warning (clean silent no-op).
home="$TMP/skill-identical"
bash "$SUT" --home "$home" --harness claude >/dev/null 2>&1         # first install
err="$(bash "$SUT" --home "$home" --harness claude 2>&1 >/dev/null)" # second run on identical
if <<<"$err" grep -qi 'WARNING.*SKILL\.md'; then
  no "SKILL.md identical: spurious WARNING emitted (no-op should be silent)"
else
  ok "SKILL.md identical: no warning on identical file (clean silent no-op)"
fi

# 29 — OpenCode support was dropped on 2026-09-23 (#954); harness-specific source test removed.

# 30 — SKILL.md not readable (chmod 000): warns about permissions, not diverged content.
#      A mode-000 destination must produce a "not readable" WARNING, not the "diverged content"
#      WARNING, so the operator diagnoses the real cause (permissions, not a content conflict).
if [ "$(id -u)" -eq 0 ]; then
  ok "SKILL.md unreadable check skipped (running as root — chmod 000 is a no-op)"
else
  home="$TMP/skill-unreadable"; mkdir -p "$home/.claude/skills/research-sdd"
  sf="$home/.claude/skills/research-sdd/SKILL.md"
  printf '# content distinct from kit source\n' > "$sf"
  chmod 000 "$sf"
  err="$(bash "$SUT" --home "$home" --harness claude 2>&1 >/dev/null)"
  chmod 644 "$sf"
  if <<<"$err" grep -qi 'WARNING.*not readable' && ! <<<"$err" grep -qi 'diverged'; then
    ok "SKILL.md unreadable (chmod 000): warns about permissions, not diverged content"
  else
    no "SKILL.md unreadable (chmod 000): wrong or missing warning (expected 'not readable', got: [$err])"
  fi
fi

# 52 — the rendered launcher section must contain 'Kit path:' pointing at a
#      harness-relative (~/...) or absolute kit root — the installer-injected
#      fast-path that lets the SKILL.md skip the per-user hardcoded default.
#      Test in both a dry-run plan and a real applied prompt file.
home="$TMP/kitpath-check"
# dry-run plan: 'Kit path:' must appear inside the rendered SPLICE block
out_52="$(bash "$SUT" --dry-run --home "$home" --harness claude 2>&1)"
if <<<"$out_52" grep -q 'Kit path:'; then
  ok "52: dry-run plan contains 'Kit path:' in the rendered launcher section"
else
  no "52: dry-run plan is MISSING 'Kit path:' (fast-path not injected into launcher)"
fi
# real apply: the installed prompt file also carries 'Kit path:' in the splice
bash "$SUT" --home "$home" --harness claude >/dev/null 2>&1
pf_52="$home/.claude/CLAUDE.md"
if grep -q 'Kit path:' "$pf_52" 2>/dev/null; then
  ok "52: applied CLAUDE.md contains 'Kit path:' in the launcher section"
else
  no "52: applied CLAUDE.md is MISSING 'Kit path:' (fast-path not injected)"
fi

# ── kit issue #993 WU2: install-time prompt-profile selection ────────────────────────────────
# 53 — profile precedence: --profile flag > $RESEARCH_SDD_PROFILE env > per-harness default
#      (adapters.sh _RSDD_DEFAULT_PROFILE: claude=claude, pi=general, gentle-shell=general).
out_53a="$(bash "$SUT" --dry-run --home "$TMP/prec-a" --harness claude --profile general 2>&1)"
<<<"$out_53a" grep -q 'profile=general (source=flag)' \
  && ok "53a: --profile flag selects the profile and reports source=flag" \
  || no "53a: --profile flag not honored (got: $(printf '%s' "$out_53a" | grep profile=)))"

out_53b="$(RESEARCH_SDD_PROFILE=general bash "$SUT" --dry-run --home "$TMP/prec-b" --harness claude 2>&1)"
<<<"$out_53b" grep -q 'profile=general (source=env)' \
  && ok "53b: \$RESEARCH_SDD_PROFILE env selects the profile and reports source=env" \
  || no "53b: env var not honored (got: $(printf '%s' "$out_53b" | grep profile=)))"

out_53c="$(RESEARCH_SDD_PROFILE=general bash "$SUT" --dry-run --home "$TMP/prec-c" --harness claude --profile claude 2>&1)"
<<<"$out_53c" grep -q 'profile=claude (source=flag)' \
  && ok "53c: --profile flag wins over \$RESEARCH_SDD_PROFILE env (precedence)" \
  || no "53c: flag did not win over env (got: $(printf '%s' "$out_53c" | grep profile=)))"

out_53d="$(bash "$SUT" --dry-run --home "$TMP/prec-d" --harness pi 2>&1)"
<<<"$out_53d" grep -q 'profile=general (source=default)' \
  && ok "53d: pi falls back to its per-harness default (general)" \
  || no "53d: pi default wrong (got: $(printf '%s' "$out_53d" | grep profile=)))"

out_53e="$(bash "$SUT" --dry-run --home "$TMP/prec-e" --harness claude 2>&1)"
<<<"$out_53e" grep -q 'profile=claude (source=default)' \
  && ok "53e: claude falls back to its per-harness default (claude)" \
  || no "53e: claude default wrong (got: $(printf '%s' "$out_53e" | grep profile=)))"

# 54 — unknown profile → exit 2 with a clear message; nothing written to the filesystem.
#      Both entry points (--profile flag and $RESEARCH_SDD_PROFILE env) are validated.
out_54a="$(bash "$SUT" --dry-run --home "$TMP/unk-flag" --harness claude --profile bogus-profile-xyz 2>&1)"; rc_54a=$?
if [ "$rc_54a" -eq 2 ] && <<<"$out_54a" grep -qi "unknown profile 'bogus-profile-xyz'"; then
  ok "54a: unknown --profile exits 2 with a clear message naming the bad value"
else no "54a: unknown --profile: wrong exit/message (rc=$rc_54a, out=$out_54a)"; fi
[ ! -e "$TMP/unk-flag" ] && ok "54a: unknown --profile writes nothing to the filesystem" \
  || no "54a: unknown --profile mutated the filesystem before validating"

out_54b="$(RESEARCH_SDD_PROFILE=bogus-env-xyz bash "$SUT" --dry-run --home "$TMP/unk-env" --harness claude 2>&1)"; rc_54b=$?
if [ "$rc_54b" -eq 2 ] && <<<"$out_54b" grep -qi "unknown profile 'bogus-env-xyz'"; then
  ok "54b: unknown \$RESEARCH_SDD_PROFILE exits 2 with a clear message"
else no "54b: unknown env profile: wrong exit/message (rc=$rc_54b, out=$out_54b)"; fi

# 55 — profile "claude" (flag, env, and default) stays byte-identical to today: the installed
#      SKILL.md is the kit source, untouched by any profile plumbing (regression guard).
home_55="$TMP/claude-byte-identical"
bash "$SUT" --home "$home_55" --harness claude --profile claude >/dev/null 2>&1
if cmp -s "$KITROOT/skills/research-sdd/SKILL.md" "$home_55/.claude/skills/research-sdd/SKILL.md"; then
  ok "55: profile=claude installs a byte-identical copy of the kit source SKILL.md"
else no "55: profile=claude SKILL.md diverged from kit source"; fi
# Note: research-sdd/ ITSELF now legitimately exists even for profile=claude — it holds the F4
# profile-switch marker (kit issue #1024 review F4), a SIBLING of profile/, not a render. The
# regression guard this test protects is specifically "no render directory", i.e. no profile/.
[ ! -d "$home_55/.claude/research-sdd/profile" ] \
  && ok "55: profile=claude creates no research-sdd/profile render directory" \
  || no "55: profile=claude unexpectedly created a render directory"

# 56 — a non-default profile (general) real install: renders into
#      <config_root>/research-sdd/profile/<name>/, installs the RENDERED SKILL.md, and the
#      installed prompt file's "Kit path:" fast-path resolves (per SKILL.md's own "Resolving the
#      kit path" step 0: expand a leading ~ to $HOME) to the RENDERED PROMPT-LOOP.md — the one
#      containing "(read IN FULL once per context)". The discriminator text was originally
#      "(read in full now)" (kit issue #993 WU1 review correction: WU2's job) — WU1's own
#      placeholder wording for the hotcore-loop-cadence slot body, chosen only to prove the
#      renderer's plumbing worked, before any doctrine-accurate content existed. Kit issue #993
#      WU4 round 4 replaced that placeholder with the doctrine-verified wording (git log -S /
#      git show 6d88930, 3d875c7 — Opus- and RDD-approved), so this is WU2's job landing: update
#      the discriminator to the real current text rather than the placeholder it was standing in
#      for. Any distinguishing string proves the SAME thing (render reached the install); this one
#      is additionally correct doctrine.
home_56="$TMP/general-real"
bash "$SUT" --home "$home_56" --harness pi >/dev/null 2>&1
pf_56="$home_56/.pi/agent/AGENTS.md"
kitpath_56="$(grep '^Kit path:' "$pf_56" 2>/dev/null | sed 's/^Kit path: //')"
kitpath_56_expanded="${kitpath_56/#\~/"$home_56"}"
if [ -n "$kitpath_56" ] && [ -f "$kitpath_56_expanded/PROMPT-LOOP.md" ] \
   && grep -q '(read IN FULL once per context)' "$kitpath_56_expanded/PROMPT-LOOP.md"; then
  ok "56: installed skill's Kit-path resolution reaches the RENDERED PROMPT-LOOP.md"
else no "56: Kit-path resolution did not reach a rendered PROMPT-LOOP.md (kitpath='$kitpath_56')"; fi
if grep -q '(read IN FULL once per context)' "$KITROOT/PROMPT-LOOP.md"; then
  no "56 sanity: kit source PROMPT-LOOP.md already contains the rendered text — test cannot discriminate"
else ok "56 sanity: kit source PROMPT-LOOP.md does not contain the rendered text (test discriminates)"; fi
sf_56="$home_56/.pi/agent/skills/research-sdd/SKILL.md"
render_56="$home_56/.pi/agent/research-sdd/profile/general/skills/research-sdd/SKILL.md"
if [ -f "$sf_56" ] && [ -f "$render_56" ] && cmp -s "$sf_56" "$render_56"; then
  ok "56: installed SKILL.md matches the rendered profile output"
else no "56: installed SKILL.md does not match the rendered profile output"; fi

# 57 — re-running install for a rendered profile must not leave STALE renders: a leftover file
#      from a prior render (e.g. a slot id later removed from the profile) does not survive.
home_57="$TMP/stale-render"
bash "$SUT" --home "$home_57" --harness pi >/dev/null 2>&1
render_dir_57="$home_57/.pi/agent/research-sdd/profile/general"
echo "stale leftover from a prior render" > "$render_dir_57/STALE-MARKER.txt"
bash "$SUT" --home "$home_57" --harness pi >/dev/null 2>&1
[ ! -e "$render_dir_57/STALE-MARKER.txt" ] \
  && ok "57: stale file from a prior render is cleaned on re-install" \
  || no "57: stale render file survived a re-install"

# 58 — anti-destructive: the render-dir cleaner refuses to touch anything outside
#      <config_root>/research-sdd/profile/ (rc=2, target left byte-preserved). Sources the real
#      SUT's functions directly (never a mutant) via a throwaway driver placed BESIDE the real
#      SUT — SELF-based adapters.sh lookup inside research-sdd-install.sh needs $0 to resolve to
#      that directory (same technique the MUTANT12 kit-path test above already relies on).
DRIVER58="$MKI/research-sdd-install-driver58.$$.sh"
printf '#!/usr/bin/env bash\nset -uo pipefail\n. "$(dirname "$0")/research-sdd-install.sh" --help >/dev/null 2>&1\n_rsdd_clean_profile_dir "$1" "$2"\necho "RC=$?"\n' > "$DRIVER58"
mkdir -p "$TMP/outside-guard58"; echo "keepme" > "$TMP/outside-guard58/keepme.txt"
out_58="$(bash "$DRIVER58" "$TMP/outside-guard58" "$TMP/some-other-config-root" 2>&1)"
rm -f "$DRIVER58"; DRIVER58=""
if <<<"$out_58" grep -q 'RC=2' && [ -f "$TMP/outside-guard58/keepme.txt" ]; then
  ok "58: render-dir cleaner refuses (rc=2) a dir outside <config_root>/research-sdd/profile/, target preserved"
else no "58: render-dir cleaner did not refuse an out-of-convention dir (got: $out_58)"; fi

# ── kit issue #1024 review correction (R3-silent-overwrite-rendered-profile): the rendered-profile
#    SKILL.md deploy must honor the SAME divergence rule as the kit-source (claude) leg. Before this
#    fix it copied over the deployed SKILL.md unconditionally: no cmp -s check, no backup,
#    --force-skill ignored, and the dry-run plan always printed a bare INSTALL even when diverged.
# 59 — dry-run on a DIVERGED deployed skill (rendered profile) prints SKIP and names
#      --force-skill as the remedy — mirrors test 32 for the render leg.
home_59="$TMP/dryrun-diverged-render"; mkdir -p "$home_59/.pi/agent/skills/research-sdd"
printf '# custom deployed content — not the rendered profile\n' > "$home_59/.pi/agent/skills/research-sdd/SKILL.md"
out_59="$(bash "$SUT" --dry-run --home "$home_59" --harness pi 2>&1)"
if <<<"$out_59" grep -q 'INSTALL.*SKIP.*--force-skill'; then
  ok "59: dry-run diverged (rendered profile): shows SKIP and names --force-skill remedy"
else no "59: dry-run diverged (rendered profile): plan wrong (got: $(printf '%s\n' "$out_59" | grep INSTALL || true))"; fi
[ ! -f "$home_59/.pi/agent/skills/research-sdd/SKILL.md.local-backup" ] \
  && ok "59: dry-run diverged (rendered profile): no backup created" \
  || no "59: dry-run diverged (rendered profile): backup created unexpectedly"

# 60 — a plain re-install (no flags) of a rendered profile with a hand-edited deployed skill must
#      NOT clobber it (this used to silently overwrite unconditionally — the finding's core claim).
home_60="$TMP/render-noclobber"
bash "$SUT" --home "$home_60" --harness pi >/dev/null 2>&1
sf_60="$home_60/.pi/agent/skills/research-sdd/SKILL.md"
printf '# my hand-edited deployed skill — local delta\n' > "$sf_60"
err_60="$(bash "$SUT" --home "$home_60" --harness pi 2>&1 >/dev/null)"
if grep -q 'my hand-edited deployed skill' "$sf_60"; then
  ok "60: rendered-profile re-install preserves a hand-edited deployed SKILL.md (data-loss regression fixed)"
else no "60: rendered-profile re-install CLOBBERED a hand-edited deployed SKILL.md (DATA LOSS)"; fi
<<<"$err_60" grep -qi 'diverged' \
  && ok "60: rendered-profile re-install warns about the diverged deployed skill" \
  || no "60: rendered-profile re-install: no diverged warning printed (got: $err_60)"

# 61 — --force-skill overwrites a diverged deployed skill on the rendered-profile leg, backing it
#      up first — same contract as test 34 for the claude/kit-source leg.
home_61="$TMP/render-force-overwrite"
bash "$SUT" --home "$home_61" --harness pi >/dev/null 2>&1
sf_61="$home_61/.pi/agent/skills/research-sdd/SKILL.md"
printf '# custom local content — NOT the rendered profile\nmy local delta\n' > "$sf_61"
bash "$SUT" --force-skill --home "$home_61" --harness pi >/dev/null 2>&1
bak_61="$sf_61.local-backup"
render_61="$home_61/.pi/agent/research-sdd/profile/general/skills/research-sdd/SKILL.md"
if [ -f "$render_61" ] && cmp -s "$sf_61" "$render_61"; then
  ok "61: --force-skill installs the rendered profile over a diverged deployed skill"
else no "61: --force-skill did not install the rendered profile (still diverged or missing)"; fi
if [ -f "$bak_61" ] && grep -q 'my local delta' "$bak_61"; then
  ok "61: --force-skill backs up diverged content before overwriting (rendered-profile leg)"
else no "61: --force-skill backup missing or does not contain original content (rendered-profile leg)"; fi

# 62 — dry-run on an IDENTICAL deployed skill (rendered profile) prints [up-to-date], not a bare
#      INSTALL — mirrors test 31 for the render leg; also proves the dry-run classification diffs
#      against the ACTUAL rendered bytes, not a stale or placeholder comparison.
home_62="$TMP/dryrun-identical-render"
bash "$SUT" --home "$home_62" --harness pi >/dev/null 2>&1
out_62="$(bash "$SUT" --dry-run --home "$home_62" --harness pi 2>&1)"
if <<<"$out_62" grep -q 'INSTALL.*\[up-to-date\]'; then
  ok "62: dry-run identical (rendered profile): shows [up-to-date]"
else no "62: dry-run identical (rendered profile): missing [up-to-date] (got: $(printf '%s\n' "$out_62" | grep INSTALL || true))"; fi
[ ! -f "$home_62/.pi/agent/skills/research-sdd/SKILL.md.local-backup" ] \
  && ok "62: dry-run identical (rendered profile): no backup created" \
  || no "62: dry-run identical (rendered profile): backup created unexpectedly"

# ── TEETH for the profile feature (kit issue #993 WU2) ────────────────────────────────────────
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: neuter the unknown-profile guard in main(); expect test 54 to fail --"
  MUTANT13="$MKI/research-sdd-install.MUTANT13.$$.sh"
  mutant_sed "$SUT" "$MUTANT13" 's/if ! rsdd_valid_profile "\$resolved" "\$KIT"; then/if false; then/' \
    || no "teeth: MUTANT13 could not be built (refused by the mutant helper — see above)"
  bash -n "$MUTANT13" 2>/dev/null \
    && ok "teeth: MUTANT13 parses (bash -n)" \
    || no "teeth: MUTANT13 is a syntax error — mutation is theater"
  bash "$MUTANT13" --dry-run --home "$TMP/teeth-unk-profile" --harness claude --profile bogus-xyz-teeth >/dev/null 2>&1; rc_m13=$?
  if [ "$rc_m13" -eq 2 ]; then
    no "teeth: MUTANT13 still refused a bogus profile — unknown-profile guard check is THEATER"
  else
    ok "teeth: MUTANT13 (validation removed) accepts a bogus profile → unknown-profile guard check has teeth"
  fi

  echo "-- teeth: neuter --profile flag precedence in rsdd_resolve_profile; expect test 53a to fail --"
  MUTANT14="$MKI/adapters.MUTANT14.$$.sh"
  mutant_sed "$HERE/../adapters.sh" "$MUTANT14" 's/if \[ -n "\$flag" \]; then/if false; then/' \
    || no "teeth: MUTANT14 could not be built (refused by the mutant helper — see above)"
  bash -n "$MUTANT14" 2>/dev/null \
    && ok "teeth: MUTANT14 parses (bash -n)" \
    || no "teeth: MUTANT14 is a syntax error — mutation is theater"
  m14kit="$TMP/teeth-m14-kit"
  mkdir -p "$m14kit/install" "$m14kit/skills/research-sdd" "$m14kit/profiles"
  cp "$SUT" "$m14kit/install/research-sdd-install.sh"
  cp "$MUTANT14" "$m14kit/install/adapters.sh"
  printf '# placeholder skill\n' > "$m14kit/skills/research-sdd/SKILL.md"
  cp "$HERE/../../profiles/general.slots.md" "$m14kit/profiles/general.slots.md"
  out_m14="$("$m14kit/install/research-sdd-install.sh" --dry-run --home "$TMP/teeth-m14-home" --harness claude --profile general 2>&1)"
  if <<<"$out_m14" grep -q 'profile=general (source=flag)'; then
    no "teeth: MUTANT14 still honored the --profile flag — flag-precedence check is THEATER"
  else
    ok "teeth: MUTANT14 (flag ignored) falls through to default → flag-precedence check has teeth"
  fi

  echo "-- teeth: force the launcher to always use \$KIT (ignore kit_for_section); expect test 56 to fail --"
  MUTANT15="$MKI/research-sdd-install.MUTANT15.$$.sh"
  mutant_sed "$SUT" "$MUTANT15" 's/"\$dispatch" "\$h" "\$home" "\$prompt_file" "\$dry" "\$kit_for_section"/"$dispatch" "$h" "$home" "$prompt_file" "$dry" "$KIT"/' \
    || no "teeth: MUTANT15 could not be built (refused by the mutant helper — see above)"
  bash -n "$MUTANT15" 2>/dev/null \
    && ok "teeth: MUTANT15 parses (bash -n)" \
    || no "teeth: MUTANT15 is a syntax error — mutation is theater"
  home_m15="$TMP/teeth-m15-kitpath"
  bash "$MUTANT15" --home "$home_m15" --harness pi >/dev/null 2>&1
  kp_m15="$(grep '^Kit path:' "$home_m15/.pi/agent/AGENTS.md" 2>/dev/null | sed 's/^Kit path: //')"
  if <<<"$kp_m15" grep -q 'research-sdd/profile/general'; then
    no "teeth: MUTANT15 still pointed Kit path at the render dir — kit_for_section wiring check is THEATER"
  else
    ok "teeth: MUTANT15 (kit_for_section ignored) breaks Kit-path→render pointing → wiring check has teeth"
  fi

  echo "-- teeth: skip the render-dir clean call; expect test 57 (stale-render cleanup) to fail --"
  MUTANT16="$MKI/research-sdd-install.MUTANT16.$$.sh"
  mutant_sed "$SUT" "$MUTANT16" 's/! _rsdd_clean_profile_dir "\$render_dir" "\$config_root"/! true/' \
    || no "teeth: MUTANT16 could not be built (refused by the mutant helper — see above)"
  bash -n "$MUTANT16" 2>/dev/null \
    && ok "teeth: MUTANT16 parses (bash -n)" \
    || no "teeth: MUTANT16 is a syntax error — mutation is theater"
  home_m16="$TMP/teeth-m16-stale"
  bash "$MUTANT16" --home "$home_m16" --harness pi >/dev/null 2>&1
  render_dir_m16="$home_m16/.pi/agent/research-sdd/profile/general"
  echo "stale" > "$render_dir_m16/STALE-MARKER.txt"
  bash "$MUTANT16" --home "$home_m16" --harness pi >/dev/null 2>&1
  if [ -e "$render_dir_m16/STALE-MARKER.txt" ]; then
    ok "teeth: MUTANT16 (clean skipped) leaves the stale marker → stale-render cleanup check has teeth"
  else
    no "teeth: MUTANT16 still cleaned the stale marker — stale-render cleanup check is THEATER"
  fi

  echo "-- teeth: neuter BOTH containment checks (textual + realpath); expect test 58 to fail --"
  # Since kit issue #1024 review F2, containment is TWO independent checks (textual prefix +
  # realpath-resolved prefix) — removing only one no longer breaks the guard (the other still
  # catches it, proven by MUTANT18/19 below), so this combined mutant proves what removing BOTH
  # layers together does: the scenario this test always used (two textually-and-really unrelated
  # tmp dirs) needs both neutered to bypass, matching the pre-F2-fix single-layer behaviour.
  MUTANT17="$MKI/research-sdd-install.MUTANT17.$$.sh"
  mutant_sed "$SUT" "$MUTANT17" -e 's|"\$config_root"/research-sdd/profile/?\*) ;;|*) ;;|' \
      -e 's|"\$prefix_real"/?\*) ;;|*) ;;|' \
    || no "teeth: MUTANT17 could not be built (refused by the mutant helper — see above)"
  bash -n "$MUTANT17" 2>/dev/null \
    && ok "teeth: MUTANT17 parses (bash -n)" \
    || no "teeth: MUTANT17 is a syntax error — mutation is theater"
  if diff -q "$SUT" "$MUTANT17" >/dev/null 2>&1; then
    no "teeth: MUTANT17 pre-check: mutant = SUT — neither containment pattern matched"
  else
    ok "teeth: MUTANT17 pre-check: mutant differs (both containment patterns neutered)"
  fi
  mkdir -p "$TMP/teeth-m17-outside"; echo "keepme" > "$TMP/teeth-m17-outside/keepme.txt"
  # MUTANT17 IS a full SUT copy living beside adapters.sh, so it can source itself the same way
  # DRIVER58 does above — no separate driver file needed for a mutant that already lives there.
  printf '. "%s" --help >/dev/null 2>&1\n_rsdd_clean_profile_dir "%s" "%s"\necho RC=$?\n' \
    "$MUTANT17" "$TMP/teeth-m17-outside" "$TMP/teeth-m17-cfgroot" | bash >/dev/null 2>&1
  if [ -f "$TMP/teeth-m17-outside/keepme.txt" ]; then
    no "teeth: MUTANT17 still refused/preserved the outside dir — containment guard check is THEATER"
  else
    ok "teeth: MUTANT17 (both containment layers neutered) removes an out-of-convention dir → containment guard check has teeth"
  fi

  echo "-- teeth: neuter ONLY the realpath containment check (F2 review); expect F2d to fail --"
  # F2d's own scenario is TEXTUALLY prefixed (config_root/research-sdd/profile/../OTHER) so check
  # #1 alone never blocks it in the real (unmutated) code either — only the realpath-resolved
  # check (#3) does. Neutering ONLY that check therefore surgically isolates its contribution,
  # independent of MUTANT17 above.
  MUTANT18="$MKI/research-sdd-install.MUTANT18.$$.sh"
  mutant_sed "$SUT" "$MUTANT18" 's|"\$prefix_real"/?\*) ;;|*) ;;|' \
    || no "teeth: MUTANT18 could not be built (refused by the mutant helper — see above)"
  bash -n "$MUTANT18" 2>/dev/null \
    && ok "teeth: MUTANT18 parses (bash -n)" \
    || no "teeth: MUTANT18 is a syntax error — mutation is theater"
  cfg_root_m18="$TMP/teeth-m18-cfgroot"
  mkdir -p "$cfg_root_m18/research-sdd/profile" "$cfg_root_m18/research-sdd/OTHER"
  echo "sentinel" > "$cfg_root_m18/research-sdd/OTHER/keepme.txt"
  printf '. "%s" --help >/dev/null 2>&1\n_rsdd_clean_profile_dir "%s" "%s"\necho RC=$?\n' \
    "$MUTANT18" "$cfg_root_m18/research-sdd/profile/../OTHER" "$cfg_root_m18" | bash >/dev/null 2>&1
  if [ -f "$cfg_root_m18/research-sdd/OTHER/keepme.txt" ]; then
    no "teeth: MUTANT18 still refused/preserved the resolved-outside dir — realpath check is THEATER"
  else
    ok "teeth: MUTANT18 (realpath check neutered) removes a textually-prefixed-but-resolved-outside dir → realpath check has teeth"
  fi

  echo "-- teeth: neuter ONLY the symlink-chain check (F2 review); expect F2e to fail --"
  MUTANT19="$MKI/research-sdd-install.MUTANT19.$$.sh"
  mutant_sed "$SUT" "$MUTANT19" 's@\[ -L "\$config_root/research-sdd" \] || \[ -L "\$config_root/research-sdd/profile" \]@false@' \
    || no "teeth: MUTANT19 could not be built (refused by the mutant helper — see above)"
  bash -n "$MUTANT19" 2>/dev/null \
    && ok "teeth: MUTANT19 parses (bash -n)" \
    || no "teeth: MUTANT19 is a syntax error — mutation is theater"
  if diff -q "$SUT" "$MUTANT19" >/dev/null 2>&1; then
    no "teeth: MUTANT19 pre-check: mutant = SUT — symlink-check line not found"
  else
    ok "teeth: MUTANT19 pre-check: mutant differs (symlink-chain check neutered)"
  fi
  # Sentinel nested at elsewhere/profile/general/keepme.txt — the EXACT resolved path "dir"
  # points at through the symlink (see F2e's identical fix: a flat elsewhere/keepme.txt is never
  # inside what gets rm -rf'd, so it would "survive" regardless of whether the guard bites —
  # asserting only file-survival on that placement is theater, not a tooth).
  mkdir -p "$TMP/teeth-m19-elsewhere/profile/general"; echo "should-not-be-touched" > "$TMP/teeth-m19-elsewhere/profile/general/keepme.txt"
  home_m19="$TMP/teeth-m19-home"; mkdir -p "$home_m19"
  ln -s "$TMP/teeth-m19-elsewhere" "$home_m19/research-sdd"
  out_m19="$(printf '. "%s" --help >/dev/null 2>&1\n_rsdd_clean_profile_dir "%s" "%s"\necho RC=$?\n' \
    "$MUTANT19" "$home_m19/research-sdd/profile/general" "$home_m19" | bash 2>&1)"
  if <<<"$out_m19" grep -q 'RC=2' || [ -f "$TMP/teeth-m19-elsewhere/profile/general/keepme.txt" ]; then
    no "teeth: MUTANT19 still refused/preserved the symlink target — symlink-chain check is THEATER (got: $out_m19)"
  else
    ok "teeth: MUTANT19 (symlink-chain check neutered) removes through a symlinked research-sdd/ → symlink-chain check has teeth"
  fi
fi

# ── kit issue #1024 review round 2, F2 (HIGH, anti-destructive) ───────────────
# The profile name used to reach _rsdd_clean_profile_dir's rm -rf before any charset check:
# rsdd_valid_profile only checked that a *.slots.md FILE existed, and "../profiles/general"
# resolves (via the kit/profiles/ prefix cancelling the leading "../") to the real general.slots.md
# — so it passed validation. The clean guard's case-pattern is a TEXTUAL prefix match, which does
# not resolve "..", so "<config_root>/research-sdd/profile/../profiles/general" textually matches
# "<config_root>/research-sdd/profile/?*" even though it resolves OUTSIDE profile/ entirely.

# F2a: --profile with a ".." traversal is rejected UP FRONT (exit 2), before any harness is even
# processed (main()'s per-harness loop never starts — proven by the absence of "harness=" in the
# output), and nothing is written to the filesystem.
home_f2a="$TMP/f2-traversal-flag"
out_f2a="$(bash "$SUT" --dry-run --home "$home_f2a" --harness claude --profile "../profiles/general" 2>&1)"; rc_f2a=$?
if [ "$rc_f2a" -eq 2 ] && ! <<<"$out_f2a" grep -q 'harness='; then
  ok "F2a: '--profile ../profiles/general' rejected up front (exit 2, before any harness processing)"
else
  no "F2a: traversal profile not rejected up front (rc=$rc_f2a, out=$out_f2a)"
fi
[ ! -e "$home_f2a" ] && ok "F2a: nothing written to the filesystem" || no "F2a: filesystem touched despite rejection"

# F2b: the same traversal through $RESEARCH_SDD_PROFILE (the other entry point) is rejected too.
home_f2b="$TMP/f2-traversal-env"
out_f2b="$(RESEARCH_SDD_PROFILE="../profiles/general" bash "$SUT" --dry-run --home "$home_f2b" --harness claude 2>&1)"; rc_f2b=$?
if [ "$rc_f2b" -eq 2 ] && ! <<<"$out_f2b" grep -q 'harness='; then
  ok "F2b: \$RESEARCH_SDD_PROFILE=../profiles/general rejected up front (exit 2)"
else
  no "F2b: env traversal profile not rejected (rc=$rc_f2b, out=$out_f2b)"
fi

# F2c: end-to-end, real (non-dry) run — a sentinel living OUTSIDE research-sdd/profile/ (but
# still under the SAME --home, so this never touches a real user's config) survives an attempted
# traversal install. This is the exact shape that was reproduced against 6a0ff24 before the fix:
# the sentinel was deleted (rm -rf resolved "profile/../profiles/general" to "profiles/general").
home_f2c="$TMP/f2-deep-real"
mkdir -p "$home_f2c/.claude/research-sdd/profile" "$home_f2c/.claude/research-sdd/profiles/general"
echo "sentinel" > "$home_f2c/.claude/research-sdd/profiles/general/keepme.txt"
bash "$SUT" --home "$home_f2c" --harness claude --profile "../profiles/general" >/dev/null 2>&1
if [ -f "$home_f2c/.claude/research-sdd/profiles/general/keepme.txt" ]; then
  ok "F2c: sibling sentinel outside profile/ survives a traversal --profile attempt"
else
  no "F2c: sibling sentinel was deleted by a traversal --profile attempt (DATA LOSS)"
fi

# F2d: _rsdd_clean_profile_dir's guard compares REALPATH-resolved results, not just text —
# direct unit test (bypasses the upfront rsdd_valid_profile check entirely) so this specifically
# proves the second, independent layer. A dir that textually matches the profile/ prefix but
# resolves (via "..") to a sibling directory must be refused, and that sibling must survive.
cfg_root_f2d="$TMP/f2d-cfgroot"
mkdir -p "$cfg_root_f2d/research-sdd/profile" "$cfg_root_f2d/research-sdd/OTHER"
echo "sentinel" > "$cfg_root_f2d/research-sdd/OTHER/keepme.txt"
out_f2d="$(_direct_clean_profile_dir "$cfg_root_f2d/research-sdd/profile/../OTHER" "$cfg_root_f2d")"
if <<<"$out_f2d" grep -q 'RC=2' && [ -f "$cfg_root_f2d/research-sdd/OTHER/keepme.txt" ]; then
  ok "F2d: _rsdd_clean_profile_dir refuses a textually-prefixed but resolved-outside path (realpath guard)"
else
  no "F2d: _rsdd_clean_profile_dir did not refuse a resolved-outside path (got: $out_f2d)"
fi

# F2e: refuses when research-sdd/ itself (anywhere in the chain) is a symlink — a pre-planted
# symlink could otherwise redirect an even textually-and-realpath-safe-looking path elsewhere.
# The sentinel is nested at .../elsewhere/profile/general/keepme.txt — the EXACT path "dir"
# resolves to through the symlink — so it is actually inside what would be rm -rf'd if the
# symlink check were absent; a sentinel placed directly under elsewhere/ would never be reached
# by this dir argument regardless of whether the guard works, proving nothing either way.
mkdir -p "$TMP/f2e-elsewhere/profile/general"
echo "should-not-be-touched" > "$TMP/f2e-elsewhere/profile/general/keepme.txt"
home_f2e="$TMP/f2e-symlink-home"
mkdir -p "$home_f2e"
ln -s "$TMP/f2e-elsewhere" "$home_f2e/research-sdd"
out_f2e="$(_direct_clean_profile_dir "$home_f2e/research-sdd/profile/general" "$home_f2e")"
if <<<"$out_f2e" grep -q 'RC=2' && [ -f "$TMP/f2e-elsewhere/profile/general/keepme.txt" ]; then
  ok "F2e: _rsdd_clean_profile_dir refuses when research-sdd/ in the chain is a symlink"
else
  no "F2e: symlinked research-sdd/ was not refused (got: $out_f2e)"
fi

# F2pos: regression guard — a LEGITIMATE profile dir (no traversal, no symlink) still cleans
# normally; the new realpath/symlink checks must not over-refuse the happy path test 57 exercises.
cfg_root_f2pos="$TMP/f2pos-cfgroot"
mkdir -p "$cfg_root_f2pos/research-sdd/profile/general"
echo "stale" > "$cfg_root_f2pos/research-sdd/profile/general/stale.txt"
out_f2pos="$(_direct_clean_profile_dir "$cfg_root_f2pos/research-sdd/profile/general" "$cfg_root_f2pos")"
if <<<"$out_f2pos" grep -q 'RC=0' && [ ! -e "$cfg_root_f2pos/research-sdd/profile/general/stale.txt" ]; then
  ok "F2pos: legitimate profile dir still cleans normally (realpath guard doesn't over-refuse)"
else
  no "F2pos: legitimate profile dir clean broke (got: $out_f2pos)"
fi

# ── kit issue #1024 review round 2, F1 (HIGH): incomplete render tree ─────────
# render-profile.sh copies ONLY SKILL.md/PROMPT-LOOP.md/METHODOLOGY.md (by design — that stays
# ITS contract). SKILL.md's own "Resolving the kit path" step 0 trusts a render dir as $KIT once
# METHODOLOGY.md is present there — so, before this fix, every OTHER `$KIT/...` reference inside
# the rendered SKILL.md (12) and PROMPT-LOOP.md (27) broke: toolbelt/*.sh, TARGETS.md, templates/,
# tool-registry.md, other skills/*, all resolved to nothing. Fixed in the INSTALLER (never
# render-profile.sh): after a successful render, every OTHER top-level kit entry, and every other
# entry under the rendered skills/ subtree, is symlinked into the render dir — only the 3 rendered
# files (and the skills/research-sdd/ directory that holds one of them) stay real.
home_f1="$TMP/f1-kitrefs"
bash "$SUT" --home "$home_f1" --harness pi >/dev/null 2>&1
render_root_f1="$home_f1/.pi/agent/research-sdd/profile/general"
skill_f1="$render_root_f1/skills/research-sdd/SKILL.md"
loop_f1="$render_root_f1/PROMPT-LOOP.md"

# F1a: every $KIT/<path> reference in the render's OWN SKILL.md/PROMPT-LOOP.md resolves under the
# completed render dir (files stay real; wildcards need at least one glob match).
if [ -f "$skill_f1" ] && [ -f "$loop_f1" ]; then
  miss_skill_f1="$(_assert_kit_refs_resolve "$render_root_f1" "$skill_f1")"; rc_skill_f1=$?
  miss_loop_f1="$(_assert_kit_refs_resolve "$render_root_f1" "$loop_f1")"; rc_loop_f1=$?
  if [ "$rc_skill_f1" -eq 0 ] && [ "$rc_loop_f1" -eq 0 ]; then
    ok "F1a: every \$KIT/<path> reference in the installed rendered SKILL.md + PROMPT-LOOP.md resolves under the render dir"
  else
    no "F1a: unresolved \$KIT/<path> reference(s) — SKILL.md: [$miss_skill_f1] · PROMPT-LOOP.md: [$miss_loop_f1]"
  fi
else
  no "F1a setup: rendered SKILL.md or PROMPT-LOOP.md not found at $render_root_f1"
fi

# F1b: spot-check the SPECIFIC entries the review named explicitly — belt-and-suspenders beyond
# F1a's generic extraction, directly against the review's own wording.
if [ -x "$render_root_f1/toolbelt/detect-tools.sh" ] \
   && [ -f "$render_root_f1/TARGETS.md" ] \
   && [ -d "$render_root_f1/templates" ] \
   && [ -f "$render_root_f1/toolbelt/tool-registry.md" ]; then
  ok "F1b: toolbelt/*.sh, TARGETS.md, templates/, tool-registry.md all resolve under the render dir"
else
  no "F1b: one or more of toolbelt/*.sh, TARGETS.md, templates/, tool-registry.md missing under the render dir"
fi

# F1c: the rendered files (and the dir holding one of them) stay REAL — completion must never
# symlink OVER already-rendered output.
if [ ! -L "$skill_f1" ] && [ ! -L "$loop_f1" ] && [ ! -L "$render_root_f1/METHODOLOGY.md" ] \
   && [ ! -L "$render_root_f1/skills/research-sdd" ]; then
  ok "F1c: the rendered files (and skills/research-sdd/) stay REAL after completion"
else
  no "F1c: a rendered file or its directory was symlinked over — completion touched rendered output"
fi

# F1d: everything else IS a symlink (not a copy) into the source kit — proves completion links
# rather than duplicates the kit tree.
if [ -L "$render_root_f1/toolbelt" ] && [ -L "$render_root_f1/TARGETS.md" ] \
   && [ -L "$render_root_f1/skills/README.md" ]; then
  ok "F1d: completed entries are symlinks (not copies) to the source kit"
else
  no "F1d: completed entries are not symlinks as expected"
fi

# F1e (kit issue #1024 round 3, item 1): checking that every $KIT/<path> reference RESOLVES (F1a)
# is not the same as checking that a script which DERIVES the kit/repo root from its own location
# (rather than trusting "Kit path:") still lands on the REAL kit when invoked through the render's
# symlinked toolbelt/. EXECUTE the toolbelt scripts identified by grepping the whole toolbelt for
# `dirname "$0"`/`BASH_SOURCE` derivations that climb past their own directory (see the PR body
# for the full inventory): reconcile-issues.sh and stage-retro-issues.sh (this PR), and
# verify-doc-consistency.sh (fixed here too, no other owner) — each in a harmless mode (report-
# only / no --apply / read-only by design) — and assert each resolves the real kit, not the
# render dir's own subtree.
harmless_retro_f1e="$TMP/f1e-retro.md"
printf '# retro\n\n## Proposed kit deltas\n\n| # | Proposed change | Target (file) | Evidence | Type | Priority |\n|---|---|---|---|---|---|\n| 1 | x | y | z | fix | P2 |\n' > "$harmless_retro_f1e"

# reconcile-issues.sh --all against a FULLY SYNTHETIC scratch mini-kit, never the real fleet: an
# earlier version of this test invoked --all through the REAL render (against the real machine's
# TARGETS.md-registered targets), which is slow/non-hermetic and would behave differently on a CI
# runner with no target corpora at all (or none registered), or touch real state on a real
# developer machine. This mirrors the identical hermetic fixture reconcile-issues.test.sh's own
# SYMLINK-TOOLBELT test already uses — never the real toolbelt/, never a real --home.
scratch_recon_f1e="$(mktemp -d)"
mkdir -p "$scratch_recon_f1e/research-sdd/toolbelt/lib" "$scratch_recon_f1e/render/profile/general" \
  "$scratch_recon_f1e/rh/target-foo/retros"
cp "$KITROOT/toolbelt/reconcile-issues.sh"  "$scratch_recon_f1e/research-sdd/toolbelt/reconcile-issues.sh"
cp "$KITROOT/toolbelt/lib/retro-status.sh"  "$scratch_recon_f1e/research-sdd/toolbelt/lib/retro-status.sh"
cp "$KITROOT/toolbelt/lib/retro-grammar.sh" "$scratch_recon_f1e/research-sdd/toolbelt/lib/retro-grammar.sh"
cp "$KITROOT/toolbelt/lib/target-paths.sh"  "$scratch_recon_f1e/research-sdd/toolbelt/lib/target-paths.sh"
printf '# test targets\n\n| # | Target | Path |\n|---|---|---|\n| 1 | target-foo | `%s` |\n' \
  "$scratch_recon_f1e/rh/target-foo" > "$scratch_recon_f1e/research-sdd/TARGETS.md"
ln -s "$scratch_recon_f1e/research-sdd/toolbelt" "$scratch_recon_f1e/render/profile/general/toolbelt"
real_retros_f1e="$scratch_recon_f1e/rh/target-foo/retros"  # captured BEFORE rm -rf, for positive evidence below
# --issues-cache makes this hermetic w.r.t. gh (kit issue #1024 round 5, CI fix): CI has no `gh`
# login, so an unauthenticated `gh auth status` would exit "degraded" here regardless of the -P
# fix under test — an empty cache file means zero open issues, never touching gh at all.
cache_recon_f1e="$scratch_recon_f1e/empty-issues-cache"; : > "$cache_recon_f1e"
out_recon_f1e="$(bash "$scratch_recon_f1e/render/profile/general/toolbelt/reconcile-issues.sh" --all --issues-cache "$cache_recon_f1e" 2>&1)"; rc_recon_f1e=$?
rm -rf "$scratch_recon_f1e"
# kit issue #1024 round 4, item 5: assert the exit code AND positive evidence the REAL TARGETS.md
# (and the real target it names) was actually used — not just the absence of the negative
# "absent-input" signal, which alone cannot distinguish "resolved correctly" from "resolved to
# some OTHER wrong-but-still-existing path". The retros/ dir has no *.md files, so the real run
# WARNs by name for it — that WARN naming the exact real path is the positive evidence.
if [ "$rc_recon_f1e" -eq 0 ] && <<<"$out_recon_f1e" grep -qF "$real_retros_f1e"; then
  ok "F1e: reconcile-issues.sh --all through a symlinked toolbelt/ resolves the real kit root (exit 0, names the real retros/ path)"
else
  no "F1e: reconcile-issues.sh --all through a symlinked toolbelt/ failed (rc=$rc_recon_f1e out=$out_recon_f1e)"
fi

# $harmless_retro_f1e lives under $TMP, which is NOT a registered target — the "target directory
# ... not found" WARN legitimately fires either way (unrelated to the -P fix). What the fix
# controls is WHICH TARGETS.md the WARN names: broken (unfixed) resolves through
# .../profile/research-sdd/TARGETS.md; fixed always names the real kit's TARGETS.md.
out_stage_f1e="$(bash "$render_root_f1/toolbelt/stage-retro-issues.sh" "$harmless_retro_f1e" 2>&1)"
if ! <<<"$out_stage_f1e" grep -q 'profile/research-sdd/TARGETS\.md'; then
  ok "F1e: stage-retro-issues.sh through the render names the real TARGETS.md (not a broken profile-nested path)"
else
  no "F1e: stage-retro-issues.sh through the render named a broken TARGETS.md path (out=$out_stage_f1e)"
fi

out_kit_vdc_f1e="$(bash "$KITROOT/toolbelt/verify-doc-consistency.sh" 2>&1)"
out_render_vdc_f1e="$(bash "$render_root_f1/toolbelt/verify-doc-consistency.sh" 2>&1)"
broken_kit_f1e="$(printf '%s' "$out_kit_vdc_f1e" | grep -oE '[0-9]+ broken citation' | grep -oE '^[0-9]+')"
broken_render_f1e="$(printf '%s' "$out_render_vdc_f1e" | grep -oE '[0-9]+ broken citation' | grep -oE '^[0-9]+')"
if [ -n "$broken_kit_f1e" ] && [ "$broken_kit_f1e" = "$broken_render_f1e" ]; then
  ok "F1e: verify-doc-consistency.sh through the render matches the direct kit run ($broken_kit_f1e broken citations)"
else
  no "F1e: verify-doc-consistency.sh through the render diverged (kit=$broken_kit_f1e render=$broken_render_f1e)"
fi

# ── kit issue #1024 review round 3, item 2 (LOW): same-profile kit update mislabeled ─────────
# The managed-overwrite path (F4) also legitimately covers a SAME-profile kit update with no
# hand-edit: deployed matches the recorded marker hash, but the kit's own content has since moved
# forward — an unedited deployed skill correctly follows the kit. That is INTENDED new behaviour,
# not a bug. But the dry-run plan line said "[will update — managed content from a profile
# switch]", which is misleading when the profile never switched at all. Relabeled to
# "managed content (matches last install)" — accurate for BOTH a profile switch and a same-
# profile kit update, since the marker-hash check cannot (and need not) distinguish the two.
_pm2_dir="$TMP/plan-managed-relabel"; mkdir -p "$_pm2_dir"
_pm2_dest="$_pm2_dir/dest.md"; _pm2_src="$_pm2_dir/src.md"; _pm2_marker="$_pm2_dir/marker"
printf 'installed content — unedited\n' > "$_pm2_dest"
printf 'newer kit content — the kit moved forward, same profile\n' > "$_pm2_src"
_pm2_sha="$(sha256sum "$_pm2_dest" | awk '{print $1}')"
printf 'profile=general\nsha256=%s\n' "$_pm2_sha" > "$_pm2_marker"
out_pm2="$(_direct_dry_skill_plan "$_pm2_src" "$_pm2_dest" 0 "from rendered profile 'general'" "$_pm2_marker" "general")"
if <<<"$out_pm2" grep -q 'managed content (matches last install)' \
   && ! <<<"$out_pm2" grep -qi 'profile switch'; then
  ok "item2: same-profile kit update labeled 'managed content (matches last install)', not 'profile switch'"
else
  no "item2: dry-run label wrong for a same-profile kit update (out=$out_pm2)"
fi

# ── kit issue #1024 review round 3, item 3 (LOW): switch keeps a hand-edit → mixed state ─────
# Reproduced: install general, hand-edit the deployed SKILL.md, then switch to claude. SKILL.md
# is correctly preserved (warn+keep — a genuine hand-edit), but the launcher's "Kit path:" line
# was STILL rewritten to the new (claude) profile — a mixed state (skill body from general,
# Kit path from claude) reported with exit 0, as if the switch had cleanly completed. Chosen fix
# (of the two the review offered): exit non-zero whenever a hand-edit is kept AND the recorded
# marker names a DIFFERENT profile than the one just requested — an ordinary re-install with a
# pre-existing hand-edit on the SAME profile (R3's own behaviour, tests 60/F4d) is unaffected,
# since old_profile == new profile there.
home_it3="$TMP/item3-mixed-state"
bash "$SUT" --home "$home_it3" --harness pi --profile general >/dev/null 2>&1
sf_it3="$home_it3/.pi/agent/skills/research-sdd/SKILL.md"
printf '# hand-edited — a real local delta\n' >> "$sf_it3"
launcher_it3="$home_it3/.pi/agent/AGENTS.md"
launcher_before_it3="$(cat "$launcher_it3" 2>/dev/null)"
err_it3="$(bash "$SUT" --home "$home_it3" --harness pi --profile claude 2>&1 >/dev/null)"; rc_it3=$?
launcher_after_it3="$(cat "$launcher_it3" 2>/dev/null)"
if [ "$rc_it3" -ne 0 ] && grep -q 'hand-edited — a real local delta' "$sf_it3"; then
  ok "item3: switch keeping a hand-edit exits non-zero (mixed-state signal), content still preserved"
else
  no "item3: switch keeping a hand-edit did not exit non-zero (rc=$rc_it3)"
fi
# kit issue #1024 round 4, item 5: assert the SPECIFIC mixed-state ERROR message text, not just
# a nonzero exit — a wrong-reason nonzero exit (e.g. an unrelated failure) would pass the check
# above just as easily.
if <<<"$err_it3" grep -qF 'switching profile "general" → "claude" was requested, but a hand-edit at'; then
  ok "item3: the SPECIFIC mixed-state ERROR message is printed (not just some nonzero exit)"
else
  no "item3: expected mixed-state ERROR message text not found (out=$err_it3)"
fi
# kit issue #1024 round 4, item 4: the launcher's "Kit path:" line must be left UNCHANGED
# (identical to before the blocked switch attempt) — step 2 is skipped entirely, so nothing
# mixed (skill body from general, Kit path rewritten to claude) is ever written to disk.
if [ "$launcher_before_it3" = "$launcher_after_it3" ] && grep -q 'profile/general' "$launcher_it3"; then
  ok "item4: launcher 'Kit path:' left UNCHANGED (still profile/general) when the switch is blocked"
else
  no "item4: launcher was rewritten despite the blocked switch (mixed state written to disk)"
fi

# ── kit issue #1024 round 5, Opus finding 3 (RDD R3-dry-run-switch-warn-untested) ─────────────
# The round-4 dry-run WARN (RDD R4-001) only PRINTED a warning; it did not change the dry-run's
# own exit code or skip the launcher SPLICE preview — a `--dry-run` that prints "a real run would
# ALSO refuse this" while itself exiting 0 and still previewing the launcher SPLICE is a direct
# contradiction (the preview promises something the real run would refuse). Reproduced the exact
# same way as item3/item4, with --dry-run added on the second call.
home_r3dr="$TMP/r3-dry-run-switch-warn"
bash "$SUT" --home "$home_r3dr" --harness pi --profile general >/dev/null 2>&1
sf_r3dr="$home_r3dr/.pi/agent/skills/research-sdd/SKILL.md"
printf '# hand-edited — a real local delta\n' >> "$sf_r3dr"
out_r3dr="$(bash "$SUT" --home "$home_r3dr" --harness pi --profile claude --dry-run 2>&1)"; rc_r3dr=$?
if [ "$rc_r3dr" -ne 0 ] \
   && <<<"$out_r3dr" grep -q 'RDD R4-001' \
   && <<<"$out_r3dr" grep -q 'SKIP.*launcher rewrite skipped' \
   && ! <<<"$out_r3dr" grep -q 'SPLICE.*AGENTS\.md'; then
  ok "R3-dry-run-switch-warn: dry-run exits non-zero AND skips the launcher SPLICE preview when the switch is blocked"
else
  no "R3-dry-run-switch-warn: dry-run contradicted the real run (rc=$rc_r3dr out=$out_r3dr)"
fi

# ── kit issue #1024 review round 3, "also" item: validate the marker's profile= before the clean
# The marker file is small operator-editable state (kit issue #1024 review F4); a corrupted or
# hand-edited profile= value used to reach _rsdd_clean_profile_dir's path construction with no
# validation of its own — _rsdd_clean_profile_dir's F2 guards (textual + symlink + realpath) still
# caught a TRAVERSAL value safely, but an unknown/non-existent profile NAME (no traversal) simply
# no-op'd silently (rm -rf on a directory that never existed). rsdd_valid_profile is now run on the
# marker's profile= value BEFORE any path is built, so an invalid value is reported explicitly.
home_mval="$TMP/marker-validate"
bash "$SUT" --home "$home_mval" --harness pi --profile general >/dev/null 2>&1
marker_mval="$home_mval/.pi/agent/research-sdd/.installed-skill-state"
sha_mval="$(sha256sum "$home_mval/.pi/agent/skills/research-sdd/SKILL.md" | awk '{print $1}')"
printf 'profile=not-a-real-profile\nsha256=%s\n' "$sha_mval" > "$marker_mval"
err_mval="$(bash "$SUT" --home "$home_mval" --harness pi --profile claude 2>&1 >/dev/null)"
if <<<"$err_mval" grep -qi "invalid profile 'not-a-real-profile'"; then
  ok "marker-validate: an invalid marker profile= value is explicitly refused before the clean"
else
  no "marker-validate: invalid marker profile= value not validated (out=$err_mval)"
fi

# ── kit issue #1024 review round 2, F4 (MEDIUM): profile switch leaves a mixed state ──────────
# Reproduced against the pre-F4 code: install general, then claude — the launcher correctly
# reverts (Kit path: back to the real kit), but SKILL.md stays the GENERAL render, reported as
# "diverged — local content kept" (a plain cmp sees any profile switch as a foreign edit), and the
# stale profile/general/ render directory is left behind. Fixed via a small marker file under
# <config_root>/research-sdd/.installed-skill-state recording the profile + sha256 of what the
# installer itself last deployed: on a switch, a deployed file matching THAT hash (whatever
# profile it came from) is a MANAGED overwrite, not a user edit — no warning, no --force-skill
# needed — and the previous profile's now-orphaned render dir is removed via the same guarded
# clean _rsdd_clean_profile_dir already uses. A file that does NOT match the recorded hash is a
# genuine hand-edit and keeps the existing warn+keep-unless---force-skill behaviour untouched.

# F4a/b: general → claude — clean switch: SKILL.md becomes byte-identical to the kit source (no
# "diverged" warning), and the orphaned general/ render dir is removed.
home_f4="$TMP/f4-switch"
bash "$SUT" --home "$home_f4" --harness pi --profile general >/dev/null 2>&1
err_f4a="$(bash "$SUT" --home "$home_f4" --harness pi --profile claude 2>&1 >/dev/null)"
sf_f4="$home_f4/.pi/agent/skills/research-sdd/SKILL.md"
if cmp -s "$sf_f4" "$KITROOT/skills/research-sdd/SKILL.md"; then
  ok "F4a: general → claude switch installs the claude kit source byte-identically"
else
  no "F4a: general → claude switch did NOT install the claude kit source (still the general render)"
fi
if <<<"$err_f4a" grep -qi 'diverged'; then
  no "F4a: general → claude switch was wrongly reported as diverged (a profile switch is not a hand-edit)"
else
  ok "F4a: general → claude switch produced no spurious 'diverged' warning"
fi
if [ ! -e "$home_f4/.pi/agent/research-sdd/profile/general" ]; then
  ok "F4b: the orphaned general/ render dir is removed after switching to claude"
else
  no "F4b: the orphaned general/ render dir survived the switch to claude"
fi

# F4c: general → claude → general → claude round trip ends in a clean claude state (matches the
# review's own round-trip scenario). Each hop must stay clean — no accumulated divergence.
home_f4c="$TMP/f4-roundtrip"
bash "$SUT" --home "$home_f4c" --harness pi --profile general >/dev/null 2>&1
bash "$SUT" --home "$home_f4c" --harness pi --profile claude  >/dev/null 2>&1
bash "$SUT" --home "$home_f4c" --harness pi --profile general >/dev/null 2>&1
err_f4c="$(bash "$SUT" --home "$home_f4c" --harness pi --profile claude 2>&1 >/dev/null)"
sf_f4c="$home_f4c/.pi/agent/skills/research-sdd/SKILL.md"
if cmp -s "$sf_f4c" "$KITROOT/skills/research-sdd/SKILL.md" \
   && ! <<<"$err_f4c" grep -qi 'diverged' \
   && [ ! -e "$home_f4c/.pi/agent/research-sdd/profile/general" ]; then
  ok "F4c: general→claude→general→claude round trip ends in a clean claude state"
else
  no "F4c: round trip did not end clean (identical=$(cmp -s "$sf_f4c" "$KITROOT/skills/research-sdd/SKILL.md" && echo yes || echo no), diverged-warned=$(<<<"$err_f4c" grep -qi diverged && echo yes || echo no), stale-dir=$([ -e "$home_f4c/.pi/agent/research-sdd/profile/general" ] && echo yes || echo no))"
fi

# F4d: regression guard — a GENUINE hand-edit made AFTER a clean switch is still detected and
# preserved (warn+keep), never silently treated as "managed" just because a marker exists.
home_f4d="$TMP/f4-handedit-after-switch"
bash "$SUT" --home "$home_f4d" --harness pi --profile general >/dev/null 2>&1
bash "$SUT" --home "$home_f4d" --harness pi --profile claude  >/dev/null 2>&1
sf_f4d="$home_f4d/.pi/agent/skills/research-sdd/SKILL.md"
printf '# hand-edited after the switch — a real local delta\n' >> "$sf_f4d"
err_f4d="$(bash "$SUT" --home "$home_f4d" --harness pi --profile claude 2>&1 >/dev/null)"
if grep -q 'hand-edited after the switch' "$sf_f4d" && <<<"$err_f4d" grep -qi 'diverged'; then
  ok "F4d: a genuine hand-edit made after a clean switch is still detected and preserved"
else
  no "F4d: hand-edit after a switch was not detected/preserved (content-kept=$(grep -q 'hand-edited after the switch' "$sf_f4d" && echo yes || echo no), warned=$(<<<"$err_f4d" grep -qi diverged && echo yes || echo no))"
fi

# ── kit issue #1024 review round 2, F1 teeth: skip the linking step ──────────
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: skip _rsdd_complete_profile_render's linking step; expect F1a/F1b to fail --"
  MUTANT20="$MKI/research-sdd-install.MUTANT20.$$.sh"
  mutant_sed "$SUT" "$MUTANT20" 's/elif ! _rsdd_complete_profile_render "\$render_dir" "\$KIT"; then/elif false; then/' \
    || no "teeth: MUTANT20 could not be built (refused by the mutant helper — see above)"
  bash -n "$MUTANT20" 2>/dev/null \
    && ok "teeth: MUTANT20 parses (bash -n)" \
    || no "teeth: MUTANT20 is a syntax error — mutation is theater"
  if diff -q "$SUT" "$MUTANT20" >/dev/null 2>&1; then
    no "teeth: MUTANT20 pre-check: mutant = SUT — linking-step call site not found"
  else
    ok "teeth: MUTANT20 pre-check: mutant differs (linking step skipped)"
  fi
  home_m20="$TMP/teeth-m20-kitrefs"
  bash "$MUTANT20" --home "$home_m20" --harness pi >/dev/null 2>&1
  render_root_m20="$home_m20/.pi/agent/research-sdd/profile/general"
  # Reproduces the pre-fix bug directly: with linking skipped, toolbelt/ (and everything else
  # outside the 3 rendered files) never appears under the render dir at all.
  if [ -e "$render_root_m20/toolbelt" ] || [ -e "$render_root_m20/TARGETS.md" ]; then
    no "teeth: MUTANT20 (linking skipped) still completed the render — F1 linking-step check is THEATER"
  else
    ok "teeth: MUTANT20 (linking skipped) leaves toolbelt/ and TARGETS.md missing → F1 linking-step check has teeth"
  fi

  # F1e teeth (kit issue #1024 round 3, item 1): a REPRESENTATIVE tooth for reconcile-issues.sh's
  # -P fix (stage-retro-issues.sh and verify-doc-consistency.sh have their OWN dedicated teeth in
  # their respective *.test.sh suites, following the identical -P pattern). CRITICAL: this builds
  # a fully SYNTHETIC scratch kit (mktemp -d) — never a real render, whose toolbelt/ is a
  # SYMLINK to the real toolbelt/ — to avoid overwriting the live tracked script (that exact
  # mistake happened once while building this fix and was caught by F1e's own cross-check).
  echo "-- teeth: revert reconcile-issues.sh's -P to plain cd/pwd; expect F1e to fail --"
  recon_sut="$KITROOT/toolbelt/reconcile-issues.sh"
  mutant_recon_f1e="$(mktemp)"
  sed -e 's/cd -P "\$(dirname "\$0")" \&\& pwd -P/cd "$(dirname "$0")" \&\& pwd/' \
      -e 's/cd -P "\$_SCRIPT_DIR\/\.\.\/\.\." \&\& pwd -P/cd "$_SCRIPT_DIR\/..\/.." \&\& pwd/' \
      "$recon_sut" > "$mutant_recon_f1e"
  if diff -q "$recon_sut" "$mutant_recon_f1e" >/dev/null 2>&1; then
    no "teeth F1e pre-check: mutant = reconcile-issues.sh — -P pattern not found"
  else
    ok "teeth F1e pre-check: mutant differs (-P reverted to plain cd/pwd)"
  fi
  scratch_f1e="$(mktemp -d)"
  mkdir -p "$scratch_f1e/toolbelt/lib" "$scratch_f1e/profile/general" "$scratch_f1e/rh/target-foo/retros"
  cp "$mutant_recon_f1e" "$scratch_f1e/toolbelt/reconcile-issues.sh"
  cp "$KITROOT/toolbelt/lib/retro-status.sh"  "$scratch_f1e/toolbelt/lib/retro-status.sh"
  cp "$KITROOT/toolbelt/lib/retro-grammar.sh" "$scratch_f1e/toolbelt/lib/retro-grammar.sh"
  cp "$KITROOT/toolbelt/lib/target-paths.sh"  "$scratch_f1e/toolbelt/lib/target-paths.sh"
  printf '# test targets\n\n| # | Target | Path |\n|---|---|---|\n| 1 | target-foo | `%s` |\n' \
    "$scratch_f1e/rh/target-foo" > "$scratch_f1e/TARGETS.md"
  ln -s "$scratch_f1e/toolbelt" "$scratch_f1e/profile/general/toolbelt"
  # --issues-cache: same hermeticity requirement as the F1e base check above (kit issue #1024
  # round 5, CI fix) — an unauthenticated gh on CI must never turn this tooth's expected
  # "absent-input" symptom into an unrelated "degraded: gh is not authenticated" one.
  cache_f1e_teeth="$scratch_f1e/empty-issues-cache"; : > "$cache_f1e_teeth"
  out_recon_f1e_teeth="$(bash "$scratch_f1e/profile/general/toolbelt/reconcile-issues.sh" --all --issues-cache "$cache_f1e_teeth" 2>&1)"
  if <<<"$out_recon_f1e_teeth" grep -qi 'absent-input.*TARGETS\.md'; then
    ok "teeth: reverted mutant re-breaks reconcile-issues.sh through a symlinked toolbelt/ → F1e has teeth"
  else
    no "teeth: reverted mutant still resolved TARGETS.md — F1e check is THEATER (out=$out_recon_f1e_teeth)"
  fi
  rm -rf "$scratch_f1e"
  rm -f "$mutant_recon_f1e"

  echo "-- teeth: neuter _rsdd_marker_matches_deployed; expect F4a to fail --"
  MUTANT21="$MKI/research-sdd-install.MUTANT21.$$.sh"
  mutant_sed "$SUT" "$MUTANT21" 's/_rsdd_marker_matches_deployed "\$marker" "\$dest"/false/' \
    || no "teeth: MUTANT21 could not be built (refused by the mutant helper — see above)"
  bash -n "$MUTANT21" 2>/dev/null \
    && ok "teeth: MUTANT21 parses (bash -n)" \
    || no "teeth: MUTANT21 is a syntax error — mutation is theater"
  if diff -q "$SUT" "$MUTANT21" >/dev/null 2>&1; then
    no "teeth: MUTANT21 pre-check: mutant = SUT — marker-match call site not found"
  else
    ok "teeth: MUTANT21 pre-check: mutant differs (marker-match check disabled)"
  fi
  home_m21="$TMP/teeth-m21-switch"
  bash "$MUTANT21" --home "$home_m21" --harness pi --profile general >/dev/null 2>&1
  err_m21="$(bash "$MUTANT21" --home "$home_m21" --harness pi --profile claude 2>&1 >/dev/null)"
  sf_m21="$home_m21/.pi/agent/skills/research-sdd/SKILL.md"
  if cmp -s "$sf_m21" "$KITROOT/skills/research-sdd/SKILL.md" && ! <<<"$err_m21" grep -qi 'diverged'; then
    no "teeth: MUTANT21 still switched cleanly — marker-match check is THEATER"
  else
    ok "teeth: MUTANT21 (marker-match disabled) mis-reports a profile switch as diverged → marker-match check has teeth"
  fi

  echo "-- teeth: neuter the orphaned-render cleanup; expect F4b to fail --"
  MUTANT22="$MKI/research-sdd-install.MUTANT22.$$.sh"
  mutant_sed "$SUT" "$MUTANT22" 's/! _rsdd_clean_profile_dir "\$config_root\/research-sdd\/profile\/\$old_profile" "\$config_root"/false/' \
    || no "teeth: MUTANT22 could not be built (refused by the mutant helper — see above)"
  bash -n "$MUTANT22" 2>/dev/null \
    && ok "teeth: MUTANT22 parses (bash -n)" \
    || no "teeth: MUTANT22 is a syntax error — mutation is theater"
  if diff -q "$SUT" "$MUTANT22" >/dev/null 2>&1; then
    no "teeth: MUTANT22 pre-check: mutant = SUT — orphan-cleanup call site not found"
  else
    ok "teeth: MUTANT22 pre-check: mutant differs (orphan-cleanup disabled)"
  fi
  home_m22="$TMP/teeth-m22-switch"
  bash "$MUTANT22" --home "$home_m22" --harness pi --profile general >/dev/null 2>&1
  bash "$MUTANT22" --home "$home_m22" --harness pi --profile claude >/dev/null 2>&1
  if [ -e "$home_m22/.pi/agent/research-sdd/profile/general" ]; then
    ok "teeth: MUTANT22 (orphan-cleanup disabled) leaves the stale general/ render dir → F4b cleanup check has teeth"
  else
    no "teeth: MUTANT22 still cleaned the orphaned render dir — F4b cleanup check is THEATER"
  fi

  echo "-- teeth: revert the item2 relabel; expect item2 to fail --"
  MUTANT23="$MKI/research-sdd-install.MUTANT23.$$.sh"
  mutant_sed "$SUT" "$MUTANT23" "s/managed content (matches last install)/managed content from a profile switch/" \
    || no "teeth: MUTANT23 could not be built (refused by the mutant helper — see above)"
  bash -n "$MUTANT23" 2>/dev/null \
    && ok "teeth: MUTANT23 parses (bash -n)" \
    || no "teeth: MUTANT23 is a syntax error — mutation is theater"
  if diff -q "$SUT" "$MUTANT23" >/dev/null 2>&1; then
    no "teeth: MUTANT23 pre-check: mutant = SUT — relabel text not found"
  else
    ok "teeth: MUTANT23 pre-check: mutant differs (relabel reverted)"
  fi
  driver_m23="$MKI/research-sdd-install-driver-m23.$$.sh"
  printf '#!/usr/bin/env bash\nset -uo pipefail\n. "$(dirname "$0")/research-sdd-install.MUTANT23.'"$$"'.sh" --help >/dev/null 2>&1\n_rsdd_dry_skill_plan "$1" "$2" "$3" "$4" "$5"\n' > "$driver_m23"
  out_m23="$(bash "$driver_m23" "$_pm2_src" "$_pm2_dest" 0 "from rendered profile 'general'" "$_pm2_marker" 2>&1)"
  rm -f "$driver_m23"
  if <<<"$out_m23" grep -qi 'profile switch'; then
    ok "teeth: MUTANT23 (relabel reverted) re-shows the misleading 'profile switch' text → item2 check has teeth"
  else
    no "teeth: MUTANT23 still avoided 'profile switch' text — item2 check is THEATER (out=$out_m23)"
  fi

  echo "-- teeth: neuter the item3 mixed-state guard; expect item3 to fail --"
  MUTANT24="$MKI/research-sdd-install.MUTANT24.$$.sh"
  mutant_sed "$SUT" "$MUTANT24" 's/if \[ -n "\$_deployed_old_profile" \] \&\& \[ "\$_deployed_old_profile" != "\$profile" \]; then/if false; then/' \
    || no "teeth: MUTANT24 could not be built (refused by the mutant helper — see above)"
  bash -n "$MUTANT24" 2>/dev/null \
    && ok "teeth: MUTANT24 parses (bash -n)" \
    || no "teeth: MUTANT24 is a syntax error — mutation is theater"
  if diff -q "$SUT" "$MUTANT24" >/dev/null 2>&1; then
    no "teeth: MUTANT24 pre-check: mutant = SUT — mixed-state guard not found"
  else
    ok "teeth: MUTANT24 pre-check: mutant differs (mixed-state guard disabled)"
  fi
  home_m24="$TMP/teeth-m24-mixed"
  bash "$MUTANT24" --home "$home_m24" --harness pi --profile general >/dev/null 2>&1
  sf_m24="$home_m24/.pi/agent/skills/research-sdd/SKILL.md"
  printf '# hand-edited — a real local delta\n' >> "$sf_m24"
  bash "$MUTANT24" --home "$home_m24" --harness pi --profile claude >/dev/null 2>&1; rc_m24=$?
  if [ "$rc_m24" -eq 0 ]; then
    ok "teeth: MUTANT24 (guard disabled) silently exits 0 on a mixed state → item3 check has teeth"
  else
    no "teeth: MUTANT24 still exited non-zero (rc=$rc_m24) — item3 check is THEATER"
  fi

  echo "-- teeth: neuter the marker-profile validation; expect marker-validate to fail --"
  MUTANT25="$MKI/research-sdd-install.MUTANT25.$$.sh"
  mutant_sed "$SUT" "$MUTANT25" 's/if ! rsdd_valid_profile "\$old_profile" "\$KIT"; then/if false; then/' \
    || no "teeth: MUTANT25 could not be built (refused by the mutant helper — see above)"
  bash -n "$MUTANT25" 2>/dev/null \
    && ok "teeth: MUTANT25 parses (bash -n)" \
    || no "teeth: MUTANT25 is a syntax error — mutation is theater"
  if diff -q "$SUT" "$MUTANT25" >/dev/null 2>&1; then
    no "teeth: MUTANT25 pre-check: mutant = SUT — marker-profile validation not found"
  else
    ok "teeth: MUTANT25 pre-check: mutant differs (marker-profile validation disabled)"
  fi
  home_m25="$TMP/teeth-m25-marker"
  bash "$MUTANT25" --home "$home_m25" --harness pi --profile general >/dev/null 2>&1
  marker_m25="$home_m25/.pi/agent/research-sdd/.installed-skill-state"
  sha_m25="$(sha256sum "$home_m25/.pi/agent/skills/research-sdd/SKILL.md" | awk '{print $1}')"
  printf 'profile=not-a-real-profile\nsha256=%s\n' "$sha_m25" > "$marker_m25"
  err_m25="$(bash "$MUTANT25" --home "$home_m25" --harness pi --profile claude 2>&1 >/dev/null)"
  if ! <<<"$err_m25" grep -qi "invalid profile 'not-a-real-profile'"; then
    ok "teeth: MUTANT25 (validation disabled) no longer reports the invalid marker profile → marker-validate has teeth"
  else
    no "teeth: MUTANT25 still reported the invalid profile — marker-validate check is THEATER"
  fi

  echo "-- teeth: neuter the item4 launcher-skip check; expect item4 to fail --"
  MUTANT26="$MKI/research-sdd-install.MUTANT26.$$.sh"
  mutant_sed "$SUT" "$MUTANT26" 's/if \[ "\$_RSDD_SKILL_BLOCKED_MIXED" = 1 \]; then/if false; then/' \
    || no "teeth: MUTANT26 could not be built (refused by the mutant helper — see above)"
  bash -n "$MUTANT26" 2>/dev/null \
    && ok "teeth: MUTANT26 parses (bash -n)" \
    || no "teeth: MUTANT26 is a syntax error — mutation is theater"
  if diff -q "$SUT" "$MUTANT26" >/dev/null 2>&1; then
    no "teeth: MUTANT26 pre-check: mutant = SUT — launcher-skip check not found"
  else
    ok "teeth: MUTANT26 pre-check: mutant differs (launcher-skip check disabled)"
  fi
  home_m26="$TMP/teeth-m26-launcher-skip"
  bash "$MUTANT26" --home "$home_m26" --harness pi --profile general >/dev/null 2>&1
  sf_m26="$home_m26/.pi/agent/skills/research-sdd/SKILL.md"
  printf '# hand-edited — a real local delta\n' >> "$sf_m26"
  launcher_m26="$home_m26/.pi/agent/AGENTS.md"
  launcher_before_m26="$(cat "$launcher_m26" 2>/dev/null)"
  bash "$MUTANT26" --home "$home_m26" --harness pi --profile claude >/dev/null 2>&1
  launcher_after_m26="$(cat "$launcher_m26" 2>/dev/null)"
  if [ "$launcher_before_m26" != "$launcher_after_m26" ]; then
    ok "teeth: MUTANT26 (launcher-skip disabled) rewrites the launcher despite the blocked switch → item4 check has teeth"
  else
    no "teeth: MUTANT26 launcher still unchanged — item4 check is THEATER"
  fi

  echo "-- teeth: neuter the RDD R4-001 dry-run return; expect R3-dry-run-switch-warn to fail --"
  MUTANT27="$MKI/research-sdd-install.MUTANT27.$$.sh"
  # A single, well-defined mutation: the dry-run WARN branch stops signalling BLOCKED_MIXED and
  # stops returning failure (both lines immediately after the WARN printf are dropped).
  awk '
    /printf .*a real run would ALSO refuse this profile switch/ { print; getline; print; getline; in_warn=1; next }
    in_warn && /_RSDD_SKILL_BLOCKED_MIXED=1/ { next }
    in_warn && /return 1/ { in_warn=0; next }
    { print }
  ' "$SUT" > "$MUTANT27"
  # Built with awk, not mutant_sed: run the same refusals (placement, empty, identical, syntax).
  mutant_verify "$SUT" "$MUTANT27" \
    || no "teeth: MUTANT27 could not be built (refused by the mutant helper — see above)"
  bash -n "$MUTANT27" 2>/dev/null \
    && ok "teeth: MUTANT27 parses (bash -n)" \
    || no "teeth: MUTANT27 is a syntax error — mutation is theater"
  if diff -q "$SUT" "$MUTANT27" >/dev/null 2>&1; then
    no "teeth: MUTANT27 pre-check: mutant = SUT — RDD R4-001 return not found"
  else
    ok "teeth: MUTANT27 pre-check: mutant differs (dry-run WARN no longer signals/returns failure)"
  fi
  home_m27="$TMP/teeth-m27-dryrun-warn"
  bash "$MUTANT27" --home "$home_m27" --harness pi --profile general >/dev/null 2>&1
  sf_m27="$home_m27/.pi/agent/skills/research-sdd/SKILL.md"
  printf '# hand-edited — a real local delta\n' >> "$sf_m27"
  out_m27="$(bash "$MUTANT27" --home "$home_m27" --harness pi --profile claude --dry-run 2>&1)"; rc_m27=$?
  if [ "$rc_m27" -eq 0 ] || <<<"$out_m27" grep -q 'SPLICE.*AGENTS\.md'; then
    ok "teeth: MUTANT27 (return neutered) dry-run exits 0 and/or previews the launcher SPLICE again → R3-dry-run-switch-warn check has teeth"
  else
    no "teeth: MUTANT27 still refused correctly — R3-dry-run-switch-warn check is THEATER (rc=$rc_m27 out=$out_m27)"
  fi
fi

# Portability (kit issue #1299 item 7): the snapshot must not depend on GNU `find -printf` (a BSD
# find rejects it, which made this suite FATAL there). A stub find that refuses -printf stands in
# for a BSD find; the snapshot must still succeed and see a change.
_pf_bin="$TMP/nofind-printf-bin"; mkdir -p "$_pf_bin"
_pf_real="$(command -v find)"
{ printf '#!/usr/bin/env bash\n'
  printf 'for a in "$@"; do [ "$a" = "-printf" ] && { echo "find: unknown primary -printf" >&2; exit 1; }; done\n'
  printf 'exec %s "$@"\n' "$_pf_real"
} > "$_pf_bin/find"; chmod +x "$_pf_bin/find"
_pf_probe="$TMP/portable-probe"; mkdir -p "$_pf_probe"; printf 'a\n' > "$_pf_probe/a.sh"
_pf_s0="$(PATH="$_pf_bin:$PATH" _install_tree_snapshot "$_pf_probe")"; _pf_rc=$?
printf 'changed\n' > "$_pf_probe/a.sh"
_pf_s1="$(PATH="$_pf_bin:$PATH" _install_tree_snapshot "$_pf_probe")"
if [ "$_pf_rc" -eq 0 ] && [ -n "$_pf_s0" ] && [ "$_pf_s1" != "$_pf_s0" ]; then
  ok "hermetic snapshot: works without GNU find -printf (BSD-style find) and still registers a change"
else no "hermetic snapshot depends on GNU find -printf (rc=$_pf_rc, snapshot=[$_pf_s0])"; fi

# Dotfiles (kit issue #1299 item 7): a created, modified and removed DOTFILE (and one inside a dot
# directory) must each change the snapshot — a `$root/*` glob would skip them all.
_df_probe="$TMP/dot-probe"; mkdir -p "$_df_probe"; printf 'a\n' > "$_df_probe/a.sh"
_df_s0="$(_install_tree_snapshot "$_df_probe")" || _df_s0="<failed>"
printf 'x\n' > "$_df_probe/.hidden"; mkdir "$_df_probe/.dotdir"; printf 'y\n' > "$_df_probe/.dotdir/inner"
_df_s1="$(_install_tree_snapshot "$_df_probe")" || _df_s1="<failed>"
printf 'xx longer\n' > "$_df_probe/.hidden"
_df_s2="$(_install_tree_snapshot "$_df_probe")" || _df_s2="<failed>"
printf 'yy longer\n' > "$_df_probe/.dotdir/inner"
_df_s3="$(_install_tree_snapshot "$_df_probe")" || _df_s3="<failed>"
rm -f "$_df_probe/.hidden"
_df_s4="$(_install_tree_snapshot "$_df_probe")" || _df_s4="<failed>"
if [ "$_df_s0" != "<failed>" ] && [ "$_df_s1" != "$_df_s0" ] && [ "$_df_s2" != "$_df_s1" ] \
   && [ "$_df_s3" != "$_df_s2" ] && [ "$_df_s4" != "$_df_s3" ]; then
  ok "hermetic snapshot: a created, modified and removed dotfile (and a file in a dot directory) are each detected (#1299 item 7)"
else no "hermetic snapshot misses dotfile changes (#1299 item 7)"; fi
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: a dotfile-blind snapshot (glob-style) must fail the dotfile fixture --"
  # Mutant: the file scan skips names starting with '.', as `"$root"/*` would.
  _df_m="$( eval "$(declare -f _install_tree_snapshot | sed "s/-type f -exec cksum/-type f ! -name '.*' -exec cksum/")"
            printf 'a\n' > "$_df_probe/.m2"; a="$(_install_tree_snapshot "$_df_probe")"; printf 'zzz longer\n' > "$_df_probe/.m2"; b="$(_install_tree_snapshot "$_df_probe")"
            [ -n "$a" ] && [ "$a" = "$b" ] && echo BLIND || echo SEES )"
  if [ "$_df_m" = BLIND ]; then ok "teeth: a dotfile-blind snapshot misses a dotfile change → the dotfile fixture bites"
  else no "teeth: the dotfile-blind mutant still saw the change (or did not run: [$_df_m]) — dotfile fixture is THEATER"; fi
fi

# ======================================================================================================
# Pi + gentle-shell harnesses. Both surface the skill under an agent dir (~/.pi/agent,
# ~/.gentle-shell/agent) AND deploy a slash-command PROMPT TEMPLATE (prompts/research-sdd.md) so Pi's
# `/research-sdd` exists. The template is an OPTIONAL adapter-table field (_RSDD_PROMPT_TEMPLATE_REL):
# empty for claude, so its behaviour is unchanged.
# ======================================================================================================
_pi_rows="pi:.pi/agent gentle-shell:.gentle-shell/agent"

# PI1 — the adapter accessor: prompt_template_path is set for pi/gentle-shell, EMPTY (rc 0) otherwise.
_pi_driver="$TMP/pi-field-driver.sh"
printf '#!/usr/bin/env bash\nset -uo pipefail\n. "%s"\nrsdd_field "$1" prompt_template_path "$2"\necho "RC=$?"\n' "$HERE/../adapters.sh" > "$_pi_driver"
for row in $_pi_rows; do
  h="${row%%:*}"; rel="${row#*:}"
  got="$(bash "$_pi_driver" "$h" /H 2>&1)"
  [ "$got" = "$(printf '/H/%s/prompts/research-sdd.md\nRC=0' "$rel")" ] \
    && ok "adapter: $h prompt_template_path = <home>/$rel/prompts/research-sdd.md" \
    || no "adapter: $h prompt_template_path wrong (got: $got)"
done
_no_tmpl_harnesses="claude"
for h in $_no_tmpl_harnesses; do
  got="$(bash "$_pi_driver" "$h" /H 2>&1)"
  [ "$got" = "$(printf '\nRC=0')" ] \
    && ok "adapter: $h prompt_template_path is empty (no template for this harness)" \
    || no "adapter: $h prompt_template_path should be empty (got: $got)"
done

for row in $_pi_rows; do
  h="${row%%:*}"; rel="${row#*:}"
  home="$TMP/pi-real-$h"; out="$(bash "$SUT" --home "$home" --harness "$h" 2>&1)"; rc=$?
  root="$home/$rel"
  [ "$rc" -eq 0 ] && ok "$h: real run exits 0" || no "$h: real run exited $rc ($out)"
  # skill at the agent-dir skills path, valid Pi frontmatter (name + description <= 1024 chars)
  sk="$root/skills/research-sdd/SKILL.md"
  fm_name="$(awk 'NR==1&&$0!="---"{exit} NR>1&&$0=="---"{exit} /^name:/{sub(/^name:[ ]*/,"");print}' "$sk" 2>/dev/null)"
  fm_desc="$(awk 'NR==1&&$0!="---"{exit} NR>1&&$0=="---"{exit} /^description:/{sub(/^description:[ ]*/,"");print}' "$sk" 2>/dev/null)"
  if [ "$fm_name" = "research-sdd" ] && [ -n "$fm_desc" ] && [ "${#fm_desc}" -le 1024 ]; then
    ok "$h: SKILL.md at $rel/skills with valid Pi frontmatter (name=research-sdd, description ${#fm_desc} chars)"
  else no "$h: SKILL.md missing or frontmatter invalid (name='$fm_name', desc chars=${#fm_desc})"; fi
  # slash-command prompt template
  tp="$root/prompts/research-sdd.md"
  if [ -f "$tp" ] && [ "$(sed -n 1p "$tp")" = "---" ] && grep -q '^description: .' "$tp" \
     && grep -q '^argument-hint: ' "$tp" && grep -qF '$ARGUMENTS' "$tp" && grep -qF "$sk" "$tp"; then
    ok "$h: prompts/research-sdd.md has frontmatter description + argument-hint, \$ARGUMENTS, and the absolute skill path"
  else no "$h: prompt template missing/incomplete at $tp"; fi
  # AGENTS.md launcher + manual sweep block, no MCP doc (the kit registers no MCP servers)
  pf="$root/AGENTS.md"
  if grep -qF "Skill file: $sk" "$pf" 2>/dev/null && grep -q '^Kit path: ' "$pf" && grep -q 'sweep-retros.sh' "$pf"; then
    ok "$h: AGENTS.md launcher carries Skill file / Kit path and the manual sweep block"
  else no "$h: AGENTS.md launcher incomplete at $pf"; fi
  if grep -qi 'registered automatically' "$pf" 2>/dev/null || [ -e "$root/config.toml" ] || [ -e "$root/mcp.json" ]; then
    no "$h: must not document or register MCP (the kit registers no MCP servers)"
  else ok "$h: no MCP doc and no MCP config file written"; fi
  <<<"$out" grep -q '^  slash_commands=true$' && ok "$h: reports slash_commands=true" || no "$h: slash_commands not true ($out)"
  # idempotent: second run is byte-identical and keeps one marked section
  cp "$tp" "$TMP/pi-tp-run1" 2>/dev/null; cp "$pf" "$TMP/pi-pf-run1" 2>/dev/null
  bash "$SUT" --home "$home" --harness "$h" >/dev/null 2>&1
  if cmp -s "$tp" "$TMP/pi-tp-run1" && cmp -s "$pf" "$TMP/pi-pf-run1" \
     && [ "$(grep -c '<!-- research-sdd:start -->' "$pf")" = 1 ]; then ok "$h: re-run is idempotent (template + AGENTS.md byte-identical, one section)"
  else no "$h: re-run changed the template/AGENTS.md or duplicated the section"; fi
  # dry-run: plans the template, writes nothing
  home_d="$TMP/pi-dry-$h"
  out_d="$(bash "$SUT" --dry-run --home "$home_d" --harness "$h" 2>&1)"
  if <<<"$out_d" grep -qF "$home_d/$rel/prompts/research-sdd.md (slash-command prompt template)" && [ ! -e "$home_d" ]; then
    ok "$h: dry-run plans the prompt template and creates nothing"
  else no "$h: dry-run missed the template plan or wrote files"; fi
  # hand-edit protection: a user-edited template is KEPT (warn); --force-skill backs up then overwrites
  printf 'MY OWN PROMPT\n' > "$tp"
  err="$(bash "$SUT" --home "$home" --harness "$h" 2>&1 >/dev/null)"
  if [ "$(cat "$tp")" = "MY OWN PROMPT" ] && <<<"$err" grep -q "WARNING $tp exists with diverged content"; then
    ok "$h: hand-edited prompt template kept (warned), never clobbered silently"
  else no "$h: hand-edited prompt template clobbered or no warning (err=$err)"; fi
  bash "$SUT" --home "$home" --harness "$h" --force-skill >/dev/null 2>&1
  if grep -qF '$ARGUMENTS' "$tp" && [ "$(cat "$tp.local-backup" 2>/dev/null)" = "MY OWN PROMPT" ]; then
    ok "$h: --force-skill backs up the hand-edited template then restores the managed one"
  else no "$h: --force-skill did not back up/restore the template"; fi
  # managed update: a template whose sha matches the installer's own recorded marker is silently updated
  printf 'OLD MANAGED BYTES\n' > "$tp"
  _sha="$(sha256sum "$tp" | cut -d' ' -f1)"
  printf 'profile=template\nsha256=%s\n' "$_sha" > "$root/research-sdd/.installed-template-state"
  bash "$SUT" --home "$home" --harness "$h" >/dev/null 2>&1
  grep -qF '$ARGUMENTS' "$tp" && ok "$h: a template matching the recorded install marker is a managed (silent) update" \
    || no "$h: managed-content template was not updated"
done

# PI2 — claude deploys NO prompt template (empty field), even under --harness all.
home="$TMP/pi-none"; bash "$SUT" --home "$home" --harness all >/dev/null 2>&1
_no_tmpl_dirs=".claude"
for d in $_no_tmpl_dirs; do
  [ ! -e "$home/$d/prompts" ] && ok "$d: no prompts/ dir deployed (no template for this harness)" || no "$d: wrongly deployed a prompts/ dir"
done
_no_tmpl_harnesses="claude"
for h in $_no_tmpl_harnesses; do
  out="$(bash "$SUT" --dry-run --home "$TMP/pi-none-dry" --harness "$h" 2>&1)"
  if <<<"$out" grep -q 'prompt template'; then no "$h: dry-run plans a prompt template (field must be empty)"
  else ok "$h: dry-run plans no prompt template"; fi
done
# --harness all installs claude then both Pi harnesses, in registration order
home="$TMP/pi-all"; out="$(bash "$SUT" --home "$home" --harness all 2>&1)"
[ "$(<<<"$out" grep '^harness=' | tr '\n' ' ')" = "harness=claude harness=pi harness=gentle-shell " ] \
  && ok "--harness all iterates claude pi gentle-shell in order" \
  || no "--harness all order/set wrong ($(<<<"$out" grep '^harness=' | tr '\n' ' '))"
[ -f "$home/.pi/agent/prompts/research-sdd.md" ] && [ -f "$home/.gentle-shell/agent/prompts/research-sdd.md" ] \
  && ok "--harness all deploys both Pi templates" || no "--harness all missed a Pi template"
# unknown-harness message names the new keys
err="$(bash "$SUT" --harness bogus --home "$TMP/pi-bogus" 2>&1)"
<<<"$err" grep -q 'known: claude pi gentle-shell all' && ok "unknown-harness error lists exactly the supported harnesses" || no "unknown-harness error stale ($err)"
# dropped harnesses (#1471): codex and reasonix are unknown harnesses — exit 2, nothing written.
for h in codex reasonix; do
  home="$TMP/dropped-$h"
  err="$(bash "$SUT" --harness "$h" --home "$home" 2>&1)"; rc=$?
  if [ "$rc" -eq 2 ] && <<<"$err" grep -q "unknown harness '$h'" && [ ! -e "$home" ]; then
    ok "--harness $h (dropped #1471): unknown-harness error, exit 2, nothing written"
  else no "--harness $h still accepted or wrong failure (rc=$rc, err=$err)"; fi
done
# partial failure: a blocked .pi must not stop the other harnesses
if [ "$(id -u)" -ne 0 ]; then
  home="$TMP/pi-aggr"; mkdir -p "$home/.pi"; chmod 000 "$home/.pi"
  bash "$SUT" --home "$home" --harness all >/dev/null 2>&1; rc=$?
  chmod 755 "$home/.pi"
  if [ "$rc" -ne 0 ] && [ -f "$home/.claude/skills/research-sdd/SKILL.md" ] && [ -f "$home/.gentle-shell/agent/prompts/research-sdd.md" ]; then
    ok "pi blocked: nonzero exit, gentle-shell and claude still install"
  else no "pi blocked: partial-failure contract broken (rc=$rc)"; fi
fi

# PI3 — slash-command invariant: supports_slash_commands=true must be backed by a prompt template or by
# a DOCUMENTED skill-native harness (none today). Keeps the field meaning "a literal /research-sdd exists".
_slash_native_documented=""
_slash_invariant() { # <adapters.sh> -> prints violating harnesses
  local adp="$1" hh sl tpl
  for hh in $(bash -c '. "$1"; echo "$RESEARCH_SDD_HARNESSES"' _ "$adp"); do
    sl="$(bash -c '. "$1"; rsdd_field "$2" supports_slash_commands /H' _ "$adp" "$hh")"
    tpl="$(bash -c '. "$1"; rsdd_field "$2" prompt_template_path /H' _ "$adp" "$hh")"
    if [ "$sl" = true ] && [ -z "$tpl" ]; then
      case " $_slash_native_documented " in *" $hh "*) ;; *) printf '%s ' "$hh" ;; esac
    fi
  done
}
_viol="$(_slash_invariant "$HERE/../adapters.sh")"
[ -z "$_viol" ] && ok "slash invariant: every supports_slash=true harness has a prompt template (or is documented skill-native)" \
  || no "slash invariant violated by: $_viol"
[ "$(bash -c '. "$1"; for h in $RESEARCH_SDD_HARNESSES; do rsdd_field "$h" supports_slash_commands /H; done | grep -c true' _ "$HERE/../adapters.sh")" = 2 ] \
  && ok "slash invariant: exactly pi + gentle-shell report supports_slash=true" || no "slash invariant: unexpected supports_slash=true set"

# PI4 — template marker isolation (kit issue #1469). The prompt template and the skill are deployed
# through the SAME helper with SEPARATE marker files (.installed-template-state, profile=template, vs
# .installed-skill-state). Sharing one file would let a skill profile switch read the template's
# profile as "previous profile", clean the wrong render dir, or rewrite the template's recorded hash.
# Scenario: install twice (default profile = general), switch the skill profile to claude, then back.
# Prints "OK" or a space-separated list of broken invariants.
_tmpl_isolation_scenario() { # <installer> <home>
  local sut="$1" home="$2" root="$2/.gentle-shell/agent" bad="" tp mk sm t_sha t_marker
  bash "$sut" --home "$home" --harness gentle-shell >/dev/null 2>&1
  bash "$sut" --home "$home" --harness gentle-shell >/dev/null 2>&1
  tp="$root/prompts/research-sdd.md"; mk="$root/research-sdd/.installed-template-state"; sm="$root/research-sdd/.installed-skill-state"
  [ -d "$root/research-sdd/profile/general" ] || bad="$bad no-initial-general-render"
  t_sha="$(cksum < "$tp" 2>/dev/null)"; t_marker="$(cat "$mk" 2>/dev/null)"
  [ -n "$t_sha" ] && [ -n "$t_marker" ] || bad="$bad no-template-or-marker"
  bash "$sut" --home "$home" --harness gentle-shell --profile claude >/dev/null 2>&1
  [ "$(cksum < "$tp" 2>/dev/null)" = "$t_sha" ] || bad="$bad template-changed-by-switch"
  [ "$(cat "$mk" 2>/dev/null)" = "$t_marker" ] || bad="$bad template-marker-changed-by-switch"
  grep -q '^profile=template$' "$mk" 2>/dev/null || bad="$bad template-marker-lost-its-profile"
  grep -q '^profile=claude$' "$sm" 2>/dev/null || bad="$bad skill-marker-not-switched"
  [ ! -e "$root/research-sdd/profile/general" ] || bad="$bad orphan-general-render-kept"
  bash "$sut" --home "$home" --harness gentle-shell --profile general >/dev/null 2>&1
  [ -f "$root/research-sdd/profile/general/skills/research-sdd/SKILL.md" ] || bad="$bad general-render-not-restored"
  [ "$(cksum < "$tp" 2>/dev/null)" = "$t_sha" ] || bad="$bad template-changed-by-switch-back"
  [ "$(cat "$mk" 2>/dev/null)" = "$t_marker" ] || bad="$bad template-marker-changed-by-switch-back"
  grep -q '^profile=general$' "$sm" 2>/dev/null || bad="$bad skill-marker-not-switched-back"
  printf '%s' "${bad:-OK}" | sed 's/^ //'
}
_ti="$(_tmpl_isolation_scenario "$SUT" "$TMP/tmpl-iso")"
if [ "$_ti" = OK ]; then ok "template marker isolation: 2 installs + skill-profile switch (general→claude→general) leave template, its marker and the render dir intact"
else no "template marker isolation broken: $_ti"; fi

if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: template marker shared with the skill marker (kit issue #1469) --"
  MTI="$MKI/research-sdd-install.MUTANT-TMPLSHARE.$$.sh"
  if mutant_sed "$SUT" "$MTI" 's|tmpl_marker="\$config_root/research-sdd/.installed-template-state"|tmpl_marker="$config_root/research-sdd/.installed-skill-state"|'; then
    _ti_m="$(_tmpl_isolation_scenario "$MTI" "$TMP/tmpl-iso-mut")"
    # The SPECIFIC failure the shared marker causes: the template marker loses profile=template (the
    # skill's marker overwrites it). A missing/broken installer yields other tokens and must not count.
    # The mutant installer must also have RUN (it wrote the skill marker): a missing installer fails too.
    [ -s "$TMP/tmpl-iso-mut/.gentle-shell/agent/research-sdd/.installed-skill-state" ] || _ti_m="installer-did-not-run $_ti_m"
    case " $_ti_m " in
      *" installer-did-not-run "*) no "teeth: MUTANT-TMPLSHARE installer did not run — no teeth established ($_ti_m)" ;;
      *" template-marker-lost-its-profile "*) ok "teeth: a shared skill/template marker makes the template marker lose profile=template ($_ti_m)" ;;
      *) no "teeth: shared-marker mutant did not fail with template-marker-lost-its-profile — check is THEATER or the mutant did not run ($_ti_m)" ;;
    esac
  else no "teeth: MUTANT-TMPLSHARE could not be built (refused by the mutant helper — see above)"; fi
fi

if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: Pi template deployment skipped / template for empty-field harness / harness dropped --"
  # build a temp kit whose install/ holds a given SUT + adapters (everything else symlinked from the live kit)
  _pi_mkkit() {
    local d="$1" sut="$2" adp="$3" f
    mkdir -p "$d/install" || return 1
    cp "$sut" "$d/install/research-sdd-install.sh" && cp "$adp" "$d/install/adapters.sh" || return 1
    for f in "$KITROOT"/* "$KITROOT"/.[!.]*; do
      [ -e "$f" ] || [ -L "$f" ] || continue
      [ "$f" = "$KITROOT/install" ] && continue
      ln -s "$f" "$d/$(basename "$f")" || return 1
    done
  }
  # T-A: skip the template deployment step
  MPA="$MKI/research-sdd-install.MUTANT-PIA.$$.sh"
  mutant_sed "$SUT" "$MPA" 's/if \[ -n "\$template_dest" \]; then/if false; then/' \
    || no "teeth: MUTANT-PIA could not be built (refused by the mutant helper — see above)"
  _pi_mkkit "$TMP/pia-kit" "$MPA" "$HERE/../adapters.sh" && bash "$TMP/pia-kit/install/research-sdd-install.sh" --home "$TMP/pia-home" --harness pi >/dev/null 2>&1
  if [ ! -f "$TMP/pia-home/.pi/agent/prompts/research-sdd.md" ] && [ -f "$TMP/pia-home/.pi/agent/skills/research-sdd/SKILL.md" ]; then
    ok "teeth: template-skipped mutant leaves no prompts/research-sdd.md (skill still installs) → the template assertions bite"
  else no "teeth: template-skipped mutant still deployed the template (or did not run) — template check is THEATER"; fi
  # T-B: the accessor returns a path even when the table field is empty → a template for claude
  MPB="$MKI/adapters.MUTANT-PIB.$$.sh"
  mutant_sed "$HERE/../adapters.sh" "$MPB" '/prompt_template_path)/,/;;/ s/if \[ -n "\$plug" \]/if true/' \
    || no "teeth: MUTANT-PIB could not be built (refused by the mutant helper — see above)"
  out_b=""
  _pi_mkkit "$TMP/pib-kit" "$SUT" "$MPB" && out_b="$(bash "$TMP/pib-kit/install/research-sdd-install.sh" --dry-run --home "$TMP/pib-home" --harness claude 2>&1)"
  if <<<"$out_b" grep -q 'prompt template'; then
    ok "teeth: empty-field-ignoring mutant plans a template for claude → the no-template-for-claude check bites"
  else no "teeth: empty-field mutant did not plan a claude template — PI2 check is THEATER"; fi
  # T-D: supports_slash=true for a harness with no template → the slash invariant must fire
  MPD="$MKI/adapters.MUTANT-PID.$$.sh"
  mutant_sed "$HERE/../adapters.sh" "$MPD" '/_RSDD_SUPPORTS_SLASH=(/,/^)/ s/\[claude\]="false"/[claude]="true"/' \
    || no "teeth: MUTANT-PID could not be built (refused by the mutant helper — see above)"
  if [ "$(_slash_invariant "$MPD")" = "claude " ]; then
    ok "teeth: slash=true without a template (claude) is caught by the slash invariant"
  else no "teeth: slash invariant did not flag the template-less slash=true mutant — PI3 is THEATER"; fi
  # T-C: gentle-shell dropped from RESEARCH_SDD_HARNESSES
  MPC="$MKI/adapters.MUTANT-PIC.$$.sh"
  mutant_sed "$HERE/../adapters.sh" "$MPC" 's/^RESEARCH_SDD_HARNESSES="\(.*\) gentle-shell"/RESEARCH_SDD_HARNESSES="\1"/' \
    || no "teeth: MUTANT-PIC could not be built (refused by the mutant helper — see above)"
  _pi_mkkit "$TMP/pic-kit" "$SUT" "$MPC" && bash "$TMP/pic-kit/install/research-sdd-install.sh" --home "$TMP/pic-home" --harness all >/dev/null 2>&1
  if [ ! -e "$TMP/pic-home/.pi/agent/skills/research-sdd/SKILL.md" ]; then
    no "teeth: harness-dropped mutant run did not execute (pi missing too) — check is THEATER"
  elif [ ! -e "$TMP/pic-home/.gentle-shell" ]; then
    ok "teeth: harness-dropped mutant installs no gentle-shell under --harness all → the --harness all check bites"
  else no "teeth: harness-dropped mutant still installed gentle-shell — registration check is THEATER"; fi
fi

# Dotfiles (kit issue #1299 item 7): the temp kit copy must mirror EVERY top-level entry of the kit,
# dotfiles included (the old `"$KITROOT"/*` glob skipped them).
_dot_missing=""
for _f in "$KITROOT"/.[!.]*; do
  [ -e "$_f" ] || [ -L "$_f" ] || continue
  [ -e "$MK/$(basename "$_f")" ] || [ -L "$MK/$(basename "$_f")" ] || _dot_missing="$_dot_missing $(basename "$_f")"
done
if [ -z "$_dot_missing" ]; then ok "temp kit copy mirrors the kit's top-level dotfiles"
else no "temp kit copy is missing top-level dotfiles:$_dot_missing"; fi

# ================================================================================================
# --verify (kit issue #1702): read-only whole-bundle digest drift report, one typed line per
# harness. Contract under test (header of research-sdd-install.sh):
#   verify harness=<h> status=match|drift|absent|degraded ...   exit 0 match/absent · 1 drift · 2 degraded
# ================================================================================================
_vinst() { bash "$SUT" --home "$1" --harness "$2" >/dev/null 2>&1; }
# _vrun <home> <harness|all> — sets VOUT (stdout+stderr) and VRC.
_vrun() { VOUT="$(bash "$SUT" --verify --home "$1" --harness "$2" 2>&1)"; VRC=$?; }
# _vline <harness> — the single typed verify line for <harness> out of $VOUT.
_vline() { awk -v p="verify harness=$1 " 'index($0,p)==1' <<<"$VOUT"; }
_vhas() { grep -Eq -- "$2" <<<"$(_vline "$1")"; }
# _home_snap <home> — path + content checksum of everything under <home> (read-only observation).
_home_snap() { (cd "$1" && { find . | LC_ALL=C sort; find . -type f -exec cksum {} + | LC_ALL=C sort; }); }
# _nosha_path <dir> — a PATH dir holding only the non-hash tools the verify path needs, so
# sha256sum / shasum / python3 are genuinely unreachable (a typed degraded state, not a crash).
_nosha_path() {
  local d="$1" t p; mkdir -p "$d"
  for t in awk sed sort find basename dirname cat grep tr uniq cut head tail wc readlink cmp rm mkdir mktemp mv cp ln paste; do
    p="$(command -v "$t" 2>/dev/null)" || continue
    case "$p" in /*) ln -sf "$p" "$d/$t" ;; esac
  done
}

echo "-- --verify (kit issue #1702) --"

# V1 — fresh install → every harness reports match with a 64-hex bundle digest, exit 0.
vh="$TMP/v1-home"; mkdir -p "$vh"; bash "$SUT" --home "$vh" >/dev/null 2>&1
_vrun "$vh" all
vm=0; for _h in claude pi gentle-shell; do
  _vhas "$_h" "^verify harness=$_h status=match bundle_sha256=[0-9a-f]{64}( |$)" && vm=$((vm+1))
done
if [ "$vm" = 3 ] && [ "$VRC" = 0 ]; then ok "V1: --verify after a clean install of all harnesses → 3 typed match lines, exit 0"
else no "V1: expected 3 match lines + exit 0 (matches=$vm rc=$VRC) :: $(tr '\n' '|' <<<"$VOUT")"; fi

# V2 — install records the bundle state beside the skill marker (config_root/research-sdd/).
v2=0; for _h in claude pi gentle-shell; do
  _cr="$(bash -c ". '$MKI/adapters.sh'; rsdd_field $_h config_root '$vh'")"
  [ -f "$_cr/research-sdd/.installed-bundle-state" ] && grep -Eq '^bundle_sha256=[0-9a-f]{64}$' "$_cr/research-sdd/.installed-bundle-state" && v2=$((v2+1))
done
[ "$v2" = 3 ] && ok "V2: install records .installed-bundle-state (bundle_sha256=<64 hex>) for every harness" \
  || no "V2: bundle-state record missing/malformed for some harness ($v2/3)"

# V3 — absent: an empty home is reported absent (exit 0) and NOTHING is created.
vh="$TMP/v3-home"; mkdir -p "$vh"; snap0="$(_home_snap "$vh")"
_vrun "$vh" all
va=0; for _h in claude pi gentle-shell; do _vhas "$_h" "^verify harness=$_h status=absent( |$)" && va=$((va+1)); done
snap1="$(_home_snap "$vh")"
if [ "$va" = 3 ] && [ "$VRC" = 0 ]; then ok "V3: --verify on an empty home → 3 absent lines, exit 0"
else no "V3: expected 3 absent + exit 0 (absent=$va rc=$VRC) :: $(tr '\n' '|' <<<"$VOUT")"; fi
[ "$snap0" = "$snap1" ] && ok "V3: --verify on an empty home created nothing (read-only)" \
  || no "V3: --verify wrote into the home"

# V4 — drift at the FIRST sorted bundle member (claude: the launcher section in CLAUDE.md).
vh="$TMP/v4-home"; mkdir -p "$vh"; _vinst "$vh" claude
sed -i 's|^Skill file: .*|Skill file: /somewhere/else|' "$vh/.claude/CLAUDE.md"
_vrun "$vh" claude; l="$(_vline claude)"
if [ "$VRC" = 1 ] && [[ "$l" == *"status=drift"* ]] && [[ "$l" == *"CLAUDE.md#research-sdd-section"* ]] && [[ "$l" != *"skills/research-sdd/SKILL.md"* ]]; then
  ok "V4: first-sorted member drifted (launcher section) → drift naming only it, exit 1"
else no "V4: wrong first-member drift report (rc=$VRC) :: $l"; fi

# V5 — drift at the LAST sorted bundle member (claude: skills/research-sdd/SKILL.md).
vh="$TMP/v5-home"; mkdir -p "$vh"; _vinst "$vh" claude
printf '\nlocal hand edit\n' >> "$vh/.claude/skills/research-sdd/SKILL.md"
_vrun "$vh" claude; l="$(_vline claude)"
if [ "$VRC" = 1 ] && [[ "$l" == *"status=drift"* ]] && [[ "$l" == *"skills/research-sdd/SKILL.md"* ]] && [[ "$l" != *"CLAUDE.md#"* ]]; then
  ok "V5: last-sorted member drifted (SKILL.md) → drift naming only it, exit 1"
else no "V5: wrong last-member drift report (rc=$VRC) :: $l"; fi

# V6 — drift in the MIDDLE (pi: a rendered profile file) while first/last stay intact.
vh="$TMP/v6-home"; mkdir -p "$vh"; _vinst "$vh" pi
_rf="$(find "$vh/.pi/agent/research-sdd/profile" -type f | LC_ALL=C sort | sed -n 1p)"
printf 'tamper\n' >> "$_rf"
_vrun "$vh" pi; l="$(_vline pi)"
if [ "$VRC" = 1 ] && [[ "$l" == *"status=drift"* ]] && [[ "$l" == *"research-sdd/profile/general/"* ]] && [[ "$l" != *"skills/research-sdd/SKILL.md"* ]] && [[ "$l" != *"AGENTS.md#"* ]]; then
  ok "V6: middle member drifted (rendered profile file) → drift naming only it, exit 1"
else no "V6: wrong middle-member drift report (rc=$VRC) :: $l"; fi

# V7 — a DELETED member and an EXTRA rendered file are both drift, named with their kind.
vh="$TMP/v7-home"; mkdir -p "$vh"; _vinst "$vh" pi
rm -f "$vh/.pi/agent/prompts/research-sdd.md"
printf 'x\n' > "$vh/.pi/agent/research-sdd/profile/general/EXTRA-FILE.md"
_vrun "$vh" pi; l="$(_vline pi)"
if [ "$VRC" = 1 ] && [[ "$l" == *"status=drift"* ]] && [[ "$l" == *"prompts/research-sdd.md"* ]] && [[ "$l" == *"EXTRA-FILE.md"* ]] \
   && [[ "$l" == *"missing"* ]] && [[ "$l" == *"extra"* ]]; then
  ok "V7: a deleted member (missing) and a stray rendered file (extra) are both drift, named"
else no "V7: missing/extra not reported (rc=$VRC) :: $l"; fi

# V8 — edits OUTSIDE the marked launcher section never count as drift.
vh="$TMP/v8-home"; mkdir -p "$vh/.claude"; printf '# my own notes\n' > "$vh/.claude/CLAUDE.md"; _vinst "$vh" claude
printf '\n# more user content after the block\n' >> "$vh/.claude/CLAUDE.md"
sed -i '1s/.*/# my REWRITTEN notes/' "$vh/.claude/CLAUDE.md"
_vrun "$vh" claude
[ "$VRC" = 0 ] && _vhas claude 'status=match' \
  && ok "V8: user edits outside the research-sdd marked block stay match (only the managed block is digested)" \
  || no "V8: user edits outside the block caused a non-match (rc=$VRC) :: $(_vline claude)"

# V9 — single-file bundle (list edge): a hand-written record with ONE member matches, then drifts.
vh="$TMP/v9-home"; mkdir -p "$vh/.claude/skills/research-sdd" "$vh/.claude/research-sdd"
printf 'only file\n' > "$vh/.claude/skills/research-sdd/SKILL.md"
_s1="$(sha256sum "$vh/.claude/skills/research-sdd/SKILL.md" | awk '{print $1}')"
_b1="$(printf '%s\t%s\n' "$_s1" 'skills/research-sdd/SKILL.md' | sha256sum | awk '{print $1}')"
printf 'bundle_sha256=%s\nprofile=claude\nfile=%s  %s\n' "$_b1" "$_s1" 'skills/research-sdd/SKILL.md' > "$vh/.claude/research-sdd/.installed-bundle-state"
_vrun "$vh" claude
[ "$VRC" = 0 ] && _vhas claude 'status=match .*files=1( |$)' \
  && ok "V9: single-file recorded bundle → match (files=1), exit 0" \
  || no "V9: single-file bundle not matched (rc=$VRC) :: $(_vline claude)"
printf 'changed\n' > "$vh/.claude/skills/research-sdd/SKILL.md"
_vrun "$vh" claude
[ "$VRC" = 1 ] && _vhas claude 'status=drift.*skills/research-sdd/SKILL.md' \
  && ok "V9: single-file bundle drifts when that one file changes, exit 1" \
  || no "V9: single-file drift missed (rc=$VRC) :: $(_vline claude)"

# V10 — degraded: no sha256 tool reachable → typed degraded, exit 2 (never a silent match/absent).
vh="$TMP/v10-home"; mkdir -p "$vh"; _vinst "$vh" claude
_nosha_path "$TMP/v10-bin"
if PATH="$TMP/v10-bin" command -v sha256sum >/dev/null 2>&1 || PATH="$TMP/v10-bin" command -v python3 >/dev/null 2>&1; then
  no "V10: setup — a hash tool is still reachable on the restricted PATH"
else
  VOUT="$(PATH="$TMP/v10-bin" "$(command -v bash)" "$SUT" --verify --home "$vh" --harness claude 2>&1)"; VRC=$?
  l="$(_vline claude)"
  if [ "$VRC" = 2 ] && [[ "$l" == *"status=degraded"* ]] && [[ "$l" == *"sha256"* ]]; then
    ok "V10: no sha256 tool → typed degraded line naming sha256, exit 2"
  else no "V10: missing hash tool not typed degraded (rc=$VRC) :: $VOUT"; fi
  # The same restricted run on an EMPTY home must also be degraded, not absent (could not prove it looked).
  mkdir -p "$TMP/v10-empty"
  VOUT="$(PATH="$TMP/v10-bin" "$(command -v bash)" "$SUT" --verify --home "$TMP/v10-empty" --harness claude 2>&1)"; VRC=$?
  [ "$VRC" = 2 ] && _vhas claude 'status=degraded' \
    && ok "V10: no sha256 tool on an empty home → degraded (not a silent absent), exit 2" \
    || no "V10: empty home with no hash tool reported $(_vline claude) rc=$VRC"
fi

# V11 — files present but no bundle record (pre-#1702 install) → degraded, never match/absent.
vh="$TMP/v11-home"; mkdir -p "$vh/.claude/skills/research-sdd"; cp "$KITROOT/skills/research-sdd/SKILL.md" "$vh/.claude/skills/research-sdd/SKILL.md"
_vrun "$vh" claude
[ "$VRC" = 2 ] && _vhas claude 'status=degraded .*(no bundle record|re-run)' \
  && ok "V11: installed files with no bundle record → degraded (re-run install), exit 2" \
  || no "V11: unrecorded install not degraded (rc=$VRC) :: $(_vline claude)"

# V12 — a corrupt record (bundle_sha256 does not match its own file lines) → degraded, exit 2.
vh="$TMP/v12-home"; mkdir -p "$vh"; _vinst "$vh" claude
sed -i 's/^bundle_sha256=.*/bundle_sha256=0000000000000000000000000000000000000000000000000000000000000000/' "$vh/.claude/research-sdd/.installed-bundle-state"
_vrun "$vh" claude
[ "$VRC" = 2 ] && _vhas claude 'status=degraded .*record' \
  && ok "V12: self-inconsistent bundle record → degraded (record corrupt), exit 2" \
  || no "V12: corrupt record not degraded (rc=$VRC) :: $(_vline claude)"

# V13 — --verify NEVER writes: byte-identical home before/after, in the match, drift and degraded states.
vh="$TMP/v13-home"; mkdir -p "$vh"; bash "$SUT" --home "$vh" >/dev/null 2>&1
snap0="$(_home_snap "$vh")"; _vrun "$vh" all; snap1="$(_home_snap "$vh")"
printf 'x\n' >> "$vh/.claude/skills/research-sdd/SKILL.md"
snap2="$(_home_snap "$vh")"; _vrun "$vh" all; snap3="$(_home_snap "$vh")"
if [ "$snap0" = "$snap1" ] && [ "$snap2" = "$snap3" ] && [ -n "$snap0" ]; then
  ok "V13: --verify leaves the home byte-identical in both the match and the drift state (no writes)"
else no "V13: --verify changed the home tree"; fi
# …and also under a read-only home (a write attempt would fail loudly and flip the exit code).
# chmod a-w must actually deny writes (false for root) or this check proves nothing: SKIP loudly then.
chmod -R a-w "$vh"
if { : > "$vh/.ro-probe"; } 2>/dev/null; then
  rm -f "$vh/.ro-probe"; chmod -R u+w "$vh"
  printf '  SKIP  V13: read-only home check — chmod has no effect here (running as root?); not counted\n'
else
  _vrun "$vh" all; _ro_rc=$VRC; chmod -R u+w "$vh"
  [ "$_ro_rc" = 1 ] && ok "V13: --verify on a read-only home still reports drift, exit 1 (needs no write access)" \
    || no "V13: read-only home verify returned rc=$_ro_rc"
fi

# V14 — mixed fleet: claude installed, others absent → exit 0; drift anywhere → exit 1.
vh="$TMP/v14-home"; mkdir -p "$vh"; _vinst "$vh" claude
_vrun "$vh" all
[ "$VRC" = 0 ] && _vhas claude 'status=match' && _vhas pi 'status=absent' && _vhas gentle-shell 'status=absent' \
  && ok "V14: claude installed + pi/gentle-shell absent → match/absent/absent, exit 0" \
  || no "V14: mixed fleet wrong (rc=$VRC) :: $(printf '%s' "$VOUT" | tr '\n' '|')"
printf 'z\n' >> "$vh/.claude/skills/research-sdd/SKILL.md"; _vrun "$vh" all
[ "$VRC" = 1 ] && ok "V14: drift in one harness among absent ones → exit 1" || no "V14: expected exit 1, got $VRC"

# V15 — option conflicts and unknown harness: usage errors, exit 2, no verify lines claimed.
for _bad in "--dry-run" "--force-skill" "--profile general"; do
  # shellcheck disable=SC2086
  VOUT="$(bash "$SUT" --verify $_bad --home "$TMP/v15-home" 2>&1)"; VRC=$?
  if [ "$VRC" = 2 ] && [[ "$VOUT" == *'--verify is read-only'* ]]; then ok "V15: --verify with $_bad → usage error, exit 2"
  else no "V15: --verify $_bad returned rc=$VRC :: $VOUT"; fi
done
VOUT="$(bash "$SUT" --verify --harness nosuch --home "$TMP/v15-home" 2>&1)"; VRC=$?
[ "$VRC" = 2 ] && ok "V15: --verify with an unknown harness → exit 2" || no "V15: unknown harness verify rc=$VRC"

# V16 — a hand-edited SKILL.md kept by install is NOT baselined: verify keeps reporting drift until
#       --force-skill actually restores managed content.
vh="$TMP/v16-home"; mkdir -p "$vh"; _vinst "$vh" claude
printf '\nhand edit\n' >> "$vh/.claude/skills/research-sdd/SKILL.md"
_vinst "$vh" claude; _vrun "$vh" claude
[ "$VRC" = 1 ] && ok "V16: re-install that KEEPS a hand-edit does not re-baseline it — verify still drift" \
  || no "V16: hand-edit was silently baselined (rc=$VRC) :: $(_vline claude)"
bash "$SUT" --home "$vh" --harness claude --force-skill >/dev/null 2>&1; _vrun "$vh" claude
[ "$VRC" = 0 ] && ok "V16: --force-skill restores managed content → verify match again" \
  || no "V16: still not match after --force-skill (rc=$VRC) :: $(_vline claude)"

# V17 — a dry-run install records nothing.
vh="$TMP/v17-home"; mkdir -p "$vh"; bash "$SUT" --dry-run --home "$vh" >/dev/null 2>&1
[ -z "$(find "$vh" -name '.installed-bundle-state' 2>/dev/null)" ] && [ -z "$(find "$vh" -type f 2>/dev/null)" ] \
  && ok "V17: --dry-run install writes no bundle state (and no files)" || no "V17: dry-run wrote files"

# V18 — --help documents --verify and its exit codes.
help_v="$(bash "$SUT" --help 2>&1)"
<<<"$help_v" grep -q -- '--verify' && <<<"$help_v" grep -Eq 'Exit: 0 = .*match or absent' && <<<"$help_v" grep -Eq '2 = at least one harness' \
  && ok "V18: --help documents --verify and the 0/1/2 exit codes" || no "V18: --help lacks --verify / exit codes"

# _stub_tool <dir> <name> <body> — a PATH shim: $REAL is the real tool, resolved before any PATH change.
_stub_tool() {
  local d="$1" n="$2" body="$3" real
  real="$(command -v "$n")" || return 1
  mkdir -p "$d"
  printf '#!/usr/bin/env bash\nREAL=%q\n%s\nexec "$REAL" "$@"\n' "$real" "$body" > "$d/$n"; chmod +x "$d/$n"
}

# V19 — a kept hand-edit is named as the CAUSE; members the run redeployed are not blamed.
vh="$TMP/v19-home"; mkdir -p "$vh"; _vinst "$vh" pi
printf '\nhand\n' >> "$vh/.pi/agent/prompts/research-sdd.md"
_vinst "$vh" pi; _vrun "$vh" pi; l="$(_vline pi)"
if [ "$VRC" = 1 ] && [[ "$l" == *"drifted=prompts/research-sdd.md (modified)"* ]] && [[ "$l" == *"kept-hand-edit=prompts/research-sdd.md"* ]] \
   && [[ "$l" != *"skills/research-sdd/SKILL.md"* ]] && [[ "$l" != *"AGENTS.md#"* ]]; then
  ok "V19: kept hand-edit → drift names only that member and prints kept-hand-edit=<path>"
else no "V19: hand-edit cause not named / other members blamed (rc=$VRC) :: $l"; fi

# V19b — once the kept file is restored by hand, a DIFFERENT member's drift must not name it as the cause.
f19="$vh/.pi/agent/prompts/research-sdd.md"; sz="$(wc -c < "$f19")"; truncate -s "$((sz - 6))" "$f19"
printf '\nother\n' >> "$vh/.pi/agent/skills/research-sdd/SKILL.md"
_vrun "$vh" pi; l="$(_vline pi)"
if [ "$VRC" = 1 ] && [[ "$l" == *"drifted=skills/research-sdd/SKILL.md (modified)"* ]] && [[ "$l" != *"kept-hand-edit="* ]]; then
  ok "V19b: restored kept file is not blamed when another member drifts"
else no "V19b: stale kept-hand-edit hint (rc=$VRC) :: $l"; fi

# V20 — degraded branches: unsafe recorded profile, unreadable member, unreadable record.
vh="$TMP/v20a-home"; mkdir -p "$vh"; _vinst "$vh" claude
sed -i 's/^profile=.*/profile=..\/evil/' "$vh/.claude/research-sdd/.installed-bundle-state"
_vrun "$vh" claude
[ "$VRC" = 2 ] && _vhas claude 'status=degraded .*unsafe' \
  && ok "V20: an unsafe recorded profile name → degraded, exit 2" || no "V20: unsafe profile not degraded (rc=$VRC) :: $(_vline claude)"
vh="$TMP/v20b-home"; mkdir -p "$vh"; _vinst "$vh" claude
chmod 000 "$vh/.claude/skills/research-sdd/SKILL.md"
if [ -r "$vh/.claude/skills/research-sdd/SKILL.md" ]; then
  printf '  SKIP  V20: unreadable-member check — chmod 000 has no effect here (running as root?); not counted\n'
else
  _vrun "$vh" claude
  [ "$VRC" = 2 ] && _vhas claude 'status=degraded' && ! _vhas claude 'status=(drift|match)' \
    && ok "V20: an existing-but-unreadable member → degraded (not drift/missing), exit 2" || no "V20: unreadable member rc=$VRC :: $(_vline claude)"
fi
chmod 644 "$vh/.claude/skills/research-sdd/SKILL.md"
vh="$TMP/v20c-home"; mkdir -p "$vh"; _vinst "$vh" claude
chmod 000 "$vh/.claude/research-sdd/.installed-bundle-state"
if [ -r "$vh/.claude/research-sdd/.installed-bundle-state" ]; then
  printf '  SKIP  V20: unreadable-record check — chmod 000 has no effect here (running as root?); not counted\n'
else
  _vrun "$vh" claude
  [ "$VRC" = 2 ] && _vhas claude 'status=degraded .*unreadable' \
    && ok "V20: an unreadable bundle record → degraded (unreadable), exit 2" || no "V20: unreadable record rc=$VRC :: $(_vline claude)"
fi
chmod 644 "$vh/.claude/research-sdd/.installed-bundle-state"

# V21 — the record is written ATOMICALLY: temp beside the state file; removed when the final mv fails.
vh="$TMP/v21-home"; mkdir -p "$vh" "$TMP/v21-log"
_stub_tool "$TMP/v21-mk" mktemp 'printf "%s\n" "$*" >> "$STUB_LOG"'
STUB_LOG="$TMP/v21-log/mktemp.log" PATH="$TMP/v21-mk:$PATH" bash "$SUT" --home "$vh" --harness claude >/dev/null 2>&1
if grep -qF "$vh/.claude/research-sdd/.installed-bundle-state." "$TMP/v21-log/mktemp.log"; then
  ok "V21: the record temp file is created in the state file's own directory (same-filesystem rename)"
else no "V21: record temp not created beside the state file :: $(cat "$TMP/v21-log/mktemp.log")"; fi
vh="$TMP/v21b-home"; mkdir -p "$vh"
_stub_tool "$TMP/v21-mv" mv 'case "${@: -1}" in *.installed-bundle-state) exit 1 ;; esac'
PATH="$TMP/v21-mv:$PATH" bash "$SUT" --home "$vh" --harness claude >/dev/null 2>&1; v21rc=$?
v21left="$(find "$vh/.claude/research-sdd" -name '.installed-bundle-state*' 2>/dev/null | awk 'END{print NR}')"
if [ "$v21rc" != 0 ] && [ "$v21left" = 0 ]; then ok "V21: a failing final mv exits non-zero and leaks no temp file"
else no "V21: failing mv left rc=$v21rc leftovers=$v21left"; fi

# V22 — a find failure while walking the rendered profile is degraded, never a confident "missing".
vh="$TMP/v22-home"; mkdir -p "$vh"; _vinst "$vh" pi; printf 'x\n' > "$vh/.pi/agent/research-sdd/profile/general/EXTRA-FILE.md"
_stub_tool "$TMP/v22-find" find 'case "$*" in *"-type f"*research-sdd/profile*|*research-sdd/profile*"-type f"*) exit 1 ;; esac'
VOUT="$(PATH="$TMP/v22-find:$PATH" bash "$SUT" --verify --home "$vh" --harness pi 2>&1)"; VRC=$?
[ "$VRC" = 2 ] && _vhas pi 'status=degraded .*traversed' \
  && ok "V22: find failing on the profile dir → degraded (could not be traversed), exit 2" || no "V22: find failure not degraded (rc=$VRC) :: $(_vline pi)"

# V23 — a member PATH that merely contains the text MISSING is not a missing member (hash column only).
vh="$TMP/v23-home"; mkdir -p "$vh"; _vinst "$vh" pi
printf 'n\n' > "$vh/.pi/agent/research-sdd/profile/general/MISSING-NOTES.md"
printf '#!/usr/bin/env bash\nset -uo pipefail\n. "$1" --help >/dev/null 2>&1\n_rsdd_write_bundle_state pi "$2" general\necho "RC=$?"\n' > "$MKI/v23-driver.sh"
v23="$(bash "$MKI/v23-driver.sh" "$SUT" "$vh" 2>&1)"
if [[ "$v23" == *"RC=0"* ]] && grep -q 'MISSING-NOTES.md' "$vh/.pi/agent/research-sdd/.installed-bundle-state"; then
  ok "V23: a profile file whose NAME contains MISSING is recorded (only the hash column is checked)"
else no "V23: record refused for a path containing MISSING :: $v23"; fi

# --- --verify teeth (kit issue #1702): every mutant is a temp copy built by lib/mutant.sh (refused =
#     counted exactly once, its tooth never runs); every tooth pins the exact good/bad exit codes plus an
#     anchored typed line, and a crash can never read as a bite.
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: --verify mutants (lib/mutant.sh) --"
  _CRASH='integer expression expected|syntax error|unbound variable|Traceback|ImportError|ModuleNotFoundError|command not found'
  _vmk() { mutant_chain "$@" || { fail=$((fail+1)); return 1; }; }
  _vtt() { if mutant_tooth "$@"; then pass=$((pass+1)); else fail=$((fail+1)); fi; }
  _TV="$TMP/teeth-verify"; mkdir -p "$_TV"
  # Fixtures (built with the REAL SUT).
  for _n in last first outside write unrec corrupt extra mixed; do mkdir -p "$_TV/$_n"; done
  _vinst "$_TV/last" claude;    printf '\nlocal hand edit\n' >> "$_TV/last/.claude/skills/research-sdd/SKILL.md"
  _vinst "$_TV/first" claude;   sed -i 's|^Skill file: .*|Skill file: /elsewhere|' "$_TV/first/.claude/CLAUDE.md"
  mkdir -p "$_TV/outside/.claude"; printf '# notes\n' > "$_TV/outside/.claude/CLAUDE.md"; _vinst "$_TV/outside" claude
  sed -i '1s/.*/# REWRITTEN notes/' "$_TV/outside/.claude/CLAUDE.md"
  _vinst "$_TV/write" claude
  mkdir -p "$_TV/unrec/.claude/skills/research-sdd"; cp "$KITROOT/skills/research-sdd/SKILL.md" "$_TV/unrec/.claude/skills/research-sdd/SKILL.md"
  _vinst "$_TV/corrupt" claude
  sed -i 's/^bundle_sha256=.*/bundle_sha256=0000000000000000000000000000000000000000000000000000000000000000/' "$_TV/corrupt/.claude/research-sdd/.installed-bundle-state"
  _vinst "$_TV/extra" pi; printf 'x\n' > "$_TV/extra/.pi/agent/research-sdd/profile/general/EXTRA-FILE.md"
  _vinst "$_TV/mixed" claude; printf 'x\n' >> "$_TV/mixed/.claude/skills/research-sdd/SKILL.md"
  mkdir -p "$_TV/mixed/.pi/agent/skills/research-sdd"; printf 'x\n' > "$_TV/mixed/.pi/agent/skills/research-sdd/SKILL.md"
  mkdir -p "$_TV/empty" "$_TV/bin"; _nosha_path "$_TV/bin"
  _ENV="$(command -v env)"; _BASH="$(command -v bash)"

  # T1 — digest comparison forced equal → a drifted bundle would read as match.
  _vmk "teeth: V-T1 forced-equal digest" "$SUT" "$MKI/v-t1.sh" 's/if \[ "\$cur_digest" = "\$rec_digest" \]; then/if true; then/' \
    && _vtt "teeth: forced-equal digest → drifted bundle reads as match" 1 0 "$MKI/v-t1.sh" --good-has 'status=drift' --bad-has 'status=match' --bad-lacks "$_CRASH" -- "$_BASH" @SUT@ --verify --home "$_TV/last" --harness claude
  # T2 — drift reported but exit forced to 0.
  _vmk "teeth: V-T2 drift exit 0" "$SUT" "$MKI/v-t2.sh" 's/\(printf .verify harness=%s status=drift drifted=%s\\n. "\$h" "\$drift_names"\)$/\1; return 0/' \
    && _vtt "teeth: drift line with exit 0 → CI cannot gate on drift" 1 0 "$MKI/v-t2.sh" --good-has 'status=drift' --bad-has 'status=drift' --bad-lacks "$_CRASH" -- "$_BASH" @SUT@ --verify --home "$_TV/last" --harness claude
  # T3 — list edges: first member skipped / last member skipped by the manifest walk.
  _vmk "teeth: V-T3 skip first member" "$SUT" "$MKI/v-t3.sh" 's/awk .NF. | LC_ALL=C sort -u)"/awk '"'"'NF'"'"' | LC_ALL=C sort -u | sed 1d)"/' \
    && _vtt "teeth: first member skipped → first-position drift is lost" 1 1 "$MKI/v-t3.sh" --good-has 'CLAUDE.md#research-sdd-section \(modified\)' --bad-lacks "$_CRASH|CLAUDE.md#research-sdd-section \\(modified\\)" -- "$_BASH" @SUT@ --verify --home "$_TV/first" --harness claude
  _vmk "teeth: V-T3b no trailing newline on the manifest loop" "$SUT" "$MKI/v-t3b.sh" 's|^  done <<<"\$rels"$|  done < <(printf "%s" "$rels")|' \
    && _vtt "teeth: manifest loop misses the LAST member (no trailing newline) → last-position drift mislabelled" 1 1 "$MKI/v-t3b.sh" --good-has 'skills/research-sdd/SKILL.md \(modified\)' --bad-lacks "$_CRASH|skills/research-sdd/SKILL.md \\(modified\\)" -- "$_BASH" @SUT@ --verify --home "$_TV/last" --harness claude
  # T4 — the sha256 probe disabled → an empty home with no hash tool reads as absent (silent zero).
  _vmk "teeth: V-T4 no sha256 probe" "$SUT" "$MKI/v-t4.sh" '/^_rsdd_have_sha256() {/,/^}/s/^  command -v sha256sum.*$/  return 0/' \
    && _vtt "teeth: sha256 probe disabled → no-hash-tool run reads as clean" 2 0 "$MKI/v-t4.sh" --good-has 'status=degraded' --bad-has 'status=absent' --bad-lacks "$_CRASH" -- "$_ENV" "PATH=$_TV/bin" "$_BASH" @SUT@ --verify --home "$_TV/empty" --harness claude
  # T5 — verify writes into the home (the read-only contract).
  _vmk "teeth: V-T5 verify writes" "$SUT" "$MKI/v-t5.sh" '/^_rsdd_verify_one() {/,/^}/s|^  pf="\$(rsdd_field "\$h" prompt_file "\$home")"$|&\n  : > "$root/.zz-verify-wrote"|' \
    && _vtt "teeth: --verify that writes a file is caught by the before/after tree snapshot" 0 0 "$MKI/v-t5.sh" --good-has '^UNCHANGED$' --bad-has '^WROTE$' --bad-lacks "$_CRASH" -- "$_BASH" -c 'b="$(find "$2" | LC_ALL=C sort)"; bash "$1" --verify --home "$2" --harness claude >/dev/null 2>&1; a="$(find "$2" | LC_ALL=C sort)"; if [ "$a" = "$b" ]; then echo UNCHANGED; else echo WROTE; fi' _ @SUT@ "$_TV/write"
  # T6 — degraded no longer outranks drift in the aggregate exit.
  _vmk "teeth: V-T6 drift outranks degraded" "$SUT" "$MKI/v-t6.sh" 's/\[ "\$degraded" = 1 \] \&\& vrc=2/:/' \
    && _vtt "teeth: degraded not outranking drift → a harness that could not be checked reads as plain drift" 2 0 "$MKI/v-t6.sh" --good-has 'status=degraded' --bad-has 'status=degraded' --bad-lacks "$_CRASH" -- "$_BASH" @SUT@ --verify --home "$_TV/mixed"
  # T7 — install stops recording the bundle.
  _vmk "teeth: V-T7 no record" "$SUT" "$MKI/v-t7.sh" 's/if ! _rsdd_write_bundle_state "\$h" "\$home" "\$profile" "\$kept"; then/if false; then/' \
    && _vtt "teeth: install that records nothing → verify cannot vouch for the install" 0 2 "$MKI/v-t7.sh" --good-has 'status=match' --bad-has 'status=degraded' --bad-lacks "$_CRASH" -- "$_BASH" -c 'h="$(mktemp -d)"; "$1" "$2" --home "$h" --harness claude >/dev/null 2>&1; "$1" "$2" --verify --home "$h" --harness claude; rc=$?; rm -rf "$h"; exit $rc' _ "$_BASH" @SUT@
  # T8 — a kept hand-edit gets baselined by the next install.
  _vmk "teeth: V-T8 baseline hand-edit" "$SUT" "$MKI/v-t8.sh" 's/| _rsdd_apply_kept "\$kept")"/| cat)"/' \
    && _vtt "teeth: kept hand-edit recorded as the baseline → drift silently becomes match" 1 0 "$MKI/v-t8.sh" --good-has 'status=drift' --bad-has 'status=match' --bad-lacks "$_CRASH" -- "$_BASH" -c 'h="$(mktemp -d)"; "$1" "$2" --home "$h" --harness claude >/dev/null 2>&1; printf "\nhand\n" >> "$h/.claude/skills/research-sdd/SKILL.md"; "$1" "$2" --home "$h" --harness claude >/dev/null 2>&1; "$1" "$2" --verify --home "$h" --harness claude; rc=$?; rm -rf "$h"; exit $rc' _ "$_BASH" @SUT@
  # T9 — the launcher block is replaced by the whole prompt file (user edits would count as drift).
  _vmk "teeth: V-T9 whole-file section hash" "$SUT" "$MKI/v-t9.sh" 's/if text="\$(_rsdd_section_text "\$f")"; then/if text="$(cat "$f")"; then/' \
    && _vtt "teeth: whole-file hashing → user edits outside the block read as drift" 0 1 "$MKI/v-t9.sh" --good-has 'status=match' --bad-has 'status=drift' --bad-lacks "$_CRASH" -- "$_BASH" @SUT@ --verify --home "$_TV/outside" --harness claude
  # T10 — extra files in the rendered profile are no longer named.
  _vmk "teeth: V-T10 extra not named" "$SUT" "$MKI/v-t10.sh" '/for (p in cur) if (!(p in rec)/d' \
    && _vtt "teeth: extra-file branch removed → a stray rendered file is no longer named" 1 2 "$MKI/v-t10.sh" --good-has 'EXTRA-FILE.md \(extra\)' --bad-has 'status=degraded' --bad-lacks "$_CRASH" -- "$_BASH" @SUT@ --verify --home "$_TV/extra" --harness pi
  # T11 — the self-consistency check of the record removed.
  _vmk "teeth: V-T11 no record self-check" "$SUT" "$MKI/v-t11.sh" 's/if \[ "\$rec_calc" != "\$rec_digest" \]; then/if false; then/' \
    && _vtt "teeth: record self-check removed → a corrupt record is no longer typed as corrupt" 2 2 "$MKI/v-t11.sh" --good-has 'does not match its own file lines' --bad-has 'status=degraded' --bad-lacks "$_CRASH|does not match its own file lines" -- "$_BASH" @SUT@ --verify --home "$_TV/corrupt" --harness claude
  # T12 — installed-but-unrecorded home reads as absent.
  _vmk "teeth: V-T12 unrecorded reads absent" "$SUT" "$MKI/v-t12.sh" 's/\[ -e "\$skill" \] \&\& installed=1/:/' \
    && _vtt "teeth: unrecorded install detection removed → files present but unrecorded read as absent" 2 0 "$MKI/v-t12.sh" --good-has 'no bundle record' --bad-has 'status=absent' --bad-lacks "$_CRASH" -- "$_BASH" @SUT@ --verify --home "$_TV/unrec" --harness claude
  # T13 — --verify no longer refuses --dry-run.
  _vmk "teeth: V-T13 verify accepts --dry-run" "$SUT" "$MKI/v-t13.sh" 's/if \[ "\$dry" = 1 \] || \[ "\$force" = 1 \] || \[ -n "\$profile_flag" \]; then/if [ "$force" = 1 ] || [ -n "$profile_flag" ]; then/' \
    && _vtt "teeth: --verify --dry-run accepted → the usage conflict is not enforced" 2 0 "$MKI/v-t13.sh" --good-has '--verify is read-only' --bad-lacks "$_CRASH|--verify is read-only" -- "$_BASH" @SUT@ --verify --dry-run --home "$_TV/empty" --harness claude

  # --- RDD round 1 teeth ---------------------------------------------------------------------
  mkdir -p "$_TV/pi" "$_TV/unsafe" "$_TV/keptcl"
  _vinst "$_TV/pi" pi; printf 'x\n' > "$_TV/pi/.pi/agent/research-sdd/profile/general/EXTRA-FILE.md"
  _vinst "$_TV/unsafe" claude; sed -i 's/^profile=.*/profile=..\/evil/' "$_TV/unsafe/.claude/research-sdd/.installed-bundle-state"
  _vinst "$_TV/keptcl" claude; printf '\nhand\n' >> "$_TV/keptcl/.claude/skills/research-sdd/SKILL.md"; _vinst "$_TV/keptcl" claude
  _stub_tool "$TMP/tv-mk" mktemp 'printf "%s\n" "$*" >> "$STUB_LOG"'
  _stub_tool "$TMP/tv-mv" mv 'case "${@: -1}" in *.installed-bundle-state) exit 1 ;; esac'
  _stub_tool "$TMP/tv-find" find 'case "$*" in *research-sdd/profile*"-type f"*) exit 1 ;; esac'

  # T14 — record temp created in the system temp dir instead of beside the state file.
  _vmk "teeth: V-T14 record temp not beside state" "$SUT" "$MKI/v-t14.sh" 's|tmp="\$(mktemp "\$state.XXXXXX")"|tmp="$(mktemp)"|' \
    && _vtt "teeth: record temp in the system temp dir → rename can cross filesystems" 0 0 "$MKI/v-t14.sh" --good-has '^SAMEDIR$' --bad-has '^OTHERDIR$' --bad-lacks "$_CRASH" -- "$_BASH" -c 'h="$(mktemp -d)"; l="$h.log"; STUB_LOG="$l" PATH="$3:$PATH" bash "$1" --home "$h" --harness claude >/dev/null 2>&1; if grep -qF "$h/.claude/research-sdd/.installed-bundle-state." "$l"; then echo SAMEDIR; else echo OTHERDIR; fi; rm -rf "$h" "$l"' _ @SUT@ x "$TMP/tv-mk"
  # T15 — temp not removed when the final mv fails.
  _vmk "teeth: V-T15 temp leaks on mv failure" "$SUT" "$MKI/v-t15.sh" 's/mv -f "\$tmp" "\$state" || { rm -f "\$tmp"; return 1; }/mv -f "$tmp" "$state"/' \
    && _vtt "teeth: no cleanup after a failed mv → temp file leaks" 0 0 "$MKI/v-t15.sh" --good-has '^LEFTOVER=0$' --bad-has '^LEFTOVER=1$' --bad-lacks "$_CRASH" -- "$_BASH" -c 'h="$(mktemp -d)"; PATH="$3:$PATH" bash "$1" --home "$h" --harness claude >/dev/null 2>&1; echo "LEFTOVER=$(find "$h/.claude/research-sdd" -name ".installed-bundle-state*" | awk "END{print NR}")"; rm -rf "$h"' _ @SUT@ x "$TMP/tv-mv"
  # T16 — find's status swallowed → an untraversable profile dir reads as drift (missing).
  _vmk "teeth: V-T16 find status swallowed" "$SUT" "$MKI/v-t16.sh" 's|found="\$(find "\$rd" -type f 2>/dev/null)" \|\| return 3|found="$(find "$rd" -type f 2>/dev/null)" \|\| found=""|' \
    && _vtt "teeth: find failure swallowed → a stray profile file goes unseen and the bundle reads as match" 2 0 "$MKI/v-t16.sh" --good-has 'status=degraded' --bad-has 'status=match' --bad-lacks "$_CRASH" -- "$_ENV" "PATH=$TMP/tv-find:$PATH" "$_BASH" @SUT@ --verify --home "$_TV/pi" --harness pi
  # T17 — kept-hand-edit hint dropped from the drift line.
  _vmk "teeth: V-T17 no kept-hand-edit hint" "$SUT" "$MKI/v-t17.sh" 's/if \[ -n "\$kept_names" \]; then/if false; then/' \
    && _vtt "teeth: kept-hand-edit hint dropped → the cause of the drift is not named" 1 1 "$MKI/v-t17.sh" --good-has 'kept-hand-edit=skills/research-sdd/SKILL.md' --bad-lacks "$_CRASH|kept-hand-edit=" -- "$_BASH" @SUT@ --verify --home "$_TV/keptcl" --harness claude
  # T18 — MISSING matched as a substring of the whole manifest.
  _vmk "teeth: V-T18 MISSING substring" "$SUT" "$MKI/v-t18.sh" '/\$1=="MISSING"/c\  case "$manifest" in *MISSING*) return 1 ;; esac' \
    && _vtt "teeth: whole-manifest MISSING match → a path containing MISSING refuses the record" 0 0 "$MKI/v-t18.sh" --good-has '^RC=0$' --bad-has '^RC=1$' --bad-lacks "$_CRASH" -- "$_BASH" -c 'h="$(mktemp -d)"; bash "$1" --home "$h" --harness pi >/dev/null 2>&1; printf "n\n" > "$h/.pi/agent/research-sdd/profile/general/MISSING-NOTES.md"; bash "$2" "$1" "$h"; rm -rf "$h"' _ @SUT@ "$MKI/v23-driver.sh"
  # T19 — the recorded-profile safety check removed.
  _vmk "teeth: V-T19 unsafe profile accepted" "$SUT" "$MKI/v-t19.sh" 's/\[\[ "\$profile" =~ \^\[a-z0-9_-\]+\$ \]\] || return 1/:/' \
    && _vtt "teeth: profile-name check removed → a traversal-shaped recorded profile is accepted" 2 0 "$MKI/v-t19.sh" --good-has 'status=degraded' --bad-has 'status=match' --bad-lacks "$_CRASH" -- "$_BASH" @SUT@ --verify --home "$_TV/unsafe" --harness claude
fi

# --- --verify kit-checkout staleness line (W1): `verify kit status=current|behind|degraded`, advisory
#     (exit code unchanged), read-only, never fetches. $RESEARCH_SDD_KIT_DIR points it at a fixture repo.
echo "-- --verify kit staleness line --"
_kg() { git -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
_kc() { printf '%s\n' "$2" > "$1/f.txt"; _kg -C "$1" add f.txt >/dev/null 2>&1; _kg -C "$1" commit -q -m "$2" >/dev/null 2>&1; }
# _krun <kitdir> [PATH override] — verify against an empty home so only the kit line is interesting.
_krun() {
  if [ -n "${2:-}" ]; then
    VOUT="$(PATH="$2" RESEARCH_SDD_KIT_DIR="$1" "$(command -v bash)" "$SUT" --verify --home "$TMP/kv-home" --harness claude 2>&1)"; VRC=$?
  else
    VOUT="$(RESEARCH_SDD_KIT_DIR="$1" bash "$SUT" --verify --home "$TMP/kv-home" --harness claude 2>&1)"; VRC=$?
  fi
  KLINE="$(awk 'index($0,"verify kit ")==1' <<<"$VOUT")"
}
mkdir -p "$TMP/kv-home"
KUP="$TMP/kv-up"; KCL="$TMP/kv-clone"; KCL2="$TMP/kv-clone2"
mkdir -p "$KUP"; _kg init -q -b main "$KUP" >/dev/null 2>&1; _kc "$KUP" one
_kg clone -q "$KUP" "$KCL" >/dev/null 2>&1; _kg clone -q "$KUP" "$KCL2" >/dev/null 2>&1
if command -v git >/dev/null 2>&1 && [ -d "$KCL/.git" ]; then
  _krun "$KCL"
  if [[ "$KLINE" == "verify kit status=current ref=origin/main behind=0"* ]] && [ "$VRC" = 0 ]; then ok "K1: up-to-date kit checkout → status=current, exit 0"
  else no "K1: expected status=current (rc 0); rc=$VRC line=[$KLINE]"; fi
  # Upstream moves (2 commits) but the clone has NOT fetched: the instrument compares local refs only.
  _kc "$KUP" two; _kc "$KUP" three
  _krun "$KCL"
  if [[ "$KLINE" == *"status=current"* ]] && [ ! -e "$KCL/.git/FETCH_HEAD" ]; then ok "K2: unfetched upstream commits are NOT seen and nothing is fetched (no implicit network)"
  else no "K2: --verify fetched or misreported (line=[$KLINE])"; fi
  _kg -C "$KCL" fetch -q >/dev/null 2>&1; rm -f "$KCL/.git/FETCH_HEAD"
  head_before="$(_kg -C "$KCL" rev-parse HEAD)"; refs_before="$(_kg -C "$KCL" for-each-ref | cksum)"
  _krun "$KCL"
  if [[ "$KLINE" == "verify kit status=behind ref=origin/main behind=2 "* ]] && [[ "$KLINE" == *"no fetch"* ]] && [[ "$KLINE" == *"pull --ff-only"* ]]; then
    ok "K3: kit checkout 2 commits behind the known upstream → typed status=behind behind=2 with the fix command and the no-fetch caveat"
  else no "K3: expected status=behind behind=2; line=[$KLINE]"; fi
  [ "$VRC" = 0 ] && ok "K4: behind is advisory — --verify exit code is unchanged (0 with every harness absent)" || no "K4: behind changed the exit code (rc=$VRC)"
  if [ "$head_before" = "$(_kg -C "$KCL" rev-parse HEAD)" ] && [ "$refs_before" = "$(_kg -C "$KCL" for-each-ref | cksum)" ] \
     && [ -z "$(_kg -C "$KCL" status --porcelain)" ] && [ ! -e "$KCL/.git/FETCH_HEAD" ]; then ok "K5: --verify left the kit checkout untouched (HEAD, refs, worktree, no FETCH_HEAD)"
  else no "K5: --verify modified the kit checkout"; fi
  [ "$(grep -c '^verify kit ' <<<"$VOUT")" = 1 ] && ok "K6: exactly one kit line is printed" || no "K6: kit line count != 1 :: $VOUT"
  # No @{upstream} but a remote-tracking origin/main exists → falls back to origin/main.
  _kg -C "$KCL2" fetch -q >/dev/null 2>&1; _kg -C "$KCL2" branch --unset-upstream >/dev/null 2>&1
  _krun "$KCL2"
  [[ "$KLINE" == *"status=behind ref=origin/main behind=2"* ]] && ok "K7: no @{upstream} → falls back to origin/main" || no "K7: fallback to origin/main failed; line=[$KLINE]"
  # Not a git checkout → typed degraded, never a silent pass.
  mkdir -p "$TMP/kv-plain"; _krun "$TMP/kv-plain"
  [[ "$KLINE" == "verify kit status=degraded reason=kit dir is not a git checkout"* ]] && ok "K8: non-git kit dir → typed degraded (not a silent pass)" || no "K8: expected degraded not-a-checkout; line=[$KLINE]"
  # A repo with no upstream ref at all → typed degraded.
  mkdir -p "$TMP/kv-noup"; _kg init -q -b main "$TMP/kv-noup" >/dev/null 2>&1; _kc "$TMP/kv-noup" solo; _krun "$TMP/kv-noup"
  [[ "$KLINE" == "verify kit status=degraded reason=no upstream ref"* ]] && ok "K9: repo without any upstream ref → typed degraded" || no "K9: expected degraded no-upstream; line=[$KLINE]"
  # git not on PATH → typed degraded naming git.
  mkdir -p "$TMP/kv-nogit"; _nosha_path "$TMP/kv-nogit"; rm -f "$TMP/kv-nogit/git"
  _krun "$KCL" "$TMP/kv-nogit"
  [[ "$KLINE" == "verify kit status=degraded reason=git not found"* ]] && ok "K10: git absent → typed degraded naming git" || no "K10: expected degraded git-not-found; line=[$KLINE]"
  # --help documents the kit line.
  grep -q 'verify kit status=behind' <<<"$(bash "$SUT" --help 2>&1)" && ok "K11: --help documents the kit staleness line" || no "K11: --help lacks the kit line"
  # K12 — a kit dir nested inside an UNRELATED enclosing repo must not report that repo's status.
  mkdir -p "$KCL/a/b/research-sdd"; _krun "$KCL/a/b/research-sdd"
  [[ "$KLINE" == "verify kit status=degraded reason=not the kit checkout root"* ]] && ok "K12: kit dir nested in an unrelated enclosing repo → degraded 'not the kit checkout root' (not that repo's status)" \
    || no "K12: nested kit dir took the enclosing repo's status; line=[$KLINE]"
  # K13 — the standard layout (<repo>/research-sdd) is accepted.
  mkdir -p "$KCL/research-sdd"; _krun "$KCL/research-sdd"
  [[ "$KLINE" == *"status=behind"* ]] && ok "K13: kit at <repo>/research-sdd resolves to that repo's status" || no "K13: <repo>/research-sdd layout rejected; line=[$KLINE]"
  # K14 — production default: RESEARCH_SDD_KIT_DIR UNSET, the installer run from inside a real checkout fixture
  # (<repo>/research-sdd/install/…), so $KIT is what resolves the kit dir.
  KUP2="$TMP/kv-up2"; KDF="$TMP/kv-default"
  mkdir -p "$KUP2/research-sdd"; cp -R "$KITROOT/install" "$KUP2/research-sdd/install"; _kg init -q -b main "$KUP2" >/dev/null 2>&1
  _kg -C "$KUP2" add -A >/dev/null 2>&1; _kg -C "$KUP2" commit -q -m base >/dev/null 2>&1
  _kg clone -q "$KUP2" "$KDF" >/dev/null 2>&1; _kc "$KUP2" tip; _kg -C "$KDF" fetch -q >/dev/null 2>&1
  _kdef() { VOUT="$(env -u RESEARCH_SDD_KIT_DIR "$(command -v bash)" "$KDF/research-sdd/install/research-sdd-install.sh" --verify --home "$TMP/kv-home" --harness claude 2>&1)"; VRC=$?
            KLINE="$(awk 'index($0,"verify kit ")==1' <<<"$VOUT")"; }
  _kdef
  [[ "$KLINE" == "verify kit status=behind ref=origin/main behind=1 "* ]] && [ "$VRC" = 0 ] && ok "K14: production default (no RESEARCH_SDD_KIT_DIR) resolves \$KIT to the real checkout and reports behind=1" \
    || no "K14: default \$KIT resolution failed; rc=$VRC line=[$KLINE] out=[$VOUT]"
  # K15 — local commits AHEAD as well as behind: a fast-forward is impossible, so no ff-only hint.
  _kc "$KCL2" localwork; _krun "$KCL2"
  if [[ "$KLINE" == "verify kit status=behind ref=origin/main behind=2 ahead=1 "* ]] && [[ "$KLINE" == *diverged* ]] && [[ "$KLINE" != *"pull --ff-only"* ]]; then
    ok "K15: checkout both ahead and behind → status=behind with ahead=1, 'diverged', and NO ff-only fix hint"
  else no "K15: diverged checkout mislabelled; line=[$KLINE]"; fi
else
  no "K0: git or fixture clone unavailable — kit staleness tests could not run (typed, not skipped)"
fi

if [ "${1:-}" = "--prove-teeth" ] && [ -d "$KCL/.git" ]; then
  echo "-- teeth: kit staleness line mutants (lib/mutant.sh) --"
  KCL4="$TMP/kv-clone4"; _kg clone -q "$KUP" "$KCL4" >/dev/null 2>&1; _kc "$KUP" four   # KCL4 is current; upstream then gains a commit KCL4 has NOT fetched
  _vmk "teeth: K-T1 behind never reported" "$SUT" "$MKI/k-t1.sh" 's/if \[ "\$n" -gt 0 \]; then/if false; then/' \
    && _vtt "teeth: behind branch disabled → a stale kit checkout reads as current" 0 0 "$MKI/k-t1.sh" --good-has 'verify kit status=behind' --bad-has 'verify kit status=current' --bad-lacks "$_CRASH" -- "$_ENV" "RESEARCH_SDD_KIT_DIR=$KCL" "$_BASH" @SUT@ --verify --home "$TMP/kv-home" --harness claude
  _vmk "teeth: K-T2 git probe removed" "$SUT" "$MKI/k-t2.sh" 's/if ! command -v git >\/dev\/null 2>&1; then/if false; then/' \
    && _vtt "teeth: git probe removed → absent git is mislabelled (reason no longer names git)" 2 2 "$MKI/k-t2.sh" --good-has 'reason=git not found' --bad-lacks "$_CRASH|reason=git not found" -- "$_ENV" "PATH=$TMP/kv-nogit" "RESEARCH_SDD_KIT_DIR=$KCL" "$_BASH" @SUT@ --verify --home "$TMP/kv-home" --harness claude
  _vmk "teeth: K-T3 no-upstream silent pass" "$SUT" "$MKI/k-t3.sh" "s/printf 'verify kit status=degraded reason=no upstream ref.*\$/ref=HEAD/" \
    && _vtt "teeth: no-upstream degraded replaced by a fallback ref → silent confident 'current'" 0 0 "$MKI/k-t3.sh" --good-has 'reason=no upstream ref' --bad-has 'verify kit status=current' --bad-lacks "$_CRASH" -- "$_ENV" "RESEARCH_SDD_KIT_DIR=$TMP/kv-noup" "$_BASH" @SUT@ --verify --home "$TMP/kv-home" --harness claude
  _vmk "teeth: K-T4 implicit fetch" "$SUT" "$MKI/k-t4.sh" 's|if ref="\$(git -C "\$dir" rev-parse --abbrev-ref|git -C "$dir" fetch -q 2>/dev/null; if ref="$(git -C "$dir" rev-parse --abbrev-ref|' \
    && _vtt "teeth: an implicit fetch sneaks in → the unfetched upstream commit becomes visible (network side effect)" 0 0 "$MKI/k-t4.sh" --good-has 'verify kit status=current' --bad-has 'verify kit status=behind' --bad-lacks "$_CRASH" -- "$_ENV" "RESEARCH_SDD_KIT_DIR=$KCL4" "$_BASH" @SUT@ --verify --home "$TMP/kv-home" --harness claude
  _vmk "teeth: K-T5 kit line not called" "$SUT" "$MKI/k-t5.sh" 's/_rsdd_verify_kit  # SENTINEL-VERIFY-KIT/:/' \
    && _vtt "teeth: kit check never called → --verify stays silent about a stale checkout" 0 0 "$MKI/k-t5.sh" --good-has 'verify kit status=' --bad-lacks "$_CRASH|verify kit status=" -- "$_ENV" "RESEARCH_SDD_KIT_DIR=$KCL" "$_BASH" @SUT@ --verify --home "$TMP/kv-home" --harness claude
fi

if [ "${1:-}" = "--prove-teeth" ] && [ -d "${KDF:-/nonexistent}/.git" ]; then
  _vmk "teeth: K-T6 kit root check removed" "$SUT" "$MKI/k-t6.sh" 's/^  if \[ -z "\$d" \] .*SENTINEL-KIT-ROOT$/  if false; then/' \
    && _vtt "teeth: root check removed → a nested kit dir reports the enclosing repo's status" 0 0 "$MKI/k-t6.sh" --good-has 'reason=not the kit checkout root' --bad-has 'status=behind' --bad-lacks "$_CRASH" -- "$_ENV" "RESEARCH_SDD_KIT_DIR=$KCL/a/b/research-sdd" "$_BASH" @SUT@ --verify --home "$TMP/kv-home" --harness claude
  _vmk "teeth: K-T8 diverged branch removed" "$SUT" "$MKI/k-t8.sh" 's/^    if \[\[ "\$ahead" .*SENTINEL-KIT-DIVERGED$/    if false; then/' \
    && _vtt "teeth: diverged branch removed → a checkout with local commits is told to ff-only pull" 0 0 "$MKI/k-t8.sh" --good-has 'ahead=1' --bad-has 'pull --ff-only' --bad-lacks "$_CRASH" -- "$_ENV" "RESEARCH_SDD_KIT_DIR=$KCL2" "$_BASH" @SUT@ --verify --home "$TMP/kv-home" --harness claude
  _vmk "teeth: K-T7 default kit dir wrong" "$SUT" "$MKI/k-t7.sh" 's/RESEARCH_SDD_KIT_DIR:-\$KIT/RESEARCH_SDD_KIT_DIR:-\/nonexistent/' \
    && _vtt "teeth: default \$KIT no longer used → the production path inspects the wrong dir" 0 0 "$MKI/k-t7.sh" --good-has 'verify kit status=behind' --bad-has 'status=degraded' --bad-lacks "$_CRASH" -- "$_BASH" -c 'cp "$1" "$2/research-sdd/install/research-sdd-install.sh"; env -u RESEARCH_SDD_KIT_DIR bash "$2/research-sdd/install/research-sdd-install.sh" --verify --home "$3" --harness claude' _ @SUT@ "$KDF" "$TMP/kv-home"
fi

# Teeth for the hermeticity check itself: the snapshot must register a NEW, a MODIFIED and a
# REMOVED file (first / middle / last positions), proven on a temp copy — never on the live tree.
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: hermeticity snapshot must see a new, a modified and a removed file (temp copy) --"
  probe="$TMP/hermetic-probe"; mkdir -p "$probe"
  printf 'a\n' > "$probe/a-first.sh"; printf 'm\n' > "$probe/m-middle.sh"; printf 'z\n' > "$probe/z-last.sh"
  snap0="$(_install_tree_snapshot "$probe")" || snap0="<failed>"
  printf 'new\n' > "$probe/n-new.MUTANT.sh"
  snap1="$(_install_tree_snapshot "$probe")" || snap1="<failed>"
  if [ "$snap0" != "<failed>" ] && [ "$snap1" != "$snap0" ]; then ok "teeth: a NEW file is registered by the hermeticity snapshot"
  else no "teeth: a NEW file went unnoticed — hermeticity check is THEATER"; fi
  printf 'longer content\n' > "$probe/m-middle.sh"
  snap2="$(_install_tree_snapshot "$probe")" || snap2="<failed>"
  if [ "$snap2" != "$snap1" ]; then ok "teeth: a MODIFIED file is registered by the hermeticity snapshot"
  else no "teeth: a MODIFIED file went unnoticed — hermeticity check is THEATER"; fi
  rm -f "$probe/z-last.sh"
  snap3="$(_install_tree_snapshot "$probe")" || snap3="<failed>"
  if [ "$snap3" != "$snap2" ]; then ok "teeth: a REMOVED file is registered by the hermeticity snapshot"
  else no "teeth: a REMOVED file went unnoticed — hermeticity check is THEATER"; fi
  if _install_tree_snapshot "$TMP/does-not-exist" >/dev/null 2>&1; then
    no "teeth: snapshot of an ABSENT root returned success — absent would read as unchanged"
  else ok "teeth: snapshot of an ABSENT root fails loudly (absent-input is not 'unchanged')"; fi
fi


# --- read-only reviewer agent definitions (kit issue #1714) -------------------------------------
# research-sdd/agents/claude/*.md are Claude Code subagent definitions the installer deploys to
# <home>/.claude/agents/ (claude harness only). Contract: every definition has frontmatter with name,
# description, tools and model; its `tools` list is a subset of the ALLOWLIST {Read, Grep, Glob} (a denylist
# would pass Bash, Task, WebFetch and mcp__* tools as "read-only"); a same-named user file
# that differs is kept with a typed WARNING; the files are bundle members, so --verify covers them.
echo "-- #1714: read-only reviewer agent definitions --"
AGENT_SRC="$KITROOT/agents/claude"
# _agents_write_grants <dir> — prints "<file>: <tool>" for every tool in a definition's frontmatter `tools`
# that is outside the allowlist {Read, Grep, Glob}, or "<file>: <problem>" for a malformed definition.
# Silent = every definition is confined to the allowlist.
# A definition with no tools line is a problem too: omitting `tools` makes a subagent inherit EVERY tool.
_agents_write_grants() {
  local d="$1" f n=0 tools front t name
  for f in "$d"/*.md; do
    [ -f "$f" ] || continue
    n=$((n+1))
    front="$(awk 'NR==1 { if ($0!="---") exit; next } $0=="---" { exit } { print }' "$f")"
    tools="$(printf '%s\n' "$front" | awk -F: '$1=="tools" { sub(/^[^:]*:[ \t]*/, ""); print; f=1 } END { exit !f }')" \
      || { printf '%s: no tools line (would inherit every tool)\n' "$(basename "$f")"; continue; }
    name="$(printf '%s\n' "$front" | awk -F': *' '$1=="name" { print $2 }')"
    [ "$name" = "$(basename "$f" .md)" ] || printf '%s: name %s does not match the file name\n' "$(basename "$f")" "${name:-<none>}"
    grep -q '^description: .' <<<"$front" || printf '%s: no description\n' "$(basename "$f")"
    grep -q '^model: .' <<<"$front" || printf '%s: no model\n' "$(basename "$f")"
    for t in $(printf '%s' "$tools" | tr ',[]' '   '); do
      case "$t" in Read|Grep|Glob) ;; *) printf '%s: %s\n' "$(basename "$f")" "$t" ;; esac
    done
  done
  [ "$n" -gt 0 ] || printf '%s: no agent definitions found\n' "$d"
}
grants="$(_agents_write_grants "$AGENT_SRC")"
if [ -z "$grants" ]; then ok "agents: every shipped definition is confined to the {Read, Grep, Glob} allowlist, named after its file, with description and model"
else no "agents: shipped definitions are not read-only/well-formed: $(printf '%s' "$grants" | tr '\n' ';')"; fi
n_src="$(find "$AGENT_SRC" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l)"

home="$TMP/agents-apply"
bash "$SUT" --home "$home" --harness claude >/dev/null 2>&1; rc_a=$?
missing_a=""
for f in "$AGENT_SRC"/*.md; do
  [ -f "$f" ] || continue
  cmp -s "$f" "$home/.claude/agents/$(basename "$f")" || missing_a="$missing_a $(basename "$f")"
done
if [ "$rc_a" = 0 ] && [ "$n_src" -gt 0 ] && [ -z "$missing_a" ]; then ok "agents: apply deploys all $n_src definitions byte-identical into <home>/.claude/agents/"
else no "agents: apply did not deploy every definition (rc=$rc_a, src=$n_src, missing:$missing_a)"; fi

before_a="$(cd "$home" && find . -type f -exec cksum {} + | LC_ALL=C sort)"
out_a2="$(bash "$SUT" --home "$home" --harness claude 2>&1)"; rc_a2=$?
after_a="$(cd "$home" && find . -type f -exec cksum {} + | LC_ALL=C sort)"
if [ "$rc_a2" = 0 ] && [ "$before_a" = "$after_a" ] && ! <<<"$out_a2" grep -qi 'warning'; then ok "agents: re-apply is idempotent (no byte change, no WARNING)"
else no "agents: re-apply changed files or warned (rc=$rc_a2): $(<<<"$out_a2" grep -i warning || true)"; fi

ver_a="$(bash "$SUT" --verify --home "$home" --harness claude 2>&1)"
if <<<"$ver_a" grep -q 'status=match' && grep -q '^file=.*  agents/research-sdd-risk\.md$' "$home/.claude/research-sdd/.installed-bundle-state"; then ok "agents: definitions are bundle members and --verify matches after install"
else no "agents: --verify/bundle record does not cover the definitions: $ver_a"; fi

printf '%s\n' '# tampered' >> "$home/.claude/agents/research-sdd-risk.md"
ver_t="$(bash "$SUT" --verify --home "$home" --harness claude 2>&1)"
if <<<"$ver_t" grep -q 'status=drift.*agents/research-sdd-risk\.md (modified)'; then ok "agents: --verify names a tampered definition as drift"
else no "agents: --verify missed a tampered definition: $ver_t"; fi

home="$TMP/agents-collide"; mkdir -p "$home/.claude/agents"
printf 'my own reviewer\n' > "$home/.claude/agents/research-sdd-risk.md"
out_c="$(bash "$SUT" --home "$home" --harness claude 2>&1)"; rc_c=$?
if [ "$(cat "$home/.claude/agents/research-sdd-risk.md")" = "my own reviewer" ] \
   && <<<"$out_c" grep -q 'WARNING.*research-sdd-risk\.md.*diverged.*kept' \
   && cmp -s "$AGENT_SRC/research-sdd-readability.md" "$home/.claude/agents/research-sdd-readability.md"; then
  ok "agents: a differing same-named user file is kept with a typed WARNING; the other definitions still deploy (rc=$rc_c)"
else no "agents: user-file collision mishandled (rc=$rc_c): $out_c"; fi

# --help text must say --force-skill reaches the agent definitions too (it overwrites user files there).
help_out="$(bash "$SUT" --help 2>&1)"
if grep -A3 -- '--force-skill when' <<<"$help_out" | grep -qi 'agent definitions'; then ok "agents: --help says --force-skill also covers the shipped agent definitions"
else no "agents: --help hides that --force-skill overwrites agent definitions"; fi

# A kit whose agent source is gone: install fails loudly, and --verify never reports match.
NA="$TMP/kit-noagents"; mkdir -p "$NA/install"
for _f in "$KITROOT/install"/*; do
  [ "$_f" = "$KITROOT/install/tests" ] && continue
  cp -R "$_f" "$NA/install/"
done
for _f in "$KITROOT"/*; do
  [ -e "$_f" ] || continue
  case "$_f" in "$KITROOT/install"|"$KITROOT/agents") continue ;; esac
  ln -s "$_f" "$NA/$(basename "$_f")"
done
home="$TMP/agents-nokit"
bash "$SUT" --home "$home" --harness claude >/dev/null 2>&1
out_na="$(bash "$NA/install/research-sdd-install.sh" --home "$TMP/agents-nokit2" --harness claude 2>&1)"; rc_na=$?
if [ "$rc_na" != 0 ] && grep -q 'no agent definitions found' <<<"$out_na"; then ok "agents: a kit without agent sources fails the install loudly (rc=$rc_na)"
else no "agents: kit without agent sources did not fail the install (rc=$rc_na): $out_na"; fi
ver_na="$(bash "$NA/install/research-sdd-install.sh" --verify --home "$home" --harness claude 2>&1)"; rc_vna=$?
if [ "$rc_vna" = 2 ] && grep -q 'harness=claude status=degraded reason=.*agent definitions' <<<"$ver_na"; then ok "agents: --verify against a kit without agent sources is degraded (exit 2), never match"
else no "agents: --verify passed or mis-typed with the agent source missing (rc=$rc_vna): $ver_na"; fi

for hh in pi gentle-shell; do
  home="$TMP/agents-$hh"
  bash "$SUT" --home "$home" --harness "$hh" >/dev/null 2>&1
  if [ ! -e "$home/.pi/agent/agents" ] && [ ! -e "$home/.gentle-shell/agent/agents" ]; then ok "agents: harness $hh deploys no agent definitions"
  else no "agents: harness $hh unexpectedly got an agents dir"; fi
done

home="$TMP/agents-dry"
out_d="$(bash "$SUT" --dry-run --home "$home" --harness claude 2>&1)"
if <<<"$out_d" grep -q 'INSTALL .*/agents/research-sdd-risk\.md (read-only agent definition)' && [ ! -e "$home/.claude" ]; then ok "agents: dry-run plans every definition and writes nothing"
else no "agents: dry-run plan lacks the agent lines or wrote files"; fi

if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: the allowlist check must go red when a definition grants anything outside Read/Grep/Glob --"
  for _g in Edit Write NotebookEdit Bash Task WebFetch mcp__engram__mem_save; do
    gd="$TMP/agents-grant-$_g"; mkdir -p "$gd"; cp "$AGENT_SRC"/*.md "$gd/"
    # plain sed: the definitions are markdown fixtures, not bash, so the bash-only mutant helper does not apply
    sed "s/^tools: .*/tools: Read, $_g, Grep/" "$AGENT_SRC/research-sdd-risk.md" > "$gd/research-sdd-risk.md" \
      || no "teeth: could not build the $_g-granting definition"
    gout="$(_agents_write_grants "$gd")"
    if grep -q "research-sdd-risk.md: $_g" <<<"$gout"; then ok "teeth: a definition granting $_g is caught by the read-only check"
    else no "teeth: a definition granting $_g passed the read-only check — it is THEATER"; fi
  done
  gd="$TMP/agents-notools"; mkdir -p "$gd"; cp "$AGENT_SRC"/*.md "$gd/"
  sed '/^tools: /d' "$AGENT_SRC/research-sdd-risk.md" > "$gd/research-sdd-risk.md" || no "teeth: could not build the tools-less definition"
  gout="$(_agents_write_grants "$gd")"
  if grep -q 'no tools line' <<<"$gout"; then ok "teeth: a definition without a tools line (inherits every tool) is caught"
  else no "teeth: a tools-less definition passed — it is THEATER"; fi

  echo "-- teeth: installer mutants must break the deploy / collision / bundle assertions --"
  M_NODEP="$MKI/research-sdd-install.MUTANT-agents-nodeploy.$$.sh"
  mutant_sed "$SUT" "$M_NODEP" 's/_rsdd_deploy_skill "\$asrc" "\$adest"/true "$asrc" "$adest"/' \
    || no "teeth: agents no-deploy mutant could not be built"
  home="$TMP/agents-m1"; bash "$M_NODEP" --home "$home" --harness claude >/dev/null 2>&1
  if [ ! -f "$home/.claude/agents/research-sdd-risk.md" ]; then ok "teeth: no-deploy mutant leaves no definition → the deploy check has teeth"
  else no "teeth: no-deploy mutant still deployed — the deploy check is THEATER"; fi

  M_CLOB="$MKI/research-sdd-install.MUTANT-agents-clobber.$$.sh"
  mutant_sed "$SUT" "$M_CLOB" 's/"\$force" "read-only agent definition"/1 "read-only agent definition"/' \
    || no "teeth: agents clobber mutant could not be built"
  home="$TMP/agents-m2"; mkdir -p "$home/.claude/agents"; printf 'my own reviewer\n' > "$home/.claude/agents/research-sdd-risk.md"
  bash "$M_CLOB" --home "$home" --harness claude >/dev/null 2>&1
  if [ "$(cat "$home/.claude/agents/research-sdd-risk.md")" != "my own reviewer" ]; then ok "teeth: always-force mutant overwrites the user's file → the collision check has teeth"
  else no "teeth: always-force mutant kept the user's file — the collision check is THEATER"; fi

  M_NOVER="$NA/install/research-sdd-install.MUTANT-agents-noverify.$$.sh"
  mutant_sed "$SUT" "$M_NOVER" 's/if ! _rsdd_agent_names "\$h" >\/dev\/null; then/if false; then/' \
    || no "teeth: agents no-verify-check mutant could not be built"
  ver_m="$(bash "$M_NOVER" --verify --home "$TMP/agents-nokit" --harness claude 2>&1)"
  if grep -q 'harness=claude status=match' <<<"$ver_m"; then ok "teeth: without the agent-source check --verify wrongly reports match → the check has teeth"
  else no "teeth: removing the agent-source check did not change the verdict — the degraded check is THEATER"; fi

  M_NOMEM="$MKI/research-sdd-install.MUTANT-agents-nomember.$$.sh"
  mutant_sed "$SUT" "$M_NOMEM" 's|printf .%s\\n. "agents/\$an"|true|' \
    || no "teeth: agents no-member mutant could not be built"
  home="$TMP/agents-m3"; bash "$M_NOMEM" --home "$home" --harness claude >/dev/null 2>&1
  if ! grep -q '^file=.*  agents/' "$home/.claude/research-sdd/.installed-bundle-state" 2>/dev/null; then ok "teeth: no-member mutant drops the definitions from the bundle record → the --verify coverage check has teeth"
  else no "teeth: no-member mutant still recorded the definitions — the bundle check is THEATER"; fi
fi

# Live-tree hermeticity (kit issue #1156): nothing under research-sdd/install changed during the run.
INSTALL_SNAP_AFTER="$(_install_tree_snapshot)" || INSTALL_SNAP_AFTER="<snapshot failed>"
if [ "$INSTALL_SNAP_AFTER" = "$INSTALL_SNAP_BEFORE" ]; then
  ok "hermetic: no path under research-sdd/install was created, modified or removed during the suite"
else
  no "hermetic: the suite changed the live install tree: $(diff <(printf '%s\n' "$INSTALL_SNAP_BEFORE") <(printf '%s\n' "$INSTALL_SNAP_AFTER") | grep '^[<>]' | cut -f1 | tr '\n' ' ')"
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
