#!/usr/bin/env bash
# research-sdd-install.sh — kit-owned, pure-bash multi-harness installer.
#
# Surfaces the single neutral asset (skills/research-sdd/SKILL.md) + a thin launcher into every AI
# harness's OWN paths by iterating the adapter table in adapters.sh. The loop body has ZERO
# per-harness `if`/`case`: WHERE/HOW/WHAT all come from the table, so another harness is one table row.
#
# usage() (below) prints exactly the text between the # HELP-START / # HELP-END sentinel comments
# — kit issue #1024 round 4, item 5: it used to be a hardcoded `sed -n 'A,Bp'` line range, which
# had to be recomputed by hand every time a paragraph was added or removed here — a repeated
# maintenance paper cut across rounds 2 and 3. Add or remove paragraphs freely between the two
# sentinels; no line numbers to keep in sync. The sentinel lines themselves are excluded.
# HELP-START
# Usage:
#   research-sdd-install.sh [--harness claude|pi|gentle-shell|all] [--home <dir>] [--dry-run] [--force-skill] [--profile <name>]
#   research-sdd-install.sh --verify [--harness claude|pi|gentle-shell|all] [--home <dir>]
#
#   --harness     which harness(es) to install into (default: all, in registration order)
#   --home        the home dir whose config roots are targeted (default: $HOME)
#   --dry-run     print the exact plan (files + rendered section) WITHOUT touching the filesystem
#   --force-skill when the deployed SKILL.md has diverged, back it up and overwrite with the kit source
#   --profile     prompt profile to install (claude|general|...): flag > $RESEARCH_SDD_PROFILE env
#                 > per-harness default (adapters.sh _RSDD_DEFAULT_PROFILE); unknown profile exits 2
#   --verify      READ-ONLY drift check (kit issue #1702): recompute a sorted-path whole-bundle sha256 over what
#                 this installer manages for each harness (the deployed SKILL.md, the slash-command prompt
#                 template, the marked research-sdd launcher block inside the shared prompt file, and the
#                 regular files of a rendered profile) and compare it with the bundle digest the last
#                 successful install recorded in <config_root>/research-sdd/.installed-bundle-state. Prints
#                 ONE typed line per harness and writes NOTHING (no temp files, no state):
#                   verify harness=<h> status=match bundle_sha256=<hex> files=<n>
#                   verify harness=<h> status=drift drifted=<path (modified|missing|extra)>,...
#                   verify harness=<h> status=absent (not installed)
#                   verify harness=<h> status=degraded reason=<why>   (no sha256 tool, no/corrupt record, unreadable file)
#                 After the harness lines, ONE kit-checkout staleness line (advisory: it never changes the exit
#                 code), because deployed Stop hooks exec toolbelt scripts from THIS checkout:
#                   verify kit status=current ref=<upstream> behind=0
#                   verify kit status=behind ref=<upstream> behind=<n> ... fix: git -C <kit> pull --ff-only
#                   verify kit status=degraded reason=<why>   (no git, not a git checkout, no upstream ref)
#                 It compares HEAD with the LOCALLY KNOWN upstream ref (@{upstream}, else origin/main) and
#                 never fetches: the ref itself is only as fresh as the last fetch, and the line says so.
#                 $RESEARCH_SDD_KIT_DIR overrides the checkout inspected (test seam; default: this kit's root).
#                 Exit: 0 = every harness match or absent · 1 = drift in at least one harness and none
#                 degraded · 2 = at least one harness degraded, or an operational/usage error (degraded
#                 outranks drift: the instrument could not look, so it must not read as a clean 1).
#                 Combining --verify with --dry-run, --force-skill or --profile is a usage error (exit 2).
#                 An install that KEEPS a hand-edited SKILL.md/template records the SOURCE digest for that
#                 member plus a kept-hand-edit=<path> line: the hand-edit is never baselined, verify reports
#                 it as drift and prints kept-hand-edit=<path> so the cause is named.
#
# pi / gentle-shell (Pi, and Pi with an isolated agent dir): the skill lands under <agent-dir>/skills/
# and a slash-command prompt template under <agent-dir>/prompts/research-sdd.md, so /research-sdd works
# (the template follows the same hand-edit protection as the skill). Pi has no session-start hook, so
# the manual sweep block is documented in <agent-dir>/AGENTS.md; the kit registers no MCP servers.
#
# Idempotent: re-running is a clean update, never a duplicate. markdown-sections splices a marked
# block into a SHARED prompt file, preserving all surrounding user content (including the harness's
# own global system prompt, e.g. Pi's <agent-dir>/AGENTS.md).
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
# user-owned file. Marker STRINGS are parameters. It splices our marked block, preserving everything
# else. The rewrite removes ONLY a well-formed $start..$end pair (no nested start between them).
#
# An ORPHANED start marker (no matching end, or a second start before the end — a hand-edited/partial
# file) is treated as user content: PRESERVED verbatim and a fresh section appended, never truncated
# (dropping trailing user content is the real risk).
#
# $label names the marker style in the plan line. Symlink targets are written THROUGH (link
# preserved); an unwritable target surfaces a write failure (nonzero).
_rsdd_splice_file() {
  local file="$1" dry="$2" start="$3" end="$4" label="$5" section="$6"
  printf '  SPLICE  %s  [%s]\n' "$file" "$label"
  emit_section "$section"
  [ "$dry" = 1 ] && return 0
  mkdir -p "$(dirname "$file")" || { echo "research-sdd-install: mkdir failed for $(dirname "$file")" >&2; return 1; }
  # Build the preserved content in $tmp, then append the fresh section via the ONE separator-aware
  # helper — so the re-splice (rewrite) path and the fresh-append path insert an identical single
  # blank-line separator, and a brand-new empty file gets no leading blank line.
  # $tmp holds the full preserved content (what we write back).
  local tmp; tmp="$(mktemp)" || return 1
  if [ -f "$file" ] && grep -Fq -- "$start" "$file"; then
    local aw
    # Remove the FIRST well-formed start..end pair; keep every other line verbatim. If a start has no
    # matching end (orphan), flush it back out and signal via exit 3 so we can warn (exit 0 = clean).
    # Markers are matched by EXACT line equality (they are rendered as whole lines), so marker text
    # containing regex-special characters (e.g. `[`/`.`) is compared literally, never as a pattern.
    awk -v start="$start" -v end="$end" '
      BEGIN { done=0; inblk=0; orphan=0 }
      {
        if (!done && !inblk && $0 == start) { inblk=1; buf=$0 ORS; next }
        if (inblk) {
          if ($0 == start) { printf "%s", buf; orphan=1; buf=$0 ORS; next }
          if ($0 == end)   { inblk=0; done=1; buf=""; next }
          buf=buf $0 ORS; next
        }
        print
      }
      END { if (inblk) { printf "%s", buf; orphan=1 } exit (orphan?3:0) }
    ' "$file" > "$tmp"; aw=$?
    if [ "$aw" = 3 ]; then
      printf 'research-sdd-install: WARNING malformed research-sdd marker in %s (start without matching end) — preserved existing content and appended a fresh section; please remove the stray marker\n' "$file" >&2
    fi
  elif [ -f "$file" ]; then
    # No marker yet: preserve all existing user content verbatim, then append the section below it.
    cat "$file" > "$tmp" || { rm -f "$tmp"; echo "research-sdd-install: read failed for $file" >&2; return 1; }
  else
    : > "$tmp"  # brand-new file: section only, no leading blank line.
  fi
  _rsdd_append_section "$tmp" "$section"
  _rsdd_write_back "$tmp" "$file" || { echo "research-sdd-install: write failed for $file" >&2; return 1; }
}

# markdown-sections: the prompt file is SHARED — splice our marked block (HTML-comment markers),
# preserving everything else. Thin wrapper over the generic splice.
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
# "Kit path:" fast-path points HERE instead of at the kit (kit issue #1024 review F1 — reasonix,
# since dropped in #1471, defaulted to "general", so a plain re-install was breaking every such
# reference for its users; the same applies now to pi and gentle-shell, which also default to
# "general"). Walks <kit>'s TOP LEVEL plus skills/* plus skills/research-sdd/* — the two directory
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

# --- bundle digest: record at install, verify read-only (kit issue #1702) ------------------------------
# The bundle is a set of members, each named by a path RELATIVE to the harness config root, sorted
# byte-wise (LC_ALL=C). Member kinds: a regular file (hashed whole), or "<prompt file>#research-sdd-section"
# (the marked launcher block only, so user edits elsewhere in the shared prompt file never count).
# The manifest is "<sha256><TAB><rel>\n" per member; the BUNDLE DIGEST is the sha256 of that manifest text
# (the same sorted-path whole-bundle shape gentle-ai uses for its managed bundle). A member that does not
# exist hashes as the literal MISSING. The record file holds the digest plus every member line so verify
# can NAME the drifted members.
_RSDD_SECTION_SUFFIX='#research-sdd-section'

# _rsdd_have_sha256 — true iff some sha256 implementation is reachable (same chain as _rsdd_sha256_file).
_rsdd_have_sha256() {
  command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1
}

# _rsdd_sha256_stdin — sha256 of stdin; same tool chain as _rsdd_sha256_file. rc=1 + no output on failure.
_rsdd_sha256_stdin() {
  local out
  if command -v sha256sum >/dev/null 2>&1; then
    out="$(sha256sum 2>/dev/null | awk '{print $1}')"
  elif command -v shasum >/dev/null 2>&1; then
    out="$(shasum -a 256 2>/dev/null | awk '{print $1}')"
  elif command -v python3 >/dev/null 2>&1; then
    out="$(python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())' 2>/dev/null)"
  else
    return 1
  fi
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

# _rsdd_section_text <file> — the first well-formed research-sdd marked block (markers included), exact
# line equality like _rsdd_splice_file. rc=1 when the file or a complete block is absent.
_rsdd_section_text() {
  [ -f "$1" ] || return 1
  awk -v start='<!-- research-sdd:start -->' -v end='<!-- research-sdd:end -->' '
    !inb && $0 == start { inb=1; buf=$0 ORS; next }
    inb { buf=buf $0 ORS; if ($0 == end) { printf "%s", buf; found=1; exit } }
    END { exit !found }
  ' "$1"
}

# _rsdd_member_hash <config_root> <rel> — prints the member's sha256 or MISSING. rc=1 when the member
# exists but cannot be hashed (unreadable): the caller must report degraded, never a digest over a gap.
_rsdd_member_hash() {
  local root="$1" rel="$2" f text h
  case "$rel" in
    *"$_RSDD_SECTION_SUFFIX")
      f="$root/${rel%"$_RSDD_SECTION_SUFFIX"}"
      if [ -e "$f" ] && [ ! -r "$f" ]; then return 1; fi
      if text="$(_rsdd_section_text "$f")"; then
        h="$(printf '%s\n' "$text" | _rsdd_sha256_stdin)" || return 1
        printf '%s\n' "$h"
      else
        printf 'MISSING\n'
      fi ;;
    *)
      f="$root/$rel"
      if [ -f "$f" ]; then
        [ -r "$f" ] || return 1
        _rsdd_sha256_file "$f" || return 1
      else
        printf 'MISSING\n'
      fi ;;
  esac
}

# _rsdd_manifest <config_root> <profile> — reads member rels on stdin, adds every regular file of the
# rendered profile dir (non-claude profile; symlinks into the kit view are not members), de-duplicates,
# sorts byte-wise, and prints "<sha>\t<rel>" lines. rc=1 on an unhashable member or an unsafe profile
# name, rc=3 when the profile dir cannot be traversed.
_rsdd_manifest() {
  local root="$1" profile="$2" rels rel h rd f found
  rels="$(cat)"
  if [ "$profile" != "claude" ]; then
    [[ "$profile" =~ ^[a-z0-9_-]+$ ]] || return 1
    rd="$root/research-sdd/profile/$profile"
    if [ -d "$rd" ]; then
      # find's own status is captured (no pipeline / process substitution that would drop it): an
      # untraversable profile dir must be degraded (rc 3), never a confident "members missing".
      found="$(find "$rd" -type f 2>/dev/null)" || return 3
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        rels="$rels
${f#"$root"/}"
      done <<<"$found"
    fi
  fi
  rels="$(printf '%s\n' "$rels" | awk 'NF' | LC_ALL=C sort -u)"
  [ -n "$rels" ] || return 1
  while IFS= read -r rel; do
    h="$(_rsdd_member_hash "$root" "$rel")" || return 1
    printf '%s\t%s\n' "$h" "$rel"
  done <<<"$rels"
}

# _rsdd_install_members <h> <home> — the members one install deploys, one rel per line.
_rsdd_install_members() {
  local h="$1" home="$2" root skill tmpl pf
  root="$(rsdd_field "$h" config_root "$home")"
  skill="$(rsdd_field "$h" skill_path "$home")"
  tmpl="$(rsdd_field "$h" prompt_template_path "$home")"
  pf="$(rsdd_field "$h" prompt_file "$home")"
  printf '%s\n' "${skill#"$root"/}" "${pf#"$root"/}$_RSDD_SECTION_SUFFIX"
  [ -z "$tmpl" ] || printf '%s\n' "${tmpl#"$root"/}"
}

# _rsdd_apply_kept <kept> — stdin manifest -> stdout manifest where each kept member's sha is replaced by
# the sha of the SOURCE this run meant to deploy. <kept> is "rel<TAB>sha" lines (may be empty).
_rsdd_apply_kept() {
  awk -F'\t' -v kept="$1" '
    BEGIN { n=split(kept, a, "\n"); for (i=1;i<=n;i++) { if (a[i]=="") continue; split(a[i], f, "\t"); k[f[1]]=f[2] } }
    { if (($2 in k)) printf "%s\t%s\n", k[$2], $2; else print }'
}

# _rsdd_write_bundle_state <h> <home> <profile> [kept] — record what the install just deployed.
# Atomic: the temp file is created in the state file's OWN directory, so the final mv is a same-
# filesystem rename; it is removed on any failure. Refuses to record a bundle with a MISSING member (a
# record must describe real files). [kept] ("rel<TAB>source-sha" lines) names members whose deployed bytes
# are a KEPT hand-edit: the record carries the SOURCE sha and a "kept-hand-edit=<rel>" line, so verify
# reports that member as drifted AND names the hand-edit as the cause, while the members the run did
# redeploy are not blamed.
_rsdd_write_bundle_state() {
  local h="$1" home="$2" profile="$3" kept="${4:-}" root state manifest digest tmp rel
  root="$(rsdd_field "$h" config_root "$home")"
  state="$root/research-sdd/.installed-bundle-state"
  manifest="$(_rsdd_install_members "$h" "$home" | _rsdd_manifest "$root" "$profile")" || return 1
  if awk -F'\t' '$1=="MISSING" { f=1 } END { exit !f }' <<<"$manifest"; then return 1; fi
  manifest="$(printf '%s\n' "$manifest" | _rsdd_apply_kept "$kept")" || return 1
  digest="$(printf '%s\n' "$manifest" | _rsdd_sha256_stdin)" || return 1
  mkdir -p "$(dirname "$state")" || return 1
  tmp="$(mktemp "$state.XXXXXX")" || return 1
  {
    printf 'bundle_sha256=%s\nprofile=%s\n' "$digest" "$profile"
    printf '%s\n' "$manifest" | awk -F'\t' '{printf "file=%s  %s\n", $1, $2}'
    while IFS=$'\t' read -r rel _; do
      [ -z "$rel" ] || printf 'kept-hand-edit=%s\n' "$rel"
    done <<<"$kept"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$state" || { rm -f "$tmp"; return 1; }
}

# _rsdd_verify_kit — print the ONE typed kit-staleness line (kit checkout vs its locally known
# upstream). Read-only: rev-parse/rev-list only, never fetch/pull. Always returns 0 (advisory).
_rsdd_verify_kit() {
  local dir="${RESEARCH_SDD_KIT_DIR:-$KIT}" ref n
  if ! command -v git >/dev/null 2>&1; then
    printf 'verify kit status=degraded reason=git not found; cannot tell whether the kit checkout is behind its upstream\n'; return 0
  fi
  local top d t
  if ! top="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" || [ -z "$top" ]; then
    printf 'verify kit status=degraded reason=kit dir is not a git checkout (%s); cannot tell whether it is behind its upstream\n' "$dir"; return 0
  fi
  # The kit lives at the repo root or one level down (<repo>/research-sdd). A kit dir nested deeper inside
  # an UNRELATED enclosing repo would otherwise report that repo's upstream status as the kit's.
  d="$(cd -P "$dir" 2>/dev/null && pwd -P)"; t="$(cd -P "$top" 2>/dev/null && pwd -P)"
  if [ -z "$d" ] || [ -z "$t" ] || { [ "$t" != "$d" ] && [ "$t" != "$(dirname "$d")" ]; }; then # SENTINEL-KIT-ROOT
    printf 'verify kit status=degraded reason=not the kit checkout root (%s sits inside the unrelated repo %s)\n' "$dir" "$top"; return 0
  fi
  if ref="$(git -C "$dir" rev-parse --abbrev-ref '@{upstream}' 2>/dev/null)" && [ -n "$ref" ]; then :
  elif git -C "$dir" rev-parse --verify --quiet refs/remotes/origin/main >/dev/null 2>&1; then ref="origin/main"
  else
    printf 'verify kit status=degraded reason=no upstream ref (no @{upstream}, no origin/main) in %s\n' "$dir"; return 0
  fi
  if ! n="$(git -C "$dir" rev-list --count "HEAD..$ref" 2>/dev/null)" || ! [[ "$n" =~ ^[0-9]+$ ]]; then
    printf 'verify kit status=degraded reason=could not count HEAD..%s in %s\n' "$ref" "$dir"; return 0
  fi
  if [ "$n" -gt 0 ]; then
    local ahead
    ahead="$(git -C "$dir" rev-list --count "$ref..HEAD" 2>/dev/null)" || ahead=""
    if [[ "$ahead" =~ ^[0-9]+$ ]] && [ "$ahead" -gt 0 ]; then  # SENTINEL-KIT-DIVERGED
      printf 'verify kit status=behind ref=%s behind=%s ahead=%s (diverged: local commits, a fast-forward is not possible — reconcile by hand; local ref, no fetch)\n' "$ref" "$n" "$ahead"
    else
      printf 'verify kit status=behind ref=%s behind=%s (local ref, no fetch — may understate) fix: git -C %s pull --ff-only\n' "$ref" "$n" "$dir"
    fi
  else
    printf 'verify kit status=current ref=%s behind=0 (local ref, no fetch)\n' "$ref"
  fi
  return 0
}

# _rsdd_verify_one <h> <home> — print the ONE typed line for this harness; return 0 match/absent,
# 1 drift, 2 degraded. Never writes anything (no mktemp, no state): hashing is pipes only.
_rsdd_verify_one() {
  local h="$1" home="$2" root state skill tmpl pf profile rec_digest rec_manifest cur_manifest cur_digest
  local nfiles drift_names kept_names rec_calc installed=0 mrc
  root="$(rsdd_field "$h" config_root "$home")"
  state="$root/research-sdd/.installed-bundle-state"
  skill="$(rsdd_field "$h" skill_path "$home")"
  tmpl="$(rsdd_field "$h" prompt_template_path "$home")"
  pf="$(rsdd_field "$h" prompt_file "$home")"

  if ! _rsdd_have_sha256; then
    printf 'verify harness=%s status=degraded reason=no sha256 tool (sha256sum, shasum and python3 all absent)\n' "$h"
    return 2
  fi
  if [ ! -e "$state" ]; then
    [ -e "$skill" ] && installed=1
    [ -n "$tmpl" ] && [ -e "$tmpl" ] && installed=1
    _rsdd_section_text "$pf" >/dev/null && installed=1
    if [ "$installed" = 1 ]; then
      printf 'verify harness=%s status=degraded reason=installed files present but no bundle record (%s) — re-run the installer to record one\n' "$h" "$state"
      return 2
    fi
    printf 'verify harness=%s status=absent (not installed)\n' "$h"
    return 0
  fi
  if [ ! -f "$state" ] || [ ! -r "$state" ]; then
    printf 'verify harness=%s status=degraded reason=bundle record unreadable (%s)\n' "$h" "$state"
    return 2
  fi
  rec_digest="$(_rsdd_marker_field "$state" bundle_sha256)" || rec_digest=""
  profile="$(_rsdd_marker_field "$state" profile)" || profile=""
  rec_manifest="$(awk 'index($0,"file=")==1 { rest=substr($0,6); i=index(rest,"  "); if (i>0) printf "%s\t%s\n", substr(rest,1,i-1), substr(rest,i+2) }' "$state")"
  if [ -z "$rec_digest" ] || [ -z "$profile" ] || [ -z "$rec_manifest" ]; then
    printf 'verify harness=%s status=degraded reason=bundle record corrupt (missing bundle_sha256, profile or file lines)\n' "$h"
    return 2
  fi
  rec_calc="$(printf '%s\n' "$rec_manifest" | _rsdd_sha256_stdin)" || rec_calc=""
  if [ "$rec_calc" != "$rec_digest" ]; then
    printf 'verify harness=%s status=degraded reason=bundle record corrupt (bundle_sha256 does not match its own file lines)\n' "$h"
    return 2
  fi
  mrc=0
  cur_manifest="$(printf '%s\n' "$rec_manifest" | awk -F'\t' '{print $2}' | _rsdd_manifest "$root" "$profile")" || mrc=$?
  if [ "$mrc" = 3 ]; then
    printf 'verify harness=%s status=degraded reason=the rendered profile dir could not be traversed\n' "$h"
    return 2
  elif [ "$mrc" != 0 ]; then
    printf 'verify harness=%s status=degraded reason=a bundle member could not be read or the recorded profile is unsafe\n' "$h"
    return 2
  fi
  cur_digest="$(printf '%s\n' "$cur_manifest" | _rsdd_sha256_stdin)" || {
    printf 'verify harness=%s status=degraded reason=could not hash the current manifest\n' "$h"
    return 2
  }
  nfiles="$(printf '%s\n' "$cur_manifest" | awk 'END{print NR}')"
  if [ "$cur_digest" = "$rec_digest" ]; then
    printf 'verify harness=%s status=match bundle_sha256=%s files=%s\n' "$h" "$cur_digest" "$nfiles"
    return 0
  fi
  drift_names="$(awk -F'\t' '
    NR==FNR { rec[$2]=$1; next }
    { cur[$2]=$1 }
    END {
      for (p in rec) { if (!(p in cur) || cur[p]=="MISSING") print p " (missing)"; else if (cur[p]!=rec[p]) print p " (modified)" }
      for (p in cur) if (!(p in rec) && cur[p]!="MISSING") print p " (extra)"
    }' <(printf '%s\n' "$rec_manifest") <(printf '%s\n' "$cur_manifest") | LC_ALL=C sort | paste -sd, -)"
  if [ -z "$drift_names" ]; then
    printf 'verify harness=%s status=degraded reason=digest differs from the record but no member differs (inconsistent record)\n' "$h"
    return 2
  fi
  # Name a kept hand-edit only while that member is itself still drifted; a restored file is not blamed.
  kept_names="$(awk -v d=",$drift_names," 'index($0,"kept-hand-edit=")==1 { k=substr($0,16); if (index(d, "," k " (")) print k }' "$state" | paste -sd, -)"
  if [ -n "$kept_names" ]; then
    printf 'verify harness=%s status=drift drifted=%s kept-hand-edit=%s\n' "$h" "$drift_names" "$kept_names"
  else
    printf 'verify harness=%s status=drift drifted=%s\n' "$h" "$drift_names"
  fi
  return 1
}

# --- the ONE install loop body — table-driven, no per-harness branching --------------------------
install_one() {
  local h="$1" home="$2" dry="$3" force="$4" profile="$5" profile_source="$6" rc=0
  local skill_path prompt_file strategy slash dispatch src_relkit src_skill
  local config_root marker
  skill_path="$(rsdd_field "$h" skill_path "$home")"
  prompt_file="$(rsdd_field "$h" prompt_file "$home")"
  strategy="$(rsdd_field "$h" prompt_strategy "$home")"
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

  # 2b. optional slash-command prompt template (pi / gentle-shell: prompts/research-sdd.md → /research-sdd).
  #     The adapter field is EMPTY for every other harness, so nothing is planned or written for them.
  #     Deployed through the SAME divergence-checked helpers as the skill (CLAUDE.md §7 three-state
  #     rule): a hand-edited template is kept with a warning, --force-skill backs it up first, and a
  #     template matching the installer's own recorded hash is a managed (silent) update. Its marker is
  #     a SEPARATE file (.installed-template-state) with a constant profile "template", so the skill's
  #     profile-switch / orphan-render-cleanup logic never fires for it. A rendered body is staged in a
  #     temp file because those helpers copy a SOURCE FILE.
  local template_dest tmpl_marker tmpl_src
  template_dest="$(rsdd_field "$h" prompt_template_path "$home")"
  if [ -n "$template_dest" ]; then
    tmpl_marker="$config_root/research-sdd/.installed-template-state"
    if ! tmpl_src="$(mktemp)"; then
      echo "research-sdd-install: [$h] mktemp failed" >&2; rc=1
    elif ! rsdd_render_prompt_template "$h" "$home" > "$tmpl_src"; then
      echo "research-sdd-install: [$h] rendering the prompt template failed" >&2; rc=1
    elif [ "$dry" = 1 ]; then
      _rsdd_dry_skill_plan "$tmpl_src" "$template_dest" "$force" "slash-command prompt template" "$tmpl_marker" "template" || rc=1
      emit_section "$(cat "$tmpl_src")"
    else
      _rsdd_deploy_skill "$tmpl_src" "$template_dest" "$force" "slash-command prompt template" "$h" "$tmpl_marker" "template" "$config_root" || rc=1
    fi
  fi

  # 3. record the bundle digest (kit issue #1702) — only when the run succeeded. A kept hand-edit is
  #    recorded with the SOURCE sha this run meant to deploy plus a `kept-hand-edit=<rel>` line, so it is
  #    never the baseline: --verify keeps reporting it as drift (and names it) until it is restored.
  if [ "$dry" != 1 ] && [ "$rc" = 0 ]; then
    local kept="" ksha
    if ! cmp -s "$src_skill" "$skill_path"; then
      ksha="$(_rsdd_sha256_file "$src_skill")" || ksha=""
      kept="${skill_path#"$config_root"/}"$'\t'"$ksha"
    fi
    if [ -n "$template_dest" ] && ! cmp -s "$tmpl_src" "$template_dest"; then
      ksha="$(_rsdd_sha256_file "$tmpl_src")" || ksha=""
      kept="${kept:+$kept$'\n'}${template_dest#"$config_root"/}"$'\t'"$ksha"
    fi
    if [[ "$kept" == *$'\t' ]] || [[ "$kept" == *$'\t\n'* ]]; then
      echo "research-sdd-install: [$h] could not hash the source of a kept hand-edit — bundle record not written" >&2
      rc=1
    else
      [ -z "$kept" ] || echo "research-sdd-install: [$h] a deployed file differs from this run's source (kept hand-edit) — recorded with the source digest; --verify will report it as drift" >&2
      if ! _rsdd_write_bundle_state "$h" "$home" "$profile" "$kept"; then
        echo "research-sdd-install: [$h] could not write the bundle record under $config_root/research-sdd/" >&2
        rc=1
      fi
    fi
  fi
  [ -z "${tmpl_src:-}" ] || rm -f "$tmpl_src"

  printf '  slash_commands=%s\n' "$slash"
  return "$rc"
}

main() {
  local harness="all" home="$HOME" dry=0 force=0 profile_flag="" verify=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --harness)     harness="${2:-}"; shift 2 ;;
      --home)        home="${2:-}"; shift 2 ;;
      --dry-run)     dry=1; shift ;;
      --force-skill) force=1; shift ;;
      --verify)      verify=1; shift ;;
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

  # --verify (kit issue #1702): read-only, one typed line per harness, no profile resolution (the
  # recorded profile is read from the bundle record). Exit: 0 all match/absent · 1 drift · 2 any
  # degraded (outranks drift). Install-mode flags make no sense here → usage error.
  if [ "$verify" = 1 ]; then
    if [ "$dry" = 1 ] || [ "$force" = 1 ] || [ -n "$profile_flag" ]; then
      echo "research-sdd-install: --verify is read-only and cannot be combined with --dry-run, --force-skill or --profile" >&2
      usage >&2; return 2
    fi
    local vrc=0 one drift=0 degraded=0
    for h in $list; do
      one=0; _rsdd_verify_one "$h" "$home" || one=$?
      case "$one" in 0) ;; 1) drift=1 ;; *) degraded=1 ;; esac
    done
    _rsdd_verify_kit  # SENTINEL-VERIFY-KIT
    [ "$degraded" = 1 ] && vrc=2
    [ "$degraded" = 0 ] && [ "$drift" = 1 ] && vrc=1
    return "$vrc"
  fi

  # Resolve + validate the EFFECTIVE prompt profile for every harness up front (kit issue #993
  # WU2) — fail fast with one clear message before touching the filesystem, dry-run or not.
  # Precedence (rsdd_resolve_profile): --profile flag > $RESEARCH_SDD_PROFILE env > this
  # harness's per-harness default (adapters.sh _RSDD_DEFAULT_PROFILE). A flag/env value applies
  # uniformly to every harness in $list; the default table can differ per harness (e.g. pi
  # defaults to "general" while claude defaults to "claude").
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
