#!/usr/bin/env bash
# block-plan.test.sh — structural check of the ephemeral block-plan doctrine and template (kit issue #1178).
#
# Pins: (a) templates/block-plan.template.md exists with its required sections and sub-step items, each
# carrying an `Artifact:` line; (b) METHODOLOGY §20 names the plan, its deletion at commit, the
# no-collision rule and the "no checker yet" statement, anchored on a sentinel (not a line number);
# (c) PROMPT-LOOP names the plan at block open, at the commit step and in RESUME; (d) templates/README.md
# lists the template. Validates the doctrine and TEMPLATE only, not plans copied from it.
#
# Test seams: BLOCK_PLAN_TEMPLATE, BLOCK_PLAN_METHODOLOGY, BLOCK_PLAN_LOOP, BLOCK_PLAN_README,
# BLOCK_PLAN_MUTANT_LIB override the paths.
#
# Usage: block-plan.test.sh [--prove-teeth]
# Exit: 0 all held · 1 regression · 2 harness error (input absent, mktemp failed, mutant lib unusable).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
KIT="$(cd "$HERE/../.." && pwd)"  # LINT-CD-PHYSICAL-OK: test driver locating its SUT in the kit checkout
TPL="${BLOCK_PLAN_TEMPLATE:-$KIT/templates/block-plan.template.md}"
METH="${BLOCK_PLAN_METHODOLOGY:-$KIT/METHODOLOGY.md}"
LOOP="${BLOCK_PLAN_LOOP:-$KIT/PROMPT-LOOP.md}"
README="${BLOCK_PLAN_README:-$KIT/templates/README.md}"
MUTLIB="${BLOCK_PLAN_MUTANT_LIB:-$HERE/lib/mutant.sh}"
TMP="$(mktemp -d)" || { echo "FATAL: mktemp -d failed" >&2; exit 2; }
[ -n "$TMP" ] && [ -d "$TMP" ] || { echo "FATAL: mktemp -d returned no directory" >&2; exit 2; }
trap 'rm -rf "$TMP"' EXIT
for f in "$TPL" "$METH" "$LOOP" "$README"; do
  [ -f "$f" ] || { echo "FATAL: input not found: $f" >&2; exit 2; }  # ABSENT-INPUT
done
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
echo "== block-plan.test.sh =="

# --- predicates (each takes the file to inspect, so teeth can aim them at a mutant copy) ---
tpl_sections()  { grep -q '^## Rules' "$1" && grep -q '^## Sub-steps' "$1"; }
tpl_items() {  # >=5 sub-step items, every one followed by an Artifact: line before the next item/heading
  awk '
    function close_item() { if (inx && !a) m++ }
    /^- \[[ xX]\] S[0-9]+/ { close_item(); inx=1; n++; a=0; next }
    /^#/ { close_item(); inx=0; next }
    inx && /^[[:space:]]+Artifact:/ { a=1 }
    END { close_item(); exit (n >= 5 && m == 0) ? 0 : 1 }
  ' "$1"
}
tpl_header()    { grep -qi 'no checker' "$1" && grep -q 'RESEARCH-STATE.md' "$1"; }
# paragraph = the line carrying the sentinel (and following lines up to a blank line)
#   ...or up to the next list item (a bullet or "N. " line), so list-embedded paragraphs stay bounded.
para() { awk -v s="$2" 'index($0,s){p=1; print; next} p&&(/^[[:space:]]*$/||/^[[:space:]]*(-|[0-9]+\.) /){exit} p{print}' "$1"; }
meth_ok() {  # METHODOLOGY §20 (non-HOT-CORE) paragraph: path, commit deletion, no-collision, ODD, return-token, no checker
  local p; p="$(para "$1" 'Block plan (resume inside ONE long block).**')"; [ -n "$p" ] || return 1
  grep -q '\.research-sdd/plan/current-plan\.txt' <<<"$p" &&
  grep -qi 'deleted at the block.s commit' <<<"$p" &&
  grep -qi 'never committed' <<<"$p" &&
  grep -qi 'NO-COLLISION' <<<"$p" &&
  grep -q 'RESEARCH-STATE.md' <<<"$p" &&
  grep -q 'odd/tasks' <<<"$p" &&
  grep -qi 'return-token' <<<"$p" &&
  grep -qi 'no checker' <<<"$p" &&
  grep -qi 'BEFORE staging' <<<"$p" &&
  grep -qi 'stale' <<<"$p" &&
  grep -q 'opened-at' <<<"$p" && grep -q '\.\.HEAD' <<<"$p" &&
  grep -q 'gitignore' <<<"$p"
}
# delete-before-stage order in the template: S6 deletes first, no commit-then-delete wording anywhere
tpl_order() {
  grep -qi 'BEFORE staging' "$1" &&
  grep -q 'Delete this plan, then stage and commit' "$1" &&
  ! grep -qi 'commit, then delete' "$1" &&
  grep -qi 'stale plan' "$1" &&
  grep -q 'opened-at' "$1" && grep -q '\.\.HEAD' "$1" &&
  grep -q 'gitignore' "$1"
}
# the template Rules repeat the no-collision rule, ODD exclusion, return-token gate, no checker
tpl_rules() {
  local r; r="$(awk '/^## Rules/{p=1;next} /^## /{p=0} p' "$1")"; [ -n "$r" ] || return 1
  grep -q 'odd/tasks' <<<"$r" &&
  grep -qi 'return-token' <<<"$r" &&
  grep -qi 'no checker' <<<"$r" &&
  grep -qi 'NO-COLLISION' <<<"$r"
}
loop_ok() { # each loop anchor paragraph names the plan; the close one says delete
  local s p
  for s in "BLOCK PLAN OPEN" "BLOCK PLAN CLOSE" "BLOCK PLAN RESUME"; do
    p="$(para "$1" "$s")"; [ -n "$p" ] || return 1
    grep -q 'current-plan\.txt' <<<"$p" || return 1
  done
  p="$(para "$1" "BLOCK PLAN CLOSE")"
  grep -qi 'delete' <<<"$p" && grep -qi 'BEFORE staging' <<<"$p" &&
  p="$(para "$1" "BLOCK PLAN RESUME")"
  grep -q 'STALE' <<<"$p" && grep -q 'opened-at' <<<"$p" && grep -q '\.\.HEAD' <<<"$p" &&
  p="$(para "$1" "BLOCK PLAN CLOSE")" && grep -q 'S5' <<<"$p" && grep -q 'S6' <<<"$p"
}
readme_ok() { grep -q 'block-plan.template.md' "$1"; }

if tpl_sections "$TPL"; then ok "template has Rules and Sub-steps sections"; else no "template lacks Rules/Sub-steps sections"; fi
if tpl_items "$TPL"; then ok "template has >=5 sub-step items, each with an Artifact: line"; else no "template sub-step items incomplete"; fi
if tpl_header "$TPL"; then ok "template header states no checker yet and names RESEARCH-STATE.md"; else no "template header incomplete"; fi
if meth_ok "$METH"; then ok "METHODOLOGY §20 names the plan, commit deletion, no-collision rule, no checker"; else no "METHODOLOGY §20 block-plan paragraph incomplete or absent"; fi
if tpl_order "$TPL"; then ok "template says delete-before-stage and a stale-plan rule"; else no "template delete-before-stage/stale wording incomplete"; fi
if tpl_rules "$TPL"; then ok "template Rules carry NO-COLLISION, ODD exclusion, return-token gate, no checker"; else no "template Rules incomplete"; fi
if loop_ok "$LOOP"; then ok "PROMPT-LOOP names the plan at open, commit (delete) and RESUME"; else no "PROMPT-LOOP block-plan text incomplete or absent"; fi
if readme_ok "$README"; then ok "templates/README.md lists the template"; else no "templates/README.md must list the template"; fi

# --- teeth: each mutant is a COPY with one load-bearing piece broken; the predicate must go red ---
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "== mutation controls =="
  [ -f "$MUTLIB" ] || { echo "FATAL: mutant lib not found: $MUTLIB" >&2; exit 2; }
  # shellcheck source=lib/mutant.sh
  . "$MUTLIB" || { echo "FATAL: mutant lib failed to source" >&2; exit 2; }
  type mutant_sed >/dev/null 2>&1 || { echo "FATAL: mutant lib lacks mutant_sed" >&2; exit 2; }
  n=0; export MUTANT_SYNTAX=none  # markdown mutants: skip the bash -n check
  # tooth LABEL FILE PREDICATE SED_EXPR : mutate a copy; predicate must now FAIL
  tooth() {
    local label="$1" file="$2" pred="$3" expr="$4"; n=$((n+1)); local out="$TMP/mut.$n.md"
    mutant_sed "$file" "$out" -e "$expr" >/dev/null || { no "tooth $label: mutant refused (did not apply)"; return; }
    if "$pred" "$out"; then no "tooth $label: predicate stayed green on mutant"; else ok "tooth $label: red on mutant"; fi
  }
  tooth "template drops Sub-steps heading" "$TPL" tpl_sections 's/^## Sub-steps/## Steps/'
  tooth "template drops an Artifact line" "$TPL" tpl_items '/S1 — Sweep/{n;d;}'
  tooth "template drops no-checker header" "$TPL" tpl_header 's/No checker script exists yet/A checker exists/'
  tooth "doctrine drops commit deletion" "$METH" meth_ok '/Block plan (resume inside ONE long block)/,/^$/s/deleted at the block.s commit/kept/I'
  tooth "doctrine drops no-collision rule" "$METH" meth_ok '/Block plan (resume inside ONE long block)/,/^$/s/NO-COLLISION/NOTE/'
  tooth "doctrine drops plan path" "$METH" meth_ok '/Block plan (resume inside ONE long block)/,/^$/s#\.research-sdd/plan/current-plan\.txt#plan.txt#'
  tooth "doctrine drops ODD exclusion" "$METH" meth_ok '/Block plan (resume inside ONE long block)/,/^$/s#odd/tasks#other#'
  tooth "doctrine drops return-token clause" "$METH" meth_ok '/Block plan (resume inside ONE long block)/,/^$/s/return-token/gate/I'
  tooth "template Rules drop ODD exclusion" "$TPL" tpl_rules 's#odd/tasks#other#'
  tooth "template Rules drop return-token clause" "$TPL" tpl_rules 's/return-token/gate/I'
  tooth "template reverted to commit-then-delete" "$TPL" tpl_order 's/Delete this plan, then stage and commit/Commit, then delete this plan/'
  tooth "doctrine drops delete-before-stage" "$METH" meth_ok '/Block plan (resume inside ONE long block)/,/^$/s/BEFORE staging/after committing/'
  tooth "doctrine drops stale-plan rule" "$METH" meth_ok '/Block plan (resume inside ONE long block)/,/^$/s/[Ss]tale/fresh/g'
  tooth "loop close drops delete-before-stage" "$LOOP" loop_ok '/BLOCK PLAN CLOSE/,/^$/s/BEFORE staging/after staging/'
  tooth "template reverted to tracked-file staleness" "$TPL" tpl_order 's/\.\.HEAD/ (block file tracked)/'
  tooth "doctrine reverted to tracked-file staleness" "$METH" meth_ok '/Block plan (resume inside ONE long block)/,/^$/s/\.\.HEAD/ tracked/'
  tooth "doctrine drops gitignore rule" "$METH" meth_ok '/Block plan (resume inside ONE long block)/,/^$/s/gitignore/ignore/'
  tooth "loop resume reverted to tracked-file staleness" "$LOOP" loop_ok '/BLOCK PLAN RESUME/,/^$/s/\.\.HEAD/ tracked/'
  tooth "loop close drops S5/S6 numbering" "$LOOP" loop_ok '/BLOCK PLAN CLOSE/,/^$/s/S6/the last step/'
  tooth "loop resume drops stale rule" "$LOOP" loop_ok '/BLOCK PLAN RESUME/,/^$/s/STALE/NOTE/'
  tooth "loop drops commit deletion" "$LOOP" loop_ok '/BLOCK PLAN CLOSE/,/^$/s/[Dd][Ee][Ll][Ee][Tt][Ee]/keep/g'
  tooth "loop drops RESUME plan mention" "$LOOP" loop_ok '/BLOCK PLAN RESUME/,/^$/s/current-plan\.txt/x.txt/g'
  tooth "README drops template row" "$README" readme_ok 's/block-plan\.template\.md/x.md/g'
fi

printf '== %s passed · %s failed ==\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
