#!/usr/bin/env bash
# hook-wiring.sh — shared helper: is a target's Stop hook registered to run retro-gate?
#
# WHY: this predicate originally lived only as an inline awk pipeline inside sweep-retros.sh's
# WIRING-STATUS fleet pass. Kit issue #1108 needs the SAME check inside verify-registry.sh (to
# reconcile a TARGETS.md row's 'hook yes' claim against reality), and kit issue #1109 needs it
# inside research-sdd-status.sh (to self-report wiring for the one target being reported on). All
# three source this file instead of carrying their own copy, so all three MUST agree — a row or
# a self-report claiming 'wired' while sweep-retros disagrees defeats the whole point of §18
# supervision.
#
#   hook_stop_wiring_state_var <target-dir>
#     Sets the GLOBAL $HOOK_WIRING_STATE to exactly one of: wired | wired-off-root | unwired |
#     absent-settings | unreadable. NEVER forks a subshell (no command substitution anywhere in
#     this function, for ANY state — kit issue #1140 round-2 review, Blocking 3: an earlier
#     revision paid a `$(git ...)` fork plus a `$(cd -P ... && pwd -P)` fork on every already-
#     'wired' result, which is the MAJORITY state on the real fleet, not a minority — measured
#     13-14 of 17 reachable targets. The git-root check below uses ONLY builtins: `[ -e ]` tests
#     and parameter-expansion path-walking, no `git` binary, no subshell), so a caller iterating
#     many targets (sweep-retros.sh's WIRING-STATUS fleet pass) can call this directly instead of
#     paying a `$(...)` fork per target. Always returns 0 — callers branch on $HOOK_WIRING_STATE,
#     never on exit status.
#
#     NARROWER than the TARGETS.md legend's 'hook' flag definition (kit issue #1108 round 2):
#     the legend recognises a hook as registered via THREE paths — project-level
#     <target>/.claude/settings.json, project-level <target>/.claude/settings.local.json, or
#     user-level ~/.claude/settings.json referencing the hook by absolute path. This function
#     checks ONLY the first — <target-dir>/.claude/settings.json — because that is the ORIGINAL
#     sweep-retros.sh WIRING-STATUS behavior this file extracted verbatim, and sweep-retros.sh's
#     real-fleet output must stay byte-identical (kit issue #1108's own acceptance gate). A
#     target correctly wired ONLY via settings.local.json or the user-level file will be
#     misreported unwired/absent-settings here — this is a pre-existing gap this extraction
#     carries forward unchanged, not a new one. Measured incidence on the real fleet (kit issue
#     #1108 round 2): 0 of the 17 reachable targets; 5 of the 16 unreachable targets claim
#     'hook yes' and could not be checked either way. Widening this predicate to the legend's
#     full definition is a separate, scoped follow-up — not folded into this fix per the kit's
#     "a sampling-rule/calibration-constant change is its own work unit" doctrine.
#       - absent-settings : <target-dir>/.claude/settings.json does not exist
#       - unreadable      : it exists but cannot be read (permission error)
#       - wired           : it is readable and its top-level "Stop" hooks array registers a
#                            command containing "retro-gate" — scoped STRICTLY to the Stop event
#                            block. A "retro-gate" substring under SessionStart, under
#                            permissions.deny, or inside an unrelated comment/string field
#                            elsewhere in the file never counts.
#       - unwired         : it is readable but no such Stop-scoped entry is found
#       - wired-off-root  : kit issue #1135 — it IS Stop-scoped-wired (as above), but <target-dir>
#                            is NOT its own git root (an ancestor directory owns the nearest
#                            `.git`). This is a STRUCTURAL fact only. Claude Code loads project
#                            settings from the directory a session is LAUNCHED in, so the hook
#                            fires ONLY for a session launched in EXACTLY <target-dir> — never
#                            above it, never at a sibling directory.
#
#                            This predicate deliberately does NOT claim to know where sessions
#                            actually launch from, and does not prescribe a fix (kit issue #1140
#                            round-2 review, Blocking 1 — a false claim here once shipped): an
#                            earlier revision asserted "a real session almost always launches from
#                            the git root" and told the maintainer to "move the hook registration
#                            to the git root". Both claims are WRONG for the one real case this
#                            predicate has ever flagged (three.js, TARGETS.md row 13): reading its
#                            session transcripts (kit issue #1140 round-2 review; read-only,
#                            outside this tool) shows 0 of its sessions launched at the git root —
#                            they launched from the non-git PARENT `~/prototipos/three.js` (8
#                            transcripts) and two sibling subdirectories (8 and 3 transcripts).
#                            Moving the registration to the git root would have left the hook
#                            exactly as silent as it already is. The correct remediation is a
#                            human decision (kit issue #1134) — this predicate's only job is to
#                            report the structural fact honestly and point at that decision,
#                            never to guess which directory is "right".
#
#                            FALSE-NEGATIVE class (kit issue #1140 round-2 review): a target
#                            registered AT its own git root can still have sessions launching from
#                            a non-git parent or a sibling directory — this predicate reports plain
#                            'wired' for such a target indistinguishably from one whose sessions
#                            truly do launch at the registered path, because "registered path is
#                            its own git root" is a structural PROXY for "sessions launch from the
#                            registered path", not the thing itself. Measured on the real fleet
#                            (same review, transcripts read manually): 1 of 28 Pancaddia sessions
#                            ran from `~/tunnel/clientes` rather than the registered git-root path,
#                            and `~/prototipos/clientes` (a sibling of the hisense target) carries
#                            one session too. This predicate cannot see that class at all — it only
#                            ever compares the registered path against its OWN git root, never
#                            against real session launch directories (and must not: this file does
#                            not read `~/.claude/projects` or any session transcript — that reading
#                            was a one-time manual review activity, not a runtime capability).
#
#                            Downgrade applies ONLY to an otherwise-'wired' result: an unwired,
#                            absent-settings, or unreadable target makes no active-firing claim in
#                            the first place, so there is nothing to downgrade (no WARN class
#                            exists for e.g. a nested 'hook no' row). When no `.git` is found
#                            anywhere from <target-dir> up to `/` (the target is not inside any git
#                            repository at all — the ORIGINAL, pre-#1135 behavior for every fixture
#                            that predates this check), the result is left 'wired' rather than
#                            guessed. No `git` binary is required and none of git's own failure
#                            modes (missing binary, a `safe.directory` / dubious-ownership refusal)
#                            can produce a silent false 'wired' here (kit issue #1140 round-2
#                            review, Blocking 2) — the walk below reads the filesystem directly via
#                            `[ -e ]`, never shells out.
#     This mirrors the kit's §7 anti-silent-zero doctrine: absent-settings, unreadable, unwired, and
#     wired-off-root are all distinct non-fully-wired states, never collapsed into a single "not
#     wired" bucket that would hide which one actually happened. The `awk` call below still forks
#     its OWN subprocess (unavoidable — this is shell, not awk-native) but that is one fork per
#     target either way, the same cost every state has always paid; the walk-up that detects
#     wired-off-root adds ZERO further forks on top of it.
#
#   hook_stop_wiring_state <target-dir>
#     Convenience wrapper: calls hook_stop_wiring_state_var, then prints $HOOK_WIRING_STATE to
#     stdout. For a caller that only needs the state ONCE (verify-registry.sh's per-row
#     reconciliation, research-sdd-status.sh's single self-report line), `$(hook_stop_wiring_state
#     "$dir")` is the simplest idiom and the one extra fork is immaterial. A caller iterating many
#     targets in a tight loop should call hook_stop_wiring_state_var directly instead.
#
#   Env: RSDD_HOOK_WIRING_CEILING — an absolute directory path (kit issue #1140 round-2 review,
#     Blocking 4). When set, the git-root walk-up NEVER scans this directory or anything above it
#     — it reports "no git root found above <target>" as soon as it would reach the ceiling,
#     exactly as if `/` had been reached. Unset (the default) walks all the way to `/`.
#     WHY THIS EXISTS: a test fixture's own sandbox root comes from `mktemp -d`, which honors
#     $TMPDIR. If $TMPDIR itself sits inside a REAL git repository — this very kit checkout is one
#     — every fixture meant to model "target IS its own git root" silently becomes "target is
#     NESTED under some enclosing repo" instead, because the walk-up (correctly) keeps climbing
#     past the fixture's own root and finds the enclosing repo's real `.git`. Test suites that
#     build fixtures with `mktemp -d` MUST set this to (at least) the parent of their sandbox root
#     before sourcing/invoking this lib, or run under a $TMPDIR guaranteed not to be inside a repo.
#
# Idempotent: safe to source more than once.

if ! declare -F _hw_find_git_root >/dev/null 2>&1; then
  # _hw_find_git_root <dir> : sets $HW_GIT_ROOT to the nearest ancestor of <dir> (inclusive of
  # <dir> itself) that owns a `.git` entry (file or directory — a linked worktree's `.git` is a
  # FILE, and this must recognise that too), or "" if none is found before reaching `/` or the
  # $RSDD_HOOK_WIRING_CEILING. Pure builtins only — [ -e ] and parameter expansion — NO fork, NO
  # git binary. `[ -e ]` resolves symlinks per path component at the kernel level, so this is
  # symlink-safe by construction: it never needs `pwd -P` / `cd -P` canonicalization to be
  # correct, because it only ever needs to know WHETHER <dir> itself owns a `.git` versus some
  # ancestor doing so — not the canonical spelling of either path.
  # KNOWN LIMITATION (kit issue #1140 round-2 review, smaller items — measured, not hypothetical):
  # a SYMLINKED LEAF works correctly — `[ -e "$d/.git" ]` follows a symlink at the final path
  # component, so a target that IS a symlink pointing directly at a git root (or that itself
  # contains a real `.git`, symlink or not) resolves correctly. A symlink in an INTERMEDIATE path
  # component does NOT: the walk climbs the TARGET STRING's own textual ancestors
  # (`${d%/*}`), never the symlink's resolution target, so a `.git` that only exists via
  # following an intermediate symlink is missed and the result stays 'wired' — a false negative,
  # not a false positive (it never invents a WARN; it can only fail to raise one). Resolving this
  # fully needs `realpath`/`pwd -P`, which forks — reintroducing exactly the per-target fork
  # Blocking 3 removed from the MAJORITY ('wired') case. TARGETS.md paths are real directories
  # under $RESEARCH_HOME in the fleet as measured, not symlinks, so this gap's incidence is 0 of 17
  # reachable targets today (measure-before-remediate, kit §7) — flagged here rather than fixed
  # with a fork every caller would pay for a case that has not occurred.
  _hw_find_git_root() {
    local d="$1" ceiling="${RSDD_HOOK_WIRING_CEILING:-}"
    case "$d" in
      */) d="${d%/}" ;;
    esac
    [ -z "$d" ] && d="/"
    while :; do
      if [ -n "$ceiling" ] && [ "$d" = "$ceiling" ]; then  # HOOK-WIRING-CEILING-CHECK
        HW_GIT_ROOT=""
        return 0
      fi
      if [ -e "$d/.git" ]; then  # HOOK-WIRING-GITDIR-CHECK
        HW_GIT_ROOT="$d"
        return 0
      fi
      if [ "$d" = "/" ]; then
        HW_GIT_ROOT=""
        return 0
      fi
      d="${d%/*}"
      [ -z "$d" ] && d="/"
    done
  }
fi

if ! declare -F hook_stop_wiring_state_var >/dev/null 2>&1; then
  hook_stop_wiring_state_var() {
    local target="$1" settings
    settings="$target/.claude/settings.json"
    if [ ! -e "$settings" ]; then
      HOOK_WIRING_STATE="absent-settings"; return 0
    fi
    if [ ! -r "$settings" ]; then
      HOOK_WIRING_STATE="unreadable"; return 0
    fi
    if awk '
      BEGIN { in_stop=0; stop_depth=0; depth=0; found=0 }
      {
        n=length($0); i=1
        while (i<=n) {
          c=substr($0,i,1)
          if (c=="{" || c=="[") {
            depth++
          } else if (c=="}" || c=="]") {
            depth--
            if (in_stop && depth<=stop_depth) { in_stop=0 }
          } else if (!in_stop && substr($0,i,6)=="\"Stop\"") {
            j=i+6
            while (j<=n && (substr($0,j,1)==" " || substr($0,j,1)=="\t")) j++
            if (j<=n && substr($0,j,1)==":") { in_stop=1; stop_depth=depth }
            i=j
          } else if (in_stop && substr($0,i,10)=="retro-gate") {
            found=1
          }
          i++
        }
      }
      END { exit !found }
    ' "$settings" 2>/dev/null; then
      HOOK_WIRING_STATE="wired"
    else
      HOOK_WIRING_STATE="unwired"
    fi
    # SESSION-ROOT CHECK (kit issue #1135): only ever runs on an already-'wired' result — see this
    # file's header for the full rationale, including the false-negative class this does NOT
    # detect. Fork-free walk-up (kit issue #1140 round-2 review, Blocking 3) — no git, no subshell.
    if [ "$HOOK_WIRING_STATE" = "wired" ]; then
      local _hw_target_norm
      _hw_target_norm="$target"
      case "$_hw_target_norm" in
        */) _hw_target_norm="${_hw_target_norm%/}" ;;
      esac
      [ -z "$_hw_target_norm" ] && _hw_target_norm="/"
      _hw_find_git_root "$target"
      if [ -n "$HW_GIT_ROOT" ] && [ "$HW_GIT_ROOT" != "$_hw_target_norm" ]; then  # WIRED-OFF-ROOT-CHECK
        HOOK_WIRING_STATE="wired-off-root"
      fi
    fi
    return 0
  }
fi

if ! declare -F hook_stop_wiring_state >/dev/null 2>&1; then
  hook_stop_wiring_state() {
    hook_stop_wiring_state_var "$1"
    printf '%s' "$HOOK_WIRING_STATE"
    return 0
  }
fi
