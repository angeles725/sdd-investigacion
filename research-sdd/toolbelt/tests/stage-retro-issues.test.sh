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
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../stage-retro-issues.sh"
[ -f "$SUT" ] || { echo "FATAL: script under test not found: $SUT" >&2; exit 2; }
RETRO_STATUS_LIB="$HERE/../lib/retro-status.sh"
[ -f "$RETRO_STATUS_LIB" ] || { echo "FATAL: retro-status helper not found" >&2; exit 2; }
RETRO_GRAMMAR_LIB="$HERE/../lib/retro-grammar.sh"
[ -f "$RETRO_GRAMMAR_LIB" ] || { echo "FATAL: retro-grammar helper not found" >&2; exit 2; }
TARGET_PATHS_LIB="$HERE/../lib/target-paths.sh"
[ -f "$TARGET_PATHS_LIB" ] || { echo "FATAL: target-paths helper not found" >&2; exit 2; }
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
#   In all non-noauth, non-listfail modes: `gh issue create` logs its args and echoes a fake URL
#   (except createfail).
mk_gh_stub() {
  local box="$1" mode="${2:-nomatch}" sigpat="${3:-}" labelmode="${4:-exists}"
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
        json)  for _f in ${_a//,/ }; do case "$_f" in state|body) ;; *) echo "gh stub: unknown JSON field: $_f" >&2; return 1 ;; esac; done ;;
        limit) case "$_a" in ''|*[!0-9]*|0) echo "gh stub: invalid --limit: $_a" >&2; return 1 ;; esac ;;
        state) case "$_a" in open|closed|all) ;; *) echo "gh stub: invalid --state: $_a" >&2; return 1 ;; esac ;;
      esac
      _sk=""; continue
    fi
    case "$_a" in
      issue|list) ;;
      --repo|--search|--jq) _sk=val ;;
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
      elif [ "$mode" = "createfailsecond" ]; then
        # createfailsecond (kit issue #949 item 4): the FIRST create succeeds, every later one fails
        # — a mixed success/failure run (created=1 failed=1), not all-or-nothing.
        printf '  *" issue create "*) create_alt; exit $? ;;\n'
      else
        printf '  *" issue create "*) printf "https://github.com/r/issues/99\\n"; exit 0 ;;\n'
      fi
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
  "| 1 | d | CLAUDE.md | B1 | new | HIGH |")"
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
  "| 1 | delta text | CLAUDE.md §7 | B1 | new | MEDIUM |")"
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
  "$(printf '| 1 | feature delta | CLAUDE.md | B1 | new | HIGH |\n| 2 | bug delta | CLAUDE.md | B2 | fix | HIGH |\n| 3 | doc delta | CLAUDE.md | B3 | docs | HIGH |')")"
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
TWO_ROWS='| 1 | first delta | CLAUDE.md | B1 | fix | HIGH |
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
  anchor_t4='  _title="$(strip_md_bold "$_delta")"'
  if [[ "$sut_content" == *"$anchor_t4"* ]]; then
    box_t4="$(mkbox teeth-bold)"
    retro_t4="$(mk_retro "$box_t4" target-foo r.md \
      "<!-- review-status: pending -->" \
      "| 1 | **Bold summary sentence.** Detail text explaining the change here. | CLAUDE.md | B1 | new | HIGH |")"
    mutant_t4="$box_t4/research-sdd/toolbelt/stage-retro-issues.sh"
    # Replace the call site so _title gets the raw _delta (bold markers intact).
    printf '%s\n' "${sut_content/"$anchor_t4"/  _title=\"\$_delta\"  # T4-teeth: raw delta}" \
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
      "| 1 | fail delta | CLAUDE.md | B1 | new | HIGH |")"
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
    echo "no-match: retro is '"'"'dismissed'"'"' — all rows shipped" >&2; exit 0
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
  retro_tsym="$(mk_retro "$box_tsym" target-foo r-tsym.md - "| 1 | do a thing | some/file | cite | fix | P2 |")"
  mutant_tsym="$box_tsym/research-sdd/toolbelt/stage-retro-issues.sh"
  sed -e 's/cd -P "\$(dirname "\$0")" \&\& pwd -P/cd "$(dirname "$0")" \&\& pwd/' \
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
      "| 1 | t7 delta | CLAUDE.md | B1 | new | HIGH |")"
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
      "| 1 | t8 delta | CLAUDE.md | B1 | new | HIGH |")"
    mutant_t8="$box_t8/research-sdd/toolbelt/stage-retro-issues.sh"
    printf '%s\n' "${sut_content/"$anchor_t8"/gh issue list --state all \\}" > "$mutant_t8"
    bash -n "$mutant_t8" 2>/dev/null || { no "T8 teeth: mutant_t8 failed bash -n syntax check" ""; }
    out_t8="$(PATH="$box_t8/bin:$PATH" \
      "$BASH_BIN" "$mutant_t8" "$retro_t8" --apply 2>&1)"; rc_t8=$?
    list_line_t8="$(grep 'issue list' "$box_t8/bin/gh.log" 2>/dev/null || true)"
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
      "| 1 | t9 delta | CLAUDE.md | B1 | new | HIGH |")"
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
      "| 1 | t10 delta | CLAUDE.md | B1 | new | HIGH |")"
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
      "| 1 | t11 delta | CLAUDE.md | B1 | new | HIGH |")"
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
      "| 1 | t12 delta | CLAUDE.md | B1 | new | HIGH |")"
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
      "| 1 | t13 delta | CLAUDE.md | B1 | new | HIGH |")"
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
      "| 1 | t14 delta | CLAUDE.md | B1 | new | HIGH |")"
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
      "| 1 | t15 delta | CLAUDE.md | B1 | new | HIGH |")"
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
      "| 1 | t16 delta | CLAUDE.md | B1 | new | HIGH |")"
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
      "| 1 | t20 delta | CLAUDE.md | B1 | new | HIGH |")"
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
      "| 1 | t21 delta | CLAUDE.md | B1 | new | HIGH |")"
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
      "| 1 | t22 delta | CLAUDE.md | B1 | new | HIGH |")"
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
      "| 1 | t23 delta | CLAUDE.md | B1 | new | HIGH |")"
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
      "| 1 | t23b delta | CLAUDE.md | B1 | new | HIGH |")"
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
      "| 1 | t17 delta | CLAUDE.md | B1 | new | HIGH |")"
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
      "| 1 | t18 delta | CLAUDE.md | B1 | new | HIGH |")"
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
      "| 1 | t19 delta | CLAUDE.md | B1 | new | HIGH |")"
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
  anchor_h2='echo "unclassifiable: delta section found but contains neither row-table rows nor '"'"'### D<N> —'"'"' entries in $retro — needs manual review, no issue auto-staged" >&2'
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
    if ! grep -qi 'unclassifiable' <<<"$out_h2"; then
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
      printf '| 1 | delta uno | CLAUDE.md | B1 | new | HIGH |\n'
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
    "| 1 | outer delta | CLAUDE.md | B1 | fix | HIGH |")"
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
    "| 1 | flat delta | CLAUDE.md | B1 | fix | HIGH |")"
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
  if tooth_swap "$box_x1" stage-retro-issues.sh 'if (ln == sig)' 'if (1)'; then
    run_box "$box_x1" "$box_x1/rh/target-foo/retros/r-x.md" --apply
    if ! grep -q 'issue create' "$box_x1/bin/gh.log" 2>/dev/null; then
      ok "T1304-1 teeth: equality removed → another target's issue suppresses the create (case 9e-1 has teeth)" "()"
    else
      no "T1304-1 teeth: equality removed" "case 9e-1 is THEATER: out=[$MOUT]"
    fi
  fi
  echo "-- teeth T1304-2: signature compared as a PREFIX (row 3 matches row 30) --"
  box_x2="$(xbox teeth-exact-prefix fuzzylongid)"
  if tooth_swap "$box_x2" stage-retro-issues.sh 'if (ln == sig)' 'if (index(ln, sig) == 1)'; then
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
    "| 1 | fail delta | CLAUDE.md | B1 | new | HIGH |")"
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
    "| 1 | fail delta | CLAUDE.md | B1 | new | HIGH |")"
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
      printf '<!-- review-status: pending -->\n# r\n\n## Proposed kit deltas\n\n### **D1** — bold id\n\n### D2 — plain id\n' > "$r"
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
    printf '<!-- review-status: pending -->\n# r\n\n## Proposed kit deltas\n\n| # | Proposed change | Target (file) | Evidence | Type | Priority |\n|---|---|---|---|---|---|\n| 1 | a | CLAUDE.md | B1 | fix | HIGH |\n' > "$mbox79/rh/other-kit/retros/r.md"
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
    printf '<!-- review-status: pending -->\n# r\n\n## Proposed kit deltas\n\n| # | Proposed change | Target (file) | Evidence | Type | Priority |\n|---|---|---|---|---|---|\n| 1 | real row | CLAUDE.md | B1 | fix | HIGH |\n\n```markdown\n| 2 | fenced example row | CLAUDE.md | B2 | fix | LOW |\n```\n' > "$MBOX/rh/target-foo/retros/r.md"
    run "$MBOX" "$MBOX/rh/target-foo/retros/r.md"
    if [ "$(grep -c '^planned-issue:' <<<"$OUT")" = 2 ]; then ok "T1369-fence teeth: table awk bypasses defenced → fenced row seeded (80a has teeth)" "()"
    else no "T1369-fence teeth: bypassing fence tracking must flip 80a" "80a is THEATER: out=[$OUT]"; fi
  fi
  if stg_mutant nolimit nomatch -e 's/^      --limit "\$_LIST_LIMIT" --search "\\"\$_search_sig\\"" /      --search "\\"$_search_sig\\"" /'; then
    run "$MBOX" "$(mk_retro "$MBOX" target-foo r.md '<!-- review-status: pending -->' '| 1 | a | CLAUDE.md | B1 | fix | HIGH |')" --apply
    if ! grep -qE 'gh issue list .*--limit [0-9]+' "$MBOX/bin/gh.log"; then ok "T1369-limit teeth: --limit dropped → no explicit limit on the dedup call (81a has teeth)" "()"
    else no "T1369-limit teeth: dropping --limit must flip 81a" "81a is THEATER"; fi
  fi
  full_mutant() {   # full_mutant <tag> <sed-expr>: page2 stub, limit 2 → 81b must stop failing
    if stg_mutant "$1" page2 -e "$2"; then
      STAGE_RETRO_ISSUES_LIST_LIMIT=2 run "$MBOX" "$(mk_retro "$MBOX" target-foo r.md '<!-- review-status: pending -->' '| 1 | a | CLAUDE.md | B1 | fix | HIGH |')" --apply
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
    _mr="$(mk_retro "$MBOX" target-foo r.md '<!-- review-status: pending -->' '| 1 | a | CLAUDE.md | B1 | fix | HIGH |')"
    chmod 000 "$_mr"; run "$MBOX" "$_mr"; chmod 600 "$_mr"
    if ! grep -q '^degraded: retro not readable' <<<"$OUT"; then ok "T1403-unreadable teeth: stage check removed → no typed degraded (82a has teeth)" "()"
    else no "T1403-unreadable teeth: removing the check must flip 82a" "82a is THEATER: out=[$OUT]"; fi
  fi
  warn_once() {   # warn_once <tag>: MBOX holds a mutant; 82b's retro must now produce != 1 WARN lines
    local r="$MBOX/rh/target-foo/retros/r.md" n
    printf '<!-- review-status: pending -->\n# r\n\n## Proposed kit deltas\n\n### D1 — one\n\n```\n### D2 — two\n' > "$r"
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
  "$(printf '| 1 | first delta | CLAUDE.md | B1 | new | HIGH |\n| 2 | second delta | CLAUDE.md | B2 | fix | LOW |')")"
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
  "| 1 | only delta | CLAUDE.md | B1 | new | HIGH |")"
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
  "$(printf '| 1 | first delta | CLAUDE.md | B1 | new | HIGH |\n| 2 | second delta | CLAUDE.md | B2 | fix | LOW |')")"
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

# ---------------------------------------------------------------------------
# kit issue #1024 round 3, MEDIUM: symlinked toolbelt (render dir)
# ---------------------------------------------------------------------------
# Same class of bug as reconcile-issues.sh (both climb "../.." via cd without -P). Here the
# symptom is subtler: TARGETS_MD points at a nonexistent path, so the per-retro target lookup
# silently falls back to basename and WARNs "target directory ... not found" — reproduced against
# the pre-fix SUT with this exact fixture.
box_sym="$(mkbox symlink-toolbelt)"
retro_sym="$(mk_retro "$box_sym" target-foo r-sym.md - "| 1 | do a thing | some/file | cite | fix | P2 |")"
mkdir -p "$box_sym/research-sdd/profile/general"
ln -s "$box_sym/research-sdd/toolbelt" "$box_sym/research-sdd/profile/general/toolbelt"
OUT_SYM="$(PATH="$box_sym/bin:$PATH" "$BASH_BIN" \
  "$box_sym/research-sdd/profile/general/toolbelt/stage-retro-issues.sh" "$retro_sym" 2>&1)"; RC_SYM=$?
# kit issue #1024 round 4, item 5: assert the exit code explicitly, not just the absence of the
# negative-signal text — a wrong-reason nonzero exit would otherwise slip through this check.
if [ "$RC_SYM" -eq 0 ] && ! grep -qi 'target directory.*not found' <<<"$OUT_SYM"; then
  ok "SYMLINK-TOOLBELT: invoked through a symlinked toolbelt/, TARGETS.md target lookup still resolves (exit 0)" \
     "(rc=$RC_SYM)"
else
  no "SYMLINK-TOOLBELT: TARGETS.md target lookup failed through a symlinked toolbelt/ (or wrong exit code)" \
     "(rc=$RC_SYM out=[$OUT_SYM])"
fi

# ---------------------------------------------------------------------------
# kit issue #1037: gh calls must target the KIT repo explicitly, never
# whatever repo the process cwd (the retro-gate.sh Stop hook's TARGET
# directory) happens to resolve to.
# ---------------------------------------------------------------------------

# 19 — REPO FLAG ON EVERY GH CALL, CWD-INDEPENDENT: the kit root gets its own git
# remote; a SEPARATE foreign-target repo (its own remote) plays the role of the
# Stop hook's process cwd. Both gh calls made during --apply must carry
# --repo <kit-owner>/<kit-name> — never the foreign target's remote, never omitted.
box="$(mkbox case-repo-flag)"
mk_git_remote "$box" "https://github.com/kit-owner/kit-repo.git"
mk_gh_stub "$box" nomatch
retro="$(mk_retro "$box" target-foo r-repoflag.md \
  "<!-- review-status: pending -->" \
  "| 1 | needs an issue | CLAUDE.md §7 | B1 | new | HIGH |")"
foreign_cwd_19="$ROOT/foreign-target-19"
mk_foreign_repo "$foreign_cwd_19" "https://github.com/foreign-owner/foreign-target.git"
OUT19="$( (cd "$foreign_cwd_19" && PATH="$box/bin:$PATH" \
  "$BASH_BIN" "$box/research-sdd/toolbelt/stage-retro-issues.sh" "$retro" --apply) 2>&1)"; RC19=$?
list_has_repo=0; create_has_repo=0; foreign_leaked=0
if [ -f "$box/bin/gh.log" ]; then
  grep -q 'issue list --repo kit-owner/kit-repo' "$box/bin/gh.log" && list_has_repo=1
  grep -q 'issue create --repo kit-owner/kit-repo' "$box/bin/gh.log" && create_has_repo=1
  grep -q 'foreign-owner' "$box/bin/gh.log" && foreign_leaked=1
fi
if [ "$RC19" = 0 ] && [ "$list_has_repo" = 1 ] && [ "$create_has_repo" = 1 ] && [ "$foreign_leaked" = 0 ]; then
  ok "19 repo flag on every gh call: kit remote used, cwd-independent, no foreign leak" "(exit $RC19)"
else
  no "19 repo flag on every gh call: kit remote used, cwd-independent, no foreign leak" \
    "exit=$RC19 list=$list_has_repo create=$create_has_repo foreign_leak=$foreign_leaked out=[$OUT19] log=[$(cat "$box/bin/gh.log" 2>/dev/null)]"
fi

# ---------------------------------------------------------------------------
# 20 — ENV OVERRIDE WINS: RESEARCH_SDD_ISSUE_REPO takes precedence over a
# configured git remote at the kit root.
box="$(mkbox case-env-override)"
mk_git_remote "$box" "https://github.com/kit-owner/kit-repo.git"
mk_gh_stub "$box" nomatch
retro="$(mk_retro "$box" target-foo r-override.md \
  "<!-- review-status: pending -->" \
  "| 1 | env override delta | CLAUDE.md | B1 | new | HIGH |")"
OUT20="$(PATH="$box/bin:$PATH" RESEARCH_SDD_ISSUE_REPO="override-owner/override-kit" \
  "$BASH_BIN" "$box/research-sdd/toolbelt/stage-retro-issues.sh" "$retro" --apply 2>&1)"; RC20=$?
override_used=0; git_remote_leaked=0
if [ -f "$box/bin/gh.log" ]; then
  grep -q 'issue create --repo override-owner/override-kit' "$box/bin/gh.log" && override_used=1
  grep -q 'kit-owner/kit-repo' "$box/bin/gh.log" && git_remote_leaked=1
fi
if [ "$RC20" = 0 ] && [ "$override_used" = 1 ] && [ "$git_remote_leaked" = 0 ]; then
  ok "20 env override wins over configured git remote" "(exit $RC20)"
else
  no "20 env override wins over configured git remote" \
    "exit=$RC20 override_used=$override_used remote_leaked=$git_remote_leaked out=[$OUT20]"
fi

# ---------------------------------------------------------------------------
# 21 — DERIVE FROM GIT REMOTE (https form): dry-run prints the resolved
# kit-issue-repo line, normalized from an https:// origin with a .git suffix.
box="$(mkbox case-derive-https)"
mk_git_remote "$box" "https://github.com/deriv-owner/deriv-kit.git"
retro="$(mk_retro "$box" target-foo r-derive-https.md \
  "<!-- review-status: pending -->" \
  "| 1 | derive https delta | CLAUDE.md | B1 | new | HIGH |")"
OUT21="$(PATH="$box/bin:$PATH" \
  "$BASH_BIN" "$box/research-sdd/toolbelt/stage-retro-issues.sh" "$retro" 2>&1)"; RC21=$?
if [ "$RC21" = 0 ] && grep -q '^kit-issue-repo: deriv-owner/deriv-kit$' <<<"$OUT21"; then
  ok "21 derive from git remote (https): kit-issue-repo printed in dry-run" "(exit $RC21)"
else
  no "21 derive from git remote (https): kit-issue-repo printed in dry-run" "exit=$RC21 out=[$OUT21]"
fi

# ---------------------------------------------------------------------------
# 22 — DERIVE FROM GIT REMOTE (scp-like ssh form: git@host:owner/name.git)
box="$(mkbox case-derive-ssh)"
mk_git_remote "$box" "git@github.com:ssh-owner/ssh-kit.git"
retro="$(mk_retro "$box" target-foo r-derive-ssh.md \
  "<!-- review-status: pending -->" \
  "| 1 | derive ssh delta | CLAUDE.md | B1 | new | HIGH |")"
OUT22="$(PATH="$box/bin:$PATH" \
  "$BASH_BIN" "$box/research-sdd/toolbelt/stage-retro-issues.sh" "$retro" 2>&1)"; RC22=$?
if [ "$RC22" = 0 ] && grep -q '^kit-issue-repo: ssh-owner/ssh-kit$' <<<"$OUT22"; then
  ok "22 derive from git remote (scp-like ssh): kit-issue-repo printed in dry-run" "(exit $RC22)"
else
  no "22 derive from git remote (scp-like ssh): kit-issue-repo printed in dry-run" "exit=$RC22 out=[$OUT22]"
fi

# ---------------------------------------------------------------------------
# 23 — UNRESOLVABLE REPO UNDER --apply: no env override, no git remote at the
# kit root, cwd is a foreign target repo → typed degraded line, non-zero exit,
# ZERO gh issue calls recorded (never fall back to the cwd/target repo).
box="$(mkbox case-unresolved-apply)"
mk_gh_stub "$box" nomatch
retro="$(mk_retro "$box" target-foo r-unresolved.md \
  "<!-- review-status: pending -->" \
  "| 1 | should never create | CLAUDE.md | B1 | new | HIGH |")"
foreign_cwd_23="$ROOT/foreign-target-23"
mk_foreign_repo "$foreign_cwd_23" "https://github.com/foreign-owner/foreign-target.git"
OUT23="$( (cd "$foreign_cwd_23" && PATH="$box/bin:$PATH" \
  "$BASH_BIN" "$box/research-sdd/toolbelt/stage-retro-issues.sh" "$retro" --apply) 2>&1)"; RC23=$?
gh_called=0
[ -f "$box/bin/gh.log" ] && grep -q 'issue' "$box/bin/gh.log" && gh_called=1
if [ "$RC23" != 0 ] && grep -qi 'degraded' <<<"$OUT23" \
   && grep -qi 'cannot resolve' <<<"$OUT23" \
   && [ "$gh_called" = 0 ]; then
  ok "23 unresolvable repo under --apply: degraded, non-zero exit, zero gh issue calls" "(exit $RC23)"
else
  no "23 unresolvable repo under --apply: degraded, non-zero exit, zero gh issue calls" \
    "exit=$RC23 gh_called=$gh_called out=[$OUT23]"
fi

# ---------------------------------------------------------------------------
# kit issue #1045: harden resolve_kit_issue_repo() past #1037/#1042.
# ---------------------------------------------------------------------------

# 24 — F1 ENCLOSING-REPO WALK (dry-run): KIT_ROOT itself is NOT a git checkout
# (no .git of its own), but its PARENT directory is a repo with its own
# origin. A logical `git remote get-url origin` walks up and would return the
# enclosing repo's origin — resolve_kit_issue_repo() must refuse (unresolved),
# never the enclosing repo's value.
enclosing_parent_24="$ROOT/case-f1-enclosing-parent"
mkdir -p "$enclosing_parent_24"
git init -q "$enclosing_parent_24" >/dev/null 2>&1
git -C "$enclosing_parent_24" remote add origin \
  "https://github.com/enclosing-owner/enclosing-repo.git" >/dev/null 2>&1
box24="$(mkbox_at "$enclosing_parent_24" nested-kit)"
retro24="$(mk_retro "$box24" target-foo r-f1.md \
  "<!-- review-status: pending -->" \
  "| 1 | f1 delta | CLAUDE.md | B1 | new | HIGH |")"
OUT24="$(PATH="$box24/bin:$PATH" RESEARCH_SDD_ISSUE_REPO="" \
  "$BASH_BIN" "$box24/research-sdd/toolbelt/stage-retro-issues.sh" "$retro24" 2>&1)"; RC24=$?
# The reason text is allowed to explain that an enclosing repo was found; what
# must never leak is the enclosing repo's OWNER/NAME being used as the value.
if [ "$RC24" = 0 ] && grep -q '^kit-issue-repo: unresolved' <<<"$OUT24" \
   && ! grep -q '^kit-issue-repo: enclosing-owner/enclosing-repo$' <<<"$OUT24"; then
  ok "24 F1 enclosing-repo walk (dry-run): unresolved, enclosing origin never surfaces" "(exit $RC24)"
else
  no "24 F1 enclosing-repo walk (dry-run): unresolved, enclosing origin never surfaces" \
    "exit=$RC24 out=[$OUT24]"
fi

# 25 — F1 ENCLOSING-REPO WALK (--apply): same fixture, --apply must refuse
# BEFORE any gh call, and the enclosing repo's owner/name must never leak into
# stdout/stderr (never used as the target repo).
box25="$(mkbox_at "$enclosing_parent_24" nested-kit-apply)"
mk_gh_stub "$box25" nomatch
retro25="$(mk_retro "$box25" target-foo r-f1-apply.md \
  "<!-- review-status: pending -->" \
  "| 1 | f1 apply delta | CLAUDE.md | B1 | new | HIGH |")"
OUT25="$(PATH="$box25/bin:$PATH" RESEARCH_SDD_ISSUE_REPO="" \
  "$BASH_BIN" "$box25/research-sdd/toolbelt/stage-retro-issues.sh" "$retro25" --apply 2>&1)"; RC25=$?
gh_called_25=0
[ -f "$box25/bin/gh.log" ] && grep -q 'issue' "$box25/bin/gh.log" && gh_called_25=1
# The reason text is allowed to explain that an enclosing repo was found; what
# must never leak is the enclosing repo's OWNER/NAME being used as the value.
if [ "$RC25" != 0 ] && grep -qi 'degraded' <<<"$OUT25" \
   && ! grep -q 'enclosing-owner/enclosing-repo' <<<"$OUT25" \
   && [ "$gh_called_25" = 0 ]; then
  ok "25 F1 enclosing-repo walk (--apply): degraded before any gh call, no leak" "(exit $RC25)"
else
  no "25 F1 enclosing-repo walk (--apply): degraded before any gh call, no leak" \
    "exit=$RC25 gh_called=$gh_called_25 out=[$OUT25]"
fi

# ---------------------------------------------------------------------------
# 26 — F2 SHAPE VALIDATION (override): a RESEARCH_SDD_ISSUE_REPO override that
# does not match `[host/]owner/repo` must resolve to unresolved (dry-run) /
# typed degraded + exit 1 BEFORE any gh call (--apply), never pass through.
box26="$(mkbox case-f2-shape-override)"
mk_gh_stub "$box26" nomatch
retro26="$(mk_retro "$box26" target-foo r-f2.md \
  "<!-- review-status: pending -->" \
  "| 1 | f2 delta | CLAUDE.md | B1 | new | HIGH |")"
f2_bad_values=(
  "foo"
  "a b/c"
  "o/n/x/y"
  "file:///srv/git/n.git"
)
f2_idx=0
for f2_bad in "${f2_bad_values[@]}"; do
  f2_idx=$((f2_idx+1))
  f2_out_dry="$(PATH="$box26/bin:$PATH" RESEARCH_SDD_ISSUE_REPO="$f2_bad" \
    "$BASH_BIN" "$box26/research-sdd/toolbelt/stage-retro-issues.sh" "$retro26" 2>&1)"; f2_rc_dry=$?
  : > "$box26/bin/gh.log"
  f2_out_apply="$(PATH="$box26/bin:$PATH" RESEARCH_SDD_ISSUE_REPO="$f2_bad" \
    "$BASH_BIN" "$box26/research-sdd/toolbelt/stage-retro-issues.sh" "$retro26" --apply 2>&1)"; f2_rc_apply=$?
  f2_gh_called=0
  [ -f "$box26/bin/gh.log" ] && grep -q 'issue' "$box26/bin/gh.log" && f2_gh_called=1
  if [ "$f2_rc_dry" = 0 ] && grep -q '^kit-issue-repo: unresolved' <<<"$f2_out_dry" \
     && [ "$f2_rc_apply" != 0 ] && grep -qi 'degraded' <<<"$f2_out_apply" \
     && [ "$f2_gh_called" = 0 ]; then
    ok "26.$f2_idx F2 shape-invalid override '$f2_bad' → unresolved/degraded, zero gh calls" \
      "(dry=$f2_rc_dry apply=$f2_rc_apply)"
  else
    no "26.$f2_idx F2 shape-invalid override '$f2_bad' → unresolved/degraded, zero gh calls" \
      "dry_rc=$f2_rc_dry dry_out=[$f2_out_dry] apply_rc=$f2_rc_apply apply_out=[$f2_out_apply] gh_called=$f2_gh_called"
  fi
done

# 27 — F2 SHAPE VALIDATION (derived): a git remote whose normalized value does
# not match `[host/]owner/repo` (e.g. a file:// origin) must also resolve to
# unresolved/degraded, never reach gh with a bogus --repo value.
box27="$(mkbox case-f2-shape-derived)"
git init -q "$box27" >/dev/null 2>&1
git -C "$box27" remote add origin "file:///srv/git/n.git" >/dev/null 2>&1
mk_gh_stub "$box27" nomatch
retro27="$(mk_retro "$box27" target-foo r-f2-derived.md \
  "<!-- review-status: pending -->" \
  "| 1 | f2 derived delta | CLAUDE.md | B1 | new | HIGH |")"
OUT27="$(PATH="$box27/bin:$PATH" RESEARCH_SDD_ISSUE_REPO="" \
  "$BASH_BIN" "$box27/research-sdd/toolbelt/stage-retro-issues.sh" "$retro27" 2>&1)"; RC27=$?
: > "$box27/bin/gh.log"
OUT27B="$(PATH="$box27/bin:$PATH" RESEARCH_SDD_ISSUE_REPO="" \
  "$BASH_BIN" "$box27/research-sdd/toolbelt/stage-retro-issues.sh" "$retro27" --apply 2>&1)"; RC27B=$?
gh_called_27=0
[ -f "$box27/bin/gh.log" ] && grep -q 'issue' "$box27/bin/gh.log" && gh_called_27=1
if [ "$RC27" = 0 ] && grep -q '^kit-issue-repo: unresolved' <<<"$OUT27" \
   && [ "$RC27B" != 0 ] && grep -qi 'degraded' <<<"$OUT27B" \
   && [ "$gh_called_27" = 0 ]; then
  ok "27 F2 shape-invalid derived (file:// origin) → unresolved/degraded, zero gh calls" \
    "(dry=$RC27 apply=$RC27B)"
else
  no "27 F2 shape-invalid derived (file:// origin) → unresolved/degraded, zero gh calls" \
    "dry_rc=$RC27 dry_out=[$OUT27] apply_rc=$RC27B apply_out=[$OUT27B] gh_called=$gh_called_27"
fi

# ---------------------------------------------------------------------------
# 28 — F3 NORMALIZATION: trailing slash stripped BEFORE the .git suffix.
# "https://github.com/o/n.git/" must resolve to "o/n", not "o/n.git" or
# unresolved.
box28="$(mkbox case-f3-slash-before-git)"
mk_git_remote "$box28" "https://github.com/o/n.git/"
retro28="$(mk_retro "$box28" target-foo r-f3-slash.md \
  "<!-- review-status: pending -->" \
  "| 1 | f3 slash delta | CLAUDE.md | B1 | new | HIGH |")"
OUT28="$(PATH="$box28/bin:$PATH" \
  "$BASH_BIN" "$box28/research-sdd/toolbelt/stage-retro-issues.sh" "$retro28" 2>&1)"; RC28=$?
if [ "$RC28" = 0 ] && grep -q '^kit-issue-repo: o/n$' <<<"$OUT28"; then
  ok "28 F3 trailing slash before .git: 'o/n.git/' -> 'o/n'" "(exit $RC28)"
else
  no "28 F3 trailing slash before .git: 'o/n.git/' -> 'o/n'" "exit=$RC28 out=[$OUT28]"
fi

# 29 — F3 NORMALIZATION: scp form WITHOUT user@ (e.g. "github.com:o/n").
box29="$(mkbox case-f3-scp-no-user)"
mk_git_remote "$box29" "github.com:scp-owner/scp-kit"
retro29="$(mk_retro "$box29" target-foo r-f3-scp.md \
  "<!-- review-status: pending -->" \
  "| 1 | f3 scp delta | CLAUDE.md | B1 | new | HIGH |")"
OUT29="$(PATH="$box29/bin:$PATH" \
  "$BASH_BIN" "$box29/research-sdd/toolbelt/stage-retro-issues.sh" "$retro29" 2>&1)"; RC29=$?
if [ "$RC29" = 0 ] && grep -q '^kit-issue-repo: scp-owner/scp-kit$' <<<"$OUT29"; then
  ok "29 F3 scp form without user@: 'github.com:o/n' -> 'o/n'" "(exit $RC29)"
else
  no "29 F3 scp form without user@: 'github.com:o/n' -> 'o/n'" "exit=$RC29 out=[$OUT29]"
fi

# 30 — F3 NORMALIZATION: non-github.com host (GHE) is KEPT as "HOST/o/n" (gh
# accepts HOST/OWNER/REPO).
box30="$(mkbox case-f3-ghe-host)"
mk_git_remote "$box30" "https://ghe.corp.example.com/ghe-owner/ghe-kit.git"
retro30="$(mk_retro "$box30" target-foo r-f3-ghe.md \
  "<!-- review-status: pending -->" \
  "| 1 | f3 ghe delta | CLAUDE.md | B1 | new | HIGH |")"
OUT30="$(PATH="$box30/bin:$PATH" \
  "$BASH_BIN" "$box30/research-sdd/toolbelt/stage-retro-issues.sh" "$retro30" 2>&1)"; RC30=$?
if [ "$RC30" = 0 ] && grep -q '^kit-issue-repo: ghe.corp.example.com/ghe-owner/ghe-kit$' <<<"$OUT30"; then
  ok "30 F3 non-github.com host kept: 'HOST/o/n' preserved for GHE" "(exit $RC30)"
else
  no "30 F3 non-github.com host kept: 'HOST/o/n' preserved for GHE" "exit=$RC30 out=[$OUT30]"
fi

# ---------------------------------------------------------------------------
# 31 — GIT MISSING (dry-run): no override, git absent from PATH → typed
# degraded reason naming git, printed inline in the dry-run unresolved line.
box31="$(mkbox case-vcs-missing-dry)"
mk_hermetic_bin "$box31"
retro31="$(mk_retro "$box31" target-foo r-vcs-missing.md \
  "<!-- review-status: pending -->" \
  "| 1 | vcs missing delta | CLAUDE.md | B1 | new | HIGH |")"
OUT31="$(PATH="$box31/bin" RESEARCH_SDD_ISSUE_REPO="" \
  "$BASH_BIN" "$box31/research-sdd/toolbelt/stage-retro-issues.sh" "$retro31" 2>&1)"; RC31=$?
# Isolate the kit-issue-repo LINE specifically — the row body/title text is
# attacker-controlled fixture prose and must not be able to false-positive
# this assertion by coincidentally containing the word "git".
kir_line31="$(grep '^kit-issue-repo: unresolved' <<<"$OUT31")"
if [ "$RC31" = 0 ] && [ -n "$kir_line31" ] && grep -qi 'git not found' <<<"$kir_line31"; then
  ok "31 git missing (dry-run): unresolved reason names git" "(exit $RC31)"
else
  no "31 git missing (dry-run): unresolved reason names git" "exit=$RC31 line=[$kir_line31] out=[$OUT31]"
fi

# 32 — GIT MISSING (--apply): gh IS present (probe passes) but git is absent
# → typed degraded message naming git, exit 1, zero gh issue calls.
box32="$(mkbox case-vcs-absent-apply)"
mk_gh_stub "$box32" nomatch
mk_no_git_bin "$box32"
retro32="$(mk_retro "$box32" target-foo r-vcs-absent-apply.md \
  "<!-- review-status: pending -->" \
  "| 1 | vcs absent apply delta | CLAUDE.md | B1 | new | HIGH |")"
OUT32="$(PATH="$box32/nogit-bin" RESEARCH_SDD_ISSUE_REPO="" \
  "$BASH_BIN" "$box32/research-sdd/toolbelt/stage-retro-issues.sh" "$retro32" --apply 2>&1)"; RC32=$?
gh_called_32=0
[ -f "$box32/bin/gh.log" ] && grep -q 'issue' "$box32/bin/gh.log" && gh_called_32=1
if [ "$RC32" != 0 ] && grep -qi 'degraded' <<<"$OUT32" \
   && grep -qi 'git not found' <<<"$OUT32" && [ "$gh_called_32" = 0 ]; then
  ok "32 git missing (--apply): degraded names git, exit 1, zero gh calls" "(exit $RC32)"
else
  no "32 git missing (--apply): degraded names git, exit 1, zero gh calls" \
    "exit=$RC32 gh_called=$gh_called_32 out=[$OUT32]"
fi

# ---------------------------------------------------------------------------
# kit issue #1046 round 2: SSH host aliases, ports, shape tightening, the
# lost-bad-value subshell bug, and the F1 reason wording.
# ---------------------------------------------------------------------------

# derive_dry <box> <url>: git-init <box> with origin <url>, run a plain
# dry-run (no override), and set OUT/RC. Small helper to keep cases 33-42
# terse — they all share this exact shape.
derive_dry() {
  local box="$1" url="$2" tgt="${3:-target-foo}"
  mk_git_remote "$box" "$url"
  local retro
  retro="$(mk_retro "$box" "$tgt" r.md \
    "<!-- review-status: pending -->" \
    "| 1 | delta | CLAUDE.md | B1 | new | HIGH |")"
  OUT="$(PATH="$box/bin:$PATH" "$BASH_BIN" \
    "$box/research-sdd/toolbelt/stage-retro-issues.sh" "$retro" 2>&1)"; RC=$?
}

# 33 — ITEM 1: scp form, SSH config Host alias (no user@) → host ALWAYS
# dropped for scp form, regardless of whether it looks like a github alias.
box33="$(mkbox case-scp-alias)"
derive_dry "$box33" "git@github.com-alias:o/n.git"
if [ "$RC" = 0 ] && grep -q '^kit-issue-repo: o/n$' <<<"$OUT"; then
  ok "33 ITEM1 scp alias host dropped: 'git@github.com-alias:o/n.git' -> 'o/n'" "(exit $RC)"
else
  no "33 ITEM1 scp alias host dropped: 'git@github.com-alias:o/n.git' -> 'o/n'" "exit=$RC out=[$OUT]"
fi

# 34 — ITEM 1: URL-scheme, "www." alias prefix → dropped.
box34="$(mkbox case-https-www-alias)"
derive_dry "$box34" "https://www.github.com/o/n"
if [ "$RC" = 0 ] && grep -q '^kit-issue-repo: o/n$' <<<"$OUT"; then
  ok "34 ITEM1 https www. alias dropped: 'https://www.github.com/o/n' -> 'o/n'" "(exit $RC)"
else
  no "34 ITEM1 https www. alias dropped: 'https://www.github.com/o/n' -> 'o/n'" "exit=$RC out=[$OUT]"
fi

# 35 — ITEM 1: URL-scheme, SSH config Host alias suffix → dropped.
box35="$(mkbox case-https-alias-suffix)"
derive_dry "$box35" "https://github.com-alias/o/n.git"
if [ "$RC" = 0 ] && grep -q '^kit-issue-repo: o/n$' <<<"$OUT"; then
  ok "35 ITEM1 https alias-suffix host dropped: 'github.com-alias' -> 'o/n'" "(exit $RC)"
else
  no "35 ITEM1 https alias-suffix host dropped: 'github.com-alias' -> 'o/n'" "exit=$RC out=[$OUT]"
fi

# 36 — ITEM 2: ssh:// scp-style with :port → port stripped, github.com dropped.
box36="$(mkbox case-ssh-port)"
derive_dry "$box36" "ssh://git@github.com:22/o/n.git"
if [ "$RC" = 0 ] && grep -q '^kit-issue-repo: o/n$' <<<"$OUT"; then
  ok "36 ITEM2 ssh:// with :port: 'ssh://git@github.com:22/o/n.git' -> 'o/n'" "(exit $RC)"
else
  no "36 ITEM2 ssh:// with :port: 'ssh://git@github.com:22/o/n.git' -> 'o/n'" "exit=$RC out=[$OUT]"
fi

# 37 — ITEM 2: https:// with :port → port stripped, github.com dropped.
box37="$(mkbox case-https-port)"
derive_dry "$box37" "https://github.com:443/o/n.git"
if [ "$RC" = 0 ] && grep -q '^kit-issue-repo: o/n$' <<<"$OUT"; then
  ok "37 ITEM2 https:// with :port: 'https://github.com:443/o/n.git' -> 'o/n'" "(exit $RC)"
else
  no "37 ITEM2 https:// with :port: 'https://github.com:443/o/n.git' -> 'o/n'" "exit=$RC out=[$OUT]"
fi

# 38 — ITEM 2: ssh:// alias host ("ssh.github.com") WITH :port → both the
# port-strip and the alias check must fire together.
box38="$(mkbox case-ssh-alias-port)"
derive_dry "$box38" "ssh://git@ssh.github.com:443/o/n.git"
if [ "$RC" = 0 ] && grep -q '^kit-issue-repo: o/n$' <<<"$OUT"; then
  ok "38 ITEM2 ssh alias host with :port: 'ssh.github.com:443' -> 'o/n'" "(exit $RC)"
else
  no "38 ITEM2 ssh alias host with :port: 'ssh.github.com:443' -> 'o/n'" "exit=$RC out=[$OUT]"
fi

# 39 — ITEM 2 (non-github host): a real GHE host with :port keeps the HOST
# (port stripped, hostname retained) — proves port-stripping isn't
# github-specific.
box39="$(mkbox case-ghe-port)"
derive_dry "$box39" "https://ghe.corp.com:8443/o/n.git"
if [ "$RC" = 0 ] && grep -q '^kit-issue-repo: ghe.corp.com/o/n$' <<<"$OUT"; then
  ok "39 ITEM2 GHE host with :port: 'ghe.corp.com:8443' -> 'ghe.corp.com/o/n'" "(exit $RC)"
else
  no "39 ITEM2 GHE host with :port: 'ghe.corp.com:8443' -> 'ghe.corp.com/o/n'" "exit=$RC out=[$OUT]"
fi

# ---------------------------------------------------------------------------
# KEEP regressions (explicit): these three forms must NOT change behaviour.
# 40 — real origin, scp form, user@.
box40="$(mkbox case-keep-real-origin)"
derive_dry "$box40" "git@github.com:angeles725/sdd-investigacion.git"
if [ "$RC" = 0 ] && grep -q '^kit-issue-repo: angeles725/sdd-investigacion$' <<<"$OUT"; then
  ok "40 KEEP real origin scp: 'git@github.com:angeles725/sdd-investigacion.git' unchanged" "(exit $RC)"
else
  no "40 KEEP real origin scp: 'git@github.com:angeles725/sdd-investigacion.git' unchanged" "exit=$RC out=[$OUT]"
fi

# 41 — mixed-case host, underscore/dot in owner/repo.
box41="$(mkbox case-keep-mixedcase)"
derive_dry "$box41" "https://GitHub.com/My_Org/Repo.Name.git"
if [ "$RC" = 0 ] && grep -q '^kit-issue-repo: My_Org/Repo.Name$' <<<"$OUT"; then
  ok "41 KEEP mixed-case host + owner/repo: 'GitHub.com/My_Org/Repo.Name.git' -> 'My_Org/Repo.Name'" "(exit $RC)"
else
  no "41 KEEP mixed-case host + owner/repo: 'GitHub.com/My_Org/Repo.Name.git' -> 'My_Org/Repo.Name'" "exit=$RC out=[$OUT]"
fi

# 42 — GHE https, no port, host kept verbatim.
box42="$(mkbox case-keep-ghe)"
derive_dry "$box42" "https://ghe.corp.com/o/n.git"
if [ "$RC" = 0 ] && grep -q '^kit-issue-repo: ghe.corp.com/o/n$' <<<"$OUT"; then
  ok "42 KEEP GHE https: 'https://ghe.corp.com/o/n.git' -> 'ghe.corp.com/o/n'" "(exit $RC)"
else
  no "42 KEEP GHE https: 'https://ghe.corp.com/o/n.git' -> 'ghe.corp.com/o/n'" "exit=$RC out=[$OUT]"
fi

# ---------------------------------------------------------------------------
# ITEM 4 — tightened shape: owner/repo/host segments must START with
# [A-Za-z0-9]; this alone rejects a bare '.'/'..' segment and a leading '-'.
box_shape="$(mkbox case-item4-shape)"
mk_gh_stub "$box_shape" nomatch
retro_shape="$(mk_retro "$box_shape" target-foo r-shape.md \
  "<!-- review-status: pending -->" \
  "| 1 | shape delta | CLAUDE.md | B1 | new | HIGH |")"
shape_bad_values=(
  "../o/n"
  "-o/n"
  "o/.."
)
shape_idx=0
for shape_bad in "${shape_bad_values[@]}"; do
  shape_idx=$((shape_idx+1))
  shape_out_dry="$(PATH="$box_shape/bin:$PATH" RESEARCH_SDD_ISSUE_REPO="$shape_bad" \
    "$BASH_BIN" "$box_shape/research-sdd/toolbelt/stage-retro-issues.sh" "$retro_shape" 2>&1)"; shape_rc_dry=$?
  : > "$box_shape/bin/gh.log"
  shape_out_apply="$(PATH="$box_shape/bin:$PATH" RESEARCH_SDD_ISSUE_REPO="$shape_bad" \
    "$BASH_BIN" "$box_shape/research-sdd/toolbelt/stage-retro-issues.sh" "$retro_shape" --apply 2>&1)"; shape_rc_apply=$?
  shape_gh_called=0
  [ -f "$box_shape/bin/gh.log" ] && grep -q 'issue' "$box_shape/bin/gh.log" && shape_gh_called=1
  if [ "$shape_rc_dry" = 0 ] && grep -q "^kit-issue-repo: unresolved (invalid repo shape '${shape_bad}'" <<<"$shape_out_dry" \
     && [ "$shape_rc_apply" != 0 ] && grep -qi 'degraded' <<<"$shape_out_apply" \
     && [ "$shape_gh_called" = 0 ]; then
    ok "43.$shape_idx ITEM4 shape-tightening rejects '$shape_bad'" "(dry=$shape_rc_dry apply=$shape_rc_apply)"
  else
    no "43.$shape_idx ITEM4 shape-tightening rejects '$shape_bad'" \
      "dry_rc=$shape_rc_dry dry_out=[$shape_out_dry] apply_rc=$shape_rc_apply apply_out=[$shape_out_apply] gh_called=$shape_gh_called"
  fi
done

# 44 — ITEM4 positive control: dots/underscores mid-segment stay ACCEPTED —
# the tightened regex must reject only a BAD leading character, not dots or
# underscores in general.
OUT44="$(PATH="$box_shape/bin:$PATH" RESEARCH_SDD_ISSUE_REPO="My_Org/Repo.Name" \
  "$BASH_BIN" "$box_shape/research-sdd/toolbelt/stage-retro-issues.sh" "$retro_shape" 2>&1)"; RC44=$?
if [ "$RC44" = 0 ] && grep -q '^kit-issue-repo: My_Org/Repo.Name$' <<<"$OUT44"; then
  ok "44 ITEM4 positive control: 'My_Org/Repo.Name' still accepted" "(exit $RC44)"
else
  no "44 ITEM4 positive control: 'My_Org/Repo.Name' still accepted" "exit=$RC44 out=[$OUT44]"
fi

# ---------------------------------------------------------------------------
# 45 — ITEM 3: the degraded/unresolved message must NAME the bad value, not
# print an empty 'invalid repo shape '' — proves resolve_kit_issue_repo() is
# no longer called through a `$(...)` subshell that discards its globals.
box45="$(mkbox case-item3-bad-value-survives)"
retro45="$(mk_retro "$box45" target-foo r-item3.md \
  "<!-- review-status: pending -->" \
  "| 1 | item3 delta | CLAUDE.md | B1 | new | HIGH |")"
OUT45="$(PATH="$box45/bin:$PATH" RESEARCH_SDD_ISSUE_REPO="foo" \
  "$BASH_BIN" "$box45/research-sdd/toolbelt/stage-retro-issues.sh" "$retro45" 2>&1)"; RC45=$?
if [ "$RC45" = 0 ] && grep -q "^kit-issue-repo: unresolved (invalid repo shape 'foo' — expected \[HOST/\]OWNER/REPO)$" <<<"$OUT45"; then
  ok "45 ITEM3 bad value survives the call: message names 'foo', not ''" "(exit $RC45)"
else
  no "45 ITEM3 bad value survives the call: message names 'foo', not ''" "exit=$RC45 out=[$OUT45]"
fi

# ---------------------------------------------------------------------------
# 46 — ITEM 5: the F1 enclosing-repo reason must say the kit root is not the
# git TOPLEVEL (not the vaguer/inaccurate "not its own git checkout"), and
# must name the enclosing checkout's actual root.
enclosing_parent_46="$ROOT/case-item5-enclosing-parent"
mkdir -p "$enclosing_parent_46"
git init -q "$enclosing_parent_46" >/dev/null 2>&1
git -C "$enclosing_parent_46" remote add origin \
  "https://github.com/item5-owner/item5-repo.git" >/dev/null 2>&1
box46="$(mkbox_at "$enclosing_parent_46" nested-kit)"
retro46="$(mk_retro "$box46" target-foo r-item5.md \
  "<!-- review-status: pending -->" \
  "| 1 | item5 delta | CLAUDE.md | B1 | new | HIGH |")"
OUT46="$(PATH="$box46/bin:$PATH" RESEARCH_SDD_ISSUE_REPO="" \
  "$BASH_BIN" "$box46/research-sdd/toolbelt/stage-retro-issues.sh" "$retro46" 2>&1)"; RC46=$?
if [ "$RC46" = 0 ] && grep -qi 'toplevel' <<<"$OUT46" \
   && grep -q "$enclosing_parent_46" <<<"$OUT46"; then
  ok "46 ITEM5 F1 reason names 'toplevel' and the enclosing root path" "(exit $RC46)"
else
  no "46 ITEM5 F1 reason names 'toplevel' and the enclosing root path" "exit=$RC46 out=[$OUT46]"
fi

# ---------------------------------------------------------------------------
# kit issue #949 item 1 — shipped-ID parser: leading '#' strip, trailing
# parenthetical annotations.
# ---------------------------------------------------------------------------

# 47 — HASH-SHIPPED: marker uses '#N (desc)' format; rows 1,2 shipped, row 3 open
# (unlike reconcile-issues.sh, stage-retro-issues.sh never had the '#' strip — #949).
box47="$(mkbox case-hash-shipped)"
retro47="$(mk_retro "$box47" target-foo r-hash-shipped.md \
  "<!-- review-status: applied 2026-09-05 · kit e0b701a · PARTIAL — shipped: #1 (§11 consumer-absence), #2 (§5 slot-vs-derived) -->" \
  "$(printf '| 1 | delta one | METHODOLOGY.md | B1 | new | HIGH |\n| 2 | delta two | METHODOLOGY.md | B2 | new | HIGH |\n| 3 | delta three | METHODOLOGY.md | B3 | new | HIGH |')")"
run "$box47" "$retro47"
row3_47=0; row1_47=0; row2_47=0
grep -q '· 3' <<<"$OUT" && row3_47=1
grep -q '· 1' <<<"$OUT" && row1_47=1
grep -q '· 2' <<<"$OUT" && row2_47=1
if [ "$RC" = 0 ] && [ "$row3_47" = 1 ] && [ "$row1_47" = 0 ] && [ "$row2_47" = 0 ]; then
  ok "47 hash-shipped: '#N (desc)' → rows 1,2 shipped (# stripped), only row 3 open" "(exit $RC)"
else
  no "47 hash-shipped: '#N (desc)' → rows 1,2 shipped (# stripped), only row 3 open" \
    "exit=$RC row1=$row1_47 row2=$row2_47 row3=$row3_47 out=[$OUT]"
fi

# 48 — TRAILING-ANNOTATION-SHIPPED: 'shipped: Δ1 (#549), D1 (§20)' → the
# parenthetical annotations are dropped, leaving ids 'Δ1' and 'D1' shipped; 'D2' stays open.
box48="$(mkbox case-annotation-shipped)"
retro48="$(mk_retro "$box48" target-foo r-annotation-shipped.md \
  "<!-- review-status: applied 2026-09-05 · kit e0b701a · PARTIAL — shipped: Δ1 (#549), D1 (§20) -->" \
  "$(printf '| Δ1 | delta one | METHODOLOGY.md | B1 | new | HIGH |\n| D1 | delta two | METHODOLOGY.md | B2 | new | HIGH |\n| D2 | delta three | METHODOLOGY.md | B3 | new | HIGH |')")"
run "$box48" "$retro48"
d2_48=0; delta1_48=0; d1_48=0
grep -q '· D2' <<<"$OUT" && d2_48=1
grep -q '· Δ1' <<<"$OUT" && delta1_48=1
grep -q '· D1' <<<"$OUT" && d1_48=1
if [ "$RC" = 0 ] && [ "$d2_48" = 1 ] && [ "$delta1_48" = 0 ] && [ "$d1_48" = 0 ]; then
  ok "48 trailing-annotation-shipped: 'Δ1 (#549), D1 (§20)' → Δ1,D1 shipped; only D2 open" "(exit $RC)"
else
  no "48 trailing-annotation-shipped: 'Δ1 (#549), D1 (§20)' → Δ1,D1 shipped; only D2 open" \
    "exit=$RC delta1=$delta1_48 d1=$d1_48 d2=$d2_48 out=[$OUT]"
fi

# ---------------------------------------------------------------------------
# kit issue #1090 — PARTIAL is a status TOKEN, never free text; dismissed always wins.
# ---------------------------------------------------------------------------

# 49 — FREE-TEXT PARTIAL (applied, no structured token): an applied marker whose FREE
# TEXT (after the em dash) happens to contain the literal uppercase word "PARTIAL" must NOT
# be treated as a PARTIAL marker — the structured segment (before the dash) has no such token,
# so this is a fully-applied retro: no-match, zero open rows.
box49="$(mkbox case-freetext-partial-applied)"
retro49="$(mk_retro "$box49" target-foo r-freetext-partial.md \
  "<!-- review-status: applied 2026-01-01 · kit abc1234 — historical note: this used to be PARTIAL but is now fully resolved -->" \
  "| 1 | fix the thing | METHODOLOGY.md | B42 | new | HIGH |")"
run "$box49" "$retro49"
if [ "$RC" = 0 ] && grep -qi 'no-match' <<<"$OUT" \
   && ! grep -q 'planned-issue:' <<<"$OUT"; then
  ok "49 free-text PARTIAL (applied): structured segment has no token → no-match" "(exit $RC)"
else
  no "49 free-text PARTIAL (applied): structured segment has no token → no-match" \
    "exit=$RC out=[$OUT]"
fi

# 50 — REAL REPRO MARKER (kit issue #1090, verbatim): a dismissed marker whose free-text
# explanation mentions 'partial' in lowercase prose must yield ZERO open rows (not all 7
# rows reopened).
box50="$(mkbox case-1090-repro)"
retro50="$(mk_retro "$box50" target-foo r-1090-repro.md \
  "<!-- review-status: dismissed 2026-09-20 · scoped to build-n4-module kit — deltas owned + implemented there (D1-D5 orient-guard, P3/P4/P5; P1 partial) -->" \
  "$(printf '| 1 | delta one | METHODOLOGY.md | B1 | new | HIGH |\n| 2 | delta two | METHODOLOGY.md | B2 | new | HIGH |')")"
run "$box50" "$retro50"
if [ "$RC" = 0 ] && ! grep -q 'planned-issue:' <<<"$OUT"; then
  ok "50 #1090 real repro marker: dismissed + prose 'partial' → zero open rows" "(exit $RC)"
else
  no "50 #1090 real repro marker: dismissed + prose 'partial' → zero open rows" \
    "exit=$RC out=[$OUT]"
fi

# 51 — PROSE 'partial' POSITION (first/middle/last) on a DISMISSED marker never trips
# PARTIAL handling, regardless of where in the free text it falls.
for pos in first middle last; do
  case "$pos" in
    first)  _prose="partial rollback only — see the linked ticket for the rest" ;;
    middle) _prose="deltas partial in scope, the remainder tracked elsewhere" ;;
    last)   _prose="deltas owned and implemented elsewhere (partial)" ;;
  esac
  box51="$(mkbox "case-1090-prose-$pos")"
  retro51="$(mk_retro "$box51" target-foo r-1090-prose.md \
    "<!-- review-status: dismissed 2026-09-20 · kit deadbeef — ${_prose} -->" \
    "| 1 | delta one | METHODOLOGY.md | B1 | new | HIGH |")"
  run "$box51" "$retro51"
  if [ "$RC" = 0 ] && ! grep -q 'planned-issue:' <<<"$OUT"; then
    ok "51 #1090 dismissed + prose 'partial' at $pos → zero open rows" "(exit $RC)"
  else
    no "51 #1090 dismissed + prose 'partial' at $pos → zero open rows" "exit=$RC out=[$OUT]"
  fi
done

# ---------------------------------------------------------------------------
# RDD repo-resolver follow-ups (kit issue #1046 round 2, RDD pass) — item a (scp fail-closed),
# item b (alias suffix must not contain dots), item c (host segment must be dotted).
# ---------------------------------------------------------------------------

# 52 — ITEM a: scp form, non-github host with user@ (e.g. a GHE remote configured over SSH)
# → unresolved, NOT silently collapsed to 'o/n'.
box52="$(mkbox case-scp-nongithub-userat)"
derive_dry "$box52" "git@ghe.corp.com:o/n.git"
if [ "$RC" = 0 ] && grep -q '^kit-issue-repo: unresolved' <<<"$OUT" \
   && grep -qi 'ghe.corp.com' <<<"$OUT" \
   && ! grep -q '^kit-issue-repo: o/n$' <<<"$OUT"; then
  ok "52 ITEMa scp non-github host (user@) → unresolved, names the host" "(exit $RC)"
else
  no "52 ITEMa scp non-github host (user@) → unresolved, names the host" "exit=$RC out=[$OUT]"
fi

# 53 — ITEM a: scp form, bare SSH config alias with NO user@ and NO dot at all (e.g. a
# personal "work" Host alias) → unresolved, never silently treated as github.com.
box53="$(mkbox case-scp-nongithub-bare)"
derive_dry "$box53" "work:o/n.git"
if [ "$RC" = 0 ] && grep -q '^kit-issue-repo: unresolved' <<<"$OUT" \
   && grep -qi 'work' <<<"$OUT" \
   && ! grep -q '^kit-issue-repo: o/n$' <<<"$OUT"; then
  ok "53 ITEMa scp non-github bare alias 'work:o/n.git' → unresolved" "(exit $RC)"
else
  no "53 ITEMa scp non-github bare alias 'work:o/n.git' → unresolved" "exit=$RC out=[$OUT]"
fi

# 54 — ITEM a (--apply): the same untrusted scp host must refuse BEFORE any gh call —
# degraded, exit non-zero, zero gh issue calls, never a fallback create against the wrong repo.
box54="$(mkbox case-scp-nongithub-apply)"
mk_gh_stub "$box54" nomatch
git init -q "$box54" >/dev/null 2>&1
git -C "$box54" remote add origin "git@ghe.corp.com:o/n.git" >/dev/null 2>&1
retro54="$(mk_retro "$box54" target-foo r-item-a-apply.md \
  "<!-- review-status: pending -->" \
  "| 1 | delta | CLAUDE.md | B1 | new | HIGH |")"
OUT54="$(PATH="$box54/bin:$PATH" RESEARCH_SDD_ISSUE_REPO="" \
  "$BASH_BIN" "$box54/research-sdd/toolbelt/stage-retro-issues.sh" "$retro54" --apply 2>&1)"; RC54=$?
gh_called_54=0
[ -f "$box54/bin/gh.log" ] && grep -q 'issue' "$box54/bin/gh.log" && gh_called_54=1
if [ "$RC54" != 0 ] && grep -qi 'degraded' <<<"$OUT54" && [ "$gh_called_54" = 0 ]; then
  ok "54 ITEMa --apply: untrusted scp host refuses before any gh call" "(exit $RC54)"
else
  no "54 ITEMa --apply: untrusted scp host refuses before any gh call" \
    "exit=$RC54 gh_called=$gh_called_54 out=[$OUT54]"
fi

# 55 — ITEM b: an https host that is 'github.com' plus a DOTTED suffix (a look-alike, not
# a bare SSH-config alias) must NOT be collapsed to plain 'o/n' — it is kept verbatim as its
# own distinct host, exactly like any other non-alias HOST/owner/repo.
box55="$(mkbox case-alias-suffix-dot)"
derive_dry "$box55" "https://github.com-x.corp/o/n"
if [ "$RC" = 0 ] && grep -q '^kit-issue-repo: github.com-x.corp/o/n$' <<<"$OUT"; then
  ok "55 ITEMb dotted alias-suffix host kept verbatim: 'github.com-x.corp' NOT collapsed to github.com" "(exit $RC)"
else
  no "55 ITEMb dotted alias-suffix host kept verbatim: 'github.com-x.corp' NOT collapsed to github.com" \
    "exit=$RC out=[$OUT]"
fi

# 56 — ITEM b: a spoofed host embedding 'github.com-' followed by an attacker-controlled
# domain must NEVER resolve to plain 'o/n' (which would make gh operate against github.com).
box56="$(mkbox case-alias-spoof)"
derive_dry "$box56" "https://user@github.com-evil.attacker.com/o/n"
if [ "$RC" = 0 ] && grep -q '^kit-issue-repo: github.com-evil.attacker.com/o/n$' <<<"$OUT" \
   && ! grep -q '^kit-issue-repo: o/n$' <<<"$OUT"; then
  ok "56 ITEMb spoofed 'github.com-evil.attacker.com' host never resolves to github.com" "(exit $RC)"
else
  no "56 ITEMb spoofed 'github.com-evil.attacker.com' host never resolves to github.com" \
    "exit=$RC out=[$OUT]"
fi

# 57 — ITEM c: a three-segment RESEARCH_SDD_ISSUE_REPO override whose first segment is NOT a
# dotted host (a plain word) must be rejected — it used to be silently accepted as
# HOST=myorg/OWNER=myrepo/REPO=subpath instead of being recognized as a malformed value.
box57="$(mkbox case-item-c-host-no-dot)"
retro57="$(mk_retro "$box57" target-foo r-item-c.md \
  "<!-- review-status: pending -->" \
  "| 1 | item c delta | CLAUDE.md | B1 | new | HIGH |")"
OUT57="$(PATH="$box57/bin:$PATH" RESEARCH_SDD_ISSUE_REPO="myorg/myrepo/subpath" \
  "$BASH_BIN" "$box57/research-sdd/toolbelt/stage-retro-issues.sh" "$retro57" 2>&1)"; RC57=$?
if [ "$RC57" = 0 ] && grep -q "^kit-issue-repo: unresolved (invalid repo shape 'myorg/myrepo/subpath'" <<<"$OUT57"; then
  ok "57 ITEMc 3-segment override with non-dotted first segment → unresolved" "(exit $RC57)"
else
  no "57 ITEMc 3-segment override with non-dotted first segment → unresolved" "exit=$RC57 out=[$OUT57]"
fi

# 58 — ITEM c positive control: a genuinely DOTTED host as the first of three segments is
# still accepted (this is the whole point of GHE support — must not regress).
box58="$(mkbox case-item-c-host-dotted)"
retro58="$(mk_retro "$box58" target-foo r-item-c-ok.md \
  "<!-- review-status: pending -->" \
  "| 1 | item c delta | CLAUDE.md | B1 | new | HIGH |")"
OUT58="$(PATH="$box58/bin:$PATH" RESEARCH_SDD_ISSUE_REPO="ghe.example.com/myorg/myrepo" \
  "$BASH_BIN" "$box58/research-sdd/toolbelt/stage-retro-issues.sh" "$retro58" 2>&1)"; RC58=$?
if [ "$RC58" = 0 ] && grep -q '^kit-issue-repo: ghe.example.com/myorg/myrepo$' <<<"$OUT58"; then
  ok "58 ITEMc positive control: dotted host 'ghe.example.com/myorg/myrepo' still accepted" "(exit $RC58)"
else
  no "58 ITEMc positive control: dotted host 'ghe.example.com/myorg/myrepo' still accepted" "exit=$RC58 out=[$OUT58]"
fi

# ---------------------------------------------------------------------------
# 59 — SPANISH CANONICAL ALIAS (kit issue #1111): "## PROPUESTA de deltas al kit" is a real
#      fleet form (Pancaddia corpus retro) — accepted as canonical, table rows staged normally.
box59="$(mkbox case-spanish-alias)"
retro59="$box59/rh/target-foo/retros/r-spanish.md"
{ printf '<!-- review-status: pending -->\n# retro\n\n## PROPUESTA de deltas al kit (revisar antes de aplicar)\n\n'
  printf '| # | Proposed change | Target (file) | Evidence | Type | Priority |\n|---|---|---|---|---|---|\n'
  printf '| 1 | delta uno | CLAUDE.md | B1 | new | HIGH |\n'
} > "$retro59"
run "$box59" "$retro59"
if [ "$RC" = 0 ] && grep -q '^planned-issue:' <<<"$OUT" && ! grep -qi 'empty-input\|unclassifiable' <<<"$OUT"; then
  ok "59 Spanish canonical alias 'PROPUESTA de deltas al kit' → row staged, not empty/unclassifiable" "(exit $RC)"
else
  no "59 Spanish canonical alias → expected row staged" "exit=$RC out=[$OUT]"
fi

# ---------------------------------------------------------------------------
# 60 — UNCLASSIFIABLE, not empty-input (kit issue #1111): a hyphenated "kit-delta" mid-heading
#      (real fleet form, niagara-research retro: "## B. Campaign-8 kit-delta backlog") with no
#      table rows must be typed unclassifiable, never a confident empty-input.
box60="$(mkbox case-hyphen-kitdelta)"
retro60="$box60/rh/target-foo/retros/r-hyphen.md"
{ printf '<!-- review-status: pending -->\n# retro\n\n'
  printf '## B. Campaign-8 kit-delta backlog (the overdue roll-up)\n\nsome prose, no table rows here\n'
} > "$retro60"
run "$box60" "$retro60"
if [ "$RC" = 0 ] && grep -qi 'unclassifiable' <<<"$OUT" && ! grep -qF 'empty-input' <<<"$OUT"; then
  ok "60 hyphenated 'kit-delta' mid-heading → unclassifiable, never empty-input" "(exit $RC)"
else
  no "60 hyphenated 'kit-delta' mid-heading → expected unclassifiable, never empty-input" "exit=$RC out=[$OUT]"
fi

# ---------------------------------------------------------------------------
# 61 — UNCLASSIFIABLE, not empty-input (kit issue #1111): a standalone H3 "### Proposals"
#      heading outside any canonical section (real fleet form, niagara-research retro) with no
#      table rows must be typed unclassifiable, never a confident empty-input.
box61="$(mkbox case-h3-proposals)"
retro61="$box61/rh/target-foo/retros/r-h3proposals.md"
{ printf '<!-- review-status: pending -->\n# retro\n\n## A. THE DEFECT\n\n'
  printf '### Proposals (propose-never-apply) — make it automatic\n\nsome prose, no table rows here\n'
} > "$retro61"
run "$box61" "$retro61"
if [ "$RC" = 0 ] && grep -qi 'unclassifiable' <<<"$OUT" && ! grep -qF 'empty-input' <<<"$OUT"; then
  ok "61 standalone H3 '### Proposals' outside section → unclassifiable, never empty-input" "(exit $RC)"
else
  no "61 standalone H3 '### Proposals' outside section → expected unclassifiable, never empty-input" "exit=$RC out=[$OUT]"
fi

# ---------------------------------------------------------------------------
# 62 — HONEST EMPTY, not unclassifiable (kit issue #1129 finding 2): a canonical section with an
#      empty table (header + separator, no data rows) PLUS a valid §18 honesty line is a correct
#      declared zero, not "not in row-table form — needs manual review". Real fleet counterexample:
#      niagara-research/retros/2026-09-17-tools-search-innovation.md.
box62="$(mkbox case-honest-empty)"
retro62="$box62/rh/target-foo/retros/r-honest-empty.md"
{ printf '<!-- review-status: pending -->\n# retro\n\n## Proposed kit deltas\n\n'
  printf '| # | Proposed change | Target (file · %%/section) | Evidence | Type | Priority |\n|---|---|---|---|---|---|\n'
  printf 'no new deltas; the kit already covers this run.\n'
} > "$retro62"
run "$box62" "$retro62"
if [ "$RC" = 0 ] && grep -qi '^empty-input:' <<<"$OUT" \
  && ! grep -qi 'unclassifiable' <<<"$OUT"; then
  ok "62 honest empty (§18 honesty line, no rows) → empty-input, not unclassifiable" "(exit $RC)"
else
  no "62 honest empty (§18 honesty line, no rows) → expected empty-input, not unclassifiable" "exit=$RC out=[$OUT]"
fi

# ---------------------------------------------------------------------------
# 63 — UNCLASSIFIABLE (found=1, no rows, NOT an honest zero) — kit issue #1129 finding 3: the
#      found=1-no-rows relabel itself had no positive test. A canonical section whose body is
#      ordinary prose (no §18 honesty phrase, no table rows) must still be unclassifiable.
box63="$(mkbox case-no-rows-not-honest)"
retro63="$box63/rh/target-foo/retros/r-not-honest.md"
{ printf '<!-- review-status: pending -->\n# retro\n\n## Proposed kit deltas\n\n'
  printf '### ABSORB → some ordinary sub-heading with prose, no table, no honesty phrase\n\nprose here\n'
} > "$retro63"
run "$box63" "$retro63"
if [ "$RC" = 0 ] && grep -qi '^unclassifiable:' <<<"$OUT" \
  && ! grep -qi '^empty-input:' <<<"$OUT"; then
  ok "63 canonical section, no rows, NOT honest → unclassifiable" "(exit $RC)"
else
  no "63 canonical section, no rows, NOT honest → expected unclassifiable" "exit=$RC out=[$OUT]"
fi

# ---------------------------------------------------------------------------
# kit issue #1169: target-name derivation must walk UP from the retro to the nearest ancestor
# registered in TARGETS.md — flat (<target>/retros), nested (<target>/corpus/retros) and deeper
# (<target>/<sub>/retros) layouts — and must never emit a structural `target:corpus|retros` label.
# kit issue #1287: the walk lives in lib/target-paths.sh (target_name_for_retro); assertions below
# use here-strings, not `printf | grep -q` (a SIGPIPE-prone shape under pipefail, #1162).

# 64 — NESTED corpus resolves to the registered target name (RED pre-fix: target:corpus + WARN)
box64="$(mkbox case-nested-corpus)"
retro64="$(mk_nested_retro "$box64" corpus/retros r-nested.md)"
run "$box64" "$retro64"
if [ "$RC" = 0 ] && grep -q 'labels: .*target:target-foo,' <<<"$OUT" \
  && ! grep -q 'target:corpus' <<<"$OUT" \
  && ! grep -qi 'target directory.*not found' <<<"$OUT"; then
  ok "64 nested <target>/corpus/retros → target:target-foo, no basename WARN" "(exit $RC)"
else
  no "64 nested <target>/corpus/retros → expected target:target-foo" "exit=$RC out=[$OUT]"
fi

# 65 — FLAT layout still resolves (regression guard for the walk-up)
box65="$(mkbox case-flat-walkup)"
retro65="$(mk_retro "$box65" target-foo r-flat.md "<!-- review-status: pending -->" \
  "| 1 | flat delta | CLAUDE.md | B1 | fix | HIGH |")"
run "$box65" "$retro65"
if [ "$RC" = 0 ] && grep -q 'labels: .*target:target-foo,' <<<"$OUT" \
  && ! grep -qi 'not found' <<<"$OUT"; then
  ok "65 flat <target>/retros → target:target-foo" "(exit $RC)"
else
  no "65 flat <target>/retros → expected target:target-foo" "exit=$RC out=[$OUT]"
fi

# 66 — DEEPER layout (<target>/examinacion-x/retros) also resolves
box66="$(mkbox case-deeper-layout)"
retro66="$(mk_nested_retro "$box66" examinacion-x/retros r-deep.md)"
run "$box66" "$retro66"
if [ "$RC" = 0 ] && grep -q 'labels: .*target:target-foo,' <<<"$OUT" \
  && ! grep -q 'target:examinacion-x' <<<"$OUT"; then
  ok "66 deeper <target>/examinacion-x/retros → target:target-foo" "(exit $RC)"
else
  no "66 deeper <target>/examinacion-x/retros → expected target:target-foo" "exit=$RC out=[$OUT]"
fi

# 67 — NESTED but unregistered: fail up front (exit 1, typed message), never plan target:corpus
box67="$(mkbox case-nested-unregistered)"
retro67="$(mk_nested_retro "$box67" corpus/retros r-unreg.md)"
printf '# test targets\n\n| # | Target | Path |\n|---|---|---|\n| 1 | other | `%s/rh/other` |\n' "$box67" \
  > "$box67/research-sdd/TARGETS.md"
mkdir -p "$box67/rh/other"
run "$box67" "$retro67"
if [ "$RC" = 1 ] && grep -qi 'cannot resolve target' <<<"$OUT" \
  && ! grep -q 'target:corpus' <<<"$OUT" \
  && ! grep -q 'planned-issue:' <<<"$OUT"; then
  ok "67 nested + unregistered → exit 1, 'cannot resolve target', no target:corpus" "(exit $RC)"
else
  no "67 nested + unregistered → expected exit 1 and no target:corpus label" "exit=$RC out=[$OUT]"
fi

# 68 — FLAT but unregistered (TARGETS.md read fine, this dir just isn't in it) keeps the legacy
#      WARN + basename fallback (not a regression). The registry needs at least one OTHER row: a
#      registry with zero rows is an operational failure (case 71), not a no-match.
box68="$(mkbox case-flat-unregistered)"
retro68="$(mk_retro "$box68" target-foo r-flat-unreg.md "<!-- review-status: pending -->" \
  "| 1 | flat delta | CLAUDE.md | B1 | fix | HIGH |")"
printf '# test targets\n\n| # | Target | Path |\n|---|---|---|\n| 1 | other | `%s/rh/other` |\n' "$box68" \
  > "$box68/research-sdd/TARGETS.md"
mkdir -p "$box68/rh/other"
run "$box68" "$retro68"
if [ "$RC" = 0 ] && grep -qi "using basename 'target-foo'" <<<"$OUT" \
  && grep -q 'target:target-foo,' <<<"$OUT"; then
  ok "68 flat + unregistered → WARN + basename fallback preserved" "(exit $RC)"
else
  no "68 flat + unregistered → expected WARN + basename fallback" "exit=$RC out=[$OUT]"
fi

# 69 — REGISTERED NAME != PATH BASENAME (real case: Pancaddia -> `pancaddia-leon-tunnel`): the
#      label is the TARGETS.md Target-column name, in flat AND nested layouts.
box69="$(mkbox case-name-not-basename)"
printf '# test targets\n\n| # | Target | Path |\n|---|---|---|\n| 1 | reg-name | `%s/rh/target-foo` |\n' "$box69" \
  > "$box69/research-sdd/TARGETS.md"
retro69n="$(mk_nested_retro "$box69" corpus/retros r-n.md)"
retro69f="$(mk_nested_retro "$box69" retros r-f.md)"
run "$box69" "$retro69n"; out69n="$OUT"; rc69n=$RC
run "$box69" "$retro69f"; out69f="$OUT"; rc69f=$RC
if [ "$rc69n" = 0 ] && [ "$rc69f" = 0 ] \
  && grep -q 'labels: .*target:reg-name,' <<<"$out69n" \
  && grep -q 'labels: .*target:reg-name,' <<<"$out69f"; then
  ok "69 registered name differs from path basename → target:reg-name (nested + flat)" "(rc=$rc69n/$rc69f)"
else
  no "69 registered name differs from path basename → expected target:reg-name" "nested=[$out69n] flat=[$out69f]"
fi

# 70 — TARGETS.md ABSENT is an OPERATIONAL failure (kit issue #1287 item 3, CLAUDE.md §7/§8):
#      exit 1 with a typed message — never a WARN + basename guess that plans issues anyway.
box70="$(mkbox case-targets-absent)"
retro70="$(mk_retro "$box70" target-foo r-noreg.md "<!-- review-status: pending -->" \
  "| 1 | flat delta | CLAUDE.md | B1 | fix | HIGH |")"
rm -f "$box70/research-sdd/TARGETS.md"
run "$box70" "$retro70"
if [ "$RC" = 1 ] && grep -qi 'cannot read' <<<"$OUT" && ! grep -q 'planned-issue:' <<<"$OUT"; then
  ok "70 TARGETS.md absent → exit 1, typed 'cannot read', nothing planned" "(exit $RC)"
else
  no "70 TARGETS.md absent → expected exit 1 + typed message + no plan" "exit=$RC out=[$OUT]"
fi

# 71 — TARGETS.md with ZERO parsed rows is also operational (an empty pairs list must not read as
#      "this retro is simply unregistered") — flat AND nested.
box71="$(mkbox case-targets-empty)"
retro71f="$(mk_retro "$box71" target-foo r-empty-f.md "<!-- review-status: pending -->" \
  "| 1 | flat delta | CLAUDE.md | B1 | fix | HIGH |")"
retro71n="$(mk_nested_retro "$box71" corpus/retros r-empty-n.md)"
printf '# test targets\n\n| # | Target | Path |\n|---|---|---|\n' > "$box71/research-sdd/TARGETS.md"
run "$box71" "$retro71f"; out71f="$OUT"; rc71f=$RC
run "$box71" "$retro71n"; out71n="$OUT"; rc71n=$RC
if [ "$rc71f" = 1 ] && [ "$rc71n" = 1 ] \
  && grep -qi 'no registered target' <<<"$out71f" && grep -qi 'no registered target' <<<"$out71n" \
  && ! grep -q 'planned-issue:' <<<"$out71f$out71n"; then
  ok "71 zero-row TARGETS.md → exit 1, typed 'no registered target paths' (flat + nested)" "(rc=$rc71f/$rc71n)"
else
  no "71 zero-row TARGETS.md → expected exit 1 + typed message" "flat=[$out71f] nested=[$out71n]"
fi

# 72 — NESTED REGISTERED TARGETS: the NEAREST ancestor labels the retro, in both row orders (a
#      mutant matching the OUTERMOST ancestor must not survive).
box72="$(mkbox case-nested-registered)"
mkdir -p "$box72/rh/target-foo/inner-t/retros"
retro72i="$box72/rh/target-foo/inner-t/retros/r-in.md"
retro72o="$(mk_retro "$box72" target-foo r-out.md "<!-- review-status: pending -->" \
  "| 1 | outer delta | CLAUDE.md | B1 | fix | HIGH |")"
cp "$retro72o" "$retro72i"
printf '# t\n\n| # | Target | Path |\n|---|---|---|\n| 1 | outer-name | `%s/rh/target-foo` |\n| 2 | inner-name | `%s/rh/target-foo/inner-t` |\n' "$box72" "$box72" \
  > "$box72/research-sdd/TARGETS.md"
run "$box72" "$retro72i"; a_i="$OUT"; run "$box72" "$retro72o"; a_o="$OUT"
printf '# t\n\n| # | Target | Path |\n|---|---|---|\n| 1 | inner-name | `%s/rh/target-foo/inner-t` |\n| 2 | outer-name | `%s/rh/target-foo` |\n' "$box72" "$box72" \
  > "$box72/research-sdd/TARGETS.md"
run "$box72" "$retro72i"; b_i="$OUT"; run "$box72" "$retro72o"; b_o="$OUT"
if grep -q 'labels: .*target:inner-name,' <<<"$a_i" && grep -q 'labels: .*target:outer-name,' <<<"$a_o" \
  && grep -q 'labels: .*target:inner-name,' <<<"$b_i" && grep -q 'labels: .*target:outer-name,' <<<"$b_o"; then
  ok "72 nested registered targets → nearest ancestor labels the retro (both row orders)" "()"
else
  no "72 nested registered targets → nearest ancestor must win" "a_in=[$a_i] a_out=[$a_o] b_in=[$b_i] b_out=[$b_o]"
fi

# 73 — RAW `$RESEARCH_HOME/...` token (the form every real TARGETS.md row uses), plain and braced.
box73="$(mkbox case-raw-rh-token)"
retro73="$(mk_nested_retro "$box73" corpus/retros r-rh.md)"
printf '# t\n\n| # | Target | Path |\n|---|---|---|\n| 1 | rh-name | `$RESEARCH_HOME/rh/target-foo` |\n' \
  > "$box73/research-sdd/TARGETS.md"
RESEARCH_HOME="$box73" run "$box73" "$retro73"; out73p="$OUT"; rc73p=$RC
printf '# t\n\n| # | Target | Path |\n|---|---|---|\n| 1 | rh-name | `${RESEARCH_HOME}/rh/target-foo` |\n' \
  > "$box73/research-sdd/TARGETS.md"
RESEARCH_HOME="$box73" run "$box73" "$retro73"; out73b="$OUT"; rc73b=$RC
if [ "$rc73p" = 0 ] && [ "$rc73b" = 0 ] \
  && grep -q 'labels: .*target:rh-name,' <<<"$out73p" && grep -q 'labels: .*target:rh-name,' <<<"$out73b"; then
  ok "73 raw \$RESEARCH_HOME / \${RESEARCH_HOME} row token → registered name label" "(rc=$rc73p/$rc73b)"
else
  no "73 raw \$RESEARCH_HOME row token → expected target:rh-name" "plain=[$out73p] braced=[$out73b]"
fi

# 74 — NAME FALLBACK: an empty name cell labels by the path basename; a whitespace name falls
#      back too, and the WARN reaches the operator instead of vanishing (R2-whitespace-fallback).
box74="$(mkbox case-name-fallback)"
retro74="$(mk_retro "$box74" target-foo r-fb.md "<!-- review-status: pending -->" \
  "| 1 | fb delta | CLAUDE.md | B1 | fix | HIGH |")"
printf '# t\n\n| # | Target | Path |\n|---|---|---|\n| 1 |  | `%s/rh/target-foo` |\n' "$box74" \
  > "$box74/research-sdd/TARGETS.md"
run "$box74" "$retro74"; out74a="$OUT"; rc74a=$RC
printf '# t\n\n| # | Target | Path |\n|---|---|---|\n| 1 | two words | `%s/rh/target-foo` |\n' "$box74" \
  > "$box74/research-sdd/TARGETS.md"
run "$box74" "$retro74"; out74b="$OUT"; rc74b=$RC
if [ "$rc74a" = 0 ] && grep -q 'labels: .*target:target-foo,' <<<"$out74a" \
  && [ "$rc74b" = 0 ] && grep -q 'labels: .*target:target-foo,' <<<"$out74b" \
  && grep -qi 'WARN.*two words' <<<"$out74b"; then
  ok "74 empty / whitespace name cell → basename label (whitespace case WARNs)" "(rc=$rc74a/$rc74b)"
else
  no "74 name fallback → expected basename label, WARN on whitespace" "empty=[$out74a] space=[$out74b]"
fi

# 75 — LEGACY SIGNATURE DEDUP (kit issue #1287 item 2): issues created before #1286 carry
#      `<path basename>/retros/<file>`; a target whose registered NAME differs from its basename
#      must ALSO search that legacy signature, or a re-marked pending retro would duplicate on
#      --apply. Control: the new signature alone matches nothing here, so only the legacy search
#      can produce the skip.
box75="$(mkbox case-legacy-dedup)"
printf '# t\n\n| # | Target | Path |\n|---|---|---|\n| 1 | reg-name | `%s/rh/target-foo` |\n' "$box75" \
  > "$box75/research-sdd/TARGETS.md"
mk_gh_stub "$box75" matchsig 'Source retro: target-foo/retros/r-legacy.md'
retro75="$(mk_retro "$box75" target-foo r-legacy.md "<!-- review-status: pending -->" \
  "| 1 | legacy delta | CLAUDE.md | B1 | fix | HIGH |")"
run "$box75" "$retro75" --apply
create75=0; [ -f "$box75/bin/gh.log" ] && grep -q 'issue create' "$box75/bin/gh.log" && create75=1
if [ "$RC" = 0 ] && [ "$create75" = 0 ] && grep -q 'skipped-duplicate' <<<"$OUT" \
  && grep -qF 'Source retro: target-foo/retros/r-legacy.md' <<<"$(cat "$box75/bin/gh.log")" \
  && grep -qF 'Source retro: reg-name/retros/r-legacy.md' <<<"$(cat "$box75/bin/gh.log")"; then
  ok "75 --apply: legacy basename signature match suppresses create (new + legacy both searched)" "(exit $RC)"
else
  no "75 --apply: legacy basename signature match must suppress create" "exit=$RC create=$create75 out=[$OUT]"
fi

# 75b — control: neither signature matches → the create goes through.
box75b="$(mkbox case-legacy-dedup-nomatch)"
printf '# t\n\n| # | Target | Path |\n|---|---|---|\n| 1 | reg-name | `%s/rh/target-foo` |\n' "$box75b" \
  > "$box75b/research-sdd/TARGETS.md"
mk_gh_stub "$box75b" matchsig 'Source retro: unrelated/retros/'
retro75b="$(mk_retro "$box75b" target-foo r-legacy.md "<!-- review-status: pending -->" \
  "| 1 | legacy delta | CLAUDE.md | B1 | fix | HIGH |")"
run "$box75b" "$retro75b" --apply
create75b=0; [ -f "$box75b/bin/gh.log" ] && grep -q 'issue create' "$box75b/bin/gh.log" && create75b=1
if [ "$RC" = 0 ] && [ "$create75b" = 1 ] && grep -q 'summary: created=1 ' <<<"$OUT"; then
  ok "75b --apply: no signature matches → create called (control)" "(exit $RC)"
else
  no "75b --apply: no signature matches → expected a create" "exit=$RC create=$create75b out=[$OUT]"
fi

# 75c — a FAILED legacy lookup must not fall through to create either (anti-silent-zero): count it
#       as failed, exit 2, exactly like a failed primary lookup.
box75c="$(mkbox case-legacy-dedup-listfail)"
printf '# t\n\n| # | Target | Path |\n|---|---|---|\n| 1 | reg-name | `%s/rh/target-foo` |\n' "$box75c" \
  > "$box75c/research-sdd/TARGETS.md"
mk_gh_stub "$box75c" failsig 'Source retro: target-foo/retros/'
retro75c="$(mk_retro "$box75c" target-foo r-legacy.md "<!-- review-status: pending -->" \
  "| 1 | legacy delta | CLAUDE.md | B1 | fix | HIGH |")"
run "$box75c" "$retro75c" --apply
create75c=0; [ -f "$box75c/bin/gh.log" ] && grep -q 'issue create' "$box75c/bin/gh.log" && create75c=1
if [ "$RC" = 2 ] && [ "$create75c" = 0 ] && grep -qi 'ERROR.*issue list' <<<"$OUT" \
  && grep -q 'summary:.*failed=1' <<<"$OUT"; then
  ok "75c --apply: failed legacy lookup counts as failed, never creates, exit 2" "(exit $RC)"
else
  no "75c --apply: failed legacy lookup must not fall through to create" "exit=$RC create=$create75c out=[$OUT]"
fi

# 75d — name == basename: NO second (legacy) list call — the legacy search is only for drift.
box75d="$(mkbox case-legacy-dedup-same)"
mk_gh_stub "$box75d" nomatch
retro75d="$(mk_retro "$box75d" target-foo r-same.md "<!-- review-status: pending -->" \
  "| 1 | same delta | CLAUDE.md | B1 | fix | HIGH |")"
run "$box75d" "$retro75d" --apply
lists75d="$(grep -c 'issue list' "$box75d/bin/gh.log")"
if [ "$RC" = 0 ] && [ "$lists75d" = 1 ]; then
  ok "75d --apply: name == basename → exactly one dedup list call" "(lists=$lists75d)"
else
  no "75d --apply: name == basename → expected exactly one list call" "exit=$RC lists=$lists75d out=[$OUT]"
fi

# 75e — a CLOSED legacy-signature match suppresses create too. This is the LIVE case: every
#       pre-#1286 issue (cloudflare #702-708, Pancaddia #720-722) is CLOSED today.
box75e="$(mkbox case-legacy-dedup-closed)"
printf '# t\n\n| # | Target | Path |\n|---|---|---|\n| 1 | reg-name | `%s/rh/target-foo` |\n' "$box75e" \
  > "$box75e/research-sdd/TARGETS.md"
mk_gh_stub "$box75e" matchsigclosed 'Source retro: target-foo/retros/r-legacy-closed.md'
retro75e="$(mk_retro "$box75e" target-foo r-legacy-closed.md "<!-- review-status: pending -->" \
  "| 1 | legacy closed delta | CLAUDE.md | B1 | fix | HIGH |")"
run "$box75e" "$retro75e" --apply
create75e=0; [ -f "$box75e/bin/gh.log" ] && grep -q 'issue create' "$box75e/bin/gh.log" && create75e=1
if [ "$RC" = 0 ] && [ "$create75e" = 0 ] && grep -q 'skipped-duplicate.*closed; legacy signature' <<<"$OUT"; then
  ok "75e --apply: CLOSED legacy-signature match suppresses create, names it closed" "(exit $RC)"
else
  no "75e --apply: CLOSED legacy-signature match must suppress create" "exit=$RC create=$create75e out=[$OUT]"
fi

# 75g — the LEGACY lookup is exact too (kit issue #1304 item 1): three.js's legacy name is
#       `research`, and GitHub's fuzzy search for `research/retros/<file> · <id>` also returns every
#       `*-research` target's issue for the same file and row. Both lookups here get such a
#       false hit (another target's issue): neither is a duplicate, so the create goes through
#       after exactly TWO list calls (new signature + legacy signature).
box75g="$(mkbox case-legacy-dedup-fuzzy)"
printf '# t\n\n| # | Target | Path |\n|---|---|---|\n| 1 | reg-name | `%s/rh/target-foo` |\n' "$box75g" \
  > "$box75g/research-sdd/TARGETS.md"
mk_gh_stub "$box75g" fuzzyother
retro75g="$(mk_retro "$box75g" target-foo r-legacy-fuzzy.md "<!-- review-status: pending -->" \
  "| 1 | legacy fuzzy delta | CLAUDE.md | B1 | fix | HIGH |")"
run "$box75g" "$retro75g" --apply
create75g=0; [ -f "$box75g/bin/gh.log" ] && grep -q 'issue create' "$box75g/bin/gh.log" && create75g=1
lists75g="$(grep -c 'issue list' "$box75g/bin/gh.log")"
if [ "$RC" = 0 ] && [ "$create75g" = 1 ] && [ "$lists75g" = 2 ] && grep -q 'summary: created=1 ' <<<"$OUT"; then
  ok "75g --apply: fuzzy hit on another target's issue in BOTH lookups → created after 2 list calls" "(exit $RC)"
else
  no "75g --apply: fuzzy hits must not suppress the create" "exit=$RC create=$create75g lists=$lists75g out=[$OUT]"
fi

# 75f — a retro under <target>/corpus/retros has the legacy name `corpus`: that signature
#       ("corpus/retros/<file> · <id>") cannot exist, so no pointless gh call is made for it.
box75f="$(mkbox case-legacy-dedup-structural)"
printf '# t\n\n| # | Target | Path |\n|---|---|---|\n| 1 | reg-name | `%s/rh/target-foo` |\n' "$box75f" \
  > "$box75f/research-sdd/TARGETS.md"
mk_gh_stub "$box75f" nomatch
retro75f="$(mk_nested_retro "$box75f" corpus/retros r75f.md)"
run "$box75f" "$retro75f" --apply
lists75f="$(grep -c 'issue list' "$box75f/bin/gh.log")"
if [ "$RC" = 0 ] && [ "$lists75f" = 1 ] && ! grep -qF 'Source retro: corpus/retros/' "$box75f/bin/gh.log"; then
  ok "75f --apply: nested corpus/retros → no legacy 'corpus/retros/...' lookup (one list call)" "(lists=$lists75f)"
else
  no "75f --apply: nested corpus/retros → expected one list call, no 'corpus/retros' signature" "exit=$RC lists=$lists75f log=[$(cat "$box75f/bin/gh.log")]"
fi


# ---------------------------------------------------------------------------
# 76 — TARGET LABEL PROBE (kit issue #1332 item 1): --apply probes the `target:<name>` label ONCE,
#      before the first create. Missing -> created with the fleet convention (description
#      `Fleet target: <name>`, color d4c5f9). A probe or label-create failure -> ONE typed
#      `degraded:` line + exit 1 before ANY issue create — never N per-row create failures.
lbl_case() {   # lbl_case <name> <issue-mode> <label-mode> [extra args]
  local n="$1" im="$2" lm="$3"; shift 3
  LBOX="$(mkbox "case-label-$n")"
  mk_gh_stub "$LBOX" "$im" "" "$lm"
  LRETRO="$(mk_retro "$LBOX" target-foo "r-$n.md" "<!-- review-status: pending -->" "$TWO_ROWS")"
  run "$LBOX" "$LRETRO" --apply "$@"
  LOG="$(cat "$LBOX/bin/gh.log" 2>/dev/null)"
  N_LLIST="$(grep -c 'gh label list' <<<"$LOG")"; N_LCREATE="$(grep -c 'gh label create' <<<"$LOG")"
  N_ICREATE="$(grep -c 'gh issue create' <<<"$LOG")"; N_DEGR="$(grep -c '^degraded:' <<<"$OUT")"
}

lbl_case missing nomatch missing
if [ "$RC" = 0 ] && [ "$N_LLIST" = 1 ] && [ "$N_LCREATE" = 1 ] && [ "$N_ICREATE" = 2 ] \
   && grep -qF 'gh label create target:target-foo' <<<"$LOG" \
   && grep -qF -- '--description Fleet target: target-foo' <<<"$LOG" \
   && grep -qF -- '--color d4c5f9' <<<"$LOG" \
   && grep -q 'summary: created=2 .*failed=0' <<<"$OUT"; then
  ok "76a --apply, label missing: ONE probe, ONE label create (convention), then both issues created" "(exit $RC)"
else
  no "76a --apply, label missing" "exit=$RC list=$N_LLIST lcreate=$N_LCREATE icreate=$N_ICREATE log=[$LOG] out=[$OUT]"
fi

lbl_case exists nomatch exists
if [ "$RC" = 0 ] && [ "$N_LLIST" = 1 ] && [ "$N_LCREATE" = 0 ] && [ "$N_ICREATE" = 2 ]; then
  ok "76b --apply, label exists: ONE probe for two rows, no label create" "(exit $RC)"
else
  no "76b --apply, label exists" "exit=$RC list=$N_LLIST lcreate=$N_LCREATE icreate=$N_ICREATE log=[$LOG]"
fi

lbl_case listfail nomatch listfail
if [ "$RC" = 1 ] && [ "$N_DEGR" = 1 ] && [ "$N_ICREATE" = 0 ] && [ "$N_LCREATE" = 0 ] \
   && grep -q "^degraded:.*target:target-foo" <<<"$OUT" && ! grep -q 'ERROR: gh issue create' <<<"$OUT"; then
  ok "76c label probe fails: ONE degraded line, exit 1, zero issue creates (never N per-row failures)" "(exit $RC)"
else
  no "76c label probe fails" "exit=$RC degr=$N_DEGR icreate=$N_ICREATE lcreate=$N_LCREATE out=[$OUT]"
fi

lbl_case failjson nomatch failjson
if [ "$RC" = 1 ] && [ "$N_DEGR" = 1 ] && [ "$N_ICREATE" = 0 ] && [ "$N_LCREATE" = 0 ]; then
  ok "76c2 label probe exit 1 with a parseable '[]' reply: exit code wins → degraded, no label/issue create" "(exit $RC)"
else
  no "76c2 label probe rc must win over the reply" "exit=$RC degr=$N_DEGR icreate=$N_ICREATE lcreate=$N_LCREATE out=[$OUT]"
fi

lbl_case createfail nomatch createfail
if [ "$RC" = 1 ] && [ "$N_DEGR" = 1 ] && [ "$N_ICREATE" = 0 ] && [ "$N_LCREATE" = 1 ] && [ "$N_LLIST" = 2 ]; then
  ok "76d label create fails and the re-probe still finds nothing: ONE degraded line, exit 1, zero issue creates" "(exit $RC)"
else
  no "76d label create fails" "exit=$RC degr=$N_DEGR icreate=$N_ICREATE lcreate=$N_LCREATE out=[$OUT]"
fi

lbl_case listempty nomatch listempty
if [ "$RC" = 1 ] && [ "$N_DEGR" = 1 ] && [ "$N_ICREATE" = 0 ] && [ "$N_LCREATE" = 0 ]; then
  ok "76e label probe exit 0 + EMPTY reply: degraded (not read as 'missing' or 'exists'), no creates" "(exit $RC)"
else
  no "76e label probe empty reply" "exit=$RC degr=$N_DEGR icreate=$N_ICREATE lcreate=$N_LCREATE out=[$OUT]"
fi

lbl_case fuzzy nomatch fuzzyonly
if [ "$RC" = 0 ] && [ "$N_LCREATE" = 1 ] && [ "$N_ICREATE" = 2 ]; then
  ok "76f fuzzy label hit (target:target-foo-extra) is NOT the label: exact name required, label created" "(exit $RC)"
else
  no "76f fuzzy label hit" "exit=$RC lcreate=$N_LCREATE icreate=$N_ICREATE log=[$LOG]"
fi

LBOX="$(mkbox case-label-dry)"; mk_gh_stub "$LBOX" nomatch "" missing
LRETRO="$(mk_retro "$LBOX" target-foo r-dry.md "<!-- review-status: pending -->" "$TWO_ROWS")"
run "$LBOX" "$LRETRO"
if [ "$RC" = 0 ] && ! grep -q 'gh ' "$LBOX/bin/gh.log" 2>/dev/null; then
  ok "76g dry-run: no gh call at all (no label probe)" "(exit $RC)"
else
  no "76g dry-run must not touch gh" "exit=$RC log=[$(cat "$LBOX/bin/gh.log" 2>/dev/null)]"
fi

# 76i (kit issue #1332 N2) — GitHub label names are case-insensitive: `TARGET:TARGET-FOO` IS the label.
lbl_case upper nomatch existsupper
if [ "$RC" = 0 ] && [ "$N_LCREATE" = 0 ] && [ "$N_ICREATE" = 2 ]; then
  ok "76i label exists with different letter case → treated as present (no create)" "(exit $RC)"
else
  no "76i case-insensitive label match" "exit=$RC lcreate=$N_LCREATE icreate=$N_ICREATE out=[$OUT]"
fi

# 76j (kit issue #1332 N3) — a failed label create is re-probed ONCE (a concurrent run may have won).
lbl_case race nomatch racewin
if [ "$RC" = 0 ] && [ "$N_LCREATE" = 1 ] && [ "$N_LLIST" = 2 ] && [ "$N_DEGR" = 0 ] && [ "$N_ICREATE" = 2 ]; then
  ok "76j label create fails but the re-probe finds it (concurrent create) → proceed, issues created" "(exit $RC)"
else
  no "76j create-failure re-probe" "exit=$RC lcreate=$N_LCREATE list=$N_LLIST degr=$N_DEGR icreate=$N_ICREATE out=[$OUT]"
fi

lbl_case alldup match missing
if [ "$RC" = 0 ] && [ "$N_LLIST" = 0 ] && [ "$N_LCREATE" = 0 ] && [ "$N_ICREATE" = 0 ]; then
  ok "76h every row already deduped: no label probe (probe is lazy, right before the first create)" "(exit $RC)"
else
  no "76h all-duplicate run" "exit=$RC list=$N_LLIST lcreate=$N_LCREATE icreate=$N_ICREATE"
fi


# ---------------------------------------------------------------------------
# 77 — ENTRY-FORM (kit issue #1332): an APPLIED retro in the `### D<N> —` entry form → `no-match`
#      (reconcile-issues.sh says `no-match: no open deltas` for the same file). A PENDING one is
#      SEEDED (cases 78*): the same IDs reconcile matches.
ENTRY_FIX="$HERE/fixtures/retro-entry-form-applied-3.md"
[ -f "$ENTRY_FIX" ] || { echo "FATAL: fixture missing: $ENTRY_FIX" >&2; exit 2; }
box77="$(mkbox case-entry-form)"; mk_gh_stub "$box77" nomatch
cp "$ENTRY_FIX" "$box77/rh/target-foo/retros/r77a.md"
run "$box77" "$box77/rh/target-foo/retros/r77a.md"
if [ "$RC" = 0 ] && grep -q "^no-match: retro is 'applied'" <<<"$OUT" && ! grep -q 'unclassifiable' <<<"$OUT"; then
  ok "77a applied entry-form retro → no-match (same file reconcile reports as no open deltas)" "(exit $RC)"
else
  no "77a applied entry-form retro" "exit=$RC out=[$OUT]"
fi

# 78 — SEED THE ENTRY FORM (kit issue #1332 N1). Fixture priorities: D1 high, D2 high, D3 medium.
mk_entry_retro() {   # mk_entry_retro <box> <fname> <marker-line>
  sed "s/^<!-- review-status: applied.*-->\$/$3/" "$ENTRY_FIX" > "$1/rh/target-foo/retros/$2"
  printf '%s' "$1/rh/target-foo/retros/$2"
}
box78="$(mkbox case-entry-seed)"; mk_gh_stub "$box78" nomatch
r78="$(mk_entry_retro "$box78" r78.md '<!-- review-status: pending -->')"
run "$box78" "$r78"
if [ "$RC" = 0 ] && [ "$(grep -c '^planned-issue:' <<<"$OUT")" = 3 ] \
   && grep -q '^planned-issue: A tool ships no export script; a bridge script covers it$' <<<"$OUT" \
   && grep -q 'Source retro: target-foo/retros/r78.md · D1$' <<<"$OUT" \
   && grep -q 'Source retro: target-foo/retros/r78.md · D3$' <<<"$OUT" \
   && ! grep -q 'unclassifiable' <<<"$OUT"; then
  ok "78a dry-run pending entry-form retro: 3 planned issues, title after the dash, signature · D<N>" "(exit $RC)"
else
  no "78a dry-run entry-form" "exit=$RC out=[$OUT]"
fi
# priority from the **Priority** line: D1 high, D3 medium (labels line follows its title line)
if <<<"$(grep -A1 '^planned-issue: A tool ships' <<<"$OUT")" grep -q 'priority:high' \
   && <<<"$(grep -A1 '^planned-issue: Verify the numerical claim' <<<"$OUT")" grep -q 'priority:medium'; then
  ok "78b entry priority read from the **Priority** line (D1 high, D3 medium)" "()"
else
  no "78b entry priority" "out=[$OUT]"
fi
run "$box78" "$r78" --apply
if [ "$RC" = 0 ] && grep -q 'summary: created=3 ' <<<"$OUT" \
   && grep -qF 'Source retro: target-foo/retros/r78.md · D2' "$box78/bin/gh.log"; then
  ok "78c --apply: 3 issues created; dedup searched the · D<N> signature" "(exit $RC)"
else
  no "78c --apply entry-form" "exit=$RC out=[$OUT] log=[$(cat "$box78/bin/gh.log")]"
fi
box78d="$(mkbox case-entry-seed-dup)"; mk_gh_stub "$box78d" match
r78d="$(mk_entry_retro "$box78d" r78d.md '<!-- review-status: pending -->')"
run "$box78d" "$r78d" --apply
if [ "$RC" = 0 ] && grep -q 'summary: created=0 skipped-duplicate=3 ' <<<"$OUT"; then
  ok "78d --apply, every entry already filed → 3 skipped-duplicate, 0 created" "(exit $RC)"
else
  no "78d entry-form dedup" "exit=$RC out=[$OUT]"
fi
# PARTIAL: shipped D1, D2 → only D3 is open (list edge: LAST entry is the survivor)
box78e="$(mkbox case-entry-seed-partial)"; mk_gh_stub "$box78e" nomatch
r78e="$(mk_entry_retro "$box78e" r78e.md '<!-- review-status: applied 2026-07-31 · kit abc · PARTIAL — shipped: D1, D2 -->')"
run "$box78e" "$r78e"
if [ "$RC" = 0 ] && [ "$(grep -c '^planned-issue:' <<<"$OUT")" = 1 ] && grep -q '· D3$' <<<"$OUT"; then
  ok "78e PARTIAL entry-form retro (shipped D1, D2) → only D3 planned" "(exit $RC)"
else
  no "78e PARTIAL entry-form" "exit=$RC out=[$OUT]"
fi
# Entries WITHOUT a matching shape for the id (a **D1** heading) are not seedable: WARN, rest still seeds.
box78f="$(mkbox case-entry-seed-gap)"; mk_gh_stub "$box78f" nomatch
r78f="$box78f/rh/target-foo/retros/r78f.md"
printf '<!-- review-status: pending -->\n# r\n\n## Proposed kit deltas\n\n### **D1** — bold id\n\n### D2 — plain id\n' > "$r78f"
run "$box78f" "$r78f"
if [ "$RC" = 0 ] && [ "$(grep -c '^planned-issue:' <<<"$OUT")" = 1 ] && grep -q '^WARN: .*1 of 2' <<<"$OUT"; then
  ok "78f entry with an unusable ID token: WARN names the gap (1 of 2), the usable entry still seeds" "(exit $RC)"
else
  no "78f entry ID gap WARN" "exit=$RC out=[$OUT]"
fi

# ---------------------------------------------------------------------------
# 79 — UNREGISTERED TARGET (kit issue #1332 NB1): the basename fallback (no TARGETS.md row for the
#      retro's directory — e.g. ANOTHER kit's retro) must never auto-create a `target:<basename>`
#      label and its issues in this repo. --apply: ONE typed degraded line naming the unregistered
#      target, exit 1, no label create, no issue create. Dry-run still plans (no gh call).
box79="$(mkbox case-unregistered)"; mk_gh_stub "$box79" nomatch "" missing
mkdir -p "$box79/rh/other-kit/retros"
r79="$box79/rh/other-kit/retros/r79.md"
printf '<!-- review-status: pending -->\n# r\n\n## Proposed kit deltas\n\n| # | Proposed change | Target (file) | Evidence | Type | Priority |\n|---|---|---|---|---|---|\n| 1 | a | CLAUDE.md | B1 | fix | HIGH |\n| 2 | b | CLAUDE.md | B2 | fix | HIGH |\n' > "$r79"
run "$box79" "$r79" --apply
LOG79="$(cat "$box79/bin/gh.log" 2>/dev/null)"
if [ "$RC" = 1 ] && [ "$(grep -c '^degraded:' <<<"$OUT")" = 1 ] && grep -q "^degraded:.*unregistered.*other-kit" <<<"$OUT" \
   && ! grep -q 'gh label create' <<<"$LOG79" && ! grep -q 'gh issue create' <<<"$LOG79"; then
  ok "79a --apply, unregistered target: ONE degraded line naming it, exit 1, no label/issue create" "(exit $RC)"
else
  no "79a unregistered target --apply" "exit=$RC out=[$OUT] log=[$LOG79]"
fi
run "$box79" "$r79"
if [ "$RC" = 0 ] && [ "$(grep -c '^planned-issue:' <<<"$OUT")" = 2 ]; then
  ok "79b dry-run on an unregistered target still plans its issues" "(exit $RC)"
else
  no "79b dry-run unregistered" "exit=$RC out=[$OUT]"
fi

# 79c (NB3) — stage's unclassifiable wording matches reconcile's: names both accepted forms.
box79c="$(mkbox case-unclass-wording)"; mk_gh_stub "$box79c" nomatch
printf '<!-- review-status: pending -->\n# r\n\n## Proposed kit deltas\n\nProse only, no table, no entries.\n' > "$box79c/rh/target-foo/retros/r79c.md"
run "$box79c" "$box79c/rh/target-foo/retros/r79c.md"
if [ "$RC" = 0 ] && grep -q "^unclassifiable: delta section found but contains neither row-table rows nor '### D<N> —' entries" <<<"$OUT"; then
  ok "79c stage unclassifiable message names both accepted forms (same wording as reconcile)" "(exit $RC)"
else
  no "79c unclassifiable wording" "exit=$RC out=[$OUT]"
fi

# ---------------------------------------------------------------------------
# 80 — FENCE TRACKING (kit issue #1356 item 1, #1369 b): fenced examples are documentation.
box80="$(mkbox case-fence-table)"; mk_gh_stub "$box80" nomatch
r80="$box80/rh/target-foo/retros/r80.md"
printf '<!-- review-status: pending -->\n# r\n\n## Proposed kit deltas\n\n| # | Proposed change | Target (file) | Evidence | Type | Priority |\n|---|---|---|---|---|---|\n| 1 | real row | CLAUDE.md | B1 | fix | HIGH |\n\n```markdown\n| 2 | fenced example row | CLAUDE.md | B2 | fix | LOW |\n```\n' > "$r80"
run "$box80" "$r80"
if [ "$RC" = 0 ] && [ "$(grep -c '^planned-issue:' <<<"$OUT")" = 1 ] && grep -q '^planned-issue: real row' <<<"$OUT"; then
  ok "80a a table row inside a fenced example is not seeded (1 planned: the real row)" "(exit $RC)"
else
  no "80a fenced table row" "exit=$RC out=[$OUT]"
fi
box80b="$(mkbox case-fence-entry)"; mk_gh_stub "$box80b" nomatch
r80b="$box80b/rh/target-foo/retros/r80b.md"
printf '<!-- review-status: pending -->\n# r\n\n## Proposed kit deltas\n\n### D1 — first (priority: high)\n\n```\n### D99 — fenced fake\n**Priority**: HIGH\n```\n\n### D2 — second (NEW, MEDIUM)\n' > "$r80b"
run "$box80b" "$r80b"
if [ "$RC" = 0 ] && [ "$(grep -c '^planned-issue:' <<<"$OUT")" = 2 ] && ! grep -q 'D99' <<<"$OUT"; then
  ok "80b a fenced '### D99 —' entry is not seeded (D1, D2 only)" "(exit $RC)"
else
  no "80b fenced entry" "exit=$RC out=[$OUT]"
fi
# 80c — heading-only priority (#1356 item 2) yields the priority label
if <<<"$(grep -A1 '^planned-issue: first' <<<"$OUT")" grep -q 'priority:high' \
   && <<<"$(grep -A1 '^planned-issue: second' <<<"$OUT")" grep -q 'priority:medium'; then
  ok "80c priority written only in the heading → priority:high / priority:medium labels" "(exit $RC)"
else
  no "80c heading priority label" "out=[$OUT]"
fi
# 80d — a 4-space-indented fence opener (indented code) hides nothing (#1369 b)
box80d="$(mkbox case-fence-indented)"; mk_gh_stub "$box80d" nomatch
r80d="$box80d/rh/target-foo/retros/r80d.md"
printf '<!-- review-status: pending -->\n# r\n\n## Proposed kit deltas\n\n### D1 — one\n\n    ```\n### D2 — two\n### D3 — three\n' > "$r80d"
run "$box80d" "$r80d"
if [ "$RC" = 0 ] && [ "$(grep -c '^planned-issue:' <<<"$OUT")" = 3 ]; then
  ok "80d a 4-space-indented fence opener opens nothing (3 planned)" "(exit $RC)"
else
  no "80d indented opener" "exit=$RC out=[$OUT]"
fi

# ---------------------------------------------------------------------------
# 81 — LIST LIMIT (kit issue #1369 c): the dedup `gh issue list` carried NO --limit (gh defaults to
#      30), so a busy repo silently truncated the result and a duplicate could be re-created.
#      Now: an explicit --limit, and a reply that fills it is a typed failure (never "no match").
box81="$(mkbox case-limit)"; mk_gh_stub "$box81" nomatch
run "$box81" "$(mk_retro "$box81" target-foo r81.md '<!-- review-status: pending -->' '| 1 | a | CLAUDE.md | B1 | fix | HIGH |')" --apply
if [ "$RC" = 0 ] && grep -qE 'gh issue list .*--limit [0-9]+' "$box81/bin/gh.log"; then
  ok "81a the dedup gh issue list passes an explicit --limit" "(exit $RC)"
else
  no "81a explicit --limit" "exit=$RC log=[$(cat "$box81/bin/gh.log" 2>/dev/null)]"
fi
box81b="$(mkbox case-limit-full)"; mk_gh_stub "$box81b" page2
r81b="$(mk_retro "$box81b" target-foo r81b.md '<!-- review-status: pending -->' '| 1 | a | CLAUDE.md | B1 | fix | HIGH |')"
STAGE_RETRO_ISSUES_LIST_LIMIT=2 run "$box81b" "$r81b" --apply
if [ "$RC" != 0 ] && grep -q '^ERROR: gh issue list (dedup) returned 2 results = the --limit 2 cap' <<<"$OUT" \
   && ! grep -q 'gh issue create' "$box81b/bin/gh.log"; then
  ok "81b a reply that FILLS the limit is a typed failure and creates nothing" "(exit $RC)"
else
  no "81b full page" "exit=$RC out=[$OUT] log=[$(cat "$box81b/bin/gh.log")]"
fi
box81c="$(mkbox case-limit-under)"; mk_gh_stub "$box81c" page2
r81c="$(mk_retro "$box81c" target-foo r81c.md '<!-- review-status: pending -->' '| 1 | a | CLAUDE.md | B1 | fix | HIGH |')"
STAGE_RETRO_ISSUES_LIST_LIMIT=3 run "$box81c" "$r81c" --apply
if [ "$RC" = 0 ] && grep -q 'gh issue create' "$box81c/bin/gh.log" && ! grep -q 'cap' <<<"$OUT"; then
  ok "81c a reply one UNDER the limit is trusted (no-match → creates)" "(exit $RC)"
else
  no "81c under limit" "exit=$RC out=[$OUT]"
fi
# 81d — an invalid limit override is refused, not passed through
STAGE_RETRO_ISSUES_LIST_LIMIT=abc run "$box81c" "$r81c"
if [ "$RC" = 1 ] && grep -q '^degraded: STAGE_RETRO_ISSUES_LIST_LIMIT must be a positive integer' <<<"$OUT"; then
  ok "81d a non-numeric STAGE_RETRO_ISSUES_LIST_LIMIT is a typed degraded exit 1" "(exit $RC)"
else
  no "81d bad limit override" "exit=$RC out=[$OUT]"
fi
# 81f — a FULL page that still holds the exact signature is a duplicate, not a failure
box81f="$(mkbox case-limit-full-match)"; mk_gh_stub "$box81f" fuzzyplusexact
r81f="$(mk_retro "$box81f" target-foo r81f.md '<!-- review-status: pending -->' '| 1 | a | CLAUDE.md | B1 | fix | HIGH |')"
STAGE_RETRO_ISSUES_LIST_LIMIT=2 run "$box81f" "$r81f" --apply
if [ "$RC" = 0 ] && grep -q '^skipped-duplicate:' <<<"$OUT" && ! grep -q 'cap' <<<"$OUT"; then
  ok "81f a full page that contains the exact signature dedups (no spurious cap error)" "(exit $RC)"
else
  no "81f full page with match" "exit=$RC out=[$OUT]"
fi
# 81e — the gh stub itself rejects an unknown flag and an unknown --json field (it must not invent support)
box81e="$(mkbox case-stub-strict)"; mk_gh_stub "$box81e" nomatch
"$box81e/bin/gh" issue list --bogus x >/dev/null 2>&1; _rc1=$?
"$box81e/bin/gh" issue list --json state,nope >/dev/null 2>&1; _rc2=$?
"$box81e/bin/gh" issue list --limit 0 >/dev/null 2>&1; _rc3=$?
"$box81e/bin/gh" issue list --repo r --state all --search q --json state,body --limit 5 >/dev/null 2>&1; _rc4=$?
if [ "$_rc1" = 2 ] && [ "$_rc2" = 2 ] && [ "$_rc3" = 2 ] && [ "$_rc4" = 0 ]; then
  ok "81e gh stub rejects unknown flag / unknown --json field / --limit 0; accepts the real shape" "(rc $_rc1 $_rc2 $_rc3 $_rc4)"
else
  no "81e stub strictness" "rc=$_rc1 $_rc2 $_rc3 $_rc4"
fi

# ---------------------------------------------------------------------------
# 82 — UNREADABLE retro (R3-unreadable-silent-zero): an existing but unreadable file is a typed
#      degraded exit 1, never "empty-input" / a silent zero. Unclosed fence: one WARN, still seeds.
box82="$(mkbox case-unreadable)"; mk_gh_stub "$box82" nomatch
r82="$(mk_retro "$box82" target-foo r82.md '<!-- review-status: pending -->' '| 1 | a | CLAUDE.md | B1 | fix | HIGH |')"
if [ "$(id -u)" = 0 ]; then
  echo "  SKIP  82a unreadable retro: running as root, permissions do not bind"
else
  chmod 000 "$r82"; run "$box82" "$r82"; chmod 600 "$r82"
  if [ "$RC" = 1 ] && grep -q '^degraded: retro not readable' <<<"$OUT" && ! grep -q 'empty-input\|planned-issue' <<<"$OUT"; then
    ok "82a unreadable retro → typed degraded exit 1 (no empty-input, nothing planned)" "(exit $RC)"
  else
    no "82a unreadable retro" "exit=$RC out=[$OUT]"
  fi
fi
box82b="$(mkbox case-unclosed-fence)"; mk_gh_stub "$box82b" nomatch
r82b="$box82b/rh/target-foo/retros/r82b.md"
printf '<!-- review-status: pending -->\n# r\n\n## Proposed kit deltas\n\n### D1 — one\n\n```\n### D2 — two\n' > "$r82b"
run "$box82b" "$r82b"
if [ "$RC" = 0 ] && [ "$(grep -c '^planned-issue:' <<<"$OUT")" = 2 ] && [ "$(grep -c '^WARN: unclosed code fence opened at line 8' <<<"$OUT")" = 1 ]; then
  ok "82b unclosed fence: both entries still seed (fail-open) and the WARN appears exactly once" "(exit $RC)"
else
  no "82b unclosed fence" "exit=$RC out=[$OUT]"
fi

# ---------------------------------------------------------------------------
# 83 — SIGPIPE race in the SUT (kit issue #1444). Under `set -o pipefail`, `printf '%s' "$big" |
#      grep -q PAT` exits 141 (the writer takes SIGPIPE once grep -q has matched and gone) whenever the
#      input outgrows the pipe buffer and the match sits early: a MATCH reads as a FAILURE. The
#      small-input cases above can never reach that, so these use inputs well past 64 KiB with the
#      match on the FIRST line / FIRST entry. Deterministic: a blocked writer is guaranteed its EPIPE.
#      (a) a >64 KiB `gh issue list` reply that starts with '[' and carries the exact OPEN match;
#      (b) a PARTIAL marker whose shipped list is >64 KiB with D1..D3 first.
sp_big_reply_stub() {   # sp_big_reply_stub <box>: swap the stub's reply() for a ~440 KB multi-line array
  local box="$1" fn="$1/bin/reply.fn" tmp="$1/bin/gh.new"
  cat > "$fn" <<'SPFN'
reply() { local _i=0; printf '[\n'; while [ "$_i" -lt 4000 ]; do printf '{"body":"unrelated padding issue %05d xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx","state":"OPEN"},\n' "$_i"; _i=$((_i+1)); done; printf '{"body":"Delta\\n\\n---\\n%s\\ntail","state":"%s"}\n]\n' "$_sig" "$1"; }
SPFN
  awk 'FNR == NR { fn = fn $0 "\n"; next } /^reply\(\) / { printf "%s", fn; next } { print }' "$fn" "$box/bin/gh" > "$tmp"
  cat "$tmp" > "$box/bin/gh"; rm -f "$tmp" "$fn"
}
sp_shipped_retro() {   # sp_shipped_retro <box> <fname>: entry-form retro, PARTIAL, shipped list D1..D3 + 150000 filler ids (~1.2 MB)
  # The ids are generated INSIDE awk and written to the file (never passed as an argument), so the
  # size is bounded by neither ARG_MAX nor the 128 KB per-argument limit: ~1.2 MB is ~19 pipe buffers
  # (64 KiB), so a piped `printf | grep -qxF D1` is certain to still be writing when grep -q exits.
  local box="$1" fname="$2" p
  p="$(mk_entry_retro "$box" "$fname" '<!-- review-status: applied 2026-07-31 · kit abc · PARTIAL — shipped: @@IDS@@ -->')"
  awk '/@@IDS@@/ { i = index($0, "@@IDS@@"); printf "%sD1, D2, D3", substr($0, 1, i - 1); for (n = 1; n <= 150000; n++) printf ", Z%06d", n; print substr($0, i + 7); next } { print }' "$p" > "$p.new" && mv "$p.new" "$p"
  printf '%s' "$p"
}
box83a="$(mkbox case-sigpipe-bigreply)"; mk_gh_stub "$box83a" match; sp_big_reply_stub "$box83a"
r83a="$(mk_entry_retro "$box83a" r83a.md '<!-- review-status: pending -->')"
run "$box83a" "$r83a" --apply
if [ "$RC" = 0 ] && grep -q 'summary: created=0 skipped-duplicate=3 ' <<<"$OUT"; then
  ok "83a --apply, a >64 KiB dedup reply opening with '[' → still 3 skipped-duplicate (no SIGPIPE flip)" "(exit $RC)"
else
  no "83a big dedup reply" "exit=$RC out=[${OUT:0:600}]"
fi
box83b="$(mkbox case-sigpipe-bigshipped)"; mk_gh_stub "$box83b" nomatch
r83b="$(sp_shipped_retro "$box83b" r83b.md)"
run "$box83b" "$r83b"
if [ "$RC" = 0 ] && ! grep -q '^planned-issue:' <<<"$OUT"; then
  ok "83b a ~1.2 MB shipped list with D1..D3 first → nothing planned (is_shipped keeps its match)" "(exit $RC)"
else
  no "83b big shipped list" "exit=$RC planned=$(grep -c '^planned-issue:' <<<"$OUT") out=[${OUT:0:600}]"
fi

if [ "${1:-}" = "--prove-teeth" ]; then
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  echo "-- teeth T1444: SUT pipe-to-grep -q race --"
  # Each mutant restores the PIPED form of one rewritten site; the matching 83x case must go red.
  sp_expr_912='s#if ! grep -q .^\[\[:space:\]\]\*\\\[. <<<"\$_existing"; then#if ! printf \x27%s\x27 "$_existing" | grep -q \x27^[[:space:]]*\\[\x27; then#'  # sigpipe-lint: allow sed anchor that restores the piped idiom in a T1444-a mutant
  sp_expr_639='s#grep -qxF "\$1" <<<"\$shipped_ids"#printf \x27%s\\n\x27 "$shipped_ids" | grep -qxF "$1"#'  # sigpipe-lint: allow sed anchor that restores the piped idiom in a T1444 mutant
  mbox="$(mkbox teeth-sigpipe-912)"; mk_gh_stub "$mbox" match; sp_big_reply_stub "$mbox"
  if mutant_sed "$SUT" "$mbox/research-sdd/toolbelt/stage-retro-issues.sh" -e "$sp_expr_912"; then
    run "$mbox" "$(mk_entry_retro "$mbox" r83t.md '<!-- review-status: pending -->')" --apply
    if ! grep -q 'summary: created=0 skipped-duplicate=3 ' <<<"$OUT" && grep -q 'unexpected reply' <<<"$OUT"; then
      ok "T1444-a teeth: piped '[' guard → big dedup reply read as unexpected (83a has teeth)" "()"
    else no "T1444-a teeth: piped form must flip 83a" "83a is THEATER: exit=$RC out=[${OUT:0:400}]"; fi
  else no "T1444-a: build mutant" "mutant_sed refused (vacuous/identical/broken)"; fi
  mbox="$(mkbox teeth-sigpipe-639)"; mk_gh_stub "$mbox" nomatch
  if mutant_sed "$SUT" "$mbox/research-sdd/toolbelt/stage-retro-issues.sh" -e "$sp_expr_639"; then
    run "$mbox" "$(sp_shipped_retro "$mbox" r83u.md)"
    if grep -q '^planned-issue:' <<<"$OUT"; then
      ok "T1444-b teeth: piped is_shipped → shipped D1..D3 re-planned (83b has teeth)" "()"
    else no "T1444-b teeth: piped form must flip 83b" "83b is THEATER: exit=$RC out=[${OUT:0:400}]"; fi
  else no "T1444-b: build mutant" "mutant_sed refused (vacuous/identical/broken)"; fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
