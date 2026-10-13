#!/usr/bin/env bash
# suite-impact.sh — which test suites does a change impact? A conservative impact map (kit issue #2201, part 1a).
#
# Given a git base ref it prints the suites a change can affect, or escalates to FULL (every suite). It is the
# instrument that will back `run-all.sh --impacted` (#2201) and the writer-discipline checker (#2208); it does
# not run anything itself and nothing in run-all.sh depends on it yet.
#
# Usage: suite-impact.sh --base <ref> [--head <ref> | --worktree] [--format list|report] [--repo DIR]
#                        [--manifest-dir DIR] [--tolerate-stale-manifest]
#        suite-impact.sh --audit [--repo DIR] [--manifest-dir DIR]
#        suite-impact.sh --deps-all | --deps <suite> [--repo DIR] [--manifest-dir DIR]
#   Changed files = `git diff --name-status -M <base>...<head>` (head defaults to HEAD). --worktree diffs the
#   merge-base of <base> and HEAD against the working tree and adds untracked files.
#   --format list    one repo-relative suite path per line (what run-all will consume)
#   --format report  (default) `Impacted: N of M suites`, `<changed> → <suite>` lines, counts, the escalation
#                    verdict and the selected list
#   --audit          re-derive the blind-spot set from the corpus and report suites missing from
#                    impact-blindspot.txt; also validates both manifests and lists unreachable production files
#   --deps-all       (kit issue #2201 part 2, the key of run-all.sh --cache) print each suite's FORWARD dependency set
#                    over the same word graph, on the working tree: tab-separated `DEP <suite> <file>` (a production
#                    file, a fixture file of a reached fixture dir, or another suite it runs), `BLIND <suite> <reason>`
#                    (listed in impact-blindspot.txt or flagged by the detector: its reach cannot be known),
#                    `ALWAYS <suite> manifest` (an always-run whole-tree reader: no key exists), `UNRESOLVED <suite> <reason>`
#                    (no dependency resolved at all), and a last
#                    `DEPS-SUMMARY <suites> <dep-lines>`. --deps <suite> prints one suite (repo-relative path). It does not
#                    change how a change is mapped to suites.
#
# Exit: 0 ok (selection printed, or FULL escalation printed) · 1 audit/manifest finding · 2 degraded or usage.
# Typed degraded line on stderr: `degraded: suite-impact: <reason>`.
#
# HOW THE MAP WORKS (a token graph, deliberately dumb):
#   Suites never `source` production code; they execute or copy it. So every file is reduced to its WORDS
#   ([A-Za-z0-9_.-]+, so `$HERE/../x.sh` yields `x.sh`), and a word equal to a production file's basename (or to
#   the directory name of a toolbelt sub-directory, or to a tests/fixtures/<dir> name) is an edge. A python
#   `import M` / `from M` line also yields the word `M.py`. Production files reference each other the same way
#   (`lib/x.sh`, `python3 x.py`, `$SELF_DIR/y.sh`), so the closure over REVERSE edges (cycles terminate: a visited
#   set) answers "which suites reach this file, directly or through other production files".
#   The tree analysed is the HEAD tree (git archive of research-sdd/), or the working tree with --worktree.
#
# IT ESCALATES TO FULL (prints `Escalated to FULL: <reason>` and every suite) on:
#   tests/lib/**, tests/run-all.sh, tests/shard-join.sh, tests/teeth-helper-waivers.txt, tests/suite-tiers.txt,
#   tests/impact-*.txt, tests/suite-impact.sh · research-sdd/install/** · research-sdd/templates/** · .github/**
#   · a .shellcheckrc · any ADDED / DELETED / RENAMED production file (toolbelt/**, non-markdown, outside tests/)
#   · a changed production/test-infra/kit-content file no suite reaches · a widely used file: the named libs
#   below, or a reverse closure of more than SUITE_IMPACT_WIDE_THRESHOLD (default 12) non-suite nodes
#   · any path this classifier cannot place (the root `.gitignore`, `.claude/**`, a non-markdown file with no
#   rule). Unplaceable is escalated, never skipped (CLAUDE.md section 7: it must prove it could see the file).
#
# ALWAYS-RUN (tests/impact-always.txt) are whole-tree readers a mapped selection cannot see; they are in every
# selection. BLIND-SPOT suites (tests/impact-blindspot.txt: eval, whole-kit copies, kit-wide globs, dynamically
# built script names) defeat the word map; they are added whenever a production CODE file changes, scoped by an
# optional REACH (kit issue #2201, part 1c): a manifest line `<suite> reach=<glob>[,<glob>...] <reason>` adds the
# suite only when a changed code file matches a glob (repo-relative, bash `case` patterns, `*` crosses `/`, each glob
# starts with `research-sdd/`, no `..`). A line without `reach=` keeps the unscoped behaviour (any code change). A code
# change outside research-sdd/toolbelt/ adds EVERY blind-spot suite (no reach glob covers it).
# `reach=` is parsed strictly and is valid only in impact-blindspot.txt; `--audit` also flags a glob matching no file.
# Docs-only changes (markdown outside templates/install, openspec/**, odd/**) select the always-run set plus
# whatever suite names the document's basename. No-change (empty diff) also selects the always-run set: the
# list is never silently empty; the report says `no-change`.
#
# Known limits: a script name assembled at run time (${x}.sh) is invisible to the map (hence the blind-spot
# manifest and --audit); the closure is over file names, not call sites, so it over-selects. Pure comment lines
# (`#` in .sh/.py, `//` in .mjs/.js) and Markdown fixtures are NOT edge sources (kit issue #2201, part 1c: prose
# mentions made research-sdd-status.sh reachable through ~77 nodes), except a comment that is a directive the
# suites rely on: `shellcheck source=`, `SENTINEL-`, `NG-`, `--prove-teeth:`, `summary-lint:`, `pipefail-audit:`.
# A mention in code, a string or a trailing comment on a code line is still an edge.
set -uo pipefail

SELF_NAME="suite-impact"
WIDE_THRESHOLD="${SUITE_IMPACT_WIDE_THRESHOLD-12}"   # validated below: a set-but-empty value is invalid, not "default"
# Libraries every other thing leans on: a change escalates without measuring the closure.
WIDE_NAMED="block-files.sh retro-status.sh retro-grammar.sh state-files.sh hook-emit.sh tool-env.sh target-paths.sh analysis_manifest.py gate.py adapter_core.py"

degraded() { echo "degraded: $SELF_NAME: $*" >&2; exit 2; }
usage() { echo "usage: $SELF_NAME.sh --base <ref> [--head <ref>|--worktree] [--format list|report] [--repo DIR] [--manifest-dir DIR] [--tolerate-stale-manifest] | --audit | --deps-all | --deps <suite>" >&2; exit 2; }

# ---- args ------------------------------------------------------------------------------------------------
BASE=""; HEAD_REF="HEAD"; HEAD_GIVEN=0; WORKTREE=0; FORMAT="report"; AUDIT=0; DEPS=0; DEPS_WANT=""; REPO_ARG="."; MANIFEST_DIR=""; TOLERATE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --base) [ $# -ge 2 ] || usage; BASE="$2"; shift 2 ;;
    --head) [ $# -ge 2 ] || usage; HEAD_REF="$2"; HEAD_GIVEN=1; shift 2 ;;
    --worktree) WORKTREE=1; shift ;;
    --format) [ $# -ge 2 ] || usage; FORMAT="$2"; shift 2 ;;
    --repo) [ $# -ge 2 ] || usage; REPO_ARG="$2"; shift 2 ;;
    --manifest-dir) [ $# -ge 2 ] || usage; MANIFEST_DIR="$2"; shift 2 ;;
    --tolerate-stale-manifest) TOLERATE=1; shift ;;
    --audit) AUDIT=1; shift ;;
    --deps-all) DEPS=1; WORKTREE=1; shift ;;
    --deps) [ $# -ge 2 ] || usage; DEPS=1; WORKTREE=1; DEPS_WANT="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "$SELF_NAME: unknown argument: $1" >&2; usage ;;
  esac
done
case "$FORMAT" in list|report) ;; *) echo "$SELF_NAME: --format must be list or report" >&2; usage ;; esac
[ "$AUDIT" = 1 ] || [ "$DEPS" = 1 ] || [ -n "$BASE" ] || usage
if [ "$WORKTREE" = 1 ] && [ "$HEAD_GIVEN" = 1 ]; then echo "$SELF_NAME: --worktree and --head are mutually exclusive" >&2; usage; fi
case "$WIDE_THRESHOLD" in ''|*[!0-9]*|0|0[0-9]*) degraded "SUITE_IMPACT_WIDE_THRESHOLD must be a positive integer, got: '$WIDE_THRESHOLD'" ;; esac
# a relative --manifest-dir is resolved against the caller's cwd, before this script changes directory
if [ -n "$MANIFEST_DIR" ]; then
  MANIFEST_DIR="$(cd -P -- "$MANIFEST_DIR" 2>/dev/null && pwd -P)" || { echo "degraded: $SELF_NAME: manifest directory absent: $MANIFEST_DIR" >&2; exit 2; }
fi

# ---- runtime deps (probe, never assume: CLAUDE.md section 7) -----------------------------------------------
for t in git grep sort awk tar mktemp find; do
  command -v "$t" >/dev/null 2>&1 || degraded "$t not found on PATH"
done

REPO="$(git -C "$REPO_ARG" rev-parse --show-toplevel 2>/dev/null)" || degraded "not a git repository: $REPO_ARG"
TMP="$(mktemp -d)" || degraded "cannot create a temp dir"
trap 'rm -rf "$TMP"' EXIT

# ---- the tree to analyse ---------------------------------------------------------------------------------
if [ "$AUDIT" = 1 ] || [ "$WORKTREE" = 1 ]; then
  ROOT="$REPO"
else
  git -C "$REPO" rev-parse --verify -q "$HEAD_REF^{commit}" >/dev/null 2>&1 || degraded "bad head ref: $HEAD_REF"
  # NOTE: `git archive` honours `export-ignore` in .gitattributes; a path marked that way never reaches the analysed
  # tree. The kit has none under research-sdd/ today; if one is added, this inventory silently omits it.
  ROOT="$TMP/tree"; mkdir -p "$ROOT"
  git -C "$REPO" archive "$HEAD_REF" research-sdd 2>/dev/null | tar -x -C "$ROOT" 2>/dev/null \
    || degraded "head $HEAD_REF has no research-sdd/ tree to analyse"
fi
[ -d "$ROOT/research-sdd" ] || degraded "no research-sdd/ directory under $ROOT"
cd "$ROOT" || degraded "cannot enter $ROOT"

TESTS_REL="research-sdd/toolbelt/tests"
[ -n "$MANIFEST_DIR" ] || MANIFEST_DIR="$ROOT/$TESTS_REL"

# ---- file inventory --------------------------------------------------------------------------------------
# One NUL-free path per line (a path containing a newline is not supported: the kit has none).
if [ "$AUDIT" = 1 ] || [ "$WORKTREE" = 1 ]; then
  git -C "$REPO" ls-files -co --exclude-standard -- research-sdd 2>/dev/null | while IFS= read -r f; do [ -f "$f" ] && printf '%s\n' "$f"; done | LC_ALL=C sort > "$TMP/files"
else
  find research-sdd -type f | LC_ALL=C sort > "$TMP/files"
fi
[ -s "$TMP/files" ] || degraded "empty inventory of research-sdd/ (could not look)"

# is_code_path PATH -> 0 when a change to PATH sets CODE_CHANGED (so the blind-spot set is considered), else 1.
# Mirrors the classification loop below: the tests tree, install/, templates/ and Markdown never get there. The audit
# matches reach globs against this universe, so a glob that only matches such files is reported dead.
is_code_path() {
  case "$1" in
    "$TESTS_REL"/*|research-sdd/install/*|research-sdd/templates/*|*.md) return 1 ;;
    research-sdd/*) return 0 ;;
  esac
  return 1
}

# kind_of PATH -> S | F | P | X (X: not a graph node; a FULL-escalation class or skipped)
kind_of() {
  local p="$1" rest
  case "$p" in
    "$TESTS_REL"/lib/*|"$TESTS_REL"/run-all.sh|"$TESTS_REL"/shard-join.sh|"$TESTS_REL"/teeth-helper-waivers.txt|"$TESTS_REL"/suite-tiers.txt|"$TESTS_REL"/impact-*.txt|"$TESTS_REL"/suite-impact.sh) echo X; return ;;
    "$TESTS_REL"/fixtures/*) echo F; return ;;
    "$TESTS_REL"/*.test.sh|"$TESTS_REL"/*.test.mjs) rest="${p#"$TESTS_REL"/}"; case "$rest" in */*) echo P ;; *) echo S ;; esac; return ;;
    research-sdd/install/tests/*.test.sh|research-sdd/install/tests/*.test.mjs) rest="${p#research-sdd/install/tests/}"; case "$rest" in */*) echo X ;; *) echo S ;; esac; return ;;
    research-sdd/install/*|research-sdd/templates/*) echo X; return ;;
    research-sdd/*) echo P; return ;;
  esac
  echo X
}

# ---- manifests -------------------------------------------------------------------------------------------
# suite_paths_for NAME -> every suite path whose basename minus .test.sh/.test.mjs is NAME
suite_paths_for() { awk -v n="$1" -F'\t' '$1=="S"{b=$2; sub(/^.*\//,"",b); sub(/\.test\.(sh|mjs)$/,"",b); if (b==n) print $2}' "$TMP/nodes"; }

: > "$TMP/nodes"
while IFS= read -r p; do
  k="$(kind_of "$p")"
  [ "$k" = X ] && continue
  printf '%s\t%s\n' "$k" "$p" >> "$TMP/nodes"
done < "$TMP/files"
awk -F'\t' '$1=="S"{print $2}' "$TMP/nodes" | LC_ALL=C sort > "$TMP/suites"
NSUITES="$(grep -c . "$TMP/suites")"
[ "$NSUITES" -gt 0 ] || degraded "no test suites found under $TESTS_REL (could not look)"

MANIFEST_BAD=0
# load_manifest FILE OUT [REACH_OUT]: validates (one `<suite> [reach=<globs>] <reason>` per line, suite exists, no
# duplicates) and writes the resolved suite paths to OUT. With REACH_OUT, `reach=` is accepted and every scoped
# suite is also written there as `<suite name>\t<suite path>\t<comma-separated globs>`; without it a `reach=` token
# is invalid. Invalid lines are reported on stderr and counted.
valid_reach() {   # valid_reach GLOBS -> 0, or prints the reason on stdout and returns 1
  local globs="$1" g
  case "$globs" in '') echo "reach= has no globs"; return 1 ;; ,*|*,|*,,*) echo "empty reach glob in: $globs"; return 1 ;; esac
  local -a gl; IFS=, read -ra gl <<<"$globs"
  for g in "${gl[@]}"; do
    case "$g" in *..*) echo "reach glob must not contain '..': $g"; return 1 ;; esac
    case "$g" in research-sdd/*) ;; *) echo "reach glob must start with research-sdd/: $g"; return 1 ;; esac
  done
  return 0
}
load_manifest() {
  local file="$1" out="$2" reach_out="${3:-}" ln=0 line name reason seen=" " paths globs tok why pp
  : > "$out"; [ -z "$reach_out" ] || : > "$reach_out"
  [ -f "$file" ] || degraded "manifest absent: $file"
  while IFS= read -r line || [ -n "$line" ]; do
    ln=$((ln+1))
    case "$line" in ''|'#'*|[[:space:]]*'#'*) continue ;; esac
    name="${line%%[[:space:]]*}"; reason="${line#"$name"}"; reason="${reason#"${reason%%[![:space:]]*}"}"
    globs=""
    case "$reason" in reach=*)
      if [ -z "$reach_out" ]; then echo "INVALID $(basename "$file"):$ln: reach= is only valid in impact-blindspot.txt: $name" >&2; MANIFEST_BAD=$((MANIFEST_BAD+1)); continue; fi
      tok="${reason%%[[:space:]]*}"; globs="${tok#reach=}"; reason="${reason#"$tok"}"; reason="${reason#"${reason%%[![:space:]]*}"}"
      if ! why="$(valid_reach "$globs")"; then echo "INVALID $(basename "$file"):$ln: $why ($name)" >&2; MANIFEST_BAD=$((MANIFEST_BAD+1)); continue; fi ;;
    esac
    if [ -z "$reason" ]; then echo "INVALID $(basename "$file"):$ln: no reason: $name" >&2; MANIFEST_BAD=$((MANIFEST_BAD+1)); continue; fi
    case "$seen" in *" $name "*) echo "INVALID $(basename "$file"):$ln: duplicate suite: $name" >&2; MANIFEST_BAD=$((MANIFEST_BAD+1)); continue ;; esac
    seen="$seen$name "
    paths="$(suite_paths_for "$name")"
    if [ -z "$paths" ]; then
      if [ "$TOLERATE" = 1 ]; then continue; fi
      echo "INVALID $(basename "$file"):$ln: names no existing suite: $name" >&2; MANIFEST_BAD=$((MANIFEST_BAD+1)); continue
    fi
    printf '%s\n' "$paths" >> "$out"
    if [ -n "$globs" ]; then while IFS= read -r pp; do printf '%s\t%s\t%s\n' "$name" "$pp" "$globs" >> "$reach_out"; done <<<"$paths"; fi
  done < "$file"
  LC_ALL=C sort -u -o "$out" "$out"
}
load_manifest "$MANIFEST_DIR/impact-always.txt" "$TMP/always"
load_manifest "$MANIFEST_DIR/impact-blindspot.txt" "$TMP/blind" "$TMP/blind_reach"

# ---- blind-spot detector (shared by --audit and the manifest's reasons) ---------------------------------
# detect_blind PATH -> prints the first matching class, or nothing. Comment lines are ignored.
detect_blind() {
  local f="$1" body
  body="$(grep -vE '^[[:space:]]*(#|//)' "$f" 2>/dev/null)" || true
  if grep -qE '(^|[;&|(`[:space:]])ev[a]l[[:space:]]+[^#[:space:]]' <<<"$body"; then echo "eval"; return; fi
  if grep -qE '(cp|rsync|ln)[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*[^|;&]*(\$KIT|\$\{KIT\}|\$TB|\$TOOLBELT|\$\{TB\}|\$\{TOOLBELT\}|toolbelt|\$\{?SRC\}?)[^|;&]*(/\*|/\.|[[:space:]]-[a-zA-Z]*[rRa])' <<<"$body"; then echo "kit-copy"; return; fi
  if grep -qE 'for [a-z_]+ in [^;]*(toolbelt|\$TB|\$TOOLBELT|\$KIT)[^;]*/\*' <<<"$body"; then echo "kit-glob"; return; fi
  if grep -qE '\$\{?[A-Za-z_]+\}?\.sh' <<<"$body"; then echo "dynamic-name"; return; fi
  if grep -qE '\$\{?[A-Za-z_]+\}?\.test\.(sh|mjs)' <<<"$body"; then echo "suite-dynamic"; return; fi
}

# ---- the word graph ----------------------------------------------------------------------------------------
# Manifest for the awk pass: P <path> <basename> <dirkey|-> · S <path> · F <path> <dir>
build_graph_input() {
  local k p b rest d
  : > "$TMP/gin"
  while IFS=$'\t' read -r k p; do
    case "$k" in
      S) printf 'S\t%s\n' "$p" >> "$TMP/gin" ;;
      P) b="${p##*/}"; d="-"
         case "$p" in research-sdd/toolbelt/*) rest="${p#research-sdd/toolbelt/}"
           case "$rest" in tests/*|lib/*) ;; */*) d="${rest%%/*}" ;; esac ;;
         esac
         printf 'P\t%s\t%s\t%s\n' "$p" "$b" "$d" >> "$TMP/gin" ;;
      F) rest="${p#"$TESTS_REL"/fixtures/}"
         case "$rest" in */*) d="${rest%%/*}" ;; *) d="$rest" ;; esac
         printf 'F\t%s\t%s\n' "$p" "$d" >> "$TMP/gin" ;;
    esac
  done < "$TMP/nodes"
}

# content files the awk pass reads: suites, code-like production files, text-like fixtures
content_files() {
  awk -F'\t' '
    $1=="S" { print $2; next }
    $1=="P" && $2 ~ /\.(sh|py|mjs|js)$/ { print $2; next }
    $1=="F" && $2 ~ /\.(sh|py|mjs|js|json|txt|bash)$/ { print $2 }
  ' "$TMP/nodes"
}

AWK_GRAPH='
BEGIN {
  FS = "\t"
  # a pure comment line is prose, not a reference; these comment forms are directives the suites rely on (kept)
  DIRECTIVE = "^[ \t]*(#|//)[ \t]*(shellcheck[ \t]+source=|SENTINEL-|NG-|--prove-teeth:|summary-lint:|pipefail-audit:)"
}
FILENAME == ARGV[1] {
  if ($1 == "S") { kind[$2] = "S"; sb = $2; sub(/^.*\//, "", sb); n = ++skn[sb]; sk[sb, n] = $2 }
  else if ($1 == "P") { kind[$2] = "P"; add_pk($3, $2); if ($4 != "-") add_pk($4, $2) }
  else if ($1 == "F") { kind[$2] = "F"; fdir[$2] = $3; dk[$3] = 1 }
  next
}
function add_pk(w, path,   n) { n = ++pkn[w]; pk[w, n] = path }
function edge(src, tgt) {
  if (src == tgt || ((src SUBSEP tgt) in seen)) return
  seen[src, tgt] = 1; n = ++rn[tgt]; rsrc[tgt, n] = src
}
function lookup(w, src,   i) {
  if (w in pkn) for (i = 1; i <= pkn[w]; i++) edge(src, "P:" pk[w, i])
  if (w in skn) for (i = 1; i <= skn[w]; i++) edge(src, "S:" sk[w, i])   # a suite that RUNS another suite
  if (kind[FILENAME] == "S" && (w in dk)) edge(src, "D:" w)
}
function word(w, src) {
  sub(/\.+$/, "", w)
  if (w ~ /^\.*$/) return
  lookup(w, src)
  if (w ~ /^\./) { sub(/^\.+/, "", w); if (w != "") lookup(w, src) }   # a dotfile is reachable by its dotted name AND the bare one
}
{
  src = (kind[FILENAME] == "S") ? "S:" FILENAME : (kind[FILENAME] == "P") ? "P:" FILENAME : "D:" fdir[FILENAME]
  if (!(FILENAME in cm)) cm[FILENAME] = (FILENAME ~ /\.(sh|bash|py)$/) ? "#" : (FILENAME ~ /\.(mjs|js)$/) ? "//" : ""
  if (cm[FILENAME] == "#" && $0 ~ /^[ \t]*#/ && $0 !~ DIRECTIVE) next
  if (cm[FILENAME] == "//" && $0 ~ /^[ \t]*\/\// && $0 !~ DIRECTIVE) next
  line = $0
  # python imports: `from lib.x import a, b` / `import a.b`. Every identifier after the keyword becomes a candidate
  # module file (`<id>.py`), so dotted paths (lib.x -> lib.py, x.py) and imported names resolve; a candidate with no
  # file of that name is no edge (lookup finds nothing), so over-reading prose after "from"/"import" is harmless.
  rest = line
  while (match(rest, /(^|[^A-Za-z0-9_])(from|import)[ \t]+/)) {
    tl = substr(rest, RSTART + RLENGTH)
    ni = split(tl, ids, /[^A-Za-z0-9_]+/)
    for (k = 1; k <= ni; k++) if (ids[k] != "") word(ids[k] ".py", src)
    rest = tl
  }
  nw = split(line, parts, /[^A-Za-z0-9_.-]+/)
  for (i = 1; i <= nw; i++) if (parts[i] != "") word(parts[i], src)
}
END {
  # changed nodes arrive as a file of node ids (P:path | D:dir | S:path) in CHANGED
  while ((getline cn < CHANGED) > 0) {
    delete vis; head = 1; tail = 0; queue[++tail] = cn; vis[cn] = 1; nonsuite = 0; found = 0
    if (cn ~ /\.md$/) {   # a document is read, not run: only the suites naming it directly, no closure
      for (j = 1; j <= rn[cn]; j++) if (rsrc[cn, j] ~ /^S:/) { print "MAP\t" cn "\t" substr(rsrc[cn, j], 3); found++ }
      print "CLOSURE\t" cn "\t0\t" found + 0; continue
    }
    while (head <= tail) {
      cur = queue[head++]
      if (cur ~ /^S:/) { print "MAP\t" cn "\t" substr(cur, 3); found++ } else nonsuite++
      for (j = 1; j <= rn[cur]; j++) { s = rsrc[cur, j]; if (!(s in vis)) { vis[s] = 1; queue[++tail] = s } }
    }
    print "CLOSURE\t" cn "\t" nonsuite "\t" found
  }
}
'

run_graph() {  # run_graph CHANGEDFILE -> TMP/gout
  build_graph_input
  content_files > "$TMP/cfiles"
  [ -s "$TMP/cfiles" ] || degraded "no content files to analyse (could not look)"
  # shellcheck disable=SC2046 # the file list is newline-separated paths without spaces (kit invariant)
  awk -v CHANGED="$1" "$AWK_GRAPH" "$TMP/gin" $(cat "$TMP/cfiles") > "$TMP/gout" || degraded "awk graph pass failed"
}

# ---- audit -----------------------------------------------------------------------------------------------
if [ "$AUDIT" = 1 ]; then
  : > "$TMP/detected"
  while IFS= read -r s; do
    c="$(detect_blind "$s")"
    [ -n "$c" ] && printf '%s\t%s\n' "$s" "$c" >> "$TMP/detected"
  done < "$TMP/suites"
  missing=0
  while IFS=$'\t' read -r s c; do
    grep -qxF -- "$s" "$TMP/blind" || { echo "AUDIT missing from impact-blindspot.txt: $s ($c)"; missing=$((missing+1)); }
  done < "$TMP/detected"
  # dead reach globs: a glob matching no CODE file (see is_code_path) would silently never select its suite
  dead=0
  if [ -s "$TMP/blind_reach" ]; then
    while IFS=$'\t' read -r name pp globs; do printf '%s\t%s\n' "$name" "$globs"; done < "$TMP/blind_reach" | LC_ALL=C sort -u > "$TMP/reach_names"
    while IFS=$'\t' read -r name globs; do
      local_gl=(); IFS=, read -ra local_gl <<<"$globs"
      for g in "${local_gl[@]}"; do
        hit=0
        # shellcheck disable=SC2254 # the reach glob is a pattern by design
        while IFS= read -r f; do is_code_path "$f" || continue; case "$f" in $g) hit=1; break ;; esac; done < "$TMP/files"
        [ "$hit" = 1 ] || { echo "AUDIT dead reach glob in impact-blindspot.txt: $g ($name)"; dead=$((dead+1)); }
      done
    done < "$TMP/reach_names"
  fi
  # orphans: production CODE files no suite reaches (a change to one escalates to FULL by design)
  awk -F'\t' '$1=="P" && $2 ~ /\.(sh|py|mjs|js)$/ && $2 !~ /\/tests\//{print "P:" $2}' "$TMP/nodes" > "$TMP/allp"
  run_graph "$TMP/allp"
  orphans="$(awk -F'\t' '$1=="CLOSURE" && $4==0{n++} END{print n+0}' "$TMP/gout")"
  echo "Audit: $NSUITES suites; detected blind-spot $(grep -c . "$TMP/detected"); manifest blind-spot $(grep -c . "$TMP/blind"); always-run $(grep -c . "$TMP/always")"
  echo "Audit: missing from impact-blindspot.txt: $missing; invalid manifest lines: $MANIFEST_BAD; dead reach globs: $dead"
  echo "Audit: production code files no suite reaches (change escalates to FULL): $orphans"
  [ "$missing" -eq 0 ] && [ "$MANIFEST_BAD" -eq 0 ] && [ "$dead" -eq 0 ] && exit 0
  exit 1
fi
# ---- forward dependency sets (kit issue #2201 part 2: the key of run-all.sh --cache) -------------------------------------
# A separate, self-contained pass: it REUSES the word graph (the same AWK_GRAPH front half: lexing, edge rules, fixture
# dirs) but replaces its END block with a forward walk, so no selection rule is touched. The reverse edges the graph
# stores (target <- source) are inverted here; a suite's set is everything reachable from it, plus the fixture dir named
# like the suite. Output is tab-separated and always ends with a DEPS-SUMMARY line (suites, DEP lines) so a caller can
# tell "looked and found nothing" from "never looked" (CLAUDE.md section 7).
AWK_DEPS_END='
END {
  for (t in rn) for (j = 1; j <= rn[t]; j++) { s = rsrc[t, j]; fwd[s, ++fn[s]] = t }
  for (ff in fdir) { d = fdir[ff]; dfile[d, ++dn[d]] = ff }
  for (f in kind) if (kind[f] == "S") {
    if (WANT != "" && f != WANT) continue
    delete vis; head = 1; tail = 0; start = "S:" f; queue[++tail] = start; vis[start] = 1; nd = 0
    b = f; sub(/^.*\//, "", b); sub(/\.test\.(sh|mjs)$/, "", b)
    if (b in dk) { queue[++tail] = "D:" b; vis["D:" b] = 1 }
    while (head <= tail) {
      cur = queue[head++]
      if (cur != start) {
        if (cur ~ /^D:/) { d = substr(cur, 3); for (i = 1; i <= dn[d]; i++) { print "DEP\t" f "\t" dfile[d, i]; nd++ } }
        else { print "DEP\t" f "\t" substr(cur, 3); nd++ }
      }
      for (j = 1; j <= fn[cur]; j++) { s = fwd[cur, j]; if (!(s in vis)) { vis[s] = 1; queue[++tail] = s } }
    }
    print "COUNT\t" f "\t" nd
  }
}
'
if [ "$DEPS" = 1 ]; then
  [ "$MANIFEST_BAD" -eq 0 ] || { echo "$SELF_NAME: $MANIFEST_BAD invalid manifest line(s); refusing to answer from a broken manifest" >&2; exit 1; }
  if [ -n "$DEPS_WANT" ]; then
    grep -qxF -- "$DEPS_WANT" "$TMP/suites" || degraded "no such suite: $DEPS_WANT (give a repo-relative suite path)"
  fi
  AWK_DEPS="${AWK_GRAPH%%END \{*}$AWK_DEPS_END"
  [ "$AWK_DEPS" != "$AWK_GRAPH" ] || degraded "cannot derive the dependency pass from the graph program (no END block found)"
  build_graph_input
  content_files > "$TMP/cfiles"
  [ -s "$TMP/cfiles" ] || degraded "no content files to analyse (could not look)"
  # shellcheck disable=SC2046 # newline-separated paths without spaces (kit invariant)
  awk -v WANT="$DEPS_WANT" "$AWK_DEPS" "$TMP/gin" $(cat "$TMP/cfiles") > "$TMP/dout" || degraded "awk dependency pass failed"
  : > "$TMP/dblind"
  while IFS=$'\t' read -r tag s n; do
    [ "$tag" = COUNT ] || continue
    c="$(detect_blind "$s")"
    # an always-run suite is a whole-tree reader: its inputs are not a dependency set, so it has no key
    if grep -qxF -- "$s" "$TMP/always"; then printf 'ALWAYS\t%s\tmanifest\n' "$s" >> "$TMP/dblind"
    elif grep -qxF -- "$s" "$TMP/blind"; then printf 'BLIND\t%s\tmanifest\n' "$s" >> "$TMP/dblind"
    elif [ -n "$c" ]; then printf 'BLIND\t%s\tdetected:%s\n' "$s" "$c" >> "$TMP/dblind"
    elif [ "$n" -eq 0 ]; then printf 'UNRESOLVED\t%s\tno dependency resolved from the suite text\n' "$s" >> "$TMP/dblind"
    fi
  done < "$TMP/dout"
  # a blind or unresolved suite lists no DEP lines: a partial set must not read as a real one
  awk -F'\t' 'FILENAME==ARGV[1]{skip[$2]=1; next} $1=="DEP" && !($2 in skip){print}' "$TMP/dblind" "$TMP/dout" | LC_ALL=C sort -u > "$TMP/dep_lines"
  nsu="$(grep -c '^COUNT' "$TMP/dout")"
  [ "$nsu" -gt 0 ] || degraded "dependency pass produced no suites (could not look)"
  cat "$TMP/dep_lines"; LC_ALL=C sort "$TMP/dblind"
  printf 'DEPS-SUMMARY\t%s\t%s\n' "$nsu" "$(grep -c . "$TMP/dep_lines")"
  exit 0
fi
[ "$MANIFEST_BAD" -eq 0 ] || { echo "$SELF_NAME: $MANIFEST_BAD invalid manifest line(s); refusing to select from a broken manifest" >&2; exit 1; }

# ---- changed files ---------------------------------------------------------------------------------------
cd "$REPO" || degraded "cannot enter $REPO"
git rev-parse --verify -q "$BASE^{commit}" >/dev/null 2>&1 || degraded "bad base ref: $BASE"
if [ "$WORKTREE" = 1 ]; then
  mb="$(git merge-base "$BASE" HEAD 2>/dev/null)" || degraded "no merge-base between $BASE and HEAD"
  git diff -z --name-status -M "$mb" > "$TMP/diff" 2>/dev/null || degraded "git diff failed against $mb"
  git ls-files -z -o --exclude-standard | while IFS= read -r -d '' f; do printf 'A\0%s\0' "$f"; done >> "$TMP/diff"
else
  git diff -z --name-status -M "$BASE...$HEAD_REF" > "$TMP/diff" 2>/dev/null || degraded "git diff failed for $BASE...$HEAD_REF"
fi
# status<TAB>path lines; a rename/copy becomes a delete of the old path and an add of the new one
: > "$TMP/changes"
mapfile -d '' -t TOK < "$TMP/diff"
i=0
while [ "$i" -lt "${#TOK[@]}" ]; do
  st="${TOK[$i]}"
  case "$st" in
    R*|C*) printf 'D\t%s\nA\t%s\n' "${TOK[$((i+1))]}" "${TOK[$((i+2))]}" >> "$TMP/changes"; i=$((i+3)) ;;
    *) printf '%s\t%s\n' "${st:0:1}" "${TOK[$((i+1))]}" >> "$TMP/changes"; i=$((i+2)) ;;
  esac
done
cd "$ROOT" || degraded "cannot enter $ROOT"

# ---- classify each change ---------------------------------------------------------------------------------
FULL_REASON=""
full() { [ -n "$FULL_REASON" ] || FULL_REASON="$1"; }
: > "$TMP/changed_nodes"; : > "$TMP/selected_direct"; : > "$TMP/maplines"; : > "$TMP/code_changed"
CODE_CHANGED=0; DOCS_ONLY=1; NCHANGED=0
while IFS=$'\t' read -r st p; do
  [ -n "$p" ] || continue
  NCHANGED=$((NCHANGED+1))
  base="${p##*/}"
  # A deleted (or renamed-away) document has no node in the head tree, so the graph cannot map it. The suites that
  # still NAME its old basename are the ones that would now fail: select them by a plain substring read.
  if [ "$st" = D ]; then
    case "$p" in *.md)
      while IFS= read -r s; do
        grep -qF -- "$base" "$s"; g=$?
        [ "$g" -le 1 ] || degraded "grep failed reading $s"
        [ "$g" -eq 0 ] && printf '%s\t%s\n' "$p" "$s" >> "$TMP/maplines"
      done < "$TMP/suites" ;;
    esac
  fi
  case "$p" in
    "$TESTS_REL"/lib/*|"$TESTS_REL"/run-all.sh|"$TESTS_REL"/shard-join.sh|"$TESTS_REL"/teeth-helper-waivers.txt|"$TESTS_REL"/suite-tiers.txt|"$TESTS_REL"/impact-*.txt|"$TESTS_REL"/suite-impact.sh)
      DOCS_ONLY=0; full "harness file changed: $p" ;;
    research-sdd/install/*) DOCS_ONLY=0; full "install tree changed: $p" ;;
    research-sdd/templates/*) DOCS_ONLY=0; full "templates changed: $p" ;;
    .github/*) DOCS_ONLY=0; full "CI configuration changed: $p" ;;
    .shellcheckrc|*/.shellcheckrc) DOCS_ONLY=0; full "shellcheck configuration changed: $p" ;;
    "$TESTS_REL"/*.test.sh|"$TESTS_REL"/*.test.mjs)
      DOCS_ONLY=0
      rest="${p#"$TESTS_REL"/}"
      case "$rest" in
        */*) printf 'P:%s\n' "$p" >> "$TMP/changed_nodes" ;;   # a nested file named *.test.sh is infra, not a suite
        *) if [ "$st" != D ] && grep -qxF -- "$p" "$TMP/suites"; then
             printf '%s\n' "$p" >> "$TMP/selected_direct"; printf '%s\t%s\n' "$p" "$p" >> "$TMP/maplines"
             printf 'S:%s\n' "$p" >> "$TMP/changed_nodes"   # also the suites that RUN this suite
           fi ;;
      esac ;;
    "$TESTS_REL"/fixtures/*)
      DOCS_ONLY=0
      rest="${p#"$TESTS_REL"/fixtures/}"
      case "$rest" in */*) d="${rest%%/*}" ;; *) d="$rest" ;; esac
      printf 'D:%s\n' "$d" >> "$TMP/changed_nodes" ;;
    "$TESTS_REL"/*)
      DOCS_ONLY=0; [ "$st" = D ] && full "deleted test-infrastructure file: $p"
      printf 'P:%s\n' "$p" >> "$TMP/changed_nodes" ;;
    research-sdd/toolbelt/*)
      case "$p" in
        *.md) [ "$st" = D ] || printf 'P:%s\n' "$p" >> "$TMP/changed_nodes" ;;
        *) DOCS_ONLY=0; CODE_CHANGED=1; printf '%s\n' "$p" >> "$TMP/code_changed"
           case "$st" in A) full "added production file: $p" ;; D) full "deleted/renamed production file: $p" ;; esac
           for w in $WIDE_NAMED; do [ "$base" = "$w" ] && full "widely used library changed: $p"; done
           printf 'P:%s\n' "$p" >> "$TMP/changed_nodes" ;;
      esac ;;
    research-sdd/*)
      case "$p" in
        *.md) [ "$st" = D ] || printf 'P:%s\n' "$p" >> "$TMP/changed_nodes" ;;
        *) DOCS_ONLY=0; CODE_CHANGED=1; printf '%s\n' "$p" >> "$TMP/code_changed"; [ "$st" = D ] && full "deleted kit-content file: $p"; printf 'P:%s\n' "$p" >> "$TMP/changed_nodes" ;;
      esac ;;
    openspec/*|odd/*) ;;
    *.md) ;;
    *) DOCS_ONLY=0; full "unclassified path (no rule places it): $p" ;;
  esac
done < "$TMP/changes"

# Nodes that do not exist in the head tree (a deleted doc) cannot map; nodes that exist are analysed.
if [ -s "$TMP/changed_nodes" ]; then
  LC_ALL=C sort -u -o "$TMP/changed_nodes" "$TMP/changed_nodes"
  # keep only nodes present in the head tree; an absent one is a deletion already handled above
  : > "$TMP/cn2"
  while IFS= read -r n; do
    case "$n" in
      P:*) grep -qxF -- "P	${n#P:}" "$TMP/nodes" && echo "$n" >> "$TMP/cn2" ;;
      D:*) awk -F'\t' -v d="${n#D:}" '$1=="F"{p=$2; sub(/^.*\/fixtures\//,"",p); sub(/\/.*$/,"",p); if (p==d) f=1} END{exit f?0:1}' "$TMP/nodes" && echo "$n" >> "$TMP/cn2" || full "deleted fixture dir: ${n#D:}" ;;
      S:*) echo "$n" >> "$TMP/cn2" ;;
    esac
  done < "$TMP/changed_nodes"
  mv "$TMP/cn2" "$TMP/changed_nodes"
fi

# ---- graph pass --------------------------------------------------------------------------------------------
if [ -s "$TMP/changed_nodes" ]; then
  run_graph "$TMP/changed_nodes"
  while IFS=$'\t' read -r tag a b c; do
    case "$tag" in
      MAP) printf '%s\t%s\n' "${a#?:}" "$b" >> "$TMP/maplines" ;;
      CLOSURE)
        if [ "$c" -eq 0 ]; then
          case "$a" in P:*.md) ;; *) full "no suite reaches the changed file: ${a#?:}" ;; esac
        fi
        if [ "$b" -gt "$WIDE_THRESHOLD" ]; then full "widely used: ${a#?:} is reached through $b production/fixture nodes (threshold $WIDE_THRESHOLD)"; fi ;;
    esac
  done < "$TMP/gout"
fi

# ---- selection ---------------------------------------------------------------------------------------------
{ cut -f2 "$TMP/maplines"; cat "$TMP/selected_direct" "$TMP/always"; } | LC_ALL=C sort -u > "$TMP/sel"
BLIND_ADDED=0; BLIND_SKIPPED=0
if [ "$CODE_CHANGED" = 1 ]; then
  # unscoped blind-spot suites always; a reach-scoped one only when a changed code file matches one of its globs
  cut -f2 "$TMP/blind_reach" | LC_ALL=C sort -u > "$TMP/scoped"
  LC_ALL=C comm -23 "$TMP/blind" "$TMP/scoped" > "$TMP/blind_add"
  : > "$TMP/scoped_hit"
  while IFS=$'\t' read -r name pp globs; do
    gl=(); IFS=, read -ra gl <<<"$globs"
    while IFS= read -r cf; do
      # shellcheck disable=SC2254 # the reach glob is a pattern by design
      for g in "${gl[@]}"; do case "$cf" in $g) printf '%s\n' "$pp" >> "$TMP/scoped_hit"; break 2 ;; esac; done
    done < "$TMP/code_changed"
  done < "$TMP/blind_reach"
  LC_ALL=C sort -u -o "$TMP/scoped_hit" "$TMP/scoped_hit"
  cat "$TMP/scoped_hit" >> "$TMP/blind_add"
  # no reach glob covers a code change outside research-sdd/toolbelt/ (profiles, skills, other kit content): add ALL
  if grep -qv '^research-sdd/toolbelt/' "$TMP/code_changed"; then cp "$TMP/blind" "$TMP/blind_add"; : > "$TMP/scoped_hit"; fi
  cat "$TMP/blind_add" >> "$TMP/sel"; LC_ALL=C sort -u -o "$TMP/sel" "$TMP/sel"
  BLIND_ADDED="$(LC_ALL=C sort -u "$TMP/blind_add" | grep -c .)"
  BLIND_SKIPPED="$(LC_ALL=C comm -23 "$TMP/scoped" "$TMP/scoped_hit" | grep -c .)"
  if grep -qv '^research-sdd/toolbelt/' "$TMP/code_changed"; then BLIND_SKIPPED=0; fi
fi
if [ -n "$FULL_REASON" ]; then cp "$TMP/suites" "$TMP/sel"; fi
NSEL="$(grep -c . "$TMP/sel")"
[ "$NSEL" -gt 0 ] || degraded "empty selection (the always-run manifest selected nothing; could not look)"

if [ "$FORMAT" = list ]; then cat "$TMP/sel"; exit 0; fi

echo "Impacted: $NSEL of $NSUITES suites"
LC_ALL=C sort -u "$TMP/maplines" | while IFS=$'\t' read -r c s; do printf '%s → %s\n' "$c" "$s"; done
if [ "$NCHANGED" -eq 0 ]; then echo "no-change: empty diff, always-run set only"
elif [ "$DOCS_ONLY" = 1 ]; then echo "docs-only: always-run set plus suites naming the document"; fi
echo "Always-run: $(grep -c . "$TMP/always")"
if [ "$CODE_CHANGED" = 1 ]; then
  echo "Blind-spot: $BLIND_ADDED added (production code changed)"
  [ -s "$TMP/scoped" ] && echo "Blind-spot skipped by reach: $BLIND_SKIPPED"
else echo "Blind-spot: 0 (not triggered)"; fi
if [ -n "$FULL_REASON" ]; then echo "Escalated to FULL: $FULL_REASON"; else echo "Escalated: no"; fi
echo "Selected:"
cat "$TMP/sel"
exit 0
