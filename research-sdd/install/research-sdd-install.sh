#!/usr/bin/env bash
# research-sdd-install.sh — kit-owned, pure-bash multi-harness installer.
#
# Surfaces the single neutral asset (skills/research-sdd/SKILL.md) + a thin launcher into every AI
# harness's OWN paths by iterating the adapter table in adapters.sh. The loop body has ZERO
# per-harness `if`/`case`: WHERE/HOW/WHAT all come from the table, so a 4th harness is one table row.
#
# Usage:
#   research-sdd-install.sh [--harness claude|opencode|codex|all] [--home <dir>] [--dry-run] [--force-skill]
#
#   --harness     which harness(es) to install into (default: all, in registration order)
#   --home        the home dir whose config roots are targeted (default: $HOME)
#   --dry-run     print the exact plan (files + rendered section) WITHOUT touching the filesystem
#   --force-skill when the deployed SKILL.md has diverged, back it up and overwrite with the kit source
#
# Idempotent: re-running is a clean update, never a duplicate. markdown-sections splices a marked
# block into a SHARED prompt file, preserving all surrounding user content (including the harness's
# own global system prompt, e.g. opencode's ~/.config/opencode/AGENTS.md).
set -uo pipefail

SELF="$(cd "$(dirname "$0")" && pwd)"
KIT="$(cd "$SELF/.." && pwd)"
# shellcheck source=adapters.sh
. "$SELF/adapters.sh"

usage() { sed -n '3,18p' "$SELF/$(basename "$0")" | sed 's/^# \{0,1\}//'; }

# --- prompt-surfacing strategies: dispatched by the STRATEGY VALUE, never by harness name ----------
# Each prints its plan line(s) + the rendered section, then (unless dry) performs the write.
emit_section() { printf '%s\n' "$1" | sed 's/^/  | /'; }

# Write $tmp back onto $file. A symlinked target is written THROUGH (link + real target preserved);
# a regular file is replaced atomically via mv. Returns nonzero on any write failure.
_rsdd_write_back() {
  local tmp="$1" file="$2"
  if [ -L "$file" ]; then
    # `> "$file"` follows the link and truncates its TARGET, so the symlink itself survives and the
    # real file it points at is updated in place — never severed into a plain file.
    if cat "$tmp" > "$file"; then rm -f "$tmp"; else rm -f "$tmp"; return 1; fi
  else
    mv -f "$tmp" "$file"
  fi
}

# Append the marked $section onto the preserved-content file $tmp with EXACTLY ONE blank-line
# separator between prior content and the section — and NO leading blank line when the preserved
# content is empty (brand-new / fully-removed file). Command substitution strips trailing newlines,
# so any number of pre-existing trailing blanks collapses to one deterministic separator, keeping
# BOTH the fresh-append and the re-splice paths byte-identical and idempotent across re-runs.
_rsdd_append_section() {
  local tmp="$1" section="$2" body
  body="$(cat "$tmp")"
  if [ -n "$body" ]; then
    printf '%s\n\n%s\n' "$body" "$section" > "$tmp"
  else
    printf '%s\n' "$section" > "$tmp"
  fi
}

# Symlink the kit's OpenCode session-start plugin into the harness plugin dir. Idempotent: an existing
# symlink is refreshed (clean relink, never duplicated); a NON-symlink already at the target is the
# user's own file and is preserved (warn + skip, never clobbered). No-op under --dry-run, but the plan
# still prints the intended link. $src is resolved from the kit root, independent of the CWD.
_rsdd_link_plugin() {
  local plugin_dir="$1" dry="$2" src="$3" dest
  dest="$plugin_dir/$(basename "$src")"
  printf '  SYMLINK %s -> %s\n' "$dest" "$src"
  [ "$dry" = 1 ] && return 0
  [ -e "$src" ] || { echo "research-sdd-install: plugin source not found: $src" >&2; return 1; }
  mkdir -p "$plugin_dir" || { echo "research-sdd-install: mkdir failed for $plugin_dir" >&2; return 1; }
  if [ -L "$dest" ]; then
    ln -sfn "$src" "$dest" || { echo "research-sdd-install: relink failed for $dest" >&2; return 1; }
  elif [ -e "$dest" ]; then
    printf 'research-sdd-install: WARNING %s exists and is not our symlink — preserved (skipped plugin link)\n' "$dest" >&2
  else
    ln -s "$src" "$dest" || { echo "research-sdd-install: symlink failed for $dest" >&2; return 1; }
  fi
}

# _rsdd_splice_file — the ONE marked-section splice, shared by every leg that writes into a SHARED
# user-owned file. Marker STRINGS are parameters, so it serves both the markdown prompt files
# (HTML-comment markers) and the codex config.toml (TOML `#`-comment markers) with a single
# implementation. It splices our marked block, preserving everything else. The rewrite removes ONLY a
# well-formed $start..$end pair (no nested start between them).
#
# $on_orphan selects how an ORPHANED start marker (no matching end, or a second start before the end —
# a hand-edited/partial file) is handled — the ONE place the two callers diverge:
#   append (default, markdown prompt files): the orphan is treated as user content — PRESERVED verbatim
#     and a fresh section appended, never truncated (markdown has no duplicate-table rule, so dropping
#     trailing user content is the real risk).
#   skip (config.toml / MCP path): our block declares [mcp_servers.*] TABLES, and the preserved orphan
#     already carries those same tables — appending would yield DUPLICATE tables (illegal TOML that
#     fails to parse). Neither duplicating nor dropping user content is acceptable, so we WARN and SKIP
#     entirely (exit 0, file left byte-for-byte untouched); registration resumes once the marker is
#     repaired. Same splice engine, one divergent knob — no forked logic.
#
# $label names the marker style in the plan line. When $conflict (an ERE) is non-empty, an UNMARKED
# line in the preserved content matching it — a user-authored table we must NOT duplicate — aborts the
# splice with a warn+skip (exit 0, file left byte-for-byte untouched). No-op under --dry-run, but the
# plan still prints the intended write. Symlink targets are written THROUGH (link preserved); an
# unwritable target surfaces a write failure (nonzero).
_rsdd_splice_file() {
  local file="$1" dry="$2" start="$3" end="$4" label="$5" section="$6" conflict="${7:-}" on_orphan="${8:-append}" orphan_skip_reason="${9:-a duplicate TOML table}"
  printf '  SPLICE  %s  [%s]\n' "$file" "$label"
  emit_section "$section"
  [ "$dry" = 1 ] && return 0
  mkdir -p "$(dirname "$file")" || { echo "research-sdd-install: mkdir failed for $(dirname "$file")" >&2; return 1; }
  # Build the preserved content in $tmp, then append the fresh section via the ONE separator-aware
  # helper — so the re-splice (rewrite) path and the fresh-append path insert an identical single
  # blank-line separator, and a brand-new empty file gets no leading blank line.
  # $tmp holds the full preserved content (what we write back); $scan holds ONLY genuine user content —
  # lines OUTSIDE every research-sdd marker region — which is all the duplicate guard may inspect. When
  # no marker exists the whole file IS user content, so $scan defaults to $tmp; with a marker present the
  # awk streams only the outside-marker lines into a dedicated $scan file (never a preserved orphan tail).
  local tmp scan; tmp="$(mktemp)" || return 1; scan="$tmp"
  if [ -f "$file" ] && grep -Fq -- "$start" "$file"; then
    scan="$(mktemp)" || { rm -f "$tmp"; return 1; }
    local aw
    # Remove the FIRST well-formed start..end pair; keep every other line verbatim. If a start has no
    # matching end (orphan), flush it back out and signal via exit 3 so we can warn (exit 0 = clean).
    # Markers are matched by EXACT line equality (they are rendered as whole lines), so marker text
    # containing regex-special characters (e.g. `[`/`.`) is compared literally, never as a pattern.
    # Genuine outside-marker user lines are ALSO streamed to $scan (the ONLY duplicate-guard input); the
    # orphan buffer is flushed to $tmp only, so a preserved remnant of OUR OWN block never self-trips it.
    awk -v start="$start" -v end="$end" -v scan="$scan" '
      BEGIN { done=0; inblk=0; orphan=0 }
      {
        if (!done && !inblk && $0 == start) { inblk=1; buf=$0 ORS; next }
        if (inblk) {
          if ($0 == start) { printf "%s", buf; orphan=1; buf=$0 ORS; next }
          if ($0 == end)   { inblk=0; done=1; buf=""; next }
          buf=buf $0 ORS; next
        }
        print; print > scan
      }
      END { if (inblk) { printf "%s", buf; orphan=1 } exit (orphan?3:0) }
    ' "$file" > "$tmp"; aw=$?
    if [ "$aw" = 3 ]; then
      if [ "$on_orphan" = skip ]; then
        # TOML path: appending would duplicate the [mcp_servers.*] tables the orphan already carries
        # (illegal TOML). Drop our staged $tmp, leave the real file byte-for-byte untouched, and skip.
        rm -f "$tmp"; [ "$scan" != "$tmp" ] && rm -f "$scan"
        printf 'research-sdd-install: WARNING malformed research-sdd marker in %s (start without matching end) — skipped MCP registration to avoid %s; repair the stray marker and re-run\n' "$file" "$orphan_skip_reason" >&2
        return 0
      fi
      printf 'research-sdd-install: WARNING malformed research-sdd marker in %s (start without matching end) — preserved existing content and appended a fresh section; please remove the stray marker\n' "$file" >&2
    fi
  elif [ -f "$file" ]; then
    # No marker yet: preserve all existing user content verbatim, then append the section below it.
    cat "$file" > "$tmp" || { rm -f "$tmp"; echo "research-sdd-install: read failed for $file" >&2; return 1; }
  else
    : > "$tmp"  # brand-new file: section only, no leading blank line.
  fi
  # Duplicate guard: with our managed block stripped, if the remaining GENUINE user content ($scan, never
  # a preserved orphan remnant of our own block) already declares a table our block would define,
  # appending would create a duplicate table (invalid TOML). Preserve the user's config verbatim and
  # skip — a deliberate no-op, not an install failure.
  if [ -n "$conflict" ] && grep -Eq "$conflict" "$scan"; then
    rm -f "$tmp"; [ "$scan" != "$tmp" ] && rm -f "$scan"
    printf 'research-sdd-install: WARNING %s already defines a research-sdd MCP table outside our managed block — preserved your config, skipped MCP registration (remove your table or leave it to the installer)\n' "$file" >&2
    return 0
  fi
  [ "$scan" != "$tmp" ] && rm -f "$scan"
  _rsdd_append_section "$tmp" "$section"
  _rsdd_write_back "$tmp" "$file" || { echo "research-sdd-install: write failed for $file" >&2; return 1; }
}

# markdown-sections: the prompt file is SHARED — splice our marked block (HTML-comment markers),
# preserving everything else. Thin wrapper over the generic splice; no duplicate-table guard needed.
_surface__markdown_sections() {
  local harness="$1" home="$2" file="$3" dry="$4" section
  section="$(rsdd_render_section "$harness" "$home")" || return 2
  _rsdd_splice_file "$file" "$dry" \
    '<!-- research-sdd:start -->' '<!-- research-sdd:end -->' \
    'markdown-sections: marker <!-- research-sdd:start/end -->' "$section"
}

# _rsdd_mcp_conflict_ere <shape> — emit the ERE that detects a user-authored (unmarked) MCP entry
# in the preserved config that our managed block would duplicate or shadow. Shape-dispatched so the
# correct detection logic is used without branching on harness name.
#
# mcp-servers-table (codex): best-effort duplicate-TABLE guard (no full TOML parser).
#   DETECTS: canonical bracket header `[mcp_servers.engram]` with optional internal whitespace, AND
#     the inline dotted-key assignment `mcp_servers.engram = { ... }`.
#   DOES NOT DETECT: exotic nested-inline forms (e.g. `engram = {...}` nested under a bare
#     [mcp_servers] header, or multiline dotted paths) — a full-TOML-parse merge is a deliberate
#     follow-up. On a suspected conflict the installer warns+skips rather than corrupt the file.
#
# plugins-array (reasonix): LINE-WISE DETECTION ONLY.
#   DETECTS: `name = "engram"`, `name = 'engram'`, `name="engram"` (bare equality, optional
#     whitespace, single or double quotes) — the forms reasonix uses for [[plugins]] entries.
#   DOES NOT DETECT: the `name` key split across lines, name in a multiline-continued form, or
#     whether the `name` key is inside a [[plugins]] block (TOML has no line-level block association).
#   FALSE POSITIVES: a `name = "engram"` key outside a [[plugins]] block is treated as a conflict
#     (warn+skip). This is intentional — a false positive is safer than silently shadowing a user
#     entry, because reasonix's [[plugins]] last-wins de-duplication produces no warning at all.
_rsdd_mcp_conflict_ere() {
  local shape="$1"
  case "$shape" in
    mcp-servers-table)
      printf '%s' '^[[:space:]]*\[[[:space:]]*mcp_servers[[:space:]]*\.[[:space:]]*(engram|codegraph)[[:space:]]*\][[:space:]]*$|^[[:space:]]*mcp_servers[[:space:]]*\.[[:space:]]*(engram|codegraph)[[:space:]]*='
      ;;
    plugins-array)
      printf '%s' '^[[:space:]]*name[[:space:]]*=[[:space:]]*["'"'"'](engram|codegraph)["'"'"']'
      ;;
    *)
      printf 'research-sdd-install: _rsdd_mcp_conflict_ere: unknown shape "%s"\n' "$shape" >&2
      return 2
      ;;
  esac
}

# MCP registration: idempotently splice the skill's MCP-server entries into the harness's shared
# config.toml, guarded so a user-authored (unmarked) entry is never duplicated or silently shadowed.
# Shape-dispatched: codex uses [mcp_servers.*] named tables; reasonix uses [[plugins]] array-of-tables.
# Same splice engine as the prompt files; only the markers (TOML `#`-comment), the conflict ERE, and
# the orphan mode (skip, not append — duplicate entries corrupt or silently override) differ.
_rsdd_register_mcp() {
  local file="$1" dry="$2" shape="$3" section conflict orphan_reason
  section="$(rsdd_render_mcp_toml "$shape")"
  # on_orphan=skip: unlike markdown prompt files, an orphaned marker here must NOT append a fresh
  # block — doing so would produce a second entry that the harness silently resolves (last wins),
  # discarding the user's config without warning. Warn + skip; file left byte-for-byte untouched.
  conflict="$(_rsdd_mcp_conflict_ere "$shape")" || return 2
  # Shape-specific orphan reason: mcp-servers-table → TOML parser rejects duplicate named tables;
  # plugins-array → duplicate [[plugins]] is valid TOML but reasonix silently picks last-entry-wins,
  # discarding the user's entry with no warning — a different risk, a different explanation.
  case "$shape" in
    mcp-servers-table) orphan_reason="a duplicate TOML table" ;;
    plugins-array)     orphan_reason="last-wins shadowing (reasonix de-duplicates [[plugins]] by name, last entry wins silently)" ;;
    *)                 orphan_reason="a duplicate entry" ;;
  esac
  _rsdd_splice_file "$file" "$dry" \
    '# research-sdd:start' '# research-sdd:end' \
    'toml-sections: marker # research-sdd:start/end' "$section" \
    "$conflict" \
    skip \
    "$orphan_reason"
}

# --- the ONE install loop body — table-driven, no per-harness branching --------------------------
install_one() {
  local h="$1" home="$2" dry="$3" force="$4" rc=0
  local skill_path prompt_file strategy plugin_dir mcp_config slash dispatch src_relkit src_skill bak
  skill_path="$(rsdd_field "$h" skill_path "$home")"
  prompt_file="$(rsdd_field "$h" prompt_file "$home")"
  strategy="$(rsdd_field "$h" prompt_strategy "$home")"
  plugin_dir="$(rsdd_field "$h" plugin_dir "$home")"
  mcp_config="$(rsdd_field "$h" mcp_config_file "$home")"
  slash="$(rsdd_field "$h" supports_slash_commands "$home")"
  src_relkit="$(rsdd_field "$h" skill_src_relkit)"
  src_skill="$KIT/$src_relkit"

  printf 'harness=%s\n' "$h"

  # 1. harness-specific asset → this harness's skills dir (source resolved from the adapter table,
  #    never branched on harness name). Dry-run classifies the deployed skill state (§7 three-state
  #    rule) and prints what WILL happen. Real run: identical → silent no-op; diverged → warn+skip
  #    unless --force-skill, which backs up the existing file and overwrites with the kit source.
  #    WHY preserve by default: the deployed SKILL.md can carry retro-applied deltas written directly
  #    into it; an unconditional overwrite would silently destroy that knowledge.
  #    States handled (both branches keep them distinguishable — CLAUDE.md §7):
  #      source not found / not readable → [SKIP]; source-unreadable must be caught BEFORE cmp -s
  #        (cmp -s exits 2 = "trouble" on an unreadable file, which reads as "differs" — wrong diagnosis)
  #      dest is not a regular file (e.g. a directory) → [SKIP]; caught BEFORE cp would descend into it
  #      dest not readable → [SKIP]; dest identical → no-op; dest diverged → warn+skip or force
  #      --force-skill + existing backup → refuse (rc=1); backup may be the only copy of past deltas
  if [ "$dry" = 1 ]; then
    # Print what the real run will ACTUALLY do — distinguishable states (CLAUDE.md §7).
    if [ ! -f "$src_skill" ]; then
      printf '  INSTALL %s (from kit %s) [SKIP — source SKILL not found]\n' "$skill_path" "$src_relkit"
    elif [ ! -r "$src_skill" ]; then
      printf '  INSTALL %s (from kit %s) [SKIP — source SKILL not readable; check permissions]\n' "$skill_path" "$src_relkit"
    elif [ -e "$skill_path" ] && [ ! -f "$skill_path" ]; then
      printf '  INSTALL %s (from kit %s) [SKIP — destination is not a regular file; remove it and re-run]\n' "$skill_path" "$src_relkit"
    elif [ -f "$skill_path" ] && [ ! -r "$skill_path" ]; then
      printf '  INSTALL %s (from kit %s) [SKIP — not readable; check permissions]\n' "$skill_path" "$src_relkit"
    elif [ -f "$skill_path" ] && cmp -s "$src_skill" "$skill_path"; then
      printf '  INSTALL %s (from kit %s) [up-to-date]\n' "$skill_path" "$src_relkit"
    elif [ -f "$skill_path" ] && [ "$force" = 1 ]; then
      if [ -e "$skill_path.local-backup" ]; then
        printf '  INSTALL %s (from kit %s) [SKIP — backup %s already exists; rename or remove it first]\n' "$skill_path" "$src_relkit" "$skill_path.local-backup"
      else
        printf '  INSTALL %s (from kit %s) [will overwrite; backup → %s]\n' "$skill_path" "$src_relkit" "$skill_path.local-backup"
      fi
    elif [ -f "$skill_path" ]; then
      printf '  INSTALL %s (from kit %s) [SKIP — diverged; use --force-skill to overwrite]\n' "$skill_path" "$src_relkit"
    else
      printf '  INSTALL %s (from kit %s)\n' "$skill_path" "$src_relkit"
    fi
  else
    printf '  INSTALL %s (from kit %s)\n' "$skill_path" "$src_relkit"
    if [ ! -f "$src_skill" ]; then
      echo "research-sdd-install: [$h] source SKILL not found: $src_skill" >&2; rc=1
    elif [ ! -r "$src_skill" ]; then
      echo "research-sdd-install: [$h] source SKILL not readable: $src_skill" >&2; rc=1
    elif ! mkdir -p "$(dirname "$skill_path")"; then
      echo "research-sdd-install: [$h] mkdir failed for $(dirname "$skill_path")" >&2; rc=1
    elif [ -e "$skill_path" ] && [ ! -f "$skill_path" ]; then
      printf 'research-sdd-install: WARNING %s exists but is not a regular file — skipped (remove it and re-run)\n' "$skill_path" >&2
    elif [ -f "$skill_path" ] && [ ! -r "$skill_path" ]; then
      printf 'research-sdd-install: WARNING %s exists but is not readable (check permissions) — local content kept\n' "$skill_path" >&2
    elif [ -f "$skill_path" ] && cmp -s "$src_skill" "$skill_path"; then
      : # byte-identical — silent no-op (idempotent re-run)
    elif [ -f "$skill_path" ] && [ "$force" = 1 ]; then
      bak="$skill_path.local-backup"
      if [ -e "$bak" ]; then
        # Refuse: the backup may be the ONLY copy of deltas from a prior --force-skill run.
        # The operator resolves this by hand (rename or remove), keeping the decision explicit.
        printf 'research-sdd-install: ERROR %s already exists — rename or remove it before re-running --force-skill (it may contain deltas you have not merged)\n' "$bak" >&2
        rc=1
      elif ! cp "$skill_path" "$bak"; then
        echo "research-sdd-install: [$h] backup failed → $bak" >&2; rc=1
      elif ! cp "$src_skill" "$skill_path"; then
        echo "research-sdd-install: [$h] cp failed → $skill_path" >&2; rc=1
      else
        printf '  BACKUP  %s → %s\n' "$skill_path" "$bak"
      fi
    elif [ -f "$skill_path" ]; then
      printf 'research-sdd-install: WARNING %s exists with diverged content — local content kept (use --force-skill to overwrite, or delete to reinstall)\n' "$skill_path" >&2
    elif ! cp "$src_skill" "$skill_path"; then
      echo "research-sdd-install: [$h] cp failed → $skill_path" >&2; rc=1
    fi
  fi

  # 2. launcher → this harness's prompt file, via the strategy the TABLE named (data, not a branch)
  dispatch="_surface__${strategy//-/_}"
  if ! declare -F "$dispatch" >/dev/null; then
    echo "research-sdd-install: [$h] no surfacing strategy '$strategy'" >&2; return 2
  fi
  if ! "$dispatch" "$h" "$home" "$prompt_file" "$dry"; then
    echo "research-sdd-install: [$h] surfacing launcher failed ($prompt_file)" >&2; rc=1
  fi

  # 3. plugin symlink — only when the table gives this harness a plugin dir (opencode). The source is
  #    resolved from the KIT root (not the CWD); idempotent relink, never clobbers a user's own file.
  if [ -n "$plugin_dir" ]; then
    if ! _rsdd_link_plugin "$plugin_dir" "$dry" "$KIT/toolbelt/opencode/research-sdd-sweep.ts"; then
      echo "research-sdd-install: [$h] plugin symlink failed ($plugin_dir)" >&2; rc=1
    fi
  fi

  # 4. MCP registration — only when the table names a config file (codex/reasonix config.toml).
  #    Idempotent marked-block splice; preserves surrounding user config; warns+skips on a
  #    user-authored entry. Shape comes from the adapter table (never branched on harness name).
  if [ -n "$mcp_config" ]; then
    local shape
    shape="$(rsdd_field "$h" mcp_toml_shape)"
    if ! _rsdd_register_mcp "$mcp_config" "$dry" "$shape"; then
      echo "research-sdd-install: [$h] MCP config registration failed ($mcp_config)" >&2; rc=1
    fi
  fi
  printf '  slash_commands=%s\n' "$slash"
  return "$rc"
}

main() {
  local harness="all" home="$HOME" dry=0 force=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --harness)     harness="${2:-}"; shift 2 ;;
      --home)        home="${2:-}"; shift 2 ;;
      --dry-run)     dry=1; shift ;;
      --force-skill) force=1; shift ;;
      -h|--help)     usage; return 0 ;;
      *) echo "research-sdd-install: unknown argument '$1'" >&2; usage >&2; return 2 ;;
    esac
  done
  local list
  if [ "$harness" = all ]; then list="$RESEARCH_SDD_HARNESSES"; else list="$harness"; fi

  local h
  for h in $list; do
    if [ -z "${_RSDD_CONFIG_ROOT_REL[$h]:-}" ]; then
      echo "research-sdd-install: unknown harness '$h' (known: $RESEARCH_SDD_HARNESSES all)" >&2
      return 2
    fi
  done
  # Aggregate: a mid-loop harness failure must NOT abort the run (still install the writable ones),
  # but the overall exit code must be nonzero if ANY harness failed. Dry-run mutates nothing → 0.
  local rc=0
  for h in $list; do
    install_one "$h" "$home" "$dry" "$force" || rc=1
  done
  return "$rc"
}

main "$@"
