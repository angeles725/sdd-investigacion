#!/usr/bin/env bash
# research-sdd-install.test.sh — RED-FIRST harness for the multi-harness kit installer.
#
# The discriminating behaviour: ONE table-driven install loop surfaces the neutral SKILL.md +
# a launcher into every harness's own paths (claude / codex / reasonix), WITHOUT any per-harness
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
TMP="$(mktemp -d)"; MUTANT=""; MUTANT2=""; MUTANT3=""; MUTANT4=""; MUTANT5=""; MUTANT6=""; MUTANT7=""; MUTANT8=""; MUTANT9=""; MUTANT10=""; MUTANT11=""; MUTANT12=""; MUTANT13=""; MUTANT14=""; MUTANT15=""; MUTANT16=""; MUTANT17=""; MUTANT18=""; MUTANT19=""; MUTANT20=""; MUTANT21=""; MUTANT22=""; MUTANT23=""; MUTANT24=""; MUTANT25=""; MUTANT26=""; MUTANT27=""; DRIVER58=""
trap 'rm -rf "$TMP"; [ -n "$MUTANT" ] && rm -f "$MUTANT"; [ -n "$MUTANT2" ] && rm -f "$MUTANT2"; [ -n "$MUTANT3" ] && rm -f "$MUTANT3"; [ -n "$MUTANT4" ] && rm -f "$MUTANT4"; [ -n "$MUTANT5" ] && rm -f "$MUTANT5"; [ -n "$MUTANT6" ] && rm -f "$MUTANT6"; [ -n "$MUTANT7" ] && rm -f "$MUTANT7"; [ -n "$MUTANT8" ] && rm -f "$MUTANT8"; [ -n "$MUTANT9" ] && rm -f "$MUTANT9"; [ -n "$MUTANT10" ] && rm -f "$MUTANT10"; [ -n "$MUTANT11" ] && rm -f "$MUTANT11"; [ -n "$MUTANT12" ] && rm -f "$MUTANT12"; [ -n "$MUTANT13" ] && rm -f "$MUTANT13"; [ -n "$MUTANT14" ] && rm -f "$MUTANT14"; [ -n "$MUTANT15" ] && rm -f "$MUTANT15"; [ -n "$MUTANT16" ] && rm -f "$MUTANT16"; [ -n "$MUTANT17" ] && rm -f "$MUTANT17"; [ -n "$MUTANT18" ] && rm -f "$MUTANT18"; [ -n "$MUTANT19" ] && rm -f "$MUTANT19"; [ -n "$MUTANT20" ] && rm -f "$MUTANT20"; [ -n "$MUTANT21" ] && rm -f "$MUTANT21"; [ -n "$MUTANT22" ] && rm -f "$MUTANT22"; [ -n "$MUTANT23" ] && rm -f "$MUTANT23"; [ -n "$MUTANT24" ] && rm -f "$MUTANT24"; [ -n "$MUTANT25" ] && rm -f "$MUTANT25"; [ -n "$MUTANT26" ] && rm -f "$MUTANT26"; [ -n "$MUTANT27" ] && rm -f "$MUTANT27"; [ -n "$DRIVER58" ] && rm -f "$DRIVER58"' EXIT
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

# Normalise a per-run tmp home to a stable placeholder so goldens are machine-independent.
norm(){ sed "s|$1|{HOME}|g"; }
# Normalise the (machine-specific) kit root so the planned plugin symlink source is portable too.
normkit(){ sed "s|$KITROOT|{KIT}|g"; }

# _direct_clean_profile_dir <dir> <config_root> — invokes _rsdd_clean_profile_dir DIRECTLY (never
# through the full install flow, so this exercises the guard in isolation regardless of what any
# earlier validation layer would have caught). Sources the real, UNMUTATED SUT's functions via a
# throwaway driver placed BESIDE it — SELF-based adapters.sh lookup inside research-sdd-install.sh
# needs $0 to resolve to that directory (same technique test 58 already established). Prints
# "RC=<n>" plus any stderr from the call; the caller greps the result.
_direct_clean_profile_dir() {
  local dir="$1" config_root="$2" driver
  driver="$HERE/../research-sdd-install-direct-clean.$$.sh"
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
  driver="$HERE/../research-sdd-install-direct-plan.$$.sh"
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
for h in claude codex reasonix; do
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
[ -f "$home/.codex/skills/research-sdd/SKILL.md" ] && ok "apply installs SKILL.md (codex leg)" || no "codex SKILL.md missing"
[ -f "$home/.reasonix/skills/research-sdd/SKILL.md" ] && ok "apply installs SKILL.md (reasonix leg)" || no "reasonix SKILL.md missing"
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

# 8 — codex leg documents the manual session-start sweep (no hook fires there); claude does NOT.
home="$TMP/sweep"; bash "$SUT" --home "$home" --harness all >/dev/null 2>&1
cx="$home/.codex/AGENTS.md"; cl="$home/.claude/CLAUDE.md"
if grep -q 'sweep-retros.sh' "$cx" && grep -q 'verify-registry.sh' "$cx"; then ok "codex AGENTS.md documents the manual sweep fallback"
else no "codex sweep-fallback doc missing in $cx"; fi
grep -q 'sweep-retros.sh' "$cl" && no "claude section wrongly carries sweep fallback (has a hook)" || ok "claude section omits sweep fallback (hook fires instead)"

# 10 — the install loop carries ZERO per-harness case arms (all divergence lives in the adapter table).
#      A case arm is a harness name at a statement boundary followed by `|` or `)` (e.g. `claude)`);
#      prose mentions like "(opencode)" in a comment are ignored.
if grep -Eq '^[[:space:]]*(claude|codex|reasonix)[|)]' "$SUT"; then no "installer has a per-harness case arm (should be table-driven)"
else ok "install loop has no per-harness branching"; fi

# 12 — CRITICAL 2: an orphaned start marker (no matching end, hand-edited file) in a MARKDOWN prompt file
#      must NOT drop every trailing user line to EOF. Unlike the TOML path (test 25, which SKIPS to avoid a
#      duplicate table), markdown has no duplicate-table rule and dropping user content is the real risk —
#      so the contract here is PRESERVE + APPEND: trailing user content survives AND a fresh marked section
#      is appended (append mode). REGRESSION GUARD: the markdown path must NOT switch to the TOML skip mode.
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
#      (OpenCode dropped #954; now blocks .codex and checks claude + reasonix still install.)
if [ "$(id -u)" -eq 0 ]; then ok "exit-code aggregation test skipped (running as root, chmod is a no-op)"
else
  home="$TMP/aggr"; mkdir -p "$home/.codex"; chmod 000 "$home/.codex"
  bash "$SUT" --home "$home" --harness all >/dev/null 2>&1; rc=$?
  chmod 755 "$home/.codex"
  [ "$rc" -ne 0 ] && ok "partial failure yields nonzero overall exit" || no "partial failure silently exited 0 (rc=$rc)"
  if [ -f "$home/.claude/skills/research-sdd/SKILL.md" ] && [ -f "$home/.reasonix/skills/research-sdd/SKILL.md" ]; then
    ok "partial failure still installs the writable harnesses (claude + reasonix)"
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

# 19 — ITEM 3: the codex AGENTS.md notes MCP servers are REGISTERED AUTOMATICALLY into config.toml
#      (no contradictory "add it yourself / no-auto-merge" guidance); claude does NOT carry it.
home="$TMP/mcpdoc"; bash "$SUT" --home "$home" --harness all >/dev/null 2>&1
cx="$home/.codex/AGENTS.md"; cl="$home/.claude/CLAUDE.md"
if grep -qi 'registered automatically' "$cx" && grep -q 'config.toml' "$cx" && ! grep -qi 'does NOT auto-merge' "$cx"; then
  ok "codex AGENTS.md notes automatic MCP registration (no contradictory doc)"
else no "codex MCP auto-registration note missing/contradictory in $cx"; fi
grep -qi 'registered automatically' "$cl" && no "claude section wrongly carries the codex MCP note" \
  || ok "claude section omits the codex-only MCP note"

# 20 — codex MCP: --dry-run PLANS the config.toml registration (SPLICE line + the toml block) and
#      writes NOTHING to the filesystem.
home="$TMP/mcp-dry"
out="$(bash "$SUT" --dry-run --home "$home" --harness codex 2>&1)"
if printf '%s\n' "$out" | grep -q "SPLICE  $home/.codex/config.toml" \
   && printf '%s\n' "$out" | grep -q '\[mcp_servers.engram\]' \
   && printf '%s\n' "$out" | grep -q '\[mcp_servers.codegraph\]'; then
  ok "dry-run plans the config.toml MCP registration (both tables shown)"
else no "dry-run did not plan the config.toml write"; fi
[ ! -e "$home/.codex/config.toml" ] && ok "dry-run creates no config.toml" || no "dry-run wrote config.toml"

# 21 — codex MCP: a real run splices a MARKED (#-comment) block with BOTH server tables into config.toml.
home="$TMP/mcp-real"; bash "$SUT" --home "$home" --harness codex >/dev/null 2>&1
cfg="$home/.codex/config.toml"
if [ -f "$cfg" ] && grep -q '# research-sdd:start' "$cfg" && grep -q '# research-sdd:end' "$cfg" \
   && grep -q '\[mcp_servers.engram\]' "$cfg" && grep -q '\[mcp_servers.codegraph\]' "$cfg"; then
  ok "real run registers both MCP tables in a marked config.toml block"
else no "config.toml MCP block missing/incomplete at $cfg"; fi

# 22 — codex MCP: registration is byte-idempotent across re-runs (exactly one block, no growth), even
#      with surrounding user TOML present.
home="$TMP/mcp-idem"; mkdir -p "$home/.codex"
printf 'model = "gpt-5.6-sol"\n\n[projects."/tmp"]\ntrust_level = "trusted"\n' > "$home/.codex/config.toml"
bash "$SUT" --home "$home" --harness codex >/dev/null 2>&1; cp "$home/.codex/config.toml" "$TMP/mcp-run1"
bash "$SUT" --home "$home" --harness codex >/dev/null 2>&1
cfg="$home/.codex/config.toml"
n="$(grep -c '# research-sdd:start' "$cfg" 2>/dev/null || echo 0)"
if [ "$n" = 1 ] && diff -q "$TMP/mcp-run1" "$cfg" >/dev/null 2>&1; then
  ok "config.toml registration is byte-idempotent (one block, no growth)"
else no "config.toml registration not idempotent (sections=$n)"; fi

# 23 — codex MCP: pre-existing UNRELATED user TOML (own tables) survives the splice untouched.
home="$TMP/mcp-preserve"; mkdir -p "$home/.codex"
printf '[projects."/tmp"]\ntrust_level = "trusted"\n\n[mcp_servers.context7]\nurl = "https://x"\n' > "$home/.codex/config.toml"
bash "$SUT" --home "$home" --harness codex >/dev/null 2>&1
cfg="$home/.codex/config.toml"
if grep -q '\[projects."/tmp"\]' "$cfg" && grep -q '\[mcp_servers.context7\]' "$cfg" \
   && grep -q '\[mcp_servers.engram\]' "$cfg"; then
  ok "unrelated user TOML preserved alongside the managed MCP block"
else no "unrelated user TOML clobbered during MCP splice"; fi

# 24 — codex MCP: a pre-existing UNMARKED [mcp_servers.engram] (user-authored) must NOT be duplicated —
#      TOML forbids duplicate tables, so the installer warns and SKIPS. Exactly one engram table remains
#      (the user's), and our managed block is NOT written.
home="$TMP/mcp-conflict"; mkdir -p "$home/.codex"
printf '[mcp_servers.engram]\ncommand = "my-own-engram"\nargs = ["x"]\n' > "$home/.codex/config.toml"
err="$(bash "$SUT" --home "$home" --harness codex 2>&1 >/dev/null)"
cfg="$home/.codex/config.toml"
n="$(grep -c '\[mcp_servers.engram\]' "$cfg" 2>/dev/null || echo 0)"
if [ "$n" = 1 ] && grep -q 'my-own-engram' "$cfg" && ! grep -q '# research-sdd:start' "$cfg" \
   && printf '%s' "$err" | grep -qi 'WARNING.*config.toml'; then
  ok "pre-existing user [mcp_servers.engram] preserved + warned (no duplicate table)"
else no "user engram table duplicated/clobbered or no warning (engram tables=$n)"; fi

# 25 — CRITICAL: an orphaned '# research-sdd:start' whose body is a [mcp_servers.*] table (no matching
#      end — a hand-edit, or a crash mid-write) must NOT be "healed" by appending a fresh block. The
#      orphan already carries [mcp_servers.engram]/[mcp_servers.codegraph], so appending our block would
#      yield TWO of each table — an illegal duplicate-table TOML that fails to parse. TOML's
#      no-duplicate-tables rule DIVERGES from the markdown orphan contract (test 12): here the installer
#      must WARN (malformed marker) and SKIP entirely — file left byte-for-byte untouched, NO second
#      table appended, NO '# research-sdd:end' synthesised — until the user fixes the stray marker.
home="$TMP/mcp-orphan"; mkdir -p "$home/.codex"
printf '# research-sdd:start\n[mcp_servers.engram]\ncommand = "engram"\nargs = ["mcp", "--tools=agent"]\n\n[mcp_servers.codegraph]\ncommand = "codegraph"\nargs = ["serve", "--mcp"]\n' \
  > "$home/.codex/config.toml"
cp "$home/.codex/config.toml" "$TMP/mcp-orphan-orig"
err="$(bash "$SUT" --home "$home" --harness codex 2>&1 >/dev/null)"; rc=$?
cfg="$home/.codex/config.toml"
engrams="$(grep -c '\[mcp_servers.engram\]' "$cfg" 2>/dev/null || true)"
if [ "$engrams" = 1 ] && ! grep -q '# research-sdd:end' "$cfg" && [ "$rc" = 0 ] \
   && diff -q "$TMP/mcp-orphan-orig" "$cfg" >/dev/null 2>&1 \
   && printf '%s' "$err" | grep -qi 'WARNING.*malformed research-sdd marker'; then
  ok "orphaned MCP marker: warn + SKIP, file byte-preserved (no duplicate table, no synthesised end)"
else no "orphaned MCP marker not skipped (engram tables=$engrams, has-end? $(grep -qc '# research-sdd:end' "$cfg"; echo $?), rc=$rc — expected byte-preserved skip)"; fi
# idempotent: re-running stays a no-op SKIP (file unchanged) until the user repairs the marker.
bash "$SUT" --home "$home" --harness codex >/dev/null 2>&1
diff -q "$TMP/mcp-orphan-orig" "$cfg" >/dev/null 2>&1 \
  && ok "orphaned MCP marker skip is byte-idempotent (still a no-op on re-run)" \
  || no "orphaned MCP marker changed the file on re-run (should stay a no-op skip)"

# 26 — WARNING: the duplicate-table guard must also catch spec-valid EQUIVALENT forms of the same table
#      path — here the inline dotted-key `mcp_servers.engram = { ... }`. It defines the same table, so
#      appending our own [mcp_servers.engram] header would be a duplicate-key TOML conflict. The installer
#      must warn + SKIP (no header appended, file byte-preserved), same as the canonical-header case.
home="$TMP/mcp-dotted"; mkdir -p "$home/.codex"
printf 'mcp_servers.engram = { command = "x", args = ["y"] }\n' > "$home/.codex/config.toml"
cp "$home/.codex/config.toml" "$TMP/mcp-dotted-orig"
err="$(bash "$SUT" --home "$home" --harness codex 2>&1 >/dev/null)"
cfg="$home/.codex/config.toml"
if ! grep -q '# research-sdd:start' "$cfg" && ! grep -q '^\[mcp_servers.engram\]' "$cfg" \
   && diff -q "$TMP/mcp-dotted-orig" "$cfg" >/dev/null 2>&1 \
   && printf '%s' "$err" | grep -qi 'WARNING.*config.toml'; then
  ok "inline dotted-key mcp_servers.engram detected as a conflict (warn+skip, byte-preserved)"
else no "inline dotted-key mcp_servers.engram NOT detected — installer appended its own header anyway"; fi

# 42 — reasonix prompt section: no manual-sweep block (it has user-level hooks, needs_sweep=false)
#      and DOES contain the MCP-config note (needs_mcp_config_doc=true) with config.toml path.
home="$TMP/rx-doc"; bash "$SUT" --home "$home" --harness reasonix >/dev/null 2>&1
rx="$home/.reasonix/AGENTS.md"
if ! grep -q 'sweep-retros.sh' "$rx" && grep -qi 'registered automatically' "$rx" \
   && grep -q 'config.toml' "$rx"; then
  ok "reasonix AGENTS.md: no sweep block (hook fires), MCP-config note present"
else no "reasonix AGENTS.md: sweep/MCP-doc check failed (sweep=$(grep -c 'sweep-retros.sh' "$rx" 2>/dev/null||echo 0), registered=$(grep -ci 'registered automatically' "$rx" 2>/dev/null||echo 0))"; fi

# 43 — reasonix MCP: --dry-run plans config.toml registration with [[plugins]] form (not the
#      [mcp_servers.*] table form used by codex). Writes NOTHING to the filesystem.
home="$TMP/rx-mcp-dry"
out="$(bash "$SUT" --dry-run --home "$home" --harness reasonix 2>&1)"
if printf '%s\n' "$out" | grep -q "SPLICE  $home/.reasonix/config.toml" \
   && printf '%s\n' "$out" | grep -q '\[\[plugins\]\]' \
   && printf '%s\n' "$out" | grep -q 'name.*=.*"engram"'; then
  ok "reasonix dry-run plans config.toml MCP registration ([[plugins]] form)"
else no "reasonix dry-run did not plan config.toml write (got: $(printf '%s\n' "$out" | grep 'SPLICE\|\[\[' | head -5 || true))"; fi
[ ! -e "$home/.reasonix/config.toml" ] \
  && ok "reasonix dry-run creates no config.toml" \
  || no "reasonix dry-run wrote config.toml"

# 44 — reasonix MCP: a real run splices a MARKED block with BOTH [[plugins]] entries into config.toml.
home="$TMP/rx-mcp-real"; bash "$SUT" --home "$home" --harness reasonix >/dev/null 2>&1
cfg="$home/.reasonix/config.toml"
if [ -f "$cfg" ] && grep -q '# research-sdd:start' "$cfg" && grep -q '# research-sdd:end' "$cfg" \
   && grep -q '\[\[plugins\]\]' "$cfg" \
   && grep -q 'name.*=.*"engram"' "$cfg" && grep -q 'name.*=.*"codegraph"' "$cfg"; then
  ok "reasonix real run registers both plugins in a marked config.toml block ([[plugins]] form)"
else no "reasonix config.toml MCP block missing/incomplete at $cfg"; fi

# 45 — reasonix MCP: registration is byte-idempotent across re-runs (exactly one block, no growth),
#      even with surrounding user TOML present.
home="$TMP/rx-mcp-idem"; mkdir -p "$home/.reasonix"
printf 'theme = "dark"\n' > "$home/.reasonix/config.toml"
bash "$SUT" --home "$home" --harness reasonix >/dev/null 2>&1; cp "$home/.reasonix/config.toml" "$TMP/rx-run1"
bash "$SUT" --home "$home" --harness reasonix >/dev/null 2>&1
cfg="$home/.reasonix/config.toml"
n="$(grep -c '# research-sdd:start' "$cfg" 2>/dev/null || echo 0)"
if [ "$n" = 1 ] && diff -q "$TMP/rx-run1" "$cfg" >/dev/null 2>&1; then
  ok "reasonix config.toml registration is byte-idempotent (one block, no growth)"
else no "reasonix config.toml registration not idempotent (sections=$n)"; fi

# 46 — reasonix MCP: pre-existing UNRELATED user TOML survives the splice untouched.
home="$TMP/rx-preserve"; mkdir -p "$home/.reasonix"
printf 'theme = "light"\n\n[[other_section]]\nfoo = "bar"\n' > "$home/.reasonix/config.toml"
bash "$SUT" --home "$home" --harness reasonix >/dev/null 2>&1
cfg="$home/.reasonix/config.toml"
if grep -q 'theme = "light"' "$cfg" && grep -q '\[\[plugins\]\]' "$cfg"; then
  ok "unrelated user reasonix TOML preserved alongside the managed MCP block"
else no "unrelated user reasonix TOML clobbered during MCP splice"; fi

# 47 — reasonix MCP: a pre-existing user-authored `name = "engram"` plugin entry must NOT be shadowed
#      silently. Unlike TOML [mcp_servers.*] duplicate-table errors (codex), reasonix SILENTLY
#      de-duplicates [[plugins]] by name with LAST WINS — which means appending our managed block would
#      silently override the user's entry with no warning at all. The installer must warn and SKIP.
home="$TMP/rx-conflict"; mkdir -p "$home/.reasonix"
printf '[[plugins]]\nname    = "engram"\ncommand = "my-own-engram"\nargs    = ["x"]\n' \
  > "$home/.reasonix/config.toml"
err="$(bash "$SUT" --home "$home" --harness reasonix 2>&1 >/dev/null)"
cfg="$home/.reasonix/config.toml"
n="$(grep -c 'name.*=.*"engram"' "$cfg" 2>/dev/null || echo 0)"
if [ "$n" = 1 ] && grep -q 'my-own-engram' "$cfg" && ! grep -q '# research-sdd:start' "$cfg" \
   && printf '%s' "$err" | grep -qi 'WARNING.*config.toml'; then
  ok "pre-existing user name=\"engram\" plugin preserved + warned (no silent shadow)"
else no "user engram plugin shadowed/not warned (engram lines=$n, has-start=$(grep -c '# research-sdd:start' "$cfg" 2>/dev/null||echo 0))"; fi

# 48 — reasonix MCP: an orphaned '# research-sdd:start' (no matching end) must WARN and SKIP
#      entirely — appending would create a second [[plugins]] name="engram" entry that reasonix
#      silently resolves by letting our entry win, discarding the user's. Same skip-not-append
#      contract as the codex TOML path (test 25).
home="$TMP/rx-orphan"; mkdir -p "$home/.reasonix"
printf '# research-sdd:start\n[[plugins]]\nname    = "engram"\ncommand = "engram"\nargs    = ["mcp", "--tools=agent"]\n' \
  > "$home/.reasonix/config.toml"
cp "$home/.reasonix/config.toml" "$TMP/rx-orphan-orig"
err="$(bash "$SUT" --home "$home" --harness reasonix 2>&1 >/dev/null)"; rc=$?
cfg="$home/.reasonix/config.toml"
n_start="$(grep -c '# research-sdd:start' "$cfg" 2>/dev/null || true)"
if [ "$n_start" = 1 ] && ! grep -q '# research-sdd:end' "$cfg" && [ "$rc" = 0 ] \
   && diff -q "$TMP/rx-orphan-orig" "$cfg" >/dev/null 2>&1 \
   && printf '%s' "$err" | grep -qi 'WARNING.*malformed research-sdd marker'; then
  ok "reasonix orphaned MCP marker: warn + SKIP, file byte-preserved"
else no "reasonix orphaned MCP marker not skipped (starts=$n_start, has-end=$(grep -c '# research-sdd:end' "$cfg" 2>/dev/null || echo 0), rc=$rc)"; fi
# idempotent: re-running stays a no-op SKIP (file unchanged).
bash "$SUT" --home "$home" --harness reasonix >/dev/null 2>&1
diff -q "$TMP/rx-orphan-orig" "$cfg" >/dev/null 2>&1 \
  && ok "reasonix orphaned MCP marker skip is byte-idempotent (still a no-op on re-run)" \
  || no "reasonix orphaned MCP marker changed the file on re-run (should stay a no-op skip)"

# 31 — dry-run on an IDENTICAL deployed skill prints [up-to-date], not a plain INSTALL.
#      The §7 three-state rule applied to the plan: identical state must be distinguishable from absent.
home="$TMP/dryrun-identical"
bash "$SUT" --home "$home" --harness codex >/dev/null 2>&1              # seed: real install
out="$(bash "$SUT" --dry-run --home "$home" --harness codex 2>&1)"      # second run: identical
if printf '%s\n' "$out" | grep -q 'INSTALL.*\[up-to-date\]'; then
  ok "dry-run identical: shows [up-to-date] (absent vs identical distinguishable)"
else no "dry-run identical: missing [up-to-date] (got: $(printf '%s\n' "$out" | grep INSTALL || true))"; fi

# 32 — dry-run on a DIVERGED deployed skill prints SKIP and names --force-skill as the remedy.
#      The plan must not promise an install it will then refuse to perform.
home="$TMP/dryrun-diverged"; mkdir -p "$home/.codex/skills/research-sdd"
printf '# custom deployed content — not kit source\n' > "$home/.codex/skills/research-sdd/SKILL.md"
out="$(bash "$SUT" --dry-run --home "$home" --harness codex 2>&1)"
if printf '%s\n' "$out" | grep -q 'INSTALL.*SKIP.*--force-skill'; then
  ok "dry-run diverged: shows SKIP and names --force-skill remedy"
else no "dry-run diverged: plan wrong (got: $(printf '%s\n' "$out" | grep INSTALL || true))"; fi
[ ! -f "$home/.codex/skills/research-sdd/SKILL.md.local-backup" ] \
  && ok "dry-run diverged: no backup created" \
  || no "dry-run diverged: backup created unexpectedly"

# 33 — dry-run on a NOT-READABLE deployed skill prints SKIP (not INSTALL), naming permissions.
#      Mirrors the real-run guard at line ~228 so the plan and real behavior agree.
if [ "$(id -u)" -eq 0 ]; then
  ok "dry-run unreadable SKILL.md check skipped (running as root — chmod 000 is a no-op)"
else
  home="$TMP/dryrun-unreadable"; mkdir -p "$home/.codex/skills/research-sdd"
  printf '# some content\n' > "$home/.codex/skills/research-sdd/SKILL.md"
  chmod 000 "$home/.codex/skills/research-sdd/SKILL.md"
  out="$(bash "$SUT" --dry-run --home "$home" --harness codex 2>&1)"
  chmod 644 "$home/.codex/skills/research-sdd/SKILL.md"
  if printf '%s\n' "$out" | grep -q 'INSTALL.*SKIP.*not readable'; then
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
if printf '%s\n' "$out" | grep -q 'INSTALL.*will overwrite.*backup'; then
  ok "--force-skill + dry-run: plans overwrite and names backup path"
else no "--force-skill + dry-run: plan wrong (got: $(printf '%s\n' "$out" | grep INSTALL || true))"; fi
if grep -q '# custom' "$sf" && [ ! -f "$bak_fd" ]; then
  ok "--force-skill + dry-run: writes nothing (file unchanged, no backup created)"
else no "--force-skill + dry-run: mutated the filesystem"; fi

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
printf '%s\n' "$help_out" | grep -q -- '--force-skill'     || help_ok=0  # in range
printf '%s\n' "$help_out" | grep -q 'set -uo pipefail' && help_ok=0      # must stay outside range
printf '%s\n' "$help_out" | grep -qi 'HELP-START\|HELP-END' && help_ok=0  # sentinels never leak
[ "$help_first" = "Usage:" ]                                || help_ok=0  # starts at Usage:, no stray blank
printf '%s\n' "$help_last" | grep -q "must never report success" || help_ok=0  # last content line
[ "$help_ok" = 1 ] \
  && ok "--help: marker-delimited block correct (--force-skill present, no pipefail/sentinel leak, first/last lines match)" \
  || no "--help: marker-delimited block wrong (force-skill=$(printf '%s\n' "$help_out"|grep -c -- '--force-skill'), pipefail=$(printf '%s\n' "$help_out"|grep -c 'pipefail'), first='$help_first', last='$help_last')"

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
printf '%s' "$err_b1" | grep -qi 'ERROR\|already exists' \
  && ok "B1: error message names the already-existing backup" \
  || no "B1: no error message about existing backup (operator has no signal)"

# 39 — B1: dry-run + --force-skill with existing backup shows SKIP (not 'will overwrite').
#      The plan must match what the real run will do — it would refuse, so the plan must say so.
home="$TMP/force-dry-bak"; mkdir -p "$home/.claude/skills/research-sdd"
printf '# diverged content\n' > "$home/.claude/skills/research-sdd/SKILL.md"
printf '# stale backup\n' > "$home/.claude/skills/research-sdd/SKILL.md.local-backup"
out="$(bash "$SUT" --force-skill --dry-run --home "$home" --harness claude 2>&1)"
if printf '%s\n' "$out" | grep -q 'INSTALL.*SKIP.*already exists'; then
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
  if printf '%s\n' "$out" | grep -q 'INSTALL.*SKIP.*source.*not readable'; then
    ok "B3 dry-run: source unreadable classified correctly (distinct from diverged)"
  else no "B3 dry-run: wrong plan (got: $(printf '%s\n' "$out" | grep INSTALL || true))"; fi
  if printf '%s\n' "$out" | grep -q 'diverged'; then
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
if printf '%s\n' "$out" | grep -q 'INSTALL.*SKIP.*not a regular file'; then
  ok "dir-at-dest dry-run: shows SKIP when skill_path is a directory"
else no "dir-at-dest dry-run: wrong plan (got: $(printf '%s\n' "$out" | grep INSTALL || true))"; fi
err_dir="$(bash "$SUT" --home "$home" --harness claude 2>&1 >/dev/null)"
if [ -d "$sf_dir" ] && ! [ -f "$sf_dir/SKILL.md" ] \
   && printf '%s' "$err_dir" | grep -qi 'WARNING.*not a regular file'; then
  ok "dir-at-dest real run: directory preserved, warned, no file created inside"
else no "dir-at-dest real run: wrong behavior (is dir? $([ -d "$sf_dir" ] && echo yes || echo no), inner-file? $([ -f "$sf_dir/SKILL.md" ] && echo yes || echo no))"; fi

# 49 — rsdd_render_mcp_toml: unknown shape must exit 2, write to stderr, write NOTHING to stdout.
#      The exit-2 guard at adapters.sh (declare -F dispatch check + return 2) is correct but has
#      no test. This assertion pins it (anti-silent-zero §7: a silent partial TOML block is a bug).
out_49="$TMP/ta-out"; err_49="$TMP/ta-err"
ta_script="$TMP/ta-run.sh"
printf '. %s\nrsdd_render_mcp_toml bogus-shape\n' "$HERE/../adapters.sh" > "$ta_script"
bash "$ta_script" >"$out_49" 2>"$err_49"; rc_49=$?
if [ "$rc_49" -eq 2 ] && grep -qi 'unknown shape' "$err_49" && [ ! -s "$out_49" ]; then
  ok "rsdd_render_mcp_toml(bogus-shape): exit 2, stderr has 'unknown shape', stdout empty"
else no "rsdd_render_mcp_toml(bogus-shape): wrong (rc=$rc_49, stderr='$(cat "$err_49")', stdout-empty=$([ ! -s "$out_49" ] && echo yes || echo no))"; fi

# 50 — rsdd_render_section: unknown mcp_toml_shape (needs_mcp_doc=true) must fail loudly —
#      non-zero exit + error on stderr. Without the else branch the if/elif falls through silently
#      (exit 0, section rendered but missing the risk sentence). Also verifies the installer
#      propagates the failure so install_one records rc=1, not silently installs the partial section.
tb_adapters="$TMP/adapters-bogus-shape.sh"
sed 's/\[codex\]="mcp-servers-table"/[codex]="bogus-shape"/' "$HERE/../adapters.sh" >"$tb_adapters"
tb_script="$TMP/tb-run.sh"
printf '. %s\nrsdd_render_section codex %s\n' "$tb_adapters" "$TMP/tb-home" >"$tb_script"
bash "$tb_script" >"$TMP/tb-out" 2>"$TMP/tb-err"; rc_50=$?
if [ "$rc_50" -ne 0 ] && [ -s "$TMP/tb-err" ]; then
  ok "rsdd_render_section(bogus-shape): fails loudly (non-zero + error on stderr)"
else no "rsdd_render_section(bogus-shape): silent (rc=$rc_50, stderr-empty=$([ ! -s "$TMP/tb-err" ] && echo yes || echo no))"; fi
# Installer end-to-end: bogus shape must not silently install a section missing the risk sentence.
tb_kit="$TMP/tb-fake-kit"
mkdir -p "$tb_kit/install" "$tb_kit/skills/research-sdd"
cp "$HERE/../research-sdd-install.sh" "$tb_kit/install/research-sdd-install.sh"
cp "$tb_adapters" "$tb_kit/install/adapters.sh"
printf '# test skill placeholder\n' > "$tb_kit/skills/research-sdd/SKILL.md"
bash "$tb_kit/install/research-sdd-install.sh" --home "$TMP/tb-inst-home" --harness codex \
  >/dev/null 2>"$TMP/tb-inst-err"; rc_50inst=$?
# Prompt file must NOT be written when rsdd_render_section fails: a partial section missing the
# risk sentence must never reach the file. Without the || return 2 propagation in
# _surface__markdown_sections, the splice still runs (silently installing the incomplete section).
tb_pf="$TMP/tb-inst-home/.codex/AGENTS.md"
if [ "$rc_50inst" -ne 0 ] && [ ! -f "$tb_pf" ]; then
  ok "installer with bogus mcp_toml_shape: non-zero exit + no partial section written to prompt file"
else no "installer with bogus mcp_toml_shape: rc=$rc_50inst, prompt-file-exists=$([ -f "$tb_pf" ] && echo yes || echo no) — partial section silently installed"; fi

# 51 — orphan-skip warning must state the shape-correct risk, not a one-size-fits-all message.
#      codex (mcp-servers-table): reason = "duplicate TOML table" (TOML parsers reject duplicates).
#      reasonix (plugins-array):  reason = last-wins/shadowing (duplicate [[plugins]] is valid TOML
#        but reasonix silently de-duplicates by name, last entry wins, discarding the user's entry).
#      Both: 'WARNING.*malformed research-sdd marker' prefix preserved (tests 25 + 48 contract).
#      Both: file byte-preserved (warn+skip semantics unchanged).
# codex orphan:
home_51cx="$TMP/tc-codex"; mkdir -p "$home_51cx/.codex"
printf '# research-sdd:start\n[mcp_servers.engram]\ncommand = "engram"\nargs = ["mcp"]\n' \
  > "$home_51cx/.codex/config.toml"
cp "$home_51cx/.codex/config.toml" "$TMP/tc-cx-orig"
err_51cx="$(bash "$SUT" --home "$home_51cx" --harness codex 2>&1 >/dev/null)"
if printf '%s' "$err_51cx" | grep -qi 'WARNING.*malformed research-sdd marker' \
   && printf '%s' "$err_51cx" | grep -qi 'duplicate.*TOML table' \
   && diff -q "$TMP/tc-cx-orig" "$home_51cx/.codex/config.toml" >/dev/null 2>&1; then
  ok "codex orphan warning: 'duplicate TOML table' reason + byte-preserved"
else no "codex orphan warning wrong (got: '$(printf '%s' "$err_51cx" | head -1)')"; fi
# reasonix orphan:
home_51rx="$TMP/tc-reasonix"; mkdir -p "$home_51rx/.reasonix"
printf '# research-sdd:start\n[[plugins]]\nname = "engram"\ncommand = "engram"\n' \
  > "$home_51rx/.reasonix/config.toml"
cp "$home_51rx/.reasonix/config.toml" "$TMP/tc-rx-orig"
err_51rx="$(bash "$SUT" --home "$home_51rx" --harness reasonix 2>&1 >/dev/null)"
if printf '%s' "$err_51rx" | grep -qi 'WARNING.*malformed research-sdd marker' \
   && printf '%s' "$err_51rx" | grep -qi 'last-wins\|shadowing' \
   && diff -q "$TMP/tc-rx-orig" "$home_51rx/.reasonix/config.toml" >/dev/null 2>&1; then
  ok "reasonix orphan warning: last-wins/shadow reason + byte-preserved"
else no "reasonix orphan warning wrong (got: '$(printf '%s' "$err_51rx" | head -1)')"; fi

# NEGATIVE CONTROL — neuter the idempotent splice (force blind append); two applies must then
# leave TWO marked sections, proving test 6's idempotency assertion has teeth.
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: neuter the marker-aware splice, expect duplicate sections on re-apply --"
  # Live beside the real SUT so the mutant still resolves adapters.sh + the kit's source SKILL.md.
  MUTANT="$HERE/../research-sdd-install.MUTANT.$$.sh"
  # Break the "does the file already carry our marker?" guard so splice always appends.
  sed 's/grep -Fq -- "\$start" "\$file"/false/' "$SUT" > "$MUTANT"
  bash -n "$MUTANT" 2>/dev/null \
    && ok "teeth: MUTANT1 parses (bash -n)" \
    || no "teeth: MUTANT1 is a syntax error — mutation is theater"
  home="$TMP/teeth"
  bash "$MUTANT" --home "$home" --harness claude >/dev/null 2>&1
  bash "$MUTANT" --home "$home" --harness claude >/dev/null 2>&1
  n="$(grep -c '<!-- research-sdd:start -->' "$home/.claude/CLAUDE.md" 2>/dev/null || echo 0)"
  [ "$n" -ge 2 ] && ok "teeth: append-only mutant duplicates the section → idempotency check has teeth" \
    || no "teeth: mutant did not duplicate ($n) — idempotency check is THEATER"

  echo "-- teeth: neuter the TOML duplicate-table guard, expect a duplicate [mcp_servers.engram] --"
  # Break the "does preserved content already define an MCP table?" conflict guard so the block is
  # appended even when the user already has [mcp_servers.engram] — producing an invalid duplicate table.
  MUTANT2="$HERE/../research-sdd-install.MUTANT2.$$.sh"
  sed 's/grep -Eq "\$conflict"/false/' "$SUT" > "$MUTANT2"
  bash -n "$MUTANT2" 2>/dev/null \
    && ok "teeth: MUTANT2 parses (bash -n)" \
    || no "teeth: MUTANT2 is a syntax error — mutation is theater"
  home="$TMP/teeth-toml"; mkdir -p "$home/.codex"
  printf '[mcp_servers.engram]\ncommand = "mine"\nargs = ["x"]\n' > "$home/.codex/config.toml"
  bash "$MUTANT2" --home "$home" --harness codex >/dev/null 2>&1
  n="$(grep -c '\[mcp_servers.engram\]' "$home/.codex/config.toml" 2>/dev/null || echo 0)"
  [ "$n" -ge 2 ] && ok "teeth: guard-less mutant duplicates [mcp_servers.engram] → duplicate-table check has teeth" \
    || no "teeth: mutant did not duplicate ($n) — duplicate-table check is THEATER"

  echo "-- teeth: neuter the TOML orphan-skip, expect a duplicate [mcp_servers.engram] table --"
  # Disable the orphan-skip guard on the TOML path so an orphaned '# research-sdd:start' carrying our own
  # [mcp_servers.*] tables falls through to the append path — producing TWO [mcp_servers.engram] tables
  # (illegal duplicate-table TOML). Proves the skip (not merely the warning) is what prevents corruption.
  MUTANT3="$HERE/../research-sdd-install.MUTANT3.$$.sh"
  sed 's/\[ "\$on_orphan" = skip \]/false/' "$SUT" > "$MUTANT3"
  bash -n "$MUTANT3" 2>/dev/null \
    && ok "teeth: MUTANT3 parses (bash -n)" \
    || no "teeth: MUTANT3 is a syntax error — mutation is theater"
  home="$TMP/teeth-orphan"; mkdir -p "$home/.codex"
  printf '# research-sdd:start\n[mcp_servers.engram]\ncommand = "engram"\nargs = ["mcp", "--tools=agent"]\n\n[mcp_servers.codegraph]\ncommand = "codegraph"\nargs = ["serve", "--mcp"]\n' \
    > "$home/.codex/config.toml"
  bash "$MUTANT3" --home "$home" --harness codex >/dev/null 2>&1
  n="$(grep -c '\[mcp_servers.engram\]' "$home/.codex/config.toml" 2>/dev/null || echo 0)"
  [ "$n" -ge 2 ] && ok "teeth: orphan-skip-less mutant duplicates [mcp_servers.engram] → orphan-skip has teeth" \
    || no "teeth: mutant did not duplicate ($n) — orphan-skip check is THEATER"

  echo "-- teeth: collapse dry-run diverged label, expect test 32 [SKIP+--force-skill] check to fail --"
  # Break the diverged dry-run branch by replacing the [SKIP label with a neutral string, so the
  # grep for 'INSTALL.*SKIP.*--force-skill' no longer matches — test 32 goes red.
  MUTANT4="$HERE/../research-sdd-install.MUTANT4.$$.sh"
  sed 's/SKIP — diverged; use --force-skill to overwrite/up-to-date/' "$SUT" > "$MUTANT4"
  bash -n "$MUTANT4" 2>/dev/null \
    && ok "teeth: MUTANT4 parses (bash -n)" \
    || no "teeth: MUTANT4 is a syntax error — mutation is theater"
  home="$TMP/teeth-dryrun-diverged"; mkdir -p "$home/.codex/skills/research-sdd"
  printf '# custom deployed content\n' > "$home/.codex/skills/research-sdd/SKILL.md"
  out_m4="$(bash "$MUTANT4" --dry-run --home "$home" --harness codex 2>&1)"
  if printf '%s\n' "$out_m4" | grep -q 'INSTALL.*SKIP.*--force-skill'; then
    no "teeth: mutant still matched [SKIP+--force-skill] — dry-run diverged check is THEATER"
  else
    ok "teeth: diverged-label mutant breaks [SKIP+--force-skill] match → dry-run diverged check has teeth"
  fi

  echo "-- teeth: disable backup cp in --force-skill (FIXED: uses elif false, not line delete) --"
  # Replace the backup cp condition with false so the backup step always skips, but the rest of
  # the elif chain is syntactically intact. The SUT still parses; the overwrite runs but no backup
  # is created. Test 34's "backup contains original content" check then fails — proving it bites.
  MUTANT5="$HERE/../research-sdd-install.MUTANT5.$$.sh"
  sed 's/elif ! cp "\$dest" "\$bak"; then/elif false; then/' "$SUT" > "$MUTANT5"
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
  MUTANT6="$HERE/../research-sdd-install.MUTANT6.$$.sh"
  sed 's/if \[ -e "\$bak" \]; then/if false; then/' "$SUT" > "$MUTANT6"
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
    MUTANT7="$HERE/../research-sdd-install.MUTANT7.$$.sh"
    sed 's/elif \[ ! -r "\$src" \]; then/elif false; then/g' "$SUT" > "$MUTANT7"
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
    if printf '%s\n' "$out_m7" | grep -q 'INSTALL.*SKIP.*source.*not readable'; then
      no "teeth: MUTANT7 still shows 'source not readable' — B3 check is THEATER"
    else
      ok "teeth: MUTANT7 hides 'source not readable' → B3 check has teeth"
    fi
    chmod 644 "$m7kit/skills/research-sdd/SKILL.md"
  fi

  echo "-- teeth: neuter plugins-array conflict guard; expect user name=\"engram\" to be shadowed --"
  # Kill the grep conflict check so the installer appends its managed block even when the user
  # already has name="engram". Because reasonix LAST-WINS silently, the user's entry is then
  # shadowed with no warning — proves the conflict guard is what prevents silent data loss.
  MUTANT8="$HERE/../research-sdd-install.MUTANT8.$$.sh"
  sed 's/grep -Eq "\$conflict" "\$scan"/false/' "$SUT" > "$MUTANT8"
  bash -n "$MUTANT8" 2>/dev/null \
    && ok "teeth: MUTANT8 parses (bash -n)" \
    || no "teeth: MUTANT8 is a syntax error — mutation is theater"
  home="$TMP/teeth-rx-conflict"; mkdir -p "$home/.reasonix"
  printf '[[plugins]]\nname    = "engram"\ncommand = "USER-FIRST"\nargs    = ["x"]\n' \
    > "$home/.reasonix/config.toml"
  bash "$MUTANT8" --home "$home" --harness reasonix >/dev/null 2>&1
  n_eng="$(grep -c 'name.*=.*"engram"' "$home/.reasonix/config.toml" 2>/dev/null || echo 0)"
  [ "$n_eng" -ge 2 ] \
    && ok "teeth: guard-less mutant shadows user engram plugin → plugins-array conflict guard has teeth" \
    || no "teeth: mutant did not shadow (name-engram lines=$n_eng) — plugins-array conflict guard is THEATER"

  echo "-- teeth: kill shape dispatch in rsdd_render_mcp_toml; expect wrong table form for reasonix --"
  # Replace the shape argument so the installer always requests the mcp-servers-table form.
  # For reasonix, this emits [mcp_servers.engram] instead of [[plugins]] — the wrong form, proving
  # the shape dispatch is what selects the correct TOML structure.
  MUTANT9="$HERE/../research-sdd-install.MUTANT9.$$.sh"
  sed 's/rsdd_render_mcp_toml "\$shape"/rsdd_render_mcp_toml "mcp-servers-table"/' "$SUT" > "$MUTANT9"
  bash -n "$MUTANT9" 2>/dev/null \
    && ok "teeth: MUTANT9 parses (bash -n)" \
    || no "teeth: MUTANT9 is a syntax error — mutation is theater"
  home_m9="$TMP/teeth-rx-shape"
  bash "$MUTANT9" --home "$home_m9" --harness reasonix >/dev/null 2>&1
  cfg_m9="$home_m9/.reasonix/config.toml"
  if [ -f "$cfg_m9" ] && grep -q '\[mcp_servers.engram\]' "$cfg_m9" \
     && ! grep -q '\[\[plugins\]\]' "$cfg_m9"; then
    ok "teeth: shape-dispatch mutant emits wrong form ([mcp_servers.*] not [[plugins]]) → shape dispatch has teeth"
  else
    no "teeth: shape-dispatch mutant still produced [[plugins]] — shape dispatch check is THEATER"
  fi

  echo "-- teeth: neuter else fail-loud in rsdd_render_section; expect T-b silent-failure check to fail --"
  # Remove the return 2 in the else branch so an unknown mcp_toml_shape exits 0 (silent) — the
  # pre-fix behaviour. T-b's non-zero exit assertion then fails, proving the else is what makes it bite.
  MUTANT10="$HERE/../adapters.MUTANT10.$$.sh"
  sed '/rsdd_render_section: unknown mcp_toml_shape/{n; s/return 2/: # mutated/}' \
    "$HERE/../adapters.sh" > "$MUTANT10"
  bash -n "$MUTANT10" 2>/dev/null \
    && ok "teeth: MUTANT10 parses (bash -n)" \
    || no "teeth: MUTANT10 is a syntax error — mutation is theater"
  ma_script="$TMP/ma-run.sh"
  ma_bogus="$TMP/ma-adapters-bogus.sh"
  sed 's/\[codex\]="mcp-servers-table"/[codex]="bogus-shape"/' "$MUTANT10" >"$ma_bogus"
  # Pass a non-empty kit path so the kit-empty guard passes and the function reaches the
  # mcp_toml_shape else branch — that is the branch MUTANT10 neutered.
  printf '. %s\nrsdd_render_section codex %s %s\n' "$ma_bogus" "$TMP/ma-home" "$KITROOT" >"$ma_script"
  bash "$ma_script" >/dev/null 2>/dev/null; rc_ma=$?
  if [ "$rc_ma" -eq 0 ]; then
    ok "teeth: else-neutered mutant exits 0 on unknown shape → T-b fail-loud check has teeth"
  else
    no "teeth: else-neutered mutant still exited $rc_ma — T-b fail-loud check is THEATER"
  fi

  echo "-- teeth: revert orphan-skip reason to wrong wording; expect T-c reasonix check to fail --"
  # Replace the shape-correct plugins-array reason with the old one-size wording ("duplicate TOML
  # table"). Reasonix orphan then warns with the wrong text — T-c's last-wins/shadowing grep fails.
  MUTANT11="$HERE/../research-sdd-install.MUTANT11.$$.sh"
  sed 's/last-wins shadowing/a duplicate TOML table/' "$SUT" > "$MUTANT11"
  bash -n "$MUTANT11" 2>/dev/null \
    && ok "teeth: MUTANT11 parses (bash -n)" \
    || no "teeth: MUTANT11 is a syntax error — mutation is theater"
  home_m11="$TMP/teeth-m11-rx"; mkdir -p "$home_m11/.reasonix"
  printf '# research-sdd:start\n[[plugins]]\nname = "engram"\ncommand = "engram"\n' \
    > "$home_m11/.reasonix/config.toml"
  err_m11="$(bash "$MUTANT11" --home "$home_m11" --harness reasonix 2>&1 >/dev/null)"
  if printf '%s' "$err_m11" | grep -qi 'last-wins\|shadowing'; then
    no "teeth: wrong-reason mutant still matched last-wins/shadowing — T-c reasonix check is THEATER"
  else
    ok "teeth: wrong-reason mutant fails last-wins/shadowing grep → T-c reasonix check has teeth"
  fi

  echo "-- teeth: remove 'Kit path:' from adapters.sh; expect test-52 'Kit path:' check to fail --"
  # Strip the Kit path: printf line from adapters.sh so the rendered section no longer carries the
  # fast-path anchor. Test 52's 'Kit path:' grep must then fail — proving the emit is what bites.
  MUTANT12="$HERE/../adapters.MUTANT12.$$.sh"
  sed '/printf.*Kit path:/d' "$HERE/../adapters.sh" > "$MUTANT12"
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
  if printf '%s\n' "$out_m12" | grep -q 'Kit path:'; then
    no "teeth: MUTANT12 still emits 'Kit path:' — test-52 Kit path check is THEATER"
  else
    ok "teeth: MUTANT12 omits 'Kit path:' → test-52 Kit path check has teeth"
  fi

fi

# 27 — DATA-LOSS REGRESSION: installing over a DIVERGED deployed SKILL.md must NOT clobber it.
#      The installer must preserve the deployed file and emit a WARNING naming the file.
#      (Regression guard for the unconditional `cp` bug that destroyed retro-applied deltas.)
home="$TMP/skill-diverge"; mkdir -p "$home/.claude/skills/research-sdd"
printf '# custom deployed content — not kit source\n' \
  > "$home/.claude/skills/research-sdd/SKILL.md"
err="$(bash "$SUT" --home "$home" --harness claude 2>&1 >/dev/null)"
sf="$home/.claude/skills/research-sdd/SKILL.md"
if grep -q 'custom deployed content' "$sf" && printf '%s' "$err" | grep -qi 'WARNING.*SKILL\.md'; then
  ok "SKILL.md diverged: deployed file preserved and warned (data-loss regression fixed)"
else
  no "SKILL.md diverged: deployed file was CLOBBERED (DATA LOSS — defining regression)"
fi

# 28 — SKILL.md identical to kit source: no spurious warning (clean silent no-op).
home="$TMP/skill-identical"
bash "$SUT" --home "$home" --harness claude >/dev/null 2>&1         # first install
err="$(bash "$SUT" --home "$home" --harness claude 2>&1 >/dev/null)" # second run on identical
if printf '%s' "$err" | grep -qi 'WARNING.*SKILL\.md'; then
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
  if printf '%s' "$err" | grep -qi 'WARNING.*not readable' && ! printf '%s' "$err" | grep -qi 'diverged'; then
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
if printf '%s\n' "$out_52" | grep -q 'Kit path:'; then
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
#      (adapters.sh _RSDD_DEFAULT_PROFILE: claude=claude, codex=claude, reasonix=general).
out_53a="$(bash "$SUT" --dry-run --home "$TMP/prec-a" --harness claude --profile general 2>&1)"
printf '%s' "$out_53a" | grep -q 'profile=general (source=flag)' \
  && ok "53a: --profile flag selects the profile and reports source=flag" \
  || no "53a: --profile flag not honored (got: $(printf '%s' "$out_53a" | grep profile=)))"

out_53b="$(RESEARCH_SDD_PROFILE=general bash "$SUT" --dry-run --home "$TMP/prec-b" --harness claude 2>&1)"
printf '%s' "$out_53b" | grep -q 'profile=general (source=env)' \
  && ok "53b: \$RESEARCH_SDD_PROFILE env selects the profile and reports source=env" \
  || no "53b: env var not honored (got: $(printf '%s' "$out_53b" | grep profile=)))"

out_53c="$(RESEARCH_SDD_PROFILE=general bash "$SUT" --dry-run --home "$TMP/prec-c" --harness claude --profile claude 2>&1)"
printf '%s' "$out_53c" | grep -q 'profile=claude (source=flag)' \
  && ok "53c: --profile flag wins over \$RESEARCH_SDD_PROFILE env (precedence)" \
  || no "53c: flag did not win over env (got: $(printf '%s' "$out_53c" | grep profile=)))"

out_53d="$(bash "$SUT" --dry-run --home "$TMP/prec-d" --harness reasonix 2>&1)"
printf '%s' "$out_53d" | grep -q 'profile=general (source=default)' \
  && ok "53d: reasonix falls back to its per-harness default (general)" \
  || no "53d: reasonix default wrong (got: $(printf '%s' "$out_53d" | grep profile=)))"

out_53e="$(bash "$SUT" --dry-run --home "$TMP/prec-e" --harness codex 2>&1)"
printf '%s' "$out_53e" | grep -q 'profile=claude (source=default)' \
  && ok "53e: codex falls back to its per-harness default (claude)" \
  || no "53e: codex default wrong (got: $(printf '%s' "$out_53e" | grep profile=)))"

# 54 — unknown profile → exit 2 with a clear message; nothing written to the filesystem.
#      Both entry points (--profile flag and $RESEARCH_SDD_PROFILE env) are validated.
out_54a="$(bash "$SUT" --dry-run --home "$TMP/unk-flag" --harness claude --profile bogus-profile-xyz 2>&1)"; rc_54a=$?
if [ "$rc_54a" -eq 2 ] && printf '%s' "$out_54a" | grep -qi "unknown profile 'bogus-profile-xyz'"; then
  ok "54a: unknown --profile exits 2 with a clear message naming the bad value"
else no "54a: unknown --profile: wrong exit/message (rc=$rc_54a, out=$out_54a)"; fi
[ ! -e "$TMP/unk-flag" ] && ok "54a: unknown --profile writes nothing to the filesystem" \
  || no "54a: unknown --profile mutated the filesystem before validating"

out_54b="$(RESEARCH_SDD_PROFILE=bogus-env-xyz bash "$SUT" --dry-run --home "$TMP/unk-env" --harness claude 2>&1)"; rc_54b=$?
if [ "$rc_54b" -eq 2 ] && printf '%s' "$out_54b" | grep -qi "unknown profile 'bogus-env-xyz'"; then
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
bash "$SUT" --home "$home_56" --harness reasonix >/dev/null 2>&1
pf_56="$home_56/.reasonix/AGENTS.md"
kitpath_56="$(grep '^Kit path:' "$pf_56" 2>/dev/null | sed 's/^Kit path: //')"
kitpath_56_expanded="${kitpath_56/#\~/"$home_56"}"
if [ -n "$kitpath_56" ] && [ -f "$kitpath_56_expanded/PROMPT-LOOP.md" ] \
   && grep -q '(read IN FULL once per context)' "$kitpath_56_expanded/PROMPT-LOOP.md"; then
  ok "56: installed skill's Kit-path resolution reaches the RENDERED PROMPT-LOOP.md"
else no "56: Kit-path resolution did not reach a rendered PROMPT-LOOP.md (kitpath='$kitpath_56')"; fi
if grep -q '(read IN FULL once per context)' "$KITROOT/PROMPT-LOOP.md"; then
  no "56 sanity: kit source PROMPT-LOOP.md already contains the rendered text — test cannot discriminate"
else ok "56 sanity: kit source PROMPT-LOOP.md does not contain the rendered text (test discriminates)"; fi
sf_56="$home_56/.reasonix/skills/research-sdd/SKILL.md"
render_56="$home_56/.reasonix/research-sdd/profile/general/skills/research-sdd/SKILL.md"
if [ -f "$sf_56" ] && [ -f "$render_56" ] && cmp -s "$sf_56" "$render_56"; then
  ok "56: installed SKILL.md matches the rendered profile output"
else no "56: installed SKILL.md does not match the rendered profile output"; fi

# 57 — re-running install for a rendered profile must not leave STALE renders: a leftover file
#      from a prior render (e.g. a slot id later removed from the profile) does not survive.
home_57="$TMP/stale-render"
bash "$SUT" --home "$home_57" --harness reasonix >/dev/null 2>&1
render_dir_57="$home_57/.reasonix/research-sdd/profile/general"
echo "stale leftover from a prior render" > "$render_dir_57/STALE-MARKER.txt"
bash "$SUT" --home "$home_57" --harness reasonix >/dev/null 2>&1
[ ! -e "$render_dir_57/STALE-MARKER.txt" ] \
  && ok "57: stale file from a prior render is cleaned on re-install" \
  || no "57: stale render file survived a re-install"

# 58 — anti-destructive: the render-dir cleaner refuses to touch anything outside
#      <config_root>/research-sdd/profile/ (rc=2, target left byte-preserved). Sources the real
#      SUT's functions directly (never a mutant) via a throwaway driver placed BESIDE the real
#      SUT — SELF-based adapters.sh lookup inside research-sdd-install.sh needs $0 to resolve to
#      that directory (same technique the MUTANT12 kit-path test above already relies on).
DRIVER58="$HERE/../research-sdd-install-driver58.$$.sh"
printf '#!/usr/bin/env bash\nset -uo pipefail\n. "$(dirname "$0")/research-sdd-install.sh" --help >/dev/null 2>&1\n_rsdd_clean_profile_dir "$1" "$2"\necho "RC=$?"\n' > "$DRIVER58"
mkdir -p "$TMP/outside-guard58"; echo "keepme" > "$TMP/outside-guard58/keepme.txt"
out_58="$(bash "$DRIVER58" "$TMP/outside-guard58" "$TMP/some-other-config-root" 2>&1)"
rm -f "$DRIVER58"; DRIVER58=""
if printf '%s' "$out_58" | grep -q 'RC=2' && [ -f "$TMP/outside-guard58/keepme.txt" ]; then
  ok "58: render-dir cleaner refuses (rc=2) a dir outside <config_root>/research-sdd/profile/, target preserved"
else no "58: render-dir cleaner did not refuse an out-of-convention dir (got: $out_58)"; fi

# ── kit issue #1024 review correction (R3-silent-overwrite-rendered-profile): the rendered-profile
#    SKILL.md deploy must honor the SAME divergence rule as the kit-source (claude) leg. Before this
#    fix it copied over the deployed SKILL.md unconditionally: no cmp -s check, no backup,
#    --force-skill ignored, and the dry-run plan always printed a bare INSTALL even when diverged.
# 59 — dry-run on a DIVERGED deployed skill (rendered profile) prints SKIP and names
#      --force-skill as the remedy — mirrors test 32 for the render leg.
home_59="$TMP/dryrun-diverged-render"; mkdir -p "$home_59/.reasonix/skills/research-sdd"
printf '# custom deployed content — not the rendered profile\n' > "$home_59/.reasonix/skills/research-sdd/SKILL.md"
out_59="$(bash "$SUT" --dry-run --home "$home_59" --harness reasonix 2>&1)"
if printf '%s\n' "$out_59" | grep -q 'INSTALL.*SKIP.*--force-skill'; then
  ok "59: dry-run diverged (rendered profile): shows SKIP and names --force-skill remedy"
else no "59: dry-run diverged (rendered profile): plan wrong (got: $(printf '%s\n' "$out_59" | grep INSTALL || true))"; fi
[ ! -f "$home_59/.reasonix/skills/research-sdd/SKILL.md.local-backup" ] \
  && ok "59: dry-run diverged (rendered profile): no backup created" \
  || no "59: dry-run diverged (rendered profile): backup created unexpectedly"

# 60 — a plain re-install (no flags) of a rendered profile with a hand-edited deployed skill must
#      NOT clobber it (this used to silently overwrite unconditionally — the finding's core claim).
home_60="$TMP/render-noclobber"
bash "$SUT" --home "$home_60" --harness reasonix >/dev/null 2>&1
sf_60="$home_60/.reasonix/skills/research-sdd/SKILL.md"
printf '# my hand-edited deployed skill — local delta\n' > "$sf_60"
err_60="$(bash "$SUT" --home "$home_60" --harness reasonix 2>&1 >/dev/null)"
if grep -q 'my hand-edited deployed skill' "$sf_60"; then
  ok "60: rendered-profile re-install preserves a hand-edited deployed SKILL.md (data-loss regression fixed)"
else no "60: rendered-profile re-install CLOBBERED a hand-edited deployed SKILL.md (DATA LOSS)"; fi
printf '%s\n' "$err_60" | grep -qi 'diverged' \
  && ok "60: rendered-profile re-install warns about the diverged deployed skill" \
  || no "60: rendered-profile re-install: no diverged warning printed (got: $err_60)"

# 61 — --force-skill overwrites a diverged deployed skill on the rendered-profile leg, backing it
#      up first — same contract as test 34 for the claude/kit-source leg.
home_61="$TMP/render-force-overwrite"
bash "$SUT" --home "$home_61" --harness reasonix >/dev/null 2>&1
sf_61="$home_61/.reasonix/skills/research-sdd/SKILL.md"
printf '# custom local content — NOT the rendered profile\nmy local delta\n' > "$sf_61"
bash "$SUT" --force-skill --home "$home_61" --harness reasonix >/dev/null 2>&1
bak_61="$sf_61.local-backup"
render_61="$home_61/.reasonix/research-sdd/profile/general/skills/research-sdd/SKILL.md"
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
bash "$SUT" --home "$home_62" --harness reasonix >/dev/null 2>&1
out_62="$(bash "$SUT" --dry-run --home "$home_62" --harness reasonix 2>&1)"
if printf '%s\n' "$out_62" | grep -q 'INSTALL.*\[up-to-date\]'; then
  ok "62: dry-run identical (rendered profile): shows [up-to-date]"
else no "62: dry-run identical (rendered profile): missing [up-to-date] (got: $(printf '%s\n' "$out_62" | grep INSTALL || true))"; fi
[ ! -f "$home_62/.reasonix/skills/research-sdd/SKILL.md.local-backup" ] \
  && ok "62: dry-run identical (rendered profile): no backup created" \
  || no "62: dry-run identical (rendered profile): backup created unexpectedly"

# ── TEETH for the profile feature (kit issue #993 WU2) ────────────────────────────────────────
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: neuter the unknown-profile guard in main(); expect test 54 to fail --"
  MUTANT13="$HERE/../research-sdd-install.MUTANT13.$$.sh"
  sed 's/if ! rsdd_valid_profile "\$resolved" "\$KIT"; then/if false; then/' "$SUT" > "$MUTANT13"
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
  MUTANT14="$HERE/../adapters.MUTANT14.$$.sh"
  sed 's/if \[ -n "\$flag" \]; then/if false; then/' "$HERE/../adapters.sh" > "$MUTANT14"
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
  if printf '%s' "$out_m14" | grep -q 'profile=general (source=flag)'; then
    no "teeth: MUTANT14 still honored the --profile flag — flag-precedence check is THEATER"
  else
    ok "teeth: MUTANT14 (flag ignored) falls through to default → flag-precedence check has teeth"
  fi

  echo "-- teeth: force the launcher to always use \$KIT (ignore kit_for_section); expect test 56 to fail --"
  MUTANT15="$HERE/../research-sdd-install.MUTANT15.$$.sh"
  sed 's/"\$dispatch" "\$h" "\$home" "\$prompt_file" "\$dry" "\$kit_for_section"/"$dispatch" "$h" "$home" "$prompt_file" "$dry" "$KIT"/' "$SUT" > "$MUTANT15"
  bash -n "$MUTANT15" 2>/dev/null \
    && ok "teeth: MUTANT15 parses (bash -n)" \
    || no "teeth: MUTANT15 is a syntax error — mutation is theater"
  home_m15="$TMP/teeth-m15-kitpath"
  bash "$MUTANT15" --home "$home_m15" --harness reasonix >/dev/null 2>&1
  kp_m15="$(grep '^Kit path:' "$home_m15/.reasonix/AGENTS.md" 2>/dev/null | sed 's/^Kit path: //')"
  if printf '%s' "$kp_m15" | grep -q 'research-sdd/profile/general'; then
    no "teeth: MUTANT15 still pointed Kit path at the render dir — kit_for_section wiring check is THEATER"
  else
    ok "teeth: MUTANT15 (kit_for_section ignored) breaks Kit-path→render pointing → wiring check has teeth"
  fi

  echo "-- teeth: skip the render-dir clean call; expect test 57 (stale-render cleanup) to fail --"
  MUTANT16="$HERE/../research-sdd-install.MUTANT16.$$.sh"
  sed 's/! _rsdd_clean_profile_dir "\$render_dir" "\$config_root"/! true/' "$SUT" > "$MUTANT16"
  bash -n "$MUTANT16" 2>/dev/null \
    && ok "teeth: MUTANT16 parses (bash -n)" \
    || no "teeth: MUTANT16 is a syntax error — mutation is theater"
  home_m16="$TMP/teeth-m16-stale"
  bash "$MUTANT16" --home "$home_m16" --harness reasonix >/dev/null 2>&1
  render_dir_m16="$home_m16/.reasonix/research-sdd/profile/general"
  echo "stale" > "$render_dir_m16/STALE-MARKER.txt"
  bash "$MUTANT16" --home "$home_m16" --harness reasonix >/dev/null 2>&1
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
  MUTANT17="$HERE/../research-sdd-install.MUTANT17.$$.sh"
  sed -e 's|"\$config_root"/research-sdd/profile/?\*) ;;|*) ;;|' \
      -e 's|"\$prefix_real"/?\*) ;;|*) ;;|' \
      "$SUT" > "$MUTANT17"
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
  MUTANT18="$HERE/../research-sdd-install.MUTANT18.$$.sh"
  sed 's|"\$prefix_real"/?\*) ;;|*) ;;|' "$SUT" > "$MUTANT18"
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
  MUTANT19="$HERE/../research-sdd-install.MUTANT19.$$.sh"
  sed 's@\[ -L "\$config_root/research-sdd" \] || \[ -L "\$config_root/research-sdd/profile" \]@false@' "$SUT" > "$MUTANT19"
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
  if printf '%s' "$out_m19" | grep -q 'RC=2' || [ -f "$TMP/teeth-m19-elsewhere/profile/general/keepme.txt" ]; then
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
if [ "$rc_f2a" -eq 2 ] && ! printf '%s' "$out_f2a" | grep -q 'harness='; then
  ok "F2a: '--profile ../profiles/general' rejected up front (exit 2, before any harness processing)"
else
  no "F2a: traversal profile not rejected up front (rc=$rc_f2a, out=$out_f2a)"
fi
[ ! -e "$home_f2a" ] && ok "F2a: nothing written to the filesystem" || no "F2a: filesystem touched despite rejection"

# F2b: the same traversal through $RESEARCH_SDD_PROFILE (the other entry point) is rejected too.
home_f2b="$TMP/f2-traversal-env"
out_f2b="$(RESEARCH_SDD_PROFILE="../profiles/general" bash "$SUT" --dry-run --home "$home_f2b" --harness claude 2>&1)"; rc_f2b=$?
if [ "$rc_f2b" -eq 2 ] && ! printf '%s' "$out_f2b" | grep -q 'harness='; then
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
if printf '%s' "$out_f2d" | grep -q 'RC=2' && [ -f "$cfg_root_f2d/research-sdd/OTHER/keepme.txt" ]; then
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
if printf '%s' "$out_f2e" | grep -q 'RC=2' && [ -f "$TMP/f2e-elsewhere/profile/general/keepme.txt" ]; then
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
if printf '%s' "$out_f2pos" | grep -q 'RC=0' && [ ! -e "$cfg_root_f2pos/research-sdd/profile/general/stale.txt" ]; then
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
bash "$SUT" --home "$home_f1" --harness reasonix >/dev/null 2>&1
render_root_f1="$home_f1/.reasonix/research-sdd/profile/general"
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
if [ "$rc_recon_f1e" -eq 0 ] && printf '%s' "$out_recon_f1e" | grep -qF "$real_retros_f1e"; then
  ok "F1e: reconcile-issues.sh --all through a symlinked toolbelt/ resolves the real kit root (exit 0, names the real retros/ path)"
else
  no "F1e: reconcile-issues.sh --all through a symlinked toolbelt/ failed (rc=$rc_recon_f1e out=$out_recon_f1e)"
fi

# $harmless_retro_f1e lives under $TMP, which is NOT a registered target — the "target directory
# ... not found" WARN legitimately fires either way (unrelated to the -P fix). What the fix
# controls is WHICH TARGETS.md the WARN names: broken (unfixed) resolves through
# .../profile/research-sdd/TARGETS.md; fixed always names the real kit's TARGETS.md.
out_stage_f1e="$(bash "$render_root_f1/toolbelt/stage-retro-issues.sh" "$harmless_retro_f1e" 2>&1)"
if ! printf '%s' "$out_stage_f1e" | grep -q 'profile/research-sdd/TARGETS\.md'; then
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
if printf '%s' "$out_pm2" | grep -q 'managed content (matches last install)' \
   && ! printf '%s' "$out_pm2" | grep -qi 'profile switch'; then
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
bash "$SUT" --home "$home_it3" --harness reasonix --profile general >/dev/null 2>&1
sf_it3="$home_it3/.reasonix/skills/research-sdd/SKILL.md"
printf '# hand-edited — a real local delta\n' >> "$sf_it3"
launcher_it3="$home_it3/.reasonix/AGENTS.md"
launcher_before_it3="$(cat "$launcher_it3" 2>/dev/null)"
err_it3="$(bash "$SUT" --home "$home_it3" --harness reasonix --profile claude 2>&1 >/dev/null)"; rc_it3=$?
launcher_after_it3="$(cat "$launcher_it3" 2>/dev/null)"
if [ "$rc_it3" -ne 0 ] && grep -q 'hand-edited — a real local delta' "$sf_it3"; then
  ok "item3: switch keeping a hand-edit exits non-zero (mixed-state signal), content still preserved"
else
  no "item3: switch keeping a hand-edit did not exit non-zero (rc=$rc_it3)"
fi
# kit issue #1024 round 4, item 5: assert the SPECIFIC mixed-state ERROR message text, not just
# a nonzero exit — a wrong-reason nonzero exit (e.g. an unrelated failure) would pass the check
# above just as easily.
if printf '%s' "$err_it3" | grep -qF 'switching profile "general" → "claude" was requested, but a hand-edit at'; then
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
bash "$SUT" --home "$home_r3dr" --harness reasonix --profile general >/dev/null 2>&1
sf_r3dr="$home_r3dr/.reasonix/skills/research-sdd/SKILL.md"
printf '# hand-edited — a real local delta\n' >> "$sf_r3dr"
out_r3dr="$(bash "$SUT" --home "$home_r3dr" --harness reasonix --profile claude --dry-run 2>&1)"; rc_r3dr=$?
if [ "$rc_r3dr" -ne 0 ] \
   && printf '%s' "$out_r3dr" | grep -q 'RDD R4-001' \
   && printf '%s' "$out_r3dr" | grep -q 'SKIP.*launcher rewrite skipped' \
   && ! printf '%s' "$out_r3dr" | grep -q 'SPLICE.*AGENTS\.md'; then
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
bash "$SUT" --home "$home_mval" --harness reasonix --profile general >/dev/null 2>&1
marker_mval="$home_mval/.reasonix/research-sdd/.installed-skill-state"
sha_mval="$(sha256sum "$home_mval/.reasonix/skills/research-sdd/SKILL.md" | awk '{print $1}')"
printf 'profile=not-a-real-profile\nsha256=%s\n' "$sha_mval" > "$marker_mval"
err_mval="$(bash "$SUT" --home "$home_mval" --harness reasonix --profile claude 2>&1 >/dev/null)"
if printf '%s' "$err_mval" | grep -qi "invalid profile 'not-a-real-profile'"; then
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
bash "$SUT" --home "$home_f4" --harness reasonix --profile general >/dev/null 2>&1
err_f4a="$(bash "$SUT" --home "$home_f4" --harness reasonix --profile claude 2>&1 >/dev/null)"
sf_f4="$home_f4/.reasonix/skills/research-sdd/SKILL.md"
if cmp -s "$sf_f4" "$KITROOT/skills/research-sdd/SKILL.md"; then
  ok "F4a: general → claude switch installs the claude kit source byte-identically"
else
  no "F4a: general → claude switch did NOT install the claude kit source (still the general render)"
fi
if printf '%s' "$err_f4a" | grep -qi 'diverged'; then
  no "F4a: general → claude switch was wrongly reported as diverged (a profile switch is not a hand-edit)"
else
  ok "F4a: general → claude switch produced no spurious 'diverged' warning"
fi
if [ ! -e "$home_f4/.reasonix/research-sdd/profile/general" ]; then
  ok "F4b: the orphaned general/ render dir is removed after switching to claude"
else
  no "F4b: the orphaned general/ render dir survived the switch to claude"
fi

# F4c: general → claude → general → claude round trip ends in a clean claude state (matches the
# review's own round-trip scenario). Each hop must stay clean — no accumulated divergence.
home_f4c="$TMP/f4-roundtrip"
bash "$SUT" --home "$home_f4c" --harness reasonix --profile general >/dev/null 2>&1
bash "$SUT" --home "$home_f4c" --harness reasonix --profile claude  >/dev/null 2>&1
bash "$SUT" --home "$home_f4c" --harness reasonix --profile general >/dev/null 2>&1
err_f4c="$(bash "$SUT" --home "$home_f4c" --harness reasonix --profile claude 2>&1 >/dev/null)"
sf_f4c="$home_f4c/.reasonix/skills/research-sdd/SKILL.md"
if cmp -s "$sf_f4c" "$KITROOT/skills/research-sdd/SKILL.md" \
   && ! printf '%s' "$err_f4c" | grep -qi 'diverged' \
   && [ ! -e "$home_f4c/.reasonix/research-sdd/profile/general" ]; then
  ok "F4c: general→claude→general→claude round trip ends in a clean claude state"
else
  no "F4c: round trip did not end clean (identical=$(cmp -s "$sf_f4c" "$KITROOT/skills/research-sdd/SKILL.md" && echo yes || echo no), diverged-warned=$(printf '%s' "$err_f4c" | grep -qi diverged && echo yes || echo no), stale-dir=$([ -e "$home_f4c/.reasonix/research-sdd/profile/general" ] && echo yes || echo no))"
fi

# F4d: regression guard — a GENUINE hand-edit made AFTER a clean switch is still detected and
# preserved (warn+keep), never silently treated as "managed" just because a marker exists.
home_f4d="$TMP/f4-handedit-after-switch"
bash "$SUT" --home "$home_f4d" --harness reasonix --profile general >/dev/null 2>&1
bash "$SUT" --home "$home_f4d" --harness reasonix --profile claude  >/dev/null 2>&1
sf_f4d="$home_f4d/.reasonix/skills/research-sdd/SKILL.md"
printf '# hand-edited after the switch — a real local delta\n' >> "$sf_f4d"
err_f4d="$(bash "$SUT" --home "$home_f4d" --harness reasonix --profile claude 2>&1 >/dev/null)"
if grep -q 'hand-edited after the switch' "$sf_f4d" && printf '%s' "$err_f4d" | grep -qi 'diverged'; then
  ok "F4d: a genuine hand-edit made after a clean switch is still detected and preserved"
else
  no "F4d: hand-edit after a switch was not detected/preserved (content-kept=$(grep -q 'hand-edited after the switch' "$sf_f4d" && echo yes || echo no), warned=$(printf '%s' "$err_f4d" | grep -qi diverged && echo yes || echo no))"
fi

# ── kit issue #1024 review round 2, F1 teeth: skip the linking step ──────────
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: skip _rsdd_complete_profile_render's linking step; expect F1a/F1b to fail --"
  MUTANT20="$HERE/../research-sdd-install.MUTANT20.$$.sh"
  sed 's/elif ! _rsdd_complete_profile_render "\$render_dir" "\$KIT"; then/elif false; then/' "$SUT" > "$MUTANT20"
  bash -n "$MUTANT20" 2>/dev/null \
    && ok "teeth: MUTANT20 parses (bash -n)" \
    || no "teeth: MUTANT20 is a syntax error — mutation is theater"
  if diff -q "$SUT" "$MUTANT20" >/dev/null 2>&1; then
    no "teeth: MUTANT20 pre-check: mutant = SUT — linking-step call site not found"
  else
    ok "teeth: MUTANT20 pre-check: mutant differs (linking step skipped)"
  fi
  home_m20="$TMP/teeth-m20-kitrefs"
  bash "$MUTANT20" --home "$home_m20" --harness reasonix >/dev/null 2>&1
  render_root_m20="$home_m20/.reasonix/research-sdd/profile/general"
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
  if printf '%s' "$out_recon_f1e_teeth" | grep -qi 'absent-input.*TARGETS\.md'; then
    ok "teeth: reverted mutant re-breaks reconcile-issues.sh through a symlinked toolbelt/ → F1e has teeth"
  else
    no "teeth: reverted mutant still resolved TARGETS.md — F1e check is THEATER (out=$out_recon_f1e_teeth)"
  fi
  rm -rf "$scratch_f1e"
  rm -f "$mutant_recon_f1e"

  echo "-- teeth: neuter _rsdd_marker_matches_deployed; expect F4a to fail --"
  MUTANT21="$HERE/../research-sdd-install.MUTANT21.$$.sh"
  sed 's/_rsdd_marker_matches_deployed "\$marker" "\$dest"/false/' "$SUT" > "$MUTANT21"
  bash -n "$MUTANT21" 2>/dev/null \
    && ok "teeth: MUTANT21 parses (bash -n)" \
    || no "teeth: MUTANT21 is a syntax error — mutation is theater"
  if diff -q "$SUT" "$MUTANT21" >/dev/null 2>&1; then
    no "teeth: MUTANT21 pre-check: mutant = SUT — marker-match call site not found"
  else
    ok "teeth: MUTANT21 pre-check: mutant differs (marker-match check disabled)"
  fi
  home_m21="$TMP/teeth-m21-switch"
  bash "$MUTANT21" --home "$home_m21" --harness reasonix --profile general >/dev/null 2>&1
  err_m21="$(bash "$MUTANT21" --home "$home_m21" --harness reasonix --profile claude 2>&1 >/dev/null)"
  sf_m21="$home_m21/.reasonix/skills/research-sdd/SKILL.md"
  if cmp -s "$sf_m21" "$KITROOT/skills/research-sdd/SKILL.md" && ! printf '%s' "$err_m21" | grep -qi 'diverged'; then
    no "teeth: MUTANT21 still switched cleanly — marker-match check is THEATER"
  else
    ok "teeth: MUTANT21 (marker-match disabled) mis-reports a profile switch as diverged → marker-match check has teeth"
  fi

  echo "-- teeth: neuter the orphaned-render cleanup; expect F4b to fail --"
  MUTANT22="$HERE/../research-sdd-install.MUTANT22.$$.sh"
  sed 's/! _rsdd_clean_profile_dir "\$config_root\/research-sdd\/profile\/\$old_profile" "\$config_root"/false/' "$SUT" > "$MUTANT22"
  bash -n "$MUTANT22" 2>/dev/null \
    && ok "teeth: MUTANT22 parses (bash -n)" \
    || no "teeth: MUTANT22 is a syntax error — mutation is theater"
  if diff -q "$SUT" "$MUTANT22" >/dev/null 2>&1; then
    no "teeth: MUTANT22 pre-check: mutant = SUT — orphan-cleanup call site not found"
  else
    ok "teeth: MUTANT22 pre-check: mutant differs (orphan-cleanup disabled)"
  fi
  home_m22="$TMP/teeth-m22-switch"
  bash "$MUTANT22" --home "$home_m22" --harness reasonix --profile general >/dev/null 2>&1
  bash "$MUTANT22" --home "$home_m22" --harness reasonix --profile claude >/dev/null 2>&1
  if [ -e "$home_m22/.reasonix/research-sdd/profile/general" ]; then
    ok "teeth: MUTANT22 (orphan-cleanup disabled) leaves the stale general/ render dir → F4b cleanup check has teeth"
  else
    no "teeth: MUTANT22 still cleaned the orphaned render dir — F4b cleanup check is THEATER"
  fi

  echo "-- teeth: revert the item2 relabel; expect item2 to fail --"
  MUTANT23="$HERE/../research-sdd-install.MUTANT23.$$.sh"
  sed "s/managed content (matches last install)/managed content from a profile switch/" "$SUT" > "$MUTANT23"
  bash -n "$MUTANT23" 2>/dev/null \
    && ok "teeth: MUTANT23 parses (bash -n)" \
    || no "teeth: MUTANT23 is a syntax error — mutation is theater"
  if diff -q "$SUT" "$MUTANT23" >/dev/null 2>&1; then
    no "teeth: MUTANT23 pre-check: mutant = SUT — relabel text not found"
  else
    ok "teeth: MUTANT23 pre-check: mutant differs (relabel reverted)"
  fi
  driver_m23="$HERE/../research-sdd-install-driver-m23.$$.sh"
  printf '#!/usr/bin/env bash\nset -uo pipefail\n. "$(dirname "$0")/research-sdd-install.MUTANT23.'"$$"'.sh" --help >/dev/null 2>&1\n_rsdd_dry_skill_plan "$1" "$2" "$3" "$4" "$5"\n' > "$driver_m23"
  out_m23="$(bash "$driver_m23" "$_pm2_src" "$_pm2_dest" 0 "from rendered profile 'general'" "$_pm2_marker" 2>&1)"
  rm -f "$driver_m23"
  if printf '%s' "$out_m23" | grep -qi 'profile switch'; then
    ok "teeth: MUTANT23 (relabel reverted) re-shows the misleading 'profile switch' text → item2 check has teeth"
  else
    no "teeth: MUTANT23 still avoided 'profile switch' text — item2 check is THEATER (out=$out_m23)"
  fi

  echo "-- teeth: neuter the item3 mixed-state guard; expect item3 to fail --"
  MUTANT24="$HERE/../research-sdd-install.MUTANT24.$$.sh"
  sed 's/if \[ -n "\$_deployed_old_profile" \] \&\& \[ "\$_deployed_old_profile" != "\$profile" \]; then/if false; then/' "$SUT" > "$MUTANT24"
  bash -n "$MUTANT24" 2>/dev/null \
    && ok "teeth: MUTANT24 parses (bash -n)" \
    || no "teeth: MUTANT24 is a syntax error — mutation is theater"
  if diff -q "$SUT" "$MUTANT24" >/dev/null 2>&1; then
    no "teeth: MUTANT24 pre-check: mutant = SUT — mixed-state guard not found"
  else
    ok "teeth: MUTANT24 pre-check: mutant differs (mixed-state guard disabled)"
  fi
  home_m24="$TMP/teeth-m24-mixed"
  bash "$MUTANT24" --home "$home_m24" --harness reasonix --profile general >/dev/null 2>&1
  sf_m24="$home_m24/.reasonix/skills/research-sdd/SKILL.md"
  printf '# hand-edited — a real local delta\n' >> "$sf_m24"
  bash "$MUTANT24" --home "$home_m24" --harness reasonix --profile claude >/dev/null 2>&1; rc_m24=$?
  if [ "$rc_m24" -eq 0 ]; then
    ok "teeth: MUTANT24 (guard disabled) silently exits 0 on a mixed state → item3 check has teeth"
  else
    no "teeth: MUTANT24 still exited non-zero (rc=$rc_m24) — item3 check is THEATER"
  fi

  echo "-- teeth: neuter the marker-profile validation; expect marker-validate to fail --"
  MUTANT25="$HERE/../research-sdd-install.MUTANT25.$$.sh"
  sed 's/if ! rsdd_valid_profile "\$old_profile" "\$KIT"; then/if false; then/' "$SUT" > "$MUTANT25"
  bash -n "$MUTANT25" 2>/dev/null \
    && ok "teeth: MUTANT25 parses (bash -n)" \
    || no "teeth: MUTANT25 is a syntax error — mutation is theater"
  if diff -q "$SUT" "$MUTANT25" >/dev/null 2>&1; then
    no "teeth: MUTANT25 pre-check: mutant = SUT — marker-profile validation not found"
  else
    ok "teeth: MUTANT25 pre-check: mutant differs (marker-profile validation disabled)"
  fi
  home_m25="$TMP/teeth-m25-marker"
  bash "$MUTANT25" --home "$home_m25" --harness reasonix --profile general >/dev/null 2>&1
  marker_m25="$home_m25/.reasonix/research-sdd/.installed-skill-state"
  sha_m25="$(sha256sum "$home_m25/.reasonix/skills/research-sdd/SKILL.md" | awk '{print $1}')"
  printf 'profile=not-a-real-profile\nsha256=%s\n' "$sha_m25" > "$marker_m25"
  err_m25="$(bash "$MUTANT25" --home "$home_m25" --harness reasonix --profile claude 2>&1 >/dev/null)"
  if ! printf '%s' "$err_m25" | grep -qi "invalid profile 'not-a-real-profile'"; then
    ok "teeth: MUTANT25 (validation disabled) no longer reports the invalid marker profile → marker-validate has teeth"
  else
    no "teeth: MUTANT25 still reported the invalid profile — marker-validate check is THEATER"
  fi

  echo "-- teeth: neuter the item4 launcher-skip check; expect item4 to fail --"
  MUTANT26="$HERE/../research-sdd-install.MUTANT26.$$.sh"
  sed 's/if \[ "\$_RSDD_SKILL_BLOCKED_MIXED" = 1 \]; then/if false; then/' "$SUT" > "$MUTANT26"
  bash -n "$MUTANT26" 2>/dev/null \
    && ok "teeth: MUTANT26 parses (bash -n)" \
    || no "teeth: MUTANT26 is a syntax error — mutation is theater"
  if diff -q "$SUT" "$MUTANT26" >/dev/null 2>&1; then
    no "teeth: MUTANT26 pre-check: mutant = SUT — launcher-skip check not found"
  else
    ok "teeth: MUTANT26 pre-check: mutant differs (launcher-skip check disabled)"
  fi
  home_m26="$TMP/teeth-m26-launcher-skip"
  bash "$MUTANT26" --home "$home_m26" --harness reasonix --profile general >/dev/null 2>&1
  sf_m26="$home_m26/.reasonix/skills/research-sdd/SKILL.md"
  printf '# hand-edited — a real local delta\n' >> "$sf_m26"
  launcher_m26="$home_m26/.reasonix/AGENTS.md"
  launcher_before_m26="$(cat "$launcher_m26" 2>/dev/null)"
  bash "$MUTANT26" --home "$home_m26" --harness reasonix --profile claude >/dev/null 2>&1
  launcher_after_m26="$(cat "$launcher_m26" 2>/dev/null)"
  if [ "$launcher_before_m26" != "$launcher_after_m26" ]; then
    ok "teeth: MUTANT26 (launcher-skip disabled) rewrites the launcher despite the blocked switch → item4 check has teeth"
  else
    no "teeth: MUTANT26 launcher still unchanged — item4 check is THEATER"
  fi

  echo "-- teeth: neuter the RDD R4-001 dry-run return; expect R3-dry-run-switch-warn to fail --"
  MUTANT27="$HERE/../research-sdd-install.MUTANT27.$$.sh"
  # A single, well-defined mutation: the dry-run WARN branch stops signalling BLOCKED_MIXED and
  # stops returning failure (both lines immediately after the WARN printf are dropped).
  awk '
    /printf .*a real run would ALSO refuse this profile switch/ { print; getline; print; getline; in_warn=1; next }
    in_warn && /_RSDD_SKILL_BLOCKED_MIXED=1/ { next }
    in_warn && /return 1/ { in_warn=0; next }
    { print }
  ' "$SUT" > "$MUTANT27"
  bash -n "$MUTANT27" 2>/dev/null \
    && ok "teeth: MUTANT27 parses (bash -n)" \
    || no "teeth: MUTANT27 is a syntax error — mutation is theater"
  if diff -q "$SUT" "$MUTANT27" >/dev/null 2>&1; then
    no "teeth: MUTANT27 pre-check: mutant = SUT — RDD R4-001 return not found"
  else
    ok "teeth: MUTANT27 pre-check: mutant differs (dry-run WARN no longer signals/returns failure)"
  fi
  home_m27="$TMP/teeth-m27-dryrun-warn"
  bash "$MUTANT27" --home "$home_m27" --harness reasonix --profile general >/dev/null 2>&1
  sf_m27="$home_m27/.reasonix/skills/research-sdd/SKILL.md"
  printf '# hand-edited — a real local delta\n' >> "$sf_m27"
  out_m27="$(bash "$MUTANT27" --home "$home_m27" --harness reasonix --profile claude --dry-run 2>&1)"; rc_m27=$?
  if [ "$rc_m27" -eq 0 ] || printf '%s' "$out_m27" | grep -q 'SPLICE.*AGENTS\.md'; then
    ok "teeth: MUTANT27 (return neutered) dry-run exits 0 and/or previews the launcher SPLICE again → R3-dry-run-switch-warn check has teeth"
  else
    no "teeth: MUTANT27 still refused correctly — R3-dry-run-switch-warn check is THEATER (rc=$rc_m27 out=$out_m27)"
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
