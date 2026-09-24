#!/usr/bin/env bash
# profile-invariants.test.sh — drift guard: a per-model-family prompt profile
# (kit issue #993 WU1: render-profile.sh + research-sdd/profiles/*.slots.md)
# must never fork doctrine. This suite renders every profile with the REAL
# render-profile.sh and runs the SAME invariant assertions
# skill-invariants.test.sh runs on the checked-in sources against every
# rendered copy (kit issue #993 WU3, #1021).
#
# A profile is allowed to change CADENCE WORDING (how often to re-read, in
# what tense) inside a slot body. It is never allowed to change WHICH
# doctrine sections exist, what they say, or what campaign/STOP vocabulary
# means — those invariants must hold in a rendered "general" copy exactly as
# they hold in the checked-in "claude" source.
#
# Checks:
#   G1  at least one custom profile file exists under $KIT/profiles/*.slots.md
#       (anti-silent-zero: "no profiles" and "profiles dir missing/unreadable"
#       are distinguishable — a missing/unreadable dir is FATAL, not a silent
#       zero-profile pass)
#   G2  every profile file declares at least one '## slot:<id>' section
#       (anti-silent-zero on the profile file itself, ahead of trusting the
#       renderer's own guard)
#   R1  render-profile.sh exits 0 for every profile (claude + every custom
#       profile) — this IS the "every slot id in the sources has a body in
#       every profile" check: render-profile.sh's own GUARD-MISSING refuses
#       (exit 2) the instant a source marker has no matching profile slot
#       section, so a clean exit proves full coverage without re-parsing
#       anything here.
#   S*  every shared invariant assertion from lib/prompt-invariants.sh (the
#       SAME functions skill-invariants.test.sh runs on the checked-in
#       sources) run against each profile's RENDERED SKILL.md, PROMPT-LOOP.md
#       and METHODOLOGY.md.
#   T1  forbidden doctrine tokens (next-entry:, campaign-bound-reached:,
#       [CERT], and any §<digit> section token) are absent from every slot
#       BODY declared in a profile file (research-sdd/profiles/*.slots.md) —
#       a slot may reword cadence, never reference or redefine a doctrine
#       section.
#   T2  the same forbidden tokens are absent from every slot SPAN in the
#       checked-in sources (the "claude" body between <!-- slot:id --> and
#       <!-- /slot -->) — guards the source side of the same invariant, so a
#       future claude-body edit cannot introduce what T1 already forbids on
#       the profile side.
#   Z1  size budget: a non-claude profile's rendered SKILL.md + PROMPT-LOOP.md
#       total bytes must not exceed the claude render's total by more than
#       10%.
#   H1  hotcore-budget.test.sh's full tier-list/budget suite (unmodified,
#       via its RSDD_SKILL/RSDD_LOOP/RSDD_METH env overrides) passes against
#       the CLAUDE-rendered tree. Not run against a non-claude render: its
#       SKILL_HC_START / LOOP_HC_START anchors are literal substrings that
#       include the slot MARKER text itself (documented in its own header
#       comment as intentional, #993-WU1-round-2), so they exist only in a
#       byte-identical "claude" render — a non-claude render legitimately
#       strips them. H2/H3 below is what verifies the SAME invariant
#       (HOT-CORE/SITUATIONAL tier membership) in a profile-portable way.
#   H2  the full SET of §<digit> section tokens found anywhere in a rendered
#       SKILL.md is identical across every profile (proves the tier lists a
#       reader sees cannot differ per profile: T1/T2 already forbid a slot
#       body from containing a §-token, so everything OUTSIDE slot spans —
#       where every §-token actually lives — is untouched by rendering; this
#       check verifies that guarantee empirically, on the real rendered
#       bytes, rather than trusting the T1/T2 static analysis alone).
#   H3  same as H2, for PROMPT-LOOP.md.
#
# --prove-teeth mutation controls (kit CLAUDE.md §4): every mutant is built
# on a COPY of the kit tree (RSDD_KIT_DIR, the same fixture pattern
# render-profile.test.sh uses) and re-rendered through the REAL renderer —
# never a hand-edited "rendered" file, and never a re-implementation of the
# check being proven.
#
# Usage: profile-invariants.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TOOLBELT="$(cd "$HERE/.." && pwd)"
KIT="$(cd "$TOOLBELT/.." && pwd)"
RENDERER="$TOOLBELT/render-profile.sh"
SKILL="$KIT/skills/research-sdd/SKILL.md"
PROMPTLOOP="$KIT/PROMPT-LOOP.md"
METHODOLOGY="$KIT/METHODOLOGY.md"
PROFILES_DIR="$KIT/profiles"
LIB="$HERE/lib/prompt-invariants.sh"
HOTCORE_SUITE="$HERE/hotcore-budget.test.sh"

for f in "$RENDERER" "$SKILL" "$PROMPTLOOP" "$METHODOLOGY" "$LIB" "$HOTCORE_SUITE"; do
  [ -f "$f" ] || { printf 'FATAL: required file not found: %s\n' "$f" >&2; exit 2; }
done
[ -x "$RENDERER" ] || { printf 'FATAL: render-profile.sh is not executable: %s\n' "$RENDERER" >&2; exit 2; }
[ -d "$PROFILES_DIR" ] || { printf 'FATAL: profiles directory not found: %s\n' "$PROFILES_DIR" >&2; exit 2; }
command -v python3 >/dev/null || { echo "FATAL: python3 required"; exit 2; }
# shellcheck source=lib/prompt-invariants.sh
source "$LIB"

pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

PROVE_TEETH=0
[ "${1:-}" = "--prove-teeth" ] && PROVE_TEETH=1
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

echo "== profile-invariants.test.sh =="

# =============================================================================
# G1/G2 — profile discovery, anti-silent-zero.
# =============================================================================
shopt -s nullglob
profile_files=("$PROFILES_DIR"/*.slots.md)
shopt -u nullglob
if [ "${#profile_files[@]}" -gt 0 ]; then
  ok "G1: ${#profile_files[@]} custom profile file(s) found under $PROFILES_DIR"
else
  no "G1: zero custom profile files found under $PROFILES_DIR — cannot verify the drift guard (anti-silent-zero)"
fi

PROFILE_NAMES=(claude)
for f in "${profile_files[@]}"; do
  base="$(basename "$f")"
  name="${base%.slots.md}"
  headers="$(grep -c '^## slot:' "$f" || true)"
  if [ "${headers:-0}" -gt 0 ]; then
    ok "G2/$name: profile file declares $headers slot section(s)"
  else
    no "G2/$name: profile file declares ZERO '## slot:<id>' sections (anti-silent-zero)"
  fi
  PROFILE_NAMES+=("$name")
done

# =============================================================================
# R1 — render every profile with the REAL renderer, against the live kit.
# A non-zero exit is the "every source slot marker has a matching profile
# body" failure signal (render-profile.sh's own GUARD-MISSING) — never
# treated as "this profile has fewer slots, skip its checks".
# =============================================================================
declare -A OUTDIR
render_failed=0
for name in "${PROFILE_NAMES[@]}"; do
  outdir="$TMP/render-$name"
  OUTDIR["$name"]="$outdir"
  if out="$("$RENDERER" "$name" "$outdir" 2>&1)"; then
    ok "R1/$name: render-profile.sh exits 0 (every source slot marker has a body in this profile)"
  else
    no "R1/$name: render-profile.sh FAILED (rc!=0) — $out"
    render_failed=1
  fi
done
if [ "$render_failed" -eq 1 ]; then
  echo "== $pass passed · $fail failed (aborting — cannot check invariants against a failed render) =="
  exit 1
fi

# =============================================================================
# S* — shared invariants (lib/prompt-invariants.sh) against every rendered
# SKILL.md / PROMPT-LOOP.md / METHODOLOGY.md.
# =============================================================================
SKILL_CHECKS=(A1 A1_neg A2 A3 A4 A5 A6 A7 A8 A10 A11 A12a A12b A13 A14_neg A15 C14 C19)
LOOP_CHECKS=(B1 B2 B3 C4 C9 C15 C16 C17 C18 C19 E2a E2b)
METH_CHECKS=(C1 C2 C3 C5 C6 C7 C8 C10 C11 C12 C13 C19 E1a E1_no_optin)

run_shared_checks() {
  local label="$1" file="$2"; shift 2
  local name fn
  for name in "$@"; do
    fn="assert_${name}"
    if "$fn" "$file"; then
      ok "$label/$name: holds"
    else
      no "$label/$name: VIOLATED on $file"
    fi
  done
}

for name in "${PROFILE_NAMES[@]}"; do
  outdir="${OUTDIR[$name]}"
  run_shared_checks "$name/SKILL"      "$outdir/skills/research-sdd/SKILL.md" "${SKILL_CHECKS[@]}"
  run_shared_checks "$name/LOOP"       "$outdir/PROMPT-LOOP.md"               "${LOOP_CHECKS[@]}"
  run_shared_checks "$name/METHODOLOGY" "$outdir/METHODOLOGY.md"              "${METH_CHECKS[@]}"
done

# =============================================================================
# T1/T2 — forbidden doctrine tokens must never appear inside a slot body: a
# slot may reword cadence, never reference/redefine a doctrine section.
# The generic §<digit> rule subsumes the explicit 'campaign-bound-reached:'
# and '§8c' examples named in the work-unit brief; they are kept as their
# own literal checks for a more specific failure message.
# =============================================================================
FORBIDDEN_PATTERN='next-entry:|campaign-bound-reached:|\[CERT\]|§[0-9]'

# scan_profile_file FILE — prints every non-header line matching
# FORBIDDEN_PATTERN. A profile file, once past render-profile.sh's own
# free-text guard, consists ONLY of '## slot:<id>' headers, slot bodies, and
# blank lines — so filtering out header lines leaves exactly the slot
# bodies, with no separate parser needed.
scan_profile_file() {
  grep -vE '^## slot:' "$1" | grep -E "$FORBIDDEN_PATTERN"
}

# scan_source_slot_spans FILE — prints the text of every
# <!-- slot:id -->...<!-- /slot --> span (the "claude" body), one per line
# group, using the SAME marker regex render-profile.sh itself parses with,
# so this reads the doctrine exactly as the renderer does.
scan_source_slot_spans() {
  python3 - "$1" <<'PYEOF'
import re, sys
text = open(sys.argv[1], encoding='utf-8').read()
TOKEN_RE = re.compile(r'<!--\s*slot:([A-Za-z0-9_-]+)\s*-->|<!--\s*/slot\s*-->')
open_at = None
for m in TOKEN_RE.finditer(text):
    if m.group(1) is not None:
        open_at = m.end()
    elif open_at is not None:
        sys.stdout.write(text[open_at:m.start()])
        sys.stdout.write("\n")
        open_at = None
PYEOF
}

for f in "${profile_files[@]}"; do
  name="$(basename "$f" .slots.md)"
  if hits="$(scan_profile_file "$f")" && [ -z "$hits" ]; then
    ok "T1/$name: no forbidden doctrine token in any slot body of $(basename "$f")"
  elif [ -n "$hits" ]; then
    no "T1/$name: forbidden doctrine token found in a slot body of $(basename "$f") — $hits"
  else
    ok "T1/$name: no forbidden doctrine token in any slot body of $(basename "$f")"
  fi
done

for f in "$SKILL" "$PROMPTLOOP"; do
  label="$(basename "$f")"
  hits="$(scan_source_slot_spans "$f" | grep -E "$FORBIDDEN_PATTERN" || true)"
  if [ -z "$hits" ]; then
    ok "T2/$label: no forbidden doctrine token in any source slot span"
  else
    no "T2/$label: forbidden doctrine token found in a source slot span — $hits"
  fi
done

# =============================================================================
# Z1 — size budget: non-claude rendered SKILL.md+PROMPT-LOOP.md must not
# exceed the claude render's total bytes by more than 10%.
# =============================================================================
claude_skill_bytes="$(wc -c < "${OUTDIR[claude]}/skills/research-sdd/SKILL.md")"
claude_loop_bytes="$(wc -c < "${OUTDIR[claude]}/PROMPT-LOOP.md")"
claude_total=$(( claude_skill_bytes + claude_loop_bytes ))
budget=$(( claude_total * 110 / 100 ))
for name in "${PROFILE_NAMES[@]}"; do
  [ "$name" = "claude" ] && continue
  s_bytes="$(wc -c < "${OUTDIR[$name]}/skills/research-sdd/SKILL.md")"
  l_bytes="$(wc -c < "${OUTDIR[$name]}/PROMPT-LOOP.md")"
  total=$(( s_bytes + l_bytes ))
  if [ "$total" -le "$budget" ]; then
    ok "Z1/$name: rendered size $total bytes within budget (claude=$claude_total, budget=$budget, +10%)"
  else
    no "Z1/$name: rendered size $total bytes EXCEEDS budget (claude=$claude_total, budget=$budget, +10%)"
  fi
done

# =============================================================================
# H1 — hotcore-budget.test.sh's full suite (unmodified) against the
# CLAUDE-rendered tree only (see header comment for why not every profile).
# =============================================================================
if RSDD_SKILL="${OUTDIR[claude]}/skills/research-sdd/SKILL.md" \
   RSDD_LOOP="${OUTDIR[claude]}/PROMPT-LOOP.md" \
   RSDD_METH="${OUTDIR[claude]}/METHODOLOGY.md" \
   bash "$HOTCORE_SUITE" >/dev/null 2>&1; then
  ok "H1: hotcore-budget.test.sh's full tier-list/budget suite passes against the claude-rendered tree"
else
  no "H1: hotcore-budget.test.sh REGRESSED against the claude-rendered tree"
fi

# =============================================================================
# H2/H3 — the full §<digit> token SET found anywhere in a rendered file is
# identical across every profile (profile-portable equivalent of hotcore-
# budget's tier-list parity, per the H1 comment above).
# =============================================================================
token_set() { grep -oE '§[0-9]+[a-z]?' "$1" | sort -u; }

for rel in "skills/research-sdd/SKILL.md:H2" "PROMPT-LOOP.md:H3"; do
  file_rel="${rel%%:*}" check_id="${rel##*:}"
  base_tokens="$(token_set "${OUTDIR[claude]}/$file_rel")"
  if [ -z "$base_tokens" ]; then
    no "$check_id/claude: zero §-tokens found in $file_rel (anti-silent-zero — cannot verify parity)"
    continue
  fi
  for name in "${PROFILE_NAMES[@]}"; do
    [ "$name" = "claude" ] && continue
    other_tokens="$(token_set "${OUTDIR[$name]}/$file_rel")"
    if diff_out="$(diff <(printf '%s\n' "$base_tokens") <(printf '%s\n' "$other_tokens"))"; then
      ok "$check_id/$name: §-token set in $file_rel matches claude ($(printf '%s' "$base_tokens" | wc -l) token(s))"
    else
      no "$check_id/$name: §-token set in $file_rel DIFFERS from claude — $diff_out"
    fi
  done
done

# ===========================================================================
# --prove-teeth: mutants on COPIES of the profile file / sources / renderer,
# via RSDD_KIT_DIR pointing at a copied kit — every mutant is re-rendered
# through the REAL render-profile.sh, never hand-edited output. Pass/fail is
# always recorded in the PARENT shell (never inside a `$(...)` — a `no()`
# there is lost in the subshell, kit CLAUDE.md §3's render-profile.test.sh
# fix).
# ===========================================================================
if [ "$PROVE_TEETH" -eq 1 ]; then

  make_kit() {  # DIR
    local dir="$1"
    mkdir -p "$dir/skills/research-sdd" "$dir/profiles"
    cp "$SKILL" "$dir/skills/research-sdd/SKILL.md"
    cp "$PROMPTLOOP" "$dir/PROMPT-LOOP.md"
    cp "$METHODOLOGY" "$dir/METHODOLOGY.md"
    for f in "${profile_files[@]}"; do
      cp "$f" "$dir/profiles/$(basename "$f")"
    done
  }

  # require_anchor FILE OLD — fails loudly (prints to stderr, returns 1) if
  # OLD is not found in FILE, so a vanished anchor is a recorded FAIL, never
  # a silently skipped tooth.
  require_anchor() {
    local file="$1" old="$2"
    grep -qF "$old" "$file" && return 0
    printf 'MUTATION-ANCHOR-NOT-FOUND: %s in %s\n' "$old" "$file" >&2
    return 1
  }

  echo "-- teeth: T-drop-invariant-phrase (remove 'the 7 markers' from the copied kit's SKILL.md source, render claude, assert_A1 must go RED) --"
  kitDrop="$TMP/kitDrop"
  make_kit "$kitDrop"
  if require_anchor "$kitDrop/skills/research-sdd/SKILL.md" 'the 7 markers'; then
    sed -i 's/the 7 markers/the N markers/g' "$kitDrop/skills/research-sdd/SKILL.md"
    outDrop="$TMP/outDrop"
    if RSDD_KIT_DIR="$kitDrop" "$RENDERER" claude "$outDrop" >/dev/null 2>&1; then
      if assert_A1 "$outDrop/skills/research-sdd/SKILL.md"; then
        no "teeth-drop-invariant-phrase: assert_A1 still PASSES on the mutant render — no teeth"
      else
        ok "teeth-drop-invariant-phrase: assert_A1 goes RED on the mutant render (real renderer, real check)"
      fi
    else
      no "teeth-drop-invariant-phrase: mutant kit failed to render — cannot prove teeth"
    fi
  else
    no "teeth-drop-invariant-phrase: mutation anchor not found — cannot prove teeth (a vanished anchor must fail, never skip)"
  fi

  echo "-- teeth: T-doctrine-token-in-profile-body (inject a §-token into general.slots.md's slot body, T1 must go RED) --"
  kitToken="$TMP/kitToken"
  make_kit "$kitToken"
  profileCopy="$kitToken/profiles/general.slots.md"
  if [ -f "$profileCopy" ] && require_anchor "$profileCopy" 'read IN FULL every iteration'; then
    sed -i 's/read IN FULL every iteration/read IN FULL every iteration (see §8c)/' "$profileCopy"
    if hits="$(scan_profile_file "$profileCopy")" && [ -z "$hits" ]; then
      no "teeth-doctrine-token-in-profile-body: T1's scan found nothing on the mutant — no teeth"
    elif [ -n "$hits" ]; then
      ok "teeth-doctrine-token-in-profile-body: T1's scan catches the injected §8c token on the mutant — $hits"
    else
      no "teeth-doctrine-token-in-profile-body: T1's scan found nothing on the mutant — no teeth"
    fi
  else
    no "teeth-doctrine-token-in-profile-body: mutation anchor not found (no general.slots.md, or anchor moved) — cannot prove teeth"
  fi

  echo "-- teeth: T-doctrine-token-in-source-span (inject a §-token into SKILL.md's hotcore-cadence source slot body, T2 must go RED) --"
  kitSourceToken="$TMP/kitSourceToken"
  make_kit "$kitSourceToken"
  skillCopy="$kitSourceToken/skills/research-sdd/SKILL.md"
  if require_anchor "$skillCopy" '<!-- slot:hotcore-cadence -->read once per context'; then
    sed -i 's/<!-- slot:hotcore-cadence -->read once per context/<!-- slot:hotcore-cadence -->read once per context (see §8c)/' "$skillCopy"
    hits="$(scan_source_slot_spans "$skillCopy" | grep -E "$FORBIDDEN_PATTERN" || true)"
    if [ -n "$hits" ]; then
      ok "teeth-doctrine-token-in-source-span: T2's scan catches the injected §8c token on the mutant source — $hits"
    else
      no "teeth-doctrine-token-in-source-span: T2's scan found nothing on the mutant source — no teeth"
    fi
  else
    no "teeth-doctrine-token-in-source-span: mutation anchor not found — cannot prove teeth"
  fi

  echo "-- teeth: T-inflate-slot-past-budget (pad a slot body in the copied kit's general.slots.md, render claude+general, Z1 must go RED) --"
  kitInflate="$TMP/kitInflate"
  make_kit "$kitInflate"
  profileInflate="$kitInflate/profiles/general.slots.md"
  if [ -f "$profileInflate" ] && require_anchor "$profileInflate" 'read IN FULL every iteration (framing + the per-block contract)'; then
    padding="$(printf 'x%.0s' $(seq 1 20000))"
    sed -i "s/read IN FULL every iteration (framing + the per-block contract)/read IN FULL every iteration (framing + the per-block contract) ${padding}/" "$profileInflate"
    outInflateClaude="$TMP/outInflateClaude"; outInflateGeneral="$TMP/outInflateGeneral"
    if RSDD_KIT_DIR="$kitInflate" "$RENDERER" claude "$outInflateClaude" >/dev/null 2>&1 \
       && RSDD_KIT_DIR="$kitInflate" "$RENDERER" general "$outInflateGeneral" >/dev/null 2>&1; then
      cb="$(wc -c < "$outInflateClaude/skills/research-sdd/SKILL.md")"
      cl="$(wc -c < "$outInflateClaude/PROMPT-LOOP.md")"
      ctotal=$(( cb + cl ))
      cbudget=$(( ctotal * 110 / 100 ))
      gb="$(wc -c < "$outInflateGeneral/skills/research-sdd/SKILL.md")"
      gl="$(wc -c < "$outInflateGeneral/PROMPT-LOOP.md")"
      gtotal=$(( gb + gl ))
      if [ "$gtotal" -gt "$cbudget" ]; then
        ok "teeth-inflate-slot-past-budget: Z1's real budget check goes RED on the mutant (general=$gtotal > budget=$cbudget)"
      else
        no "teeth-inflate-slot-past-budget: general=$gtotal still within budget=$cbudget on the mutant — no teeth"
      fi
    else
      no "teeth-inflate-slot-past-budget: mutant kit failed to render — cannot prove teeth"
    fi
  else
    no "teeth-inflate-slot-past-budget: mutation anchor not found — cannot prove teeth"
  fi

  echo "-- teeth: T-remove-slot-body (delete a '## slot:' section from the copied kit's general.slots.md, R1 must go RED) --"
  kitRemove="$TMP/kitRemove"
  make_kit "$kitRemove"
  profileRemove="$kitRemove/profiles/general.slots.md"
  if [ -f "$profileRemove" ] && require_anchor "$profileRemove" '## slot:hotcore-loop-cadence'; then
    python3 - "$profileRemove" <<'PYEOF'
import re, sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
s = re.sub(r'## slot:hotcore-loop-cadence\n.*?(?=\n## slot:|\Z)', '', s, flags=re.DOTALL)
open(p, 'w', encoding='utf-8').write(s)
PYEOF
    outRemove="$TMP/outRemove"
    if RSDD_KIT_DIR="$kitRemove" "$RENDERER" general "$outRemove" >/dev/null 2>&1; then
      no "teeth-remove-slot-body: mutant kit STILL rendered (exit 0) with a missing slot body — no teeth"
    else
      ok "teeth-remove-slot-body: R1's real render-exit-code check goes RED on the mutant (render-profile.sh's own GUARD-MISSING fires)"
    fi
  else
    no "teeth-remove-slot-body: mutation anchor not found — cannot prove teeth"
  fi

  echo "-- teeth: T-vanished-anchor (a mutation anchor that does not exist must FAIL, not be silently skipped) --"
  kitVanished="$TMP/kitVanished"
  make_kit "$kitVanished"
  if require_anchor "$kitVanished/skills/research-sdd/SKILL.md" 'THIS-ANCHOR-DOES-NOT-EXIST-IN-ANY-KIT-SOURCE-XYZ'; then
    no "teeth-vanished-anchor: require_anchor unexpectedly SUCCEEDED on a nonexistent anchor — the guard itself is broken"
  else
    ok "teeth-vanished-anchor: require_anchor correctly reports FAILURE (rc=1) on a vanished anchor — the caller records it as FAIL, not a silent skip"
  fi

fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
