#!/usr/bin/env bash
# research-sdd-install.sh — kit-owned, pure-bash multi-harness installer.
#
# Surfaces the single neutral asset (skills/research-sdd/SKILL.md) + a thin launcher into every AI
# harness's OWN paths by iterating the adapter table in adapters.sh. The loop body has ZERO
# per-harness `if`/`case`: WHERE/HOW/WHAT all come from the table, so a 4th harness is one table row.
#
# usage() (below) prints exactly the text between the # HELP-START / # HELP-END sentinel comments
# — kit issue #1024 round 4, item 5: it used to be a hardcoded `sed -n 'A,Bp'` line range, which
# had to be recomputed by hand every time a paragraph was added or removed here — a repeated
# maintenance paper cut across rounds 2 and 3. Add or remove paragraphs freely between the two
# sentinels; no line numbers to keep in sync. The sentinel lines themselves are excluded.
# HELP-START
# Usage:
#   research-sdd-install.sh [--harness claude|codex|reasonix|all] [--home <dir>] [--dry-run] [--force-skill] [--profile <name>]
#
#   --harness     which harness(es) to install into (default: all, in registration order)
#   --home        the home dir whose config roots are targeted (default: $HOME)
#   --dry-run     print the exact plan (files + rendered section) WITHOUT touching the filesystem
#   --force-skill when the deployed SKILL.md has diverged, back it up and overwrite with the kit source
#   --profile     prompt profile to install (claude|general|...): flag > $RESEARCH_SDD_PROFILE env
#                 > per-harness default (adapters.sh _RSDD_DEFAULT_PROFILE); unknown profile exits 2
#
# Idempotent: re-running is a clean update, never a duplicate. markdown-sections splices a marked
# block into a SHARED prompt file, preserving all surrounding user content (including the harness's
# own global system prompt, e.g. codex's ~/.codex/AGENTS.md).
#
# Managed overwrite (kit issue #1024 F4 + round 3 item 2): a deployed skill that still matches the
# sha256 the installer itself last recorded is a MANAGED overwrite, not a hand-edit — it is
# silently updated to the new source, no --force-skill needed. This covers TWO cases identically,
# since the marker-hash check cannot (and need not) distinguish them: a profile SWITCH (deployed
# is the previous profile's unedited render) and a SAME-profile kit update (deployed is unedited,
# but the kit's own content has since moved forward — e.g. a newer kit checkout). Either way the
# dry-run plan says "[will update — managed content (matches last install)]". A deployed file that
# does NOT match the recorded hash is a genuine hand-edit and keeps the existing protected
# behaviour (warn + keep, or --force-skill backup + overwrite) unchanged — EXCEPT: if this was an
# attempted profile SWITCH (the marker names a different profile than the one just requested) and
# the hand-edit blocks it, the overall run exits non-zero (round 3 item 3) instead of the usual
# exit 0 — the launcher's "Kit path:" would otherwise be rewritten to the NEW profile while the
# kept SKILL.md stays the OLD profile's content, a mixed state that must never report success.
# HELP-END
set -uo pipefail

# -P/pwd -P: see research-sdd/toolbelt/verify-cd-physical.sh's own header for why (kit issue
# #1024). CONSEQUENCE (round 5, Opus finding 4): $KIT — and therefore every PERSISTED "Kit path:"
# line this installer writes into a harness's launcher/prompt file — is now the PHYSICALLY
# resolved path, following any symlink in this script's own invocation path or in $KIT's own
# location. If the kit checkout (or a directory above it) is reached through a symlink, the
# persisted "Kit path:" names the symlink's REAL target, not the symlink path a user may be more
# accustomed to seeing — this is intentional (a physical path is unambiguous and stable across
# however the installer itself happened to be invoked), not a regression to work around.
SELF="$(cd -P "$(dirname "$0")" && pwd -P)"
KIT="$(cd -P "$SELF/.." && pwd -P)"
# shellcheck source=adapters.sh
. "$SELF/adapters.sh"

usage() {
  awk '/^# HELP-START$/{f=1;next} /^# HELP-END$/{f=0} f' "$SELF/$(basename "$0")" | sed 's/^# \{0,1\}//'
}

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
# $5 (kit) lets a non-default-profile install point the launcher's "Kit path:" fast-path at the
# rendered profile tree instead of the kit source (kit issue #993 WU2); defaults to $KIT so every
# other caller/strategy keeps today's behaviour untouched.
_surface__markdown_sections() {
  local harness="$1" home="$2" file="$3" dry="$4" kit="${5:-$KIT}" section
  section="$(rsdd_render_section "$harness" "$home" "$kit")" || return 2
  _rsdd_splice_file "$file" "$dry" \
    '<!-- research-sdd:start -->' '<!-- research-sdd:end -->' \
    'markdown-sections: marker <!-- research-sdd:start/end -->' "$section"
}

# _rsdd_realpath_m <path> — realpath -m semantics (resolve "..", normalize, tolerate a missing
# final component) via python3, mirroring render-profile.sh's identical convention/comment: GNU
# realpath's -m flag is not available on macOS/BSD, so python3 (already a kit-wide dependency) is
# the portable choice. Fails closed (rc=2) if python3 itself is unavailable — a caller that cannot
# resolve a path can never prove containment, so it must refuse, not assume safety.
_rsdd_realpath_m() {
  command -v python3 >/dev/null 2>&1 || return 2
  python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$1"
}

# _rsdd_clean_profile_dir <dir> <config_root> — removes a stale prior render before a fresh one.
# Anti-destructive guard (CLAUDE.md §8, propose-never-apply extended to renders). THREE
# independent checks, ALL must pass, hardened by kit issue #1024 review F2 after a textual-only
# check let "<config_root>/research-sdd/profile/../profiles/general" pass — the case-pattern glob
# never resolves ".." — and rm -rf then deleted a SIBLING directory outside profile/ entirely
# (reproduced against 6a0ff24 before this fix):
#   1. textual prefix match — cheap, catches the common no-".." case, needs no external tool.
#   2. neither <config_root>/research-sdd nor .../research-sdd/profile may be a SYMLINK — a
#      pre-planted symlink could redirect an otherwise textually- and realpath-safe-looking path.
#   3. realpath -m of <dir> must resolve strictly INSIDE realpath -m of
#      <config_root>/research-sdd/profile — the AUTHORITATIVE check: catches any ".." (or other
#      non-canonical form) check 1 cannot see. A realpath failure (including python3 missing)
#      refuses rather than skips — this check can never be bypassed by starving it of a tool.
# The rm -rf runs against the RESOLVED path, never the original (possibly-".."-bearing) string —
# no window where a later re-interpretation of the unresolved string could diverge from what was
# actually checked.
_rsdd_clean_profile_dir() {
  local dir="$1" config_root="$2" dir_real prefix_real
  case "$dir" in
    "$config_root"/research-sdd/profile/?*) ;;
    *)
      echo "research-sdd-install: refusing to clean non-profile-owned dir: $dir" >&2
      return 2
      ;;
  esac
  if [ -L "$config_root/research-sdd" ] || [ -L "$config_root/research-sdd/profile" ]; then
    echo "research-sdd-install: refusing to clean $dir — research-sdd/ or research-sdd/profile/ in the chain is a symlink" >&2
    return 2
  fi
  dir_real="$(_rsdd_realpath_m "$dir")" || {
    echo "research-sdd-install: refusing to clean $dir — could not resolve realpath (python3 required)" >&2
    return 2
  }
  prefix_real="$(_rsdd_realpath_m "$config_root/research-sdd/profile")" || {
    echo "research-sdd-install: refusing to clean $dir — could not resolve realpath (python3 required)" >&2
    return 2
  }
  case "$dir_real" in
    "$prefix_real"/?*) ;;
    *)
      echo "research-sdd-install: refusing to clean $dir — resolves to $dir_real, outside $prefix_real" >&2
      return 2
      ;;
  esac
  rm -rf "$dir_real" || { echo "research-sdd-install: rm -rf failed for $dir_real" >&2; return 1; }
}

# _rsdd_link_missing_entries <dest_dir> <src_dir> [skip_name] — for every entry directly inside
# <src_dir>, symlink it into <dest_dir> UNLESS something already exists there (a file rendered by
# render-profile.sh, or <skip_name> — a subtree this function's OWN caller handles separately via
# its own recursive call, so it must never be shadowed by a symlink to the WHOLE source subtree
# here). Absolute paths in <src_dir> flow straight through find into the symlink target, so every
# link is absolute and independent of where <dest_dir> ends up.
_rsdd_link_missing_entries() {
  local dest_dir="$1" src_dir="$2" skip_name="${3:-}" name base
  while IFS= read -r -d '' name; do
    base="$(basename "$name")"
    [ -n "$skip_name" ] && [ "$base" = "$skip_name" ] && continue
    if [ -e "$dest_dir/$base" ] || [ -L "$dest_dir/$base" ]; then continue; fi
    ln -s "$name" "$dest_dir/$base" || {
      echo "research-sdd-install: symlink failed: $dest_dir/$base -> $name" >&2
      return 1
    }
  done < <(find "$src_dir" -mindepth 1 -maxdepth 1 -print0)
}

# _rsdd_complete_profile_render <render_dir> <kit> — after render-profile.sh has written a
# profile's substituted files into <render_dir> (SKILL.md, PROMPT-LOOP.md, METHODOLOGY.md today —
# NEVER hardcoded here, see below), complete it into a FULL kit view: every kit entry
# render-profile.sh did NOT materialize is symlinked in at the same relative path, so every
# $KIT/... reference inside the rendered SKILL.md/PROMPT-LOOP.md (toolbelt/*.sh, TARGETS.md,
# templates/, tool-registry.md, other skills/*, ...) still resolves once the installed launcher's
# "Kit path:" fast-path points HERE instead of at the kit (kit issue #1024 review F1 — reasonix
# now defaults to "general", so a plain re-install was breaking every such reference for reasonix
# users). Walks <kit>'s TOP LEVEL plus skills/* plus skills/research-sdd/* — the two directory
# levels a renderer could plausibly touch — rather than hardcoding render-profile.sh's 3 file
# names, so a future renderer output is completed automatically without editing this function.
# render-profile.sh's OWN contract is untouched: this lives here, in the installer, on purpose.
_rsdd_complete_profile_render() {
  local render_dir="$1" kit="$2"
  _rsdd_link_missing_entries "$render_dir" "$kit" "skills" || return 1
  if [ -d "$kit/skills" ]; then
    mkdir -p "$render_dir/skills" || {
      echo "research-sdd-install: mkdir failed for $render_dir/skills" >&2; return 1
    }
    _rsdd_link_missing_entries "$render_dir/skills" "$kit/skills" "research-sdd" || return 1
    if [ -d "$kit/skills/research-sdd" ]; then
      mkdir -p "$render_dir/skills/research-sdd" || {
        echo "research-sdd-install: mkdir failed for $render_dir/skills/research-sdd" >&2; return 1
      }
      _rsdd_link_missing_entries "$render_dir/skills/research-sdd" "$kit/skills/research-sdd" || return 1
    fi
  fi
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

# _rsdd_sha256_file <path> — portable sha256 (sha256sum, then shasum -a 256, then python3
# hashlib — python3 is already a kit-wide dependency via render-profile.sh/_rsdd_realpath_m, so
# this never adds a NEW one). Prints the hex digest and returns 0, or returns 1 with nothing
# printed on any failure (missing tool, unreadable file) — callers must check the exit status,
# never trust empty output as "no hash".
_rsdd_sha256_file() {
  local f="$1" out
  if command -v sha256sum >/dev/null 2>&1; then
    out="$(sha256sum "$f" 2>/dev/null | awk '{print $1}')"
  elif command -v shasum >/dev/null 2>&1; then
    out="$(shasum -a 256 "$f" 2>/dev/null | awk '{print $1}')"
  elif command -v python3 >/dev/null 2>&1; then
    out="$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$f" 2>/dev/null)"
  else
    return 1
  fi
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

# _rsdd_marker_field <marker_file> <field> — read one "field=value" line from the marker; empty
# stdout and rc=1 if the file is missing, unreadable, or the field is absent.
_rsdd_marker_field() {
  local marker="$1" field="$2"
  [ -f "$marker" ] && [ -r "$marker" ] || return 1
  awk -F= -v k="$field" '$1==k{print substr($0, index($0,"=")+1); found=1} END{exit !found}' "$marker"
}

# _rsdd_write_marker <marker_file> <profile> <deployed_path> — record what the installer itself
# just deployed: the profile name and the sha256 of <deployed_path> AS IT NOW STANDS. Written
# atomically (tmp + mv). Lives at <config_root>/research-sdd/.installed-skill-state — a SIBLING
# of profile/, never inside it, so it survives _rsdd_clean_profile_dir cleaning any specific
# profile/<name>/ subtree (kit issue #1024 review F4).
_rsdd_write_marker() {
  local marker="$1" profile="$2" deployed="$3" sha tmp
  sha="$(_rsdd_sha256_file "$deployed")" || return 1
  mkdir -p "$(dirname "$marker")" || return 1
  tmp="$(mktemp)" || return 1
  printf 'profile=%s\nsha256=%s\n' "$profile" "$sha" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$marker"
}

# _rsdd_marker_matches_deployed <marker_file> <deployed_path> — true iff the marker exists, has a
# recorded sha256, AND that hash equals <deployed_path>'s CURRENT sha256. This is the switch:
# "deployed differs from the NEW source" alone (a plain cmp) cannot tell a genuine hand-edit apart
# from "this is just what a DIFFERENT profile legitimately rendered" — both look identically
# diverged to cmp. A hash match here means the deployed bytes are EXACTLY what the installer
# itself last wrote (whatever profile that was), so a difference from the new source is a
# profile switch to manage, not a user's local delta to protect (kit issue #1024 review F4).
_rsdd_marker_matches_deployed() {
  local marker="$1" deployed="$2" recorded actual
  recorded="$(_rsdd_marker_field "$marker" sha256)" || return 1
  [ -n "$recorded" ] || return 1
  actual="$(_rsdd_sha256_file "$deployed")" || return 1
  [ "$recorded" = "$actual" ]
}

# _rsdd_dry_skill_plan <src> <dest> <force> <label> <marker> [profile] — print the exact INSTALL
# line dry-run takes for copying <src> onto <dest>, applying the SAME divergence rule (CLAUDE.md
# §7) no matter WHAT is being deployed: the kit source directly, or a freshly rendered profile.
# <label> is the human-readable provenance phrase embedded in the printed line (e.g. "from kit
# <relkit>" or "from rendered profile '<name>'"). Shared by every leg that deploys a skill file so
# a divergence fix made once (kit issue #1024, R3-silent-overwrite-rendered-profile; extended by
# F4's marker-matches managed-overwrite state) covers all of them. [profile], when given, is the
# profile just requested — used only for the RDD R4-001 WARN (round 4 item 4): the diverged
# branch additionally previews whether a REAL run would refuse this as a blocked profile switch.
# Sets _RSDD_SKILL_BLOCKED_MIXED=1 and returns 1 when that WARN fires (kit issue #1024 round 5,
# Opus finding 3, RDD R3-dry-run-switch-warn-untested) — a dry-run preview that promises a clean
# switch a real run would then refuse is a contradiction: install_one must ALSO skip previewing
# the launcher SPLICE for this harness, and the overall dry-run exit code must go non-zero, the
# same way the real run's blocked-mixed-state path already does.
_rsdd_dry_skill_plan() {
  local src="$1" dest="$2" force="$3" label="$4" marker="${5:-}" profile="${6:-}"
  local _dry_old_profile
  _RSDD_SKILL_BLOCKED_MIXED=0
  if [ ! -f "$src" ]; then
    printf '  INSTALL %s (%s) [SKIP — source SKILL not found]\n' "$dest" "$label"
  elif [ ! -r "$src" ]; then
    printf '  INSTALL %s (%s) [SKIP — source SKILL not readable; check permissions]\n' "$dest" "$label"
  elif [ -e "$dest" ] && [ ! -f "$dest" ]; then
    printf '  INSTALL %s (%s) [SKIP — destination is not a regular file; remove it and re-run]\n' "$dest" "$label"
  elif [ -f "$dest" ] && [ ! -r "$dest" ]; then
    printf '  INSTALL %s (%s) [SKIP — not readable; check permissions]\n' "$dest" "$label"
  elif [ -f "$dest" ] && cmp -s "$src" "$dest"; then
    printf '  INSTALL %s (%s) [up-to-date]\n' "$dest" "$label"
  elif [ -f "$dest" ] && _rsdd_marker_matches_deployed "$marker" "$dest"; then
    printf '  INSTALL %s (%s) [will update — managed content (matches last install)]\n' "$dest" "$label"
  elif [ -f "$dest" ] && [ "$force" = 1 ]; then
    if [ -e "$dest.local-backup" ]; then
      printf '  INSTALL %s (%s) [SKIP — backup %s already exists; rename or remove it first]\n' "$dest" "$label" "$dest.local-backup"
    else
      printf '  INSTALL %s (%s) [will overwrite; backup → %s]\n' "$dest" "$label" "$dest.local-backup"
    fi
  elif [ -f "$dest" ]; then
    printf '  INSTALL %s (%s) [SKIP — diverged; use --force-skill to overwrite]\n' "$dest" "$label"
    # RDD R4-001 (kit issue #1024 round 4, item 4): the REAL run's warn+keep branch below refuses
    # (and skips the launcher rewrite) when this diverged file is ALSO an attempted profile
    # switch a hand-edit blocked. The dry-run preview must say so too — otherwise `--dry-run`
    # promises a clean switch a real run would then refuse.
    _dry_old_profile="$(_rsdd_marker_field "$marker" profile 2>/dev/null)" || _dry_old_profile=""
    if [ -n "$profile" ] && [ -n "$_dry_old_profile" ] && [ "$_dry_old_profile" != "$profile" ]; then
      printf '  WARN    %s: a real run would ALSO refuse this profile switch "%s" → "%s" (mixed-state guard, RDD R4-001) — the launcher rewrite would be skipped too\n' \
        "$dest" "$_dry_old_profile" "$profile"
      _RSDD_SKILL_BLOCKED_MIXED=1
      return 1
    fi
  else
    printf '  INSTALL %s (%s)\n' "$dest" "$label"
  fi
}

# _rsdd_deploy_skill <src> <dest> <force> <label> <harness> <marker> <profile> <config_root> —
# perform the copy the plan above previews, applying the identical divergence rule PLUS the
# marker-matches managed-overwrite state (kit issue #1024 review F4). Returns nonzero on any
# failure. WHY preserve a genuine hand-edit by default: the deployed SKILL.md can carry
# retro-applied deltas written directly into it; an unconditional overwrite would silently
# destroy that knowledge, no matter whether <src> is the kit source or a rendered profile. WHY
# NOT treat a profile switch the same way: cmp alone cannot distinguish "the user edited this"
# from "this is what the PREVIOUS profile legitimately rendered" — both differ from the new
# source identically. On any successful deploy (fresh install, managed switch-overwrite, or a
# --force-skill overwrite) the marker is updated to record the NEW profile + hash, and — only
# then — the PREVIOUS profile's now-orphaned render dir (if it had one) is removed through the
# same guarded _rsdd_clean_profile_dir. A warn+keep for a genuine hand-edit leaves the marker (and
# any old render dir) untouched: the switch has not actually completed.
_rsdd_deploy_skill() {
  local src="$1" dest="$2" force="$3" label="$4" h="$5" marker="$6" profile="$7" config_root="$8"
  local bak deployed_now=0 old_profile
  # Named-output signal (kit issue #1024 round 4, item 4) — a caller (install_one) reads this
  # RIGHT AFTER the call to learn whether THIS SPECIFIC blocked-mixed-state path fired, distinct
  # from every other reason this function can return nonzero. Reset unconditionally at the top of
  # every call so a caller reusing the same shell for multiple harnesses never sees a stale 1 from
  # a PREVIOUS harness's blocked switch.
  _RSDD_SKILL_BLOCKED_MIXED=0
  printf '  INSTALL %s (%s)\n' "$dest" "$label"
  if [ ! -f "$src" ]; then
    echo "research-sdd-install: [$h] source SKILL not found: $src" >&2; return 1
  elif [ ! -r "$src" ]; then
    echo "research-sdd-install: [$h] source SKILL not readable: $src" >&2; return 1
  elif ! mkdir -p "$(dirname "$dest")"; then
    echo "research-sdd-install: [$h] mkdir failed for $(dirname "$dest")" >&2; return 1
  elif [ -e "$dest" ] && [ ! -f "$dest" ]; then
    printf 'research-sdd-install: WARNING %s exists but is not a regular file — skipped (remove it and re-run)\n' "$dest" >&2
  elif [ -f "$dest" ] && [ ! -r "$dest" ]; then
    printf 'research-sdd-install: WARNING %s exists but is not readable (check permissions) — local content kept\n' "$dest" >&2
  elif [ -f "$dest" ] && cmp -s "$src" "$dest"; then
    deployed_now=1 # byte-identical — silent no-op, but still (re)confirm the marker below
  elif [ -f "$dest" ] && _rsdd_marker_matches_deployed "$marker" "$dest"; then
    if ! cp "$src" "$dest"; then
      echo "research-sdd-install: [$h] cp failed → $dest" >&2; return 1
    fi
    deployed_now=1
  elif [ -f "$dest" ] && [ "$force" = 1 ]; then
    bak="$dest.local-backup"
    if [ -e "$bak" ]; then
      # Refuse: the backup may be the ONLY copy of deltas from a prior --force-skill run.
      # The operator resolves this by hand (rename or remove), keeping the decision explicit.
      printf 'research-sdd-install: ERROR %s already exists — rename or remove it before re-running --force-skill (it may contain deltas you have not merged)\n' "$bak" >&2
      return 1
    elif ! cp "$dest" "$bak"; then
      echo "research-sdd-install: [$h] backup failed → $bak" >&2; return 1
    elif ! cp "$src" "$dest"; then
      echo "research-sdd-install: [$h] cp failed → $dest" >&2; return 1
    else
      printf '  BACKUP  %s → %s\n' "$dest" "$bak"
      deployed_now=1
    fi
  elif [ -f "$dest" ]; then
    printf 'research-sdd-install: WARNING %s exists with diverged content — local content kept (use --force-skill to overwrite, or delete to reinstall)\n' "$dest" >&2
    # kit issue #1024 round 3 item 3 (round 4 item 4 extends this): if this WAS an attempted
    # profile switch (the marker names a DIFFERENT profile than the one just requested) and the
    # hand-edit blocked it, the launcher's "Kit path:" would otherwise still be rewritten to the
    # NEW profile (step 2 used to always run unconditionally) while SKILL.md stays the OLD
    # profile's content — a mixed state. Round 3 made this exit non-zero; round 4 additionally
    # signals the caller via _RSDD_SKILL_BLOCKED_MIXED so install_one can SKIP step 2 entirely —
    # nothing mixed is ever written to disk, not even the launcher's Kit path line. An ordinary
    # re-install with a pre-existing hand-edit on the SAME profile (old_profile == profile, or no
    # marker yet) is unaffected — step 2 still runs normally for that case.
    _deployed_old_profile="$(_rsdd_marker_field "$marker" profile 2>/dev/null)" || _deployed_old_profile=""
    if [ -n "$_deployed_old_profile" ] && [ "$_deployed_old_profile" != "$profile" ]; then
      printf 'research-sdd-install: ERROR %s: switching profile "%s" → "%s" was requested, but a hand-edit at %s blocked it — the launcher was left UNCHANGED (still "%s") so nothing mixed is written; the deployed skill also stays "%s". Resolve with --force-skill (overwrites, backs up first) or by hand, then re-run.\n' \
        "$h" "$_deployed_old_profile" "$profile" "$dest" "$_deployed_old_profile" "$_deployed_old_profile" >&2
      _RSDD_SKILL_BLOCKED_MIXED=1
      return 1
    fi
  elif ! cp "$src" "$dest"; then
    echo "research-sdd-install: [$h] cp failed → $dest" >&2; return 1
  else
    deployed_now=1
  fi
  if [ "$deployed_now" = 1 ]; then
    old_profile="$(_rsdd_marker_field "$marker" profile 2>/dev/null)" || old_profile=""
    _rsdd_write_marker "$marker" "$profile" "$dest" || {
      echo "research-sdd-install: [$h] warning: could not write profile-state marker $marker" >&2
    }
    if [ -n "$old_profile" ] && [ "$old_profile" != "$profile" ] && [ "$old_profile" != "claude" ]; then
      # kit issue #1024 round 3 "also": the marker is small operator-editable state — validate
      # its profile= value against the SAME known-profile check the installer uses everywhere
      # else, BEFORE it ever reaches a path construction, rather than relying solely on
      # _rsdd_clean_profile_dir's own (already-sufficient-for-traversal) F2 guards downstream.
      if ! rsdd_valid_profile "$old_profile" "$KIT"; then
        echo "research-sdd-install: [$h] warning: marker names an invalid profile '$old_profile' — refusing to clean, leaving it for manual inspection" >&2
      elif ! _rsdd_clean_profile_dir "$config_root/research-sdd/profile/$old_profile" "$config_root"; then
        echo "research-sdd-install: [$h] warning: could not clean the orphaned '$old_profile' render dir" >&2
      fi
    fi
  fi
}

# --- the ONE install loop body — table-driven, no per-harness branching --------------------------
install_one() {
  local h="$1" home="$2" dry="$3" force="$4" profile="$5" profile_source="$6" rc=0
  local skill_path prompt_file strategy mcp_config slash dispatch src_relkit src_skill
  local config_root marker
  skill_path="$(rsdd_field "$h" skill_path "$home")"
  prompt_file="$(rsdd_field "$h" prompt_file "$home")"
  strategy="$(rsdd_field "$h" prompt_strategy "$home")"
  mcp_config="$(rsdd_field "$h" mcp_config_file "$home")"
  slash="$(rsdd_field "$h" supports_slash_commands "$home")"
  src_relkit="$(rsdd_field "$h" skill_src_relkit)"
  src_skill="$KIT/$src_relkit"
  config_root="$(rsdd_field "$h" config_root "$home")"
  # <config_root>/research-sdd/.installed-skill-state — a SIBLING of profile/, so cleaning any
  # specific profile/<name>/ subtree never touches it (kit issue #1024 review F4).
  marker="$config_root/research-sdd/.installed-skill-state"

  printf 'harness=%s\n' "$h"
  printf '  profile=%s (source=%s)\n' "$profile" "$profile_source"

  # 0/1. deploy the neutral SKILL.md into this harness's skills dir. profile "claude" is the
  #    byte-identical-to-today path: $src_skill stays the kit source, $kit_for_section stays $KIT.
  #    A non-default profile (kit issue #993 WU2) first renders the profile's substituted sources
  #    into this harness's OWN config root — never the kit tree — and deploys FROM THAT RENDER
  #    instead; $kit_for_section (passed to the launcher strategy below) then points the prompt
  #    file's "Kit path:" fast-path at the render, so SKILL.md's own kit-path resolution (step 0,
  #    "Resolving the kit path") reaches the rendered PROMPT-LOOP.md/METHODOLOGY.md, not the kit's.
  #    A render is always freshly regenerated (clean, then render) — the render dir itself has
  #    nothing to preserve, it IS the source of truth for that profile. The DEPLOYED skill_path is
  #    a different matter: it can carry retro-applied deltas written directly into it by an
  #    operator, on EITHER leg, so both legs deploy through the SAME divergence-checked helpers
  #    (_rsdd_dry_skill_plan / _rsdd_deploy_skill, CLAUDE.md §7 three-state rule) — kit issue #1024
  #    review correction (R3-silent-overwrite-rendered-profile): the render leg used to `cp`
  #    unconditionally, with no cmp -s check, no backup, and --force-skill silently ignored.
  local kit_for_section="$KIT" render_dir="" render_err label
  # Global (not local) signal read after _rsdd_deploy_skill returns — see its own comment (kit
  # issue #1024 round 4, item 4). Reset here too: the dry-run branches below never call
  # _rsdd_deploy_skill at all, so without this a STALE 1 from a PREVIOUS harness in the same
  # process could otherwise survive into this harness's dry-run pass.
  _RSDD_SKILL_BLOCKED_MIXED=0
  if [ "$profile" != "claude" ]; then
    render_dir="$config_root/research-sdd/profile/$profile"
    kit_for_section="$render_dir"
    src_skill="$render_dir/$src_relkit"
    label="from rendered profile '$profile'"
    printf '  RENDER  %s (profile=%s)\n' "$render_dir" "$profile"
    if [ "$dry" = 1 ]; then
      # Render into a throwaway scratch dir so the plan previews the ACTUAL bytes the real run
      # would deploy, without touching the harness's own (persistent) render dir — dry-run stays
      # a pure preview (CLAUDE.md §8: propose-never-apply extended to renders).
      local dry_render_dir dry_render_err
      dry_render_dir="$(mktemp -d)" || { echo "research-sdd-install: [$h] mktemp failed" >&2; rc=1; }
      if [ -n "${dry_render_dir:-}" ]; then
        if ! dry_render_err="$("$KIT/toolbelt/render-profile.sh" "$profile" "$dry_render_dir" 2>&1)"; then
          echo "research-sdd-install: [$h] render-profile.sh failed: $dry_render_err" >&2
          rc=1
        else
          _rsdd_dry_skill_plan "$dry_render_dir/$src_relkit" "$skill_path" "$force" "$label" "$marker" "$profile" || rc=1
        fi
        rm -rf "$dry_render_dir"
      fi
    else
      if ! _rsdd_clean_profile_dir "$render_dir" "$config_root"; then
        rc=1
      elif ! render_err="$("$KIT/toolbelt/render-profile.sh" "$profile" "$render_dir" 2>&1)"; then
        echo "research-sdd-install: [$h] render-profile.sh failed: $render_err" >&2
        rc=1
      elif ! _rsdd_complete_profile_render "$render_dir" "$KIT"; then
        echo "research-sdd-install: [$h] could not complete the render into a full kit view" >&2
        rc=1
      else
        _rsdd_deploy_skill "$src_skill" "$skill_path" "$force" "$label" "$h" "$marker" "$profile" "$config_root" || rc=1
      fi
    fi
  else
    label="from kit $src_relkit"
    if [ "$dry" = 1 ]; then
      _rsdd_dry_skill_plan "$src_skill" "$skill_path" "$force" "$label" "$marker" "$profile" || rc=1
    else
      _rsdd_deploy_skill "$src_skill" "$skill_path" "$force" "$label" "$h" "$marker" "$profile" "$config_root" || rc=1
    fi
  fi

  # 2. launcher → this harness's prompt file, via the strategy the TABLE named (data, not a branch)
  #    kit issue #1024 round 4, item 4: SKIP this step entirely when step 0/1 hit the blocked-
  #    mixed-state path above — never rewrite (or even preview rewriting) the launcher's "Kit
  #    path:" line to the new profile while the deployed skill stays the OLD profile's content.
  #    The non-zero exit from step 0/1 already reported this; step 2 must not paper over it by
  #    writing a HALF of the switch to disk.
  if [ "$_RSDD_SKILL_BLOCKED_MIXED" = 1 ]; then
    printf '  SKIP    %s (launcher rewrite skipped — profile switch blocked by a hand-edit, mixed state avoided)\n' "$prompt_file"
  else
    dispatch="_surface__${strategy//-/_}"
    if ! declare -F "$dispatch" >/dev/null; then
      echo "research-sdd-install: [$h] no surfacing strategy '$strategy'" >&2; return 2
    fi
    if ! "$dispatch" "$h" "$home" "$prompt_file" "$dry" "$kit_for_section"; then
      echo "research-sdd-install: [$h] surfacing launcher failed ($prompt_file)" >&2; rc=1
    fi
  fi

  # 3. MCP registration — only when the table names a config file (codex/reasonix config.toml).
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
  local harness="all" home="$HOME" dry=0 force=0 profile_flag=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --harness)     harness="${2:-}"; shift 2 ;;
      --home)        home="${2:-}"; shift 2 ;;
      --dry-run)     dry=1; shift ;;
      --force-skill) force=1; shift ;;
      --profile)
        if [ $# -lt 2 ] || [ -z "${2:-}" ]; then
          echo "research-sdd-install: --profile requires a non-empty value" >&2; usage >&2; return 2
        fi
        profile_flag="$2"; shift 2 ;;
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

  # Resolve + validate the EFFECTIVE prompt profile for every harness up front (kit issue #993
  # WU2) — fail fast with one clear message before touching the filesystem, dry-run or not.
  # Precedence (rsdd_resolve_profile): --profile flag > $RESEARCH_SDD_PROFILE env > this
  # harness's per-harness default (adapters.sh _RSDD_DEFAULT_PROFILE). A flag/env value applies
  # uniformly to every harness in $list; the default table can differ per harness (e.g. reasonix
  # defaults to "general" while claude/codex default to "claude").
  declare -A _profile_for=() _profile_source_for=()
  local resolved_pair resolved source
  for h in $list; do
    resolved_pair="$(rsdd_resolve_profile "$h" "$profile_flag")"
    resolved="${resolved_pair%%:*}"; source="${resolved_pair##*:}"
    if ! rsdd_valid_profile "$resolved" "$KIT"; then
      echo "research-sdd-install: unknown profile '$resolved' for harness '$h' (valid: $(rsdd_list_profiles "$KIT"))" >&2
      return 2
    fi
    _profile_for[$h]="$resolved"
    _profile_source_for[$h]="$source"
  done

  # Aggregate: a mid-loop harness failure must NOT abort the run (still install the writable ones),
  # but the overall exit code must be nonzero if ANY harness failed. Dry-run mutates nothing → 0.
  local rc=0
  for h in $list; do
    install_one "$h" "$home" "$dry" "$force" "${_profile_for[$h]}" "${_profile_source_for[$h]}" || rc=1
  done
  return "$rc"
}

main "$@"
