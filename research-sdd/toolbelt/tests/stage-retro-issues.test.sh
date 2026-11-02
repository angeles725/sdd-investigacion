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


echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
