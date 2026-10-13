#!/usr/bin/env bash
# kit-writer-check.sh — mechanical writer discipline for kit work (kit issue #2208).
#
# Catches, BEFORE the full gate, three incident shapes from the 2026-10-11 chain:
#   (1) a writer ran only the plain suite of an edited script and broke mutants the full gate found (#2184);
#   (2) a writer used a name-based process kill on its own load loops (#2199);
#   (3) RED was asserted but never executed (#2184) — that one is the PR-body `RED:` line, checked in CI by
#       .github/scripts/parse-red-evidence.cjs, not here.
#
# Usage: kit-writer-check.sh --base <ref> [--head <ref> | --worktree] [--teeth-log DIR] [--format report|json] [--repo DIR]
#                              [--manifest-dir DIR] [--tolerate-stale-manifest] [--print-binding]
#        kit-writer-check.sh --write-teeth-log DIR --base <ref> [--repo DIR] <suite>...
#        kit-writer-check.sh --classify <path>...
#   Check mode. Changed files = `git diff --name-status -M <base>...<head>` (head defaults to HEAD; --worktree
#   diffs the merge-base against the working tree and adds untracked files), the same range suite-impact.sh uses.
#     required suites   every suite suite-impact.sh maps a changed production script to (see --classify for what
#                       production means), plus every changed *.test.sh. When suite-impact escalates to FULL the set
#                       is "every suite that names the changed file" (the map if none does) and a `full-gate-needed`
#                       note says the PR also needs the full gate. A changed production script no suite names is a
#                       `no-suite` finding. An empty requirement set says so (`required: 0`).
#     teeth evidence    one log per required *.test.sh in --teeth-log DIR (omitted = every log missing), named after the
#                       repo-relative suite path with / -> __ (research-sdd__toolbelt__tests__foo.test.sh.log), so the
#                       same basename in two corpora cannot collide. A log is a `--prove-teeth` run: the last summary
#                       line `== N passed · 0 failed ==` with N>0, a teeth banner line (`-- teeth ...` / `== teeth ...`,
#                       the marker run-all.sh counts) and no `  FAIL  ` line, else `missing-teeth <suite> <reason>`.
#                       Its FIRST line is the binding header `# writer-check: head=<sha> tree=<hash>` that
#                       --write-teeth-log writes: tree hashes the changed files' contents when the log was produced
#                       (path + blob id, sorted), head is informational. Check mode recomputes the tree; a missing,
#                       malformed or different header is `stale-teeth <suite>`: the log does not describe the code
#                       being checked (edit after the run, or a hand-written log). Suites that are not *.test.sh (node
#                       tests) take no --prove-teeth flag: `teeth-na`, never required.
#     waivers           tests/writer-check-waivers.txt, one `<repo-relative suite> <reason>` per line (# comments): a
#                       required suite named there needs no log (a suite that prints no teeth banner, or can only skip)
#                       and is reported `teeth-waived <suite> (<reason>)`, never silently. A line with no reason is a
#                       `bad-waiver` finding. The file is read from the checked tree; absent = nothing waived.
#     name-kill         an ADDED line (shell, python, js, ts; comment-only lines skipped) that kills processes by
#                       NAME: pkill / killall, `kill -1` and its signal forms (`kill -9 -1`, `kill -- -1`, `kill -TERM -1`),
#                       pgrep / pidof piped into xargs / while ... kill, or substituted into kill. Same verdicts as the
#                       hook's --strict-name-kill (templates/hook-pretool-pkill-guard.sh), pinned by one corpus
#                       (tests/fixtures/kit-writer-check/name-kill-corpus.txt). Kill a recorded PID instead.
#                       Opt out per line with a `# writer-check: allow-name-kill <reason>` comment on that line.
#   --print-binding prints the binding header for the checked range and exits (what --write-teeth-log writes).
#   --write-teeth-log runs each suite with --prove-teeth, bounded by `timeout` (KIT_WRITER_CHECK_TIMEOUT seconds,
#   default 900), writing the log (header + output) the check expects; it binds to the WORKTREE contents against
#   --base. Exit 1 if any suite failed.
#   --classify prints `production <path>` or `other <path>` per path and exits 0. Production = a script (.sh .py .mjs
#   .js .cjs .ts) under research-sdd/toolbelt, research-sdd/install or research-sdd/templates, EXCEPT suites
#   (tests/*.test.*), tests/fixtures/**, other tests/ sub-directories and research-sdd/install/tests/**; the test
#   infrastructure (tests/run-all.sh, suite-impact.sh, shard-join.sh, tests/lib/**) counts. parse-red-evidence.cjs
#   implements the same rule; tests/fixtures/kit-writer-check/production-paths.txt pins both.
#
#   --manifest-dir / --tolerate-stale-manifest pass straight to suite-impact.sh: replaying an OLD commit whose tree
#   predates the impact manifests (point --manifest-dir at a current tests/ dir, tolerate names that no longer exist).
#
# Exit: 0 clean · 1 findings · 2 degraded or usage.   Typed degraded line on stderr: `degraded: kit-writer-check: <reason>`.
# Finding lines (report): `missing-teeth <suite> <reason>` · `stale-teeth <suite> <reason>` · `name-kill <file>:<line>` ·
# `no-suite <file>` · `bad-waiver <file>:<line>`.
# Note lines (never fail): `full-gate-needed: <reason>` · `teeth-na <suite>` · `teeth-waived <suite> (<reason>)` ·
# `required: 0 (...)`.
# Known limits: the name-kill scan is a line regex, not a shell parser (a kill assembled at run time is invisible; a
# multi-line pipe into while-read is only seen when it sits on one line); a teeth log proves a run happened only as far as
# the binding and the log are honest — the full gate is still the authority.
set -uo pipefail

SELF_NAME="kit-writer-check"
SELF_DIR="$(cd -P -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
IMPACT="${KIT_WRITER_CHECK_IMPACT:-$SELF_DIR/../tests/suite-impact.sh}"
WAIVER_REL="research-sdd/toolbelt/tests/writer-check-waivers.txt"

degraded() { echo "degraded: $SELF_NAME: $*" >&2; exit 2; }
usage() {
  echo "usage: $SELF_NAME.sh --base <ref> [--head <ref>|--worktree] [--teeth-log DIR] [--format report|json] [--repo DIR] [--manifest-dir DIR] [--tolerate-stale-manifest] [--print-binding]" >&2
  echo "       $SELF_NAME.sh --write-teeth-log DIR --base <ref> [--repo DIR] <suite>..." >&2
  echo "       $SELF_NAME.sh --classify <path>..." >&2
  exit 2
}

# is_production PATH: a changed script whose behavior suites exercise (deleted files are filtered by the caller).
# The same rule lives in .github/scripts/parse-red-evidence.cjs; tests/fixtures/kit-writer-check/production-paths.txt pins both.
is_production() {
  case "$1" in
    research-sdd/toolbelt/tests/fixtures/*) return 1 ;;
    research-sdd/toolbelt/tests/lib/*) ;;                                  # test infrastructure counts
    research-sdd/toolbelt/tests/*.test.*) return 1 ;;                      # suites
    research-sdd/toolbelt/tests/*/*) return 1 ;;                           # any other tests/ sub-directory
    research-sdd/install/tests/*) return 1 ;;
    research-sdd/toolbelt/*|research-sdd/install/*|research-sdd/templates/*) ;;
    *) return 1 ;;
  esac
  case "$1" in *.sh|*.py|*.mjs|*.js|*.cjs|*.ts) return 0 ;; *) return 1 ;; esac
}

MANIFEST_DIR=""; TOLERATE=0; PRINT_BINDING=0; CLASSIFY=0
BASE=""; HEAD_REF="HEAD"; HEAD_GIVEN=0; WORKTREE=0; LOGDIR=""; FORMAT="report"; REPO_ARG="."; WRITE_DIR=""; WRITE=0
SUITES_ARG=()
while [ $# -gt 0 ]; do
  case "$1" in
    --base) [ $# -ge 2 ] || usage; BASE="$2"; shift 2 ;;
    --head) [ $# -ge 2 ] || usage; HEAD_REF="$2"; HEAD_GIVEN=1; shift 2 ;;
    --worktree) WORKTREE=1; shift ;;
    --teeth-log) [ $# -ge 2 ] || usage; LOGDIR="$2"; shift 2 ;;
    --format) [ $# -ge 2 ] || usage; FORMAT="$2"; shift 2 ;;
    --repo) [ $# -ge 2 ] || usage; REPO_ARG="$2"; shift 2 ;;
    --manifest-dir) [ $# -ge 2 ] || usage; MANIFEST_DIR="$2"; shift 2 ;;
    --tolerate-stale-manifest) TOLERATE=1; shift ;;
    --print-binding) PRINT_BINDING=1; shift ;;
    --classify) CLASSIFY=1; shift ;;
    --write-teeth-log) [ $# -ge 2 ] || usage; WRITE=1; WRITE_DIR="$2"; shift 2 ;;
    -h|--help) usage ;;
    -*) echo "$SELF_NAME: unknown argument: $1" >&2; usage ;;
    *) SUITES_ARG+=("$1"); shift ;;
  esac
done

if [ "$CLASSIFY" = 1 ]; then
  [ "${#SUITES_ARG[@]}" -gt 0 ] || usage
  for p in "${SUITES_ARG[@]}"; do
    if is_production "$p"; then echo "production $p"; else echo "other $p"; fi
  done
  exit 0
fi

case "$FORMAT" in report|json) ;; *) echo "$SELF_NAME: --format must be report or json" >&2; usage ;; esac
for t in git grep awk sort mktemp timeout sed; do
  command -v "$t" >/dev/null 2>&1 || degraded "$t not found on PATH"
done
REPO="$(git -C "$REPO_ARG" rev-parse --show-toplevel 2>/dev/null)" || degraded "not a git repository: $REPO_ARG"

if [ "$WRITE" = 1 ]; then
  [ "${#SUITES_ARG[@]}" -gt 0 ] || { echo "$SELF_NAME: --write-teeth-log needs at least one suite" >&2; usage; }
  [ -n "$BASE" ] || { echo "$SELF_NAME: --write-teeth-log needs --base (the log is bound to the changed files against it)" >&2; usage; }
  WORKTREE=1; HEAD_GIVEN=0
else
  [ -n "$BASE" ] || usage
  [ "${#SUITES_ARG[@]}" -eq 0 ] || { echo "$SELF_NAME: unexpected argument: ${SUITES_ARG[0]}" >&2; usage; }
  if [ "$WORKTREE" = 1 ] && [ "$HEAD_GIVEN" = 1 ]; then echo "$SELF_NAME: --worktree and --head are mutually exclusive" >&2; usage; fi
  if [ -n "$LOGDIR" ]; then
    [ -d "$LOGDIR" ] || degraded "teeth-log dir absent: $LOGDIR"
    LOGDIR="$(cd -P -- "$LOGDIR" && pwd -P)"
  fi
  [ "$PRINT_BINDING" = 1 ] || [ -f "$IMPACT" ] || degraded "suite-impact.sh not found: $IMPACT"
fi

TMP="$(mktemp -d)" || degraded "cannot create a temp dir"
trap 'rm -rf "$TMP"' EXIT

git -C "$REPO" rev-parse --verify -q "$BASE^{commit}" >/dev/null 2>&1 || degraded "bad base ref: $BASE"
if [ "$WORKTREE" = 1 ]; then
  RANGE_BASE="$(git -C "$REPO" merge-base "$BASE" HEAD 2>/dev/null)" || degraded "no merge-base of $BASE and HEAD"
else
  git -C "$REPO" rev-parse --verify -q "$HEAD_REF^{commit}" >/dev/null 2>&1 || degraded "bad head ref: $HEAD_REF"
fi

# ---- changed files + added lines ---------------------------------------------------------------------------
if [ "$WORKTREE" = 1 ]; then
  git -C "$REPO" diff --name-status -M "$RANGE_BASE" > "$TMP/changes" 2>/dev/null || degraded "git diff failed against $RANGE_BASE"
  git -C "$REPO" ls-files -o --exclude-standard 2>/dev/null | while IFS= read -r f; do printf 'A\t%s\n' "$f"; done >> "$TMP/changes"
  git -C "$REPO" diff -U0 --no-color -M "$RANGE_BASE" > "$TMP/udiff" 2>/dev/null || degraded "git diff -U0 failed against $RANGE_BASE"
  git -C "$REPO" ls-files -o --exclude-standard 2>/dev/null | while IFS= read -r f; do
    [ -f "$REPO/$f" ] || continue
    printf 'diff --git a/%s b/%s\n--- /dev/null\n+++ b/%s\n@@ -0,0 +1,0 @@\n' "$f" "$f" "$f"
    awk '{print "+" $0}' "$REPO/$f"   # the scanner numbers these from the synthetic hunk header
  done >> "$TMP/udiff"
else
  git -C "$REPO" diff --name-status -M "$BASE...$HEAD_REF" > "$TMP/changes" 2>/dev/null || degraded "git diff failed for $BASE...$HEAD_REF"
  git -C "$REPO" diff -U0 --no-color -M "$BASE...$HEAD_REF" > "$TMP/udiff" 2>/dev/null || degraded "git diff -U0 failed for $BASE...$HEAD_REF"
fi

# ---- binding: what a teeth log is tied to --------------------------------------------------------------------------
# tree = hash of "<path> <blob id>" for every changed file (the worktree's current contents, or the head commit's),
# a deleted/renamed-away path as "<path> DELETED". Same bytes -> same tree, whichever clone or commit they sit in.
binding_header() {
  local st a b p h head tree
  while IFS=$'\t' read -r st a b; do
    case "$st" in
      D*) printf '%s DELETED\n' "$a"; continue ;;
      R*|C*) p="$b"; [ "${st:0:1}" = R ] && printf '%s DELETED\n' "$a" ;;
      *) p="$a" ;;
    esac
    if [ "$WORKTREE" = 1 ]; then h="$(git -C "$REPO" hash-object -- "$p" 2>/dev/null)"
    else h="$(git -C "$REPO" rev-parse -q --verify "$HEAD_REF:$p" 2>/dev/null)"; fi
    printf '%s %s\n' "$p" "${h:-MISSING}"
  done < "$TMP/changes" | LC_ALL=C sort > "$TMP/bind"
  tree="$(git -C "$REPO" hash-object --stdin < "$TMP/bind")" || degraded "cannot hash the changed files"
  head="$(git -C "$REPO" rev-parse HEAD 2>/dev/null)" || head="unknown"
  printf '# writer-check: head=%s tree=%s\n' "$head" "$tree"
}

if [ "$PRINT_BINDING" = 1 ]; then binding_header; exit 0; fi

# ---- --write-teeth-log ----------------------------------------------------------------------------------
if [ "$WRITE" = 1 ]; then
  T_OUT="${KIT_WRITER_CHECK_TIMEOUT:-900}"
  case "$T_OUT" in ''|*[!0-9]*|0|0[0-9]*) degraded "KIT_WRITER_CHECK_TIMEOUT must be a positive integer, got: '$T_OUT'" ;; esac
  mkdir -p -- "$WRITE_DIR" || degraded "cannot create teeth-log dir: $WRITE_DIR"
  WRITE_DIR="$(cd -P -- "$WRITE_DIR" && pwd -P)"
  HDR="$(binding_header)"
  bad=0
  for s in "${SUITES_ARG[@]}"; do
    case "$s" in /*) sp="$s"; rel="${s#"$REPO"/}" ;; *) sp="$REPO/$s"; rel="$s" ;; esac
    if [ ! -f "$sp" ]; then echo "FAIL  $s: suite not found" >&2; bad=$((bad+1)); continue; fi
    case "$s" in *.test.sh) ;; *) echo "FAIL  $s: only *.test.sh suites take --prove-teeth" >&2; bad=$((bad+1)); continue ;; esac
    log="$WRITE_DIR/$(printf '%s' "$rel" | sed 's#/#__#g').log"
    (cd "$REPO" && timeout "$T_OUT" bash "$sp" --prove-teeth) > "$TMP/run.out" 2>&1
    rc=$?
    { printf '%s\n' "$HDR"; cat "$TMP/run.out"; } > "$log"
    if [ "$rc" -eq 0 ]; then echo "PASS  $s -> $log"
    elif [ "$rc" -eq 124 ]; then echo "FAIL  $s: timed out after ${T_OUT}s -> $log" >&2; bad=$((bad+1))
    else echo "FAIL  $s: exit $rc -> $log" >&2; bad=$((bad+1)); fi
  done
  [ "$bad" -eq 0 ] || exit 1
  exit 0
fi

# ---- suite-impact -------------------------------------------------------------------------------------------
IMPACT_ARGS=(--repo "$REPO" --base "$BASE" --format report)
[ -z "$MANIFEST_DIR" ] || IMPACT_ARGS+=(--manifest-dir "$MANIFEST_DIR")
[ "$TOLERATE" = 0 ] || IMPACT_ARGS+=(--tolerate-stale-manifest)
if [ "$WORKTREE" = 1 ]; then IMPACT_ARGS+=(--worktree); elif [ "$HEAD_GIVEN" = 1 ]; then IMPACT_ARGS+=(--head "$HEAD_REF"); fi
bash "$IMPACT" "${IMPACT_ARGS[@]}" > "$TMP/impact" 2> "$TMP/impact.err"
irc=$?
if [ "$irc" -ne 0 ]; then
  degraded "suite-impact.sh exited $irc: $(head -c 300 "$TMP/impact.err" | tr '\n' ' ')"
fi
FULL_REASON="$(sed -n 's/^Escalated to FULL: //p' "$TMP/impact" | head -n 1)"
# `<changed file> → <suite>` lines
awk -F ' → ' 'NF==2 && $1 ~ /^research-sdd\// {print $1 "\t" $2}' "$TMP/impact" | LC_ALL=C sort -u > "$TMP/map"

: > "$TMP/prod"; : > "$TMP/chsuites"
while IFS=$'\t' read -r st a b; do
  p="$a"; case "$st" in R*|C*) p="$b" ;; esac
  case "$st" in D*) continue ;; esac
  if is_production "$p"; then printf '%s\n' "$p" >> "$TMP/prod"; fi
  case "$p" in research-sdd/*/tests/*.test.sh)
    case "$p" in */fixtures/*) ;; *) printf '%s\n' "$p" >> "$TMP/chsuites" ;; esac ;;
  esac
done < "$TMP/changes"
LC_ALL=C sort -u -o "$TMP/prod" "$TMP/prod"; LC_ALL=C sort -u -o "$TMP/chsuites" "$TMP/chsuites"

FINDINGS="$TMP/findings"; NOTES="$TMP/notes"; : > "$FINDINGS"; : > "$NOTES"
# direct_suites FILE: every suite whose text names the basename of FILE as a word (head tree, or the working tree).
direct_suites() {
  local bn="${1##*/}" out line
  if [ "$WORKTREE" = 1 ]; then
    out="$(git -C "$REPO" grep -l -F -w --untracked -e "$bn" -- 'research-sdd/toolbelt/tests/*.test.sh' 'research-sdd/install/tests/*.test.sh' 2>/dev/null)"
    printf '%s\n' "$out"
  else
    out="$(git -C "$REPO" grep -l -F -w -e "$bn" "$HEAD_REF" -- 'research-sdd/toolbelt/tests/*.test.sh' 'research-sdd/install/tests/*.test.sh' 2>/dev/null)"
    while IFS= read -r line; do [ -n "$line" ] && printf '%s\n' "${line#"$HEAD_REF":}"; done <<<"$out"
  fi
}
# required suites = the suites suite-impact maps a changed production script to (its closure, small by
# construction when it does not escalate) or, under a FULL escalation (a widely used file reaches most of the
# corpus), the suites that name the file directly; plus every changed suite
: > "$TMP/req"
while IFS= read -r f; do
  [ -n "$f" ] || continue
  n=0
  if [ -n "$FULL_REASON" ]; then
    n="$(direct_suites "$f" | grep . | tee -a "$TMP/req" | grep -c .)"
  fi
  # not escalated, or escalated but no suite names the file: whatever the map reaches
  if [ "$n" -eq 0 ]; then
    n="$(awk -F'\t' -v f="$f" '$1==f {print $2}' "$TMP/map" | tee -a "$TMP/req" | grep -c .)"
  fi
  if [ "$n" -eq 0 ]; then printf 'no-suite\t%s\tno suite names this changed file\n' "$f" >> "$FINDINGS"; fi
done < "$TMP/prod"
cat "$TMP/chsuites" >> "$TMP/req"
LC_ALL=C sort -u -o "$TMP/req" "$TMP/req"
NREQ="$(grep -c . "$TMP/req")"
if [ -n "$FULL_REASON" ]; then printf 'full-gate-needed: %s\n' "$FULL_REASON" >> "$NOTES"; fi
if [ "$NREQ" -eq 0 ]; then
  printf 'required: 0 (no changed production script and no changed suite; the impact map found nothing to require)\n' >> "$NOTES"
fi

# ---- waivers (read from the checked tree; absent = nothing waived) ---------------------------------------------------
if [ "$WORKTREE" = 1 ]; then
  if [ -f "$REPO/$WAIVER_REL" ]; then cat "$REPO/$WAIVER_REL" > "$TMP/waivers"; else : > "$TMP/waivers"; fi
else
  git -C "$REPO" show "$HEAD_REF:$WAIVER_REL" > "$TMP/waivers" 2>/dev/null || : > "$TMP/waivers"
fi
: > "$TMP/waived"; wln=0
while IFS= read -r wl || [ -n "$wl" ]; do
  wln=$((wln+1))
  case "$wl" in ''|'#'*|[[:space:]]*'#'*) continue ;; esac
  wsuite="${wl%%[[:space:]]*}"; wreason="${wl#"$wsuite"}"; wreason="${wreason#"${wreason%%[![:space:]]*}"}"
  if [ -z "$wreason" ]; then printf 'bad-waiver\t%s:%s\tno reason for %s\n' "$(basename -- "$WAIVER_REL")" "$wln" "$wsuite" >> "$FINDINGS"; continue; fi
  printf '%s\t%s\n' "$wsuite" "$wreason" >> "$TMP/waived"
done < "$TMP/waivers"

# ---- teeth evidence -------------------------------------------------------------------------------------------
# check_log <suite> -> prints "<missing|stale>|<reason>" when the evidence is invalid, nothing when valid
check_log() {
  local s="$1" log summary n first
  if [ -z "$LOGDIR" ]; then echo "missing|no --teeth-log given"; return; fi
  log="$LOGDIR/$(printf '%s' "$s" | sed 's#/#__#g').log"
  if [ ! -f "$log" ]; then echo "missing|no log $(basename -- "$log")"; return; fi
  if [ ! -s "$log" ]; then echo "missing|log is empty"; return; fi
  first="$(head -n 1 "$log")"
  if ! grep -qE '^# writer-check: head=[0-9a-f]+ tree=[0-9a-f]{40}$' <<<"$first"; then
    echo "stale|no writer-check header (a log not produced by --write-teeth-log is not evidence)"; return
  fi
  if [ "${first##* tree=}" != "${BIND_HDR##* tree=}" ]; then
    echo "stale|changed files differ from when the log was written (re-run --write-teeth-log)"; return
  fi
  summary="$(grep -E '^== [0-9]+ passed · [0-9]+ failed ==[[:space:]]*$' "$log" | tail -n 1)"
  if [ -z "$summary" ]; then echo "missing|no summary line"; return; fi
  n="$(sed -E 's/^== ([0-9]+) passed · ([0-9]+) failed ==.*/\1 \2/' <<<"$summary")"
  if [ "${n#* }" != "0" ]; then echo "missing|summary reports failures: $summary"; return; fi
  if [ "${n%% *}" = "0" ]; then echo "missing|summary reports zero passed cases"; return; fi
  if grep -qE '^  FAIL  ' "$log"; then echo "missing|log contains a FAIL line"; return; fi
  if ! grep -qEi '^[[:space:]]*(--|==)[[:space:]]*teeth\b' "$log"; then echo "missing|plain run: no teeth banner (not a --prove-teeth run)"; return; fi
}
BIND_HDR="$(binding_header)"
while IFS= read -r s; do
  [ -n "$s" ] || continue
  case "$s" in
    *.test.sh)
      wr="$(awk -F'\t' -v s="$s" '$1==s {print $2; exit}' "$TMP/waived")"
      if [ -n "$wr" ]; then printf 'teeth-waived %s (%s)\n' "$s" "$wr" >> "$NOTES"; continue; fi
      res="$(check_log "$s")"
      if [ -n "$res" ]; then
        case "${res%%|*}" in
          stale) printf 'stale-teeth\t%s\t%s\n' "$s" "${res#*|}" >> "$FINDINGS" ;;
          *) printf 'missing-teeth\t%s\t%s\n' "$s" "${res#*|}" >> "$FINDINGS" ;;
        esac
      fi ;;
    *) printf 'teeth-na %s\n' "$s" >> "$NOTES" ;;
  esac
done < "$TMP/req"

# ---- name-kill scan over ADDED lines ------------------------------------------------------------------------
# Patterns use the bracket trick ([x]) so this file does not match itself. In shell the tool name must be in COMMAND
# position (line start, after ; & | ( { $( `bash -c '` or then/do/else/if/while/sudo/exec/env/nohup/xargs/time/timeout/
# command/nice, past flags, numbers and VAR=x), so prose, grep patterns and JSON fixtures that merely mention it do not
# trip. In python/js/ts the argv-list form ["tool", ...] and a call such as system(...tool...) count too.
# The verdicts are pinned to the hook's --strict-name-kill by tests/fixtures/kit-writer-check/name-kill-corpus.txt.
awk '
  BEGIN {
    kw  = "(then|do|else|elif|if|while|until|sudo|exec|env|nohup|xargs|time|timeout|command|nice)"
    pre = "(^|[;&|(`{]|[$][(]|(^|[^[:alnum:]_-])" kw "|-c[[:space:]]+[\"\047])[[:space:]]*"
    opt = "(([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*|-[^[:space:]]*|[0-9]+)[[:space:]]+)*"
    cmd = pre opt "(/[^[:space:]]*/)?([p]kill|[k]illall)([^[:alnum:]_.-]|$)"
    killsig = pre opt "[k]ill[[:space:]]+(-[A-Za-z0-9]+[[:space:]]+|--[[:space:]]+|-s[[:space:]]+[A-Za-z0-9]+[[:space:]]+)*-1([^0-9]|$)"
    pipekill = "([p]grep|[p]idof)[^&|;]*\\|[[:space:]]*(xargs|while)[^&]*(^|[^[:alnum:]_-])[k]ill([^[:alnum:]_-]|$)"
    subkill = "(^|[^[:alnum:]_-])[k]ill[^;|&]*(\\$\\(|`)[[:space:]]*([p]grep|[p]idof)"
    argv = "[\"\047]([p]kill|[k]illall)[\"\047]"
    call = "(system|run|call|Popen|check_call|check_output|exec[A-Za-z]*|spawn[A-Za-z]*)[(][^)]*[\"\047 ][p]kill"
  }
  /^\+\+\+ (b\/|\/dev\/null)/ { f=$2; sub(/^b\//,"",f); scan = (f ~ /\.(sh|bash|py|mjs|cjs|js|ts)$/); script = (f ~ /\.(py|mjs|cjs|js|ts)$/); next }
  /^--- /    { next }
  /^@@ /     { s=$3; sub(/^\+/,"",s); split(s, a, ","); ln=a[1]+0; next }
  /^\+/      {
    line=substr($0,2); cur=ln; ln++
    if (!scan) next
    if (line ~ /^[[:space:]]*(#|\/\/)/) next
    if (line ~ /writer-check:[[:space:]]*allow-name-kill/) next
    if (line ~ cmd || (script && (line ~ argv || line ~ call)) || line ~ killsig || line ~ pipekill || line ~ subkill)
      printf "name-kill\t%s:%d\tname-based process kill\n", f, cur
  }
' "$TMP/udiff" >> "$FINDINGS"

NF_="$(grep -c . "$FINDINGS")"

# ---- output --------------------------------------------------------------------------------------------------
jesc() { local s="${1//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\t'/ }"; printf '%s' "$s"; }
if [ "$FORMAT" = json ]; then
  printf '{"status":"%s","full_gate_needed":%s,"required":[' "$([ "$NF_" -eq 0 ] && echo ok || echo findings)" "$([ -n "$FULL_REASON" ] && echo true || echo false)"
  first=1; while IFS= read -r s; do [ -n "$s" ] || continue; [ $first = 1 ] || printf ','; first=0; printf '"%s"' "$(jesc "$s")"; done < "$TMP/req"
  printf '],"findings":['
  first=1; while IFS=$'\t' read -r ty subj det; do [ -n "$ty" ] || continue; [ $first = 1 ] || printf ','; first=0
    printf '{"type":"%s","subject":"%s","detail":"%s"}' "$(jesc "$ty")" "$(jesc "$subj")" "$(jesc "$det")"; done < "$FINDINGS"
  printf ']}\n'
else
  printf 'Required suites: %s\n' "$NREQ"
  sed 's/^/  /' "$TMP/req"
  cat "$NOTES"
  while IFS=$'\t' read -r ty subj det; do [ -n "$ty" ] || continue; printf '%s %s (%s)\n' "$ty" "$subj" "$det"; done < "$FINDINGS"
  printf 'Findings: %s\n' "$NF_"
fi
[ "$NF_" -eq 0 ] || exit 1
exit 0
