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
#     absent-settings | unreadable. COST GUARANTEE: exactly one awk fork per call (the Stop-scope
#     check), for every state; the git-root / off-root check adds no fork — it uses only builtins
#     (`[ -e ]` tests and parameter-expansion path-walking; no `git` binary, no `$(...)`, no
#     here-string), so a caller iterating many targets (sweep-retros.sh's WIRING-STATUS fleet
#     pass) pays one fork per target. (History: kit issue #1140 round-2 review Blocking 3 removed
#     an earlier second fork on the majority 'wired' state.)
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
#                            against real session launch directories (and must not: the wiring state
#                            never reads `~/.claude/projects` or any session transcript, so
#                            sweep-retros.sh stays byte-identical). The launch-history question is a
#                            SEPARATE predicate, hook_stop_launch_state_var, at the end of this file
#                            (kit issue #1157), which reads only the existence of a history directory.
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

if ! declare -F _hw_abspath >/dev/null 2>&1; then
  # _hw_abspath <path> : sets $HW_ABS_PATH to <path> made absolute (prefixed with $PWD if
  # relative) with every "." and ".." component COLLAPSED — pure builtins, no `realpath`/`pwd -P`
  # fork, no symlink resolution (see _hw_find_git_root's own KNOWN LIMITATION below for what that
  # still leaves unhandled). Shared by _hw_find_git_root and hook_stop_wiring_state_var so both
  # normalize identically. Two bugs this fixes together (kit issue #1140 correction, then r3
  # review M1): a relative target ('.', 'foo', 'foo/bar' -> 'foo') never gave ${d%/*} a "/" to
  # climb past, so the walk-up spun forever; and an UNcollapsed ".." in the target made the
  # walk-up climb one raw textual segment at a time instead of resolving it, so a target like
  # '.../A/B/..' (which really resolves to '.../A') could climb onto the REAL directory '.../A/B'
  # and pick up an unrelated nested repo's `.git` there — a false 'wired-off-root'.
  _hw_abspath() {
    local d="$1" part result=""
    case "$d" in
      /*) : ;;
      *)  d="$PWD/$d" ;;
    esac
    # Split on '/' with parameter expansion only (kit issue #1153): a `read -ra` over a here-string
    # needs a $TMPDIR temp file on bash < 5.1 and stops at an embedded newline.
    local rest="${d#/}" last=0
    while [ "$last" -eq 0 ]; do
      case "$rest" in
        */*) part="${rest%%/*}"; rest="${rest#*/}" ;;
        *)   part="$rest"; last=1 ;;
      esac
      case "$part" in
        ''|.) continue ;;
        ..)   result="${result%/*}" ;;
        *)    result="$result/$part" ;;
      esac
    done
    [ -z "$result" ] && result="/"
    HW_ABS_PATH="$result"
  }
fi

if ! declare -F _hw_find_git_root >/dev/null 2>&1; then
  # NOTE: $HW_GIT_ROOT is always a real git-root path or "" (kit issue #1696). When the target AS
  # SPELLED owns a `.git` (RAW-TARGET CHECK below) it is that spelled path and $HW_TARGET_IS_ROOT is
  # "1"; in every other outcome $HW_TARGET_IS_ROOT is "0".
  # _hw_find_git_root <dir> : sets $HW_GIT_ROOT to the nearest ancestor of <dir> (inclusive of
  # <dir> itself) that owns a `.git` entry (file or directory — a linked worktree's `.git` is a
  # FILE, and this must recognise that too), or "" if none is found before reaching `/` or the
  # $RSDD_HOOK_WIRING_CEILING. Pure builtins only — [ -e ] and parameter expansion — NO fork, NO
  # git binary, NO `realpath`/`pwd -P`. `[ -e "$d/.git" ]` DOES resolve a symlink AT THAT ONE
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
  _hw_find_git_root() {
    local d ceiling="" _hw_next
    HW_TARGET_IS_ROOT=0
    _hw_abspath "$1"; d="$HW_ABS_PATH"
    # kit r3 review, M3: $ceiling used to be compared TEXTUALLY against $RSDD_HOOK_WIRING_CEILING
    # as-is, so a value with a trailing slash never matched $d (always trailing-slash-free after
    # _hw_abspath) and silently never fired. Normalize it through the SAME _hw_abspath.
    if [ -n "${RSDD_HOOK_WIRING_CEILING:-}" ]; then
      _hw_abspath "$RSDD_HOOK_WIRING_CEILING"; ceiling="$HW_ABS_PATH"
    fi
    # RAW-TARGET CHECK (kit issue #1153): the kernel resolves '..' AFTER following a symlink but the
    # textual collapse above does not, so for ".../link/.." the collapsed $d names a different
    # directory than the one the caller means. If the target AS SPELLED already owns a `.git`, it is
    # its own git root; answer that before the textual walk can climb past it. The ceiling still
    # wins for the collapsed path, exactly as in the loop below.
    local _hw_raw="$1"
    case "$_hw_raw" in /*) : ;; *) _hw_raw="$PWD/$_hw_raw" ;; esac
    if { [ -z "$ceiling" ] || [ "$d" != "$ceiling" ]; } && [ -e "$_hw_raw/.git" ]; then  # HOOK-WIRING-RAWGIT-CHECK
      # The sole consumer (hook_stop_wiring_state_var, WIRED-OFF-ROOT-CHECK) reads the flag, not a
      # string comparison: the collapsed $d may name a directory that owns no `.git` at all, so it
      # is never returned as the root. The spelled path owns the `.git`, so it is a real root.
      HW_TARGET_IS_ROOT=1
      HW_GIT_ROOT="$_hw_raw"
      return 0
    fi
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
      _hw_next="${d%/*}"
      [ -z "$_hw_next" ] && _hw_next="/"
      if [ "$_hw_next" = "$d" ]; then  # HOOK-WIRING-NOPROGRESS-GUARD — defense in depth, fail closed
        HW_GIT_ROOT=""
        return 0
      fi
      d="$_hw_next"
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
      _hw_abspath "$target"; _hw_target_norm="$HW_ABS_PATH"  # same normalization as _hw_find_git_root below
      _hw_find_git_root "$target"
      if [ "$HW_TARGET_IS_ROOT" != "1" ] && [ -n "$HW_GIT_ROOT" ] && [ "$HW_GIT_ROOT" != "$_hw_target_norm" ]; then  # WIRED-OFF-ROOT-CHECK
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
#     COST: exactly one awk fork per call, none for the absent/unreadable states. Always returns 0.
#
#   hook_stop_script_state <target-dir> : wrapper, prints $HOOK_SCRIPT_STATE (one extra fork).
if ! declare -F hook_stop_script_state_var >/dev/null 2>&1; then
  hook_stop_script_state_var() {
    local target="$1" settings rc
    settings="$target/.claude/settings.json"
    if [ ! -e "$settings" ] || [ ! -r "$settings" ]; then
      HOOK_SCRIPT_STATE="no-entry"; return 0
    fi
    _hw_abspath "$target"
    awk -v tgt="$HW_ABS_PATH" -v home="${HOME:-}" '
      function esc_at(s, k,   b) { b = 0; while (k > 1 && substr(s, k - 1, 1) == "\\") { b++; k-- } return b % 2 }
      # pfx(s, pat): 1 when s starts with pat followed by "/" (the only place a variable is resolved).
      function pfx(s, pat) { return substr(s, 1, length(pat) + 1) == pat "/" }
      # resolve(w, hascd): a word of the command that mentions retro-gate -> "ok"/"miss"/"unver".
      # "miss" is a firm claim, emitted only when the path was resolved unambiguously.
      function resolve(w, hascd, widx, prev,   tok, r, ln) {
        tok = w
        if (index(tok, "\047") > 0 && tok ~ /[$~]/) return "unver"   # single-quoted: the shell would not expand it
        if (prev ~ /^-[a-zA-Z]*c$/) return "unver"   # a shell -c payload: the shell re-parses it
        gsub(/["\047]/, "", tok)
        if (substr(tok, 1, 1) == "-") return "unver"   # an option (--cfg=/x/retro-gate.json), not a script path
        if (index(w, "\"") > 0 && substr(tok, 1, 1) == "~") return "unver"   # no tilde expansion inside double quotes
        if (pfx(tok, "${CLAUDE_PROJECT_DIR}")) tok = tgt substr(tok, 22)
        else if (pfx(tok, "$CLAUDE_PROJECT_DIR")) tok = tgt substr(tok, 20)
        else if (home != "" && pfx(tok, "${HOME}")) tok = home substr(tok, 8)
        else if (home != "" && pfx(tok, "$HOME")) tok = home substr(tok, 6)
        else if (home != "" && substr(tok, 1, 2) == "~/") tok = home substr(tok, 2)
        if (tok ~ /[$`*?\\]/ || substr(tok, 1, 1) == "~" || index(tok, "/") == 0) return "unver"
        if (index(tok, ":") > 0 && index(tok, ":") < index(tok, "/")) return "unver"   # scheme or drive prefix (C:/x), not a local path
        if (substr(tok, 1, 1) != "/") {
          if (hascd) return "unver"          # relative to a directory the command itself changed
          if (widx > 2) return "unver"       # a relative word past the command/interpreter slots may be a fragment or an argument
          tok = tgt "/" tok
        }
        r = (getline ln < tok); close(tok)
        return (r >= 0) ? "ok" : "miss"
      }
      # check(line, pos): classify every retro-gate word of the JSON string that contains pos.
      # Returns the index of the closing quote (so the scanner can skip the string), or 0.
      function check(line, pos,   s, e, k, cmd, n, c, q, w, hascd, any, widx, prev) {
        s = 0
        for (k = pos - 1; k >= 1; k--) if (substr(line, k, 1) == "\"" && !esc_at(line, k)) { s = k; break }
        e = 0
        for (k = pos + 10; k <= length(line); k++) if (substr(line, k, 1) == "\"" && !esc_at(line, k)) { e = k; break }
        entries++
        if (s == 0 || e == 0) { unver++; return 0 }
        cmd = substr(line, s + 1, e - s - 1)
        gsub(/\\"/, "\"", cmd)
        hascd = (cmd ~ /(^|[ \t;&|(])cd[ \t]/)
        # quote-aware split: whitespace inside a quoted span does not end a word
        n = length(cmd); q = ""; w = ""; any = 0; widx = 0; prev = ""
        for (k = 1; k <= n + 1; k++) {
          c = (k <= n) ? substr(cmd, k, 1) : " "
          if (q == "" && (c == " " || c == "\t")) {
            if (w != "") widx++
            if (w != "" && index(w, "retro-gate") > 0) { any = 1; res[resn++] = resolve(w, hascd, widx, prev) }
            if (w != "") prev = w
            w = ""
            continue
          }
          if (q == "" && (c == "\"" || c == "\047")) q = c
          else if (q != "" && c == q) q = ""
          w = w c
        }
        if (q != "") { unver++; resn = 0; return e }   # unterminated quote: the command could not be split reliably
        if (!any) unver++
        for (k = 0; k < resn; k++) { if (res[k] == "ok") okc++; else if (res[k] == "miss") miss++; else unver++ }
        resn = 0
        return e
      }
      BEGIN { in_stop = 0; stop_depth = 0; depth = 0; entries = 0; okc = 0; miss = 0; unver = 0; resn = 0 }
      {
        n = length($0); i = 1
        while (i <= n) {
          c = substr($0, i, 1)
          if (c == "{" || c == "[") {
            depth++
          } else if (c == "}" || c == "]") {
            depth--
            if (in_stop && depth <= stop_depth) { in_stop = 0 }
          } else if (!in_stop && substr($0, i, 6) == "\"Stop\"") {
            j = i + 6
            while (j <= n && (substr($0, j, 1) == " " || substr($0, j, 1) == "\t")) j++
            if (j <= n && substr($0, j, 1) == ":") { in_stop = 1; stop_depth = depth }
            i = j
          } else if (in_stop && substr($0, i, 10) == "retro-gate") {
            e = check($0, i)
            if (e > i) i = e
          }
          i++
        }
      }
      END {
        if (entries == 0) exit 3
        if (okc > 0) exit 0
        if (unver > 0) exit 5
        exit 4
      }
    ' "$settings" 2>/dev/null
    rc=$?
    case "$rc" in
      0) HOOK_SCRIPT_STATE="present" ;;
      3) HOOK_SCRIPT_STATE="no-entry" ;;
      4) HOOK_SCRIPT_STATE="missing" ;;
      5) HOOK_SCRIPT_STATE="unverifiable" ;;
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
#                     root exists and holds at least one `*.jsonl` session transcript — a session
#                     HAS been launched from exactly this directory, so its project settings loaded.
#       no-sessions : the history root exists and is readable, but holds no transcript for
#                     <target-dir> — no session was ever launched from exactly this directory, so a
#                     hook REGISTERED here has never been loaded (the launch site is elsewhere).
#       unknown     : the instrument could not look — HOME unset/empty and no override, the history
#                     root is absent or not a directory, the target path has a non-ASCII byte (the
#                     directory-name encoding is per UTF-16 code unit in Claude Code but per byte
#                     under a C locale), or the encoded name exceeds 200 characters (Claude Code
#                     truncates and hashes long names). NO claim in either direction (§7): a machine
#                     with no Claude history must not read as "never launched".
#     Directory name = the absolute, ./..-collapsed target path with every character outside
#     [A-Za-z0-9] replaced by '-' (so /home/u/a.b/c becomes -home-u-a-b-c), under
#     "${RSDD_CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}". RSDD_CLAUDE_PROJECTS_DIR is a test seam
#     (and an escape hatch for a non-default Claude config directory; CLAUDE_CONFIG_DIR is not read).
#     A session launched in a SUBDIRECTORY or PARENT of <target-dir> records under its own name and
#     does not count: project settings load from the launch directory only (observed behavior, kit
#     issue #1134), which is the whole point of this question. Symlinked targets are not resolved.
#     This is a SEPARATE question from the wiring state and the script state: it never changes
#     hook_stop_wiring_state_var (sweep-retros.sh and research-sdd-status.sh stay byte-identical)
#     and is asked by a caller only AFTER 'wired' / 'wired-off-root' and a non-'missing' script.
#     COST: zero forks — builtins only ([ -d ], compgen, parameter expansion). Always returns 0.
#
#   hook_stop_launch_state <target-dir> : wrapper, prints $HOOK_LAUNCH_STATE (one extra fork).
if ! declare -F hook_stop_launch_state_var >/dev/null 2>&1; then
  hook_stop_launch_state_var() {
    local root enc d
    root="${RSDD_CLAUDE_PROJECTS_DIR:-}"
    if [ -z "$root" ]; then
      [ -n "${HOME:-}" ] || { HOOK_LAUNCH_STATE="unknown"; return 0; }
      root="$HOME/.claude/projects"
    fi
    if [ ! -d "$root" ] || [ ! -r "$root" ]; then
      HOOK_LAUNCH_STATE="unknown"; return 0
    fi
    _hw_abspath "$1"; d="$HW_ABS_PATH"
    case "$d" in *[!\ -~]*) HOOK_LAUNCH_STATE="unknown"; return 0 ;; esac   # HOOK-LAUNCH-NONASCII-GUARD
    enc="${d//[^A-Za-z0-9]/-}"
    if [ "${#enc}" -gt 200 ]; then HOOK_LAUNCH_STATE="unknown"; return 0; fi   # HOOK-LAUNCH-LONGNAME-GUARD
    if compgen -G "$root/$enc/*.jsonl" >/dev/null 2>&1; then  # HOOK-LAUNCH-HISTORY-CHECK
      HOOK_LAUNCH_STATE="launched"
    else
      HOOK_LAUNCH_STATE="no-sessions"
    fi
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
