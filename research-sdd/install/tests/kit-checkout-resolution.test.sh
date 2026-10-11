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


# _launcher_check <installer> <home> <harness> <expected-checkout> — 0 iff the installed pi / gentle-shell
# launcher carries everything #2120 requires: the exact 'Kit checkout:' line, the rule sentence (without the
# retro markers, which live in <target>/retros/ and never touch the kit), and ABSOLUTE script paths only.
# Sets LC_WHY to the first failed requirement.
_launcher_check() {
  local blk
  LC_WHY=""
  blk="$(_launcher "$2" "$3")"
  grep -qxF "Kit checkout: $4" <<<"$blk" || { LC_WHY="no exact 'Kit checkout: $4' line"; return 1; }
  grep -q 'registry/ledger edits' <<<"$blk" && grep -q 'toolbelt runs go to Kit checkout, never the profile copy' <<<"$blk" \
    || { LC_WHY="no registry/ledger-to-checkout rule sentence"; return 1; }
  ! grep -qi 'retro markers' <<<"$blk" || { LC_WHY="rule sentence names retro markers (they live in the target, not the kit)"; return 1; }
  grep -qF "\`$4/toolbelt/sweep-all.sh\`" <<<"$blk" && grep -qF "$4/toolbelt/stage-retro-issues.sh <retro> --apply" <<<"$blk" \
    && ! grep -qE '`toolbelt/' <<<"$blk" || { LC_WHY="script paths not all absolute"; return 1; }
  return 0
}

# L1..L3 — pi and gentle-shell launchers name the checkout and use absolute script paths.
for h in pi gentle-shell; do
  home="$TMP/l-$h"; mkdir -p "$home"; _inst "$SUT" "$home" "$h"
  if _launcher_check "$SUT" "$home" "$h" "$KITROOT_P"; then ok "L1 ($h): launcher carries the checkout line, the rule (no retro markers) and absolute script paths"
  else no "L1 ($h): launcher requirement failed: $LC_WHY :: $(_launcher "$home" "$h" | grep -n 'Kit\|toolbelt' | head -4 | tr '\n' '|')"; fi
  _launcher "$home" "$h" | grep -q '^Kit path: ~/.*research-sdd/profile/general$' && ok "L3 ($h): 'Kit path:' still points at the rendered profile (prompts)" \
    || no "L3 ($h): 'Kit path:' no longer the profile copy"
done

# L4 — claude: Kit path is the checkout already; no extra line (byte-identical launcher).
home="$TMP/l-claude"; mkdir -p "$home"; _inst "$SUT" "$home" claude
blk="$(_launcher "$home" claude)"
if ! grep -q 'Kit checkout:' <<<"$blk" && grep -qF "Kit path: $KITROOT_P" <<<"$blk"; then ok "L4: claude launcher has no 'Kit checkout:' line (Kit path is already the checkout)"
else no "L4: claude launcher changed :: $(grep -n 'Kit' <<<"$blk" | tr '\n' '|')"; fi

# L5 — the renderer emits the line only when the render dir differs from the checkout; tilde under home.
r_same="$(bash -c '. "$1"; rsdd_render_section pi /h /h/kit /h/kit' _ "$HERE/../adapters.sh" 2>&1)"
r_diff="$(bash -c '. "$1"; rsdd_render_section pi /h /h/rendered /h/kit' _ "$HERE/../adapters.sh" 2>&1)"
if ! grep -q 'Kit checkout:' <<<"$r_same" && grep -qxF 'Kit checkout: ~/kit' <<<"$r_diff" && grep -qF '`~/kit/toolbelt/sweep-all.sh`' <<<"$r_diff"; then
  ok "L5: renderer emits 'Kit checkout:' (tilde-relative) only when render dir != checkout"
else no "L5: renderer gating wrong :: same=[$(grep -c 'Kit checkout' <<<"$r_same")] diff=[$(grep 'Kit checkout' <<<"$r_diff")]"; fi

# V — verify names a regular file where the bundle expects a symlink to the checkout.
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

# V5 — the reconcile target is the INSTALLED checkout (readlink of a surviving render-dir symlink), not the
# kit the verify happens to run from (a worktree, a second clone). Verify with the temp-copy installer, whose
# own kit root is $MK, against a render completed by the real SUT.
home="$TMP/v5"; mkdir -p "$home"; _inst "$SUT" "$home" pi
rd5="$home/.pi/agent/research-sdd/profile/general"
rm -f "$rd5/TARGETS.md"; printf 'x\n' > "$rd5/TARGETS.md"
_vrun "$home" pi "$MKI/research-sdd-install.sh"; l="$(_vline pi)"
if [[ "$l" == *"reconcile them into $KITROOT_P/TARGETS.md by hand)"* ]] && [[ "$l" != *"$MK"* ]]; then ok "V5: verify run from a different kit still names the INSTALLED checkout"
else no "V5: reconcile target follows the running kit, not the install :: $l"; fi

# V6 — no surviving kit symlink in the render dir → the target is stated as unknown, never guessed.
home="$TMP/v6"; mkdir -p "$home"; _inst "$SUT" "$home" pi
rd6="$home/.pi/agent/research-sdd/profile/general"
find "$rd6" -mindepth 1 -maxdepth 1 -type l -exec rm -f {} +
printf 'x\n' > "$rd6/TARGETS.md"
_vrun "$home" pi; l="$(_vline pi)"
if [[ "$l" == *"TARGETS.md (extra: registry edits written into the rendered profile — reconcile target unknown"* ]]; then ok "V6: no surviving symlink → 'reconcile target unknown' (no guess)"
else no "V6: unknown target not stated :: $l"; fi

# V7 — a regular FILE named like a kit DIRECTORY (toolbelt/) gets no reconcile-into-a-file advice.
home="$TMP/v7"; mkdir -p "$home"; _inst "$SUT" "$home" pi
rd7="$home/.pi/agent/research-sdd/profile/general"
rm -f "$rd7/toolbelt"; printf 'x\n' > "$rd7/toolbelt"
_vrun "$home" pi; l="$(_vline pi)"
if [[ "$l" == *"profile/general/toolbelt (extra)"* ]] && [[ "$l" != *"toolbelt (extra:"* ]]; then ok "V7: a file shadowing the kit's toolbelt/ directory keeps the plain '(extra)' form"
else no "V7: directory-named stray got file advice :: $l"; fi

# V8 — a checkout under the home directory is displayed tilde-relative. The temp installer's kit ($MK) sits
# under $TMP, so install and verify with --home $TMP.
home="$TMP"; _inst "$MKI/research-sdd-install.sh" "$home" pi
rd8="$home/.pi/agent/research-sdd/profile/general"
rm -f "$rd8/TARGETS.md"; printf 'x\n' > "$rd8/TARGETS.md"
_vrun "$home" pi "$MKI/research-sdd-install.sh"; l="$(_vline pi)"
if [[ "$l" == *"reconcile them into ~/mkkit/TARGETS.md by hand)"* ]]; then ok "V8: a checkout under the home directory is shown as ~/..."
else no "V8: tilde display missing :: $l"; fi
rm -rf "$home/.pi"

if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth --"
  # An adapters mutant is swapped into the temp install copy (the installer sources adapters.sh by its own
  # dir), a REAL pi install runs through it, and the SAME _launcher_check as L1 must reject the result.
  _swap_check() { # <label> <sed-expr> <expected: pass|fail> [claude]
    local m="$TMP/adapters.mut.sh" bak="$TMP/adapters.orig.sh" th="$TMP/t-$RANDOM"
    cp "$MKI/adapters.sh" "$bak"
    if ! mutant_sed "$HERE/../adapters.sh" "$m" "$2"; then no "teeth: $1 mutant could not be built"; return; fi
    cp "$m" "$MKI/adapters.sh"; mkdir -p "$th"
    if [ "${4:-}" = claude ]; then
      _inst "$MKI/research-sdd-install.sh" "$th" claude
      if _launcher "$th" claude | grep -q 'Kit checkout:'; then ok "teeth: $1 → claude launcher gains the line, L4 bites"
      else no "teeth: $1 → claude launcher unchanged, L4 is THEATER"; fi
    else
      _inst "$MKI/research-sdd-install.sh" "$th" pi
      if _launcher_check "$MKI/research-sdd-install.sh" "$th" pi "$MK"; then no "teeth: $1 → install still passes L1, THEATER"
      else ok "teeth: $1 → L1 rejects the installed launcher ($LC_WHY)"; fi
    fi
    cp "$bak" "$MKI/adapters.sh"
  }
  _swap_check "T1 checkout line dropped" '/printf.*Kit checkout: /d' fail
  _swap_check "T2 relative script paths" 's|\\`\$tb/|\\`toolbelt/|g' fail
  _swap_check "T3 gating removed" 's/\[ "\$checkout" != "\$kit" \]/true/' fail claude
  _swap_check "T6 rule sentence dropped" '/Read the prompts from Kit path/d;/INSTALLED-TOOLS.md) and toolbelt runs/d' fail
  _swap_check "T7 retro markers back in the rule" 's/INSTALLED-TOOLS.md) and/INSTALLED-TOOLS.md, retro markers) and/' fail

  _swap_inst() { # <label> <sed-expr> <home> <check-fn-name>; builds a verify mutant, returns its line in $l
    local m="$MKI/research-sdd-install.MUT-$$.sh"
    mutant_sed "$SUT" "$m" "$2" || { no "teeth: $1 mutant could not be built"; return 1; }
    cp "$m" "$MKI/research-sdd-install.mut.sh"; rm -f "$m"
  }
  # T4: annotation guard always false → plain (extra) for the kit files (V1 bites).
  if _swap_inst "T4 no annotation" 's/\[ -f "\${co_root:-\$KIT}\/\$arel" \]/false/'; then
    th="$TMP/t4"; mkdir -p "$th"; _inst "$SUT" "$th" pi; rm -f "$th/.pi/agent/research-sdd/profile/general/TARGETS.md"; printf 'x\n' > "$th/.pi/agent/research-sdd/profile/general/TARGETS.md"
    _vrun "$th" pi "$MKI/research-sdd-install.mut.sh"
    [[ "$(_vline pi)" == *"TARGETS.md (extra)"* ]] && ok "teeth: T4 guard false → plain '(extra)' → V1 bites" || no "teeth: T4 still annotates — V1 THEATER"
  fi
  # T5: guard always true → a stray non-kit file is annotated (V3 bites).
  if _swap_inst "T5 annotate all" 's/\[ -f "\${co_root:-\$KIT}\/\$arel" \]/true/'; then
    th="$TMP/t5"; mkdir -p "$th"; _inst "$SUT" "$th" pi; printf 'x\n' > "$th/.pi/agent/research-sdd/profile/general/EXTRA-FILE.md"
    _vrun "$th" pi "$MKI/research-sdd-install.mut.sh"
    [[ "$(_vline pi)" == *"EXTRA-FILE.md (extra)"* ]] && no "teeth: T5 still plain for a stray file — V3 THEATER" || ok "teeth: T5 annotates a non-kit stray file → V3 bites"
  fi
  # T8: -f weakened to -e → a file shadowing the kit's toolbelt/ dir gets file advice (V7 bites).
  if _swap_inst "T8 -e instead of -f" 's/\[ -f "\${co_root:-\$KIT}\/\$arel" \]/[ -e "${co_root:-$KIT}\/$arel" ]/'; then
    th="$TMP/t8"; mkdir -p "$th"; _inst "$SUT" "$th" pi; rm -f "$th/.pi/agent/research-sdd/profile/general/toolbelt"; printf 'x\n' > "$th/.pi/agent/research-sdd/profile/general/toolbelt"
    _vrun "$th" pi "$MKI/research-sdd-install.mut.sh"
    [[ "$(_vline pi)" == *"toolbelt (extra:"* ]] && ok "teeth: T8 -e admits a directory-named stray → V7 bites" || no "teeth: T8 still plain — V7 THEATER :: $(_vline pi)"
  fi
  # T9: target taken from the RUNNING kit again (the pre-review bug) → V5 bites.
  if _swap_inst "T9 running kit" 's/^  kit_disp="\$co_root"$/  kit_disp="$KIT"; co_root="$KIT"/'; then
    th="$TMP/t9"; mkdir -p "$th"; _inst "$SUT" "$th" pi; rm -f "$th/.pi/agent/research-sdd/profile/general/TARGETS.md"; printf 'x\n' > "$th/.pi/agent/research-sdd/profile/general/TARGETS.md"
    _vrun "$th" pi "$MKI/research-sdd-install.mut.sh"
    [[ "$(_vline pi)" == *"$MK/TARGETS.md"* ]] && ok "teeth: T9 running-kit mutant names the wrong kit → V5 bites" || no "teeth: T9 still names the install — V5 THEATER :: $(_vline pi)"
  fi
  # T10: unknown target guessed from the running kit → V6 bites.
  if _swap_inst "T10 guess" 's/if \[ -n "\$kit_disp" \]; then/if true; then/'; then
    th="$TMP/t10"; mkdir -p "$th"; _inst "$SUT" "$th" pi; find "$th/.pi/agent/research-sdd/profile/general" -mindepth 1 -maxdepth 1 -type l -exec rm -f {} +
    printf 'x\n' > "$th/.pi/agent/research-sdd/profile/general/TARGETS.md"
    _vrun "$th" pi "$MKI/research-sdd-install.mut.sh"
    [[ "$(_vline pi)" == *"reconcile target unknown"* ]] && no "teeth: T10 still says unknown — V6 THEATER" || ok "teeth: T10 prints a path with no known checkout → V6 bites"
  fi
  # T11: tilde branch removed → V8 bites.
  if _swap_inst "T11 no tilde" 's/if \[ -n "\$co_root" \] \&\& \[ "\${co_root#"\$home\/"}" != "\$co_root" \]; then/if false; then/'; then
    th="$TMP"; _inst "$MKI/research-sdd-install.sh" "$th" pi; rm -f "$th/.pi/agent/research-sdd/profile/general/TARGETS.md"; printf 'x\n' > "$th/.pi/agent/research-sdd/profile/general/TARGETS.md"
    _vrun "$th" pi "$MKI/research-sdd-install.mut.sh"
    [[ "$(_vline pi)" == *"~/mkkit"* ]] && no "teeth: T11 still shows ~ — V8 THEATER" || ok "teeth: T11 no tilde branch → V8 bites"
    rm -rf "$th/.pi"
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
