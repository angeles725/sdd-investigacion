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
TMP="$(mktemp -d)"; MUTANT=""; MUTANT2=""; MUTANT3=""; MUTANT4=""; MUTANT5=""; MUTANT6=""; MUTANT7=""
trap 'rm -rf "$TMP"; [ -n "$MUTANT" ] && rm -f "$MUTANT"; [ -n "$MUTANT2" ] && rm -f "$MUTANT2"; [ -n "$MUTANT3" ] && rm -f "$MUTANT3"; [ -n "$MUTANT4" ] && rm -f "$MUTANT4"; [ -n "$MUTANT5" ] && rm -f "$MUTANT5"; [ -n "$MUTANT6" ] && rm -f "$MUTANT6"; [ -n "$MUTANT7" ] && rm -f "$MUTANT7"' EXIT
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

# 31 — dry-run on an IDENTICAL deployed skill prints [up-to-date], not a plain INSTALL.
#      The §7 three-state rule applied to the plan: identical state must be distinguishable from absent.
home="$TMP/dryrun-identical"
bash "$SUT" --home "$home" --harness opencode >/dev/null 2>&1              # seed: real install
out="$(bash "$SUT" --dry-run --home "$home" --harness opencode 2>&1)"      # second run: identical
if printf '%s\n' "$out" | grep -q 'INSTALL.*\[up-to-date\]'; then
  ok "dry-run identical: shows [up-to-date] (absent vs identical distinguishable)"
else no "dry-run identical: missing [up-to-date] (got: $(printf '%s\n' "$out" | grep INSTALL || true))"; fi

# 32 — dry-run on a DIVERGED deployed skill prints SKIP and names --force-skill as the remedy.
#      The plan must not promise an install it will then refuse to perform.
home="$TMP/dryrun-diverged"; mkdir -p "$home/.config/opencode/skills/research-sdd"
printf '# custom deployed content — not kit source\n' > "$home/.config/opencode/skills/research-sdd/SKILL.md"
out="$(bash "$SUT" --dry-run --home "$home" --harness opencode 2>&1)"
if printf '%s\n' "$out" | grep -q 'INSTALL.*SKIP.*--force-skill'; then
  ok "dry-run diverged: shows SKIP and names --force-skill remedy"
else no "dry-run diverged: plan wrong (got: $(printf '%s\n' "$out" | grep INSTALL || true))"; fi
[ ! -f "$home/.config/opencode/skills/research-sdd/SKILL.md.local-backup" ] \
  && ok "dry-run diverged: no backup created" \
  || no "dry-run diverged: backup created unexpectedly"

# 33 — dry-run on a NOT-READABLE deployed skill prints SKIP (not INSTALL), naming permissions.
#      Mirrors the real-run guard at line ~228 so the plan and real behavior agree.
if [ "$(id -u)" -eq 0 ]; then
  ok "dry-run unreadable SKILL.md check skipped (running as root — chmod 000 is a no-op)"
else
  home="$TMP/dryrun-unreadable"; mkdir -p "$home/.config/opencode/skills/research-sdd"
  printf '# some content\n' > "$home/.config/opencode/skills/research-sdd/SKILL.md"
  chmod 000 "$home/.config/opencode/skills/research-sdd/SKILL.md"
  out="$(bash "$SUT" --dry-run --home "$home" --harness opencode 2>&1)"
  chmod 644 "$home/.config/opencode/skills/research-sdd/SKILL.md"
  if printf '%s\n' "$out" | grep -q 'INSTALL.*SKIP.*not readable'; then
    ok "dry-run unreadable: shows SKIP for permissions issue (not a plain INSTALL)"
  else no "dry-run unreadable: wrong plan (got: $(printf '%s\n' "$out" | grep INSTALL || true))"; fi
fi

# 34 — --force-skill overwrites a diverged SKILL.md after backing it up to <path>.local-backup.
#      The backup must contain the original content so the operator can recover any deltas.
home="$TMP/force-overwrite"; mkdir -p "$home/.config/opencode/skills/research-sdd"
printf '# custom local content — NOT kit source\nmy local delta\n' \
  > "$home/.config/opencode/skills/research-sdd/SKILL.md"
bash "$SUT" --force-skill --home "$home" --harness opencode >/dev/null 2>&1
sf="$home/.config/opencode/skills/research-sdd/SKILL.md"
bak_fo="$home/.config/opencode/skills/research-sdd/SKILL.md.local-backup"
if grep -q 'OpenCode runtime adapter' "$sf"; then
  ok "--force-skill installs kit source over diverged SKILL.md"
else no "--force-skill did not install kit source (still diverged or missing)"; fi
if [ -f "$bak_fo" ] && grep -q 'my local delta' "$bak_fo"; then
  ok "--force-skill backs up diverged content before overwriting"
else no "--force-skill backup missing or does not contain original content"; fi

# 35 — --force-skill + --dry-run plans the overwrite (with backup path) but writes nothing.
#      Exercises the compose requirement: force and dry-run must compose cleanly.
home="$TMP/force-dry"; mkdir -p "$home/.config/opencode/skills/research-sdd"
printf '# custom\n' > "$home/.config/opencode/skills/research-sdd/SKILL.md"
out="$(bash "$SUT" --force-skill --dry-run --home "$home" --harness opencode 2>&1)"
sf="$home/.config/opencode/skills/research-sdd/SKILL.md"
bak_fd="$home/.config/opencode/skills/research-sdd/SKILL.md.local-backup"
if printf '%s\n' "$out" | grep -q 'INSTALL.*will overwrite.*backup'; then
  ok "--force-skill + dry-run: plans overwrite and names backup path"
else no "--force-skill + dry-run: plan wrong (got: $(printf '%s\n' "$out" | grep INSTALL || true))"; fi
if grep -q '# custom' "$sf" && [ ! -f "$bak_fd" ]; then
  ok "--force-skill + dry-run: writes nothing (file unchanged, no backup created)"
else no "--force-skill + dry-run: mutated the filesystem"; fi

# 36 — --help range integrity: correct first and last lines, --force-skill present, set -uo absent.
#      Catches all four ±1 drift directions on the hardcoded sed range in usage():
#        3,17p → last rendered line is NOT the Idempotent tail (fails "opencode's" check)
#        3,19p → "set -uo pipefail" appears in output (fails pipefail-absent check)
#        4,18p → first rendered line is NOT empty (fails empty-first-line check)
#        2,18p → first rendered line is NOT empty (fails empty-first-line check)
help_out="$(bash "$SUT" --help 2>&1)"
help_first="$(printf '%s\n' "$help_out" | head -1)"
help_last="$(printf '%s\n' "$help_out" | grep . | tail -1)"
help_ok=1
printf '%s\n' "$help_out" | grep -q -- '--force-skill'     || help_ok=0  # line 14 in range
printf '%s\n' "$help_out" | grep -q 'set -uo pipefail' && help_ok=0      # must stay outside range
[ -z "$help_first" ]                                       || help_ok=0  # line 3 is bare '#'
printf '%s\n' "$help_last" | grep -q "opencode's"          || help_ok=0  # last content line = 18
[ "$help_ok" = 1 ] \
  && ok "--help: range correct (--force-skill present, no pipefail, first/last lines match)" \
  || no "--help: range wrong (force-skill=$(printf '%s\n' "$help_out"|grep -c -- '--force-skill'), pipefail=$(printf '%s\n' "$help_out"|grep -c 'pipefail'), first='$help_first', last='$help_last')"

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
home="$TMP/force-bak-exists"; mkdir -p "$home/.config/opencode/skills/research-sdd"
printf '# diverged content\nDELTA-1\n' > "$home/.config/opencode/skills/research-sdd/SKILL.md"
printf '# stale backup — contains deltas\n' > "$home/.config/opencode/skills/research-sdd/SKILL.md.local-backup"
err_b1="$(bash "$SUT" --force-skill --home "$home" --harness opencode 2>&1 >/dev/null)"; rc_b1=$?
sf_b1="$home/.config/opencode/skills/research-sdd/SKILL.md"
bak_b1="$home/.config/opencode/skills/research-sdd/SKILL.md.local-backup"
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
home="$TMP/force-dry-bak"; mkdir -p "$home/.config/opencode/skills/research-sdd"
printf '# diverged content\n' > "$home/.config/opencode/skills/research-sdd/SKILL.md"
printf '# stale backup\n' > "$home/.config/opencode/skills/research-sdd/SKILL.md.local-backup"
out="$(bash "$SUT" --force-skill --dry-run --home "$home" --harness opencode 2>&1)"
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
mkdir -p "$home/.config/opencode/skills/research-sdd/SKILL.md"  # SKILL.md is a directory
out="$(bash "$SUT" --dry-run --home "$home" --harness opencode 2>&1)"
sf_dir="$home/.config/opencode/skills/research-sdd/SKILL.md"
if printf '%s\n' "$out" | grep -q 'INSTALL.*SKIP.*not a regular file'; then
  ok "dir-at-dest dry-run: shows SKIP when skill_path is a directory"
else no "dir-at-dest dry-run: wrong plan (got: $(printf '%s\n' "$out" | grep INSTALL || true))"; fi
err_dir="$(bash "$SUT" --home "$home" --harness opencode 2>&1 >/dev/null)"
if [ -d "$sf_dir" ] && ! [ -f "$sf_dir/SKILL.md" ] \
   && printf '%s' "$err_dir" | grep -qi 'WARNING.*not a regular file'; then
  ok "dir-at-dest real run: directory preserved, warned, no file created inside"
else no "dir-at-dest real run: wrong behavior (is dir? $([ -d "$sf_dir" ] && echo yes || echo no), inner-file? $([ -f "$sf_dir/SKILL.md" ] && echo yes || echo no))"; fi

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
  home="$TMP/teeth-dryrun-diverged"; mkdir -p "$home/.config/opencode/skills/research-sdd"
  printf '# custom deployed content\n' > "$home/.config/opencode/skills/research-sdd/SKILL.md"
  out_m4="$(bash "$MUTANT4" --dry-run --home "$home" --harness opencode 2>&1)"
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
  sed 's/elif ! cp "\$skill_path" "\$bak"; then/elif false; then/' "$SUT" > "$MUTANT5"
  bash -n "$MUTANT5" 2>/dev/null \
    && ok "teeth: MUTANT5 parses (bash -n)" \
    || no "teeth: MUTANT5 is a syntax error — mutation is theater"
  home="$TMP/teeth-force-backup"; mkdir -p "$home/.config/opencode/skills/research-sdd"
  printf '# custom local content\nmy local delta\n' > "$home/.config/opencode/skills/research-sdd/SKILL.md"
  bash "$MUTANT5" --force-skill --home "$home" --harness opencode >/dev/null 2>&1
  bak_t5="$home/.config/opencode/skills/research-sdd/SKILL.md.local-backup"
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
  home_m6="$TMP/teeth-b1-exists"; mkdir -p "$home_m6/.config/opencode/skills/research-sdd"
  printf '# diverged\nDELTA-1\n' > "$home_m6/.config/opencode/skills/research-sdd/SKILL.md"
  printf '# stale backup — DELTA-1 only copy\n' > "$home_m6/.config/opencode/skills/research-sdd/SKILL.md.local-backup"
  bash "$MUTANT6" --force-skill --home "$home_m6" --harness opencode >/dev/null 2>&1; rc_m6=$?
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
    sed 's/elif \[ ! -r "\$src_skill" \]; then/elif false; then/g' "$SUT" > "$MUTANT7"
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

# 30 — SKILL.md not readable (chmod 000): warns about permissions, not diverged content.
#      A mode-000 destination must produce a "not readable" WARNING, not the "diverged content"
#      WARNING, so the operator diagnoses the real cause (permissions, not a content conflict).
if [ "$(id -u)" -eq 0 ]; then
  ok "SKILL.md unreadable check skipped (running as root — chmod 000 is a no-op)"
else
  home="$TMP/skill-unreadable"; mkdir -p "$home/.config/opencode/skills/research-sdd"
  sf="$home/.config/opencode/skills/research-sdd/SKILL.md"
  printf '# content distinct from kit source\n' > "$sf"
  chmod 000 "$sf"
  err="$(bash "$SUT" --home "$home" --harness opencode 2>&1 >/dev/null)"
  chmod 644 "$sf"
  if printf '%s' "$err" | grep -qi 'WARNING.*not readable' && ! printf '%s' "$err" | grep -qi 'diverged'; then
    ok "SKILL.md unreadable (chmod 000): warns about permissions, not diverged content"
  else
    no "SKILL.md unreadable (chmod 000): wrong or missing warning (expected 'not readable', got: [$err])"
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
