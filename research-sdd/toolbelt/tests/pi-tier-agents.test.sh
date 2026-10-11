#!/usr/bin/env bash
# pi-tier-agents.test.sh — suite for the tier-named pi / gentle-shell subagents and the model_profiles
# snippet + verify state the installer ships for them (kit issue #2124).
#
# Contract under test:
#   agents      research-sdd/agents/pi/research-sdd-{mechanical,structural,reasoning}.md: frontmatter valid per
#               gentle-shell's parser rules (name == file name, description, body required, `tools` an allowlist
#               list inside {read, grep, find}), NO model / thinking / effort key (model selection is user-owned,
#               model-tiers.v1 §3), and no collision with gentle-shell's MANAGED agent names.
#   adapters    pi + gentle-shell take agents/pi; claude keeps agents/claude.
#   installer   the agents deploy to <agent home>/agents/ as bundle members (verify, uninstall-if-unmodified,
#               hand-edit protection) through the SAME helpers as the claude reviewers; the installer PRINTS a
#               ready-to-merge model_profiles snippet and writes no subagents.json anywhere.
#   verify      informational `verify tier-profile` lines: configured | unconfigured | degraded (unreadable
#               JSON), global <agent home>/subagents.json and project <cwd>/.pi/subagents.json; they never move
#               the exit code.
#   --prove-teeth  every invariant has a mutant (agent source, adapters.sh, installer) that must turn it red.
#
# Usage: pi-tier-agents.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression · 2 setup.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
KIT="$(cd "$HERE/../.." && pwd)"
AGENTS="$KIT/agents/pi"
SUT="$KIT/install/research-sdd-install.sh"
ADAPTERS="$KIT/install/adapters.sh"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
# shellcheck source=lib/mutant.sh
. "$HERE/lib/mutant.sh" || { echo "FATAL: mutant helper missing" >&2; exit 2; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 is required (JSON checks)" >&2; exit 2; }

echo "== pi-tier-agents.test.sh =="

TIERS="research-sdd-mechanical research-sdd-structural research-sdd-reasoning"
# gentle-shell v4.0.0 lib/agent-assets.ts ASSET_OWNER_BY_KEY — agent names the launcher owns.
MANAGED="review-risk review-readability review-reliability review-resilience jd-judge-a jd-judge-b jd-fix-agent gentle-ai-explore gentle-ai-worker gentle-ai-verify"

# agent_problems DIR — one line per problem (silent = every definition valid). Mirrors gentle-shell's parser
# rules: `---` frontmatter, name / description, a non-empty body, `tools` an allowlist inside {read, grep, find}.
agent_problems() {
  local d="$1" f n=0 b name front body tools t m
  for f in "$d"/*.md; do
    [ -f "$f" ] || continue
    n=$((n+1)); b="$(basename "$f")"; name="${b%.md}"
    [ "$(head -1 "$f")" = "---" ] || { echo "$b: no frontmatter opening ---"; continue; }
    front="$(awk 'NR==1{next} $0=="---"{exit} {print}' "$f")"
    awk 'NR>1 && $0=="---"{f=1} END{exit !f}' "$f" || { echo "$b: frontmatter never closed"; continue; }
    body="$(awk 'NR==1{next} c==0&&$0=="---"{c=1;next} c==1{print}' "$f" | tr -d ' \t\n')"
    [ -n "$body" ] || echo "$b: empty body (gentle-shell requires one)"
    [ "$(awk -F': *' '$1=="name"{print $2}' <<<"$front")" = "$name" ] || echo "$b: name does not match the file name"
    grep -q '^description: .' <<<"$front" || echo "$b: no description"
    for m in model thinking effort mode; do
      ! grep -q "^$m:" <<<"$front" || echo "$b: sets '$m' (user-owned; the profile decides)"
    done
    tools="$(awk '$0 ~ /^tools:/{sub(/^tools:[ \t]*/,""); print; f=1} END{exit !f}' <<<"$front")" || { echo "$b: no tools line (would inherit every tool)"; continue; }
    [[ "$tools" == \[*\] ]] || { echo "$b: tools is not an inline [list]"; continue; }
    [ -n "$(tr -d ' \t,[]' <<<"$tools")" ] || { echo "$b: empty tools list"; continue; }
    for t in $(tr ',[]' '   ' <<<"$tools"); do
      case "$t" in read|grep|find) ;; *) echo "$b: tool '$t' outside the read-only allowlist {read, grep, find}" ;; esac
    done
    for m in $MANAGED; do [ "$name" != "$m" ] || echo "$b: collides with the gentle-shell MANAGED agent $m"; done
    case "$name" in review-*|jd-*|gentle-ai-*) echo "$b: uses a reserved managed prefix" ;; esac
  done
  [ "$n" -gt 0 ] || echo "$d: no agent definitions found"
}

echo "-- agent sources --"
have="$(find "$AGENTS" -maxdepth 1 -name '*.md' 2>/dev/null | sed 's|.*/||; s|\.md$||' | LC_ALL=C sort | tr '\n' ' ')"
want="$(printf '%s\n' $TIERS | LC_ALL=C sort | tr '\n' ' ')"
[ "$have" = "$want" ] && ok "agents/pi holds exactly the three tier agents" || no "agents/pi holds [$have], expected [$want]"
p="$(agent_problems "$AGENTS")"
[ -z "$p" ] && ok "every tier agent passes gentle-shell's frontmatter/body/tools rules, sets no model, and avoids managed names" \
  || no "tier agent problems: $(tr '\n' ';' <<<"$p")"
# Positive controls for the validator (a validator that flags nothing proves nothing).
bad="$TMP/bad"; mkdir -p "$bad"
printf -- '---\nname: bad-model\ndescription: x\nmodel: a/b\ntools: [read]\n---\nbody\n' >"$bad/bad-model.md"
printf -- '---\nname: bad-body\ndescription: x\ntools: [read]\n---\n' >"$bad/bad-body.md"
printf -- '---\nname: bad-tool\ndescription: x\ntools: [read, bash]\n---\nbody\n' >"$bad/bad-tool.md"
printf -- '---\nname: bad-notools\ndescription: x\n---\nbody\n' >"$bad/bad-notools.md"
printf -- '---\nname: review-risk\ndescription: x\ntools: [read]\n---\nbody\n' >"$bad/review-risk.md"
printf -- '---\nname: other\ndescription: x\ntools: [read]\n---\nbody\n' >"$bad/bad-name.md"
printf -- 'no frontmatter\n' >"$bad/bad-fm.md"
bp="$(agent_problems "$bad")"
miss=""
for k in "bad-model.md: sets 'model'" "bad-body.md: empty body" "bad-tool.md: tool 'bash'" "bad-notools.md: no tools line" "review-risk.md: collides" "bad-name.md: name does not match" "bad-fm.md: no frontmatter"; do
  grep -qF "$k" <<<"$bp" || miss="$miss [$k]"
done
[ -z "$miss" ] && ok "validator controls: model key, empty body, non-read-only tool, missing tools, managed name, name mismatch, no frontmatter all flagged" \
  || no "validator missed:$miss"

echo "-- adapters --"
af() { bash -c '. "$1"; rsdd_field "$2" agents_src_relkit /H' _ "${3:-$ADAPTERS}" "$1"; }
[ "$(af pi)" = "agents/pi" ] && [ "$(af gentle-shell)" = "agents/pi" ] && ok "pi and gentle-shell source agents/pi" || no "pi=[$(af pi)] gentle-shell=[$(af gentle-shell)]"
[ "$(af claude)" = "agents/claude" ] && ok "claude still sources agents/claude (unchanged)" || no "claude=[$(af claude)]"
mpf() { bash -c '. "$1"; rsdd_field "$2" model_profiles_path /H' _ "$ADAPTERS" "$1"; }
[ "$(mpf pi)" = "/H/.pi/agent/subagents.json" ] && [ "$(mpf gentle-shell)" = "/H/.gentle-shell/agent/subagents.json" ] && [ -z "$(mpf claude)" ] \
  && ok "model_profiles_path: pi/gentle-shell global subagents.json, none for claude" || no "model_profiles_path pi=[$(mpf pi)] gs=[$(mpf gentle-shell)] claude=[$(mpf claude)]"

# --- temp kit copies (install dir copied, the rest linked) -------------------------------------------------
# MK  : the live installer/adapters, copied; mutants of the installer are built here.
# MK1 : same, but adapters.sh gives pi NO agents and NO extension, so the --verify comparison set is exactly the
#       recorded members and a ONE-member bundle record is reachable (the single-element list edge, CLAUDE.md §7).
mkkit() { # DIR
  local f
  mkdir -p "$1/install" || return 1
  for f in "$KIT/install"/*; do [ "$f" = "$KIT/install/tests" ] && continue; cp -R "$f" "$1/install/" || return 1; done
  for f in "$KIT"/* "$KIT"/.[!.]*; do [ -e "$f" ] || [ -L "$f" ] || continue; [ "$f" = "$KIT/install" ] && continue; ln -s "$f" "$1/$(basename "$f")" || return 1; done
}
MK="$TMP/kit"; MK1="$TMP/kit1"
mkkit "$MK" && mkkit "$MK1" || { echo "FATAL: cannot build the temp kit copies" >&2; exit 2; }
sed -i -e 's|^  \[pi\]="agents/pi"$|  [pi]=""|' -e 's|^  \[pi\]="install/pi/research-sdd-hooks.ts"$|  [pi]=""|' "$MK1/install/adapters.sh"
[ "$(grep -c '^  \[pi\]=""$' "$MK1/install/adapters.sh")" = 2 ] || { echo "FATAL: MK1 adapters mutation did not apply twice" >&2; exit 2; }

# --- installer ---------------------------------------------------------------------------------------
rootrel() { case "$1" in pi) echo ".pi/agent" ;; gentle-shell) echo ".gentle-shell/agent" ;; esac; }
# The snippet is a clean JSON block between two marker lines (no per-line prefix).
SNIP_B='--- model_profiles snippet: begin ---'; SNIP_E='--- model_profiles snippet: end ---'
snippet_json() { awk -v b="$SNIP_B" -v e="$SNIP_E" '$0==b{f=1;next} $0==e{f=0} f'; }
count_line() { grep -cFx -- "$1"; }

for h in pi gentle-shell; do
  echo "-- installer: $h --"
  r="$(rootrel "$h")"
  home="$TMP/$h-home"; work="$TMP/$h-work"; mkdir -p "$home" "$work"
  out="$(cd "$work" && bash "$SUT" --home "$home" --harness "$h" 2>&1)"; rc=$?
  miss=""
  for t in $TIERS; do cmp -s "$AGENTS/$t.md" "$home/$r/agents/$t.md" || miss="$miss $t"; done
  [ "$rc" = 0 ] && [ -z "$miss" ] && ok "$h: install deploys the three tier agents byte-identical into <agent home>/agents/" || no "$h: install rc=$rc missing:$miss"
  st="$home/$r/research-sdd/.installed-bundle-state"
  c=0; for t in $TIERS; do grep -q "^file=.*  agents/$t\.md\$" "$st" && c=$((c+1)); done
  [ "$c" = 3 ] && ok "$h: the agents are recorded bundle members" || no "$h: only $c of 3 agents in the bundle record"
  js="$(snippet_json <<<"$out")"
  if [ -n "$js" ] && printf '%s' "$js" | python3 -I -c '
import json,sys
d=json.load(sys.stdin); mp=d["model_profiles"]
assert sorted(mp)==["research-sdd-mechanical","research-sdd-reasoning","research-sdd-structural"], sorted(mp)
for k,v in mp.items():
    assert isinstance(v["model"],str) and v["model"].startswith("<"), k
' 2>"$TMP/pyerr"; then ok "$h: install prints a pasteable model_profiles JSON block for the three agents with placeholder models"
  else no "$h: snippet missing/invalid ($(tail -1 "$TMP/pyerr" 2>/dev/null)) :: $(head -c 300 <<<"$js")"; fi
  { [ "$(count_line "$SNIP_B" <<<"$out")" = 1 ] && [ "$(count_line "$SNIP_E" <<<"$out")" = 1 ] && ! grep -q 'profiles|' <<<"$out"; } \
    && ok "$h: the block sits between exactly one begin and one end marker line, with no per-line prefix" || no "$h: marker lines/prefix wrong"
  grep -q '\.pi/subagents\.json' <<<"$out" && grep -q 'already has a model_profiles object' <<<"$out" \
    && ok "$h: output points at the project .pi/subagents.json and says to merge into an existing model_profiles object" || no "$h: pointer/merge note missing"
  found="$(find "$home" "$work" -name 'subagents.json' 2>/dev/null)"
  [ -z "$found" ] && ok "$h: the snippet is printed, never written (no subagents.json under the home or the cwd)" || no "$h: a subagents.json was written: $found"
  dout="$(cd "$work" && bash "$SUT" --home "$TMP/$h-dry" --harness "$h" --dry-run 2>&1)"
  { [ -n "$(snippet_json <<<"$dout")" ] && [ -z "$(find "$TMP/$h-dry" -type f 2>/dev/null)" ]; } \
    && ok "$h: --dry-run prints the snippet and writes nothing" || no "$h: dry-run snippet/purity failed"

  vout="$(cd "$work" && bash "$SUT" --verify --home "$home" --harness "$h" 2>&1)"; vrc=$?
  grep -q "^verify harness=$h status=match" <<<"$vout" && [ "$vrc" = 0 ] && ok "$h: --verify matches after install, exit 0" || no "$h: verify rc=$vrc :: $vout"
  printf '# tampered\n' >> "$home/$r/agents/research-sdd-structural.md"
  vt="$(cd "$work" && bash "$SUT" --verify --home "$home" --harness "$h" 2>&1)"; vtrc=$?
  { [ "$vtrc" = 1 ] && grep -q 'status=drift.*agents/research-sdd-structural\.md (modified)' <<<"$vt"; } && ok "$h: --verify names a tampered tier agent as drift" || no "$h: tamper not named (rc=$vtrc) :: $vt"
  # re-install: a hand-edited agent is kept with a typed WARNING (the other two still deploy / stay)
  wout="$(cd "$work" && bash "$SUT" --home "$home" --harness "$h" 2>&1)"
  { grep -q 'WARNING.*research-sdd-structural\.md.*diverged.*kept' <<<"$wout" && grep -q '^# tampered$' <<<"$(tail -1 "$home/$r/agents/research-sdd-structural.md")"; } \
    && ok "$h: a hand-edited tier agent is kept with a typed WARNING on re-install" || no "$h: hand-edit not protected :: $(grep -i warn <<<"$wout" | head -2)"
  # uninstall: unmodified agents go, the hand-edited one is kept
  uout="$(cd "$work" && bash "$SUT" --uninstall --yes --home "$home" --harness "$h" 2>&1)"
  gone=0; for t in research-sdd-mechanical research-sdd-reasoning; do [ ! -e "$home/$r/agents/$t.md" ] && gone=$((gone+1)); done
  { [ "$gone" = 2 ] && [ -e "$home/$r/agents/research-sdd-structural.md" ]; } && ok "$h: uninstall removes unmodified tier agents and keeps the hand-edited one" || no "$h: uninstall gone=$gone :: $uout"
done

echo "-- verify: tier-profile states --"
h=pi; r=".pi/agent"
vh="$TMP/vp-home"; vw="$TMP/vp-work"; mkdir -p "$vh" "$vw"
bash "$SUT" --home "$vh" --harness "$h" >/dev/null 2>&1
tp() { # WORKDIR -> sets VOUT VRC
  VOUT="$(cd "$1" && bash "$SUT" --verify --home "$vh" --harness "$h" 2>&1)"; VRC=$?; }
tl() { grep -F "verify tier-profile harness=$h agent=$1 " <<<"$VOUT"; }
tlq() { grep -q -- "$2" <<<"$(tl "$1")"; }
GJ="$vh/$r/subagents.json"; PJ="$vw/.pi/subagents.json"
tp "$vw"
c=0; for t in $TIERS; do tlq "$t" 'status=unconfigured' && c=$((c+1)); done
{ [ "$c" = 3 ] && [ "$VRC" = 0 ]; } && ok "verify: no subagents.json anywhere -> 3 x unconfigured, exit still 0 (informational)" || no "verify unconfigured c=$c rc=$VRC :: $VOUT"
[ "$(grep -c "^verify tier-profile-note harness=$h not-checked=profile pins and session bindings" <<<"$VOUT")" = 1 ] \
  && ok "verify: one note line says profile pins / session bindings (which replace model_profiles) are not checked" || no "verify: tier-profile-note missing/duplicated :: $VOUT"
mkdir -p "$vh/$r"
printf '{"model_profiles":{"research-sdd-mechanical":{"model":"p/cheap","effort":"low"},"research-sdd-structural":{"model":"<provider>/<mid>"}}}\n' > "$GJ"
tp "$vw"
{ tlq research-sdd-mechanical 'status=configured source=global' && tlq research-sdd-structural 'status=placeholder source=global' && tlq research-sdd-reasoning 'status=unconfigured'; } \
  && ok "verify: global only -> configured; an unreplaced <placeholder> model in the global file is status=placeholder (not unconfigured); a missing key is unconfigured" || no "verify global :: $(grep tier-profile <<<"$VOUT" | tr '\n' '|')"
# Runtime precedence (gentle-shell mergeProfiles: profile.model ?? base.model): a project entry carrying a model
# string wins over the global one, placeholder or not.
printf '{"model_profiles":{"research-sdd-mechanical":{"model":"p/cheap"},"research-sdd-structural":{"model":"p/mid"}}}\n' > "$GJ"
mkdir -p "$vw/.pi"; printf '{"model_profiles":{"research-sdd-mechanical":{"model":"<provider>/<m>"},"research-sdd-reasoning":{"model":"p/strong","thinking":"high"}}}\n' > "$PJ"
tp "$vw"
{ tlq research-sdd-mechanical 'status=placeholder source=project' && tlq research-sdd-structural 'status=configured source=global' && tlq research-sdd-reasoning 'status=configured source=project'; } \
  && ok "verify: a placeholder in the PROJECT file hides the real global profile -> status=placeholder source=project (same precedence as the runtime)" || no "verify placeholder-in-project :: $(grep tier-profile <<<"$VOUT" | tr '\n' '|')"
printf '{"model_profiles":{"research-sdd-mechanical":{"model":"<provider>/<m>"}}}\n' > "$GJ"
printf '{"model_profiles":{"research-sdd-mechanical":{"model":"p/real"}}}\n' > "$PJ"
tp "$vw"
tlq research-sdd-mechanical 'status=configured source=project' && ok "verify: a real project model over a placeholder global one -> configured source=project" || no "verify real-project-over-placeholder-global :: $(tl research-sdd-mechanical)"
printf '{"model_profiles":{"research-sdd-mechanical":{"model":"p/real"}}}\n' > "$GJ"
printf '{"model_profiles":{"research-sdd-mechanical":{"effort":"high"}}}\n' > "$PJ"
tp "$vw"
tlq research-sdd-mechanical 'status=configured source=global' && ok "verify: a project entry WITHOUT a model falls through to the global model (runtime: model ?? base.model)" || no "verify project-entry-without-model :: $(tl research-sdd-mechanical)"
printf '{ not json\n' > "$GJ"; printf '{"model_profiles":{"research-sdd-reasoning":{"model":"p/strong"}}}\n' > "$PJ"
tp "$vw"
{ tlq research-sdd-mechanical 'status=degraded reason=.*not valid JSON' && tlq research-sdd-reasoning 'status=configured source=project' && [ "$VRC" = 0 ]; } \
  && ok "verify: unreadable global JSON -> degraded for the agents it could not settle, a readable project profile still counts, exit 0" || no "verify degraded :: $(grep tier-profile <<<"$VOUT" | tr '\n' '|') rc=$VRC"
# An invalid PROJECT file is treated as missing by the runtime: still degraded, plus the effective result.
printf '{"model_profiles":{"research-sdd-mechanical":{"model":"p/real"},"research-sdd-structural":{"model":"<a>/<b>"}}}\n' > "$GJ"; printf '{ nope\n' > "$PJ"
tp "$vw"
{ tlq research-sdd-mechanical 'status=degraded reason=.*not valid JSON (runtime ignores an invalid project file) effective=configured source=global' \
  && tlq research-sdd-structural 'status=degraded .*effective=placeholder source=global' \
  && tlq research-sdd-reasoning 'status=degraded .*effective=unconfigured' && [ "$VRC" = 0 ]; } \
  && ok "verify: invalid PROJECT JSON stays degraded and appends the effective result from the global file (runtime ignores the project file)" || no "verify degraded-project :: $(grep '^verify tier-profile ' <<<"$VOUT" | tr '\n' '|')"
printf '[1,2]\n' > "$GJ"; rm -f "$PJ"
tp "$vw"
tlq research-sdd-mechanical 'status=unconfigured' && ok "verify: valid JSON without model_profiles object -> unconfigured (not degraded)" || no "verify non-object JSON :: $(tl research-sdd-mechanical)"
em="$TMP/vp-empty-home"; mkdir -p "$em"
eo="$(cd "$vw" && bash "$SUT" --verify --home "$em" --harness all 2>&1)"
! grep -q '^verify tier-profile' <<<"$eo" && ok "verify: nothing installed -> no tier-profile lines (absent stays absent)" || no "verify tier-profile on an empty home :: $eo"
co="$(cd "$vw" && bash "$SUT" --home "$TMP/cl-home" --harness claude >/dev/null 2>&1; bash "$SUT" --verify --home "$TMP/cl-home" --harness claude 2>&1)"
! grep -q '^verify tier-profile' <<<"$co" && ok "verify: claude never reports tier profiles" || no "verify claude tier-profile :: $co"

# --- JSON tool fallbacks: python3 hidden (jq path), python3 and jq hidden (typed degraded) --------------------
echo "-- verify: JSON tool fallbacks --"
BASHBIN="$(command -v bash)"
TOOLS="awk sed sort find basename dirname cat grep tr uniq cut head tail wc readlink cmp rm mkdir mktemp mv cp ln paste sha256sum env date git ls diff chmod id realpath stat xargs touch sleep tee od expr uname hostname rmdir dd"
mkpathdir() { # DIR tool... : symlink each resolvable tool into DIR
  local d="$1" t p; shift; mkdir -p "$d"
  for t in "$@"; do p="$(command -v "$t" 2>/dev/null)" || continue; case "$p" in /*) ln -sf "$p" "$d/$t" ;; esac; done
}
NOPY="$TMP/path-nopy"; NOJSON="$TMP/path-nojson"
# shellcheck disable=SC2086
mkpathdir "$NOPY" $TOOLS bash jq
# shellcheck disable=SC2086
mkpathdir "$NOJSON" $TOOLS bash
has_tool() { ( PATH="$1"; command -v "$2" >/dev/null 2>&1 ); }
HAVE_JQ=0; command -v jq >/dev/null 2>&1 && HAVE_JQ=1
if { ! has_tool "$NOPY" python3; } && { ! has_tool "$NOJSON" python3; } && { ! has_tool "$NOJSON" jq; } && has_tool "$NOJSON" sha256sum; then
  ok "fallback PATH dirs are sound: python3 absent from both, jq absent from the second, sha256sum still reachable"
else no "fallback PATH dirs are not sound (python3 leaked or sha256sum missing)"; fi
rm -f "$PJ"
printf '{"model_profiles":{"research-sdd-mechanical":{"model":"p/cheap"},"research-sdd-structural":{"model":"<provider>/<mid>"}}}\n' > "$GJ"
vpath() { # PATHDIR -> VOUT VRC
  VOUT="$(cd "$vw" && PATH="$1" "$BASHBIN" "$SUT" --verify --home "$vh" --harness "$h" 2>&1)"; VRC=$?; }
if [ "$HAVE_JQ" = 1 ]; then
  vpath "$NOPY"
  { grep -q "^verify harness=$h status=match" <<<"$VOUT" && tlq research-sdd-mechanical 'status=configured source=global' \
    && tlq research-sdd-structural 'status=placeholder source=global' && tlq research-sdd-reasoning 'status=unconfigured' && [ "$VRC" = 0 ]; } \
    && ok "verify without python3: the jq path settles configured / placeholder / unconfigured, harness line still match, exit 0" || no "verify jq path :: rc=$VRC $(grep -e tier-profile -e 'verify harness' <<<"$VOUT" | tr '\n' '|')"
  printf '{ nope\n' > "$GJ"; vpath "$NOPY"
  tlq research-sdd-mechanical 'status=degraded reason=.*not valid JSON' && ok "verify without python3: invalid JSON is degraded via jq" || no "verify jq invalid :: $(tl research-sdd-mechanical)"
  printf '[1,2]\n' > "$GJ"; vpath "$NOPY"
  tlq research-sdd-mechanical 'status=unconfigured' && ok "verify without python3: a non-object JSON document is unconfigured via jq" || no "verify jq non-object :: $(tl research-sdd-mechanical)"
else
  printf '  SKIP  verify jq path: jq is not installed here\n'
fi
printf '{"model_profiles":{"research-sdd-mechanical":{"model":"p/cheap"}}}\n' > "$GJ"; vpath "$NOJSON"
c=0; for t in $TIERS; do tlq "$t" 'status=degraded reason=no JSON tool' && c=$((c+1)); done
{ [ "$c" = 3 ] && grep -q "^verify harness=$h status=match" <<<"$VOUT" && [ "$VRC" = 0 ]; } \
  && ok "verify with neither python3 nor jq: typed degraded (never unconfigured) for every tier agent, exit 0" || no "verify no-json-tool c=$c rc=$VRC :: $(grep tier-profile <<<"$VOUT" | tr '\n' '|')"
rm -f "$GJ"; vpath "$NOJSON"
tlq research-sdd-mechanical 'status=unconfigured' && ok "verify with no JSON tool but NO subagents.json: unconfigured (nothing to read, not degraded)" || no "verify no-json-tool absent file :: $(tl research-sdd-mechanical)"

# --- list edges of the --verify bundle comparison (CLAUDE.md §7: first / middle / last / single) -----------
echo "-- verify: bundle list edges --"
edge_home() { # DIR rel... : files + a hand-written record naming exactly those members
  local d="$1" rel s p="$1/.pi/agent" man="" rec=""; shift
  mkdir -p "$p/research-sdd"
  for rel in "$@"; do mkdir -p "$p/$(dirname "$rel")"; printf 'member %s\n' "$rel" > "$p/$rel"; done
  while IFS= read -r rel; do
    s="$(sha256sum "$p/$rel" | awk '{print $1}')"
    man="$man$(printf '%s\t%s\n' "$s" "$rel")"$'\n'; rec="$rec$(printf 'file=%s  %s\n' "$s" "$rel")"$'\n'
  done < <(printf '%s\n' "$@" | LC_ALL=C sort)
  printf 'bundle_sha256=%s\nprofile=pi\n%s' "$(printf '%s' "$man" | sha256sum | awk '{print $1}')" "$rec" > "$p/research-sdd/.installed-bundle-state"
}
# edge_check INSTALLER rel... -> rc 0 when: the record matches (files=N), and tampering ANY ONE member (first,
# middle(s), last, or the single one) is reported as drift naming that member and no other.
edge_check() {
  local inst="$1" d out rc rel n res=0; shift; n=$#
  d="$(mktemp -d "$TMP/edge.XXXXXX")"; edge_home "$d" "$@"
  out="$(cd "$d" && "$BASHBIN" "$inst" --verify --home "$d" --harness pi 2>&1)"; rc=$?
  { grep -Eq "^verify harness=pi status=match .*files=$n( |\$)" <<<"$out" && [ "$rc" = 0 ]; } || { res=1; EDGE_WHY="${EDGE_WHY:-}match rc=$rc: $(head -c 300 <<<"$out") | "; }
  for rel in "$@"; do
    printf 'tampered\n' >> "$d/.pi/agent/$rel"
    out="$(cd "$d" && "$BASHBIN" "$inst" --verify --home "$d" --harness pi 2>&1)"; rc=$?
    { [ "$rc" = 1 ] && grep -q "^verify harness=pi status=drift drifted=$rel (modified)\$" <<<"$out"; } || res=1
    printf 'member %s\n' "$rel" > "$d/.pi/agent/$rel"
  done
  return "$res"
}
EDGE4="agents/research-sdd-mechanical.md agents/research-sdd-reasoning.md agents/research-sdd-structural.md extensions/research-sdd-hooks.ts"
# shellcheck disable=SC2086
edge_check "$MK/install/research-sdd-install.sh" $EDGE4 \
  && ok "list edges (4 members = pi's whole shipped set): match, then drift named alone at the first, both middle and the last position" || no "list edges, 4-member set :: ${EDGE_WHY:-}"
edge_check "$MK1/install/research-sdd-install.sh" extensions/research-sdd-hooks.ts \
  && ok "list edges (single member, temp kit whose pi ships no agents/extension): match files=1, then drift named alone" || no "list edges, single member :: ${EDGE_WHY:-}"

# --- teeth ---------------------------------------------------------------------------------------------
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth --"
  M="$TMP/mt"; mkdir -p "$M"
  # agent-source mutants: agent_problems must flag the named problem.
  atooth() { # NAME FILE EXPECT SED
    local name="$1" file="$2" expect="$3" sedx="$4" d="$M/a-$1"
    mkdir -p "$d"; cp "$AGENTS"/*.md "$d/"
    if ! MUTANT_SYNTAX=none mutant_sed "$AGENTS/$file.md" "$d/$file.md" "$sedx" >/dev/null 2>&1; then no "teeth $name: mutant not built"; return; fi
    if grep -qF "$expect" <<<"$(agent_problems "$d")"; then ok "teeth $name: validator reports '$expect'"; else no "teeth $name: validator stayed green - THEATER"; fi
  }
  atooth model-added     research-sdd-mechanical 'sets '"'model'" 's/^description: .*/&\nmodel: p\/m/'
  atooth bash-granted    research-sdd-structural "tool 'bash'"  's/^tools: .*/tools: [read, grep, find, bash]/'
  atooth tools-removed   research-sdd-reasoning  'no tools line' '/^tools:/d'
  atooth name-mismatch   research-sdd-reasoning  'name does not match' 's/^name: .*/name: research-sdd-other/'
  # A managed name needs the FILE renamed too (the validator derives the expected name from the file name).
  mn="$M/a-managed-name"; mkdir -p "$mn"; cp "$AGENTS"/*.md "$mn/"; rm -f "$mn/research-sdd-mechanical.md"
  if MUTANT_SYNTAX=none mutant_sed "$AGENTS/research-sdd-mechanical.md" "$mn/jd-judge-a.md" 's/research-sdd-mechanical/jd-judge-a/' >/dev/null 2>&1 \
     && grep -qF 'jd-judge-a.md: collides with the gentle-shell MANAGED agent' <<<"$(agent_problems "$mn")"; then ok "teeth managed-name: validator reports the collision with a managed agent"
  else no "teeth managed-name: validator stayed green - THEATER"; fi
  # mcheck CHECK INSTALLER-PATH -> rc 0 when the invariant HOLDS on that installer, 1 when it is broken.
  mcheck() {
    local check="$1" inst="$2" mh mw mo mrc res=0 g pth
    mh="$(mktemp -d "$M/h.XXXXXX")"; mw="$(mktemp -d "$M/w.XXXXXX")"
    case "$check" in
      deploy)
        (cd "$mw" && bash "$inst" --home "$mh" --harness pi >/dev/null 2>&1)
        [ -e "$mh/.pi/agent/agents/research-sdd-mechanical.md" ] || res=1 ;;
      snippet)
        mo="$(cd "$mw" && bash "$inst" --home "$mh" --harness pi 2>&1)"
        { snippet_json <<<"$mo" | python3 -I -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null && [ -z "$(find "$mh" "$mw" -name subagents.json)" ]; } || res=1 ;;
      edge4)
        # shellcheck disable=SC2086
        edge_check "$inst" $EDGE4 || res=1 ;;
      edge1) edge_check "$inst" extensions/research-sdd-hooks.ts || res=1 ;;
      verify-*)
        (cd "$mw" && bash "$SUT" --home "$mh" --harness pi >/dev/null 2>&1)
        g="$mh/.pi/agent/subagents.json"; pth="$PATH"
        case "$check" in
          verify-unconf)          printf '{"model_profiles":{}}\n' > "$g" ;;
          verify-conf)            printf '{"model_profiles":{"research-sdd-mechanical":{"model":"p/m"}}}\n' > "$g" ;;
          verify-placeholder-glob) printf '{"model_profiles":{"research-sdd-mechanical":{"model":"<provider>/<m>"}}}\n' > "$g" ;;
          verify-placeholder-proj) printf '{"model_profiles":{"research-sdd-mechanical":{"model":"p/real"}}}\n' > "$g"
                                  mkdir -p "$mw/.pi"; printf '{"model_profiles":{"research-sdd-mechanical":{"model":"<provider>/<m>"}}}\n' > "$mw/.pi/subagents.json" ;;
          verify-degraded)        printf '{ nope\n' > "$g" ;;
          verify-degraded-proj)   printf '{"model_profiles":{"research-sdd-mechanical":{"model":"p/real"}}}\n' > "$g"; mkdir -p "$mw/.pi"; printf '{ nope\n' > "$mw/.pi/subagents.json" ;;
          verify-project)         mkdir -p "$mw/.pi"; printf '{"model_profiles":{"research-sdd-mechanical":{"model":"p/m"}}}\n' > "$mw/.pi/subagents.json" ;;
          verify-jq)              printf '{"model_profiles":{"research-sdd-mechanical":{"model":"p/m"},"research-sdd-structural":{"model":"<a>/<b>"}}}\n' > "$g"; pth="$NOPY" ;;
          verify-notool)          printf '{"model_profiles":{"research-sdd-mechanical":{"model":"p/m"}}}\n' > "$g"; pth="$NOJSON" ;;
        esac
        mo="$(cd "$mw" && PATH="$pth" "$BASHBIN" "$inst" --verify --home "$mh" --harness pi 2>&1)"; mrc=$?
        case "$check" in
          verify-unconf)           grep -q 'agent=research-sdd-mechanical status=unconfigured' <<<"$mo" || res=1 ;;
          verify-conf)             grep -q 'agent=research-sdd-mechanical status=configured source=global' <<<"$mo" || res=1 ;;
          verify-placeholder-glob) grep -q 'agent=research-sdd-mechanical status=placeholder source=global' <<<"$mo" || res=1 ;;
          verify-placeholder-proj) grep -q 'agent=research-sdd-mechanical status=placeholder source=project' <<<"$mo" || res=1 ;;
          verify-project)          grep -q 'agent=research-sdd-mechanical status=configured source=project' <<<"$mo" || res=1 ;;
          verify-degraded)         grep -q 'agent=research-sdd-mechanical status=degraded' <<<"$mo" || res=1 ;;
          verify-degraded-proj)    grep -q 'agent=research-sdd-mechanical status=degraded reason=.*effective=configured source=global' <<<"$mo" || res=1 ;;
          verify-jq)               { grep -q 'agent=research-sdd-mechanical status=configured source=global' <<<"$mo" && grep -q 'agent=research-sdd-structural status=placeholder source=global' <<<"$mo" && grep -q '^verify harness=pi status=match' <<<"$mo"; } || res=1 ;;
          verify-notool)           { grep -q 'agent=research-sdd-mechanical status=degraded reason=no JSON tool' <<<"$mo" && grep -q '^verify harness=pi status=match' <<<"$mo"; } || res=1 ;;
        esac
        [ "$mrc" = 0 ] || res=1 ;;
    esac
    return "$res"
  }
  # Baseline: every check HOLDS on the unmutated temp-kit installers, so a red mutant is red because of the mutation.
  CHECKS="deploy snippet edge4 verify-unconf verify-conf verify-placeholder-glob verify-placeholder-proj verify-degraded verify-degraded-proj verify-project"
  [ "$HAVE_JQ" = 1 ] && CHECKS="$CHECKS verify-jq"
  CHECKS="$CHECKS verify-notool"
  for chk in $CHECKS; do
    if mcheck "$chk" "$MK/install/research-sdd-install.sh"; then ok "teeth baseline: '$chk' holds on the unmutated temp-kit installer"
    else no "teeth baseline: '$chk' fails on the UNMUTATED installer - the mutants below prove nothing"; fi
  done
  if mcheck edge1 "$MK1/install/research-sdd-install.sh"; then ok "teeth baseline: 'edge1' holds on the unmutated single-member temp kit"
  else no "teeth baseline: 'edge1' fails on the UNMUTATED single-member kit - the mutants below prove nothing"; fi
  KITV="$MK"
  mtooth() { # NAME FILE(rel to install) CHECK SED...   the mutant installer (in $KITV) must BREAK CHECK
    local name="$1" rel="$2" check="$3"; shift 3
    if ! mutant_chain "teeth $name" "$KIT/install/$rel" "$KITV/install/$rel" "$@" >/dev/null 2>&1; then
      no "teeth $name: mutant not built"; cp "$KIT/install/$rel" "$KITV/install/$rel"; return
    fi
    if mcheck "$check" "$KITV/install/research-sdd-install.sh"; then no "teeth $name: '$check' stayed green on the mutant - THEATER"
    else ok "teeth $name: the mutant breaks the '$check' invariant"; fi
    cp "$KIT/install/$rel" "$KITV/install/$rel"
  }
  INST=research-sdd-install.sh
  PYCFG='^    print("placeholder" if m.strip().startswith("<") else "configured")$'
  mtooth adapters-pi-no-agents    adapters.sh deploy 's|\[pi\]="agents/pi"|[pi]=""|'
  mtooth adapters-pi-claude-src   adapters.sh deploy 's|\[pi\]="agents/pi"|[pi]="agents/claude"|'
  mtooth snippet-not-printed      "$INST" snippet 's/^_rsdd_print_tier_snippet() {$/&\n  return 0/'
  mtooth snippet-written          "$INST" snippet 's|^  gpath="\$(rsdd_field "\$h" model_profiles_path "\$home")"$|&; printf "{}" > "$gpath"|'
  mtooth verify-always-configured "$INST" verify-unconf "s/^    print(\"unconfigured\")\$/    print(\"configured\")/"
  mtooth verify-never-configured  "$INST" verify-conf "s/$PYCFG/    print(\"unconfigured\")/"
  mtooth verify-placeholder-ok    "$INST" verify-placeholder-glob "s/$PYCFG/    print(\"configured\")/"
  mtooth verify-bad-json-silent   "$INST" verify-degraded 's/invalid) echo "degraded:\$f is not valid JSON" ;;/invalid) echo unconfigured ;;/'
  mtooth verify-degraded-no-effective "$INST" verify-degraded-proj 's/ effective=$g source=global//'
  mtooth verify-project-ignored   "$INST" verify-project 's|pfile="\$PWD/.pi/subagents.json"|pfile="/nonexistent/.pi/subagents.json"|'
  mtooth verify-moves-exit-code   "$INST" verify-unconf 's/^      _rsdd_verify_tier_profiles "\$h" "\$home"/      degraded=1; &/'
  # precedence: swapping which file feeds g and p, or letting the project win only when "configured", must go red.
  mtooth verify-precedence-swap   "$INST" verify-placeholder-proj 's|g="\$(_rsdd_profile_file_state "\$gfile" "\$a")"|g="$(_rsdd_profile_file_state "$pfile" "$a")"|' 's|p="\$(_rsdd_profile_file_state "\$pfile" "\$a")"|p="$(_rsdd_profile_file_state "$gfile" "$a")"|'
  mtooth verify-project-needs-real "$INST" verify-placeholder-proj 's/if \[ "\$p" = configured \] || \[ "\$p" = placeholder \]; then/if [ "$p" = configured ]; then/'
  # tool fallbacks.
  if [ "$HAVE_JQ" = 1 ]; then
    mtooth verify-jq-swapped      "$INST" verify-jq 's/then "placeholder" else "configured" end/then "configured" else "placeholder" end/'
    mtooth verify-jq-dropped      "$INST" verify-jq 's/elif command -v jq >\/dev\/null 2>&1; then/elif false; then/'
  else
    printf '  SKIP  teeth verify-jq-*: jq is not installed here\n'
  fi
  mtooth verify-notool-silent     "$INST" verify-notool 's/echo "degraded:no JSON tool (python3 and jq both absent) to read \$f"; return 0/echo unconfigured; return 0/'
  # list edges: dropping the manifest's trailing newline loses the LAST member (read without a final newline);
  # skipping the first line of the comparison set loses the FIRST (and the only member of a one-member set).
  mtooth edge-last-member-lost    "$INST" edge4 's/awk \x27NF \&\& !seen\[\$0\]++\x27)"/awk \x27NF \&\& !seen[$0]++\x27 | sed \x27$d\x27)"/'
  mtooth edge-first-member-lost   "$INST" edge4 's/NF \&\& !seen\[\$0\]++/NF \&\& !seen[$0]++ \&\& NR>1/'
  KITV="$MK1"
  mtooth edge-single-member-lost  "$INST" edge1 's/NF \&\& !seen\[\$0\]++/NF \&\& !seen[$0]++ \&\& NR>1/'
  mtooth edge-single-last-lost    "$INST" edge1 's/awk \x27NF \&\& !seen\[\$0\]++\x27)"/awk \x27NF \&\& !seen[$0]++\x27 | sed \x27$d\x27)"/'
fi

echo
echo "== $pass passed · $fail failed =="
[ "$fail" = 0 ]
