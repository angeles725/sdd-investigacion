# Frozen verbatim excerpt of research-sdd/toolbelt/research-sdd-init.sh (the U5.1 wiring functions, kit issue #2467).
# The function bodies are copied unchanged, so the Go port in scaffold/wiring*.go is differentially tested against the
# real thing. Do not edit: wiring_oracle_test.go pins the sha256 of this file. It is sourced by init-wiring-driver.sh,
# which supplies the globals the functions read (KIT TPL target subject subject_given prefix _RSDD_GATE_* _RSDD_DRIFT_*).
# shellcheck shell=bash disable=SC2154
# kit issue #1043 (1): escape the three characters that are special in the REPLACEMENT of a
# `sed "s|...|...|"` expression — backslash (escape), `&` (re-inserts the match) and `|` (our
# delimiter) — so a target/kit path containing them is rendered literally, not mangled or rejected.
_rsdd_sed_escape() { printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'; }

# kit issue #1043 (1): render the <KIT>/<TARGET> placeholders of a copied hook template in place.
_rsdd_render_hook() {
  local f="$1" k t
  k="$(_rsdd_sed_escape "$KIT")"; t="$(_rsdd_sed_escape "$target")"
  sed -i "s|<KIT>|$k|g; s|<TARGET>|$t|g" "$f"
}

# kit issue #1043 (3): install a freshly-merged settings file ATOMICALLY. The temp file is created
# in the SAME directory as the real destination (so the final mv is a same-filesystem rename), the
# mode of an existing file is copied onto it, and a symlinked settings.json is resolved first so the
# rename replaces the link TARGET and the link itself survives. A failed write removes the temp and
# leaves the original bytes untouched (an in-place `cat >` would truncate them). Caller guarantees
# $2 is not a dangling symlink.
_rsdd_install_settings() {
  local tmp="$1" dest="$2" real tmp2
  real="$(readlink -f -- "$dest")" || { rm -f "$tmp"; return 1; }
  tmp2="$(mktemp "$(dirname "$real")/.settings.XXXXXX")" || { rm -f "$tmp"; return 1; }
  if cat "$tmp" > "$tmp2" \
     && { [ ! -e "$real" ] || chmod --reference="$real" "$tmp2"; } \
     && { [ -e "$real" ] || chmod "$(printf '%o' $((0666 & ~$(umask))))" "$tmp2"; } \
     && mv -f "$tmp2" "$real"; then
    rm -f "$tmp"; return 0
  fi
  rm -f "$tmp" "$tmp2"; return 1
}

_RSDD_PH_SUBJECT='<SUBJECT>'
_RSDD_HOOK_PLACEHOLDERS=("$_RSDD_PH_SUBJECT" '<prefix>' '<path to binaries/decompiled output/source code of the system under study>')

# kit issue #1040 finding 3 (round 2 of #1038): detect a placeholder only in NON-COMMENT lines. The
# shipped template's own header comments legitimately contain the literal token, and a real
# adaptation that leaves those comments untouched (api-paneles repro) must not be misread as
# unadapted — that silently blocks SessionStart forever.
_rsdd_hook_has_placeholder() {
  local f="$1" ph="$2"
  [ -f "$f" ] || return 1
  grep -qF -- "$ph" < <(grep -vE '^[[:space:]]*#' "$f" 2>/dev/null)
}
# SessionStart registration is gated on <SUBJECT> ONLY (see the header): this is the gate every call site uses.
_rsdd_has_live_subject_placeholder() { _rsdd_hook_has_placeholder "$1" "$_RSDD_PH_SUBJECT"; }

# kit issue #1845: WARN (stderr) naming every live placeholder OTHER than the gating <SUBJECT> one (the call sites keep
# their own, context-specific <SUBJECT> WARN) with the exact next step. None of these blocks SessionStart wiring.
_rsdd_warn_other_placeholders() {
  local f="$1" ph step
  for ph in "${_RSDD_HOOK_PLACEHOLDERS[@]}"; do
    [ "$ph" = "$_RSDD_PH_SUBJECT" ] && continue
    _rsdd_hook_has_placeholder "$f" "$ph" || continue
    case "$ph" in
      '<prefix>') step="replace it with the block-file prefix (the --prefix slug) by hand";;
      *)          step="no flag can fill it: edit the hook and list the real primary-source paths (binaries / decompiled output / source of the system under study) under item 3";;
    esac
    echo "WARN: $f still contains the $ph placeholder — $step. SessionStart wiring is NOT blocked by it." >&2
  done
}

# kit issue #1845: the value a flag supplies for one placeholder; rc 1 = no flag fills it (or it was not given).
_rsdd_placeholder_value() {
  case "$1" in
    "$_RSDD_PH_SUBJECT") [ "$subject_given" = 1 ] && printf '%s' "$subject";;
    '<prefix>')          [ -n "$prefix" ] && printf '%s' "$prefix";;
    *)                   return 1;;
  esac
}
# Escape the regex metacharacters of a LITERAL placeholder for the pattern side of `sed "s|...|...|"`.
_rsdd_sed_pattern_escape() { printf '%s' "$1" | sed -e 's/[][\\.*^$|]/\\&/g'; }

_RSDD_FILL_TMP=""; _RSDD_STAGE=""; _RSDD_OWNED_DEST=""
_rsdd_cleanup_tmp() {
  [ -z "$_RSDD_FILL_TMP" ] || rm -f -- "$_RSDD_FILL_TMP"
  [ -z "$_RSDD_OWNED_DEST" ] || rm -f -- "$_RSDD_OWNED_DEST"   # kit issue #1914 review: an exclusively-created hook a signal interrupted before it was filled
  [ -z "$_RSDD_STAGE" ] || rm -rf -- "$_RSDD_STAGE"
}
trap '_rsdd_cleanup_tmp' EXIT
trap '_rsdd_cleanup_tmp; exit 130' INT
trap '_rsdd_cleanup_tmp; exit 143' TERM

# kit issue #1845: every failed fill removes its temp file and returns 1 with a typed FATAL; the hook stays exactly as copied.
_rsdd_fill_abort() {  # <tmp> <message>
  rm -f "$1"
  _RSDD_FILL_TMP=""
  echo "FATAL: $2" >&2
  return 1
}

# kit issue #1845: fill the flag-supplied placeholders of a freshly copied hook, NON-COMMENT lines only, in ONE rewrite: all
# substitutions go through a single temp file in the hook's own directory (never `sed -i`, whose flag differs on BSD/macOS)
# and are installed with one mv, so a failure at any step leaves the hook as copied (never half-filled) and no temp file.
# A typed FATAL (rc 1, never a silent no-op) when a placeholder a flag was given for is absent from the template or survives.
_rsdd_fill_hook() {
  local f="$1" ph val tmp
  local -a exprs=()
  for ph in "${_RSDD_HOOK_PLACEHOLDERS[@]}"; do
    val="$(_rsdd_placeholder_value "$ph")" || continue
    if ! _rsdd_hook_has_placeholder "$f" "$ph"; then
      echo "FATAL: the kit template $TPL/hook-sessionstart.sh carries no live $ph placeholder — nothing to fill from the flag (hook as copied: $f)" >&2; return 1
    fi
    exprs+=(-e "/^[[:space:]]*#/! s|$(_rsdd_sed_pattern_escape "$ph")|$(_rsdd_sed_escape "$val")|g")
  done
  [ "${#exprs[@]}" -gt 0 ] || return 0
  tmp="$(mktemp "$(dirname "$f")/.hook.XXXXXX")" || { echo "FATAL: could not create a temp file beside $f (hook left as copied)" >&2; return 1; }
  _RSDD_FILL_TMP="$tmp"   # the INT/TERM/EXIT trap removes it if the run is interrupted before the mv
  cp -p "$f" "$tmp" || { _rsdd_fill_abort "$tmp" "could not copy $f to its temp file (hook left as copied)"; return 1; }   # carries the mode over
  sed "${exprs[@]}" "$f" > "$tmp" || { _rsdd_fill_abort "$tmp" "sed failed filling $f (hook left as copied)"; return 1; }
  for ph in "${_RSDD_HOOK_PLACEHOLDERS[@]}"; do
    _rsdd_placeholder_value "$ph" >/dev/null || continue
    if _rsdd_hook_has_placeholder "$tmp" "$ph"; then _rsdd_fill_abort "$tmp" "$ph survived the fill of $f (hook left as copied)"; return 1; fi
  done
  mv -f "$tmp" "$f" || { _rsdd_fill_abort "$tmp" "could not install the filled hook over $f (hook left as copied)"; return 1; }
  _RSDD_FILL_TMP=""
}

# kit issue #1860: stage + fill the SessionStart hook in a mktemp dir OUTSIDE the target (wire-only path). An unwritable or
# missing TMPDIR is a typed FATAL (exit 2) with nothing written: the staging runs before anything is created in the target.
_rsdd_stage_hook() {
  _RSDD_STAGE="$(mktemp -d)" || { _RSDD_STAGE=""; echo "FATAL: could not create a staging directory for the hook (nothing written; check TMPDIR)" >&2; exit 2; }
  cp "$TPL/hook-sessionstart.sh" "$_RSDD_STAGE/hook" || { echo "FATAL: could not stage $TPL/hook-sessionstart.sh (nothing written)" >&2; exit 2; }
  _rsdd_fill_hook "$_RSDD_STAGE/hook" || exit 2
  # kit issue #2141: the staged copy is what gets installed (mode carried by _rsdd_install_noclobber), so +x here makes the hook
  # executable whatever mode the template checkout carries — and leaves the install step's own mode-carrying checks (#1845) intact.
  chmod +x "$_RSDD_STAGE/hook" || { echo "FATAL: could not make the staged hook executable (nothing written)" >&2; exit 2; }   # WIRED-SS-CHMOD-WIRE
}

# kit issue #1845: the flags fill only a hook THIS run creates. An existing hook is never overwritten: --subject REFUSES (exit 3,
# before any write); --prefix is also the corpus block-prefix flag that operators re-pass on re-wires, so it is a typed note.
_rsdd_refuse_fill_on_existing_hook() {
  local f="$1"
  [ -e "$f" ] || return 0
  if [ "$subject_given" = 1 ]; then
    echo "REFUSED: --subject only fills a hook this run creates, but $f already exists (nothing written). Edit it by hand, or pass --force to re-scaffold the WHOLE corpus (destructive: it clobbers hand-adapted hooks, INDEX.md and backlog rows, kit issue #1038)." >&2
    exit 3
  fi
  [ -z "$prefix" ] || echo "note: --prefix not applied to existing $f (fill <prefix> by hand)"
  return 0
}

# kit issue #1040 finding 1 (round 2 of #1038), extended round 3: a hook may already be
# registered via $CLAUDE_PROJECT_DIR in any of FIVE equivalent forms instead of the absolute
# path this script writes — unquoted, the variable alone double-quoted, brace-expanded, or the
# WHOLE command string double-quoted (the form Claude Code's own docs use and the kit's own
# settings.json templates carry, kit issue #1040 round 3 finding 2). Missing any of these made a
# real target's SessionStart hook run twice (cloudflare repro: $CLAUDE_PROJECT_DIR/<rel> was
# already registered, and the literal-string dedup appended the absolute-path form alongside it).
_rsdd_cmd_variants_json() {
  local abs="$1" rel="$2"
  jq -cn --arg a "$abs" --arg r "$rel" '[
    $a,
    ("$CLAUDE_PROJECT_DIR/" + $r),
    ("\"$CLAUDE_PROJECT_DIR\"/" + $r),
    ("${CLAUDE_PROJECT_DIR}/" + $r),
    ("\"$CLAUDE_PROJECT_DIR/" + $r + "\"")
  ]'
}

# Echo the bare absolute path of a command that is exactly a bare or double-quoted absolute path to
# return-token-gate.sh; return 1 for any other form. Used to classify STALE candidates.
_rsdd_gate_stale_path() {
  local c="$1" p="$1" quoted=0
  if [[ "$c" == \"*\" && ${#c} -ge 2 ]]; then p="${c:1:${#c}-2}"; quoted=1; fi
  case "$p" in /*/return-token-gate.sh) ;; *) return 1 ;; esac  # RSDD-GATE-STRICT
  [[ "$p" == *[\"\$\~\`\']* || "$p" == *$'\n'* ]] && return 1
  if [ "$quoted" = 0 ] && [[ "$p" == *[[:space:]]* ]]; then return 1; fi
  printf '%s' "$p"
}

# kit issue #1496 (RDD round 1): ONE merge + dedup predicate for BOTH the wire-only repair and the
# scaffold --wire path, so the two can never diverge on which already-registered forms count as the
# same hook (they did: scaffold --wire matched exact strings only). Reads the base settings JSON on
# stdin; args: <stop-abs> <ss-abs> <pk-abs> <stop-rel> <ss-rel> <pk-rel> <skip_ss true|false> <gate-abs>
# (kit issue #1732: the return-token gate command, an explicit argument, no global). Emits
# {settings, has_stop, has_ss, has_pk, has_gate, has_current, repaired, requoted, others}; a skipped SessionStart never removes an
# existing entry.
# GATE (<gate-abs> is passed double-quoted): the CURRENT gate is a Stop command equal to it, or to its bare unquoted path.
# STALE means ONLY a command that is exactly a bare or double-quoted ABSOLUTE path to .../return-token-gate.sh (no
# arguments, no interpreter prefix, no `$`, no `~`) that does NOT exist on disk (the kit moved): all such entries are DROPPED
# and listed in `repaired`. EVERY other gate-looking command (interpreter-prefixed, with arguments, relative, `~`,
# $CLAUDE_PROJECT_DIR, or an absolute path that still exists) is a working gate in another form: it is never touched, it is
# listed in `others`, and it counts as registered (has_gate), so the current <gate-abs> is appended only when no working
# gate exists in any form.
# A bare (unquoted) CURRENT gate path containing whitespace word-splits and never runs (kit issue #1757): it is NOT a current
# form (`spaced_bare`, computed once). It is rewritten to the quoted form (the kit's own entry, so safe): the bare entry goes into
# the separate `requoted` bucket (dropped like a stale one, but reported as "requoted", never "stale") and the quoted one is appended.
_rsdd_merge_settings() {
  local sv ssv pv gv base c _gp _gpath spaced_bare=0 stale='[]' requoted='[]' others='[]'
  _gpath="${8#\"}"; _gpath="${_gpath%\"}"   # <gate-abs> arrives double-quoted; the bare path is also a CURRENT form
  [[ "$_gpath" == *[[:space:]]* ]] && spaced_bare=1   # RSDD-GATE-SPACED-BARE: computed ONCE; the bare form of a spaced path is unrunnable
  sv="$(_rsdd_cmd_variants_json "$1" "$4")"; ssv="$(_rsdd_cmd_variants_json "$2" "$5")"
  pv="$(_rsdd_cmd_variants_json "$3" "$6")"
  if [ "$spaced_bare" = 1 ]; then gv="$(jq -cn --arg g "$8" '[$g]')"
  else gv="$(jq -cn --arg g "$8" --arg p "$_gpath" '[$g, $p]')"; fi
  base="$(cat)"
  while IFS= read -r c; do
    [ "$c" = "$8" ] && continue
    if [ "$c" = "$_gpath" ]; then
      if [ "$spaced_bare" = 1 ]; then requoted="$(jq -c --arg c "$c" '. + [$c]' <<<"$requoted")"; fi
      continue
    fi
    if _gp="$(_rsdd_gate_stale_path "$c")" && [ "$_gp" != "$_gpath" ]; then
      [ -e "$_gp" ] || { stale="$(jq -c --arg c "$c" '. + [$c]' <<<"$stale")"; continue; }  # RSDD-GATE-STALE
    fi
    others="$(jq -c --arg c "$c" '. + [$c]' <<<"$others")"
  done < <(jq -r '(.hooks.Stop // [])[]? | (.hooks // [])[]? | (.command // empty) | select(type == "string" and contains("return-token-gate.sh"))' <<<"$base" 2>/dev/null)
  jq --arg sc "$1" --arg ac "$2" --arg pc "$3" --arg gc "$8" \
    --argjson stop_variants "$sv" --argjson ss_variants "$ssv" --argjson pk_variants "$pv" \
    --argjson gate_variants "$gv" --argjson stale "$stale" --argjson requoted "$requoted" --argjson others "$others" \
    --argjson skip_ss "$7" '
    ((.hooks.Stop // []) | map(.hooks // [] | map(.command)) | add // []) as $stop_cmds |
    ((.hooks.SessionStart // []) | map(.hooks // [] | map(.command)) | add // []) as $ss_cmds |
    ($stop_cmds | any(. as $c | ($stop_variants | index($c)) != null)) as $has_stop |
    # kit issue #1732: has_current = the CURRENT gate command is registered; has_gate = ANY working gate (current or another form).
    ($stop_cmds | any(. as $c | ($gate_variants | index($c)) != null)) as $has_current |
    ($has_current or ($others | length) > 0) as $has_gate |
    ($ss_cmds | any(. as $c | ($ss_variants | index($c)) != null)) as $has_ss |
    # kit issue #1509: the guard only protects Bash, so a registration counts as "present" ONLY under
    # a matcher that fires for Bash ("" / absent / "*" / a regex that fully matches "Bash"); the same
    # command under e.g. matcher "Edit" is not the guard wired. An invalid regex counts as not covering.
    def covers_bash: (.matcher // "") as $m |
      ($m == "" or $m == "*" or (try ("Bash" | test("^(?:" + $m + ")$")) catch false));
    ((.hooks.PreToolUse // []) | map(select(covers_bash) | .hooks // [] | map(.command)) | add // []) as $pk_cmds |
    ($pk_cmds | any(. as $c | ($pk_variants | index($c)) != null)) as $has_pk |
    (.hooks.PreToolUse = (if $has_pk then (.hooks.PreToolUse // [])
      else (.hooks.PreToolUse // []) + [{"matcher":"Bash","hooks":[{"type":"command","command":$pc}]}] end)) |
    (.hooks.Stop = ((.hooks.Stop // [])
      + (if $has_stop then [] else [{"matcher":"","hooks":[{"type":"command","command":$sc}]}] end)
      + (if $has_gate then [] else [{"matcher":"","hooks":[{"type":"command","command":$gc}]}] end))) |
    (($stale + $requoted)) as $drop |
    (if ($drop | length) > 0 then
       # drop EVERY stale gate hook plus any unrunnable bare spaced current entry (the current quoted one was appended above only
       # when NO working gate exists); an entry emptied by the drop is removed, every other entry is left byte-identical.
       (.hooks.Stop |= map(. as $e | ($e.hooks // []) as $h | ($h | map(select(((.command // "") | IN($drop[])) | not))) as $n
                           | if ($n | length) == ($h | length) then $e elif ($n | length) == 0 then empty else ($e | .hooks = $n) end))
     else . end) |
    (.hooks.SessionStart = (if $skip_ss or $has_ss then (.hooks.SessionStart // [])
      else (.hooks.SessionStart // []) + [{"matcher":"","hooks":[{"type":"command","command":$ac}]}] end)) |
    {settings: ., has_stop: $has_stop, has_ss: $has_ss, has_pk: $has_pk, has_gate: $has_gate, has_current: $has_current, repaired: $stale, requoted: $requoted, others: $others}
  ' <<<"$base"
}

# kit issue #2141: a hook that already EXISTS is never rewritten (hand-adapted hooks are not modified), but one without the
# execute bit is inert once wired (Claude Code runs the bare command and gets exit 126), so report it by name. Args: <hook-path>.
_rsdd_warn_hook_noexec() {
  [ ! -e "$1" ] || [ -x "$1" ] || echo "WARN: $1 is not executable — the hook cannot run until you chmod +x it (left untouched: hand-adapted hooks are never modified)." >&2
}
# kit issue #2141: the kit's own scripts are wired as bare commands too (Stop return-token gate, SessionStart drift hook); a kit
# checkout that lost its +x bits (zip export, non-POSIX mount) would register commands that exit 126. Args: <kit-script-path>.
_rsdd_warn_kit_script_noexec() {
  [ ! -e "$1" ] || [ -x "$1" ] || echo "WARN: kit script $1 is not executable — the hook wired to it cannot run until the kit checkout restores its execute bit (chmod +x it)." >&2
}

# kit issue #1732: ONE reporting block for the gate's status, shared by the wire-only repair and scaffold --wire paths
# (they carried two hand-copied renderings). Args: <merge-output-json> <settings-path>.
_rsdd_report_gate() {
  local out="$1" settings="$2" _old
  _rsdd_warn_kit_script_noexec "$_RSDD_GATE_PATH"
  if [ "$(jq -r '.repaired | length' <<<"$out")" != 0 ]; then
    jq -r '.repaired[] | ltrimstr("\"") | rtrimstr("\"")' <<<"$out" | while IFS= read -r _old; do
      echo "  wired  : Stop return-token gate repaired (stale path $_old) in $settings"
    done
  fi
  if [ "$(jq -r '.requoted | length' <<<"$out")" != 0 ]; then
    jq -r '.requoted[]' <<<"$out" | while IFS= read -r _old; do
      echo "  wired  : Stop return-token gate requoted (unquoted path with whitespace $_old would word-split) in $settings"
    done
  fi
  if [ "$(jq -r '.has_current | not' <<<"$out")" = "true" ] && [ "$(jq -r '.others | length' <<<"$out")" != 0 ]; then
    echo "  wired  : Stop return-token gate already wired (other form: $(jq -r '.others[0]' <<<"$out")) in $settings"
  elif [ "$(jq -r '(.repaired | length) + (.requoted | length)' <<<"$out")" != 0 ]; then :
  elif [ "$(jq -r '.has_gate' <<<"$out")" = "true" ]; then
    echo "  wired  : Stop return-token gate already wired in $settings"
  else
    echo "  wired  : Stop return-token gate registered in $settings"
  fi
}

# kit issue #1787 item 1: register the stale-KIT drift hook under SessionStart of an ALREADY-merged settings file, with the
# gate's machinery: the current command is the double-quoted kit path; a bare current path with whitespace word-splits and is
# rewritten (requoted); an exact bare/quoted ABSOLUTE path to .../verify-skill-drift-hook.sh that no longer exists is STALE and
# dropped (the kit moved); every other form (interpreter prefix, arguments, relative, ~, $CLAUDE_PROJECT_DIR, an absolute
# path that still exists) is a working registration in another form: never touched, and nothing is added next to it. Other
# SessionStart entries stay byte-identical; a re-run that changes nothing writes nothing. Prints typed "wired" lines.
# Args: <settings-path>. rc 1 = could not read/merge/install (the caller must not report success).
_rsdd_wire_drift() {
  local settings="$1" base c p quoted have=0 add=true drop='[]' others="" tmp rep=""
  _rsdd_warn_kit_script_noexec "$_RSDD_DRIFT_PATH"
  # ADVISORY (RDD round 1): a failure here is a typed WARN on stdout + rc 1, never fatal for the core wire (the caller keeps going).
  local w="  WARN   : drift hook not registered:"
  # RSDD_TEST_DRIFT_FAIL is a test seam only: it forces this failure path (the real ones need a broken filesystem).
  [ -z "${RSDD_TEST_DRIFT_FAIL:-}" ] || { echo "$w forced failure (test seam) — $settings left as the core wire wrote it"; return 1; }
  [ -s "$settings" ] || { echo "$w $settings is missing or empty"; return 1; }
  base="$(cat "$settings")" || { echo "$w could not read $settings"; return 1; }
  while IFS= read -r c; do
    if [ "$c" = "$_RSDD_DRIFT_CMD" ]; then have=1; continue; fi
    if [ "$c" = "$_RSDD_DRIFT_PATH" ]; then
      if [[ "$c" == *[[:space:]]* ]]; then   # RSDD-DRIFT-SPACED-BARE
        drop="$(jq -c --arg c "$c" '. + [$c]' <<<"$drop")"
        rep="$rep  wired  : SessionStart stale-KIT drift hook requoted (unquoted path with whitespace $c would word-split) in $settings"$'\n'
      else have=1; fi
      continue
    fi
    p="$c"; quoted=0
    if [[ "$c" == \"*\" && ${#c} -ge 2 ]]; then p="${c:1:${#c}-2}"; quoted=1; fi
    if [[ "$p" == /*/verify-skill-drift-hook.sh && "$p" != *[\"\$\~\`\']* && "$p" != *$'\n'* && ! -e "$p" ]] \
       && { [ "$quoted" = 1 ] || [[ "$p" != *[[:space:]]* ]]; }; then   # RSDD-DRIFT-STALE
      drop="$(jq -c --arg c "$c" '. + [$c]' <<<"$drop")"
      rep="$rep  wired  : SessionStart stale-KIT drift hook repaired (stale path $p) in $settings"$'\n'
      continue
    fi
    [ -n "$others" ] || others="$c"
  done < <(jq -r '(.hooks.SessionStart // [])[]? | (.hooks // [])[]? | (.command // empty) | select(type == "string" and contains("verify-skill-drift-hook.sh"))' <<<"$base" 2>/dev/null)
  if [ "$have" = 1 ] || [ -n "$others" ]; then add=false; fi
  if [ "$drop" = '[]' ] && [ "$add" = false ]; then
    if [ "$have" = 1 ]; then echo "  wired  : SessionStart stale-KIT drift hook already wired in $settings"
    else echo "  wired  : SessionStart stale-KIT drift hook already wired (other form: $others) in $settings"; fi
    return 0
  fi
  tmp="$(mktemp)" || { echo "$w mktemp failed"; return 1; }
  if ! jq --argjson drop "$drop" --argjson add "$add" --arg cmd "$_RSDD_DRIFT_CMD" '
      (if ($drop | length) > 0 then
         (.hooks.SessionStart |= map(. as $e | ($e.hooks // []) as $h | ($h | map(select(((.command // "") | IN($drop[])) | not))) as $n
                                     | if ($n | length) == ($h | length) then $e elif ($n | length) == 0 then empty else ($e | .hooks = $n) end))
       else . end)
      | if $add then .hooks.SessionStart = ((.hooks.SessionStart // []) + [{"matcher":"","hooks":[{"type":"command","command":$cmd,"timeout":15}]}]) else . end
    ' <<<"$base" > "$tmp" 2>/dev/null || [ ! -s "$tmp" ]; then rm -f "$tmp"; echo "$w jq could not edit $settings (unexpected SessionStart shape?)"; return 1; fi
  _rsdd_install_settings "$tmp" "$settings" || { echo "$w could not write $settings (left untouched)"; return 1; }
  printf '%s' "$rep"
  if [ "$add" = true ] && [ -z "$rep" ]; then echo "  wired  : SessionStart stale-KIT drift hook registered in $settings"
  elif [ "$add" = false ]; then
    # a stale/requoted entry was dropped in this run AND a working registration remains: say which one remains (never an empty "other form")
    if [ "$have" = 1 ]; then echo "  wired  : SessionStart stale-KIT drift hook already wired in $settings"
    else echo "  wired  : SessionStart stale-KIT drift hook already wired (other form: $others) in $settings"; fi
  fi
  return 0
}

# kit issue #1040 finding 2 (round 2 of #1038): the print-only fallback — jq absent, or jq
# processing failure — must honor the SAME #959 guard as the live-write path: never offer a
# SessionStart line to paste while research-protocol.sh still carries a live <SUBJECT>.
_rsdd_print_wire_snippet() {
  local stop_cmd="$1" ss_cmd="$2" skip_ss="$3" tgt="$4" pk_cmd="$5"
  echo "-- §479 HOOK WIRING snippet (paste into $tgt/.claude/settings.json) --"
  _rsdd_print_wire_block "$stop_cmd" "$ss_cmd" "$skip_ss" "$pk_cmd"
  if [ "$skip_ss" = "true" ]; then
    echo "-- SessionStart omitted: $ss_cmd still has the <SUBJECT> placeholder (adapt it first, PROMPT-LOOP §c follow-up) --"
  fi
}

# JSON-escape one string value in pure bash (the degraded snippet is printed when jq is absent): backslash and quote.
_rsdd_json_esc() { local v="${1//\\/\\\\}"; printf '%s' "${v//\"/\\\"}"; }

# kit issue #1509: the JSON block alone, shared by the wire-only/degraded snippet above AND the
# scaffold print-only snippet (they used to carry two hand-copied renderings of the same block).
_rsdd_print_wire_block() {
  local stop_cmd ss_cmd="$2" skip_ss="$3" pk_cmd gate_cmd
  stop_cmd="$(_rsdd_json_esc "$1")"; ss_cmd="$(_rsdd_json_esc "$ss_cmd")"; pk_cmd="$(_rsdd_json_esc "$4")"; gate_cmd="$(_rsdd_json_esc "$_RSDD_GATE_CMD")"
  # kit issue #1496: PreToolUse (matcher Bash) carries the pkill-guard; it takes no per-target
  # params, so it is always offered (like Stop). SessionStart is omitted while unadapted (#959).
  local pk_entry="      {\"matcher\":\"Bash\",\"hooks\":[{\"type\":\"command\",\"command\":\"$pk_cmd\"}]}"
  local stop_entry="      {\"matcher\":\"\",\"hooks\":[{\"type\":\"command\",\"command\":\"$stop_cmd\"}]}"
  local ss_entry="      {\"matcher\":\"\",\"hooks\":[{\"type\":\"command\",\"command\":\"$ss_cmd\"}]}"
  local gate_entry="      {\"matcher\":\"\",\"hooks\":[{\"type\":\"command\",\"command\":\"$gate_cmd\"}]}"
  local drift_entry drift_cmd
  drift_cmd="$(_rsdd_json_esc "$_RSDD_DRIFT_CMD")"
  drift_entry="      {\"matcher\":\"\",\"hooks\":[{\"type\":\"command\",\"command\":\"$drift_cmd\",\"timeout\":15}]}"
  if [ "$skip_ss" = "true" ]; then
    printf '%s\n' '{' \
      '  "hooks": {' \
      '    "Stop": [' "$stop_entry," "$gate_entry" '    ],' \
      '    "PreToolUse": [' "$pk_entry" '    ],' \
      '    "SessionStart": [' "$drift_entry" '    ]' \
      '  }' \
      '}'
  else
    printf '%s\n' '{' \
      '  "hooks": {' \
      '    "Stop": [' "$stop_entry," "$gate_entry" '    ],' \
      '    "PreToolUse": [' "$pk_entry" '    ],' \
      '    "SessionStart": [' "$ss_entry," "$drift_entry" '    ]' \
      '  }' \
      '}'
  fi
}
