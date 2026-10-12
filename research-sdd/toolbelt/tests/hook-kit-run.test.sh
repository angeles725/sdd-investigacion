#!/usr/bin/env bash
# hook-kit-run.test.sh — kit issue #2175: a target's tracked .claude/settings.json must not embed /home/<user> or kit paths.
# Two units are pinned here:
#   (A) templates/hook-kit-run.sh — the run-time kit resolver a target carries as tools/hooks/kit-run.sh: resolution order
#       ($RESEARCH_SDD_KIT > launcher `Kit checkout:`/`Kit path:` lines > default checkout), stdin/exit passthrough, typed
#       DEGRADED exit 1 when unresolved, and the PreToolUse pkill guard failing CLOSED (permissionDecision "ask").
#   (B) research-sdd-init.sh --portable — installs the resolver into the target's tracked tree and wires the kit-owned hooks
#       (Stop return-token gate, SessionStart drift hook, PreToolUse pkill guard) through it with "$CLAUDE_PROJECT_DIR", so the
#       generated settings.json carries no absolute path; a fresh-clone simulation (settings.json + tools/ only) runs them.
#       Without --portable the wiring is unchanged (absolute kit paths).
#
# Usage: hook-kit-run.test.sh [--prove-teeth]      Exit: 0 held · 1 regression · 2 harness error.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT_RUN="$HERE/../../templates/hook-kit-run.sh"
SUT_INIT="$HERE/../research-sdd-init.sh"
[ -f "$SUT_RUN" ] || { echo "FATAL: resolver template not found: $SUT_RUN" >&2; exit 2; }
[ -f "$SUT_INIT" ] || { echo "FATAL: SUT not found: $SUT_INIT" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required" >&2; exit 2; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok() { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

# stubkit <dir> : a minimal kit (toolbelt/ + the real pkill-guard template) whose scripts echo a marker.
stubkit() {
  mkdir -p "$1/toolbelt" "$1/templates"
  printf '#!/usr/bin/env bash\ncat >/dev/null\necho "stub-ran:$(basename "$0"):$*"\nexit "${STUB_RC:-0}"\n' > "$1/toolbelt/probe.sh"
  cp "$1/toolbelt/probe.sh" "$1/toolbelt/return-token-gate.sh"; cp "$1/toolbelt/probe.sh" "$1/toolbelt/verify-skill-drift-hook.sh"; cp "$1/toolbelt/probe.sh" "$1/toolbelt/retro-gate.sh"
  cp "$HERE/../../templates/hook-pretool-pkill-guard.sh" "$1/templates/"
}
# fakehome <dir> : an empty HOME so the host's launcher files and default checkout cannot answer.
fakehome() { mkdir -p "$1"; }

# run_kit <resolver> <home> [env VAR=val ...] -- <args...> : run the resolver with a scrubbed environment; stdin from $STDIN.
run_kit() {
  local sut="$1" home="$2"; shift 2
  local envs=()
  while [ "$1" != "--" ]; do envs+=("$1"); shift; done; shift
  printf '%s' "${STDIN:-{\}}" | env -i PATH="$PATH" HOME="$home" "${envs[@]}" bash "$sut" "$@"
}

# ---- (A) resolver ----
case_env() {            # $RESEARCH_SDD_KIT resolves; args + stdin + exit code pass through
  local sut="$1" k="$TMP/k-env" h="$TMP/h-env" out rc
  stubkit "$k"; fakehome "$h"
  out="$(STDIN='{"x":1}' STUB_RC=7 run_kit "$sut" "$h" RESEARCH_SDD_KIT="$k" STUB_RC=7 -- toolbelt/probe.sh a b 2>/dev/null)"; rc=$?
  [ "$rc" = 7 ] && [ "$out" = "stub-ran:probe.sh:a b" ]
}
case_launcher_claude() {   # ~/.claude/CLAUDE.md `Kit path:` line (with a leading ~) resolves
  local sut="$1" h="$TMP/h-cl"; fakehome "$h"; mkdir -p "$h/.claude" "$h/kits"; stubkit "$h/kits/k"
  printf 'x\nKit path: ~/kits/k\n' > "$h/.claude/CLAUDE.md"
  [ "$(run_kit "$sut" "$h" -- toolbelt/probe.sh 2>/dev/null)" = "stub-ran:probe.sh:" ]
}
case_launcher_pi() {       # ~/.pi/agent/AGENTS.md `Kit checkout:` line resolves
  local sut="$1" h="$TMP/h-pi"; fakehome "$h"; mkdir -p "$h/.pi/agent"; stubkit "$TMP/k-pi"
  printf 'Kit checkout: %s\n' "$TMP/k-pi" > "$h/.pi/agent/AGENTS.md"
  [ "$(run_kit "$sut" "$h" -- toolbelt/probe.sh 2>/dev/null)" = "stub-ran:probe.sh:" ]
}
case_gentle_home() {       # $GENTLE_PI_AGENT_HOME/AGENTS.md resolves
  local sut="$1" h="$TMP/h-gp" g="$TMP/gp"; fakehome "$h"; mkdir -p "$g"; stubkit "$TMP/k-gp"
  printf 'Kit path: %s\n' "$TMP/k-gp" > "$g/AGENTS.md"
  [ "$(run_kit "$sut" "$h" GENTLE_PI_AGENT_HOME="$g" -- toolbelt/probe.sh 2>/dev/null)" = "stub-ran:probe.sh:" ]
}
case_default() {           # $HOME/investigacion/sdd-investigacion/research-sdd is the last resort
  local sut="$1" h="$TMP/h-df"; fakehome "$h"; stubkit "$h/investigacion/sdd-investigacion/research-sdd"
  [ "$(run_kit "$sut" "$h" -- toolbelt/probe.sh 2>/dev/null)" = "stub-ran:probe.sh:" ]
}
case_env_beats_launcher() {  # the env var wins over a launcher line
  local sut="$1" h="$TMP/h-pr" ke="$TMP/k-pr-env" kl="$TMP/k-pr-file"; fakehome "$h"; mkdir -p "$h/.claude"
  stubkit "$ke"; stubkit "$kl"; printf '#!/usr/bin/env bash\necho from-file\n' > "$kl/toolbelt/probe.sh"
  printf 'Kit path: %s\n' "$kl" > "$h/.claude/CLAUDE.md"
  [ "$(run_kit "$sut" "$h" RESEARCH_SDD_KIT="$ke" -- toolbelt/probe.sh 2>/dev/null)" = "stub-ran:probe.sh:" ]
}
case_unresolved() {        # nothing resolves -> typed DEGRADED, exit 1, the script did not run
  local sut="$1" h="$TMP/h-un" err rc; fakehome "$h"
  err="$(run_kit "$sut" "$h" -- toolbelt/probe.sh 2>&1 >/dev/null)"; rc=$?
  [ "$rc" = 1 ] && grep -q 'kit-run: DEGRADED: research-sdd kit not found' <<<"$err" && grep -q 'did NOT run' <<<"$err"
}
case_missing_script() {    # kit resolves but the script is absent -> typed DEGRADED, exit 1
  local sut="$1" k="$TMP/k-ms" h="$TMP/h-ms" err rc; stubkit "$k"; fakehome "$h"
  err="$(run_kit "$sut" "$h" RESEARCH_SDD_KIT="$k" -- toolbelt/nope.sh 2>&1 >/dev/null)"; rc=$?
  [ "$rc" = 1 ] && grep -q 'nope.sh is missing' <<<"$err"
}
case_pkill_closed() {      # unresolved kit: the pkill guard asks for a pkill command, passes any other
  local sut="$1" h="$TMP/h-pk" out rc; fakehome "$h"
  out="$(STDIN='{"tool_input":{"command":"pkill -f foo"}}' run_kit "$sut" "$h" -- templates/hook-pretool-pkill-guard.sh 2>/dev/null)"; rc=$?
  [ "$rc" = 0 ] && [ "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$out")" = ask ] || return 1
  out="$(STDIN='{"tool_input":{"command":"ls -la"}}' run_kit "$sut" "$h" -- templates/hook-pretool-pkill-guard.sh 2>/dev/null)"; rc=$?
  [ "$rc" = 0 ] && [ -z "$out" ] || return 1
  out="$(STDIN='{"tool_input":{"command":"pgrep -f foo"}}' run_kit "$sut" "$h" -- research-sdd/templates/hook-pretool-pkill-guard.sh 2>/dev/null)"
  [ "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$out")" = ask ]   # matched by suffix, not by one exact path
}
case_invalid_env() {       # a set-but-invalid $RESEARCH_SDD_KIT is reported (typed) and the next source still resolves
  local sut="$1" h="$TMP/h-ie" k="$TMP/k-ie" out err rc; fakehome "$h"; mkdir -p "$h/.claude"; stubkit "$k"
  printf 'Kit path: %s\n' "$k" > "$h/.claude/CLAUDE.md"
  err="$(run_kit "$sut" "$h" RESEARCH_SDD_KIT="$TMP/nope-kit" -- toolbelt/probe.sh 2>&1 >/dev/null)"
  out="$(run_kit "$sut" "$h" RESEARCH_SDD_KIT="$TMP/nope-kit" -- toolbelt/probe.sh 2>/dev/null)"; rc=$?
  [ "$rc" = 0 ] && [ "$out" = "stub-ran:probe.sh:" ] && grep -q "kit-run: DEGRADED: RESEARCH_SDD_KIT=$TMP/nope-kit invalid" <<<"$err"
}
case_rel_escape() {        # an absolute or '..' script path is refused before anything runs
  local sut="$1" k="$TMP/k-re" h="$TMP/h-re" err rc; stubkit "$k"; fakehome "$h"
  err="$(run_kit "$sut" "$h" RESEARCH_SDD_KIT="$k" -- ../etc/x.sh 2>&1 >/dev/null)"; rc=$?
  [ "$rc" = 1 ] && grep -q "must be kit-relative" <<<"$err" || return 1
  err="$(run_kit "$sut" "$h" RESEARCH_SDD_KIT="$k" -- "$k/toolbelt/probe.sh" 2>&1 >/dev/null)"; rc=$?
  [ "$rc" = 1 ] && grep -q "must be kit-relative" <<<"$err"
}
case_launcher_backtick() { # a backtick-quoted launcher value (markdown) resolves
  local sut="$1" h="$TMP/h-bt"; fakehome "$h"; mkdir -p "$h/.claude" "$h/kits"; stubkit "$h/kits/k"
  printf 'Kit path: `~/kits/k`\n' > "$h/.claude/CLAUDE.md"
  [ "$(run_kit "$sut" "$h" -- toolbelt/probe.sh 2>/dev/null)" = "stub-ran:probe.sh:" ]
}

# ---- (B) init --portable ----
# mkkit <name> [<init-sut>] : a private kit copy so the SUT's KIT path is a tmp path we can grep for.
mkkit() {
  local k="$TMP/$1" sut="${2:-$SUT_INIT}"
  mkdir -p "$k/toolbelt"
  cp -R "$HERE/../lib" "$k/toolbelt/lib"
  cp "$HERE/../return-token-gate.sh" "$HERE/../verify-skill-drift-hook.sh" "$k/toolbelt/" 2>/dev/null || :
  cp "$sut" "$k/toolbelt/research-sdd-init.sh"
  cp -R "$HERE/../../templates" "$k/templates"
  printf '%s' "$k"
}
scaffold_portable() {   # <kit> <target> : scaffold + wire --portable
  mkdir -p "$2"
  bash "$1/toolbelt/research-sdd-init.sh" "$2" --corpus flat --prefix t --subject "kit run" --scaffold --wire --portable >"$2.out" 2>&1
}
case_no_abs_paths() {   # generated settings.json carries no absolute path, no kit path, no target path
  local kit="$1" d="$TMP/np-$RANDOM"
  scaffold_portable "$kit" "$d" || return 1
  [ -f "$d/tools/hooks/kit-run.sh" ] && [ -x "$d/tools/hooks/kit-run.sh" ] || return 1
  ! grep -qE '/home/|'"$kit"'|'"$d" "$d/.claude/settings.json" || return 1
  jq -e '[.. | strings | select(startswith("/") or contains(" /"))] | length == 0' "$d/.claude/settings.json" >/dev/null || return 1
  grep -qF 'tools/hooks/kit-run.sh toolbelt/return-token-gate.sh' "$d/.claude/settings.json" &&
    grep -qF 'tools/hooks/kit-run.sh toolbelt/verify-skill-drift-hook.sh' "$d/.claude/settings.json" &&
    grep -qF 'tools/hooks/kit-run.sh templates/hook-pretool-pkill-guard.sh' "$d/.claude/settings.json" &&
    jq -e '[.hooks.Stop[].hooks[].command] | any(. == "bash \"$CLAUDE_PROJECT_DIR\"/tools/hooks/kit-run.sh toolbelt/retro-gate.sh \"$CLAUDE_PROJECT_DIR\"")' "$d/.claude/settings.json" >/dev/null &&
    jq -e '[.hooks.SessionStart[].hooks[].command] | any(. == "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/research-protocol.sh")' "$d/.claude/settings.json" >/dev/null
}
case_no_percopy() {     # --portable creates no per-target retro-gate-stop.sh / pkill-guard.sh (both run through kit-run.sh)
  local kit="$1" d="$TMP/pc-$RANDOM"
  scaffold_portable "$kit" "$d" || return 1
  [ ! -e "$d/.claude/hooks/retro-gate-stop.sh" ] && [ ! -e "$d/.claude/hooks/pkill-guard.sh" ] && [ -x "$d/.claude/hooks/research-protocol.sh" ]
}
case_gitignore_tracked() {  # settings.json, the SessionStart hook and the runner are TRACKED; the rest of .claude/ is ignored
  local kit="$1" d="$TMP/gt-$RANDOM" tracked
  scaffold_portable "$kit" "$d" || return 1
  printf 'x\n' > "$d/.claude/session-sha"
  git -C "$d" add -A >/dev/null 2>&1 || return 1
  tracked="$(git -C "$d" ls-files)"
  grep -qx '.claude/settings.json' <<<"$tracked" && grep -qx '.claude/hooks/research-protocol.sh' <<<"$tracked" &&
    grep -qx 'tools/hooks/kit-run.sh' <<<"$tracked" && ! grep -qx '.claude/session-sha' <<<"$tracked" && ! grep -qxF '.claude/' "$d/.gitignore"
}
case_gitignore_blanket_warns() {  # a pre-existing blanket `.claude/` line is never rewritten: typed WARN, no track rules appended
  local kit="$1" d="$TMP/gb-$RANDOM"; mkdir -p "$d"; printf 'node_modules/\n.claude/\n' > "$d/.gitignore"
  scaffold_portable "$kit" "$d" || return 1
  grep -q 'WARN .*UNTRACKED' "$d.out" && [ "$(grep -c '^\.claude/$' "$d/.gitignore")" = 1 ] && ! grep -qF '!.claude/settings.json' "$d/.gitignore"
}
case_fresh_clone() {    # a REAL git clone of the scaffolded target runs every wired hook command without absolute paths
  local kit="$1" d="$TMP/fc-$RANDOM" c="$TMP/fc-clone-$RANDOM" sk="$TMP/fc-stub-$RANDOM" h="$TMP/fc-home-$RANDOM" cmd n=0 out
  scaffold_portable "$kit" "$d" || return 1
  git -C "$d" add -A >/dev/null 2>&1 && git -C "$d" -c user.name=t -c user.email=t@t commit -qm scaffold >/dev/null 2>&1 || return 1
  git clone -q "$d" "$c" >/dev/null 2>&1 || return 1
  [ -f "$c/.claude/settings.json" ] || return 1
  stubkit "$sk"; fakehome "$h"
  while IFS= read -r cmd; do
    n=$((n+1))
    out="$(printf '{"source":"startup","tool_input":{"command":"ls"}}' | env -i PATH="$PATH" HOME="$h" RESEARCH_SDD_KIT="$sk" CLAUDE_PROJECT_DIR="$c" bash -c "$cmd" 2>/dev/null)" || return 1
    case "$cmd" in
      *pkill-guard*) [ -z "$out" ] || return 1;;
      *kit-run.sh*) grep -q '^stub-ran:' <<<"$out" || return 1;;
    esac
  done < <(jq -r '.hooks | to_entries[] | .value[] | .hooks[] | .command' "$c/.claude/settings.json")
  [ "$n" = 5 ]   # SessionStart hook + drift, Stop retro gate + return-token gate, PreToolUse pkill guard
}
case_pkill_unresolved_wired() {   # the WIRED pkill command fails closed when no kit resolves
  local kit="$1" d="$TMP/pu-$RANDOM" h="$TMP/pu-home-$RANDOM" cmd out; scaffold_portable "$kit" "$d" || return 1; fakehome "$h"
  cmd="$(jq -r '.hooks.PreToolUse[].hooks[].command | select(contains("pkill-guard"))' "$d/.claude/settings.json")"
  out="$(printf '{"tool_input":{"command":"pkill -f x"}}' | env -i PATH="$PATH" HOME="$h" CLAUDE_PROJECT_DIR="$d" bash -c "$cmd" 2>/dev/null)"
  [ "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$out")" = ask ]
}
case_idempotent() {     # re-running --wire --portable adds no second copy of any hook
  local kit="$1" d="$TMP/id-$RANDOM" before after
  scaffold_portable "$kit" "$d" || return 1
  before="$(cksum < "$d/.claude/settings.json")"
  bash "$kit/toolbelt/research-sdd-init.sh" "$d" --wire --portable >"$d.out2" 2>&1 || return 1
  after="$(cksum < "$d/.claude/settings.json")"
  [ "$before" = "$after" ] && [ "$(jq '[.hooks.Stop[].hooks[]] | length' "$d/.claude/settings.json")" = 2 ]
}
case_default_unchanged() {   # without --portable the kit-owned hooks keep their absolute kit path and no runner is installed
  local kit="$1" d="$TMP/du-$RANDOM"; mkdir -p "$d"
  bash "$kit/toolbelt/research-sdd-init.sh" "$d" --corpus flat --prefix t --subject "kit run" --scaffold --wire >"$d.out" 2>&1 || return 1
  grep -qF "$kit/toolbelt/return-token-gate.sh" "$d/.claude/settings.json" && [ ! -e "$d/tools/hooks/kit-run.sh" ]
}
case_wire_only_installs() {  # --wire --portable on an existing corpus installs the runner create-only
  local kit="$1" d="$TMP/wi-$RANDOM"; mkdir -p "$d/tools/hooks"; : > "$d/INDEX.md"
  printf '#!/usr/bin/env bash\n# hand-adapted\n' > "$d/tools/hooks/kit-run.sh"
  bash "$kit/toolbelt/research-sdd-init.sh" "$d" --wire --portable >"$d.out" 2>&1 || return 1
  grep -q 'hand-adapted' "$d/tools/hooks/kit-run.sh" && grep -qF 'kept: ' "$d.out" && ! grep -qE '/home/|'"$kit" "$d/.claude/settings.json"
}

case_migration() {      # --wire --portable over a target wired the DEFAULT way: absolute entries are REPLACED, never duplicated
  local kit="$1" d="$TMP/mg-$RANDOM" st="" n
  mkdir -p "$d"
  bash "$kit/toolbelt/research-sdd-init.sh" "$d" --corpus flat --prefix t --subject "kit run" --scaffold --wire >"$d.out0" 2>&1 || return 1
  grep -qF "$d/.claude/hooks/pkill-guard.sh" "$d/.claude/settings.json" || return 1   # precondition: really the old absolute wiring
  bash "$kit/toolbelt/research-sdd-init.sh" "$d" --wire --portable >"$d.out" 2>&1 || return 1
  st="$d/.claude/settings.json"
  ! grep -qE '/home/|'"$kit"'|'"$d" "$st" || return 1
  [ "$(jq '[.hooks.Stop[].hooks[]] | length' "$st")" = 2 ] && [ "$(jq '[.hooks.PreToolUse[].hooks[]] | length' "$st")" = 1 ] &&
    [ "$(jq '[.hooks.SessionStart[].hooks[]] | length' "$st")" = 2 ] || return 1
  grep -q 'migrated:' "$d.out" || return 1
  grep -q 'gitignore: WARN .*UNTRACKED' "$d.out" || return 1   # the default scaffold wrote a blanket .claude/ line: kept, and named
  jq -e '[.hooks.Stop[].hooks[].command] | any(contains("kit-run.sh toolbelt/retro-gate.sh"))' "$st" >/dev/null || return 1
  n="$(cksum < "$st")"; bash "$kit/toolbelt/research-sdd-init.sh" "$d" --wire --portable >"$d.out2" 2>&1 || return 1   # and the migration is itself idempotent
  [ "$n" = "$(cksum < "$st")" ]
}
case_migration_adapted() {  # a HAND-ADAPTED per-target pkill guard is kept (portable form of the same file), not swapped for the kit's
  local kit="$1" d="$TMP/ma-$RANDOM" st
  mkdir -p "$d"
  bash "$kit/toolbelt/research-sdd-init.sh" "$d" --corpus flat --prefix t --subject "kit run" --scaffold --wire >"$d.out0" 2>&1 || return 1
  printf '#!/usr/bin/env bash\n# hand-adapted\nexit 0\n' > "$d/.claude/hooks/pkill-guard.sh"
  bash "$kit/toolbelt/research-sdd-init.sh" "$d" --wire --portable >"$d.out" 2>&1 || return 1
  st="$d/.claude/settings.json"
  [ "$(jq '[.hooks.PreToolUse[].hooks[]] | length' "$st")" = 1 ] &&
    jq -e '.hooks.PreToolUse[0].hooks[0].command == "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/pkill-guard.sh"' "$st" >/dev/null && ! grep -qF "$d" "$st"
}
case_migration_stop_edited() {  # an EDITED per-target retro-gate-stop.sh is kept wired (typed note), never silently swapped for the kit's gate
  local kit="$1" d="$TMP/ms-$RANDOM" st before
  mkdir -p "$d"
  bash "$kit/toolbelt/research-sdd-init.sh" "$d" --corpus flat --prefix t --subject "kit run" --scaffold --wire >"$d.out0" 2>&1 || return 1
  printf '# hand-adapted\n' >> "$d/.claude/hooks/retro-gate-stop.sh"; before="$(cksum < "$d/.claude/hooks/retro-gate-stop.sh")"
  bash "$kit/toolbelt/research-sdd-init.sh" "$d" --wire --portable >"$d.out" 2>&1 || return 1
  st="$d/.claude/settings.json"
  [ "$before" = "$(cksum < "$d/.claude/hooks/retro-gate-stop.sh")" ] || return 1
  [ "$(jq '[.hooks.Stop[].hooks[]] | length' "$st")" = 2 ] &&
    jq -e '[.hooks.Stop[].hooks[].command] | any(. == "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/retro-gate-stop.sh")' "$st" >/dev/null &&
    ! jq -e '[.hooks.Stop[].hooks[].command] | any(contains("toolbelt/retro-gate.sh"))' "$st" >/dev/null && ! grep -qF "$d" "$st" &&
    grep -q 'note   : kept edited .*retro-gate-stop.sh' "$d.out"
}
case_gitignore_order() {  # missing track rules are appended IN ORDER (.claude/* before the negations); an out-of-order file is WARNed, not edited
  local kit="$1" d="$TMP/go-$RANDOM" e="$TMP/go2-$RANDOM" r
  mkdir -p "$d" "$e"; printf 'node_modules/\n.claude/*\n' > "$d/.gitignore"
  scaffold_portable "$kit" "$d" || return 1
  r="$(grep -nxF -e '.claude/*' -e '!.claude/settings.json' -e '!.claude/hooks/' -e '.claude/hooks/*' -e '!.claude/hooks/research-protocol.sh' "$d/.gitignore" | cut -d: -f2- | paste -sd' ')"
  [ "$r" = ".claude/* !.claude/settings.json !.claude/hooks/ .claude/hooks/* !.claude/hooks/research-protocol.sh" ] || return 1
  printf '!.claude/settings.json\n' > "$e/.gitignore"   # a negation with no preceding .claude/*: appending .claude/* would un-track it
  scaffold_portable "$kit" "$e" || return 1
  grep -q 'gitignore: WARN .*order' "$e.out" && [ "$(grep -c 'claude' "$e/.gitignore")" = 1 ] &&
    grep -qx '    .claude/hooks/\*' "$e.out"   # the rules are printed one per line
}
case_gitignore_blanket_variants() {  # every spelling of a blanket .claude ignore draws the WARN and is left untouched
  local kit="$1" v d i=0
  for v in '.claude/**' '/.claude/*' '/.claude/' '.claude' '.claude/ '; do
    i=$((i+1)); d="$TMP/gv-$i-$RANDOM"; mkdir -p "$d"; printf '%s\n' "$v" > "$d/.gitignore"
    scaffold_portable "$kit" "$d" || return 1
    grep -q 'gitignore: WARN .*UNTRACKED' "$d.out" || return 1
    grep -qxF "$v" "$d/.gitignore" || return 1
  done
}
case_portable_messages() {  # --portable never claims a per-target pkill-guard hook nor tells the user to `git add --force` settings
  local kit="$1" d="$TMP/pm-$RANDOM"; mkdir -p "$d"; git -C "$d" init -q >/dev/null 2>&1 || return 1   # an ALREADY-git target prints the git hint
  scaffold_portable "$kit" "$d" || return 1
  ! grep -q 'created: .*pkill-guard hook' "$d.out" && ! grep -q 'git add --force' "$d.out" && grep -q 'ALREADY under git' "$d.out"
}
case_default_bytes() {  # without --portable the generated settings.json is byte-identical to origin/main's (frozen fixture, paths normalised)
  local kit="$1" d="$TMP/db-$RANDOM"; mkdir -p "$d"
  bash "$kit/toolbelt/research-sdd-init.sh" "$d" --corpus flat --prefix t --subject "kit run" --scaffold --wire >"$d.out" 2>&1 || return 1
  sed "s|$kit|<KIT>|g; s|$d|<TARGET>|g" "$d/.claude/settings.json" | cmp -s - "$HERE/fixtures/hook-kit-run/default-settings.expected.json"
}

K="$(mkkit k0)"
case_env "$SUT_RUN"              && ok "1 \$RESEARCH_SDD_KIT resolves; args, stdin and exit code pass through" || no "1 env resolution / passthrough"
case_launcher_claude "$SUT_RUN"  && ok "2 ~/.claude/CLAUDE.md 'Kit path:' line (leading ~) resolves" || no "2 CLAUDE.md launcher"
case_launcher_pi "$SUT_RUN"      && ok "3 ~/.pi/agent/AGENTS.md 'Kit checkout:' line resolves" || no "3 pi launcher"
case_gentle_home "$SUT_RUN"      && ok "4 \$GENTLE_PI_AGENT_HOME/AGENTS.md resolves" || no "4 GENTLE_PI_AGENT_HOME launcher"
case_default "$SUT_RUN"          && ok "5 default checkout under \$HOME is the last resort" || no "5 default checkout"
case_env_beats_launcher "$SUT_RUN" && ok "6 the env var wins over a launcher line" || no "6 precedence"
case_unresolved "$SUT_RUN"       && ok "7 unresolved kit -> typed DEGRADED, exit 1" || no "7 unresolved must be a typed DEGRADED"
case_missing_script "$SUT_RUN"   && ok "8 missing kit script -> typed DEGRADED, exit 1" || no "8 missing script"
case_pkill_closed "$SUT_RUN"     && ok "9 pkill guard fails CLOSED (ask) on pkill/pgrep, passes other commands" || no "9 pkill guard must fail closed"
case_no_abs_paths "$K"           && ok "10 --portable settings.json has no absolute/kit/target path and wires all three hooks through kit-run.sh" || no "10 portable wiring"
case_fresh_clone "$K"            && ok "11 fresh clone (settings.json + tools/ only) runs every kit-owned hook command" || no "11 fresh clone"
case_pkill_unresolved_wired "$K" && ok "12 wired pkill command fails closed when no kit resolves" || no "12 wired pkill closed"
case_idempotent "$K"             && ok "13 --wire --portable is idempotent (no duplicate hooks)" || no "13 idempotency"
case_default_unchanged "$K"      && ok "14 without --portable: absolute kit path, no runner installed" || no "14 default must be unchanged"
case_wire_only_installs "$K"     && ok "15 wire-only --portable keeps an existing kit-run.sh and wires portably" || no "15 wire-only"
case_migration "$K"              && ok "16 --wire --portable over default (absolute) wiring REPLACES the entries: no duplicates, no absolute path, idempotent" || no "16 migration"
case_migration_adapted "$K"      && ok "17 a hand-adapted per-target pkill guard is migrated to its CLAUDE_PROJECT_DIR form, not replaced" || no "17 adapted migration"
case_gitignore_tracked "$K"      && ok "18 --portable tracks settings.json + the SessionStart hook + the runner; the rest of .claude/ is ignored" || no "18 gitignore must track the wiring"
case_gitignore_blanket_warns "$K" && ok "19 a pre-existing blanket .claude/ line is kept and WARNed about, never rewritten" || no "19 blanket gitignore line"
case_no_percopy "$K"             && ok "20 --portable creates no per-target retro-gate-stop.sh / pkill-guard.sh" || no "20 per-target copies"
case_migration_stop_edited "$K"  && ok "25 an edited per-target retro-gate-stop.sh stays wired (typed note), like the pkill guard" || no "25 edited stop hook"
case_gitignore_order "$K"        && ok "26 track rules are appended in order; an out-of-order .gitignore is WARNed (rules one per line), not edited" || no "26 gitignore order"
case_gitignore_blanket_variants "$K" && ok "27 .claude/**, /.claude/*, /.claude/, .claude and trailing-space spellings all draw the WARN" || no "27 blanket variants"
case_portable_messages "$K"      && ok "28 --portable prints no pkill-guard-hook claim and no 'git add --force' hint" || no "28 portable messages"
case_default_bytes "$K"          && ok "21 default (no --portable) settings.json is byte-identical to the origin/main fixture" || no "21 default wiring must be unchanged"
case_invalid_env "$SUT_RUN"      && ok "22 a set-but-invalid RESEARCH_SDD_KIT is reported (typed) then the next source resolves" || no "22 invalid env"
case_rel_escape "$SUT_RUN"       && ok "23 an absolute or '..' script path is refused" || no "23 rel escape"
case_launcher_backtick "$SUT_RUN" && ok "24 a backtick-quoted launcher value resolves" || no "24 backtick launcher"

if [ "${1:-}" = "--prove-teeth" ]; then
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  mutant_bootstrap mutant_chain mutant_or_count mutant_chain_or_count || exit 2
  # rteeth <label> <case-fn> <sed-expr>... : mutate the RESOLVER; the case passes on the real one and must fail on the mutant.
  rteeth() {
    local label="$1" fn="$2" mut="$TMP/rmut-$RANDOM.sh"; shift 2
    "$fn" "$SUT_RUN" || { no "teeth $label: case FAILS on the unmutated resolver — tooth is vacuous"; return; }
    mutant_chain_or_count fail "teeth $label" "$SUT_RUN" "$mut" "$@" || return 0
    if "$fn" "$mut"; then no "teeth $label: mutant survived — case is THEATER"; else ok "teeth $label: mutant breaks the case (has teeth)"; fi
  }
  # iteeth <label> <case-fn> <sed-expr>... : mutate the INIT script (run from a private kit copy).
  iteeth() {
    local label="$1" fn="$2" mut="$TMP/imut-$RANDOM.sh" mk; shift 2
    "$fn" "$K" || { no "teeth $label: case FAILS on the unmutated SUT — tooth is vacuous"; return; }
    mutant_chain_or_count fail "teeth $label" "$SUT_INIT" "$mut" "$@" || return 0
    mk="$(mkkit "m-$RANDOM" "$mut")"
    if "$fn" "$mk"; then no "teeth $label: mutant survived — case is THEATER"; else ok "teeth $label: mutant breaks the case (has teeth)"; fi
  }
  rteeth ENV-DROPPED case_env 's/local cands=("${RESEARCH_SDD_KIT:-}")/local cands=()/'
  rteeth KIT-PATH-KEY-DROPPED case_launcher_claude 's/for key in "Kit checkout" "Kit path"/for key in "Kit checkout"/'
  rteeth KIT-CHECKOUT-KEY-DROPPED case_launcher_pi 's/for key in "Kit checkout" "Kit path"/for key in "Kit path"/'
  rteeth TILDE-NOT-EXPANDED case_launcher_claude 's|\${line/#\\~/\$HOME}|${line}|'
  rteeth GENTLE-HOME-DROPPED case_gentle_home 's/for d in "${GENTLE_PI_AGENT_HOME:-}" "${PI_CODING_AGENT_DIR:-}"/for d in "${PI_CODING_AGENT_DIR:-}"/'
  rteeth DEFAULT-DROPPED case_default '/^  cands+=("\$HOME\/investigacion/d'
  rteeth ENV-LOSES-TO-FILE case_env_beats_launcher 's/local cands=("${RESEARCH_SDD_KIT:-}")/local cands=()/; s/^  cands+=("\$HOME\/investigacion.*$/  cands+=("${RESEARCH_SDD_KIT:-}")/'
  rteeth DEGRADED-EXIT-ZERO case_unresolved '/did NOT run/{n;s/exit 1/exit 0/}'
  rteeth MISSING-SCRIPT-IGNORED case_missing_script 's/^\[ -f "\$kit\/\$rel" \] || degraded.*$/:/'
  rteeth PKILL-FAILS-OPEN case_pkill_closed 's/permissionDecision:"ask"/permissionDecision:"allow"/'
  rteeth PKILL-ASKS-ON-EVERYTHING case_pkill_closed 's/grep -Eq .pkill|pgrep./true/'
  rteeth INVALID-ENV-SILENT case_invalid_env 's/^    echo "kit-run: DEGRADED: RESEARCH_SDD_KIT=.*$/    :/'
  rteeth REL-ESCAPE-ALLOWED case_rel_escape 's/^if \[\[ "\$rel" == \/\* .*$/:/'
  rteeth BACKTICK-KEPT case_launcher_backtick '/a launcher value may be backtick-quoted/d'
  rteeth PKILL-EXACT-PATH-ONLY case_pkill_closed 's/\[\[ "\$rel" == \*hook-pretool-pkill-guard.sh \]\]/[ "$rel" = "templates\/hook-pretool-pkill-guard.sh" ]/'
  iteeth PORTABLE-STOP-ABSOLUTE case_no_abs_paths 's/^  _C_STOP=.*# PORTABLE-STOP.*$/  :/'
  iteeth PORTABLE-SS-ABSOLUTE case_no_abs_paths 's/^  _C_SS=.*# PORTABLE-SS$/  :/'
  iteeth PORTABLE-DRIFT-ABSOLUTE case_no_abs_paths 's/^  _RSDD_DRIFT_CMD=.*# PORTABLE-DRIFT$/  :/'
  iteeth PORTABLE-PK-WIRED-ABSOLUTE case_pkill_unresolved_wired 's/^  _C_PK=.*# PORTABLE-PK$/  :/'
  iteeth RUNNER-OVERWRITTEN case_wire_only_installs 's/^  if \[ -e "\$dest" \]; then echo "kept: \$dest"; return 0; fi.*$/  :/'
  iteeth DUPLICATE-PKILL-ENTRY case_idempotent 's/(if \$has_pk then/(if false then/'
  iteeth MIGRATION-DROPPED case_migration '/# PORTABLE-MIGRATE$/d'
  iteeth MIGRATION-ADAPTED-REPLACED case_migration_adapted 's/^  if \[ -e "\$hd\/pkill-guard.sh" \] && ! cmp -s.*$/  :/'
  iteeth GITIGNORE-RULES-DROPPED case_gitignore_tracked 's/^  for l in "\${gwant\[@]}"; do .* # PORTABLE-GI$/  :/'
  iteeth GITIGNORE-BLANKET-IGNORED case_gitignore_blanket_warns 's/if \[ -f "\$gi" \] && grep -qxE [^ ]* "\$gi" 2>\/dev\/null; then/if false; then/'
  iteeth PERTARGET-COPIES-KEPT case_no_percopy 's/^if \[ "\$portable" != 1 \]; then   # --portable (kit #2175): both/if true; then   # both/'
  iteeth STOP-EDITED-REPLACED case_migration_stop_edited '/# PORTABLE-STOP-EDITED$/d'
  iteeth GITIGNORE-ORDER-IGNORED case_gitignore_order 's/^  if \[ "\$gbad" = 1 \]; then.*$/  if false; then/'
  iteeth BLANKET-NARROW case_gitignore_blanket_variants 's/grep -qxE [^ ]* "\$gi"/grep -qxE ".claude\/?" "$gi"/'
  iteeth GIT-HINT-ALWAYS case_portable_messages 's/^  if \[ "\$portable" = 1 \]; then echo "           --portable: .*$/  if false; then :/'
  iteeth SUMMARY-PKILL-CLAIM case_portable_messages 's/^_created_hooks="hook · pkill-guard hook"; .*$/_created_hooks="hook · pkill-guard hook"/'
  iteeth DEFAULT-DRIFT-QUOTING case_default_bytes 's/^_RSDD_DRIFT_CMD=.*$/_RSDD_DRIFT_CMD="$_RSDD_DRIFT_PATH"/'
  iteeth PORTABLE-GATE-ABSOLUTE case_no_abs_paths 's/^  _RSDD_GATE_CMD=.*# PORTABLE-GATE$/:/'
  iteeth PORTABLE-RUNNER-NOT-INSTALLED case_fresh_clone '/# PORTABLE-INSTALL-RUNNER$/d'
  iteeth PORTABLE-PKILL-ABSOLUTE case_no_abs_paths 's/^  _C_PK=.*# PORTABLE-PK$/  :/'
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
