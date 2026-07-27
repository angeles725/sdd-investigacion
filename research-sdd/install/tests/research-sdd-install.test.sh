#!/usr/bin/env bash
# research-sdd-install.test.sh — RED-FIRST harness for the multi-harness kit installer.
#
# The discriminating behaviour: ONE table-driven install loop surfaces the neutral SKILL.md +
# a launcher into every harness's own paths (claude / opencode / codex), WITHOUT any per-harness
# branching in the loop. --dry-run must print a deterministic plan (locked by committed goldens);
# apply must be idempotent (re-running never duplicates the marked prompt section).
#
# Usage: research-sdd-install.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression · 2 setup.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../research-sdd-install.sh"
GOLD="$HERE/golden"
KITROOT="$(cd "$HERE/../.." && pwd)"                       # research-sdd kit root (holds toolbelt/)
PLUGSRC="$KITROOT/toolbelt/opencode/research-sdd-sweep.ts" # canonical OpenCode plugin source
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
TMP="$(mktemp -d)"; MUTANT=""; MUTANT2=""; MUTANT3=""
trap 'rm -rf "$TMP"; [ -n "$MUTANT" ] && rm -f "$MUTANT"; [ -n "$MUTANT2" ] && rm -f "$MUTANT2"; [ -n "$MUTANT3" ] && rm -f "$MUTANT3"' EXIT
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }

# Normalise a per-run tmp home to a stable placeholder so goldens are machine-independent.
norm(){ sed "s|$1|{HOME}|g"; }
# Normalise the (machine-specific) kit root so the planned plugin symlink source is portable too.
normkit(){ sed "s|$KITROOT|{KIT}|g"; }

echo "== research-sdd-install.test.sh =="

# 1..3 — dry-run plan per harness matches its committed golden (locks WHERE + WHAT is written).
for h in claude opencode codex; do
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

# 9 — opencode surfaces via markdown-sections into a fresh AGENTS.md: the launcher marker is present.
home="$TMP/fr"; bash "$SUT" --home "$home" --harness opencode >/dev/null 2>&1
grep -q '<!-- research-sdd:start -->' "$home/.config/opencode/AGENTS.md" 2>/dev/null \
  && ok "opencode markdown-sections writes the launcher into AGENTS.md" || no "opencode AGENTS.md missing the launcher marker"

# 10 — the install loop carries ZERO per-harness case arms (all divergence lives in the adapter table).
#      A case arm is a harness name at a statement boundary followed by `|` or `)` (e.g. `claude)`);
#      prose mentions like "(opencode)" in a comment are ignored.
if grep -Eq '^[[:space:]]*(claude|opencode|codex)[|)]' "$SUT"; then no "installer has a per-harness case arm (should be table-driven)"
else ok "install loop has no per-harness branching"; fi

# 11 — CRITICAL 1: opencode's AGENTS.md is the user's GLOBAL system prompt. Installing MUST splice a
#      marked section, preserving pre-existing user content, NOT truncate the whole file.
home="$TMP/oc-preserve"; mkdir -p "$home/.config/opencode"
printf '# user global prompt\nmy custom rule line\n' > "$home/.config/opencode/AGENTS.md"
bash "$SUT" --home "$home" --harness opencode >/dev/null 2>&1
pf="$home/.config/opencode/AGENTS.md"
n="$(grep -c '<!-- research-sdd:start -->' "$pf" 2>/dev/null || echo 0)"
if grep -q 'my custom rule line' "$pf" && [ "$n" = 1 ]; then ok "opencode preserves user AGENTS.md content (splice, exactly one section)"
else no "opencode clobbered user AGENTS.md (present? $(grep -qc 'my custom rule line' "$pf"; echo $?), sections=$n)"; fi

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

# 13 — CRITICAL 3: on a partial failure (one harness's config-root parent non-writable), overall exit
#      MUST be nonzero AND the still-writable harnesses must still be installed.
if [ "$(id -u)" -eq 0 ]; then ok "exit-code aggregation test skipped (running as root, chmod is a no-op)"
else
  home="$TMP/aggr"; mkdir -p "$home/.config"; chmod 000 "$home/.config"
  bash "$SUT" --home "$home" --harness all >/dev/null 2>&1; rc=$?
  chmod 755 "$home/.config"
  [ "$rc" -ne 0 ] && ok "partial failure yields nonzero overall exit" || no "partial failure silently exited 0 (rc=$rc)"
  if [ -f "$home/.claude/skills/research-sdd/SKILL.md" ] && [ -f "$home/.codex/skills/research-sdd/SKILL.md" ]; then
    ok "partial failure still installs the writable harnesses (claude + codex)"
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

# 16 — ITEM 2: --dry-run must PLAN the opencode plugin symlink (source resolved from the kit root)
#      without touching the filesystem.
home="$TMP/plug-dry"
out="$(bash "$SUT" --dry-run --home "$home" --harness opencode 2>&1)"
printf '%s\n' "$out" | grep -q "SYMLINK $home/.config/opencode/plugins/research-sdd-sweep.ts -> $PLUGSRC" \
  && ok "dry-run plans the opencode plugin symlink" || no "dry-run did not plan the plugin symlink"
[ ! -e "$home/.config/opencode/plugins/research-sdd-sweep.ts" ] \
  && ok "dry-run creates no plugin symlink" || no "dry-run created a plugin symlink"

# 17 — ITEM 2: a real opencode install creates the symlink pointing at the kit source; re-running is
#      a clean relink (idempotent, exit 0, still exactly our symlink — never a duplicate/error).
home="$TMP/plug-real"; bash "$SUT" --home "$home" --harness opencode >/dev/null 2>&1
dest="$home/.config/opencode/plugins/research-sdd-sweep.ts"
if [ -L "$dest" ] && [ "$(readlink "$dest")" = "$PLUGSRC" ]; then ok "real run creates the plugin symlink → kit source"
else no "plugin symlink missing or wrong target ($(readlink "$dest" 2>/dev/null))"; fi
bash "$SUT" --home "$home" --harness opencode >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ] && [ -L "$dest" ] && [ "$(readlink "$dest")" = "$PLUGSRC" ]; then ok "second opencode run relinks cleanly (idempotent, exit 0)"
else no "second opencode run not clean (rc=$rc, target=$(readlink "$dest" 2>/dev/null))"; fi

# 18 — ITEM 2: a pre-existing NON-symlink user file at the plugin target MUST be preserved (never
#      clobbered) and the user MUST be warned.
home="$TMP/plug-userfile"; mkdir -p "$home/.config/opencode/plugins"
printf 'user own plugin\n' > "$home/.config/opencode/plugins/research-sdd-sweep.ts"
err="$(bash "$SUT" --home "$home" --harness opencode 2>&1 >/dev/null)"
dest="$home/.config/opencode/plugins/research-sdd-sweep.ts"
if [ ! -L "$dest" ] && grep -q 'user own plugin' "$dest" && printf '%s' "$err" | grep -qi 'WARNING.*research-sdd-sweep.ts'; then
  ok "pre-existing user plugin file preserved + warned (not clobbered)"
else no "user plugin file clobbered or no warning emitted"; fi

# 19 — ITEM 3: the codex AGENTS.md notes MCP servers are REGISTERED AUTOMATICALLY into config.toml
#      (no contradictory "add it yourself / no-auto-merge" guidance); claude/opencode do NOT carry it.
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

# NEGATIVE CONTROL — neuter the idempotent splice (force blind append); two applies must then
# leave TWO marked sections, proving test 6's idempotency assertion has teeth.
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: neuter the marker-aware splice, expect duplicate sections on re-apply --"
  # Live beside the real SUT so the mutant still resolves adapters.sh + the kit's source SKILL.md.
  MUTANT="$HERE/../research-sdd-install.MUTANT.$$.sh"
  # Break the "does the file already carry our marker?" guard so splice always appends.
  sed 's/grep -Fq -- "\$start" "\$file"/false/' "$SUT" > "$MUTANT"
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
  home="$TMP/teeth-orphan"; mkdir -p "$home/.codex"
  printf '# research-sdd:start\n[mcp_servers.engram]\ncommand = "engram"\nargs = ["mcp", "--tools=agent"]\n\n[mcp_servers.codegraph]\ncommand = "codegraph"\nargs = ["serve", "--mcp"]\n' \
    > "$home/.codex/config.toml"
  bash "$MUTANT3" --home "$home" --harness codex >/dev/null 2>&1
  n="$(grep -c '\[mcp_servers.engram\]' "$home/.codex/config.toml" 2>/dev/null || echo 0)"
  [ "$n" -ge 2 ] && ok "teeth: orphan-skip-less mutant duplicates [mcp_servers.engram] → orphan-skip has teeth" \
    || no "teeth: mutant did not duplicate ($n) — orphan-skip check is THEATER"
fi

# 27 — DATA-LOSS REGRESSION: installing over a DIVERGED deployed SKILL.md must NOT clobber it.
#      The installer must preserve the deployed file and emit a WARNING naming the file.
#      (Regression guard for the unconditional `cp` bug that destroyed retro-applied deltas.)
home="$TMP/skill-diverge"; mkdir -p "$home/.config/opencode/skills/research-sdd"
printf '# custom deployed content — not kit source\nOpenCode runtime adapter\n' \
  > "$home/.config/opencode/skills/research-sdd/SKILL.md"
err="$(bash "$SUT" --home "$home" --harness opencode 2>&1 >/dev/null)"
sf="$home/.config/opencode/skills/research-sdd/SKILL.md"
if grep -q 'custom deployed content' "$sf" && printf '%s' "$err" | grep -qi 'WARNING.*SKILL\.md'; then
  ok "SKILL.md diverged: deployed file preserved and warned (data-loss regression fixed)"
else
  no "SKILL.md diverged: deployed file was CLOBBERED (DATA LOSS — defining regression)"
fi

# 28 — SKILL.md identical to kit source: no spurious warning (clean silent no-op).
home="$TMP/skill-identical"
bash "$SUT" --home "$home" --harness opencode >/dev/null 2>&1         # first install
err="$(bash "$SUT" --home "$home" --harness opencode 2>&1 >/dev/null)" # second run on identical
if printf '%s' "$err" | grep -qi 'WARNING.*SKILL\.md'; then
  no "SKILL.md identical: spurious WARNING emitted (no-op should be silent)"
else
  ok "SKILL.md identical: no warning on identical file (clean silent no-op)"
fi

# 29 — opencode SKILL.md fresh install uses the harness-specific source (toolbelt/opencode/SKILL.md),
#      which carries the OpenCode runtime adapter section absent from the generic skills/ source.
home="$TMP/skill-fresh-oc"
bash "$SUT" --home "$home" --harness opencode >/dev/null 2>&1
sf="$home/.config/opencode/skills/research-sdd/SKILL.md"
if [ -f "$sf" ] && grep -q 'OpenCode runtime adapter' "$sf"; then
  ok "opencode SKILL.md fresh install: harness-specific source (with OpenCode adapter) used"
else
  no "opencode SKILL.md fresh install: missing OpenCode adapter content (wrong source used)"
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
