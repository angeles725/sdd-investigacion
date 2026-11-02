#!/usr/bin/env bash
# FROZEN LEGACY COPY - do not edit. Lines 134-312 and 349-465 of research-sdd/toolbelt/lib/hook-wiring.sh as of
# origin/main 9cf94d50 (kit issue #2356, U2.3a): _hw_abspath, _hw_find_git_root, hook_stop_wiring_state(_var),
# hook_stop_script_state(_var). internal/hook/differential_test.go runs it as the oracle for the Go port; the live
# lib no longer carries this code (it is a shim over `rsdd hook ...`).
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
