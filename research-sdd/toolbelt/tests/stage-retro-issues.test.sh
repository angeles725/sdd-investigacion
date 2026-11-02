#!/usr/bin/env bash
# stage-retro-issues.test.sh — TDD harness for stage-retro-issues.sh.
#
# Covers: dry-run output for pending retro; partial marker (deferred rows only);
# empty-input (no delta section); no-match (all shipped/applied); wrong-kit row;
# no-priority row (label omitted); --apply dedup (stub returns existing match);
# --apply creates issue (stub records the call); absent-input (file not found);
# degraded on missing gh under --apply.
#
# Usage: stage-retro-issues.test.sh                (run the suite)
#        stage-retro-issues.test.sh --prove-teeth  (run suite + mutation teeth)
# Exit: 0 = all pass · 1 = failure · 2 = harness error

set -uo pipefail
# HERMETICITY (kit issue #1157): never read the developer's real ~/.claude/projects launch history.
export RSDD_CLAUDE_PROJECTS_DIR="/nonexistent/rsdd-claude-history"
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../stage-retro-issues.sh"
[ -f "$SUT" ] || { echo "FATAL: script under test not found: $SUT" >&2; exit 2; }
RETRO_STATUS_LIB="$HERE/../lib/retro-status.sh"
[ -f "$RETRO_STATUS_LIB" ] || { echo "FATAL: retro-status helper not found" >&2; exit 2; }
RETRO_GRAMMAR_LIB="$HERE/../lib/retro-grammar.sh"
[ -f "$RETRO_GRAMMAR_LIB" ] || { echo "FATAL: retro-grammar helper not found" >&2; exit 2; }
TARGET_PATHS_LIB="$HERE/../lib/target-paths.sh"
[ -f "$TARGET_PATHS_LIB" ] || { echo "FATAL: target-paths helper not found" >&2; exit 2; }
SCRUB_LIB="$HERE/../lib/scrub-issue-text.sh"
[ -f "$SCRUB_LIB" ] || { echo "FATAL: scrub-issue-text helper not found" >&2; exit 2; }
BASH_BIN="$(type -P bash)"; [ -n "$BASH_BIN" ] || { echo "FATAL: bash not on PATH" >&2; exit 2; }
command -v awk  >/dev/null 2>&1 || { echo "FATAL: awk not on PATH" >&2; exit 2; }
command -v grep >/dev/null 2>&1 || { echo "FATAL: grep not on PATH" >&2; exit 2; }

# Pre-resolve coreutil paths for hermetic PATH construction in degraded test
_AWK_BIN="$(type -P awk)"; _GREP_BIN="$(type -P grep)"
_SED_BIN="$(type -P sed)"; _TR_BIN="$(type -P tr)"
_DIRNAME_BIN="$(type -P dirname)"; _BASENAME_BIN="$(type -P basename)"
_HEAD_BIN="$(type -P head)"; _SORT_BIN="$(type -P sort)"
_CUT_BIN="$(type -P cut)"; _PRINTF_BIN="$(type -P printf 2>/dev/null)" || _PRINTF_BIN=""

# mk_hermetic_bin <box>: populate $box/bin with symlinks to essential coreutils
# but WITHOUT gh — used for the degraded test case.
mk_hermetic_bin() {
  local box="$1"
  mkdir -p "$box/bin"
  ln -sf "$BASH_BIN"     "$box/bin/bash"
  ln -sf "$_AWK_BIN"     "$box/bin/awk"
  ln -sf "$_GREP_BIN"    "$box/bin/grep"
  ln -sf "$_SED_BIN"     "$box/bin/sed"
  ln -sf "$_TR_BIN"      "$box/bin/tr"
  ln -sf "$_DIRNAME_BIN" "$box/bin/dirname"
  ln -sf "$_BASENAME_BIN" "$box/bin/basename"
  ln -sf "$_HEAD_BIN"    "$box/bin/head"
  ln -sf "$_SORT_BIN"    "$box/bin/sort"
  ln -sf "$_CUT_BIN"     "$box/bin/cut"
  # No gh symlink — that is the point of this helper
}

# mk_no_git_bin <box>: populate $box/nogit-bin with symlinks to essential
# coreutils AND $box/bin/gh (if it exists) but WITHOUT git — used for the
# "git missing" degraded-message tests (kit issue #1045). Unlike
# mk_hermetic_bin, gh IS included here so the --apply gh-probe passes and the
# test actually exercises the git-missing branch of kit-issue-repo resolution,
# not the earlier gh-missing probe.
mk_no_git_bin() {
  local box="$1"
  mkdir -p "$box/nogit-bin"
  ln -sf "$BASH_BIN"      "$box/nogit-bin/bash"
  ln -sf "$_AWK_BIN"      "$box/nogit-bin/awk"
  ln -sf "$_GREP_BIN"     "$box/nogit-bin/grep"
  ln -sf "$_SED_BIN"      "$box/nogit-bin/sed"
  ln -sf "$_TR_BIN"       "$box/nogit-bin/tr"
  ln -sf "$_DIRNAME_BIN"  "$box/nogit-bin/dirname"
  ln -sf "$_BASENAME_BIN" "$box/nogit-bin/basename"
  ln -sf "$_HEAD_BIN"     "$box/nogit-bin/head"
  ln -sf "$_SORT_BIN"     "$box/nogit-bin/sort"
  ln -sf "$_CUT_BIN"      "$box/nogit-bin/cut"
  [ -x "$box/bin/gh" ] && ln -sf "$box/bin/gh" "$box/nogit-bin/gh"
  # No git symlink — that is the point of this helper
}

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
pass=0; fail=0
ok() { printf '  PASS  %-60s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
no() { printf '  FAIL  %-60s %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

# ---------------------------------------------------------------------------
# SANDBOX BUILDER
# mkbox <name> [target-name]
#   Creates a hermetic sandbox:
#     $box/
#       research-sdd/
#         TARGETS.md          — one-row table pointing at $box/rh/<target>
#         toolbelt/
#           stage-retro-issues.sh   (copy of SUT)
#           lib/               (copies of required libs)
#       rh/<target>/retros/    (where test retros land)
#       bin/                   (gh stub, if mk_gh_stub is called after)
#   Returns the box path (no trailing newline; echoes to stdout).
# mkbox_at <base-dir> <name> [target-name]
#   Same as mkbox (below) but the box is created under <base-dir> instead of
#   $ROOT. Used by the F1 (kit issue #1045) enclosing-repo-walk fixture, which
#   needs the box's PARENT to be a git repo while the box itself stays a plain
#   directory (never git-inited) — mkbox's own boxes are never repos, so this
#   is the only fixture that deliberately relies on git's upward remote walk;
#   every other fixture stays either its own repo (mk_git_remote/mk_foreign_repo)
#   or explicitly not a repo at all.
mkbox_at() {
  local base="$1" name="$2" tgt="${3:-target-foo}"
  local box="$base/$name"
  mkdir -p "$box/research-sdd/toolbelt/lib" "$box/rh/$tgt/retros" "$box/bin"
  cp "$SUT"              "$box/research-sdd/toolbelt/stage-retro-issues.sh"
  cp "$RETRO_STATUS_LIB" "$box/research-sdd/toolbelt/lib/retro-status.sh"
  cp "$RETRO_GRAMMAR_LIB" "$box/research-sdd/toolbelt/lib/retro-grammar.sh"
  cp "$TARGET_PATHS_LIB" "$box/research-sdd/toolbelt/lib/target-paths.sh"
  cp "$SCRUB_LIB"        "$box/research-sdd/toolbelt/lib/scrub-issue-text.sh"
  # TARGETS.md with an absolute path so target_paths_all resolves correctly
  {
    printf '# test targets\n\n| # | Target | Path |\n|---|---|---|\n'
    printf '| 1 | %s | `%s` |\n' "$tgt" "$box/rh/$tgt"
  } > "$box/research-sdd/TARGETS.md"
  printf '%s' "$box"
}

mkbox() {
  mkbox_at "$ROOT" "$@"
}

# mk_gh_stub <box> [mode]
#   mode=noauth      : `gh auth status` fails (unauthenticated)
#   mode=match       : `gh issue list --json state` returns an OPEN match (dedup)
#   mode=matchclosed : `gh issue list --json state` returns a CLOSED match — kit issue #949
#                      item 2: a closed match must ALSO dedup, not just an open one
#   mode=nomatch     : `gh issue list` returns an empty JSON array (no existing issue) [default]
#   mode=listfail    : `gh issue list` exits non-zero (simulates a real gh/API failure) — must
#                      count as failed, never fall through to create
#   mode=listempty   : `gh issue list` exits 0 with EMPTY stdout (no '[' at all) — kit issue
#                      #1093 item 1: a transient gh/API hiccup that still exits 0 must NOT be
#                      read as "no match" and fall through to create; it must count as failed,
#                      exactly like listfail
#   mode=createfail  : `gh issue list` returns empty; `gh issue create` exits 1 (API error)
#   mode=createnourl : `gh issue create` exits 0 but prints NO issue URL (kit issue #1705)
#   In all non-noauth, non-listfail modes: `gh issue create` logs its args, remembers its --body and echoes
#   a fake URL (except createfail). 5th arg viewmode (kit issue #1705) shapes `gh issue view <N> --json body
#   --jq .body`: ok (default; replies the body the create sent) | nosig (a body without the signature line) |
#   empty (exit 0, no output) | fail (exit 1).
mk_gh_stub() {
  local box="$1" mode="${2:-nomatch}" sigpat="${3:-}" labelmode="${4:-exists}" viewmode="${5:-ok}"
  {
    printf '#!%s\n' "$BASH_BIN"
    # Log all calls for inspection
    printf 'printf "%%s\\n" "gh $*" >> "%s/bin/gh.log"\n' "$box"
    if [ "$mode" = "noauth" ]; then
      printf 'case " $* " in\n'
      printf '  *" auth status "*) exit 1 ;;\n'
      printf '  *) exit 0 ;;\n'
      printf 'esac\n'
    else
      # Kit issue #1304 item 1: the dedup now fetches --json state,body and keeps only hits whose
      # BODY carries the exact signature line, so a matching stub must reply the way real GitHub
      # does — with a body. The signature is read back from the --search argument the SUT sent, so
      # one stub serves every target/file/row. reply <STATE> = an exact-signature hit;
      # fuzzy_other <STATE> = a different TARGET's issue (GitHub fuzzy word match);
      # fuzzy_longid <STATE> = the same retro but row id <id>0 (a prefix-id fuzzy hit).
      cat <<'STUBHELP'
_sig=""; _prev=""
for _a in "$@"; do [ "$_prev" = "--search" ] && _sig="$_a"; _prev="$_a"; done
save_body() { local _p="" _x; for _x in "$@"; do [ "$_p" = "--body" ] && printf "%s" "$_x" > "$0.body"; _p="$_x"; done; }
_validate_view() {
  local _sk="" _a _n=0 _repo=0 _json=0 _jq=0
  for _a in "$@"; do
    if [ -n "$_sk" ]; then
      case "$_sk" in json) [ "$_a" = body ] && _json=1 ;; jq) [ "$_a" = .body ] && _jq=1 ;; repo) _repo=1 ;; esac
      _sk=""; continue
    fi
    case "$_a" in
      issue|view) ;;
      --repo) _sk=repo ;; --json) _sk=json ;; --jq) _sk=jq ;;
      [0-9]*) case "$_a" in *[!0-9]*) echo "gh stub: bad issue number: $_a" >&2; return 1 ;; esac; _n=1 ;;
      *) echo "gh stub: unknown flag: $_a" >&2; return 1 ;;
    esac
  done
  [ "$_n$_repo$_json$_jq" = 1111 ] || { echo "gh stub: issue view needs <N> --repo R --json body --jq .body" >&2; return 1; }
}
_sig="${_sig#\"}"; _sig="${_sig%\"}"
reply() { printf '[{"body":"Delta text\\n\\n**Target:** x\\n\\n---\\n%s\\nPart of backlog-first rollout #557","state":"%s"}]\n' "$_sig" "$1"; }
fuzzy_other() { printf '[{"body":"Other delta\\n\\n---\\nSource retro: niagara-%s\\nPart of backlog-first rollout #557","state":"%s"}]\n' "${_sig#Source retro: }" "$1"; }
fuzzy_longid() { printf '[{"body":"Other row\\n\\n---\\n%s0\\nPart of backlog-first rollout #557","state":"%s"}]\n' "$_sig" "$1"; }
fuzzy_plus_exact() { printf '[{"body":"Other\\n---\\nSource retro: niagara-%s","state":"OPEN"},{"body":"x\\n---\\n%s\\ntail","state":"OPEN"}]\n' "${_sig#Source retro: }" "$_sig"; }
crlf_reply() { printf '[{"body":"x\\n---\\n%s\\r\\ntail","state":"OPEN"}]\n' "$_sig"; }
create_alt() { local n; n="$(cat "$0.cnt" 2>/dev/null || echo 0)"; n=$((n+1)); echo "$n" > "$0.cnt"; if [ "$n" -ge 2 ]; then printf 'ERROR: GraphQL request failed\n'; return 1; fi; printf 'https://github.com/r/issues/%s\n' "$n"; }
sigonly_reply() { printf '[{"state":"OPEN","body":"%s"}]\n' "$_sig"; }
# Kit issue #1369 (c): the stub must REJECT what real gh would reject instead of inventing support.
# `gh issue list` here accepts only --repo/--state/--search/--jq/--limit/--json, --limit a positive
# integer, --json fields from {state, body}. Anything else exits 2 with a gh-style message.
_validate_list() {
  local _sk="" _a _f
  for _a in "$@"; do
    if [ -n "$_sk" ]; then
      case "$_sk" in
        json)  for _f in ${_a//,/ }; do case "$_f" in state|body|number|title) ;; *) echo "gh stub: unknown JSON field: $_f" >&2; return 1 ;; esac; done ;;
        limit) case "$_a" in ''|*[!0-9]*|0) echo "gh stub: invalid --limit: $_a" >&2; return 1 ;; esac ;;
        state) case "$_a" in open|closed|all) ;; *) echo "gh stub: invalid --state: $_a" >&2; return 1 ;; esac ;;
      esac
      _sk=""; continue
    fi
    case "$_a" in
      issue|list) ;;
      --repo|--search|--jq|--label) _sk=val ;;
      --state) _sk=state ;;
      --json)  _sk=json ;;
      --limit) _sk=limit ;;
      *) echo "gh stub: unknown flag: $_a" >&2; return 1 ;;
    esac
  done
}
# page2: a repo with two NON-matching issues for the query. Honours --limit exactly as gh does: at most
# <limit> of them come back, so limit 2 returns a FULL page (possibly truncated) and limit 3 does not.
page2_reply() {
  local _l="" _p="" _a _n _i _o=""
  for _a in "$@"; do [ "$_p" = "--limit" ] && _l="$_a"; _p="$_a"; done
  _n=2; [ -n "$_l" ] && [ "$_l" -lt 2 ] && _n="$_l"
  for ((_i = 1; _i <= _n; _i++)); do _o="${_o}${_o:+,}{\"body\":\"unrelated issue $_i\",\"state\":\"OPEN\"}"; done
  printf '[%s]\n' "$_o"
}
# Kit issue #1708: occurrence-comment surface. The OCCURRENCE lookup (`gh issue list ... --json number,state,title`)
# replies the JSON array in $0.occ (absent = `[]`, no candidates; empty file = empty reply). $0.occfail = exit 1;
# $0.occnoend = a reply cut off mid-string (unparseable).
# `gh issue comment` appends its --body to $0.comments (fails when $0.commentfail exists; with $0.commentghost the
# write is NOT recorded yet the exit is 0 and a URL prints); `gh issue view <N> --json comments` replays
# $0.comments (fails when $0.viewfail exists).
occ_list() {
  # $0.occ2: from the SECOND list call on, reply this instead (a create whose outcome was unknown had landed).
  local _on; _on="$(cat "$0.occn" 2>/dev/null || echo 0)"; _on=$((_on+1)); echo "$_on" > "$0.occn"
  [ "$_on" -ge 2 ] && [ -f "$0.occ2" ] && { cat "$0.occ2"; return 0; }
  [ -f "$0.occfail" ] && { printf 'gh: occurrence lookup failed\n' >&2; return 1; }
  [ -f "$0.occnoend" ] && { printf '[{"number":55,"state":"OPEN","title":"cut off here\n'; return 0; }
  if [ -f "$0.occ" ]; then cat "$0.occ"; else printf '[]\n'; fi
  return 0
}
occ_comment() {
  local _p="" _n="" _b="" _x
  for _x in "$@"; do
    [ "$_p" = "--body" ] && _b="$_x"
    case "$_x" in [0-9]*) _n="$_x" ;; esac
    _p="$_x"
  done
  # $0.commentfailwrote: the write LANDS (recorded) but the call still exits 1 (a timeout after the write).
  [ -f "$0.commentfailwrote" ] && { printf '%s\n' "$_b" >> "$0.comments.$_n"; printf 'gh: timeout\n' >&2; return 1; }
  [ -f "$0.commentfail" ] || [ -f "$0.commentfail.$_n" ] && { printf 'gh: comment failed\n' >&2; return 1; }
  [ -f "$0.commentghost" ] || [ -f "$0.commentghost.$_n" ] || printf '%s\n' "$_b" >> "$0.comments.$_n"
  [ -f "$0.commentnourl" ] && { printf 'done\n'; return 0; }
  printf 'https://github.com/r/issues/%s#issuecomment-1\n' "$_n"
}
occ_view() {
  local _n="" _x
  for _x in "$@"; do case "$_x" in [0-9]*) _n="$_x" ;; esac; done
  [ -f "$0.viewfail" ] && { printf 'gh: HTTP 502\n' >&2; return 1; }
  # $0.viewfailafter holds K: the K-th and later comment views fail (view 1 = pre-write check, 2 = re-read/read-back).
  if [ -f "$0.viewfailafter" ]; then
    local _vc; _vc="$(cat "$0.vcnt" 2>/dev/null || echo 0)"; _vc=$((_vc+1)); echo "$_vc" > "$0.vcnt"
    [ "$_vc" -ge "$(cat "$0.viewfailafter")" ] && { printf 'gh: HTTP 502\n' >&2; return 1; }
  fi
  [ -f "$0.comments.$_n" ] && cat "$0.comments.$_n"
  return 0
}
STUBHELP
      printf 'case " $* " in *" issue list "*) _validate_list "$@" || exit 2 ;; esac\n'
      printf 'case " $* " in\n'
      printf '  *" auth status "*) exit 0 ;;\n'
      # Kit issue #1332 item 1: the `target:<name>` label probe. labelmode (4th arg):
      #   exists (default) : `gh label list` replies with the label the --search asked for
      #   missing          : `gh label list` replies [] and `gh label create` succeeds
      #   listfail         : `gh label list` exits 1
      #   listempty        : `gh label list` exits 0 with EMPTY stdout (not a JSON array)
      #   createfail       : `gh label list` replies [] and `gh label create` exits 1
      #   failjson         : `gh label list` prints a valid '[]' but exits 1 (rc must win over the reply)
      #   existsupper      : the label exists but with UPPER-CASE letters (GitHub label names are case-insensitive)
      #   racewin          : first `label list` -> [], `label create` exits 1, SECOND `label list` -> exists (a concurrent run created it)
      #   fuzzyonly        : `gh label list` replies ONLY a longer, different label (a fuzzy hit)
      case "$labelmode" in
        exists)     printf '  *" label list "*) _s=""; _p=""; for _a in "$@"; do [ "$_p" = "--search" ] && _s="$_a"; _p="$_a"; done; printf "[{\\"name\\":\\"%%s\\"}]\\n" "$_s"; exit 0 ;;\n' ;;
        existsupper) printf '  *" label list "*) _s=""; _p=""; for _a in "$@"; do [ "$_p" = "--search" ] && _s="$_a"; _p="$_a"; done; _u="$(printf "%%s" "$_s" | tr a-z A-Z)"; printf "[{\\"name\\":\\"%%s\\"}]\\n" "$_u"; exit 0 ;;\n' ;;
        racewin)    printf '  *" label list "*) _c="$(cat "$0.lcnt" 2>/dev/null || echo 0)"; _c=$((_c+1)); echo "$_c" > "$0.lcnt"; _s=""; _p=""; for _a in "$@"; do [ "$_p" = "--search" ] && _s="$_a"; _p="$_a"; done; if [ "$_c" -ge 2 ]; then printf "[{\\"name\\":\\"%%s\\"}]\\n" "$_s"; else printf "[]\\n"; fi; exit 0 ;;\n' ;;
        fuzzyonly)  printf '  *" label list "*) _s=""; _p=""; for _a in "$@"; do [ "$_p" = "--search" ] && _s="$_a"; _p="$_a"; done; printf "[{\\"name\\":\\"%%s-extra\\"}]\\n" "$_s"; exit 0 ;;\n' ;;
        listfail)   printf '  *" label list "*) printf "gh: label list failed\\n" >&2; exit 1 ;;\n' ;;
        listempty)  printf '  *" label list "*) exit 0 ;;\n' ;;
        failjson)   printf '  *" label list "*) printf "[]\\n"; exit 1 ;;\n' ;;   # exit 1 BUT a parseable array
        *)          printf '  *" label list "*) printf "[]\\n"; exit 0 ;;\n' ;;
      esac
      if [ "$labelmode" = "createfail" ] || [ "$labelmode" = "racewin" ]; then
        printf '  *" label create "*) printf "gh: label create failed\\n" >&2; exit 1 ;;\n'
      else
        printf '  *" label create "*) exit 0 ;;\n'
      fi
      cat <<'STUBOCC'
  *" issue list "*" number,state,title "*) occ_list; exit $? ;;
  *" issue comment "*) occ_comment "$@"; exit $? ;;
  *" issue view "*" --json comments "*) occ_view "$@"; exit $? ;;
STUBOCC
      case "$mode" in
        match)
          printf '  *" issue list "*) reply OPEN; exit 0 ;;\n'
          ;;
        fuzzyother)
          # Fuzzy-search false hit: another TARGET's issue (open). Must NOT count as a duplicate.
          printf '  *" issue list "*) fuzzy_other OPEN; exit 0 ;;\n'
          ;;
        fuzzyotherclosed)
          printf '  *" issue list "*) fuzzy_other CLOSED; exit 0 ;;\n'
          ;;
        fuzzylongid)
          # Fuzzy-search false hit: the same retro, row id with an extra digit (row 3 vs row 30).
          printf '  *" issue list "*) fuzzy_longid OPEN; exit 0 ;;\n'
          ;;
        fuzzyplusexact)
          # A fuzzy false hit AND the genuine exact hit in one reply: the exact one must win.
          printf '  *" issue list "*) fuzzy_plus_exact; exit 0 ;;\n'
          ;;
        crlfsig)
          # The exact signature line carries a trailing CR (a body edited in the web UI).
          printf '  *" issue list "*) crlf_reply; exit 0 ;;\n'
          ;;
        sigonly)
          # LIST EDGE: the body IS the signature (first AND last line), state key BEFORE body.
          printf '  *" issue list "*) sigonly_reply; exit 0 ;;\n'
          ;;
        nullbody)
          printf '  *" issue list "*) printf "[{\\"body\\":null,\\"state\\":\\"OPEN\\"}]\\n"; exit 0 ;;\n'
          ;;
        badjson)
          # Exit 0 and starts with '[' but is cut off mid-string: unparseable, must count as failed.
          printf '  *" issue list "*) printf "[{\\"body\\":\\"cut off here\\n"; exit 0 ;;\n'
          ;;
        matchclosed)
          # A real `gh issue list --state open` never returns a CLOSED issue at all — the
          # filtering happens server-side. Simulate that: only a call that actually asks for
          # 'all' or 'closed' sees the closed match; '--state open' gets an empty result. This
          # is what makes teeth T22 (reverting --state all back to --state open) meaningful —
          # without this state-sensitivity the stub would return the closed match regardless of
          # which --state flag the mutant sent, and the code's own JSON parsing would mask the
          # very regression the tooth exists to prove.
          printf '  *" --state open "*) printf "[]\\n"; exit 0 ;;\n'
          printf '  *" issue list "*) reply CLOSED; exit 0 ;;\n'
          ;;
        matchsig)
          # kit issue #1287 item 2: an OPEN match ONLY for a `gh issue list` whose --search text
          # contains $sigpat (the 3rd arg); every other list call sees an empty array. Lets a test
          # prove WHICH signature (new vs legacy) a dedup lookup carried.
          printf '  *" issue list "*"%s"*) reply OPEN; exit 0 ;;\n' "$sigpat"
          printf '  *" issue list "*) printf "[]\\n"; exit 0 ;;\n'
          ;;
        matchsigclosed)
          # Like matchsig, but the matching list call returns a CLOSED issue — the live case for
          # the legacy signature (every pre-#1286 issue is closed today).
          printf '  *" issue list "*"%s"*) reply CLOSED; exit 0 ;;\n' "$sigpat"
          printf '  *" issue list "*) printf "[]\\n"; exit 0 ;;\n'
          ;;
        failsig)
          # Like matchsig, but the matching list call FAILS (exit 1) — a failed lookup for ONE of
          # the signatures must still count as failed, never fall through to create.
          printf '  *" issue list "*"%s"*) printf "gh: error: something went wrong\\n" >&2; exit 1 ;;\n' "$sigpat"
          printf '  *" issue list "*) printf "[]\\n"; exit 0 ;;\n'
          ;;
        page2)
          printf '  *" issue list "*) page2_reply "$@"; exit 0 ;;\n'
          ;;
        listfail)
          printf '  *" issue list "*) printf "gh: error: something went wrong\\n" >&2; exit 1 ;;\n'
          ;;
        createfailcreated)
          # kit issue #1261: `gh issue create` FAILS but the issue was in fact created server-side
          # (a timeout after the write). Lists see nothing until the create ran, then the exact hit.
          printf '  *" issue list "*) if [ -f "$0.created" ]; then reply OPEN; else printf "[]\\n"; fi; exit 0 ;;\n'
          ;;
        createfailrelistfail)
          # kit issue #1261: create fails AND the follow-up lookup fails — the outcome stays unknown.
          printf '  *" issue list "*) if [ -f "$0.created" ]; then printf "gh: error: boom\\n" >&2; exit 1; else printf "[]\\n"; fi; exit 0 ;;\n'
          ;;
        listempty)
          # Exit 0, EMPTY stdout — no '[' at all. Distinguishes "the call succeeded and truly
          # found nothing" (a real '[]' reply) from "the call succeeded but the reply itself is
          # garbage/empty" (kit issue #1093 item 1).
          printf '  *" issue list "*) exit 0 ;;\n'
          ;;
        *)
          # nomatch / createfail: empty JSON array
          printf '  *" issue list "*) printf "[]\\n"; exit 0 ;;\n'
          ;;
      esac
      if [ "$mode" = "createfail" ]; then
        # createfail: gh issue create exits 1 to simulate an API error
        printf '  *" issue create "*) printf "ERROR: GraphQL request failed\\n"; exit 1 ;;\n'
      elif [ "$mode" = "createnourl" ]; then
        printf '  *" issue create "*) save_body "$@"; printf "Created!\\n"; exit 0 ;;\n'
      elif [ "$mode" = "createfailcreated" ] || [ "$mode" = "createfailrelistfail" ]; then
        printf '  *" issue create "*) : > "$0.created"; printf "ERROR: timeout after write\\n"; exit 1 ;;\n'
      elif [ "$mode" = "createfailsecond" ]; then
        # createfailsecond (kit issue #949 item 4): the FIRST create succeeds, every later one fails
        # — a mixed success/failure run (created=1 failed=1), not all-or-nothing.
        printf '  *" issue create "*) save_body "$@"; create_alt; exit $? ;;\n'
      else
        printf '  *" issue create "*) save_body "$@"; printf "https://github.com/r/issues/99\\n"; exit 0 ;;\n'
      fi
      # kit issue #1705: `gh issue view <N> --json body --jq .body` — the read-back after a create.
      case "$viewmode" in
        ok)    printf '  *" issue view "*) _validate_view "$@" || exit 2; [ -f "$0.body" ] || { printf "gh: could not resolve to an issue\\n" >&2; exit 1; }; cat "$0.body"; printf "\\n"; exit 0 ;;\n' ;;
        nosig) printf '  *" issue view "*) _validate_view "$@" || exit 2; printf "Some other body without the signature\\n"; exit 0 ;;\n' ;;
        empty) printf '  *" issue view "*) _validate_view "$@" || exit 2; exit 0 ;;\n' ;;
        fail)  printf '  *" issue view "*) _validate_view "$@" || exit 2; printf "gh: HTTP 502\\n" >&2; exit 1 ;;\n' ;;
      esac
      printf '  *) exit 0 ;;\n'
      printf 'esac\n'
    fi
  } > "$box/bin/gh"
  chmod +x "$box/bin/gh"
}

# mk_git_remote <box> <url>: git-init the KIT root (= box itself, since script sits at
# $box/research-sdd/toolbelt/… and KIT_ROOT = script_dir/../..) and set 'origin' to
# <url>. Used only by tests exercising the git-remote-derivation path (kit issue
# #1037); an untouched mkbox (no git init) is what makes a box's git-remote
# resolution naturally unresolvable — that IS the "no repo configured" fixture.
mk_git_remote() {
  local box="$1" url="$2"
  git init -q "$box" >/dev/null 2>&1
  git -C "$box" remote add origin "$url" >/dev/null 2>&1 \
    || git -C "$box" remote set-url origin "$url" >/dev/null 2>&1
}

# mk_foreign_repo <dir> <url>: git-init a standalone repo at <dir> with 'origin' set
# to <url>. Simulates the retro-gate.sh Stop-hook scenario where the process cwd is
# a TARGET repo (its own, different, remote) while the kit repo lives elsewhere on
# disk — proves repo resolution reads KIT_ROOT's remote, never the process cwd's.
mk_foreign_repo() {
  local dir="$1" url="$2"
  mkdir -p "$dir"
  git init -q "$dir" >/dev/null 2>&1
  git -C "$dir" remote add origin "$url" >/dev/null 2>&1
}

# mk_retro <box> <target> <filename> <marker> <table-content>
#   Writes a retro file at $box/rh/<target>/retros/<filename>.
#   <marker>        : the leading HTML comment line, or "-" for none
#   <table-content> : extra lines appended AFTER the canonical header/separator
#                     (pass "" for an empty table, "-" to skip the delta section entirely)
mk_retro() {
  local box="$1" tgt="$2" fname="$3" marker="$4" table_content="$5"
  local f="$box/rh/$tgt/retros/$fname"
  {
    [ "$marker" = "-" ] || printf '%s\n' "$marker"
    if [ "$table_content" = "-" ]; then
      # No delta section
      printf '# retro\n\nNo proposed deltas here.\n'
    else
      printf '# retro\n\n## Proposed kit deltas\n\n'
      printf '| # | Proposed change | Target (file) | Evidence | Type | Priority |\n'
      printf '|---|---|---|---|---|---|\n'
      [ -z "$table_content" ] || printf '%s\n' "$table_content"
    fi
  } > "$f"
  printf '%s' "$f"
}

# run <box> <retro-path> [extra-args...]
#   Invoke the sandbox SUT copy; capture stdout+stderr into OUT, RC into RC.
#   RESEARCH_SDD_ISSUE_REPO defaults to a fixed fake value so every PRE-EXISTING
#   test keeps exercising gh (dedup/create/failure) without needing its own git
#   remote — the ":-" fallback means an already-exported value (used by the new
#   env-override tests) still wins, per resolution order §1.
run() {
  local box="$1" retro="$2"; shift 2
  OUT="$(PATH="$box/bin:$PATH" \
    RESEARCH_SDD_ISSUE_REPO="${RESEARCH_SDD_ISSUE_REPO:-test-owner/test-kit}" \
    "$BASH_BIN" "$box/research-sdd/toolbelt/stage-retro-issues.sh" \
    "$retro" "$@" 2>&1)"; RC=$?
}

# mk_nested_retro <box> <subpath-under-target> <fname> (kit issue #1169): retro at
#   rh/target-foo/<subpath>/<fname> (nested/deeper corpus layouts); echoes its path.
mk_nested_retro() {
  local box="$1" sub="$2" fname="$3"
  local d="$box/rh/target-foo/$sub"
  mkdir -p "$d"
  {
    printf '<!-- review-status: pending -->\n# retro\n\n## Proposed kit deltas\n\n'
    printf '| # | Proposed change | Target (file) | Evidence | Type | Priority |\n|---|---|---|---|---|---|\n'
    printf '| 1 | nested delta | CLAUDE.md | B1 | fix | HIGH |\n'
  } > "$d/$fname"
  printf '%s' "$d/$fname"
}

echo "== stage-retro-issues.test.sh =="

# ---------------------------------------------------------------------------
# 1 — ABSENT-INPUT: retro file not found → typed absent-input message, exit 1
box="$(mkbox case-absent)"
run "$box" "$box/rh/target-foo/retros/does-not-exist.md"
if [ "$RC" = 1 ] && grep -qi 'absent-input' <<<"$OUT"; then
  ok "1 absent-input: missing retro → exit 1 + absent-input message" "(exit $RC)"
else
  no "1 absent-input: missing retro → exit 1 + absent-input message" "exit=$RC out=[$OUT]"
fi

# ---------------------------------------------------------------------------
# 2 — EMPTY-INPUT: retro has no delta section → typed empty-input, exit 0
box="$(mkbox case-empty)"
retro="$(mk_retro "$box" target-foo r-empty.md "<!-- review-status: pending -->" "-")"
run "$box" "$retro"
if [ "$RC" = 0 ] && grep -qi 'empty-input' <<<"$OUT"; then
  ok "2 empty-input: no delta section → exit 0 + empty-input message" "(exit $RC)"
else
  no "2 empty-input: no delta section → exit 0 + empty-input message" "exit=$RC out=[$OUT]"
fi

# ---------------------------------------------------------------------------
# 3 — NO-MATCH: all rows shipped/applied → typed no-match, exit 0
box="$(mkbox case-nomatc)"
retro="$(mk_retro "$box" target-foo r-applied.md \
  "<!-- review-status: applied 2026-01-01 · kit abc1234 -->" \
  "| 1 | fix the thing | METHODOLOGY.md | B42 | new | HIGH |")"
run "$box" "$retro"
if [ "$RC" = 0 ] && grep -qi 'no-match\|all.*shipped\|no open' <<<"$OUT"; then
  ok "3 no-match: applied retro → exit 0 + no-match message" "(exit $RC)"
else
  no "3 no-match: applied retro → exit 0 + no-match message" "exit=$RC out=[$OUT]"
fi

# ---------------------------------------------------------------------------
# 4 — PENDING RETRO DRY-RUN: pending marker, 2 rows → 2 planned issues printed
box="$(mkbox case-pending)"
retro="$(mk_retro "$box" target-foo r-pending.md \
  "<!-- review-status: pending -->" \
  "$(printf '| 1 | Add session cost instrument | CLAUDE.md §5 | B10 | new | HIGH |\n| 2 | Fix anti-silent-zero in sweep | sweep-retros.sh | B20 | fix | LOW |')")"
run "$box" "$retro"
issue_count="$(grep -c 'planned-issue:' <<<"$OUT" || true)"
if [ "$RC" = 0 ] \
   && [ "$issue_count" -ge 2 ] \
   && grep -q 'status:needs-review' <<<"$OUT" \
   && grep -q 'target:target-foo' <<<"$OUT" \
   && grep -q 'Source retro:.*r-pending\.md.*·.*1' <<<"$OUT"; then
  ok "4 pending retro dry-run → 2 planned issues, correct labels + source line" "(exit $RC)"
else
  no "4 pending retro dry-run → 2 planned issues, correct labels + source line" \
    "exit=$RC issues=$issue_count out=[$OUT]"
fi

# ---------------------------------------------------------------------------
# 5 — PARTIAL MARKER: only NON-shipped rows are open
#   Marker: applied · sha · PARTIAL — shipped: 1; deferred: 2
#   Row 1 is shipped → skip. Row 2 is deferred (not shipped) → open.
box="$(mkbox case-partial)"
retro="$(mk_retro "$box" target-foo r-partial.md \
  "<!-- review-status: applied 2026-06-01 · kit deadbeef · PARTIAL — shipped: 1; deferred: 2 -->" \
  "$(printf '| 1 | shipped delta | METHODOLOGY.md | B1 | new | HIGH |\n| 2 | deferred delta | CLAUDE.md | B2 | new | MEDIUM |')")"
run "$box" "$retro"
row2_found=0; row1_found=0
grep -q '· 2' <<<"$OUT" && row2_found=1
grep -q '· 1' <<<"$OUT" && row1_found=1
if [ "$RC" = 0 ] && [ "$row2_found" = 1 ] && [ "$row1_found" = 0 ]; then
  ok "5 partial marker: only deferred row 2 emitted, shipped row 1 skipped" "(exit $RC)"
else
  no "5 partial marker: only deferred row 2 emitted, shipped row 1 skipped" \
    "exit=$RC row1=$row1_found row2=$row2_found out=[$OUT]"
fi

# ---------------------------------------------------------------------------
# 6 — WRONG-KIT ROW: row whose Target cell names another kit → skipped-wrong-kit
box="$(mkbox case-wrongkit)"
retro="$(mk_retro "$box" target-foo r-wrongkit.md \
  "<!-- review-status: pending -->" \
  "$(printf '| 1 | normal delta | CLAUDE.md §7 | B1 | new | HIGH |\n| 2 | wrong kit delta | build-n4-module-kit: METHODOLOGY.md §3 | B2 | new | LOW |')")"
run "$box" "$retro"
wrong_skipped=0; normal_found=0
grep -qi 'skipped-wrong-kit\|wrong.kit' <<<"$OUT" && wrong_skipped=1
grep -q '· 1' <<<"$OUT" && normal_found=1
if [ "$RC" = 0 ] && [ "$wrong_skipped" = 1 ] && [ "$normal_found" = 1 ]; then
  ok "6 wrong-kit row: skipped with report, normal row still planned" "(exit $RC)"
else
  no "6 wrong-kit row: skipped with report, normal row still planned" \
    "exit=$RC wrong_skipped=$wrong_skipped normal=$normal_found out=[$OUT]"
fi

# ---------------------------------------------------------------------------
# 7 — NO-PRIORITY ROW: row with "—" in priority column → priority label omitted
box="$(mkbox case-noprio)"
retro="$(mk_retro "$box" target-foo r-noprio.md \
  "<!-- review-status: pending -->" \
  "| 1 | delta with no priority | METHODOLOGY.md | B1 | new | — |")"
run "$box" "$retro"
has_label=0; has_noprio_signal=0
grep -q 'priority:' <<<"$OUT" && has_label=1
grep -q 'status:needs-review' <<<"$OUT" && has_noprio_signal=1
if [ "$RC" = 0 ] && [ "$has_label" = 0 ] && [ "$has_noprio_signal" = 1 ]; then
  ok "7 no-priority row: priority label omitted, other labels present" "(exit $RC)"
else
  no "7 no-priority row: priority label omitted, other labels present" \
    "exit=$RC has_priority_label=$has_label has_needs_review=$has_noprio_signal out=[$OUT]"
fi

# ---------------------------------------------------------------------------
# 8 — APPLY MODE CREATES ISSUE: --apply with nomatch stub → gh issue create called
box="$(mkbox case-apply-create)"
mk_gh_stub "$box" nomatch
retro="$(mk_retro "$box" target-foo r-apply.md \
  "<!-- review-status: pending -->" \
  "| 1 | create this issue | CLAUDE.md §7 | B1 | new | HIGH |")"
run "$box" "$retro" --apply
# Expect gh issue create to have been called
create_called=0
[ -f "$box/bin/gh.log" ] && grep -q 'issue create' "$box/bin/gh.log" && create_called=1
if [ "$RC" = 0 ] && [ "$create_called" = 1 ]; then
  ok "8 --apply nomatch: gh issue create called" "(exit $RC)"
else
  no "8 --apply nomatch: gh issue create called" "exit=$RC create_called=$create_called out=[$OUT]"
fi

# ---------------------------------------------------------------------------
# 9 — APPLY MODE DEDUP: --apply with match stub → issue creation skipped
box="$(mkbox case-apply-dedup)"
mk_gh_stub "$box" match
retro="$(mk_retro "$box" target-foo r-dedup.md \
  "<!-- review-status: pending -->" \
  "| 1 | existing issue | CLAUDE.md §7 | B1 | new | HIGH |")"
run "$box" "$retro" --apply
# Expect creation NOT called, but skipped-duplicate reported
create_called=0
[ -f "$box/bin/gh.log" ] && grep -q 'issue create' "$box/bin/gh.log" && create_called=1
dup_reported=0
grep -qi 'skipped-duplicate\|already.*exists\|dedup' <<<"$OUT" && dup_reported=1
if [ "$RC" = 0 ] && [ "$create_called" = 0 ] && [ "$dup_reported" = 1 ]; then
  ok "9 --apply match: dedup skips create, reports skipped-duplicate" "(exit $RC)"
else
  no "9 --apply match: dedup skips create, reports skipped-duplicate" \
    "exit=$RC create_called=$create_called dup_reported=$dup_reported out=[$OUT]"
fi

# ---------------------------------------------------------------------------
# 9b — APPLY MODE DEDUP COVERS CLOSED ISSUES (kit issue #949 item 2): a CLOSED
# match must ALSO suppress create — the pre-fix dedup only searched --state open, so a
# false issue that got manually closed was silently re-seeded on the next --apply.
box="$(mkbox case-apply-dedup-closed)"
mk_gh_stub "$box" matchclosed
retro="$(mk_retro "$box" target-foo r-dedup-closed.md \
  "<!-- review-status: pending -->" \
  "| 1 | existing closed issue | CLAUDE.md §7 | B1 | new | HIGH |")"
run "$box" "$retro" --apply
create_called=0
[ -f "$box/bin/gh.log" ] && grep -q 'issue create' "$box/bin/gh.log" && create_called=1
closed_reported=0
grep -qi 'skipped-duplicate.*closed' <<<"$OUT" && closed_reported=1
if [ "$RC" = 0 ] && [ "$create_called" = 0 ] && [ "$closed_reported" = 1 ]; then
  ok "9b --apply matchclosed: dedup skips create on a CLOSED match, names it closed" "(exit $RC)"
else
  no "9b --apply matchclosed: dedup skips create on a CLOSED match, names it closed" \
    "exit=$RC create_called=$create_called closed_reported=$closed_reported out=[$OUT]"
fi

# ---------------------------------------------------------------------------
# 9c — APPLY MODE DEDUP LIST FAILURE (kit issue #949 item 2): a failed `gh issue list`
# (dedup search) must NOT fall through to create — count it as failed, keep the exit-2
# partial-failure contract, and never silently create a possible duplicate.
box="$(mkbox case-apply-dedup-listfail)"
mk_gh_stub "$box" listfail
retro="$(mk_retro "$box" target-foo r-dedup-listfail.md \
  "<!-- review-status: pending -->" \
  "| 1 | list call fails | CLAUDE.md §7 | B1 | new | HIGH |")"
run "$box" "$retro" --apply
create_called=0
[ -f "$box/bin/gh.log" ] && grep -q 'issue create' "$box/bin/gh.log" && create_called=1
if [ "$RC" = 2 ] && [ "$create_called" = 0 ] \
   && grep -qi 'ERROR.*issue list' <<<"$OUT" \
   && grep -q 'summary:.*failed=1' <<<"$OUT"; then
  ok "9c --apply listfail: dedup list failure counts as failed, never creates, exit 2" "(exit $RC)"
else
  no "9c --apply listfail: dedup list failure counts as failed, never creates, exit 2" \
    "exit=$RC create_called=$create_called out=[$OUT]"
fi

# ---------------------------------------------------------------------------
# 9d — APPLY MODE DEDUP EMPTY REPLY (kit issue #1093 item 1): `gh issue list` exits 0 but its
# stdout is completely EMPTY (not the '[]' a genuinely empty JSON array reply would carry — e.g.
# a transient gh/API hiccup that still exits 0). This must NOT be read as "no match" and fall
# through to create a possible duplicate — it must count as failed, exactly like an explicit
# non-zero exit (case 9c).
box="$(mkbox case-apply-dedup-listempty)"
mk_gh_stub "$box" listempty
retro="$(mk_retro "$box" target-foo r-dedup-listempty.md \
  "<!-- review-status: pending -->" \
  "| 1 | list call returns empty reply | CLAUDE.md §7 | B1 | new | HIGH |")"
run "$box" "$retro" --apply
create_called=0
[ -f "$box/bin/gh.log" ] && grep -q 'issue create' "$box/bin/gh.log" && create_called=1
if [ "$RC" = 2 ] && [ "$create_called" = 0 ] \
   && grep -qi 'ERROR.*issue list' <<<"$OUT" \
   && grep -q 'summary:.*failed=1' <<<"$OUT"; then
  ok "9d --apply listempty: empty gh reply counts as failed, never creates, exit 2 (#1093 item 1)" "(exit $RC)"
else
  no "9d --apply listempty: empty gh reply counts as failed, never creates, exit 2 (#1093 item 1)" \
    "exit=$RC create_called=$create_called out=[$OUT]"
fi

# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# 9e — EXACT-SIGNATURE DEDUP (kit issue #1304 item 1). GitHub's phrase search is a fuzzy WORD
# match: it returns other targets' issues and other rows' issues for the same signature text. A
# hit only counts as a duplicate when its BODY carries the exact `Source retro: … · <id>` line.
#   created = a `gh issue create` was issued; skipped = reported skipped-duplicate, no create;
#   failed  = no create, failed=1 in the summary, exit 2.
# dedup_case <label> <stub-mode> <expect>
dedup_case() {
  local label="$1" mode="$2" expect="$3" b r created=0 skipped=0 failed1=0 got=none
  b="$(mkbox "case-exact-$mode")"
  mk_gh_stub "$b" "$mode"
  r="$(mk_retro "$b" target-foo "r-exact-$mode.md" "<!-- review-status: pending -->" \
    "| 3 | exact dedup delta | CLAUDE.md §7 | B1 | new | HIGH |")"
  run "$b" "$r" --apply
  [ -f "$b/bin/gh.log" ] && grep -q 'issue create' "$b/bin/gh.log" && created=1
  grep -q '^skipped-duplicate:' <<<"$OUT" && skipped=1
  grep -q 'failed=1' <<<"$OUT" && failed1=1
  if [ "$created" = 1 ]; then got=created
  elif [ "$skipped" = 1 ]; then got=skipped
  elif [ "$failed1" = 1 ]; then got=failed; fi
  if [ "$got" = "$expect" ]; then ok "$label" "(exit $RC, $got)"
  else no "$label" "expected $expect, got $got (exit $RC) out=[$OUT]"; fi
}
dedup_case "9e-1 fuzzy hit on ANOTHER target's OPEN issue → not a duplicate, row is created" fuzzyother created
dedup_case "9e-2 fuzzy hit on another target's CLOSED issue → not a duplicate, row is created" fuzzyotherclosed created
dedup_case "9e-3 fuzzy hit on the same retro's row 30 when asked for row 3 → created" fuzzylongid created
dedup_case "9e-4 fuzzy false hit AND the exact hit in one reply (exact last) → skipped" fuzzyplusexact skipped
dedup_case "9e-5 exact signature line with a trailing CR → still the exact match, skipped" crlfsig skipped
dedup_case "9e-6 LIST EDGE: body is the signature alone, state key before body → skipped" sigonly skipped
dedup_case "9e-7 hit with a null body can never be an exact match → created" nullbody created
dedup_case "9e-8 reply cut off mid-string (unparseable) → failed, never created" badjson failed
dedup_case "9e-9 exact hit, OPEN (regression pin for the exact path) → skipped" match skipped

# 10 — DEGRADED on missing gh under --apply (hermetic PATH: no gh available)
box="$(mkbox case-degraded)"
mk_hermetic_bin "$box"   # essentials only, NO gh
_deg_retro="$(mk_retro "$box" target-foo r-deg.md "<!-- review-status: pending -->" \
  "| 1 | d fixture row | CLAUDE.md | B1 | new | HIGH |")"
# Run with a FULLY hermetic PATH so no system gh can be found
OUT10="$(PATH="$box/bin" \
  "$BASH_BIN" "$box/research-sdd/toolbelt/stage-retro-issues.sh" \
  "$_deg_retro" --apply 2>&1)"; RC10=$?
if [ "$RC10" != 0 ] && grep -qi 'degraded' <<<"$OUT10"; then
  ok "10 degraded: missing gh under --apply → non-zero + degraded message" "(exit $RC10)"
else
  no "10 degraded: missing gh under --apply → non-zero + degraded message" \
    "exit=$RC10 out=[$OUT10]"
fi

# ---------------------------------------------------------------------------
# 11 — SOURCE RETRO LINE: body contains 'Source retro: ...' + 'rollout #557'
box="$(mkbox case-srcline)"
retro="$(mk_retro "$box" target-foo r-src.md \
  "<!-- review-status: pending -->" \
  "| 1 | delta text fixture row | CLAUDE.md §7 | B1 | new | MEDIUM |")"
run "$box" "$retro"
has_src=0; has_rollout=0
grep -q 'Source retro:.*r-src\.md.*·.*1' <<<"$OUT" && has_src=1
grep -q 'rollout #557' <<<"$OUT" && has_rollout=1
if [ "$RC" = 0 ] && [ "$has_src" = 1 ] && [ "$has_rollout" = 1 ]; then
  ok "11 source retro line: body has Source retro + rollout #557" "(exit $RC)"
else
  no "11 source retro line: body has Source retro + rollout #557" \
    "exit=$RC src=$has_src rollout=$has_rollout out=[$OUT]"
fi

# ---------------------------------------------------------------------------
# 12 — TYPE LABEL MAPPING: new→feature, fix→bug, doc→docs
box="$(mkbox case-types)"
retro="$(mk_retro "$box" target-foo r-types.md \
  "<!-- review-status: pending -->" \
  "$(printf '| 1 | feature delta | CLAUDE.md | B1 | new | HIGH |\n| 2 | bug delta fixture row | CLAUDE.md | B2 | fix | HIGH |\n| 3 | doc delta fixture row | CLAUDE.md | B3 | docs | HIGH |')")"
run "$box" "$retro"
feat_found=0; bug_found=0; docs_found=0
grep -q 'type:feature' <<<"$OUT" && feat_found=1
grep -q 'type:bug' <<<"$OUT"     && bug_found=1
grep -q 'type:docs' <<<"$OUT"    && docs_found=1
if [ "$RC" = 0 ] && [ "$feat_found" = 1 ] && [ "$bug_found" = 1 ] && [ "$docs_found" = 1 ]; then
  ok "12 type label mapping: new→feature, fix→bug, docs→docs" "(exit $RC)"
else
  no "12 type label mapping: new→feature, fix→bug, docs→docs" \
    "exit=$RC feat=$feat_found bug=$bug_found docs=$docs_found out=[$OUT]"
fi

# ---------------------------------------------------------------------------
# 13 — DEPRECATED ALIAS HEADING: deprecated alias still surfaces open rows
# The retro-grammar lib accepts "## Summary of proposed deltas" as a deprecated alias
box="$(mkbox case-depr)"
cat > "$box/rh/target-foo/retros/r-depr.md" <<'EOF'
<!-- review-status: pending -->
# retro

## Summary of proposed deltas

| # | Proposed change | Target (file) | Evidence | Type | Priority |
|---|---|---|---|---|---|
| 1 | delta from deprecated heading | CLAUDE.md §3 | B1 | new | LOW |
EOF
run "$box" "$box/rh/target-foo/retros/r-depr.md"
if [ "$RC" = 0 ] && grep -q 'planned-issue:' <<<"$OUT"; then
  ok "13 deprecated alias heading: rows extracted from Summary of proposed deltas" "(exit $RC)"
else
  no "13 deprecated alias heading: rows extracted from Summary of proposed deltas" "exit=$RC out=[$OUT]"
fi

# ---------------------------------------------------------------------------
# 14 — BOLD LEAD-IN TITLE: cell opens with **phrase.** detail → title is phrase only
# The bug: strip_md_bold stripped the opening ** but left the closing ** in the
# middle, producing "phrase.** detail..." in the title.  After the fix, the title
# must be the bolded phrase only, with no stray **.
box="$(mkbox case-bold-lead)"
retro="$(mk_retro "$box" target-foo r-bold.md \
  "<!-- review-status: pending -->" \
  "| 1 | **Bold summary sentence.** Detail text explaining the change. | CLAUDE.md | B1 | new | HIGH |")"
run "$box" "$retro"
title_line14="$(grep '^planned-issue:' <<<"$OUT")"
bold_title_ok=0
if grep -q 'Bold summary sentence\.' <<<"$title_line14" \
   && ! grep -q '\*\*' <<<"$title_line14"; then
  bold_title_ok=1
fi
if [ "$RC" = 0 ] && [ "$bold_title_ok" = 1 ]; then
  ok "14 bold lead-in title: bolded phrase used as title, no stray **" "(exit $RC)"
else
  no "14 bold lead-in title: bolded phrase used as title, no stray **" \
    "exit=$RC bold_ok=$bold_title_ok title=[$title_line14]"
fi

# ---------------------------------------------------------------------------
# 15 — PLAIN CELL REGRESSION: cell with no bold markers → title unchanged
# Ensures the bold-lead fix does not alter plain (non-bold) delta cells.
box="$(mkbox case-plain-title)"
retro="$(mk_retro "$box" target-foo r-plain.md \
  "<!-- review-status: pending -->" \
  "| 1 | Plain text delta without bold markers here. | CLAUDE.md | B1 | new | HIGH |")"
run "$box" "$retro"
title_line15="$(grep '^planned-issue:' <<<"$OUT")"
plain_title_ok=0
if grep -q 'Plain text delta without bold markers here\.' <<<"$title_line15"; then
  plain_title_ok=1
fi
if [ "$RC" = 0 ] && [ "$plain_title_ok" = 1 ]; then
  ok "15 plain cell regression: plain cell title unchanged by bold-lead fix" "(exit $RC)"
else
  no "15 plain cell regression: plain cell title unchanged by bold-lead fix" \
    "exit=$RC plain_ok=$plain_title_ok title=[$title_line15]"
fi

# ---------------------------------------------------------------------------
# TEETH (negative controls for --prove-teeth)
# ---------------------------------------------------------------------------
# Two open rows (kit issue #1332): used by the label-probe cases (76*) and their teeth.
TWO_ROWS='| 1 | first delta fixture row | CLAUDE.md | B1 | fix | HIGH |
| 2 | second delta | CLAUDE.md | B2 | fix | HIGH |'
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: mutation controls --"

  sut_content="$(cat "$SUT")"

  # TOOTH 1: Neuter the no-match early-exit guard for applied/dismissed retros.
  # The anchor is the compound statement that prints "no-match" and exits 0 for
  # fully applied/dismissed retros. Neutering it allows rows to appear because the
  # row loop only skips shipped rows (is_partial=0 → nothing skipped there either).
  echo "-- teeth T1: neuter applied no-match early exit --"
  anchor_t1='[ $is_partial -eq 0 ] && { echo "no-match: retro is '"'"'applied'"'"' — all rows shipped" >&2; exit 0; }'
  if [[ "$sut_content" == *"$anchor_t1"* ]]; then
    box_t1="$(mkbox teeth-applied)"
    retro_t1="$(mk_retro "$box_t1" target-foo r.md \
      "<!-- review-status: applied 2026-01-01 · kit abc1234 -->" \
      "| 1 | should appear when guard removed | CLAUDE.md | B1 | new | HIGH |")"
    mutant_t1="$box_t1/research-sdd/toolbelt/stage-retro-issues.sh"
    # Replace the guard with a no-op: rows now reach the loop (is_partial=0 skips nothing)
    printf '%s\n' "${sut_content/"$anchor_t1"/: # teeth-t1-nomatch-guard-removed}" > "$mutant_t1"
    out_t1="$(PATH="$box_t1/bin:$PATH" \
      "$BASH_BIN" "$mutant_t1" "$retro_t1" 2>&1)"; rc_t1=$?
    if grep -q 'planned-issue:' <<<"$out_t1"; then
      ok "T1 teeth: no-match guard neutered → rows appear for applied retro (case 3 has teeth)" "()"
    else
      no "T1 teeth: no-match guard neutered → rows appear for applied retro" \
        "mutant did not emit planned-issue — case 3 is THEATER: rc=$rc_t1 out=[$out_t1]"
    fi
  else
    no "T1 teeth: locate no-match guard anchor" "anchor not found in SUT — SUT drifted?"
  fi

  # TOOTH 2: Neuter is_wrong_kit body → wrong-kit row is planned instead of skipped.
  # The anchor is the grep pattern inside is_wrong_kit that detects another-kit target cells.
  echo "-- teeth T2: neuter is_wrong_kit detection --"
  anchor_t2="  grep -qiE '[-a-zA-Z0-9]+-kit[:/]' <<<\"\$1\""
  if [[ "$sut_content" == *"$anchor_t2"* ]]; then
    box_t2="$(mkbox teeth-wrongkit)"
    retro_t2="$(mk_retro "$box_t2" target-foo r.md \
      "<!-- review-status: pending -->" \
      "| 1 | wrong kit delta | build-n4-module-kit: METHODOLOGY.md §3 | B1 | new | HIGH |")"
    mutant_t2="$box_t2/research-sdd/toolbelt/stage-retro-issues.sh"
    # Replace the grep inside is_wrong_kit with one that never matches → function always returns 1
    printf '%s\n' "${sut_content/"$anchor_t2"/  false}" > "$mutant_t2"
    out_t2="$(PATH="$box_t2/bin:$PATH" \
      "$BASH_BIN" "$mutant_t2" "$retro_t2" 2>&1)"; rc_t2=$?
    if grep -q 'planned-issue:' <<<"$out_t2"; then
      ok "T2 teeth: is_wrong_kit neutered → wrong-kit row planned (case 6 has teeth)" "()"
    else
      no "T2 teeth: is_wrong_kit neutered → wrong-kit row planned" \
        "row not in output — case 6 is THEATER: rc=$rc_t2 out=[$out_t2]"
    fi
  else
    no "T2 teeth: locate is_wrong_kit grep anchor" "anchor not found in SUT — SUT drifted?"
  fi

  # TOOTH 3: Neuter the dedup check → gh issue create is called even when a match exists.
  # The anchor is the comment + condition line that guards creation on a found duplicate.
  echo "-- teeth T3: neuter dedup OPEN-match check condition --"
  anchor_t3='    if grep -q '"'"'"state":[[:space:]]*"OPEN"'"'"' <<<"$_existing"; then'
  if [[ "$sut_content" == *"$anchor_t3"* ]]; then
    box_t3="$(mkbox teeth-dedup)"
    mk_gh_stub "$box_t3" match
    retro_t3="$(mk_retro "$box_t3" target-foo r.md \
      "<!-- review-status: pending -->" \
      "| 1 | existing delta | CLAUDE.md | B1 | new | HIGH |")"
    mutant_t3="$box_t3/research-sdd/toolbelt/stage-retro-issues.sh"
    reverted_t3='    if false; then  # teeth-t3-open-match-check-removed'
    printf '%s\n' "${sut_content/"$anchor_t3"/"$reverted_t3"}" > "$mutant_t3"
    bash -n "$mutant_t3" 2>/dev/null || { no "T3 teeth: mutant_t3 failed bash -n syntax check" ""; }
    out_t3="$(PATH="$box_t3/bin:$PATH" RESEARCH_SDD_ISSUE_REPO="test-owner/test-kit" \
      "$BASH_BIN" "$mutant_t3" "$retro_t3" --apply 2>&1)"; rc_t3=$?
    create_called_t3=0
    [ -f "$box_t3/bin/gh.log" ] && grep -q 'issue create' "$box_t3/bin/gh.log" \
      && create_called_t3=1
    if [ "$create_called_t3" = 1 ]; then
      ok "T3 teeth: dedup OPEN-match guard neutered → create called despite match (case 9 has teeth)" "()"
    else
      no "T3 teeth: dedup OPEN-match guard neutered → create called despite match" \
        "create not called — case 9 is THEATER: rc=$rc_t3 out=[$out_t3]"
    fi
  else
    no "T3 teeth: locate dedup OPEN-match check anchor" "anchor comment not found in SUT — SUT drifted?"
  fi

  # TOOTH 4: Replace the strip_md_bold CALL SITE with a raw _delta assignment.
  # Anchor: the call-site line that invokes strip_md_bold.  For a bold-lead-in
  # cell, skipping strip_md_bold leaves ** markers in the raw _delta → stray **.
  # The STAGE_RETRO_ISSUES_BOLD_LEAD sentinel in the SUT confirms this version.
  echo "-- teeth T4: skip strip_md_bold call → raw delta used as title --"
  anchor_t4='  _title_raw="$(strip_md_bold "$_delta")"'
  if [[ "$sut_content" == *"$anchor_t4"* ]]; then
    box_t4="$(mkbox teeth-bold)"
    retro_t4="$(mk_retro "$box_t4" target-foo r.md \
      "<!-- review-status: pending -->" \
      "| 1 | **Bold summary sentence.** Detail text explaining the change here. | CLAUDE.md | B1 | new | HIGH |")"
    mutant_t4="$box_t4/research-sdd/toolbelt/stage-retro-issues.sh"
    # Replace the call site so _title gets the raw _delta (bold markers intact).
    printf '%s\n' "${sut_content/"$anchor_t4"/  _title_raw=\"\$_delta\"  # T4-teeth: raw delta}" \
      > "$mutant_t4"
    out_t4="$(PATH="$box_t4/bin:$PATH" \
      "$BASH_BIN" "$mutant_t4" "$retro_t4" 2>&1)"; rc_t4=$?
    title_t4="$(grep '^planned-issue:' <<<"$out_t4")"
    if grep -q '\*\*' <<<"$title_t4"; then
      ok "T4 teeth: strip_md_bold skipped → raw ** in title (cases 14+15 have teeth)" "()"
    else
      no "T4 teeth: strip_md_bold skipped → raw ** expected in title" \
        "no ** found — cases 14+15 are THEATER: rc=$rc_t4 title=[$title_t4]"
    fi
  else
    no "T4 teeth: locate strip_md_bold call-site anchor" \
      "anchor not found in SUT — SUT drifted?"
  fi

  # TOOTH 5: Remove the `failed=$((failed+1))` increment → failed stays 0 → summary shows failed=0
  # and the process exits 0 even when creates fail.
  # Uses sed on a COPY to avoid bash variable-expansion issues in the anchor string.
  # Anchor: the literal text 'failed=$((failed+1)); continue' on its own line in the SUT.
  echo "-- teeth T5: remove failed counter increment; summary must show failed=0, exit 0 (case 16 has teeth) --"
  if grep -qF 'failed=$((failed+1)); continue' "$SUT" 2>/dev/null; then
    box_t5="$(mkbox teeth-failed)"
    mk_gh_stub "$box_t5" createfail
    retro_t5="$(mk_retro "$box_t5" target-foo r.md \
      "<!-- review-status: pending -->" \
      "| 1 | fail delta fixture row | CLAUDE.md | B1 | new | HIGH |")"
    mutant_t5="$box_t5/research-sdd/toolbelt/stage-retro-issues.sh"
    # Remove the increment, keeping only 'continue'; sed replaces the whole token-containing line.
    sed 's/failed=\$((failed+1)); continue/continue  # T5-teeth-no-increment/' \
      "$SUT" > "$mutant_t5"
    bash -n "$mutant_t5" 2>/dev/null || { no "T5 teeth: mutant_t5 failed bash -n syntax check" ""; }
    out_t5="$(PATH="$box_t5/bin:$PATH" RESEARCH_SDD_ISSUE_REPO="test-owner/test-kit" \
      "$BASH_BIN" "$mutant_t5" "$retro_t5" --apply 2>&1)"; rc_t5=$?
    sum_t5="$(grep '^summary:' <<<"$out_t5")"
    # With the counter removed: failed=0, exit 0 → case 16's assertion (rc_nonzero=1, failed>0) goes RED
    if [ "$rc_t5" -eq 0 ] || grep -qE 'failed=0\b' <<<"$sum_t5"; then
      ok "T5 teeth: failed counter removed → failed=0 / exit 0 (case 16 has teeth)" "(rc=$rc_t5 sum=[$sum_t5])"
    else
      no "T5 teeth: failed counter removed → should give failed=0 or exit 0" \
        "rc=$rc_t5 sum=[$sum_t5] — case 16 is THEATER"
    fi
  else
    no "T5 teeth: locate 'failed=\$((failed+1)); continue' in SUT" "line not found — SUT drifted?"
  fi

  # TOOTH 6 (kit issue #1090): neuter the 'dismissed always wins' guard so a dismissed
  # marker falls through to the is_partial check like 'applied' does. Paired with a marker
  # whose structured segment DOES carry the PARTIAL token (contrived, but exactly what the
  # guard must defend against even so — see the header comment), removing the dedicated
  # dismissed branch reopens rows instead of yielding no-match.
  echo "-- teeth T6: neuter 'dismissed always wins' guard; dismissed+PARTIAL must reopen rows (case 50/51 have teeth) --"
  anchor_t6='  dismissed)
    echo "no-match: retro is '"'"'dismissed'"'"' — all rows shipped" >&2
    echo "unclassifiable-items: 0 (retro-closed: dismissed)"; exit 0
    ;;'
  if [[ "$sut_content" == *"$anchor_t6"* ]]; then
    box_t6="$(mkbox teeth-dismissed-wins)"
    retro_t6="$(mk_retro "$box_t6" target-foo r-t6.md \
      "<!-- review-status: dismissed 2026-09-20 · kit deadbeef · PARTIAL — shipped: 99 -->" \
      "| 1 | should stay closed unless guard removed | CLAUDE.md | B1 | new | HIGH |")"
    mutant_t6="$box_t6/research-sdd/toolbelt/stage-retro-issues.sh"
    # Fold 'dismissed' into the 'applied'-style is_partial-gated branch, exactly the pre-#1090
    # shape: dismissed no longer wins unconditionally.
    reverted_t6='  dismissed)
    [ $is_partial -eq 0 ] && { echo "no-match: retro is '"'"'dismissed'"'"' — all rows shipped" >&2; exit 0; }
    ;;'
    printf '%s\n' "${sut_content/"$anchor_t6"/"$reverted_t6"}" > "$mutant_t6"
    bash -n "$mutant_t6" 2>/dev/null || { no "T6 teeth: mutant_t6 failed bash -n" ""; }
    out_t6="$(PATH="$box_t6/bin:$PATH" \
      "$BASH_BIN" "$mutant_t6" "$retro_t6" 2>&1)"; rc_t6=$?
    if grep -q 'planned-issue:' <<<"$out_t6"; then
      ok "T6 teeth: dismissed-wins guard neutered → dismissed+PARTIAL reopens rows (case 50/51 have teeth)" "()"
    else
      no "T6 teeth: dismissed-wins guard neutered → should reopen rows" \
        "no planned-issue — case 50/51 is THEATER: rc=$rc_t6 out=[$out_t6]"
    fi
  else
    no "T6 teeth: locate 'dismissed always wins' guard anchor" "anchor not found — SUT drifted?"
  fi

  # TOOTH SYMLINK-TOOLBELT: revert -P/pwd -P to plain cd/pwd (kit issue #1024 round 3, MEDIUM).
  echo "-- teeth SYMLINK-TOOLBELT: revert -P to plain cd/pwd --"
  box_tsym="$(mkbox teeth-symlink-toolbelt)"
  retro_tsym="$(mk_retro "$box_tsym" target-foo r-tsym.md - "| 1 | do a thing fixture row | some/file | cite | fix | P2 |")"
  mutant_tsym="$box_tsym/research-sdd/toolbelt/stage-retro-issues.sh"
  sed -e 's/\(_RSDD_SELF="\$(CDPATH=[^ ]* cd -- "\$(dirname -- "\$_rsdd_s")" && pwd\) -P)"/\1)"/' \
      -e 's/cd -P "\$_SCRIPT_DIR\/\.\.\/\.\." \&\& pwd -P/cd "$_SCRIPT_DIR\/..\/.." \&\& pwd/' \
      "$SUT" > "$mutant_tsym"
  if diff -q "$SUT" "$mutant_tsym" >/dev/null 2>&1; then
    no "teeth SYMLINK-TOOLBELT pre-check: mutant = SUT — -P pattern not found"
  else
    ok "teeth SYMLINK-TOOLBELT pre-check: mutant differs (-P reverted to plain cd/pwd)"
  fi
  mkdir -p "$box_tsym/research-sdd/profile/general"
  ln -s "$box_tsym/research-sdd/toolbelt" "$box_tsym/research-sdd/profile/general/toolbelt"
  out_tsym="$(PATH="$box_tsym/bin:$PATH" "$BASH_BIN" \
    "$box_tsym/research-sdd/profile/general/toolbelt/stage-retro-issues.sh" "$retro_tsym" 2>&1)"
  # Since kit issue #1287 an unreadable TARGETS.md is an operational exit 1 ("cannot read" / "cannot
  # resolve target"), no longer the old WARN + basename guess — either signal proves the break.
  if grep -qiE 'target directory.*not found|cannot read|cannot resolve target' <<<"$out_tsym"; then
    ok "teeth SYMLINK-TOOLBELT: reverted mutant re-breaks through a symlinked toolbelt/ → -P fix has teeth"
  else
    no "teeth SYMLINK-TOOLBELT: reverted mutant still resolved TARGETS.md — -P fix check is THEATER" \
       "(out=[$out_tsym])"
  fi

  # TOOTH 7 (kit issue #1037): drop --repo from the gh issue create call site.
  # Anchor: the literal call-site text that puts --repo right after "issue create".
  echo "-- teeth T7: drop --repo from gh issue create call --"
  anchor_t7='gh issue create --repo "$KIT_ISSUE_REPO" \'
  if [[ "$sut_content" == *"$anchor_t7"* ]]; then
    box_t7="$(mkbox teeth-t7-create-repo)"
    mk_git_remote "$box_t7" "https://github.com/kit-owner/kit-repo.git"
    mk_gh_stub "$box_t7" nomatch
    retro_t7="$(mk_retro "$box_t7" target-foo r.md \
      "<!-- review-status: pending -->" \
      "| 1 | t7 delta fixture row | CLAUDE.md | B1 | new | HIGH |")"
    mutant_t7="$box_t7/research-sdd/toolbelt/stage-retro-issues.sh"
    printf '%s\n' "${sut_content/"$anchor_t7"/gh issue create \\}" > "$mutant_t7"
    bash -n "$mutant_t7" 2>/dev/null || { no "T7 teeth: mutant_t7 failed bash -n syntax check" ""; }
    out_t7="$(PATH="$box_t7/bin:$PATH" \
      "$BASH_BIN" "$mutant_t7" "$retro_t7" --apply 2>&1)"; rc_t7=$?
    create_line_t7="$(grep 'issue create' "$box_t7/bin/gh.log" 2>/dev/null || true)"
    if [ -n "$create_line_t7" ] && ! grep -q -- '--repo' <<<"$create_line_t7"; then
      ok "T7 teeth: --repo dropped from create call → flag missing (case 19/20 have teeth)" "()"
    else
      no "T7 teeth: --repo dropped from create call → flag should be missing" \
        "still present or create not called — case 19/20 are THEATER: rc=$rc_t7 line=[$create_line_t7] out=[$out_t7]"
    fi
  else
    no "T7 teeth: locate gh issue create --repo anchor" "anchor not found in SUT — SUT drifted?"
  fi

  # TOOTH 8 (kit issue #1037): drop --repo from the gh issue list (dedup) call site.
  echo "-- teeth T8: drop --repo from gh issue list call --"
  anchor_t8='gh issue list --repo "$KIT_ISSUE_REPO" --state all \'
  if [[ "$sut_content" == *"$anchor_t8"* ]]; then
    box_t8="$(mkbox teeth-t8-list-repo)"
    mk_git_remote "$box_t8" "https://github.com/kit-owner/kit-repo.git"
    mk_gh_stub "$box_t8" nomatch
    retro_t8="$(mk_retro "$box_t8" target-foo r.md \
      "<!-- review-status: pending -->" \
      "| 1 | t8 delta fixture row | CLAUDE.md | B1 | new | HIGH |")"
    mutant_t8="$box_t8/research-sdd/toolbelt/stage-retro-issues.sh"
    printf '%s\n' "${sut_content/"$anchor_t8"/gh issue list --state all \\}" > "$mutant_t8"
    bash -n "$mutant_t8" 2>/dev/null || { no "T8 teeth: mutant_t8 failed bash -n syntax check" ""; }
    out_t8="$(PATH="$box_t8/bin:$PATH" \
      "$BASH_BIN" "$mutant_t8" "$retro_t8" --apply 2>&1)"; rc_t8=$?
    list_line_t8="$(grep 'issue list' "$box_t8/bin/gh.log" 2>/dev/null | grep -v 'number,state,title' || true)"
    if [ -n "$list_line_t8" ] && ! grep -q -- '--repo' <<<"$list_line_t8"; then
      ok "T8 teeth: --repo dropped from list call → flag missing (case 19 has teeth)" "()"
    else
      no "T8 teeth: --repo dropped from list call → flag should be missing" \
        "still present or list not called — case 19 is THEATER: rc=$rc_t8 line=[$list_line_t8] out=[$out_t8]"
    fi
  else
    no "T8 teeth: locate gh issue list --repo anchor" "anchor not found in SUT — SUT drifted?"
  fi

  # TOOTH 9 (kit issue #1037): neuter the unresolved-repo degraded/exit guard so an
  # unresolvable repo falls back SILENTLY under --apply instead of refusing.
  echo "-- teeth T9: neuter unresolved-repo degraded/exit guard under --apply --"
  anchor_t9='if [ $apply -eq 1 ] && [ -z "$KIT_ISSUE_REPO" ]; then'
  if [[ "$sut_content" == *"$anchor_t9"* ]]; then
    box_t9="$(mkbox teeth-t9-unresolved-guard)"
    mk_gh_stub "$box_t9" nomatch
    retro_t9="$(mk_retro "$box_t9" target-foo r.md \
      "<!-- review-status: pending -->" \
      "| 1 | t9 delta fixture row | CLAUDE.md | B1 | new | HIGH |")"
    mutant_t9="$box_t9/research-sdd/toolbelt/stage-retro-issues.sh"
    printf '%s\n' "${sut_content/"$anchor_t9"/if false; then}" > "$mutant_t9"
    bash -n "$mutant_t9" 2>/dev/null || { no "T9 teeth: mutant_t9 failed bash -n syntax check" ""; }
    out_t9="$(PATH="$box_t9/bin:$PATH" \
      "$BASH_BIN" "$mutant_t9" "$retro_t9" --apply 2>&1)"; rc_t9=$?
    create_called_t9=0
    [ -f "$box_t9/bin/gh.log" ] && grep -q 'issue create' "$box_t9/bin/gh.log" && create_called_t9=1
    if [ "$create_called_t9" = 1 ]; then
      ok "T9 teeth: unresolved-repo guard neutered → create called with no repo resolved (case 23 has teeth)" "()"
    else
      no "T9 teeth: unresolved-repo guard neutered → create should still be called (silently)" \
        "create not called — case 23 is THEATER: rc=$rc_t9 out=[$out_t9]"
    fi
  else
    no "T9 teeth: locate unresolved-repo guard anchor" "anchor not found in SUT — SUT drifted?"
  fi

  # TOOTH 10 (kit issue #1045 F1): drop the physical toplevel check so an
  # enclosing repo's remote (KIT_ROOT is NOT its own checkout) is accepted.
  echo "-- teeth T10: drop F1 physical-toplevel check --"
  anchor_t10='  if [ "$_top_phys" != "$_kit_phys" ]; then'
  if [[ "$sut_content" == *"$anchor_t10"* ]]; then
    parent_t10="$ROOT/teeth-t10-enclosing-parent"
    mkdir -p "$parent_t10"
    git init -q "$parent_t10" >/dev/null 2>&1
    git -C "$parent_t10" remote add origin \
      "https://github.com/t10-enclosing-owner/t10-enclosing-repo.git" >/dev/null 2>&1
    box_t10="$(mkbox_at "$parent_t10" nested-kit)"
    retro_t10="$(mk_retro "$box_t10" target-foo r.md \
      "<!-- review-status: pending -->" \
      "| 1 | t10 delta fixture row | CLAUDE.md | B1 | new | HIGH |")"
    mutant_t10="$box_t10/research-sdd/toolbelt/stage-retro-issues.sh"
    printf '%s\n' "${sut_content/"$anchor_t10"/  if false; then  # teeth-t10-f1-check-removed}" > "$mutant_t10"
    bash -n "$mutant_t10" 2>/dev/null || { no "T10 teeth: mutant_t10 failed bash -n syntax check" ""; }
    out_t10="$(PATH="$box_t10/bin:$PATH" RESEARCH_SDD_ISSUE_REPO="" \
      "$BASH_BIN" "$mutant_t10" "$retro_t10" 2>&1)"; rc_t10=$?
    if grep -q '^kit-issue-repo: t10-enclosing-owner/t10-enclosing-repo$' <<<"$out_t10"; then
      ok "T10 teeth: F1 toplevel check dropped → enclosing repo leaks through (case 24/25 have teeth)" "()"
    else
      no "T10 teeth: F1 toplevel check dropped → enclosing repo should leak through" \
        "enclosing origin did not leak — case 24/25 is THEATER: rc=$rc_t10 out=[$out_t10]"
    fi
  else
    no "T10 teeth: locate F1 toplevel-check anchor" "anchor not found in SUT — SUT drifted?"
  fi

  # TOOTH 11 (kit issue #1045 F2): neuter shape validation so an invalid
  # override/derived value passes straight through to gh unchecked.
  echo "-- teeth T11: neuter _validate_repo_shape (F2) --"
  anchor_t11='  [[ "$1" =~ $_KIT_ISSUE_REPO_SHAPE_RE ]]'
  if [[ "$sut_content" == *"$anchor_t11"* ]]; then
    box_t11="$(mkbox teeth-t11-shape)"
    retro_t11="$(mk_retro "$box_t11" target-foo r.md \
      "<!-- review-status: pending -->" \
      "| 1 | t11 delta fixture row | CLAUDE.md | B1 | new | HIGH |")"
    mutant_t11="$box_t11/research-sdd/toolbelt/stage-retro-issues.sh"
    printf '%s\n' "${sut_content/"$anchor_t11"/  return 0  # teeth-t11-shape-check-removed}" > "$mutant_t11"
    bash -n "$mutant_t11" 2>/dev/null || { no "T11 teeth: mutant_t11 failed bash -n syntax check" ""; }
    out_t11="$(PATH="$box_t11/bin:$PATH" RESEARCH_SDD_ISSUE_REPO="foo" \
      "$BASH_BIN" "$mutant_t11" "$retro_t11" 2>&1)"; rc_t11=$?
    if grep -q '^kit-issue-repo: foo$' <<<"$out_t11"; then
      ok "T11 teeth: shape validation neutered → invalid override 'foo' leaks through (case 26/27 have teeth)" "()"
    else
      no "T11 teeth: shape validation neutered → invalid override should leak through" \
        "invalid value did not leak — case 26/27 is THEATER: rc=$rc_t11 out=[$out_t11]"
    fi
  else
    no "T11 teeth: locate _validate_repo_shape body anchor" "anchor not found in SUT — SUT drifted?"
  fi

  # TOOTH 12 (kit issue #1045 F3): revert the slash-before-.git strip order so
  # a URL like "o/n.git/" leaves the stray "o/n.git" behind again.
  echo "-- teeth T12: revert F3 slash-before-.git strip order --"
  anchor_t12="$(printf '  rest="${rest%%/}"\n  rest="${rest%%.git}"\n  rest="${rest%%/}"')"
  if [[ "$sut_content" == *"$anchor_t12"* ]]; then
    box_t12="$(mkbox teeth-t12-slash-order)"
    mk_git_remote "$box_t12" "https://github.com/o/n.git/"
    retro_t12="$(mk_retro "$box_t12" target-foo r.md \
      "<!-- review-status: pending -->" \
      "| 1 | t12 delta fixture row | CLAUDE.md | B1 | new | HIGH |")"
    mutant_t12="$box_t12/research-sdd/toolbelt/stage-retro-issues.sh"
    reverted_t12="$(printf '  rest="${rest%%.git}"\n  rest="${rest%%/}"')"
    printf '%s\n' "${sut_content/"$anchor_t12"/"$reverted_t12"}" > "$mutant_t12"
    bash -n "$mutant_t12" 2>/dev/null || { no "T12 teeth: mutant_t12 failed bash -n syntax check" ""; }
    out_t12="$(PATH="$box_t12/bin:$PATH" \
      "$BASH_BIN" "$mutant_t12" "$retro_t12" 2>&1)"; rc_t12=$?
    if grep -q '^kit-issue-repo: o/n\.git$' <<<"$out_t12"; then
      ok "T12 teeth: slash-before-.git order reverted → stray 'o/n.git' reappears (case 28 has teeth)" "()"
    else
      no "T12 teeth: slash-before-.git order reverted → stray '.git' should reappear" \
        "stray suffix did not reappear — case 28 is THEATER: rc=$rc_t12 out=[$out_t12]"
    fi
  else
    no "T12 teeth: locate F3 slash/.git strip-order anchor" "anchor not found in SUT — SUT drifted?"
  fi

  # TOOTH 13 (kit issue #1045 F3, re-anchored for #1046 round 2): the
  # URL-scheme "keep a real non-github host" branch is neutered to always
  # drop instead, so a GHE origin silently loses its host again.
  echo "-- teeth T13: drop F3 non-github.com host retention (URL-scheme keep branch) --"
  anchor_t13='      printf '"'"'%s/%s'"'"' "$host" "$rest"'
  if [[ "$sut_content" == *"$anchor_t13"* ]]; then
    box_t13="$(mkbox teeth-t13-host-drop)"
    mk_git_remote "$box_t13" "https://ghe.corp.example.com/ghe-owner/ghe-kit.git"
    retro_t13="$(mk_retro "$box_t13" target-foo r.md \
      "<!-- review-status: pending -->" \
      "| 1 | t13 delta fixture row | CLAUDE.md | B1 | new | HIGH |")"
    mutant_t13="$box_t13/research-sdd/toolbelt/stage-retro-issues.sh"
    printf '%s\n' "${sut_content/"$anchor_t13"/      printf '%s' \"\$rest\"  # teeth-t13-host-drop}" > "$mutant_t13"
    bash -n "$mutant_t13" 2>/dev/null || { no "T13 teeth: mutant_t13 failed bash -n syntax check" ""; }
    out_t13="$(PATH="$box_t13/bin:$PATH" \
      "$BASH_BIN" "$mutant_t13" "$retro_t13" 2>&1)"; rc_t13=$?
    if grep -q '^kit-issue-repo: ghe-owner/ghe-kit$' <<<"$out_t13"; then
      ok "T13 teeth: GHE host retention dropped → host lost again (case 30/39/42 have teeth)" "()"
    else
      no "T13 teeth: GHE host retention dropped → host should be lost" \
        "host was not dropped — case 30/39/42 is THEATER: rc=$rc_t13 out=[$out_t13]"
    fi
  else
    no "T13 teeth: locate F3 host-retention anchor" "anchor not found in SUT — SUT drifted?"
  fi

  # TOOTH 14 (kit issue #1046 round 2 item 1): neuter the github-alias-host
  # check so an alias/prefix host (e.g. "github.com-alias", "www.github.com")
  # is treated like a real GHE host and KEPT instead of dropped.
  echo "-- teeth T14: neuter github-alias host check (URL-scheme) --"
  anchor_t14='    if [[ "$(printf '"'"'%s'"'"' "$host" | tr '"'"'A-Z'"'"' '"'"'a-z'"'"')" =~ $_KIT_GITHUB_HOST_ALIAS_RE ]]; then'
  if [[ "$sut_content" == *"$anchor_t14"* ]]; then
    box_t14="$(mkbox teeth-t14-alias-check)"
    mk_git_remote "$box_t14" "https://github.com-alias/o/n.git"
    retro_t14="$(mk_retro "$box_t14" target-foo r.md \
      "<!-- review-status: pending -->" \
      "| 1 | t14 delta fixture row | CLAUDE.md | B1 | new | HIGH |")"
    mutant_t14="$box_t14/research-sdd/toolbelt/stage-retro-issues.sh"
    printf '%s\n' "${sut_content/"$anchor_t14"/    if false; then  # teeth-t14-alias-check-removed}" > "$mutant_t14"
    bash -n "$mutant_t14" 2>/dev/null || { no "T14 teeth: mutant_t14 failed bash -n syntax check" ""; }
    out_t14="$(PATH="$box_t14/bin:$PATH" \
      "$BASH_BIN" "$mutant_t14" "$retro_t14" 2>&1)"; rc_t14=$?
    if grep -q '^kit-issue-repo: github.com-alias/o/n$' <<<"$out_t14"; then
      ok "T14 teeth: alias check neutered → alias host leaks through (case 34/35/38 have teeth)" "()"
    else
      no "T14 teeth: alias check neutered → alias host should leak through" \
        "alias did not leak — case 34/35/38 is THEATER: rc=$rc_t14 out=[$out_t14]"
    fi
  else
    no "T14 teeth: locate github-alias host-check anchor" "anchor not found in SUT — SUT drifted?"
  fi

  # TOOTH 15 (kit issue #1046 round 2 item 2): drop the :port strip so a
  # ported host is never recognized as github.com and fails shape validation.
  echo "-- teeth T15: drop :port strip from host --"
  anchor_t15='  host="${host%%:*}"'
  if [[ "$sut_content" == *"$anchor_t15"* ]]; then
    box_t15="$(mkbox teeth-t15-port-strip)"
    mk_git_remote "$box_t15" "https://github.com:443/o/n.git"
    retro_t15="$(mk_retro "$box_t15" target-foo r.md \
      "<!-- review-status: pending -->" \
      "| 1 | t15 delta fixture row | CLAUDE.md | B1 | new | HIGH |")"
    mutant_t15="$box_t15/research-sdd/toolbelt/stage-retro-issues.sh"
    printf '%s\n' "${sut_content/"$anchor_t15"/  : # teeth-t15-port-strip-removed}" > "$mutant_t15"
    bash -n "$mutant_t15" 2>/dev/null || { no "T15 teeth: mutant_t15 failed bash -n syntax check" ""; }
    out_t15="$(PATH="$box_t15/bin:$PATH" \
      "$BASH_BIN" "$mutant_t15" "$retro_t15" 2>&1)"; rc_t15=$?
    if ! grep -q '^kit-issue-repo: o/n$' <<<"$out_t15"; then
      ok "T15 teeth: port strip removed → 'o/n' no longer resolved (case 36/37/38/39 have teeth)" "(rc=$rc_t15)"
    else
      no "T15 teeth: port strip removed → 'o/n' should NOT resolve cleanly" \
        "still resolved cleanly — case 36/37/38/39 is THEATER: rc=$rc_t15 out=[$out_t15]"
    fi
  else
    no "T15 teeth: locate :port strip anchor" "anchor not found in SUT — SUT drifted?"
  fi

  # TOOTH 16 (RDD follow-up item a): neuter the scp-branch github-alias CHECK (force it to
  # always match) so EVERY scp host — including an untrusted, non-github one — is silently
  # dropped to bare 'owner/repo' instead of failing closed to the sentinel. This is the exact
  # pre-fix security bug direction: an scp remote pointed at a foreign host (e.g. ghe.corp.com)
  # would resolve as if it were github.com.
  echo "-- teeth T16: force scp-branch alias check always-true; untrusted scp host must silently drop (case 52/53 have teeth) --"
  anchor_t16='    # STAGE_RETRO_ISSUES_SCP_HOST_DROP (RDD follow-up item a): scp form drops its host ONLY
    # when it matches the github.com alias pattern — see the docstring above for why any OTHER
    # scp host is wrapped in the sentinel (fail closed) rather than dropped unconditionally.
    if [[ "$(printf '"'"'%s'"'"' "$host" | tr '"'"'A-Z'"'"' '"'"'a-z'"'"')" =~ $_KIT_GITHUB_HOST_ALIAS_RE ]]; then'
  if [[ "$sut_content" == *"$anchor_t16"* ]]; then
    box_t16="$(mkbox teeth-t16-scp-fail-closed)"
    mk_git_remote "$box_t16" "git@ghe.corp.com:o/n.git"
    retro_t16="$(mk_retro "$box_t16" target-foo r.md \
      "<!-- review-status: pending -->" \
      "| 1 | t16 delta fixture row | CLAUDE.md | B1 | new | HIGH |")"
    mutant_t16="$box_t16/research-sdd/toolbelt/stage-retro-issues.sh"
    reverted_t16='    # STAGE_RETRO_ISSUES_SCP_HOST_DROP (RDD follow-up item a): scp form drops its host ONLY
    # when it matches the github.com alias pattern — see the docstring above for why any OTHER
    # scp host is wrapped in the sentinel (fail closed) rather than dropped unconditionally.
    if true; then  # teeth-t16-alias-check-forced-true'
    printf '%s\n' "${sut_content/"$anchor_t16"/"$reverted_t16"}" > "$mutant_t16"
    bash -n "$mutant_t16" 2>/dev/null || { no "T16 teeth: mutant_t16 failed bash -n syntax check" ""; }
    out_t16="$(PATH="$box_t16/bin:$PATH" \
      "$BASH_BIN" "$mutant_t16" "$retro_t16" 2>&1)"; rc_t16=$?
    if grep -q '^kit-issue-repo: o/n$' <<<"$out_t16"; then
      ok "T16 teeth: scp alias check forced true → untrusted host silently drops (case 52/53 have teeth)" "()"
    else
      no "T16 teeth: scp alias check forced true → untrusted host should silently drop to 'o/n'" \
        "did not leak — case 52/53 is THEATER: rc=$rc_t16 out=[$out_t16]"
    fi
  else
    no "T16 teeth: locate scp-branch alias-check anchor" "anchor not found in SUT — SUT drifted?"
  fi

  # TOOTH 20 (kit issue #1046 round 2 item b): widen the github-alias-suffix regex back to
  # allow dots ('-[^/]*' instead of '-[^./]*'), so a spoofed host like
  # 'github.com-evil.attacker.com' is wrongly collapsed to plain github.com again.
  echo "-- teeth T20: widen alias-suffix regex to allow dots; spoofed host must collapse to github.com (case 55/56 have teeth) --"
  anchor_t20="_KIT_GITHUB_HOST_ALIAS_RE='^(ssh\\.|www\\.)?github\\.com(-[^./]*)?\$'"
  if [[ "$sut_content" == *"$anchor_t20"* ]]; then
    box_t20="$(mkbox teeth-t20-alias-dot)"
    mk_git_remote "$box_t20" "https://user@github.com-evil.attacker.com/o/n"
    retro_t20="$(mk_retro "$box_t20" target-foo r.md \
      "<!-- review-status: pending -->" \
      "| 1 | t20 delta fixture row | CLAUDE.md | B1 | new | HIGH |")"
    mutant_t20="$box_t20/research-sdd/toolbelt/stage-retro-issues.sh"
    reverted_t20="_KIT_GITHUB_HOST_ALIAS_RE='^(ssh\\.|www\\.)?github\\.com(-[^/]*)?\$'"
    printf '%s\n' "${sut_content/"$anchor_t20"/"$reverted_t20"}" > "$mutant_t20"
    bash -n "$mutant_t20" 2>/dev/null || { no "T20 teeth: mutant_t20 failed bash -n syntax check" ""; }
    out_t20="$(PATH="$box_t20/bin:$PATH" \
      "$BASH_BIN" "$mutant_t20" "$retro_t20" 2>&1)"; rc_t20=$?
    if grep -q '^kit-issue-repo: o/n$' <<<"$out_t20"; then
      ok "T20 teeth: alias-suffix regex widened → spoofed host collapses to github.com (case 55/56 have teeth)" "()"
    else
      no "T20 teeth: alias-suffix regex widened → spoofed host should collapse to 'o/n'" \
        "did not collapse — case 55/56 is THEATER: rc=$rc_t20 out=[$out_t20]"
    fi
  else
    no "T20 teeth: locate alias-suffix regex anchor" "anchor not found in SUT — SUT drifted?"
  fi

  # TOOTH 21 (kit issue #1046 round 2 item c): drop the dotted-host requirement from the shape
  # regex, so a 3-segment override with a non-dotted first segment is wrongly accepted again.
  echo "-- teeth T21: drop dotted-host requirement from shape regex; 'myorg/myrepo/subpath' must wrongly resolve (case 57 has teeth) --"
  anchor_t21="_KIT_ISSUE_REPO_SHAPE_RE='^([A-Za-z0-9][A-Za-z0-9-]*(\\.[A-Za-z0-9-]+)+/)?[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*\$'"
  if [[ "$sut_content" == *"$anchor_t21"* ]]; then
    box_t21="$(mkbox teeth-t21-host-dot)"
    retro_t21="$(mk_retro "$box_t21" target-foo r.md \
      "<!-- review-status: pending -->" \
      "| 1 | t21 delta fixture row | CLAUDE.md | B1 | new | HIGH |")"
    mutant_t21="$box_t21/research-sdd/toolbelt/stage-retro-issues.sh"
    reverted_t21="_KIT_ISSUE_REPO_SHAPE_RE='^([A-Za-z0-9][A-Za-z0-9.-]*/)?[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*\$'"
    printf '%s\n' "${sut_content/"$anchor_t21"/"$reverted_t21"}" > "$mutant_t21"
    bash -n "$mutant_t21" 2>/dev/null || { no "T21 teeth: mutant_t21 failed bash -n syntax check" ""; }
    out_t21="$(PATH="$box_t21/bin:$PATH" RESEARCH_SDD_ISSUE_REPO="myorg/myrepo/subpath" \
      "$BASH_BIN" "$mutant_t21" "$retro_t21" 2>&1)"; rc_t21=$?
    if grep -q '^kit-issue-repo: myorg/myrepo/subpath$' <<<"$out_t21"; then
      ok "T21 teeth: dotted-host requirement dropped → non-dotted 3-segment wrongly accepted (case 57 has teeth)" "()"
    else
      no "T21 teeth: dotted-host requirement dropped → non-dotted 3-segment should be wrongly accepted" \
        "still rejected — case 57 is THEATER: rc=$rc_t21 out=[$out_t21]"
    fi
  else
    no "T21 teeth: locate shape-regex dotted-host anchor" "anchor not found in SUT — SUT drifted?"
  fi

  # TOOTH 22 (kit issue #949 item 2): revert --state all to --state open in the dedup list
  # call, so a CLOSED match (case 9b) is no longer found and a duplicate is created.
  echo "-- teeth T22: revert dedup --state all to --state open; closed match must false-negative (case 9b has teeth) --"
  anchor_t22='    _existing="$(gh issue list --repo "$KIT_ISSUE_REPO" --state all \'
  if [[ "$sut_content" == *"$anchor_t22"* ]]; then
    box_t22="$(mkbox teeth-t22-state-all)"
    mk_gh_stub "$box_t22" matchclosed
    retro_t22="$(mk_retro "$box_t22" target-foo r.md \
      "<!-- review-status: pending -->" \
      "| 1 | t22 delta fixture row | CLAUDE.md | B1 | new | HIGH |")"
    mutant_t22="$box_t22/research-sdd/toolbelt/stage-retro-issues.sh"
    reverted_t22='    _existing="$(gh issue list --repo "$KIT_ISSUE_REPO" --state open \'
    printf '%s\n' "${sut_content/"$anchor_t22"/"$reverted_t22"}" > "$mutant_t22"
    bash -n "$mutant_t22" 2>/dev/null || { no "T22 teeth: mutant_t22 failed bash -n syntax check" ""; }
    out_t22="$(PATH="$box_t22/bin:$PATH" RESEARCH_SDD_ISSUE_REPO="test-owner/test-kit" \
      "$BASH_BIN" "$mutant_t22" "$retro_t22" --apply 2>&1)"; rc_t22=$?
    create_called_t22=0
    [ -f "$box_t22/bin/gh.log" ] && grep -q 'issue create' "$box_t22/bin/gh.log" && create_called_t22=1
    if [ "$create_called_t22" = 1 ]; then
      ok "T22 teeth: dedup reverted to --state open → closed match false-negatives, create called (case 9b has teeth)" "()"
    else
      no "T22 teeth: dedup reverted to --state open → create should be called (missed closed match)" \
        "create not called — case 9b is THEATER: rc=$rc_t22 out=[$out_t22]"
    fi
  else
    no "T22 teeth: locate dedup --state all anchor" "anchor not found in SUT — SUT drifted?"
  fi

  # TOOTH 23 (kit issue #949 item 2, updated for #1093 item 1's added layer): neuter BOTH dedup
  # failure guards — the original rc!=0 check AND the newer empty/malformed-reply check added by
  # kit issue #1093 item 1 — so a failed 'gh issue list' call falls through to create instead of
  # counting as failed. Since #1093 item 1 the two guards are defense-in-depth for the SAME
  # failure mode (a failed dedup lookup): neutering only one no longer reproduces the fall-through
  # bug on its own, because the other still catches it. Both anchors must be present and removed
  # together for case 9c's fall-through scenario to reproduce.
  echo "-- teeth T23: neuter both dedup failure guards; failed list call must fall through to create (case 9c has teeth) --"
  anchor_t23='    if [ "$_dedup_rc" -ne 0 ]; then'
  anchor_t23b='    if ! grep -q '\''^[[:space:]]*\['\'' <<<"$_existing"; then'
  if [[ "$sut_content" == *"$anchor_t23"* ]] && [[ "$sut_content" == *"$anchor_t23b"* ]]; then
    box_t23="$(mkbox teeth-t23-listfail-guard)"
    mk_gh_stub "$box_t23" listfail
    retro_t23="$(mk_retro "$box_t23" target-foo r.md \
      "<!-- review-status: pending -->" \
      "| 1 | t23 delta fixture row | CLAUDE.md | B1 | new | HIGH |")"
    mutant_t23="$box_t23/research-sdd/toolbelt/stage-retro-issues.sh"
    mutant_content_t23="${sut_content/"$anchor_t23"/    if false; then  # teeth-t23-listfail-guard-removed}"
    mutant_content_t23="${mutant_content_t23/"$anchor_t23b"/    if false; then  # teeth-t23-emptyreply-guard-removed}"
    printf '%s\n' "$mutant_content_t23" > "$mutant_t23"
    bash -n "$mutant_t23" 2>/dev/null || { no "T23 teeth: mutant_t23 failed bash -n syntax check" ""; }
    out_t23="$(PATH="$box_t23/bin:$PATH" RESEARCH_SDD_ISSUE_REPO="test-owner/test-kit" \
      "$BASH_BIN" "$mutant_t23" "$retro_t23" --apply 2>&1)"; rc_t23=$?
    create_called_t23=0
    [ -f "$box_t23/bin/gh.log" ] && grep -q 'issue create' "$box_t23/bin/gh.log" && create_called_t23=1
    if [ "$create_called_t23" = 1 ]; then
      ok "T23 teeth: both failure guards neutered → falls through to create (case 9c has teeth)" "()"
    else
      no "T23 teeth: both failure guards neutered → should fall through to create" \
        "create not called — case 9c is THEATER: rc=$rc_t23 out=[$out_t23]"
    fi
  else
    no "T23 teeth: locate both dedup failure guard anchors" "anchor(s) not found in SUT — SUT drifted?"
  fi

  # TOOTH 23b (kit issue #1093 item 1): neuter ONLY the new empty/malformed-reply guard, in
  # isolation, leaving the original rc!=0 check intact. Case 9d's fixture (gh exits 0 with
  # completely EMPTY stdout) passes the rc!=0 check fine (rc IS 0) — with the new guard gone,
  # nothing else stops the empty reply from being read as "no match", so it falls through to
  # create, proving case 9d's teeth.
  echo "-- teeth T23b: neuter ONLY the empty/malformed-reply guard; empty gh reply must fall through to create (case 9d has teeth) --"
  if [[ "$sut_content" == *"$anchor_t23b"* ]]; then
    box_t23b="$(mkbox teeth-t23b-emptyreply-guard)"
    mk_gh_stub "$box_t23b" listempty
    retro_t23b="$(mk_retro "$box_t23b" target-foo r.md \
      "<!-- review-status: pending -->" \
      "| 1 | t23b delta fixture row | CLAUDE.md | B1 | new | HIGH |")"
    mutant_t23b="$box_t23b/research-sdd/toolbelt/stage-retro-issues.sh"
    printf '%s\n' "${sut_content/"$anchor_t23b"/    if false; then  # teeth-t23b-emptyreply-guard-removed}" > "$mutant_t23b"
    bash -n "$mutant_t23b" 2>/dev/null || { no "T23b teeth: mutant_t23b failed bash -n syntax check" ""; }
    out_t23b="$(PATH="$box_t23b/bin:$PATH" RESEARCH_SDD_ISSUE_REPO="test-owner/test-kit" \
      "$BASH_BIN" "$mutant_t23b" "$retro_t23b" --apply 2>&1)"; rc_t23b=$?
    create_called_t23b=0
    [ -f "$box_t23b/bin/gh.log" ] && grep -q 'issue create' "$box_t23b/bin/gh.log" && create_called_t23b=1
    if [ "$create_called_t23b" = 1 ]; then
      ok "T23b teeth: empty-reply guard neutered → falls through to create (case 9d has teeth)" "()"
    else
      no "T23b teeth: empty-reply guard neutered → should fall through to create" \
        "create not called — case 9d is THEATER: rc=$rc_t23b out=[$out_t23b]"
    fi
  else
    no "T23b teeth: locate empty-reply guard anchor" "anchor not found in SUT — SUT drifted?"
  fi

  # TOOTH 17 (kit issue #1046 round 2 item 4): revert the tightened shape
  # regex to the old permissive one, so '-o/n' (a leading '-') is wrongly
  # accepted instead of rejected.
  echo "-- teeth T17: revert shape-tightening regex (item 4) --"
  anchor_t17="_KIT_ISSUE_REPO_SHAPE_RE='^([A-Za-z0-9][A-Za-z0-9-]*(\\.[A-Za-z0-9-]+)+/)?[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*\$'"
  if [[ "$sut_content" == *"$anchor_t17"* ]]; then
    box_t17="$(mkbox teeth-t17-shape-tighten)"
    retro_t17="$(mk_retro "$box_t17" target-foo r.md \
      "<!-- review-status: pending -->" \
      "| 1 | t17 delta fixture row | CLAUDE.md | B1 | new | HIGH |")"
    mutant_t17="$box_t17/research-sdd/toolbelt/stage-retro-issues.sh"
    reverted_t17="_KIT_ISSUE_REPO_SHAPE_RE='^([A-Za-z0-9.-]+/)?[A-Za-z0-9._-]+/[A-Za-z0-9._-]+\$'"
    printf '%s\n' "${sut_content/"$anchor_t17"/"$reverted_t17"}" > "$mutant_t17"
    bash -n "$mutant_t17" 2>/dev/null || { no "T17 teeth: mutant_t17 failed bash -n syntax check" ""; }
    out_t17="$(PATH="$box_t17/bin:$PATH" RESEARCH_SDD_ISSUE_REPO="-o/n" \
      "$BASH_BIN" "$mutant_t17" "$retro_t17" 2>&1)"; rc_t17=$?
    if grep -q '^kit-issue-repo: -o/n$' <<<"$out_t17"; then
      ok "T17 teeth: shape regex reverted → '-o/n' wrongly accepted (case 43.2 has teeth)" "()"
    else
      no "T17 teeth: shape regex reverted → '-o/n' should be wrongly accepted" \
        "'-o/n' still rejected — case 43.2 is THEATER: rc=$rc_t17 out=[$out_t17]"
    fi
  else
    no "T17 teeth: locate shape-tightening regex anchor" "anchor not found in SUT — SUT drifted?"
  fi

  # TOOTH 18 (kit issue #1046 round 2 item 3): re-wrap the resolve call in a
  # subshell — the exact bug class that lost _KIT_ISSUE_REPO_BAD_VALUE before
  # — and confirm the degraded message goes back to naming an empty ''.
  echo "-- teeth T18: re-wrap resolve_kit_issue_repo call in a subshell --"
  anchor_t18="$(printf 'resolve_kit_issue_repo\n_kit_issue_repo_rc=$?')"
  if [[ "$sut_content" == *"$anchor_t18"* ]]; then
    box_t18="$(mkbox teeth-t18-subshell-bug)"
    retro_t18="$(mk_retro "$box_t18" target-foo r.md \
      "<!-- review-status: pending -->" \
      "| 1 | t18 delta fixture row | CLAUDE.md | B1 | new | HIGH |")"
    mutant_t18="$box_t18/research-sdd/toolbelt/stage-retro-issues.sh"
    reverted_t18="$(printf '( resolve_kit_issue_repo )\n_kit_issue_repo_rc=$?')"
    printf '%s\n' "${sut_content/"$anchor_t18"/"$reverted_t18"}" > "$mutant_t18"
    bash -n "$mutant_t18" 2>/dev/null || { no "T18 teeth: mutant_t18 failed bash -n syntax check" ""; }
    out_t18="$(PATH="$box_t18/bin:$PATH" RESEARCH_SDD_ISSUE_REPO="foo" \
      "$BASH_BIN" "$mutant_t18" "$retro_t18" 2>&1)"; rc_t18=$?
    if grep -q "invalid repo shape ''" <<<"$out_t18"; then
      ok "T18 teeth: resolve call re-subshelled → bad value lost again (case 45 has teeth)" "()"
    else
      no "T18 teeth: resolve call re-subshelled → bad value should be lost ('')" \
        "bad value still survived — case 45 is THEATER: rc=$rc_t18 out=[$out_t18]"
    fi
  else
    no "T18 teeth: locate resolve_kit_issue_repo call-site anchor" "anchor not found in SUT — SUT drifted?"
  fi

  # TOOTH 19 (kit issue #1046 round 2 item 5): revert the F1 reason wording
  # to the old inaccurate text, so it no longer names "toplevel".
  echo "-- teeth T19: revert F1 reason wording (item 5) --"
  anchor_t19='    3) _kit_issue_repo_reason="kit root ($KIT_ROOT) is not the git checkout'"'"'s toplevel — git found an enclosing checkout rooted at ${_KIT_ISSUE_REPO_TOPLEVEL} instead" ;;'
  if [[ "$sut_content" == *"$anchor_t19"* ]]; then
    enclosing_parent_t19="$ROOT/teeth-t19-enclosing-parent"
    mkdir -p "$enclosing_parent_t19"
    git init -q "$enclosing_parent_t19" >/dev/null 2>&1
    git -C "$enclosing_parent_t19" remote add origin \
      "https://github.com/t19-owner/t19-repo.git" >/dev/null 2>&1
    box_t19="$(mkbox_at "$enclosing_parent_t19" nested-kit)"
    retro_t19="$(mk_retro "$box_t19" target-foo r.md \
      "<!-- review-status: pending -->" \
      "| 1 | t19 delta fixture row | CLAUDE.md | B1 | new | HIGH |")"
    mutant_t19="$box_t19/research-sdd/toolbelt/stage-retro-issues.sh"
    reverted_t19='    3) _kit_issue_repo_reason="kit root is not its own git checkout — found an enclosing repo instead at $KIT_ROOT" ;;'
    printf '%s\n' "${sut_content/"$anchor_t19"/"$reverted_t19"}" > "$mutant_t19"
    bash -n "$mutant_t19" 2>/dev/null || { no "T19 teeth: mutant_t19 failed bash -n syntax check" ""; }
    out_t19="$(PATH="$box_t19/bin:$PATH" RESEARCH_SDD_ISSUE_REPO="" \
      "$BASH_BIN" "$mutant_t19" "$retro_t19" 2>&1)"; rc_t19=$?
    if ! grep -qi 'toplevel' <<<"$out_t19"; then
      ok "T19 teeth: F1 reason wording reverted → 'toplevel' no longer present (case 46 has teeth)" "()"
    else
      no "T19 teeth: F1 reason wording reverted → 'toplevel' should be gone" \
        "'toplevel' still present — case 46 is THEATER: rc=$rc_t19 out=[$out_t19]"
    fi
  else
    no "T19 teeth: locate F1 reason-wording anchor" "anchor not found in SUT — SUT drifted?"
  fi

  # TOOTH T-OOS (kit issue #1099): neuter the out-of-scope-marker guard. Case 17b's fixture
  # (marker after a second heading) must then be silently read as if no marker existed at all —
  # its row planned instead of the seed being refused — reproducing the exact #1048-#1089
  # fail-open shape #1099 fixes.
  echo "-- teeth T-OOS: neuter the out-of-scope-marker guard; case 17b must fail open again --"
  anchor_toos='if [ -z "$_marker_line" ] && retro_marker_out_of_scope "$retro"; then'
  if [[ "$sut_content" == *"$anchor_toos"* ]]; then
    box_toos="$(mkbox teeth-oos)"
    retro_toos="$box_toos/rh/target-foo/retros/r-oos.md"
    cat > "$retro_toos" <<'RETROEOF'
# §18 Retro — focus: apis

## Notes

<!-- review-status: applied 2026-09-20 · kit ad87c33 -->

## Proposed kit deltas

| # | Proposed change | Target (file) | Evidence | Type | Priority |
|---|---|---|---|---|---|
| 1 | fix the thing | METHODOLOGY.md | B42 | new | HIGH |
RETROEOF
    mutant_toos="$box_toos/research-sdd/toolbelt/stage-retro-issues.sh"
    printf '%s\n' "${sut_content/"$anchor_toos"/if false; then}" > "$mutant_toos"
    "$BASH_BIN" -n "$mutant_toos" 2>/dev/null || no "T-OOS teeth: mutant syntax check" "bash -n failed"
    out_toos="$(PATH="$box_toos/bin:$PATH" \
      "$BASH_BIN" "$mutant_toos" "$retro_toos" 2>&1)"; rc_toos=$?
    if grep -q 'planned-issue:' <<<"$out_toos"; then
      ok "T-OOS teeth: guard neutered → row planned again, fails open (case 17b has teeth)" "()"
    else
      no "T-OOS teeth: guard neutered → row should be planned (fail open)" \
        "mutant did not emit planned-issue — case 17b is THEATER: rc=$rc_toos out=[$out_toos]"
    fi
  else
    no "T-OOS teeth: locate out-of-scope-marker guard anchor" "anchor not found in SUT — SUT drifted?"
  fi

  # ── kit issue #1129 findings 2/3: mutation controls for the found=1-no-rows branch and for
  # each grammar rule this PR series added, none of which had a --prove-teeth control before. ──

  # Tooth H1: drop the retro_grammar_has_honesty guard from the found=1-no-rows branch. Case 62
  # (honest empty) must then flip from empty-input to unclassifiable.
  echo "-- teeth H1: drop the honesty check; case 62 (honest empty) must flip to unclassifiable --"
  anchor_h1='  if retro_grammar_has_honesty "$retro"; then
    echo "empty-input: delta section found but contains no data rows (honest §18 zero) in $retro" >&2
    echo "unclassifiable-items: 0 (empty-input: honest §18 zero, no data rows)"
    exit 0
  fi'
  if [[ "$sut_content" == *"$anchor_h1"* ]]; then
    box_h1="$(mkbox teeth-h1)"
    retro_h1="$box_h1/rh/target-foo/retros/r-h1.md"
    { printf '<!-- review-status: pending -->\n# retro\n\n## Proposed kit deltas\n\n'
      printf '| # | Proposed change | Target (file) | Evidence | Type | Priority |\n|---|---|---|---|---|---|\n'
      printf 'no new deltas; the kit already covers this run.\n'
    } > "$retro_h1"
    mutant_h1="$box_h1/research-sdd/toolbelt/stage-retro-issues.sh"
    printf '%s\n' "${sut_content/"$anchor_h1"/}" > "$mutant_h1"
    "$BASH_BIN" -n "$mutant_h1" 2>/dev/null || no "teeth H1: mutant syntax check" "bash -n failed"
    out_h1="$(PATH="$box_h1/bin:$PATH" "$BASH_BIN" "$mutant_h1" "$retro_h1" 2>&1)"
    if grep -qi '^unclassifiable:' <<<"$out_h1"; then
      ok "teeth H1: honesty check removed → case 62 flips to unclassifiable (has teeth)" "()"
    else
      no "teeth H1: honesty check removed → should flip to unclassifiable" "case 62 is THEATER: out=[$out_h1]"
    fi
  else
    no "teeth H1: locate the honesty-check guard anchor" "anchor not found — SUT drifted?"
  fi

  # Tooth H2: the surviving unclassifiable echo itself — silence it, case 63 must go quiet.
  echo "-- teeth H2: silence the unclassifiable echo; case 63 must go quiet (no unclassifiable line) --"
  anchor_h2='echo "unclassifiable: delta section found but contains neither row-table rows nor '"'"'### D<N> —'"'"' entries (nor numbered items directly under the heading, nor '"'"'## Delta <ID> —'"'"' entries) in $retro — needs manual review, no issue auto-staged" >&2'
  if [[ "$sut_content" == *"$anchor_h2"* ]]; then
    box_h2="$(mkbox teeth-h2)"
    retro_h2="$box_h2/rh/target-foo/retros/r-h2.md"
    { printf '<!-- review-status: pending -->\n# retro\n\n## Proposed kit deltas\n\n'
      printf '### ABSORB → prose, no table, no honesty\n\nprose here\n'
    } > "$retro_h2"
    mutant_h2="$box_h2/research-sdd/toolbelt/stage-retro-issues.sh"
    printf '%s\n' "${sut_content/"$anchor_h2"/:}" > "$mutant_h2"
    "$BASH_BIN" -n "$mutant_h2" 2>/dev/null || no "teeth H2: mutant syntax check" "bash -n failed"
    out_h2="$(PATH="$box_h2/bin:$PATH" "$BASH_BIN" "$mutant_h2" "$retro_h2" 2>&1)"
    if ! grep -qi '^unclassifiable:' <<<"$out_h2"; then
      ok "teeth H2: unclassifiable echo silenced → case 63's typed message gone (has teeth)" "()"
    else
      no "teeth H2: unclassifiable echo silenced → message should be gone" "case 63 is THEATER: out=[$out_h2]"
    fi
  else
    no "teeth H2: locate the unclassifiable echo anchor" "anchor not found — SUT drifted?"
  fi

  # Tooth GR1 (kit issue #1129 Q5): the Spanish canonical alias, sourced from the shared grammar
  # lib as loaded by THIS consumer — remove it from the copy the seeder sources and prove case 59
  # (Spanish alias with real table rows) stops being staged.
  echo "-- teeth GR1: remove the Spanish canonical alias from the sourced grammar lib; case 59 must stop staging --"
  rg_lib_content="$(cat "$RETRO_GRAMMAR_LIB")"
  anchor_gr1='  if (low ~ /^## propuesta de deltas al kit([[:space:]]|$)/) return 1'
  if [[ "$rg_lib_content" == *"$anchor_gr1"* ]]; then
    box_gr1="$(mkbox teeth-gr1)"
    retro_gr1="$box_gr1/rh/target-foo/retros/r-gr1.md"
    { printf '<!-- review-status: pending -->\n# retro\n\n## PROPUESTA de deltas al kit (revisar antes de aplicar)\n\n'
      printf '| # | Proposed change | Target (file) | Evidence | Type | Priority |\n|---|---|---|---|---|---|\n'
      printf '| 1 | delta uno fixture row | CLAUDE.md | B1 | new | HIGH |\n'
    } > "$retro_gr1"
    printf '%s\n' "${rg_lib_content/"$anchor_gr1"/}" > "$box_gr1/research-sdd/toolbelt/lib/retro-grammar.sh"
    "$BASH_BIN" -n "$box_gr1/research-sdd/toolbelt/lib/retro-grammar.sh" 2>/dev/null \
      || no "teeth GR1: mutant lib syntax check" "bash -n failed"
    out_gr1="$(PATH="$box_gr1/bin:$PATH" "$BASH_BIN" "$box_gr1/research-sdd/toolbelt/stage-retro-issues.sh" "$retro_gr1" 2>&1)"
    if grep -qi '^empty-input:' <<<"$out_gr1"; then
      ok "teeth GR1: Spanish alias removed from lib → case 59 reverts to empty-input (has teeth)" "()"
    else
      no "teeth GR1: Spanish alias removed from lib → should revert to empty-input" "case 59 is THEATER: out=[$out_gr1]"
    fi
  else
    no "teeth GR1: locate the Spanish canonical alias in lib/retro-grammar.sh" "anchor not found — lib drifted?"
  fi

  # Tooth GR2 (kit issue #1129 Q5): revert Rule 2's hyphen widening back to space-only. Case 60
  # (hyphenated kit-delta) must then revert from unclassifiable to empty-input.
  echo "-- teeth GR2: revert Rule 2's hyphen widening; case 60 must revert to empty-input --"
  anchor_gr2='if (!is_unrec && low ~ /[ -]kit[ -]delt/ && low !~ /not[ -]+kit[ -]+delt/) is_unrec=1'
  if [[ "$rg_lib_content" == *"$anchor_gr2"* ]]; then
    box_gr2="$(mkbox teeth-gr2)"
    retro_gr2="$box_gr2/rh/target-foo/retros/r-gr2.md"
    { printf '<!-- review-status: pending -->\n# retro\n\n'
      printf '## B. Campaign-8 kit-delta backlog (the overdue roll-up)\n\nsome prose, no table rows here\n'
    } > "$retro_gr2"
    reverted_gr2='if (!is_unrec && low ~ / kit delt/ && low !~ /not +kit +delt/) is_unrec=1'
    printf '%s\n' "${rg_lib_content/"$anchor_gr2"/"$reverted_gr2"}" > "$box_gr2/research-sdd/toolbelt/lib/retro-grammar.sh"
    "$BASH_BIN" -n "$box_gr2/research-sdd/toolbelt/lib/retro-grammar.sh" 2>/dev/null \
      || no "teeth GR2: mutant lib syntax check" "bash -n failed"
    out_gr2="$(PATH="$box_gr2/bin:$PATH" "$BASH_BIN" "$box_gr2/research-sdd/toolbelt/stage-retro-issues.sh" "$retro_gr2" 2>&1)"
    if grep -qi '^empty-input:' <<<"$out_gr2"; then
      ok "teeth GR2: Rule 2 hyphen widening reverted → case 60 reverts to empty-input (has teeth)" "()"
    else
      no "teeth GR2: Rule 2 hyphen widening reverted → should revert to empty-input" "case 60 is THEATER: out=[$out_gr2]"
    fi
  else
    no "teeth GR2: locate Rule 2's hyphen-widened pattern in lib/retro-grammar.sh" "anchor not found — lib drifted?"
  fi

  # Tooth GR3 (kit issue #1129 Q5): disable Rule 4 (standalone H3 "Proposals" outside section).
  # Case 61 must then revert from unclassifiable to empty-input.
  echo "-- teeth GR3: disable Rule 4 (standalone H3 Proposals); case 61 must revert to empty-input --"
  anchor_gr3='      !in_sec && /^###[^#]/ {
        if (!unrec_found && low ~ /^### +([0-9]+\. )?proposals?([[:space:]]|[(]|$)/) {
          unrec_found=1; unrec_heading=$0
        }
        next
      }'
  if [[ "$rg_lib_content" == *"$anchor_gr3"* ]]; then
    box_gr3="$(mkbox teeth-gr3)"
    retro_gr3="$box_gr3/rh/target-foo/retros/r-gr3.md"
    { printf '<!-- review-status: pending -->\n# retro\n\n## A. THE DEFECT\n\n'
      printf '### Proposals (propose-never-apply) — make it automatic\n\nsome prose, no table rows here\n'
    } > "$retro_gr3"
    printf '%s\n' "${rg_lib_content/"$anchor_gr3"/}" > "$box_gr3/research-sdd/toolbelt/lib/retro-grammar.sh"
    "$BASH_BIN" -n "$box_gr3/research-sdd/toolbelt/lib/retro-grammar.sh" 2>/dev/null \
      || no "teeth GR3: mutant lib syntax check" "bash -n failed"
    out_gr3="$(PATH="$box_gr3/bin:$PATH" "$BASH_BIN" "$box_gr3/research-sdd/toolbelt/stage-retro-issues.sh" "$retro_gr3" 2>&1)"
    if grep -qi '^empty-input:' <<<"$out_gr3"; then
      ok "teeth GR3: Rule 4 disabled → case 61 reverts to empty-input (has teeth)" "()"
    else
      no "teeth GR3: Rule 4 disabled → should revert to empty-input" "case 61 is THEATER: out=[$out_gr3]"
    fi
  else
    no "teeth GR3: locate Rule 4 (standalone H3 Proposals) in lib/retro-grammar.sh" "anchor not found — lib drifted?"
  fi

  # kit issue #1287: the walk-up + name lookup moved into lib/target-paths.sh, so the #1169 teeth
  # mutate the LIB copy inside the box (the SUT is unchanged). tooth_swap <box> <relfile> <anchor>
  # <replacement> writes the mutant over the box's copy of <relfile> and refuses a vacuous (anchor
  # missing / byte-identical) or syntactically broken mutant — a crash is not a tooth.
  tooth_swap() {
    local box="$1" rel="$2" anchor="$3" repl="$4"
    local file="$box/research-sdd/toolbelt/$rel" content
    content="$(cat "$file")"
    if [[ "$content" != *"$anchor"* ]]; then
      no "tooth_swap: locate anchor in $rel" "anchor not found — file drifted? anchor=[$anchor]"; return 1
    fi
    printf '%s\n' "${content/"$anchor"/"$repl"}" > "$file"
    if cmp -s "$file" "$HERE/../$rel"; then
      no "tooth_swap: mutant of $rel" "mutant is identical to the original — vacuous"; return 1
    fi
    if ! "$BASH_BIN" -n "$file" 2>/dev/null; then
      no "tooth_swap: mutant of $rel passes bash -n" "syntax error — crash-based theater"; return 1
    fi
    return 0
  }
  # run_box <box> <retro> [args]: run the box's (possibly mutated) SUT copy; sets MOUT (stdout+stderr).
  run_box() {
    local box="$1" retro="$2"; shift 2
    MOUT="$(PATH="$box/bin:$PATH" RESEARCH_SDD_ISSUE_REPO=test-owner/test-kit \
      "$BASH_BIN" "$box/research-sdd/toolbelt/stage-retro-issues.sh" "$retro" "$@" 2>&1)"
  }

  # TOOTH #1169-a: remove the walk-up (stop after the first ancestor = old dirname(dirname())
  # behaviour). A nested corpus must then fall back to the structural basename again.
  echo "-- teeth T1169a: neuter walk-up (lib) --"
  box_w="$(mkbox teeth-walkup)"
  retro_w="$(mk_nested_retro "$box_w" corpus/retros r-w.md)"
  if tooth_swap "$box_w" lib/target-paths.sh '      [ "$anc" = "/" ] && break' '      break'; then
    run_box "$box_w" "$retro_w"
    if ! grep -q 'labels: .*target:target-foo,' <<<"$MOUT"; then
      ok "T1169a teeth: walk-up neutered → nested corpus no longer resolves (case 64 has teeth)" "()"
    else
      no "T1169a teeth: walk-up neutered" "case 64 is THEATER: out=[$MOUT]"
    fi
  fi

  # TOOTH #1169-b: remove the structural-name guard. An unregistered nested corpus must then
  # plan `target:corpus` again instead of failing up front.
  echo "-- teeth T1169b: neuter structural-name guard --"
  box_g="$(mkbox teeth-structural)"
  retro_g="$(mk_nested_retro "$box_g" corpus/retros r-g.md)"
  printf '# test targets\n\n| # | Target | Path |\n|---|---|---|\n| 1 | other | `%s/rh/other` |\n' "$box_g" \
    > "$box_g/research-sdd/TARGETS.md"
  mkdir -p "$box_g/rh/other"
  if tooth_swap "$box_g" stage-retro-issues.sh '    corpus|retros)' '    __never_matches__)'; then
    run_box "$box_g" "$retro_g"
    if grep -q 'target:corpus' <<<"$MOUT"; then
      ok "T1169b teeth: guard neutered → target:corpus planned (case 67 has teeth)" "()"
    else
      no "T1169b teeth: guard neutered" "case 67 is THEATER: out=[$MOUT]"
    fi
  fi

  # TOOTH #1169-c: use the path basename instead of the registered Target name (lib). Case 69 must
  # then yield the basename label (target-foo), not the registered name (reg-name).
  echo "-- teeth T1169c: neuter registered-name lookup (lib) --"
  box_n="$(mkbox teeth-regname)"
  printf '# test targets\n\n| # | Target | Path |\n|---|---|---|\n| 1 | reg-name | `%s/rh/target-foo` |\n' "$box_n" \
    > "$box_n/research-sdd/TARGETS.md"
  retro_n="$(mk_nested_retro "$box_n" corpus/retros r-n.md)"
  anchor_n="$(grep -m 1 '^    name="\$(_TP_RAW=' "$TARGET_PATHS_LIB")"
  if [ -n "$anchor_n" ] && tooth_swap "$box_n" lib/target-paths.sh "$anchor_n" '    name=""; arc=0'; then
    run_box "$box_n" "$retro_n"
    if ! grep -q 'target:reg-name,' <<<"$MOUT"; then
      ok "T1169c teeth: name lookup neutered → basename label (case 69 has teeth)" "()"
    else
      no "T1169c teeth: name lookup neutered" "case 69 is THEATER: out=[$MOUT]"
    fi
  else
    no "T1169c teeth: locate registered-name anchor in lib" "anchor not found — lib drifted?"
  fi

  # TOOTH #1287-a: outermost-ancestor match (lib: drop the first-match break). Case 72 must flip:
  # the inner target's retro would be labelled with the OUTER name.
  echo "-- teeth T1287a: nearest ancestor → outermost (lib) --"
  box_a="$(mkbox teeth-nearest)"
  mkdir -p "$box_a/rh/target-foo/inner-t/retros"
  retro_a="$(mk_retro "$box_a" target-foo r-a.md "<!-- review-status: pending -->" \
    "| 1 | outer delta fixture row | CLAUDE.md | B1 | fix | HIGH |")"
  cp "$retro_a" "$box_a/rh/target-foo/inner-t/retros/r-a.md"
  printf '# t\n\n| # | Target | Path |\n|---|---|---|\n| 1 | outer-name | `%s/rh/target-foo` |\n| 2 | inner-name | `%s/rh/target-foo/inner-t` |\n' "$box_a" "$box_a" \
    > "$box_a/research-sdd/TARGETS.md"
  anchor_a="$(grep -m 1 'SENTINEL-TNR-NEAREST' "$TARGET_PATHS_LIB")"
  if [ -n "$anchor_a" ] && tooth_swap "$box_a" lib/target-paths.sh "$anchor_a" '          :'; then
    run_box "$box_a" "$box_a/rh/target-foo/inner-t/retros/r-a.md"
    if grep -q 'labels: .*target:outer-name,' <<<"$MOUT"; then
      ok "T1287a teeth: outermost-ancestor mutant → inner retro labelled outer (case 72 has teeth)" "()"
    else
      no "T1287a teeth: outermost-ancestor mutant" "case 72 is THEATER: out=[$MOUT]"
    fi
  fi

  # TOOTH #1287-b: swallow the operational failure (rc 1 from the helper) → back to WARN + guess.
  echo "-- teeth T1287b: neuter the TARGETS.md operational-failure exit --"
  box_b="$(mkbox teeth-opfail)"
  retro_b="$(mk_retro "$box_b" target-foo r-b.md "<!-- review-status: pending -->" \
    "| 1 | flat delta fixture row | CLAUDE.md | B1 | fix | HIGH |")"
  rm -f "$box_b/research-sdd/TARGETS.md"
  if tooth_swap "$box_b" stage-retro-issues.sh 'if [ "$_tnr_rc" -eq 1 ]; then' 'if false; then'; then
    run_box "$box_b" "$retro_b"
    if grep -q 'planned-issue:' <<<"$MOUT"; then
      ok "T1287b teeth: failure exit neutered → plans on a guessed basename (case 70 has teeth)" "()"
    else
      no "T1287b teeth: failure exit neutered" "case 70 is THEATER: out=[$MOUT]"
    fi
  fi

  # TOOTH #1287-c/d/e: the legacy-signature dedup. Each mutant must make its case create a duplicate.
  legacy_box() {  # <name> <stub-mode> <stub-pattern> → echoes box; retro at $box/rh/target-foo/retros/r-legacy.md
    local b
    b="$(mkbox "$1")"
    printf '# t\n\n| # | Target | Path |\n|---|---|---|\n| 1 | reg-name | `%s/rh/target-foo` |\n' "$b" \
      > "$b/research-sdd/TARGETS.md"
    mk_gh_stub "$b" "$2" "$3"
    mk_retro "$b" target-foo r-legacy.md "<!-- review-status: pending -->" \
      "| 1 | legacy delta | CLAUDE.md | B1 | fix | HIGH |" >/dev/null
    printf '%s' "$b"
  }
  echo "-- teeth T1287c: disable the legacy-signature search --"
  box_c="$(legacy_box teeth-legacy-off matchsig 'Source retro: target-foo/retros/r-legacy.md')"
  if tooth_swap "$box_c" stage-retro-issues.sh 'if [ "$_legacy_target_name" != "$target_name" ]; then' 'if false; then'; then
    run_box "$box_c" "$box_c/rh/target-foo/retros/r-legacy.md" --apply
    if grep -q 'issue create' "$box_c/bin/gh.log" 2>/dev/null; then
      ok "T1287c teeth: legacy search disabled → duplicate created (case 75 has teeth)" "()"
    else
      no "T1287c teeth: legacy search disabled" "case 75 is THEATER: out=[$MOUT]"
    fi
  fi
  echo "-- teeth T1287d: legacy lookup failure guards neutered --"
  box_d="$(legacy_box teeth-legacy-failguard failsig 'Source retro: target-foo/retros/')"
  if tooth_swap "$box_d" stage-retro-issues.sh 'if [ "$_legacy_rc" -ne 0 ]; then' 'if false; then' \
     && tooth_swap "$box_d" stage-retro-issues.sh "if ! grep -q '^[[:space:]]*\\[' <<<\"\$_legacy_existing\"; then" 'if false; then'; then
    run_box "$box_d" "$box_d/rh/target-foo/retros/r-legacy.md" --apply
    if grep -q 'issue create' "$box_d/bin/gh.log" 2>/dev/null; then
      ok "T1287d teeth: legacy failure guards neutered → falls through to create (case 75c has teeth)" "()"
    else
      no "T1287d teeth: legacy failure guards neutered" "case 75c is THEATER: out=[$MOUT]"
    fi
  fi
  echo "-- teeth T1287e: legacy OPEN-match check neutered --"
  box_e="$(legacy_box teeth-legacy-open matchsig 'Source retro: target-foo/retros/r-legacy.md')"
  if tooth_swap "$box_e" stage-retro-issues.sh "if grep -q '\"state\":[[:space:]]*\"OPEN\"' <<<\"\$_legacy_existing\"; then" 'if false; then'; then
    run_box "$box_e" "$box_e/rh/target-foo/retros/r-legacy.md" --apply
    if grep -q 'issue create' "$box_e/bin/gh.log" 2>/dev/null; then
      ok "T1287e teeth: legacy OPEN check neutered → duplicate created (case 75 has teeth)" "()"
    else
      no "T1287e teeth: legacy OPEN check neutered" "case 75 is THEATER: out=[$MOUT]"
    fi
  fi

  echo "-- teeth T1287f: legacy CLOSED-match branch deleted --"
  box_f="$(legacy_box teeth-legacy-closed matchsigclosed 'Source retro: target-foo/retros/r-legacy.md')"
  if tooth_swap "$box_f" stage-retro-issues.sh "if grep -q '\"state\":[[:space:]]*\"CLOSED\"' <<<\"\$_legacy_existing\"; then" 'if false; then'; then
    run_box "$box_f" "$box_f/rh/target-foo/retros/r-legacy.md" --apply
    if grep -q 'issue create' "$box_f/bin/gh.log" 2>/dev/null; then
      ok "T1287f teeth: legacy CLOSED branch deleted → duplicate created (case 75e has teeth)" "()"
    else
      no "T1287f teeth: legacy CLOSED branch deleted" "case 75e is THEATER: out=[$MOUT]"
    fi
  fi
  echo "-- teeth T1287g: structural legacy-name skip removed --"
  box_g2="$(mkbox teeth-legacy-structural)"
  printf '# t\n\n| # | Target | Path |\n|---|---|---|\n| 1 | reg-name | `%s/rh/target-foo` |\n' "$box_g2" \
    > "$box_g2/research-sdd/TARGETS.md"
  mk_gh_stub "$box_g2" nomatch
  retro_g2="$(mk_nested_retro "$box_g2" corpus/retros r-g2.md)"
  if tooth_swap "$box_g2" stage-retro-issues.sh '  corpus|retros) _legacy_target_name="$target_name" ;;' '  __never_matches__) _legacy_target_name="$target_name" ;;'; then
    run_box "$box_g2" "$retro_g2" --apply
    if grep -qF 'Source retro: corpus/retros/' "$box_g2/bin/gh.log" 2>/dev/null; then
      ok "T1287g teeth: structural skip removed → pointless corpus/retros lookup (case 75f has teeth)" "()"
    else
      no "T1287g teeth: structural skip removed" "case 75f is THEATER: out=[$MOUT]"
    fi
  fi

  # TOOTH #1304-1: the exact-signature filter (kit issue #1304 item 1). Each mutant must make its
  # case misclassify a fuzzy/garbled reply, proving cases 9e / 75g bite.
  xbox() {  # <name> <stub-mode> → echoes a box with a pending 1-row retro and the stub in <mode>
    local b
    b="$(mkbox "$1")"
    mk_gh_stub "$b" "$2"
    mk_retro "$b" target-foo r-x.md "<!-- review-status: pending -->" \
      "| 3 | exact dedup delta | CLAUDE.md | B1 | new | HIGH |" >/dev/null
    printf '%s' "$b"
  }
  echo "-- teeth T1304-1: any search hit counts as a duplicate (equality check removed) --"
  box_x1="$(xbox teeth-exact-any fuzzyother)"
  if tooth_swap "$box_x1" stage-retro-issues.sh 'if (ln == needle)' 'if (1)'; then
    run_box "$box_x1" "$box_x1/rh/target-foo/retros/r-x.md" --apply
    if ! grep -q 'issue create' "$box_x1/bin/gh.log" 2>/dev/null; then
      ok "T1304-1 teeth: equality removed → another target's issue suppresses the create (case 9e-1 has teeth)" "()"
    else
      no "T1304-1 teeth: equality removed" "case 9e-1 is THEATER: out=[$MOUT]"
    fi
  fi
  echo "-- teeth T1304-2: signature compared as a PREFIX (row 3 matches row 30) --"
  box_x2="$(xbox teeth-exact-prefix fuzzylongid)"
  if tooth_swap "$box_x2" stage-retro-issues.sh 'if (ln == needle)' 'if (index(ln, needle) == 1)'; then
    run_box "$box_x2" "$box_x2/rh/target-foo/retros/r-x.md" --apply
    if ! grep -q 'issue create' "$box_x2/bin/gh.log" 2>/dev/null; then
      ok "T1304-2 teeth: prefix match → row 30 suppresses row 3 (case 9e-3 has teeth)" "()"
    else
      no "T1304-2 teeth: prefix match" "case 9e-3 is THEATER: out=[$MOUT]"
    fi
  fi
  echo "-- teeth T1304-3: trailing CR/whitespace no longer trimmed --"
  box_x3="$(xbox teeth-exact-crlf crlfsig)"
  if tooth_swap "$box_x3" stage-retro-issues.sh 'sub(/[ \t\r]+$/, "", ln)' 'ln = ln'; then
    run_box "$box_x3" "$box_x3/rh/target-foo/retros/r-x.md" --apply
    if grep -q 'issue create' "$box_x3/bin/gh.log" 2>/dev/null; then
      ok "T1304-3 teeth: no trim → a CRLF body is missed and the row duplicated (case 9e-5 has teeth)" "()"
    else
      no "T1304-3 teeth: no trim" "case 9e-5 is THEATER: out=[$MOUT]"
    fi
  fi
  echo "-- teeth T1304-4: unparseable reply no longer rejected --"
  box_x4="$(xbox teeth-exact-badjson badjson)"
  if tooth_swap "$box_x4" stage-retro-issues.sh 'if (!closed) exit 3' 'if (!closed) { }' \
     && tooth_swap "$box_x4" stage-retro-issues.sh 'if (depth != 0) exit 3' 'if (0) exit 3'; then
    run_box "$box_x4" "$box_x4/rh/target-foo/retros/r-x.md" --apply
    if grep -q 'issue create' "$box_x4/bin/gh.log" 2>/dev/null; then
      ok "T1304-4 teeth: parse guards removed → garbled reply read as no-match, create called (case 9e-8 has teeth)" "()"
    else
      no "T1304-4 teeth: parse guards removed" "case 9e-8 is THEATER: out=[$MOUT]"
    fi
  fi
  echo "-- teeth T1304-5: legacy lookup left unfiltered --"
  box_x5="$(legacy_box teeth-exact-legacy fuzzyother '')"
  if tooth_swap "$box_x5" stage-retro-issues.sh '_exact_sig_matches "$_legacy_sig")" || {' 'cat)" || {'; then
    run_box "$box_x5" "$box_x5/rh/target-foo/retros/r-legacy.md" --apply
    if ! grep -q 'issue create' "$box_x5/bin/gh.log" 2>/dev/null; then
      ok "T1304-5 teeth: legacy filter removed → another target's issue suppresses the create (case 75g has teeth)" "()"
    else
      no "T1304-5 teeth: legacy filter removed" "case 75g is THEATER: out=[$MOUT]"
    fi
  fi

  # TOOTH #949-4 (kit issue #949 item 4): the failure counter and the exit-2 gate each need a
  # single-failure / mixed case to bite. Both mutants are built on a COPY via tooth_swap-style sed.
  echo "-- teeth T949-4a: failure counter adds 2 instead of 1 (case 16b has teeth) --"
  box_f2="$(mkbox teeth-failed-plus2)"
  mk_gh_stub "$box_f2" createfail
  retro_f2="$(mk_retro "$box_f2" target-foo r.md "<!-- review-status: pending -->" \
    "| 1 | fail delta fixture row | CLAUDE.md | B1 | new | HIGH |")"
  sed 's/failed=\$((failed+1)); continue/failed=$((failed+2)); continue/' "$SUT" > "$box_f2/research-sdd/toolbelt/stage-retro-issues.sh"
  if cmp -s "$SUT" "$box_f2/research-sdd/toolbelt/stage-retro-issues.sh"; then
    no "T949-4a teeth: build +2 mutant" "mutant identical — sed substitution failed"
  elif ! "$BASH_BIN" -n "$box_f2/research-sdd/toolbelt/stage-retro-issues.sh" 2>/dev/null; then
    no "T949-4a teeth: build +2 mutant" "syntax error — crash-based theater"
  else
    out_f2="$(PATH="$box_f2/bin:$PATH" RESEARCH_SDD_ISSUE_REPO="test-owner/test-kit" \
      "$BASH_BIN" "$box_f2/research-sdd/toolbelt/stage-retro-issues.sh" "$retro_f2" --apply 2>&1)"
    if grep -qE 'failed=2$' <<<"$(grep '^summary:' <<<"$out_f2")"; then
      ok "T949-4a teeth: +2 counter → failed=2 for one failure (case 16b has teeth)" "()"
    else
      no "T949-4a teeth: +2 counter must read failed=2" "case 16b is THEATER: out=[$out_f2]"
    fi
  fi
  echo "-- teeth T949-4b: exit-2 gate fires only above one failure (case 16b has teeth) --"
  box_g1="$(mkbox teeth-failed-gt1)"
  mk_gh_stub "$box_g1" createfail
  retro_g1="$(mk_retro "$box_g1" target-foo r.md "<!-- review-status: pending -->" \
    "| 1 | fail delta fixture row | CLAUDE.md | B1 | new | HIGH |")"
  sed 's/\[ "\$failed" -gt 0 \] && exit 2/[ "$failed" -gt 1 ] \&\& exit 2/' "$SUT" > "$box_g1/research-sdd/toolbelt/stage-retro-issues.sh"
  if cmp -s "$SUT" "$box_g1/research-sdd/toolbelt/stage-retro-issues.sh"; then
    no "T949-4b teeth: build -gt 1 mutant" "mutant identical — sed substitution failed"
  elif ! "$BASH_BIN" -n "$box_g1/research-sdd/toolbelt/stage-retro-issues.sh" 2>/dev/null; then
    no "T949-4b teeth: build -gt 1 mutant" "syntax error — crash-based theater"
  else
    PATH="$box_g1/bin:$PATH" RESEARCH_SDD_ISSUE_REPO="test-owner/test-kit" \
      "$BASH_BIN" "$box_g1/research-sdd/toolbelt/stage-retro-issues.sh" "$retro_g1" --apply >/dev/null 2>&1; rc_g1=$?
    if [ "$rc_g1" -eq 0 ]; then
      ok "T949-4b teeth: -gt 1 gate → one failure exits 0 (case 16b has teeth)" "(rc=$rc_g1)"
    else
      no "T949-4b teeth: -gt 1 gate must exit 0 on one failure" "case 16b is THEATER: rc=$rc_g1"
    fi
  fi

  # ---- kit issue #1332 item 1 teeth (label probe) — mutants built with tests/lib/mutant.sh ----
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  # lbl_mutant <tag> <issue-mode> <label-mode> <sed-expr>: run a 2-row --apply against a mutant of
  # the SUT; sets LOG/OUT/RC and the N_* counters exactly as lbl_case does. mutant_sed REFUSES a
  # vacuous, identical, syntax-broken or live-tree mutant, so a refusal is a FAIL, never a pass.
  lbl_mutant() {
    local tag="$1" im="$2" lm="$3" expr="$4" mbox mfile
    mbox="$(mkbox "teeth-label-$tag")"; mk_gh_stub "$mbox" "$im" "" "$lm"
    mfile="$mbox/research-sdd/toolbelt/stage-retro-issues.sh"
    if ! mutant_sed "$SUT" "$mfile" -e "$expr"; then
      no "T1332-$tag: build mutant" "mutant_sed refused (vacuous/identical/broken)"; return 1
    fi
    local r; r="$(mk_retro "$mbox" target-foo "r-$tag.md" "<!-- review-status: pending -->" "$TWO_ROWS")"
    run "$mbox" "$r" --apply
    LOG="$(cat "$mbox/bin/gh.log" 2>/dev/null)"
    N_LLIST="$(grep -c 'gh label list' <<<"$LOG")"; N_LCREATE="$(grep -c 'gh label create' <<<"$LOG")"
    N_ICREATE="$(grep -c 'gh issue create' <<<"$LOG")"; N_DEGR="$(grep -c '^degraded:' <<<"$OUT")"
    return 0
  }
  echo "-- teeth T1332: label probe --"
  if lbl_mutant skipcall nomatch missing 's/^    ensure_target_label .*/    :/'; then
    if [ "$N_LLIST" = 0 ] && [ "$N_LCREATE" = 0 ]; then ok "T1332-a teeth: probe call removed → no label traffic (76a/76b have teeth)" "()"
    else no "T1332-a teeth: probe removed must flip 76a" "76a is THEATER: list=$N_LLIST lcreate=$N_LCREATE"; fi
  fi
  if lbl_mutant nocache nomatch exists 's/^  \[ "\$_label_ready" -eq 1 \] && return 0/  :/'; then
    if [ "$N_LLIST" = 2 ]; then ok "T1332-b teeth: no once-guard → probe per row, 2 lists (76b has teeth)" "()"
    else no "T1332-b teeth: per-row probe must flip 76b" "76b is THEATER: list=$N_LLIST"; fi
  fi
  if lbl_mutant probecont nomatch failjson 's/if \[ "\$_lrc" -ne 0 \]; then/if false; then/'; then
    if [ "$N_LCREATE" = 1 ] && [ "$N_ICREATE" = 2 ]; then ok "T1332-c teeth: probe exit code ignored → failed probe read as 'missing' (76c2 has teeth)" "()"
    else no "T1332-c teeth: ignored probe rc must flip 76c2" "76c2 is THEATER: lcreate=$N_LCREATE icreate=$N_ICREATE"; fi
  fi
  if lbl_mutant createcont nomatch createfail '/could not be created/{n;s/exit 1/:/;}'; then
    if [ "$N_ICREATE" = 2 ]; then ok "T1332-d teeth: label-create failure no longer exits → issues created (76d has teeth)" "()"
    else no "T1332-d teeth: swallowed create failure must flip 76d" "76d is THEATER: icreate=$N_ICREATE"; fi
  fi
  if lbl_mutant fuzzy nomatch fuzzyonly 's/grep -qF "\\"name\\":\\"\${_lname_lc}\\""/grep -qF "${_lname_lc}"/'; then
    if [ "$N_LCREATE" = 0 ]; then ok "T1332-e teeth: substring match → fuzzy hit read as 'exists', no create (76f has teeth)" "()"
    else no "T1332-e teeth: fuzzy match must flip 76f" "76f is THEATER: lcreate=$N_LCREATE"; fi
  fi
  if lbl_mutant emptyok nomatch listempty '/<<<"\$_lout"; then$/s/if !/if false \&\& !/'; then
    if [ "$N_ICREATE" = 2 ] || [ "$N_LCREATE" = 1 ]; then ok "T1332-f teeth: empty-reply guard removed → empty reply read as 'missing' (76e has teeth)" "()"
    else no "T1332-f teeth: removed guard must flip 76e" "76e is THEATER: icreate=$N_ICREATE lcreate=$N_LCREATE"; fi
  fi
  if lbl_mutant color nomatch missing 's/--color d4c5f9/--color ededed/'; then
    if ! grep -qF -- '--color d4c5f9' <<<"$LOG"; then ok "T1332-g teeth: wrong color → convention assertion fails (76a has teeth)" "()"
    else no "T1332-g teeth: wrong color must flip 76a" "76a is THEATER"; fi
  fi

  if lbl_mutant nocase nomatch existsupper 's/ | tr .A-Z. .a-z.)$/)/'; then
    if [ "$N_LCREATE" = 1 ]; then ok "T1332-h teeth: case-sensitive compare → upper-case label read as missing (76i has teeth)" "()"
    else no "T1332-h teeth: case-sensitive compare must flip 76i" "76i is THEATER: lcreate=$N_LCREATE"; fi
  fi
  if lbl_mutant noreprobe nomatch racewin 's/^      if ! _label_present "\$_lname"; then$/      if true; then/'; then
    if [ "$N_DEGR" = 1 ] && [ "$N_ICREATE" = 0 ]; then ok "T1332-i teeth: no re-probe after a failed create → degraded despite the race winner (76j has teeth)" "()"
    else no "T1332-i teeth: removed re-probe must flip 76j" "76j is THEATER: degr=$N_DEGR icreate=$N_ICREATE"; fi
  fi
  # entry-form seeding (N1/N6) mutants
  ent_mutant() {   # ent_mutant <tag> <sed-expr> <retro-fixture-writer-arg: plain|gap>
    local tag="$1" expr="$2" kind="$3" mbox mfile r
    mbox="$(mkbox "teeth-entry-$tag")"; mk_gh_stub "$mbox" nomatch
    mfile="$mbox/research-sdd/toolbelt/stage-retro-issues.sh"
    if ! mutant_sed "$SUT" "$mfile" -e "$expr"; then no "T1332-$tag: build mutant" "mutant_sed refused"; return 1; fi
    r="$mbox/rh/target-foo/retros/r.md"
    if [ "$kind" = gap ]; then
      printf '<!-- review-status: pending -->\n# r\n\n## Proposed kit deltas\n\n### **D1** — bold id entry fixture\n\n### D2 — plain id entry fixture\n' > "$r"
    else
      sed 's/^<!-- review-status: applied.*-->$/<!-- review-status: pending -->/' "$HERE/fixtures/retro-entry-form-applied-3.md" > "$r"
    fi
    run "$mbox" "$r"
    return 0
  }
  if ent_mutant seedoff 's/^  _rows="\$(retro_grammar_entry_rows "\$retro_file")"/  _rows=""/' plain; then
    if grep -q '^unclassifiable:' <<<"$OUT"; then ok "T1332-j teeth: entry fallback removed → unclassifiable again (78a has teeth)" "()"
    else no "T1332-j teeth: removed entry fallback must flip 78a" "78a is THEATER: out=[$OUT]"; fi
  fi
  if ent_mutant warnoff 's/^  \[ -z "\$_rows" \] || retro_grammar_entry_warn "\$retro_file" >&2/  :/' gap; then
    if ! grep -q '^WARN: .*1 of 2' <<<"$OUT"; then ok "T1332-k teeth: gap WARN removed → silent (78f has teeth)" "()"
    else no "T1332-k teeth: removed WARN must flip 78f" "78f is THEATER: out=[$OUT]"; fi
  fi

  # NB1 mutant: the unregistered guard disabled → the basename fallback creates a label + issues (79a has teeth)
  mbox79="$(mkbox teeth-unregistered)"; mk_gh_stub "$mbox79" nomatch "" missing
  mkdir -p "$mbox79/rh/other-kit/retros"
  if mutant_sed "$SUT" "$mbox79/research-sdd/toolbelt/stage-retro-issues.sh" -e 's/^  if \[ "\$_target_registered" -ne 1 \]; then$/  if false; then/'; then
    printf '<!-- review-status: pending -->\n# r\n\n## Proposed kit deltas\n\n| # | Proposed change | Target (file) | Evidence | Type | Priority |\n|---|---|---|---|---|---|\n| 1 | a fixture row | CLAUDE.md | B1 | fix | HIGH |\n' > "$mbox79/rh/other-kit/retros/r.md"
    run "$mbox79" "$mbox79/rh/other-kit/retros/r.md" --apply
    if grep -q 'gh label create' "$mbox79/bin/gh.log" && grep -q 'gh issue create' "$mbox79/bin/gh.log"; then
      ok "T1332-l teeth: guard disabled → unregistered target gets a label and issues (79a has teeth)" "()"
    else no "T1332-l teeth: disabled guard must flip 79a" "79a is THEATER: out=[$OUT]"; fi
  else no "T1332-l: build mutant" "mutant_sed refused"; fi

  # #1356/#1369 mutants: fence tracking and the list limit (cases 80a, 81a, 81b, 81d have teeth)
  stg_mutant() {   # stg_mutant <tag> <stub-mode> <sed-expr...>: builds mbox + mutant SUT; sets MBOX
    local tag="$1" mode="$2"; shift 2
    MBOX="$(mkbox "teeth-1369-$tag")"; mk_gh_stub "$MBOX" "$mode"
    mutant_sed "$SUT" "$MBOX/research-sdd/toolbelt/stage-retro-issues.sh" "$@" \
      || { no "T1369-$tag: build mutant" "mutant_sed refused"; return 1; }
  }
  if stg_mutant fence nomatch -e 's/^_rows="\$(_RG_QUIET_FENCE=1 retro_grammar_defenced "\$retro_file" | awk/_rows="$(cat "$retro_file" | awk/'; then
    printf '<!-- review-status: pending -->\n# r\n\n## Proposed kit deltas\n\n| # | Proposed change | Target (file) | Evidence | Type | Priority |\n|---|---|---|---|---|---|\n| 1 | real row fixture row | CLAUDE.md | B1 | fix | HIGH |\n\n```markdown\n| 2 | fenced example row | CLAUDE.md | B2 | fix | LOW |\n```\n' > "$MBOX/rh/target-foo/retros/r.md"
    run "$MBOX" "$MBOX/rh/target-foo/retros/r.md"
    if [ "$(grep -c '^planned-issue:' <<<"$OUT")" = 2 ]; then ok "T1369-fence teeth: table awk bypasses defenced → fenced row seeded (80a has teeth)" "()"
    else no "T1369-fence teeth: bypassing fence tracking must flip 80a" "80a is THEATER: out=[$OUT]"; fi
  fi
  if stg_mutant nolimit nomatch -e 's/^      --limit "\$_LIST_LIMIT" --search "\\"\$_search_sig\\"" /      --search "\\"$_search_sig\\"" /'; then
    run "$MBOX" "$(mk_retro "$MBOX" target-foo r.md '<!-- review-status: pending -->' '| 1 | a fixture row | CLAUDE.md | B1 | fix | HIGH |')" --apply
    dedup_lines_1369="$(grep -v 'number,state,title' "$MBOX/bin/gh.log")"
    if ! grep -qE 'gh issue list .*--limit [0-9]+' <<<"$dedup_lines_1369"; then ok "T1369-limit teeth: --limit dropped → no explicit limit on the dedup call (81a has teeth)" "()"
    else no "T1369-limit teeth: dropping --limit must flip 81a" "81a is THEATER"; fi
  fi
  full_mutant() {   # full_mutant <tag> <sed-expr>: page2 stub, limit 2 → 81b must stop failing
    if stg_mutant "$1" page2 -e "$2"; then
      STAGE_RETRO_ISSUES_LIST_LIMIT=2 run "$MBOX" "$(mk_retro "$MBOX" target-foo r.md '<!-- review-status: pending -->' '| 1 | a fixture row | CLAUDE.md | B1 | fix | HIGH |')" --apply
      if grep -q 'gh issue create' "$MBOX/bin/gh.log"; then ok "T1369-$1 teeth: mutant creates despite a full page (81b has teeth)" "()"
      else no "T1369-$1 teeth: mutant must flip 81b" "81b is THEATER: out=[$OUT]"; fi
    fi
  }
  full_mutant capguard 's/^    if \[ -n "\$_page_filled" \]; then$/    if false; then/'
  full_mutant filledcmp 's/\[ "\$_t" -ge "\$_LIST_LIMIT" \]/[ "$_t" -gt "$_LIST_LIMIT" ]/'
  full_mutant totalline 's/^      printf "total=%d\\n", ntotal /      printf "total=%d\\n", 0 /'
  if stg_mutant limitvalid nomatch -e "s/^  ''|\*\[!0-9\]\*|0) echo \"degraded: STAGE_RETRO_ISSUES_LIST_LIMIT/  NEVER) echo \"degraded: STAGE_RETRO_ISSUES_LIST_LIMIT/"; then
    STAGE_RETRO_ISSUES_LIST_LIMIT=abc run "$MBOX" "$MBOX/rh/target-foo/retros/none.md"
    if ! grep -q '^degraded: STAGE_RETRO_ISSUES_LIST_LIMIT' <<<"$OUT"; then ok "T1369-limitvalid teeth: validation removed → no typed degraded line (81d has teeth)" "()"
    else no "T1369-limitvalid teeth: removing validation must flip 81d" "81d is THEATER: out=[$OUT]"; fi
  fi

  # #1403 fix-first mutants: unreadable retro, single unclosed-fence WARN (cases 82a, 82b)
  if [ "$(id -u)" != 0 ] && stg_mutant unreadable nomatch -e 's/^if \[ ! -r "\$retro" \]; then$/if false; then/'; then
    _mr="$(mk_retro "$MBOX" target-foo r.md '<!-- review-status: pending -->' '| 1 | a fixture row | CLAUDE.md | B1 | fix | HIGH |')"
    chmod 000 "$_mr"; run "$MBOX" "$_mr"; chmod 600 "$_mr"
    if ! grep -q '^degraded: retro not readable' <<<"$OUT"; then ok "T1403-unreadable teeth: stage check removed → no typed degraded (82a has teeth)" "()"
    else no "T1403-unreadable teeth: removing the check must flip 82a" "82a is THEATER: out=[$OUT]"; fi
  fi
  warn_once() {   # warn_once <tag>: MBOX holds a mutant; 82b's retro must now produce != 1 WARN lines
    local r="$MBOX/rh/target-foo/retros/r.md" n
    printf '<!-- review-status: pending -->\n# r\n\n## Proposed kit deltas\n\n### D1 — one entry fixture\n\n```\n### D2 — two entry fixture\n' > "$r"
    run "$MBOX" "$r"; n="$(grep -c '^WARN: unclosed code fence' <<<"$OUT")"
    if [ "$n" != 1 ]; then ok "T1403-$1 teeth: WARN count is $n, not 1 (82b has teeth)" "()"
    else no "T1403-$1 teeth: mutant must flip 82b" "82b is THEATER: out=[$OUT]"; fi
  }
  if stg_mutant quiettable nomatch -e 's/^_rows="\$(_RG_QUIET_FENCE=1 retro_grammar_defenced/_rows="$(retro_grammar_defenced/'; then warn_once quiettable; fi
  MBOX="$(mkbox teeth-1403-quietwarn)"; mk_gh_stub "$MBOX" nomatch
  if mutant_sed "$RETRO_GRAMMAR_LIB" "$MBOX/research-sdd/toolbelt/lib/retro-grammar.sh" -e 's/info="\$(_RG_QUIET_FENCE=1 retro_grammar_delta_info "\$f")"/info="$(retro_grammar_delta_info "$f")"/'; then warn_once quietwarn
  else no "T1403-quietwarn: build mutant" "mutant_sed refused"; fi

fi  # --prove-teeth

# ---------------------------------------------------------------------------
# 16 — APPLY MODE CREATE FAILURE: --apply with all creates failing → failed=N in summary, exit non-zero
# RED against origin/main: exits 0 and summary has no failed= field.
box="$(mkbox case-createfail)"
mk_gh_stub "$box" createfail
retro="$(mk_retro "$box" target-foo r-createfail.md \
  "<!-- review-status: pending -->" \
  "$(printf '| 1 | first delta fixture row | CLAUDE.md | B1 | new | HIGH |\n| 2 | second delta | CLAUDE.md | B2 | fix | LOW |')")"
run "$box" "$retro" --apply
summary_line16="$(grep '^summary:' <<<"$OUT")"
has_failed_field=0; failed_count_nonzero=0; rc_nonzero=0
grep -qE 'failed=[0-9]' <<<"$summary_line16" && has_failed_field=1
grep -qE 'failed=[1-9]' <<<"$summary_line16" && failed_count_nonzero=1
[ "$RC" -ne 0 ] && rc_nonzero=1
if [ "$rc_nonzero" = 1 ] && [ "$has_failed_field" = 1 ] && [ "$failed_count_nonzero" = 1 ]; then
  ok "16 --apply createfail: failed= in summary, non-zero exit" "(exit $RC summary=[$summary_line16])"
else
  no "16 --apply createfail: failed= in summary, non-zero exit" \
    "exit=$RC rc_nonzero=$rc_nonzero has_failed=$has_failed_field nonzero_count=$failed_count_nonzero summary=[$summary_line16]"
fi

# 16b — SINGLE failure (kit issue #949 item 4): exactly one open row whose create fails must report
#       failed=1 (not 2) AND exit 2. Case 16 uses two failing rows, so a counter that adds 2 or a
#       gate that fires only above one failure survived it.
box="$(mkbox case-createfail-single)"
mk_gh_stub "$box" createfail
retro="$(mk_retro "$box" target-foo r-createfail1.md "<!-- review-status: pending -->" \
  "| 1 | only delta fixture row | CLAUDE.md | B1 | new | HIGH |")"
run "$box" "$retro" --apply
summary_line16b="$(grep '^summary:' <<<"$OUT")"
if [ "$RC" = 2 ] && grep -qF 'created=0 ' <<<"$summary_line16b" && grep -qE 'failed=1$' <<<"$summary_line16b"; then
  ok "16b --apply single create failure: failed=1 exactly, exit 2" "(summary=[$summary_line16b])"
else
  no "16b --apply single create failure: expected failed=1 and exit 2" "exit=$RC summary=[$summary_line16b]"
fi

# 16c — MIXED run: the first create succeeds, the second fails → created=1 AND failed=1, exit 2
#       (partial failure must not look like success, nor swallow the row that did get created).
box="$(mkbox case-createfail-mixed)"
mk_gh_stub "$box" createfailsecond
retro="$(mk_retro "$box" target-foo r-createfail-mixed.md "<!-- review-status: pending -->" \
  "$(printf '| 1 | first delta fixture row | CLAUDE.md | B1 | new | HIGH |\n| 2 | second delta | CLAUDE.md | B2 | fix | LOW |')")"
run "$box" "$retro" --apply
summary_line16c="$(grep '^summary:' <<<"$OUT")"
if [ "$RC" = 2 ] && grep -qF 'created=1 ' <<<"$summary_line16c" && grep -qE 'failed=1$' <<<"$summary_line16c" \
  && grep -q '^created: ' <<<"$OUT"; then
  ok "16c --apply mixed run: created=1 failed=1, exit 2" "(summary=[$summary_line16c])"
else
  no "16c --apply mixed run: expected created=1 failed=1 and exit 2" "exit=$RC summary=[$summary_line16c]"
fi

# ---------------------------------------------------------------------------
# 17 — MARKER AFTER H1: retro with applied marker placed after H1+blank → no-match (not seeded)
# Real example: niagara-research/retros/*-closure.md has H1 on line 1, blank on line 2, marker on line 3.
# RED against origin/main: marker is missed → rows are emitted as planned-issues instead of no-match.
box="$(mkbox case-after-h1-applied)"
retro_after_h1="$box/rh/target-foo/retros/r-after-h1.md"
cat > "$retro_after_h1" <<'RETROEOF'
# §18 Retro — focus: signing-pki

<!-- review-status: applied 2026-09-20 · kit ad87c33 -->

## Proposed kit deltas

| # | Proposed change | Target (file) | Evidence | Type | Priority |
|---|---|---|---|---|---|
| 1 | fix the thing | METHODOLOGY.md | B42 | new | HIGH |
| 2 | another thing | CLAUDE.md | B43 | fix | MEDIUM |
RETROEOF
run "$box" "$retro_after_h1"
after_h1_nomatch=0; after_h1_planned=0
grep -qi 'no-match\|all.*shipped\|applied' <<<"$OUT" && after_h1_nomatch=1
grep -q 'planned-issue:' <<<"$OUT" && after_h1_planned=1
if [ "$RC" = 0 ] && [ "$after_h1_nomatch" = 1 ] && [ "$after_h1_planned" = 0 ]; then
  ok "17 marker after H1: applied retro not seeded → no-match" "(exit $RC)"
else
  no "17 marker after H1: applied retro not seeded → no-match" \
    "exit=$RC nomatch=$after_h1_nomatch planned=$after_h1_planned out=[$OUT]"
fi

# ---------------------------------------------------------------------------
# 17b — SCOPE NARROWING + FAIL-CLOSED (kit issues #945, #1099): a marker positioned deep in the
# body — after a SECOND heading, unrelated to the leading-block-plus-one-H1 shape — is out of
# retro_marker_scope_line's scope. Before #1099, an out-of-scope marker was silently
# indistinguishable from "no marker at all" and its row was emitted as planned — the fail-open
# shape that produced #1048-#1089 (every row seeded because a marker sat somewhere the parser
# never looked). #1099 makes this refuse to seed instead: typed 'out-of-scope-marker:' message,
# exit 0, NO planned-issue: lines.
# RED against pre-#1099: the deep marker was silently read as absent and the row WAS planned.
box="$(mkbox case-two-headings-marker)"
retro_two_headings="$box/rh/target-foo/retros/r-two-headings.md"
cat > "$retro_two_headings" <<'RETROEOF'
# §18 Retro — focus: apis

## Notes

<!-- review-status: applied 2026-09-20 · kit ad87c33 -->

## Proposed kit deltas

| # | Proposed change | Target (file) | Evidence | Type | Priority |
|---|---|---|---|---|---|
| 1 | fix the thing | METHODOLOGY.md | B42 | new | HIGH |
RETROEOF
run "$box" "$retro_two_headings"
two_headings_planned=0; two_headings_oos=0
grep -q 'planned-issue:' <<<"$OUT" && two_headings_planned=1
grep -q '^out-of-scope-marker:' <<<"$OUT" && two_headings_oos=1
if [ "$RC" = 0 ] && [ "$two_headings_planned" = 0 ] && [ "$two_headings_oos" = 1 ]; then
  ok "17b marker after a SECOND heading → out-of-scope-marker, refuses to seed (#945, #1099)" "(exit $RC)"
else
  no "17b marker after a SECOND heading → out-of-scope-marker, refuses to seed (#945, #1099)" \
    "exit=$RC planned=$two_headings_planned oos=$two_headings_oos out=[$OUT]"
fi

# ---------------------------------------------------------------------------
# 17fence — FENCE EDGE CASES (kit issues #949 item 3 / #1304 item 6): an applied retro must never plan
# issues because the whole-file marker scan was fooled by a fence. Both repros below were read as
# "no marker at all" before the CommonMark-style fence tracking, so every row was seeded.
# 17fence-1: a '~~~' fence holding a ``` line, the (out-of-scope) marker AFTER it → refuses to seed.
box="$(mkbox case-fence-tilde)"
retro_fence_tilde="$box/rh/target-foo/retros/r-fence-tilde.md"
{
  printf '# §18 Retro — focus: apis\n\n## Notes\n\n~~~\n```\n~~~\n\n<!-- review-status: applied 2026-09-20 · kit ad87c33 -->\n\n'
  printf '## Proposed kit deltas\n\n| # | Proposed change | Target (file) | Evidence | Type | Priority |\n|---|---|---|---|---|---|\n| 1 | fix the thing | METHODOLOGY.md | B42 | new | HIGH |\n'
} > "$retro_fence_tilde"
run "$box" "$retro_fence_tilde"
[ "$RC" = 0 ] && grep -q '^out-of-scope-marker:' <<<"$OUT" && ! grep -q 'planned-issue:' <<<"$OUT" \
  && ok "17fence-1 ~~~ fence containing a \`\`\` line, marker after it → refuses to seed" "(exit $RC)" \
  || no "17fence-1 ~~~ fence containing a \`\`\` line, marker after it → refuses to seed" "exit=$RC out=[$OUT]"

# 17fence-2: an UNCLOSED fence before the marker → fails closed (refuses), never reads as markerless.
box="$(mkbox case-fence-unclosed)"
retro_fence_unclosed="$box/rh/target-foo/retros/r-fence-unclosed.md"
{
  printf '# §18 Retro — focus: apis\n\n## Notes\n\n```\nstray opener, never closed\n\n<!-- review-status: applied 2026-09-20 · kit ad87c33 -->\n\n'
  printf '## Proposed kit deltas\n\n| # | Proposed change | Target (file) | Evidence | Type | Priority |\n|---|---|---|---|---|---|\n| 1 | fix the thing | METHODOLOGY.md | B42 | new | HIGH |\n'
} > "$retro_fence_unclosed"
run "$box" "$retro_fence_unclosed"
[ "$RC" = 0 ] && grep -q '^out-of-scope-marker:' <<<"$OUT" && ! grep -q 'planned-issue:' <<<"$OUT" \
  && ok "17fence-2 unclosed fence before the marker → fails closed, refuses to seed" "(exit $RC)" \
  || no "17fence-2 unclosed fence before the marker → fails closed, refuses to seed" "exit=$RC out=[$OUT]"

# ---------------------------------------------------------------------------
# 17c — OUT-OF-SCOPE MARKER, LIST EDGES (kit issue #1099, §7 "test the list edges"): the
# whole-file scan (retro_marker_line) that detects an out-of-scope marker reads the file
# line-by-line; prove it is not blind at any structural position — EARLY, MIDDLE, LATE (no
# trailing newline, mirroring the verify-registry.sh last-field bug) — and that a minimal
# single-extra-line file (smallest possible out-of-scope shape) is caught too.

# 17c-1 — EARLY: YAML frontmatter precedes an otherwise leading-block-shaped marker.
box="$(mkbox case-oos-early)"
retro_oos_early="$box/rh/target-foo/retros/r-oos-early.md"
printf -- '---\ntitle: x\n---\n\n<!-- review-status: applied 2026-09-20 · kit ad87c33 -->\n\n## Proposed kit deltas\n\n| # | Proposed change | Target (file) | Evidence | Type | Priority |\n|---|---|---|---|---|---|\n| 1 | fix the thing | METHODOLOGY.md | B42 | new | HIGH |\n' \
  > "$retro_oos_early"
run "$box" "$retro_oos_early"
[ "$RC" = 0 ] && grep -q '^out-of-scope-marker:' <<<"$OUT" \
  && ! grep -q 'planned-issue:' <<<"$OUT" \
  && ok "17c-1 out-of-scope marker EARLY (YAML frontmatter) → refuses to seed" "(exit $RC)" \
  || no "17c-1 out-of-scope marker EARLY (YAML frontmatter) → refuses to seed" "exit=$RC out=[$OUT]"

# 17c-2 — MIDDLE: substantial unrelated content both before AND after the out-of-scope marker.
box="$(mkbox case-oos-middle)"
retro_oos_middle="$box/rh/target-foo/retros/r-oos-middle.md"
{
  printf '# §18 Retro — focus: apis\n\n## Background\n\nSome long narrative paragraph explaining\nwhat happened across several lines of prose\nso the marker below sits well past line 1.\n\n'
  printf '<!-- review-status: applied 2026-09-20 · kit ad87c33 -->\n\n'
  printf '## More notes\n\nEven more narrative content follows the marker,\nso it is not the last line of the file either.\n\n'
  printf '## Proposed kit deltas\n\n| # | Proposed change | Target (file) | Evidence | Type | Priority |\n|---|---|---|---|---|---|\n| 1 | fix the thing | METHODOLOGY.md | B42 | new | HIGH |\n'
} > "$retro_oos_middle"
run "$box" "$retro_oos_middle"
[ "$RC" = 0 ] && grep -q '^out-of-scope-marker:' <<<"$OUT" \
  && ! grep -q 'planned-issue:' <<<"$OUT" \
  && ok "17c-2 out-of-scope marker MIDDLE (narrative before+after) → refuses to seed" "(exit $RC)" \
  || no "17c-2 out-of-scope marker MIDDLE (narrative before+after) → refuses to seed" "exit=$RC out=[$OUT]"

# 17c-3 — LAST: the marker is the FINAL line of the file, with NO trailing newline — the exact
# shape of verify-registry.sh's list-edge bug (a `read` loop silently skipping the last element).
box="$(mkbox case-oos-last)"
retro_oos_last="$box/rh/target-foo/retros/r-oos-last.md"
printf '# §18 Retro — focus: apis\n\n## Notes\n\n<!-- review-status: applied 2026-09-20 · kit ad87c33 -->' \
  > "$retro_oos_last"
run "$box" "$retro_oos_last"
[ "$RC" = 0 ] && grep -q '^out-of-scope-marker:' <<<"$OUT" \
  && ok "17c-3 out-of-scope marker LAST line, no trailing newline → still detected" "(exit $RC)" \
  || no "17c-3 out-of-scope marker LAST line, no trailing newline → still detected" "exit=$RC out=[$OUT]"

# 17c-4 — SINGLE-ROW: the smallest possible out-of-scope shape — exactly one non-blank,
# non-comment line (a lone '## Notes' heading) between the leading block and the marker.
box="$(mkbox case-oos-single-row)"
retro_oos_single="$box/rh/target-foo/retros/r-oos-single.md"
printf '## Notes\n<!-- review-status: applied 2026-09-20 · kit ad87c33 -->\n' > "$retro_oos_single"
run "$box" "$retro_oos_single"
[ "$RC" = 0 ] && grep -q '^out-of-scope-marker:' <<<"$OUT" \
  && ok "17c-4 out-of-scope marker, single-row minimal shape → still detected" "(exit $RC)" \
  || no "17c-4 out-of-scope marker, single-row minimal shape → still detected" "exit=$RC out=[$OUT]"

# 17d — REGRESSION GUARD: a genuinely markerless retro (no marker anywhere in the file) must
# NOT be misclassified as out-of-scope-marker — it stays the ordinary pending/open case with
# rows planned, exactly as before #1099.
box="$(mkbox case-oos-genuinely-absent)"
retro_absent="$(mk_retro "$box" target-foo r-no-marker-at-all.md "-" \
  "$(printf '| 1 | fix the thing | METHODOLOGY.md | B1 | new | HIGH |')")"
run "$box" "$retro_absent"
[ "$RC" = 0 ] && grep -q 'planned-issue:' <<<"$OUT" \
  && ! grep -q '^out-of-scope-marker:' <<<"$OUT" \
  && ok "17d genuinely markerless retro → still planned as open, NOT out-of-scope-marker" "(exit $RC)" \
  || no "17d genuinely markerless retro → still planned as open, NOT out-of-scope-marker" "exit=$RC out=[$OUT]"

# 17e — REGRESSION GUARD (BOM): a UTF-8 BOM followed by an otherwise in-scope H1/blank/marker
# layout must still be read IN scope (status honored normally) — not misclassified as
# out-of-scope-marker just because of the BOM.
box="$(mkbox case-oos-bom-inscope)"
retro_bom="$box/rh/target-foo/retros/r-bom-inscope.md"
printf '\xef\xbb\xbf# §18 Retro — focus: apis\n\n<!-- review-status: applied 2026-09-20 · kit ad87c33 -->\n\n## Proposed kit deltas\n\n| # | Proposed change | Target (file) | Evidence | Type | Priority |\n|---|---|---|---|---|---|\n| 1 | fix the thing | METHODOLOGY.md | B42 | new | HIGH |\n' \
  > "$retro_bom"
run "$box" "$retro_bom"
[ "$RC" = 0 ] && grep -qi 'no-match\|all.*shipped\|applied' <<<"$OUT" \
  && ! grep -q 'planned-issue:' <<<"$OUT" \
  && ! grep -q '^out-of-scope-marker:' <<<"$OUT" \
  && ok "17e BOM + otherwise in-scope marker → honored normally (no-match), not out-of-scope" "(exit $RC)" \
  || no "17e BOM + otherwise in-scope marker → honored normally (no-match), not out-of-scope" "exit=$RC out=[$OUT]"

# ---------------------------------------------------------------------------
# 18 — DISMISSED MARKER WITH PROSE "partial": dismissed retro with lowercase "partial" in marker prose
# should NOT trigger is_partial. Real example: 2026-09-01-build-n4-module-kit-v0.2-retro.md has
# "dismissed ... (P1 partial)" in the marker text. The case-insensitive grep currently flips is_partial.
# RED against origin/main: the dismissed retro creates issues instead of exiting with no-match.
box="$(mkbox case-dismissed-prose-partial)"
retro_dpp="$box/rh/target-foo/retros/r-dismissed-partial-prose.md"
cat > "$retro_dpp" <<'RETROEOF'
<!-- review-status: dismissed 2026-09-20 · scoped to other-kit — deltas owned there (D1-D5, P1 partial) -->
# Retro — build-n4-module kit v0.2

## Proposed kit deltas

| # | Proposed change | Target (file) | Evidence | Type | Priority |
|---|---|---|---|---|---|
| D1 | fix the thing | METHODOLOGY.md | B42 | new | HIGH |
| D2 | another thing | CLAUDE.md | B43 | fix | MEDIUM |
RETROEOF
run "$box" "$retro_dpp"
dpp_nomatch=0; dpp_planned=0
# grep for the explicit no-match: message, NOT for the word "dismissed" (which would match the filename)
grep -qi '^no-match:' <<<"$OUT" && dpp_nomatch=1
grep -q 'planned-issue:' <<<"$OUT" && dpp_planned=1
if [ "$RC" = 0 ] && [ "$dpp_nomatch" = 1 ] && [ "$dpp_planned" = 0 ]; then
  ok "18 dismissed with prose 'partial': not seeded → no-match" "(exit $RC)"
else
  no "18 dismissed with prose 'partial': not seeded → no-match" \
    "exit=$RC nomatch=$dpp_nomatch planned=$dpp_planned out=[$OUT]"
fi


echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
