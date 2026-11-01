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
# PORTED TO GO (kit issue #2356, U2.3a): the first half of this library - hook_stop_wiring_state(_var),
# hook_stop_script_state(_var) and _hw_find_git_root - is a set of shims over `rsdd hook wiring-state|script-state|git-root
# <arg>` (research-sdd/rsdd/internal/hook, resolved through lib/rsdd-exec.sh). The rules below are unchanged and now live in
# Go, pinned by internal/hook's tests and by a differential test against a frozen copy of the bash they replace. What the
# shims decide themselves: the environment handed to rsdd, which answers are accepted, and how a failure reads. When rsdd is
# unavailable (or answers anything outside the documented states, or exits non-zero) the typed
# `degraded: rsdd-unavailable` line goes to stderr and the state reads "unreadable" (wiring: the wiring is UNKNOWN; it never
# reads wired, unwired or absent-settings) or "degraded" (script state, the existing "measurement invalid, not a zero"
# state).
#
# PORTED TO GO (kit issue #2357, U2.3b): the second half - hook_stop_launch_state(_var), hook_stop_launch_states_var and
# hook_wired_exec_report - is the same kind of shim over `rsdd hook launch-state|wired-exec` (_hw_abspath, _hw_split_cmd,
# _hw_unv and _hw_check_command are gone: Go owns them, internal/hook AbsPath / splitCommand / checkCommand). A failing or
# unavailable rsdd reads "unknown" for the launch state (the instrument could not look) and as ONE unverifiable finding for the
# wired-exec report; neither ever reads as a clean answer. The Go entry points another tool can call in process are
# internal/hook LaunchState and WiredExecReport. Differences from the shell original, all deliberate: settings.json is
# always parsed natively (the old "jq not on PATH" text-match fallback and its note no longer exist), and the launch-history
# root is taken literally (it was a glob pattern).
#
#   hook_stop_wiring_state_var <target-dir>
#     Sets the GLOBAL $HOOK_WIRING_STATE to exactly one of: wired | wired-off-root | unwired |
#     absent-settings | unreadable. COST: one nested subshell and one rsdd exec per call (kit issue #2356; it was one
#     awk fork before the port). sweep-retros.sh's WIRING-STATUS fleet pass uses the batch form below instead (one rsdd for the fleet); the git-root / off-root check is part of the same rsdd call.
#     Always returns 0 — callers branch on $HOOK_WIRING_STATE, never on exit status.
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
#                            `.git`). This is a STRUCTURAL fact only. Per observed Claude Code
#                            behavior (project settings load from the session's launch directory —
#                            not a cited spec; see kit issue #1134), the hook is EXPECTED to fire
#                            only for a session launched in exactly <target-dir> — never above it,
#                            never at a sibling directory — but this predicate does not verify
#                            that behavior itself; it only reports the structural mismatch.
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
#                            against real session launch directories. History of this rule: until kit
#                            issue #1157 this file stated "must not read `~/.claude/projects` or any
#                            session transcript — that reading was a one-time manual review activity,
#                            not a runtime capability". DESIGN DECISION (kit issue #1157): that rule is
#                            LIFTED for one scoped purpose — detecting "registered but never loaded"
#                            requires launch evidence, and #1157's own evidence cites that history.
#                            New scope: directory/glob EXISTENCE only (a `*.jsonl` name under the
#                            project's history directory), NEVER transcript contents. The wiring state
#                            itself stays history-blind (sweep-retros.sh stays byte-identical); the
#                            launch question is the SEPARATE predicate hook_stop_launch_state_var at
#                            the end of this file.
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
#     wired" bucket that would hide which one actually happened. (Before the Go port the Stop scan was
#     one awk fork per call and the walk-up that detects wired-off-root added none; both now run inside the single rsdd call.)
#
#   hook_stop_wiring_states_var <target-dir>...
#     Batch form (kit issue #2356): ONE rsdd exec for every target. Sets the ARRAY $HOOK_WIRING_STATES, one element per
#     target in argument order, each exactly one of the five states above. If rsdd fails, answers a different number of
#     lines than targets, or any line is not one of the five states, EVERY element reads "unreadable" (wiring unknown, never
#     a silent wired/unwired; the typed `degraded: rsdd-unavailable` line is on stderr when rsdd could not be resolved).
#     No targets: an empty array and no rsdd call. Always returns 0. sweep-retros.sh's WIRING-STATUS pass uses it.
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

# --- rsdd bridge (kit issue #2356) ------------------------------------------------------------------------------
# lib/rsdd-exec.sh is loaded on first USE of a ported function, never at source time: sourcing this file stays free and
# silent (a caller may source it under a PATH with no external commands and only use the second half).
if ! declare -F _hw_rsdd >/dev/null 2>&1; then
  _HW_SELF="${BASH_SOURCE[0]}"
  case "$_HW_SELF" in /*) ;; *) _HW_SELF="$PWD/$_HW_SELF" ;; esac   # builtins only; the symlink walk waits for first use

  # _hw_rsdd_load : makes rsdd_exec available. A missing rsdd-exec.sh is announced once and leaves a rsdd_exec that fails,
  # so the ported functions read as unavailable instead of as a clean answer.
  _hw_rsdd_load() {
    local s="$_HW_SELF" n=0 t libdir
    # own directory from BASH_SOURCE with symlinks followed (the kit #1675 idea, lazily and with local variables) - never $0 or the caller cwd.
    while [ -L "$s" ] && [ "$n" -lt 40 ]; do n=$((n + 1)); t="$(readlink -- "$s")" || break; case "$t" in /*) s="$t" ;; *) s="$(dirname -- "$s")/$t" ;; esac; done
    libdir="$(CDPATH='' cd -- "$(dirname -- "$s")" && pwd -P)"
    # shellcheck source=rsdd-exec.sh
    . "$libdir/rsdd-exec.sh" 2>/dev/null || {
      printf 'degraded: rsdd-unavailable — rsdd-exec.sh missing beside %s\n' "$_HW_SELF" >&2
      rsdd_exec() { return 2; }
    }
  }

  # _hw_rsdd <cmd> <arg>... : runs `rsdd hook <cmd> <arg>...`; sets _HW_OUT to its stdout minus the ONE trailing newline the
  # command adds (embedded and further trailing newlines of a payload are kept) and _HW_RC to its exit status.
  # rsdd_exec ends in `exec`, so it runs in its own subshell; the status is appended after the output so that $(...)
  # cannot strip a payload's trailing newlines. RSDD_HOOK_WIRING_CEILING, RSDD_CLAUDE_PROJECTS_DIR, CLAUDE_CONFIG_DIR and HOME
  # are handed over explicitly: the bash lib read them as plain variables, which need not be exported (an empty value reads
  # like an unset one to rsdd).
  _hw_rsdd() {
    local out
    declare -F rsdd_exec >/dev/null 2>&1 || _hw_rsdd_load
    out="$( ( RSDD_HOOK_WIRING_CEILING="${RSDD_HOOK_WIRING_CEILING:-}" RSDD_CLAUDE_PROJECTS_DIR="${RSDD_CLAUDE_PROJECTS_DIR:-}" CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-}" HOME="${HOME:-}" rsdd_exec hook "$@" ); printf '|%s' "$?")"
    _HW_RC="${out##*|}"
    out="${out%|*}"
    _HW_OUT="${out%$'\n'}"   # HW-ONE-NEWLINE
  }
fi

if ! declare -F _hw_find_git_root >/dev/null 2>&1; then
  # NOTE: $HW_GIT_ROOT is always a real git-root path or "" (kit issue #1696). When the target AS
  # SPELLED owns a `.git` (RAW-TARGET CHECK below) it is that spelled path and $HW_TARGET_IS_ROOT is
  # "1"; in every other outcome $HW_TARGET_IS_ROOT is "0".
  # _hw_find_git_root <dir> : sets $HW_GIT_ROOT to the nearest ancestor of <dir> (inclusive of
  # <dir> itself) that owns a `.git` entry (file or directory — a linked worktree's `.git` is a
  # FILE, and this must recognise that too), or "" if none is found before reaching `/` or the
  # $RSDD_HOOK_WIRING_CEILING. (Go: only existence tests and string path-walking - no
  # git binary, no `realpath`/`pwd -P`.) `[ -e "$d/.git" ]` DOES resolve a symlink AT THAT ONE
  # CHECK, at the kernel level — so it correctly answers "does <d> itself own a `.git`" even when
  # <d> is a symlink. It is NOT symlink-safe overall, because the CLIMB (`${d%/*}`) and the
  # off-root COMPARISON both work on the target STRING's own textual spelling, never on any
  # symlink's resolution target. See the KNOWN LIMITATION below for exactly which shapes that
  # breaks.
  # KNOWN LIMITATION (kit r3 review, M2 — CORRECTED: an earlier revision of this comment, and its
  # test 14a, mislabeled this case "intermediate component" and claimed leaf symlinks "work
  # correctly"; test 14a is actually a LEAF symlink, and it does NOT work correctly — see below):
  # `[ -e "$d/.git" ]` follows a symlink at the FINAL path component, so a LEAF symlink pointing
  # DIRECTLY at a git ROOT (its resolved target itself owns `.git` — test 14b) resolves correctly
  # on the very FIRST check, before any climbing happens. A leaf symlink pointing at a NESTED,
  # non-root directory (test 14a) does NOT: once the walk needs to climb past the leaf, it climbs
  # the SYMLINK'S OWN textual path, never the resolved target's real ancestors, so the real git
  # root behind the resolved path is never found and the result stays 'wired' — a false negative
  # (that shape only fails to raise a WARN it should have; the one false-positive shape, a symlink
  # followed by '..' that lands on a git root, is answered by the raw-target check, kit issue #1153
  # — a symlink followed by '..' that lands on a NON-root directory of a different tree can still
  # climb the wrong textual ancestors, same root cause, unmeasured). A genuinely
  # INTERMEDIATE symlinked path component (a real directory nested under a symlinked ancestor) is
  # a distinct, currently UNTESTED shape with the same root cause. Resolving either fully needs
  # `realpath`/`pwd -P`, which forks — reintroducing exactly the per-target fork Blocking 3 removed
  # from the MAJORITY ('wired') case. TARGETS.md paths are real directories under $RESEARCH_HOME in
  # the fleet as measured, not symlinks, so this gap's incidence is 0 of 17 reachable targets today
  # (measure-before-remediate, kit §7) — flagged here rather than fixed with a fork every caller
  # would pay for a case that has not occurred.
  # SHIM (kit issue #2356): the walk-up is `rsdd hook git-root <dir>` (internal/hook/pathwalk.go); line 1 of its answer is
  # HW_TARGET_IS_ROOT, the rest is HW_GIT_ROOT. A failing rsdd leaves no root (flag 0, root "") after the typed
  # `degraded: rsdd-unavailable` line; the function still returns 0.
  # shellcheck disable=SC2034  # the HW_* results are read by the callers and by tests/hook-wiring.test.sh
  _hw_find_git_root() {
    HW_TARGET_IS_ROOT=0; HW_GIT_ROOT=""
    _hw_rsdd git-root "$1"
    [ "$_HW_RC" = 0 ] || return 0
    case "$_HW_OUT" in
      0$'\n'*) HW_GIT_ROOT="${_HW_OUT#0$'\n'}" ;;
      1$'\n'*) HW_TARGET_IS_ROOT=1; HW_GIT_ROOT="${_HW_OUT#1$'\n'}" ;;   # HW-ROOT-FLAG
    esac
    return 0
  }
fi

if ! declare -F hook_stop_wiring_state_var >/dev/null 2>&1; then
  # SHIM (kit issue #2356): `rsdd hook wiring-state <target>`. Only the five documented states are accepted from a
  # successful run; anything else (rsdd unavailable, a non-zero exit, an unknown answer) reads "unreadable": the wiring is
  # UNKNOWN, and the typed `degraded: rsdd-unavailable` line is on stderr when rsdd could not be resolved.
  hook_stop_wiring_state_var() {
    _hw_rsdd wiring-state "$1"
    case "$_HW_RC:$_HW_OUT" in
      0:wired|0:wired-off-root|0:unwired|0:absent-settings|0:unreadable) HOOK_WIRING_STATE="$_HW_OUT" ;;
      *) HOOK_WIRING_STATE="unreadable" ;;
    esac
    return 0
  }
fi

if ! declare -F hook_stop_wiring_states_var >/dev/null 2>&1; then
  # BATCH SHIM (kit issue #2356): `rsdd hook wiring-state <target>...` once for every target. Sets the array
  # HOOK_WIRING_STATES, one element per target in argument order. The answer is accepted only as a whole: a failing rsdd, a
  # line count that differs from the target count, or ANY line outside the five states reads "unreadable" for EVERY
  # element (the wiring is unknown; it never reads a silent wired/unwired). No targets: an empty array, rsdd not called.
  hook_stop_wiring_states_var() {
    local _hw_n=0 _hw_rest _hw_line _hw_i _hw_ok=1 _hw_last=0
    HOOK_WIRING_STATES=()
    [ "$#" -gt 0 ] || return 0
    _hw_rsdd wiring-state "$@"
    if [ "$_HW_RC" = 0 ]; then
      _hw_rest="$_HW_OUT"
      while :; do
        case "$_hw_rest" in
          *$'\n'*) _hw_line="${_hw_rest%%$'\n'*}"; _hw_rest="${_hw_rest#*$'\n'}" ;;
          *)        _hw_line="$_hw_rest"; _hw_rest=""; _hw_last=1 ;;
        esac
        case "$_hw_line" in
          wired|wired-off-root|unwired|absent-settings|unreadable) HOOK_WIRING_STATES[_hw_n]="$_hw_line" ;;
          *) _hw_ok=0 ;;
        esac
        _hw_n=$(( _hw_n + 1 ))
        [ "$_hw_last" = 0 ] || break
      done
    fi
    # an empty line (also a trailing one) counts as a line and fails the vocabulary check
    if [ "$_HW_RC" = 0 ] && [ "$_hw_n" = "$#" ] && [ "$_hw_ok" = 1 ]; then  # HW-BATCH-GUARD
      return 0
    fi
    HOOK_WIRING_STATES=()
    for _hw_i in "$@"; do HOOK_WIRING_STATES+=("unreadable"); done
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

# --- SCRIPT-RESOLUTION state (kit issue #1157) ---------------------------------------------------
#   hook_stop_script_state_var <target-dir>
#     Sets the GLOBAL $HOOK_SCRIPT_STATE to exactly one of:
#       present      : at least one Stop-scoped retro-gate command names a script that exists and
#                      can be opened for reading — the hook CAN load.
#       missing      : EVERY Stop-scoped retro-gate command was resolved unambiguously to a path
#                      that does not exist (or cannot be opened) — the hook is REGISTERED in
#                      settings.json but can NEVER load. One present entry wins ('present'); one
#                      unresolvable entry prevents 'missing' ('unverifiable'). 'missing' is a firm
#                      claim, so it is emitted only when no entry was ambiguous. Distinct from 'wired'
#                      in hook_stop_wiring_state_var: that predicate is a text match on the settings
#                      file and is DELIBERATELY unchanged (sweep-retros.sh and research-sdd-status.sh
#                      stay byte-identical); this is a separate question callers ask AFTER
#                      'wired'/'wired-off-root'.
#       unverifiable : no entry could be confirmed present and at least one could not be resolved to
#                      a path unambiguously — see "Resolved forms" for what does resolve. This is
#                      "the instrument could not look", never a claim in either direction (§7).
#       no-entry     : settings.json is absent or unreadable, or its Stop block has no retro-gate
#                      command — there is nothing to resolve (the wiring state names which).
#       degraded     : awk is unavailable or failed — the measurement is invalid, NOT a zero.
#     Resolved forms (the ONLY ones): an absolute '/p'; a leading '$CLAUDE_PROJECT_DIR/p' or
#     '${CLAUDE_PROJECT_DIR}/p' (against the normalized target); a leading '$HOME/p', '${HOME}/p' or
#     '~/p' when HOME is non-empty; and a relative 'dir/p' (against the target, the directory Claude
#     Code runs project hooks from) ONLY when the command contains no 'cd' and the word is the
#     command itself or its first argument (word 1 or 2: 'x.sh' or 'bash x.sh'). Words are split
#     quote-aware, so '"/my tools/retro-gate.sh"' is one word; interpreter prefixes and trailing
#     arguments are tolerated. Everything else is 'unverifiable' (including a word starting with '-', a ':' before the first '/', a '~' inside double quotes, and the word after a '-c' shell flag): a variable that is not a leading
#     resolvable one, '~user/p', a backslash, glob characters, a bare command name (no '/'), a
#     single-quoted '$'/'~', an unterminated quote, a relative path after 'cd', an empty HOME.
#     NOT checked: the executable bit (a fork-free awk cannot test it; 'bash x.sh' needs none), the
#     settings.local.json / user-level registration paths (same narrowness as the wiring predicate),
#     and where sessions launch from (kit issue #1134 — the other half of #1157, undecidable here).
#     COST: one nested subshell and one rsdd exec per call (it was one awk fork before the Go port). Always returns 0.
#
#   hook_stop_script_state <target-dir> : wrapper, prints $HOOK_SCRIPT_STATE (one extra fork).
if ! declare -F hook_stop_script_state_var >/dev/null 2>&1; then
  # SHIM (kit issue #2356): `rsdd hook script-state <target>`. Only the five documented states are accepted from a
  # successful run; anything else (rsdd unavailable, a non-zero exit, an unknown answer) reads "degraded".
  hook_stop_script_state_var() {
    _hw_rsdd script-state "$1"
    case "$_HW_RC:$_HW_OUT" in
      0:present|0:missing|0:unverifiable|0:no-entry|0:degraded) HOOK_SCRIPT_STATE="$_HW_OUT" ;;
      *) HOOK_SCRIPT_STATE="degraded" ;;
    esac
    return 0
  }
fi

if ! declare -F hook_stop_script_state >/dev/null 2>&1; then
  hook_stop_script_state() {
    hook_stop_script_state_var "$1"
    printf '%s' "$HOOK_SCRIPT_STATE"
    return 0
  }
fi

# --- LAUNCH-HISTORY state (kit issue #1157) ------------------------------------------------------
#   hook_stop_launch_state_var <target-dir>
#     Sets the GLOBAL $HOOK_LAUNCH_STATE to exactly one of:
#       launched    : Claude Code's per-project history directory for <target-dir> as the session
#                     root exists and holds at least one `*.jsonl` session transcript — a Claude Code
#                     session was retained from exactly this directory. This says NOTHING about
#                     whether the hook existed or was registered at that time: the transcript may
#                     predate the registration, so 'launched' is evidence the directory is a launch
#                     site, not that the hook has fired.
#       no-sessions : the history root exists and is readable, but holds no retained transcript for
#                     <target-dir>. RETENTION: Claude Code prunes old transcripts, so this means "no
#                     RETAINED Claude Code transcript", not a proof that no session ever started
#                     there. The Stop hook in .claude/settings.json is Claude-Code-specific: a
#                     target worked in another harness (pi, gentle-shell) has no such history and
#                     reads no-sessions without the hook being wrong for that harness.
#       unknown     : the instrument could not look — HOME unset/empty and no override, the history
#                     root is absent or not a directory, the target path has a non-ASCII byte (the
#                     directory-name encoding is per UTF-16 code unit in Claude Code but per byte
#                     under a C locale), the encoded name exceeds 200 characters (Claude Code
#                     truncates and hashes long names), or any component of the target path is a
#                     symlink (Claude Code records the resolved path, which this fork-free check
#                     cannot compute). NO claim in either direction (§7).
#     DESIGN DECISION (kit issue #1157): this predicate lifts the earlier rule "the lib must not read
#     ~/.claude/projects"; the read is limited to directory/glob EXISTENCE, never transcript contents.
#     Directory name = the absolute, ./..-collapsed target path with every character outside
#     [A-Za-z0-9] replaced by '-' (so /home/u/a.b/c becomes -home-u-a-b-c), under
#     "${RSDD_CLAUDE_PROJECTS_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects}".
#     RSDD_CLAUDE_PROJECTS_DIR is the test seam (it wins over CLAUDE_CONFIG_DIR).
#     A session launched in a SUBDIRECTORY or PARENT of <target-dir> records under its own name and
#     does not count: project settings load from the launch directory only (observed behavior, kit
#     issue #1134), which is the whole point of this question.
#     This is a SEPARATE question from the wiring state and the script state: it never changes
#     hook_stop_wiring_state_var (sweep-retros.sh and research-sdd-status.sh stay byte-identical)
#     and is asked by a caller only AFTER 'wired' / 'wired-off-root' and a non-'missing' script.
#     COST: one nested subshell and one rsdd exec per call (it was zero forks before the Go port; kit issue #2357). Returns 0.
#     A rsdd that is unavailable, fails or answers outside the three states reads "unknown".
#
#   hook_stop_launch_states_var <target-dir>... : batch form, ONE rsdd exec for every target. Sets the ARRAY
#     $HOOK_LAUNCH_STATES, one element per target in argument order. Any doubt (rsdd failing, a line count that differs from
#     the target count, a line outside the three states) reads "unknown" for EVERY element. No targets: an empty array and no
#     rsdd call. Fleet loops use it instead of one hook_stop_launch_state_var per target.
#
#   hook_stop_launch_state <target-dir> : wrapper, prints $HOOK_LAUNCH_STATE (one extra fork).
if ! declare -F hook_stop_launch_state_var >/dev/null 2>&1; then
  # SHIM (kit issue #2357): `rsdd hook launch-state <target>`. Only the three documented states are accepted from a
  # successful run; anything else (rsdd unavailable, a non-zero exit, an unknown answer) reads "unknown": the instrument
  # could not look, which makes no claim in either direction and never reads as no-sessions.
  hook_stop_launch_state_var() {
    _hw_rsdd launch-state "$1"
    case "$_HW_RC:$_HW_OUT" in
      0:launched|0:no-sessions|0:unknown) HOOK_LAUNCH_STATE="$_HW_OUT" ;;
      *) HOOK_LAUNCH_STATE="unknown" ;;   # HW-LAUNCH-FALLBACK
    esac
    return 0
  }
fi

if ! declare -F hook_stop_launch_states_var >/dev/null 2>&1; then
  # BATCH SHIM (kit issue #2357): `rsdd hook launch-state <target>...` once for every target. Sets the array
  # HOOK_LAUNCH_STATES, one element per target in argument order. The answer is accepted only as a whole: a failing rsdd, a
  # line count that differs from the target count, or ANY line outside the three states reads "unknown" for EVERY element.
  # No targets: an empty array, rsdd not called.
  hook_stop_launch_states_var() {
    local _hw_n=0 _hw_rest _hw_line _hw_i _hw_ok=1 _hw_last=0
    HOOK_LAUNCH_STATES=()
    [ "$#" -gt 0 ] || return 0
    _hw_rsdd launch-state "$@"
    if [ "$_HW_RC" = 0 ]; then
      _hw_rest="$_HW_OUT"
      while :; do
        case "$_hw_rest" in
          *$'\n'*) _hw_line="${_hw_rest%%$'\n'*}"; _hw_rest="${_hw_rest#*$'\n'}" ;;
          *)        _hw_line="$_hw_rest"; _hw_rest=""; _hw_last=1 ;;
        esac
        case "$_hw_line" in
          launched|no-sessions|unknown) HOOK_LAUNCH_STATES[_hw_n]="$_hw_line" ;;
          *) _hw_ok=0 ;;
        esac
        _hw_n=$(( _hw_n + 1 ))
        [ "$_hw_last" = 0 ] || break
      done
    fi
    # an empty line (also a trailing one) counts as a line and fails the vocabulary check
    if [ "$_HW_RC" = 0 ] && [ "$_hw_n" = "$#" ] && [ "$_hw_ok" = 1 ]; then  # HW-LAUNCH-BATCH-GUARD
      return 0
    fi
    HOOK_LAUNCH_STATES=()
    for _hw_i in "$@"; do HOOK_LAUNCH_STATES+=("unknown"); done
    return 0
  }
fi

if ! declare -F hook_stop_launch_state >/dev/null 2>&1; then
  hook_stop_launch_state() {
    hook_stop_launch_state_var "$1"
    printf '%s' "$HOOK_LAUNCH_STATE"
    return 0
  }
fi

# --- WIRED-HOOK EXECUTE-BIT state (kit issue #2141) ------------------------------------------------
#   hook_wired_exec_report <target-dir>
#     Reads <target-dir>/.claude/settings.json (project file only, like the Stop predicate above) and,
#     for every command wired under its top-level "hooks" key (any event; statusLine / mcpServers
#     commands are not hooks and are not read), prints one tab-separated line per finding on stdout:
#       not-executable<TAB><path><TAB><event>   a script run DIRECTLY exists and lacks +x (exit 126)
#       missing<TAB><path><TAB><event>          the script path names no file
#       unverifiable<TAB><head><TAB><reason>    the command is not one of the asserted shapes below, or
#                                               the settings file could not be read: said out loud,
#                                               never a silent "all fine" (CLAUDE.md section 7)
#     DOCTRINE: a parser over free-form shell must not guess argument structure. Existence and the
#     execute bit are asserted for EXACTLY these shapes (the first simple command: the word list ends
#     at the first unquoted `; & | < > ( )`), after expanding `${CLAUDE_PROJECT_DIR}` /
#     `$CLAUDE_PROJECT_DIR` (to <target-dir>), `$HOME` / `${HOME}` and an UNQUOTED leading `~/`, and
#     removing matching quotes:
#       1. `<path> [args...]`  the first word contains `/` -> must exist AND be executable
#          (a relative path is taken from <target-dir>)
#       2. prefixes with NO options: `exec|nohup|command <path>`, `timeout <N[smh]> <path>`,
#          `NAME=value... <path>` -> as shape 1
#       3. `bash|sh|zsh|python|python3|node|perl <abs-path> [args...]`, optionally via `env <interp>`
#          with no env options, where the word right after the interpreter does NOT start with `-`
#          -> must exist only (an interpreter run needs no +x)
#     EVERYTHING ELSE with a command word is unverifiable, with a typed reason: an interpreter followed
#     by any option (`-c`, `-lc`, `-r`, `-I`, `--eval`, ...), env / nice / timeout with options, a
#     wrapper followed by an option, a relative or non-absolute script for an interpreter, a quoted
#     interpreter word, `cd ...` or any other command followed by an operator before a path command,
#     a bare command name with arguments, a backslash, an unterminated quote, `~` the shell would not
#     expand, an unresolved variable / glob / substitution. A bare command name that is the ENTIRE
#     command (`true`) is the only silent shape. An unreadable or invalid settings file is
#     unverifiable too. settings.json is parsed natively by rsdd (no jq involved; the old text-match
#     fallback for a machine without jq is gone). If rsdd itself cannot answer, the report is ONE
#     unverifiable line for <target-dir>/.claude/settings.json.
#     Read-only: it never touches the target. An ABSENT settings.json prints nothing. Returns 0.
if ! declare -F hook_wired_exec_report >/dev/null 2>&1; then
  # SHIM (kit issue #2357): `rsdd hook wired-exec <target>`. The report is whatever rsdd prints; it is accepted only from a
  # successful run whose first line starts with one of the three kinds. A failing or unavailable rsdd, or an answer outside
  # that vocabulary, is ONE unverifiable finding (the instrument could not look: never a silent "all fine"). Returns 0.
  hook_wired_exec_report() {
    local settings="$1/.claude/settings.json"
    _hw_rsdd wired-exec "$1"
    if [ "$_HW_RC" = 0 ]; then
      case "$_HW_OUT" in
        '') return 0 ;;   # nothing wired, nothing to report
        'not-executable'$'\t'*|'missing'$'\t'*|'unverifiable'$'\t'*)   # HW-EXEC-VOCAB
          printf '%s\n' "$_HW_OUT"; return 0 ;;
      esac
    fi
    printf 'unverifiable\t%s\t%s\n' "$settings" "rsdd could not produce the wired-hook report (rsdd unavailable, failed or answered outside the report format)"   # HW-EXEC-FALLBACK
    return 0
  }
fi
