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

# --- installer ---------------------------------------------------------------------------------------
# root_of H -> config root relative to home
rootrel() { case "$1" in pi) echo ".pi/agent" ;; gentle-shell) echo ".gentle-shell/agent" ;; esac; }
# run_in DIR CMD... : run with DIR as cwd
SNIP_BEGIN='  profiles| '
snippet_json() { grep -F "$SNIP_BEGIN" | sed "s/^  profiles| //"; }

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
    assert isinstance(v["model"],str) and "<" in v["model"], k
' 2>"$TMP/pyerr"; then ok "$h: install prints a parseable model_profiles snippet for the three agents with placeholder models"
  else no "$h: snippet missing/invalid ($(cat "$TMP/pyerr" 2>/dev/null | tail -1)) :: $(head -c 300 <<<"$js")"; fi
  grep -q '\.pi/subagents\.json' <<<"$out" && ok "$h: output points at the project .pi/subagents.json" || no "$h: no pointer to the project .pi/subagents.json"
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
  { grep -q 'WARNING.*research-sdd-structural\.md.*diverged.*kept' <<<"$wout" && tail -1 "$home/$r/agents/research-sdd-structural.md" | grep -q '^# tampered$'; } \
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
tp "$vw"
c=0; for t in $TIERS; do tl "$t" | grep -q 'status=unconfigured' && c=$((c+1)); done
{ [ "$c" = 3 ] && [ "$VRC" = 0 ]; } && ok "verify: no subagents.json anywhere -> 3 x unconfigured, exit still 0 (informational)" || no "verify unconfigured c=$c rc=$VRC :: $VOUT"
mkdir -p "$vh/$r"
printf '{"model_profiles":{"research-sdd-mechanical":{"model":"p/cheap","effort":"low"},"research-sdd-structural":{"model":"<provider>/<mid>"}}}\n' > "$vh/$r/subagents.json"
tp "$vw"
{ tl research-sdd-mechanical | grep -q 'status=configured source=global' && tl research-sdd-structural | grep -q 'status=unconfigured' && tl research-sdd-reasoning | grep -q 'status=unconfigured'; } \
  && ok "verify: global profile -> configured(source=global); an unreplaced <placeholder> model and a missing key stay unconfigured" || no "verify global :: $(grep tier-profile <<<"$VOUT" | tr '\n' '|')"
mkdir -p "$vw/.pi"; printf '{"model_profiles":{"research-sdd-reasoning":{"model":"p/strong","thinking":"high"}}}\n' > "$vw/.pi/subagents.json"
tp "$vw"
{ tl research-sdd-reasoning | grep -q 'status=configured source=project' && tl research-sdd-mechanical | grep -q 'status=configured source=global'; } \
  && ok "verify: project .pi/subagents.json is read from the cwd (source=project) alongside the global one" || no "verify project :: $(grep tier-profile <<<"$VOUT" | tr '\n' '|')"
printf '{ not json\n' > "$vh/$r/subagents.json"
tp "$vw"
{ tl research-sdd-mechanical | grep -q 'status=degraded reason=.*not valid JSON' && tl research-sdd-reasoning | grep -q 'status=configured source=project' && [ "$VRC" = 0 ]; } \
  && ok "verify: unreadable global JSON -> degraded for the agents it could not settle, a readable project profile still counts, exit 0" || no "verify degraded :: $(grep tier-profile <<<"$VOUT" | tr '\n' '|') rc=$VRC"
printf '[1,2]\n' > "$vh/$r/subagents.json"; rm -f "$vw/.pi/subagents.json"
tp "$vw"
tl research-sdd-mechanical | grep -q 'status=unconfigured' && ok "verify: valid JSON without model_profiles object -> unconfigured (not degraded)" || no "verify non-object JSON :: $(tl research-sdd-mechanical)"
em="$TMP/vp-empty-home"; mkdir -p "$em"
eo="$(cd "$vw" && bash "$SUT" --verify --home "$em" --harness all 2>&1)"
! grep -q 'tier-profile' <<<"$eo" && ok "verify: nothing installed -> no tier-profile lines (absent stays absent)" || no "verify tier-profile on an empty home :: $eo"
co="$(cd "$vw" && bash "$SUT" --home "$TMP/cl-home" --harness claude >/dev/null 2>&1; bash "$SUT" --verify --home "$TMP/cl-home" --harness claude 2>&1)"
! grep -q 'tier-profile' <<<"$co" && ok "verify: claude never reports tier profiles" || no "verify claude tier-profile :: $co"

# --- teeth ---------------------------------------------------------------------------------------------
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth --"
  M="$TMP/mt"; mkdir -p "$M"
  # agent-source mutants: agent_problems must flag the named problem.
  atooth() { # NAME FILE EXPECT SED
    local name="$1" file="$2" expect="$3" sedx="$4" d="$M/a-$1"
    mkdir -p "$d"; cp "$AGENTS"/*.md "$d/"
    if ! MUTANT_SYNTAX=none mutant_sed "$AGENTS/$file.md" "$d/$file.md" "$sedx" >/dev/null 2>&1; then no "teeth $name: mutant not built"; return; fi
    if agent_problems "$d" | grep -qF "$expect"; then ok "teeth $name: validator reports '$expect'"; else no "teeth $name: validator stayed green — THEATER"; fi
  }
  atooth model-added     research-sdd-mechanical 'sets '"'model'" 's/^description: .*/&\nmodel: p\/m/'
  atooth bash-granted    research-sdd-structural "tool 'bash'"  's/^tools: .*/tools: [read, grep, find, bash]/'
  atooth tools-removed   research-sdd-reasoning  'no tools line' '/^tools:/d'
  atooth name-mismatch   research-sdd-reasoning  'name does not match' 's/^name: .*/name: research-sdd-other/'
  # A managed name needs the FILE renamed too (the validator derives the expected name from the file name).
  mn="$M/a-managed-name"; mkdir -p "$mn"; cp "$AGENTS"/*.md "$mn/"; rm -f "$mn/research-sdd-mechanical.md"
  if MUTANT_SYNTAX=none mutant_sed "$AGENTS/research-sdd-mechanical.md" "$mn/jd-judge-a.md" 's/research-sdd-mechanical/jd-judge-a/' >/dev/null 2>&1 \
     && agent_problems "$mn" | grep -qF 'jd-judge-a.md: collides with the gentle-shell MANAGED agent'; then ok "teeth managed-name: validator reports the collision with a managed agent"
  else no "teeth managed-name: validator stayed green - THEATER"; fi
  # installer/adapters mutants run from a temp kit copy (install dir copied, the rest linked).
  MK="$M/kit"; mkdir -p "$MK/install"
  for f in "$KIT/install"/*; do [ "$f" = "$KIT/install/tests" ] && continue; cp -R "$f" "$MK/install/"; done
  for f in "$KIT"/* "$KIT"/.[!.]*; do [ -e "$f" ] || [ -L "$f" ] || continue; [ "$f" = "$KIT/install" ] && continue; ln -s "$f" "$MK/$(basename "$f")"; done
  # mcheck CHECK INSTALLER-PATH -> rc 0 when the invariant HOLDS on that installer, 1 when it is broken.
  # CHECK = deploy|snippet|verify-unconf|verify-conf|verify-placeholder|verify-degraded|verify-project
  mcheck() {
    local check="$1" inst="$2" mh mw mo mrc res=0 g
    mh="$(mktemp -d "$M/h.XXXXXX")"; mw="$(mktemp -d "$M/w.XXXXXX")"
    case "$check" in
      deploy)
        (cd "$mw" && bash "$inst" --home "$mh" --harness pi >/dev/null 2>&1)
        [ -e "$mh/.pi/agent/agents/research-sdd-mechanical.md" ] || res=1 ;;
      snippet)
        mo="$(cd "$mw" && bash "$inst" --home "$mh" --harness pi 2>&1)"
        { snippet_json <<<"$mo" | python3 -I -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null && [ -z "$(find "$mh" "$mw" -name subagents.json)" ]; } || res=1 ;;
      verify-*)
        (cd "$mw" && bash "$SUT" --home "$mh" --harness pi >/dev/null 2>&1)
        g="$mh/.pi/agent/subagents.json"
        case "$check" in
          verify-unconf)      printf '{"model_profiles":{}}\n' > "$g" ;;
          verify-conf)        printf '{"model_profiles":{"research-sdd-mechanical":{"model":"p/m"}}}\n' > "$g" ;;
          verify-placeholder) printf '{"model_profiles":{"research-sdd-mechanical":{"model":"<provider>/<m>"}}}\n' > "$g" ;;
          verify-degraded)    printf '{ nope\n' > "$g" ;;
          verify-project)     mkdir -p "$mw/.pi"; printf '{"model_profiles":{"research-sdd-mechanical":{"model":"p/m"}}}\n' > "$mw/.pi/subagents.json" ;;
        esac
        mo="$(cd "$mw" && bash "$inst" --verify --home "$mh" --harness pi 2>&1)"; mrc=$?
        case "$check" in
          verify-unconf|verify-placeholder) grep -q 'agent=research-sdd-mechanical status=unconfigured' <<<"$mo" || res=1 ;;
          verify-conf)     grep -q 'agent=research-sdd-mechanical status=configured source=global' <<<"$mo" || res=1 ;;
          verify-project)  grep -q 'agent=research-sdd-mechanical status=configured source=project' <<<"$mo" || res=1 ;;
          verify-degraded) grep -q 'agent=research-sdd-mechanical status=degraded' <<<"$mo" || res=1 ;;
        esac
        [ "$mrc" = 0 ] || res=1 ;;
    esac
    return "$res"
  }
  # Baseline: every check HOLDS on the unmutated temp-kit installer, so a red mutant is red because of the mutation.
  for chk in deploy snippet verify-unconf verify-conf verify-placeholder verify-degraded verify-project; do
    if mcheck "$chk" "$MK/install/research-sdd-install.sh"; then ok "teeth baseline: '$chk' holds on the unmutated temp-kit installer"
    else no "teeth baseline: '$chk' fails on the UNMUTATED installer - the mutants below prove nothing"; fi
  done
  mtooth() { # NAME FILE(rel to install) CHECK SED...   the mutant installer must BREAK CHECK
    local name="$1" rel="$2" check="$3"; shift 3
    if ! mutant_chain "teeth $name" "$KIT/install/$rel" "$MK/install/$rel" "$@" >/dev/null 2>&1; then
      no "teeth $name: mutant not built"; cp "$KIT/install/$rel" "$MK/install/$rel"; return
    fi
    if mcheck "$check" "$MK/install/research-sdd-install.sh"; then no "teeth $name: '$check' stayed green on the mutant - THEATER"
    else ok "teeth $name: the mutant breaks the '$check' invariant"; fi
    cp "$KIT/install/$rel" "$MK/install/$rel"
  }
  mtooth adapters-pi-no-agents    adapters.sh deploy 's|\[pi\]="agents/pi"|[pi]=""|'
  mtooth adapters-pi-claude-src   adapters.sh deploy 's|\[pi\]="agents/pi"|[pi]="agents/claude"|'
  mtooth snippet-not-printed      research-sdd-install.sh snippet 's/^_rsdd_print_tier_snippet() {$/&\n  return 0/'
  mtooth snippet-written          research-sdd-install.sh snippet 's|^  gpath="\$(rsdd_field "\$h" model_profiles_path "\$home")"$|&; printf "{}" > "$gpath"|'
  mtooth verify-always-configured research-sdd-install.sh verify-unconf 's/^print("configured" if isinstance(m, str) and m.strip() and not m.strip().startswith("<") else "unconfigured")$/print("configured")/'
  mtooth verify-never-configured  research-sdd-install.sh verify-conf 's/^print("configured" if isinstance(m, str) and m.strip() and not m.strip().startswith("<") else "unconfigured")$/print("unconfigured")/'
  mtooth verify-placeholder-ok    research-sdd-install.sh verify-placeholder 's/ and not m.strip().startswith("<")//'
  mtooth verify-bad-json-silent   research-sdd-install.sh verify-degraded 's/invalid) echo "degraded:\$f is not valid JSON" ;;/invalid) echo unconfigured ;;/'
  mtooth verify-project-ignored   research-sdd-install.sh verify-project 's|pfile="\$PWD/.pi/subagents.json"|pfile="/nonexistent/.pi/subagents.json"|'
  mtooth verify-moves-exit-code   research-sdd-install.sh verify-unconf 's/^      _rsdd_verify_tier_profiles "\$h" "\$home"/      degraded=1; &/'
fi

echo
echo "RESULT: pass=$pass fail=$fail"
[ "$fail" = 0 ]
