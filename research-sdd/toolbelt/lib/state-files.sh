#!/usr/bin/env bash
# state-files.sh — enumerate every RESEARCH-STATE*.md in a corpus directory.
# Shared by research-sdd-archive.sh, research-sdd-status.sh, and any future consumer
# that needs ALL state files for a corpus.
#
#   list_state_files <dir>
#     Prints the absolute (or dir-relative) sorted paths of every
#     RESEARCH-STATE*.md under <dir> (maxdepth 3, *.template.md excluded,
#     .git excluded), one per line. Returns 0; prints nothing if none found.
#
# Drift hazard: this file is the SINGLE definition of the "enumerate state files"
# incantation for gate/aggregation consumers. Do NOT copy-paste the find command
# into a new consumer; source this library instead. The find flags here MUST match
# the canonical pattern in verify-state.sh:33, which predates this library and is
# the authoritative reference for the exclusion set.
#
# Scope of this rule: gate/aggregation consumers (--sync-state seeding, --next
# multi-focus scan, archive enumeration). ROOT DISCOVERY (the single `find | head -1`
# that determines $corpus at startup) uses the SAME incantation but occurs before this
# library is sourced (the lib path uses $here which is computed after $corpus); it is
# therefore the one legitimate exception — same flags, different ordering constraint.
# The --focus <slug> selection (searches for a SPECIFIC filename) is a semantically
# different operation and is NOT governed by this rule.
#
# Idempotent: safe to source more than once (multiple consumers may pull it in
# the same shell; declare -F guard prevents double-definition). Follow the pattern
# of lib/retro-status.sh and lib/focus-prefix.sh.

# shellcheck disable=SC2148   # intentionally no shebang guard — always sourced, never executed
if ! declare -F list_state_files >/dev/null 2>&1; then
  list_state_files() {
    local corpus="$1"
    find "$corpus" -maxdepth 3 \
      -name 'RESEARCH-STATE*.md' \
      -not -name '*.template.md' \
      -not -path '*/.git/*' \
      2>/dev/null | sort
  }
fi
