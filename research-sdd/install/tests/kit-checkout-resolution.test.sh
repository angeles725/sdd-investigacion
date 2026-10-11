#!/usr/bin/env bash
# kit-checkout-resolution.test.sh — kit issue #2120: under pi / gentle-shell the launcher's
# "Kit path:" is the RENDERED profile copy, so a session wrote registry/ledger edits (TARGETS.md,
# BREAKTHROUGHS.md) into the copy and ran toolbelt scripts from a directory that is not a git checkout.
#
# Contract locked here:
#   * the pi / gentle-shell launcher names the authoritative checkout on a `Kit checkout:` line and
#     lists the manual-sweep scripts by ABSOLUTE path (bare `toolbelt/...` does not resolve from a
#     target's cwd);
#   * the claude launcher (Kit path = checkout) carries neither addition;
#   * --verify names a regular file sitting where the bundle expects a symlink to the checkout
#     (TARGETS.md, BREAKTHROUGHS.md) specifically, never moves it, and keeps the typed drift/exit contract.
#
# Usage: kit-checkout-resolution.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression · 2 setup.
set -uo pipefail
unset RESEARCH_SDD_KIT RSDD_KIT
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../research-sdd-install.sh"
KITROOT="$(cd "$HERE/../.." && pwd)"  # LINT-CD-PHYSICAL-OK: test driver locating its SUT from the kit checkout, never through a rendered/symlinked toolbelt
KITROOT_P="$(cd -P "$KITROOT" && pwd -P)"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
# shellcheck source=../../toolbelt/tests/lib/mutant.sh
. "$HERE/../../toolbelt/tests/lib/mutant.sh" || { echo "FATAL: mutant helper missing" >&2; exit 2; }
# Mutants live in a temp copy of the install dir (kit issue #1156), every other kit entry symlinked.
MK="$TMP/mkkit"; MKI="$MK/install"
mkdir -p "$MKI" || { echo "FATAL: cannot create $MKI" >&2; exit 2; }
for _f in "$KITROOT/install"/*; do
  [ "$_f" = "$KITROOT/install/tests" ] && continue
  cp -R "$_f" "$MKI/" || { echo "FATAL: cannot copy $_f" >&2; exit 2; }
done
for _f in "$KITROOT"/* "$KITROOT"/.[!.]*; do
  [ -e "$_f" ] || [ -L "$_f" ] || continue
  [ "$_f" = "$KITROOT/install" ] && continue
  ln -s "$_f" "$MK/$(basename "$_f")" || { echo "FATAL: cannot link $_f" >&2; exit 2; }
done
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

echo "== kit-checkout-resolution.test.sh =="

# _inst <installer> <home> <harness> — real install into a temp home.
_inst() { bash "$1" --home "$2" --harness "$3" >/dev/null 2>&1; }
# _launcher <home> <harness> — the marked launcher block of the installed prompt file.
_launcher() {
  local f
  case "$2" in
    claude) f="$1/.claude/CLAUDE.md" ;;
    pi) f="$1/.pi/agent/AGENTS.md" ;;
    gentle-shell) f="$1/.gentle-shell/agent/AGENTS.md" ;;
  esac
  [ -f "$f" ] && sed -n '/research-sdd:start/,/research-sdd:end/p' "$f"
}

# L1/L2 — pi and gentle-shell launchers name the checkout and use absolute script paths.
for h in pi gentle-shell; do
  home="$TMP/l-$h"; mkdir -p "$home"; _inst "$SUT" "$home" "$h"
  blk="$(_launcher "$home" "$h")"
  if grep -qxF "Kit checkout: $KITROOT_P" <<<"$blk"; then ok "L1 ($h): launcher carries 'Kit checkout: <real kit root>'"
  else no "L1 ($h): launcher lacks the exact 'Kit checkout: $KITROOT_P' line :: $(grep -n 'Kit' <<<"$blk" | tr '\n' '|')"; fi
  if grep -q 'registry/ledger edits' <<<"$blk" && grep -q 'never the profile copy' <<<"$blk"; then ok "L1 ($h): launcher states the state-goes-to-checkout rule"
  else no "L1 ($h): launcher lacks the registry/ledger-to-checkout sentence"; fi
  if grep -qF "\`$KITROOT_P/toolbelt/sweep-all.sh\`" <<<"$blk" && grep -qF "$KITROOT_P/toolbelt/stage-retro-issues.sh <retro> --apply" <<<"$blk" \
     && ! grep -qE '`toolbelt/' <<<"$blk"; then ok "L2 ($h): sweep/retro scripts are absolute paths into the checkout, no bare toolbelt/ left"
  else no "L2 ($h): script paths are not all absolute :: $(grep -n 'toolbelt/' <<<"$blk" | head -3 | tr '\n' '|')"; fi
  grep -q '^Kit path: ~/.*research-sdd/profile/general$' <<<"$blk" && ok "L3 ($h): 'Kit path:' still points at the rendered profile (prompts)" \
    || no "L3 ($h): 'Kit path:' no longer the profile copy"
done

# L4 — claude: Kit path is the checkout already; no extra line, no scripts block (byte-identical).
home="$TMP/l-claude"; mkdir -p "$home"; _inst "$SUT" "$home" claude
blk="$(_launcher "$home" claude)"
if ! grep -q 'Kit checkout:' <<<"$blk" && grep -qF "Kit path: $KITROOT_P" <<<"$blk"; then ok "L4: claude launcher has no 'Kit checkout:' line (Kit path is already the checkout)"
else no "L4: claude launcher changed :: $(grep -n 'Kit' <<<"$blk" | tr '\n' '|')"; fi

# L5 — the renderer emits the line only when the render dir differs from the checkout.
r_same="$(bash -c '. "$1"; rsdd_render_section pi /h /h/kit /h/kit' _ "$HERE/../adapters.sh" 2>&1)"
r_diff="$(bash -c '. "$1"; rsdd_render_section pi /h /h/rendered /h/kit' _ "$HERE/../adapters.sh" 2>&1)"
if ! grep -q 'Kit checkout:' <<<"$r_same" && grep -qxF 'Kit checkout: ~/kit' <<<"$r_diff" && grep -qF '`~/kit/toolbelt/sweep-all.sh`' <<<"$r_diff"; then
  ok "L5: renderer emits 'Kit checkout:' (tilde-relative) only when render dir != checkout"
else no "L5: renderer gating wrong :: same=[$(grep -c 'Kit checkout' <<<"$r_same")] diff=[$(grep 'Kit checkout' <<<"$r_diff")]"; fi

# V1..V4 — verify names a regular file where the bundle expects a symlink to the checkout.
_vrun() { VOUT="$(bash "${3:-$SUT}" --verify --home "$1" --harness "$2" 2>&1)"; VRC=$?; }
_vline() { awk -v p="verify harness=$1 " 'index($0,p)==1' <<<"$VOUT"; }
for h in pi gentle-shell; do
  rd=".$h/agent/research-sdd/profile/general"
  home="$TMP/v-$h"; mkdir -p "$home"; _inst "$SUT" "$home" "$h"
  _vrun "$home" "$h"
  if [ "$VRC" = 0 ] && [[ "$(_vline "$h")" == *"status=match"* ]]; then ok "V0 ($h): clean install verifies as match"
  else no "V0 ($h): clean install not a match (rc=$VRC) :: $(_vline "$h")"; fi
  rm -f "$home/$rd/TARGETS.md"; printf 'row from a session\n' > "$home/$rd/TARGETS.md"
  rm -f "$home/$rd/BREAKTHROUGHS.md"; printf 'ledger from a write tool\n' > "$home/$rd/BREAKTHROUGHS.md"
  printf 'x\n' > "$home/$rd/EXTRA-FILE.md"
  _vrun "$home" "$h"; l="$(_vline "$h")"
  if [ "$VRC" = 1 ] && [[ "$l" == *"status=drift"* ]] \
     && [[ "$l" == *"research-sdd/profile/general/TARGETS.md (extra: registry edits written into the rendered profile"* ]] \
     && [[ "$l" == *"reconcile them into $KITROOT_P/TARGETS.md by hand)"* ]]; then ok "V1 ($h): regular-file TARGETS.md is named specifically with the checkout target, exit 1"
  else no "V1 ($h): TARGETS.md not reported specifically (rc=$VRC) :: $l"; fi
  if [[ "$l" == *"research-sdd/profile/general/BREAKTHROUGHS.md (extra: "* ]] && [[ "$l" == *"$KITROOT_P/BREAKTHROUGHS.md by hand)"* ]]; then
    ok "V2 ($h): a symlink replaced by a regular BREAKTHROUGHS.md is named specifically"
  else no "V2 ($h): BREAKTHROUGHS.md not reported specifically :: $l"; fi
  if [[ "$l" == *"research-sdd/profile/general/EXTRA-FILE.md (extra)"* ]]; then ok "V3 ($h): an unrelated stray file keeps the plain '(extra)' form"
  else no "V3 ($h): stray file annotation wrong :: $l"; fi
  if [ -f "$home/$rd/TARGETS.md" ] && [ ! -L "$home/$rd/TARGETS.md" ] && [ "$(cat "$home/$rd/TARGETS.md")" = "row from a session" ]; then
    ok "V4 ($h): --verify never moved or rewrote the stray TARGETS.md"
  else no "V4 ($h): TARGETS.md was touched by --verify"; fi
done

if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth --"
  # T1: launcher without the Kit checkout line.
  M1="$MKI/adapters.MUTANT-nocheckout.$$.sh"
  if mutant_sed "$HERE/../adapters.sh" "$M1" '/printf.*Kit checkout: /d'; then
    out="$(bash -c '. "$1"; rsdd_render_section pi /h /h/rendered /h/kit' _ "$M1" 2>&1)"
    grep -q 'Kit checkout:' <<<"$out" && no "teeth: checkout-line-less mutant still renders it — L1/L5 THEATER" \
      || ok "teeth: dropping the printf removes 'Kit checkout:' → L1/L5 bite"
  else no "teeth: T1 mutant could not be built"; fi
  # T2: scripts keep the bare relative path.
  M2="$MKI/adapters.MUTANT-relpaths.$$.sh"
  if mutant_sed "$HERE/../adapters.sh" "$M2" 's|\\`\$tb/|\\`toolbelt/|g'; then
    out="$(bash -c '. "$1"; rsdd_render_section pi /h /h/rendered /h/kit' _ "$M2" 2>&1)"
    grep -qF '`toolbelt/sweep-all.sh`' <<<"$out" && ok "teeth: relative-path mutant renders bare toolbelt/ → L2 bites" \
      || no "teeth: relative-path mutant still renders absolute paths — L2 THEATER"
  else no "teeth: T2 mutant could not be built"; fi
  # T3: gating removed — claude-shaped call (render == checkout) must not emit the line.
  M3="$MKI/adapters.MUTANT-ungated.$$.sh"
  if mutant_sed "$HERE/../adapters.sh" "$M3" 's/\[ "\$checkout" != "\$kit" \]/true/'; then
    out="$(bash -c '. "$1"; rsdd_render_section pi /h /h/kit /h/kit' _ "$M3" 2>&1)"
    grep -q 'Kit checkout:' <<<"$out" && ok "teeth: ungated mutant emits the line for render==checkout → L5 bites" \
      || no "teeth: ungated mutant still silent — L5 THEATER"
  else no "teeth: T3 mutant could not be built"; fi
  # T4: verify without the annotation.
  M4="$MKI/research-sdd-install.MUTANT-noannot.$$.sh"
  if mutant_chain "teeth: T4" "$SUT" "$M4" 's/\[ -e "\$KIT\/\$arel" \]/false/'; then
    home="$TMP/t4"; mkdir -p "$home"; _inst "$M4" "$home" pi
    rm -f "$home/.pi/agent/research-sdd/profile/general/TARGETS.md"; printf 'r\n' > "$home/.pi/agent/research-sdd/profile/general/TARGETS.md"
    _vrun "$home" pi "$M4"
    [[ "$(_vline pi)" == *"TARGETS.md (extra)"* ]] && ok "teeth: annotation-less mutant reports plain '(extra)' → V1 bites" \
      || no "teeth: annotation-less mutant still annotates — V1 THEATER :: $(_vline pi)"
  else no "teeth: T4 mutant could not be built"; fi
  # T5: annotation applied to every extra file (no kit-entry check) → V3 bites.
  M5="$MKI/research-sdd-install.MUTANT-annotall.$$.sh"
  if mutant_chain "teeth: T5" "$SUT" "$M5" 's/\[ -e "\$KIT\/\$arel" \]/true/'; then
    home="$TMP/t5"; mkdir -p "$home"; _inst "$M5" "$home" pi
    printf 'x\n' > "$home/.pi/agent/research-sdd/profile/general/EXTRA-FILE.md"
    _vrun "$home" pi "$M5"
    [[ "$(_vline pi)" == *"EXTRA-FILE.md (extra)"* ]] && no "teeth: unguarded mutant still plain for a stray file — V3 THEATER" \
      || ok "teeth: unguarded mutant annotates a stray non-kit file → V3 bites"
  else no "teeth: T5 mutant could not be built"; fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
