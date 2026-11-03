#!/usr/bin/env bash
# rsdd-exec.test.sh — suite for lib/rsdd-exec.sh, the compatibility-shim helper of the Go port (kit issue #2275).
#
# Hermetic: every case builds a temp kit layout (<tmp>/<case>/k it/{toolbelt/lib,rsdd,bin}) holding a COPY of
# the library, a FAKE `rsdd` binary (echoes its argv as `%q` lines, stdin and a chosen exit code) and a FAKE
# `go` (`go run ./cmd/rsdd-srchash .` prints a controllable hash; `go build -ldflags ... -o` writes a binary
# stamped with the -X value, fails, or is slow). The fake binary answers `version --source-hash` like the real one.
# Staleness is a source-hash comparison, so the expected tree hash comes from ref_hash(), the verbatim README
# pipeline of rsdd/internal/commands/testdata/source-hash, never from the library under test. Nothing touches the
# real research-sdd/ tree (the hash fixture and the Makefile are only READ) and Go itself is never needed. The kit
# path contains a space on purpose.
#
# Each scenario runs in a child process (`--scenario NAME LIB`) and prints a report (`## label`, `RC=`, `o| `
# stdout lines, `e| ` stderr lines, probes). The main run asserts on the report of the real library; the
# `--prove-teeth` run asserts the SAME report differs in a named way for a mutant of the library.
#
# Usage: rsdd-exec.test.sh [--prove-teeth]
# Exit: 0 = all passed · 1 = regression · 2 = harness error.
set -uo pipefail
HERE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)"
SELF="$HERE/rsdd-exec.test.sh"
LIB="$HERE/../lib/rsdd-exec.sh"
BASH_BIN="$(type -P bash)"; [ -n "$BASH_BIN" ] || { echo "FATAL: bash not on PATH" >&2; exit 2; }

# ------------------------------------------------------------------------------------------------ scenarios
# Fixture pieces. SCRATCH = this process's scratch dir, FARM = symlink farm of the tools the library may use (a PATH
# made of only this is the "no go" PATH), GOBIN = dir holding the fake go.
setup_world() {   # LIB_PATH
  SCRATCH="$(mktemp -d)" || exit 2
  SCRATCH="$(CDPATH='' cd -- "$SCRATCH" && pwd -P)"
  trap 'chmod -R u+rwx -- "$SCRATCH" 2>/dev/null; rm -rf -- "$SCRATCH"' EXIT
  SCLIB="$1"
  FARM="$SCRATCH/farm"; GOBIN="$SCRATCH/gobin"; JQD="$SCRATCH/jqd"; mkdir -p "$FARM" "$GOBIN" "$JQD"
  local t p
  FARMNF="$SCRATCH/farm-noflock"; FARMNS="$SCRATCH/farm-nosha"; FARMSHA="$SCRATCH/farm-shasum"; FLOGD="$SCRATCH/flogd"
  mkdir -p "$FARMNF" "$FARMNS" "$FARMSHA" "$FLOGD"
  for t in bash env mktemp mv rm find mkdir dirname cat sleep touch chmod ls readlink sort sha256sum flock; do
    p="$(type -P "$t")" || { echo "FATAL: tool $t missing" >&2; exit 2; }
    ln -s "$p" "$FARM/$t"
    [ "$t" = flock ] || ln -s "$p" "$FARMNF/$t"
    [ "$t" = sha256sum ] || ln -s "$p" "$FARMNS/$t"
    [ "$t" = sha256sum ] || ln -s "$p" "$FARMSHA/$t"
  done
  # FARMSHA: no sha256sum, only shasum (the library's fallback); an absent shasum leaves SHASUM_OK unset (typed SKIP)
  SHASUM_OK=""; p="$(type -P shasum)" && { ln -s "$p" "$FARMSHA/shasum"; SHASUM_OK=1; }
  # FLOGD: a flock that logs its argv to $FLOCK_LOG and runs the real one
  FLOCK_REAL="$(type -P flock)"
  printf '#!%s\nprintf "%%s\\n" "$*" >>"$FLOCK_LOG"\nexec "%s" "$@"\n' "$BASH_BIN" "$FLOCK_REAL" >"$FLOGD/flock"; chmod 755 "$FLOGD/flock"
  p="$(type -P jq)" && ln -s "$p" "$JQD/jq"
  # SHALOGD: a sha256sum that logs its argv to $SHA_LOG (the full hash passes `-- <files>`, the fingerprint reads stdin) and
  # runs the real one. BADFIND: a find that refuses -printf (BSD find, a broken stat) and otherwise runs the real one.
  SHALOGD="$SCRATCH/shalogd"; BADFIND="$SCRATCH/badfind"; mkdir -p "$SHALOGD" "$BADFIND"; SHA_LOG="$SCRATCH/sha.log"; export SHA_LOG
  printf '#!%s\nprintf "%%s\\n" "$*" >>"$SHA_LOG"\nexec "%s" "$@"\n' "$BASH_BIN" "$(type -P sha256sum)" >"$SHALOGD/sha256sum"; chmod 755 "$SHALOGD/sha256sum"
  printf '#!%s\nfor a in "$@"; do [ "$a" = -printf ] && exit 1; done\nexec "%s" "$@"\n' "$BASH_BIN" "$(type -P find)" >"$BADFIND/find"; chmod 755 "$BADFIND/find"
  MK_SYM="$(awk '$1 == "SOURCE_HASH_SYM" && $2 == ":=" { print $3 }' "$HERE/../../rsdd/Makefile")"
  [ -n "$MK_SYM" ] || { echo "FATAL: SOURCE_HASH_SYM not found in rsdd/Makefile" >&2; exit 2; }
  H_OLD="sha256:$(printf '%064d' 0)"
  cat >"$SCRATCH/body" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = version ] && [ "$2" = --source-hash ]; then echo "@HASH@"; exit "${FAKE_HASH_RC:-0}"; fi
echo "FAKE-@TAG@"
printf 'n=%s\n' "$#"
for a in "$@"; do printf 'arg=%q\n' "$a"; done
if [ -n "${FAKE_READ_STDIN:-}" ]; then printf 'stdin=%q\n' "$(cat)"; fi
exit "${FAKE_RC:-0}"
EOF
  cat >"$GOBIN/go" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  run)
    if [ "$#" -ne 3 ] || [ "$2" != ./cmd/rsdd-srchash ] || [ "$3" != . ]; then echo "fake go: unexpected args: $*" >&2; exit 64; fi
    printf '%s\n' "$PWD" >> "$FAKE_GO_RUNLOG"
    if [ "${FAKE_SRC_MODE:-ok}" = fail ]; then echo "SRCHASH-NOISE-STDERR" >&2; exit 1; fi
    printf '%s\n' "$FAKE_SRCHASH"; exit 0 ;;
  build) ;;
  *) echo "fake go: unexpected args: $*" >&2; exit 64 ;;
esac
if [ "$#" -ne 6 ] || [ "$2" != -ldflags ] || [ "$4" != -o ] || [ "$6" != ./cmd/rsdd ]; then echo "fake go: unexpected args: $*" >&2; exit 64; fi
ld="$3"; out="$5"
case "$ld" in *" -X $FAKE_GO_SYM="*) ;; *) echo "fake go: -ldflags lack -X $FAKE_GO_SYM=: $ld" >&2; exit 65 ;; esac
h="${ld##*-X "$FAKE_GO_SYM"=}"; h="${h%% *}"
printf '%s\n' "$PWD" >> "$FAKE_GO_LOG"
printf '%s\n' "$h" >> "$FAKE_GO_LDLOG"
printf '%s\n' "${CGO_ENABLED-unset}" >> "$FAKE_GO_LOG.cgo"
echo "BUILDNOISE-STDOUT"
echo "BUILDNOISE-STDERR" >&2
body="$(<"$FAKE_BODY")"; body="${body//@TAG@/"${FAKE_GO_TAG:-NEW}"}"; body="${body//@HASH@/"$h"}"
case "${FAKE_GO_MODE:-ok}" in
  fail) printf 'half-written junk' > "$out"; exit 1 ;;
  slow) : > "$out"; chmod 755 "$out"
        [ -z "${FAKE_GO_READY:-}" ] || : > "$FAKE_GO_READY"
        for ((i = 0; i < 100; i++)); do [ -e "${FAKE_GO_RELEASE:-/nonexistent}" ] && break; sleep 0.05; done
        [ -e "${FAKE_GO_RELEASE:-/nonexistent}" ] || { echo "fake go: release timeout" >&2; exit 97; }
        printf '%s\n' "$body" > "$out" ;;
  *) printf '%s\n' "$body" > "$out" ;;
esac
EOF
  chmod 755 "$GOBIN/go"
}

mkkit() {   # NAME — KIT=<SCRATCH>/NAME/k it with lib copy, shims and (old) sources; no bin/
  KIT="$SCRATCH/$1/k it"
  mkdir -p "$KIT/toolbelt/lib" "$KIT/rsdd/cmd/rsdd" "$KIT/rsdd/internal/deep"
  cp "$SCLIB" "$KIT/toolbelt/lib/rsdd-exec.sh"
  cp "$HERE/../lib/hook-emit.sh" "$KIT/toolbelt/lib/hook-emit.sh"   # stage-libs-ok: the only lib rsdd-exec.sh sources; the hook-emit-missing case deletes it
  printf 'package main\n' >"$KIT/rsdd/cmd/rsdd/main.go"
  printf 'package deep\n' >"$KIT/rsdd/internal/deep/deep.go"
  printf 'module x\n' >"$KIT/rsdd/go.mod"; printf 'sum\n' >"$KIT/rsdd/go.sum"
  cat >"$KIT/toolbelt/shim.sh" <<'EOF'
#!/usr/bin/env bash
. "$(dirname "$0")/lib/rsdd-exec.sh" && rsdd_exec verify block "$@"
EOF
  cat >"$KIT/toolbelt/direct.sh" <<'EOF'
#!/usr/bin/env bash
before="$-"
. "$(dirname "$0")/lib/rsdd-exec.sh"
[ "$before" = "$-" ] || echo "OPTS-CHANGED"
rsdd_exec "$@"
EOF
  cat >"$KIT/toolbelt/strict.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
before="$-"
. "$(dirname "$0")/lib/rsdd-exec.sh"
. "$(dirname "$0")/lib/rsdd-exec.sh"
[ "$before" = "$-" ] || echo "OPTS-CHANGED"
rsdd_exec verify block "$@"
EOF
  cat >"$KIT/toolbelt/nocd.sh" <<'EOF'
#!/usr/bin/env bash
cd() { return 1; }
. "$(dirname "$0")/lib/rsdd-exec.sh"
unset -f cd
rsdd_exec verify block "$@"
EOF
  cat >"$KIT/toolbelt/hook.sh" <<'EOF'
#!/usr/bin/env bash
. "$(dirname "$0")/lib/rsdd-exec.sh" && rsdd_exec_hook "$@"
EOF
  touch -d '2020-01-01 00:00:00' "$KIT/rsdd/cmd/rsdd/main.go" "$KIT/rsdd/internal/deep/deep.go" "$KIT/rsdd/go.mod" "$KIT/rsdd/go.sum"
  : >"$SCRATCH/go.log"; : >"$SCRATCH/run.log"; : >"$SCRATCH/ld.log"; : >"$SCRATCH/go.log.cgo"
}

# ref_hash DIR — the tree hash by the README's independent shell pipeline (rsdd/internal/commands/testdata/source-hash)
ref_hash() {
  ( cd -- "$1" 2>/dev/null && find . -type f \( -name '*.go' ! -name '*_test.go' -o -path ./go.mod -o -path ./go.sum \
      -o -path './vendor/*' -o -path './embed/*' -o -path '*/embed/*' \) \
      ! -path './testdata/*' ! -path '*/testdata/*' ! -name testdata \
    | sed 's|^\./||' | LC_ALL=C sort \
    | while IFS= read -r p; do printf '%s\0%s\n' "$p" "$(sha256sum < "$p" | cut -d' ' -f1)"; done \
    | sha256sum | awk '{print "sha256:" $1}' ) 2>/dev/null
}

putbin() {   # TAG [HASH] [DATE] — fake rsdd at KIT/bin/rsdd; HASH = what `version --source-hash` prints (absent/empty = the hash of the CURRENT tree); DATE absent = now
  mkdir -p "$KIT/bin"
  local body h="${2:-}"; [ -n "$h" ] || h="$(ref_hash "$KIT/rsdd")"
  body="$(<"$SCRATCH/body")"; body="${body//@TAG@/"$1"}"; printf '%s\n' "${body//@HASH@/"$h"}" >"$KIT/bin/rsdd"
  chmod 755 "$KIT/bin/rsdd"
  if [ -n "${3:-}" ]; then touch -d "$3" "$KIT/bin/rsdd"; fi
}

# dorun LABEL SCRIPT PM args... — PM shalog (go, sha256sum logs argv) | badfind (shalog, find refuses -printf) | go|gojq|nogojq|nogo|goNF (no flock)|nosha (go, no sha tool)|nosha_nogo|shasum (go, shasum only)|shasum_nogo|flog (go, flock logs argv to FLOCK_LOG).
# Env knobs: GOMODE GOTAG GOHASH (what `go run rsdd-srchash` prints; default = the tree hash) SRCMODE=fail FAKE_RC
# FAKE_HASH_RC READ_STDIN STDIN_FILE USE_RSDD_BIN DORUN_TIMEOUT
dorun() {
  local label="$1" script="$2" pm="$3" p gh; shift 3
  case "$pm" in go) p="$GOBIN:$FARM" ;; gojq) p="$GOBIN:$FARM:$JQD" ;; nogojq) p="$FARM:$JQD" ;; goNF) p="$GOBIN:$FARMNF" ;;
    nosha) p="$GOBIN:$FARMNS" ;; nosha_nogo) p="$FARMNS" ;; shasum) p="$GOBIN:$FARMSHA" ;; shasum_nogo) p="$FARMSHA" ;;
    flog) p="$GOBIN:$FLOGD:$FARM" ;; shalog) p="$GOBIN:$SHALOGD:$FARMNS" ;; badfind) p="$GOBIN:$BADFIND:$SHALOGD:$FARMNS" ;; *) p="$FARM" ;; esac
  local sp="$KIT/toolbelt/$script"; case "$script" in /*) sp="$script" ;; esac
  if [ -n "${GOHASH+x}" ]; then gh="$GOHASH"; else gh="$(ref_hash "$KIT/rsdd")"; fi
  local -a ev=(PATH="$p" FAKE_GO_LOG="$SCRATCH/go.log" FAKE_GO_RUNLOG="$SCRATCH/run.log" FAKE_GO_LDLOG="$SCRATCH/ld.log" FAKE_GO_SYM="$MK_SYM"
    FAKE_SRCHASH="$gh" FAKE_SRC_MODE="${SRCMODE:-ok}" FAKE_HASH_RC="${FAKE_HASH_RC:-0}"
    FAKE_GO_MODE="${GOMODE:-ok}" FAKE_GO_TAG="${GOTAG:-NEW}" FAKE_BODY="$SCRATCH/body"
    FAKE_RC="${FAKE_RC:-0}" FAKE_READ_STDIN="${READ_STDIN:-}" FAKE_GO_READY="${READY_FILE:-}" FAKE_GO_RELEASE="${RELEASE_FILE:-}"
    RSDD_TEST_LABEL="$label" RSDD_TEST_SCRATCH="$SCRATCH")
  if [ -n "${USE_RSDD_BIN+x}" ]; then ev+=(RSDD_BIN="$USE_RSDD_BIN"); fi
  ${DORUN_TIMEOUT:+timeout "$DORUN_TIMEOUT"} env -u RSDD_BIN -u CGO_ENABLED "${ev[@]}" "$BASH_BIN" "$sp" "$@" <"${STDIN_FILE:-/dev/null}" >"$SCRATCH/$label.out" 2>"$SCRATCH/$label.err"
  echo "$?" >"$SCRATCH/$label.rc"
}
prefixed() {   # PREFIX FILE
  local l
  while IFS= read -r l || [ -n "$l" ]; do printf '%s| %s\n' "$1" "$l"; done <"$2"
}
show() {   # LABEL
  printf '## %s\nRC=%s\n' "$1" "$(<"$SCRATCH/$1.rc")"
  prefixed o "$SCRATCH/$1.out"; prefixed e "$SCRATCH/$1.err"
}
probes() {   # build-side probes: how often fake go built / ran srchash, where, what is left in bin/
  printf 'GOCALLS=%s\n' "$(grep -c . "$SCRATCH/go.log")"
  printf 'GOCWD=%s\n' "$(head -n 1 "$SCRATCH/go.log" 2>/dev/null)"
  printf 'SRCRUNS=%s\n' "$(grep -c . "$SCRATCH/run.log")"
  printf 'STAMP=%s\n' "$(head -n 1 "$SCRATCH/ld.log" 2>/dev/null)"
  printf 'GOCGO=%s\n' "$(head -n 1 "$SCRATCH/go.log.cgo" 2>/dev/null)"
  printf 'KIT=%s\n' "$KIT"
  printf 'TMPLEFT=%s\n' "$(find "$KIT/bin" -maxdepth 1 -name '.rsdd.*' ! -name .rsdd.lock 2>/dev/null | grep -c .)"
  printf 'LOCK=%s\n' "$([ -e "$KIT/bin/.rsdd.lock" ] && echo yes || echo no)"
}
hashprobe() {   # TREE = the reference hash of the tree now · BINHASH = what the binary on disk reports
  printf 'TREE=%s\n' "$(ref_hash "$KIT/rsdd")"
  printf 'BINHASH=%s\n' "$("$KIT/bin/rsdd" version --source-hash 2>&1)"
}
doshow() { dorun "$@"; show "$1"; }   # LABEL SCRIPT PM args...

tplfile() {   # NAME OUT — the header template NAME of the library under test, prefix stripped
  awk -v n="$1" '$0 == "#   >>> TEMPLATE " n { on = 1; next } $0 == "#   <<< TEMPLATE" { on = 0 } on { sub(/^#       /, ""); print }' "$SCLIB" >"$2"
}
sc_args() {
  mkkit args; putbin FRESH
  doshow plain shim.sh go a b
  doshow none shim.sh go
  doshow one shim.sh go --only
  doshow first shim.sh go --flag 'x y' mid last
  doshow mid shim.sh go first '' 'two words' $'new\nline' '*' last
  doshow last shim.sh go first 'a b'
  doshow empty shim.sh go ''
  probes
}
sc_exits() {
  mkkit exits; putbin FRESH
  local rc
  for rc in 0 1 3 42; do FAKE_RC=$rc doshow "rc$rc" shim.sh go; done
  probes
}
sc_stdin() {
  mkkit stdin; putbin FRESH
  printf 'line1\nline2 x\n' >"$SCRATCH/in.txt"
  READ_STDIN=1 STDIN_FILE="$SCRATCH/in.txt" doshow stdin shim.sh go
  probes
}
sc_stale() {   # VARIANT: gomod | gosum | deepgo | maingo — the CONTENT of one source changes, its mtime stays OLDER than the binary
  local v="${1:-gomod}" f
  mkkit "stale-$v"; putbin OLD
  case "$v" in
    gomod) f="$KIT/rsdd/go.mod" ;; gosum) f="$KIT/rsdd/go.sum" ;;
    deepgo) f="$KIT/rsdd/internal/deep/deep.go" ;; *) f="$KIT/rsdd/cmd/rsdd/main.go" ;;
  esac
  printf '// changed\n' >>"$f"; touch -d '2019-01-01 00:00:00' "$f"
  doshow stale shim.sh go x
  probes
  hashprobe
}
sc_stale_strict() {
  mkkit stalestrict; putbin OLD "$H_OLD"
  doshow strict strict.sh go x
  probes
  doshow lenient direct.sh go verify block y
}
sc_fresh() {   # the binary's hash equals the tree hash: no build, no go, no lock, silent
  mkkit fresh; putbin OLDBIN '' '2021-01-01 00:00:00'
  doshow fresh shim.sh go x
  probes
}
sc_touched() {   # every source touched NOW (newer than the binary), same bytes: still fresh
  mkkit touched; putbin OLDBIN '' '2021-01-01 00:00:00'
  touch "$KIT/rsdd/go.mod" "$KIT/rsdd/go.sum" "$KIT/rsdd/cmd/rsdd/main.go" "$KIT/rsdd/internal/deep/deep.go"
  doshow touched shim.sh go x
  probes
}
# --- the fingerprint fast path (#2599). RSDD_EXEC_FP_SETTLE=0 switches the racy-stamp guard off so a stamp is written at once;
# the guard itself is tested by sc_fp_settle with the default. A shim run is "full" when the sha tool was given files.
fpprobe() {   # FILEHASHES = full source hashes so far · STAMPFILE = is there a stamp
  printf 'FILEHASHES=%s\n' "$(grep -c '^-- ' "$SHA_LOG" 2>/dev/null)"
  printf 'STAMPFILE=%s\n' "$([ -f "$KIT/bin/.rsdd-fp" ] && echo yes || echo no)"
}
fp_warm() {   # NAME — a fresh binary, one shim run that verifies it and (settle 0) stamps the state
  export RSDD_EXEC_FP_SETTLE=0; : >"$SHA_LOG"
  mkkit "$1"; putbin OLDBIN
  doshow warm shim.sh shalog x
  fpprobe
}
sc_fp_fast() {   # unchanged tree: the second run takes the fast path (no full hash); a touch (ctime moves) hashes once more, still fresh
  fp_warm fpfast
  local before; before="$(grep -c '^-- ' "$SHA_LOG")"
  doshow again shim.sh shalog x
  fpprobe
  printf 'AGAIN-NEW-HASHES=%s\n' "$(($(grep -c '^-- ' "$SHA_LOG") - before))"
  touch "$KIT/rsdd/go.mod"
  doshow touched shim.sh shalog x
  fpprobe
  probes
}
sc_fp_settle() {   # the DEFAULT settle window: files written a moment ago are not stamped (a same-tick second write could hide)
  unset RSDD_EXEC_FP_SETTLE; : >"$SHA_LOG"
  mkkit fpsettle; putbin OLDBIN
  doshow warm shim.sh shalog x
  fpprobe
}
sc_fp_change() {   # VARIANT: edit | add | delete | rename | stampdir | stampjunk | badfind — a verified-fresh state then changes; the next run must rebuild
  local v="$1" pm=shalog
  fp_warm "fpc-$v"
  case "$v" in
    edit|stampdir|stampjunk|badfind)   # same size, old mtime restored: only the ctime tells
      printf 'package maix\n' >"$KIT/rsdd/cmd/rsdd/main.go"; touch -d '2020-01-01 00:00:00' "$KIT/rsdd/cmd/rsdd/main.go" ;;&
    stampdir) rm -f "$KIT/bin/.rsdd-fp"; mkdir "$KIT/bin/.rsdd-fp" ;;
    stampjunk) printf 'fp1:not-a-fingerprint\n' >"$KIT/bin/.rsdd-fp" ;;
    badfind) pm=badfind ;;
    add) printf 'package deep\n' >"$KIT/rsdd/internal/deep/extra.go" ;;
    delete) rm -f "$KIT/rsdd/internal/deep/deep.go" ;;
    rename) mv "$KIT/rsdd/internal/deep/deep.go" "$KIT/rsdd/internal/deep/deep2.go" ;;
  esac
  doshow changed shim.sh "$pm" x
  fpprobe
  probes
}
sc_unselected() {   # changes outside the hashed set (a _test.go, testdata/, a README) never rebuild
  mkkit unsel; putbin OLDBIN
  printf 'package main\n// t\n' >"$KIT/rsdd/cmd/rsdd/main_test.go"
  mkdir -p "$KIT/rsdd/testdata"; printf 'package x\n' >"$KIT/rsdd/testdata/x.go"; printf 'notes\n' >"$KIT/rsdd/README.md"
  doshow unsel shim.sh go x
  probes
}
sc_mismatch() {   # same sources, the binary was stamped with another hash
  mkkit mism; putbin OLD "$H_OLD"
  doshow mism shim.sh go x
  probes
  hashprobe
}
sc_unknown() {   # an unstamped binary prints sha256:unknown: stale
  mkkit unk; putbin OLD sha256:unknown
  doshow unk shim.sh go x
  probes
  hashprobe
}
sc_garbage() {   # any other answer is stale
  mkkit garb; putbin OLD 'not a hash at all'
  doshow garb shim.sh go x
  probes
}
sc_hashrc() {   # the right hash but a non-zero exit is stale
  mkkit hrc; putbin OLD
  FAKE_HASH_RC=1 doshow hrc shim.sh go x
  probes
}
sc_symbol() {   # the -X symbol of the library equals SOURCE_HASH_SYM of rsdd/Makefile
  # shellcheck source=/dev/null
  . "$SCLIB"
  printf 'LIBSYM=%s\n' "$_RSDD_EXEC_HASH_SYM"
  printf 'MAKESYM=%s\n' "$MK_SYM"
  mkkit sym
  doshow sym shim.sh go x
  probes
}
sc_fixture() {   # the shell tree hash over the Go fixture equals the hash the Go side pins (expected-hash.txt)
  local fx="$HERE/../../rsdd/internal/commands/testdata/source-hash" want
  # shellcheck source=/dev/null
  . "$SCLIB"
  [ -f "$fx/expected-hash.txt" ] || { echo "FIXTURE=ABSENT"; return; }
  want="$(<"$fx/expected-hash.txt")"
  if _rsdd_exec_shell_hash "$fx"; then
    if [ "$_RSDD_EXEC_TREE" = "$want" ]; then echo "FIXTURE=OK"; else echo "FIXTURE=DIFF got=$_RSDD_EXEC_TREE want=$want"; fi
  else
    echo "FIXTURE=UNAVAILABLE why=$_RSDD_EXEC_HWHY"
  fi
  printf 'REF=%s\n' "$(ref_hash "$fx")"
  printf 'WANT=%s\n' "$want"
}
sc_nosha() {   # no sha tool: go run rsdd-srchash stands in for the shell hash
  mkkit nosha; putbin OLD
  doshow fresh shim.sh nosha x
  probes
  mkkit noshastale; putbin OLD "$H_OLD"
  doshow stale shim.sh nosha x
  probes
  hashprobe
}
sc_hash_unavailable() {   # the hash cannot be computed anywhere: typed line, the existing binary runs, no build
  mkkit hu1; putbin OLD
  SRCMODE=fail doshow nosha shim.sh nosha x
  probes
  mkkit hu2; putbin OLD
  doshow nosha_nogo shim.sh nosha_nogo x
  probes
  mkkit hu3; putbin OLD "$H_OLD"
  SRCMODE=fail doshow stale_unknown shim.sh nosha x
  probes
}
sc_weirdpath() {   # [VARIANT] a selected path with a backslash or a newline: shell hash unavailable, never fresh by accident
  local v
  for v in ${1:-backslash newline}; do
    mkkit "weird-$v"; putbin OLD
    case "$v" in backslash) printf 'package x\n' >"$KIT/rsdd/bad\\name.go" ;; *) printf 'package x\n' >"$KIT/rsdd/bad"$'\n'"name.go" ;; esac
    SRCMODE=fail doshow "$v-fail" shim.sh go x
    probes
    GOHASH="$H_OLD" doshow "$v-go" shim.sh go x
    probes
  done
}
sc_empty_sel() {   # nothing selected: the hash of nothing proves nothing
  mkkit emptysel; putbin OLD
  rm -f "$KIT/rsdd/go.mod" "$KIT/rsdd/go.sum" "$KIT/rsdd/cmd/rsdd/main.go" "$KIT/rsdd/internal/deep/deep.go"
  SRCMODE=fail doshow empty shim.sh go x
  probes
}
sc_stampfail() {   # a failed stamp computation is a failed build
  mkkit sf1
  SRCMODE=fail doshow none shim.sh go x
  probes
  mkkit sf2; putbin OLD "$H_OLD"
  SRCMODE=fail doshow old shim.sh go x
  probes
  mkkit sf3
  GOHASH='not-a-hash' doshow garbage shim.sh go x
  probes
}
sc_noflock() {   # flock absent: one notice, the rebuild still happens (unlocked)
  mkkit nf1; putbin OLD "$H_OLD"
  doshow stale shim.sh goNF x
  probes
  mkkit nf2
  doshow missing shim.sh goNF x
  probes
  mkkit nf3; putbin OLD
  doshow fresh shim.sh goNF x
}
sc_lockfree() {   # the lock is held by someone else: a fresh binary still runs at once (no lock on the fresh path)
  mkkit lf; putbin OLD
  mkdir -p "$KIT/bin"; : >"$KIT/bin/.rsdd.lock"
  ( exec 9>"$KIT/bin/.rsdd.lock"; flock -x 9 && exec sleep 30 ) &
  local holder=$!
  _held() { ! flock -n "$KIT/bin/.rsdd.lock" true; }
  if ! wait_until _held; then echo "HANDSHAKE-TIMEOUT=lock-never-held"; kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null; return; fi
  DORUN_TIMEOUT=8 doshow fresh shim.sh go x
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
  probes
}
sc_missing() {
  mkkit missing
  doshow build shim.sh go z
  probes
  printf 'BINMODE=%s\n' "$([ -x "$KIT/bin/rsdd" ] && echo exec || echo noexec)"
}
sc_buildfail_old() {
  mkkit bfo; putbin OLD "$H_OLD"
  GOMODE=fail doshow bf shim.sh go
  probes
}
sc_buildfail_none() {
  mkkit bfn
  GOMODE=fail doshow bf shim.sh go
  probes
}
sc_nogo_old() {
  mkkit ngo; putbin OLD "$H_OLD"
  doshow nogo shim.sh nogo
  probes
}
sc_nogo_none() {
  mkkit ngn
  doshow nogo shim.sh nogo
  probes
}
sc_nosrc() {
  mkkit nosrc; rm -rf "$KIT/rsdd"
  doshow nosrc shim.sh go
  probes
}
sc_binonly() {   # binary present, sources directory absent: the binary runs, no build attempt
  mkkit binonly; putbin SOLO; rm -rf "$KIT/rsdd"
  doshow solo shim.sh nogo
  probes
}
sc_rsddbin() {
  mkkit rb; putbin KITBIN "$H_OLD"
  mkdir -p "$SCRATCH/own"; local body; body="$(<"$SCRATCH/body")"; printf '%s\n' "${body//@TAG@/ENV}" >"$SCRATCH/own/my rsdd"; chmod 755 "$SCRATCH/own/my rsdd"
  USE_RSDD_BIN="$SCRATCH/own/my rsdd" doshow env shim.sh go q
  probes
  rm -rf "${KIT:?}/bin" "${KIT:?}/rsdd"
  USE_RSDD_BIN="$SCRATCH/own/my rsdd" doshow nokit shim.sh nogo q
  USE_RSDD_BIN='' doshow empty shim.sh go
}
sc_rsddbin_bad() {
  mkkit rbb; putbin KITBIN
  USE_RSDD_BIN="$SCRATCH/does-not-exist" doshow missing shim.sh go
  : >"$SCRATCH/plain"; chmod 644 "$SCRATCH/plain"
  USE_RSDD_BIN="$SCRATCH/plain" doshow noexec shim.sh go
  mkdir -p "$SCRATCH/adir"
  USE_RSDD_BIN="$SCRATCH/adir" doshow dir shim.sh go
  probes
}
sc_usage() {
  mkkit usage; putbin FRESH
  doshow zero direct.sh go
  doshow one direct.sh go onlygroup
  doshow two direct.sh go verify block
}
sc_testdata_file() {   # a REGULAR FILE named testdata (vendor/, embed/) is dropped by the Go side: no hash drift, no rebuild
  mkkit tdfile
  mkdir -p "$KIT/rsdd/vendor/x" "$KIT/rsdd/embed/y"; printf 'v\n' >"$KIT/rsdd/vendor/x/testdata"; printf 'e\n' >"$KIT/rsdd/embed/y/testdata"
  putbin OLDBIN '' '2021-01-01 00:00:00'
  doshow tdfile shim.sh go x
  probes
}
sc_disagree() {   # the Go stamp never equals the shell hash: ONE rebuild, one typed line per call, no rebuild loop
  mkkit dis; putbin OLD "$H_OLD"
  GOHASH="$H_OLD" doshow first shim.sh go x
  probes
  GOHASH="$H_OLD" doshow second shim.sh go x
  probes
  printf 'package deep\n// moved\n' >"$KIT/rsdd/internal/deep/deep.go"
  GOHASH="$H_OLD" doshow third shim.sh go x
  probes
}
sc_disagree_noflock() {   # the same disagreement on a host without flock: still ONE rebuild, no loop (#2384 review)
  mkkit disnf; putbin OLD "$H_OLD"
  GOHASH="$H_OLD" doshow first shim.sh goNF x
  probes
  GOHASH="$H_OLD" doshow second shim.sh goNF x
  probes
  printf 'package deep\n// moved\n' >"$KIT/rsdd/internal/deep/deep.go"
  GOHASH="$H_OLD" doshow third shim.sh goNF x
  probes
}
sc_lockbusy() {   # the rebuild lock is held by someone else for longer than the wait
  local holder v
  for v in old none; do
    mkkit "lb-$v"; [ "$v" = old ] && putbin OLD "$H_OLD"
    mkdir -p "$KIT/bin"; : >"$KIT/bin/.rsdd.lock"
    ( exec 9>"$KIT/bin/.rsdd.lock"; flock -x 9 && exec sleep 30 ) &
    holder=$!
    _held() { ! flock -n "$KIT/bin/.rsdd.lock" true; }
    if ! wait_until _held; then echo "HANDSHAKE-TIMEOUT=lock-never-held"; kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null; return; fi
    RSDD_EXEC_LOCK_WAIT=1 DORUN_TIMEOUT=10 doshow "$v" shim.sh go x
    if [ "$v" = none ]; then RSDD_EXEC_LOCK_WAIT=1 DORUN_TIMEOUT=10 doshow guard hook.sh go guard verify block x; fi
    kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
    probes
  done
}
sc_lockwait_arg() {   # the wait handed to flock: default 120, RSDD_EXEC_LOCK_WAIT when valid; invalid values: one notice, 120
  local v n=0
  export FLOCK_LOG="$SCRATCH/flock.log"
  mkkit lwdef; putbin OLD "$H_OLD"; : >"$FLOCK_LOG"
  doshow default shim.sh flog x
  printf 'DEFARGS=%s\n' "$(head -n 1 "$FLOCK_LOG")"
  for v in 7 abc 0 -3 '' '1 2' 007; do
    n=$((n + 1)); mkkit "lw$n"; putbin OLD "$H_OLD"; : >"$FLOCK_LOG"
    RSDD_EXEC_LOCK_WAIT="$v" doshow "v$n" shim.sh flog x
    printf 'VALUE%s=[%s] ARGS=%s\n' "$n" "$v" "$(head -n 1 "$FLOCK_LOG")"
  done
}
sc_shasum() {   # only shasum (no sha256sum): fresh, stale and unknown-to-go cases still decide by the shell hash
  if [ -z "$SHASUM_OK" ]; then echo "SHASUM=ABSENT"; return; fi
  mkkit shs1; putbin OLDBIN
  doshow fresh shim.sh shasum_nogo x
  probes
  mkkit shs2; putbin OLD "$H_OLD"
  doshow stale shim.sh shasum x
  probes
}
sc_fixture_shasum() {   # the shasum path of the shell hash equals the hash the Go side pins
  local fx="$HERE/../../rsdd/internal/commands/testdata/source-hash" want
  if [ -z "$SHASUM_OK" ]; then echo "SHASUM=ABSENT"; return; fi
  # shellcheck source=/dev/null
  . "$SCLIB"
  want="$(<"$fx/expected-hash.txt")"
  (
    PATH="$FARMSHA"
    if command -v sha256sum >/dev/null 2>&1; then echo "FIXTURE=FARM-HAS-SHA256SUM"; exit 0; fi
    if _rsdd_exec_shell_hash "$fx"; then
      if [ "$_RSDD_EXEC_TREE" = "$want" ]; then echo "FIXTURE=OK"; else echo "FIXTURE=DIFF got=$_RSDD_EXEC_TREE want=$want"; fi
    else echo "FIXTURE=UNAVAILABLE why=$_RSDD_EXEC_HWHY"; fi
  )
}
sc_empty_strict() {   # empty selection under the caller's set -euo pipefail: the typed line, no unbound-variable crash
  mkkit emptystrict; putbin OLD
  rm -f "$KIT/rsdd/go.mod" "$KIT/rsdd/go.sum" "$KIT/rsdd/cmd/rsdd/main.go" "$KIT/rsdd/internal/deep/deep.go"
  SRCMODE=fail doshow strict strict.sh go x
  probes
}

wait_until() {   # FN — poll FN up to ~5 s; rc 1 = typed timeout
  local i
  for ((i = 0; i < 100; i++)); do "$1" && return 0; sleep 0.05; done
  return 1
}
_ready() { [ -e "$SCRATCH/ready" ]; }
_b_waiting() {   # B's flock child is blocked: a process `flock` carrying B's environment marker
  local d c
  for d in /proc/[0-9]*; do
    IFS= read -r -d '' c <"$d/cmdline" 2>/dev/null || continue
    case "$c" in */flock | flock) ;; *) continue ;; esac
    if grep -qaF "RSDD_TEST_LABEL=B" "$d/environ" 2>/dev/null && grep -qaF "RSDD_TEST_SCRATCH=$SCRATCH" "$d/environ" 2>/dev/null; then return 0; fi
  done
  return 1
}
sc_race() {   # A builds (slow); B starts meanwhile and must WAIT on the lock, then find A's binary fresh: one build
  mkkit race
  ( GOMODE=slow READY_FILE="$SCRATCH/ready" RELEASE_FILE="$SCRATCH/release" dorun A shim.sh go ra ) &
  if ! wait_until _ready; then echo "HANDSHAKE-TIMEOUT=A-never-signalled-ready"; : >"$SCRATCH/release"; wait; return; fi
  ( GOMODE=slow READY_FILE="$SCRATCH/ready" RELEASE_FILE="$SCRATCH/release" dorun B shim.sh go rb ) &
  # only when B is blocked on the lock (or, with no lock, never) is A released
  wait_until _b_waiting || echo "HANDSHAKE-TIMEOUT=B-never-blocked-on-the-lock"
  : >"$SCRATCH/release"
  wait
  show A; show B
  printf 'B-COMPLETE=%s\n' "$(grep -qx 'FAKE-NEW' "$SCRATCH/B.out" && echo yes || echo no)"
  probes
  local final=""
  if [ -x "$KIT/bin/rsdd" ]; then final="$("$KIT/bin/rsdd" 2>&1 | head -n 1)"; fi
  printf 'FINAL=%s\n' "$final"
}
sc_midbuild() {   # while A rebuilds a stale binary, the binary on disk is still the old COMPLETE one (atomic rename)
  mkkit mid; putbin OLD "$H_OLD"
  ( GOMODE=slow READY_FILE="$SCRATCH/ready" RELEASE_FILE="$SCRATCH/release" dorun A shim.sh go ra ) &
  if ! wait_until _ready; then echo "HANDSHAKE-TIMEOUT=A-never-signalled-ready"; : >"$SCRATCH/release"; wait; return; fi
  printf 'MID=%s\n' "$("$KIT/bin/rsdd" 2>&1 | head -n 1)"
  : >"$SCRATCH/release"
  wait
  show A
  probes
  printf 'FINAL=%s\n' "$("$KIT/bin/rsdd" 2>&1 | head -n 1)"
}

# hook scenarios
sc_hook_sweep() {
  mkkit hs; putbin FRESH
  local weird got; weird=$'/no/"q"\\b\ttab\x01ctl'
  USE_RSDD_BIN="$weird" doshow weird hook.sh gojq sweep verify block a
  USE_RSDD_BIN="$weird" doshow weirdplain hook.sh go sweep verify block a
  USE_RSDD_BIN='/plain/path' doshow plain hook.sh go sweep verify block a
  doshow nogo hook.sh nogo sweep verify block
  rm -rf "${KIT:?}/bin"; doshow nogo2 hook.sh nogo sweep verify block
  _rt weird sweep
}
_rt() {   # LABEL KIND — jq round trip of LABEL's stdout (KIND sweep|guard); prints JQ-RT-LABEL=ok|bad|skip
  local label="$1" kind="$2" weird got want
  weird=$'/no/"q"\\b\ttab\x01ctl'
  if ! command -v jq >/dev/null 2>&1; then echo "JQ-RT-$label=skip"; return; fi
  if [ "$kind" = sweep ]; then
    got="$(jq -r '.hookSpecificOutput.additionalContext' "$SCRATCH/$label.out" 2>/dev/null)"
    want="Research-SDD hooks DEGRADED: rsdd-unavailable — RSDD_BIN not executable: $weird"
    if [ "$got" = "$want" ] && jq -e '.hookSpecificOutput.hookEventName == "SessionStart"' "$SCRATCH/$label.out" >/dev/null 2>&1; then echo "JQ-RT-$label=ok"; else echo "JQ-RT-$label=bad"; fi
  else
    got="$(jq -r '.hookSpecificOutput.permissionDecisionReason' "$SCRATCH/$label.out" 2>/dev/null)"
    want="Research-SDD guard DEGRADED: rsdd-unavailable — RSDD_BIN not executable: $weird"
    if [ "$got" = "$want" ] && jq -e '.hookSpecificOutput.hookEventName == "PreToolUse" and .hookSpecificOutput.permissionDecision == "ask"' "$SCRATCH/$label.out" >/dev/null 2>&1; then echo "JQ-RT-$label=ok"; else echo "JQ-RT-$label=bad"; fi
  fi
}
sc_hook_guard() {
  mkkit hgd; putbin FRESH
  local weird; weird=$'/no/"q"\\b\ttab\x01ctl'
  USE_RSDD_BIN="$weird" doshow weird hook.sh gojq guard verify block a
  USE_RSDD_BIN="$weird" doshow weirdplain hook.sh go guard verify block a
  doshow avail hook.sh nogo guard verify block z
  rm -rf "${KIT:?}/bin"; doshow nogo hook.sh nogo guard verify block
  rm -rf "${KIT:?}/rsdd"; doshow nosrc hook.sh go guard verify block
  _rt weird guard; _rt weirdplain guard
}
sc_hook_nohe() {   # lib/hook-emit.sh missing beside the lib: still announces, still allows
  mkkit hnh; putbin FRESH
  rm -f "$KIT/toolbelt/lib/hook-emit.sh"
  USE_RSDD_BIN='/plain/path' doshow sweep hook.sh gojq sweep verify block
}
sc_tpl() {   # the header templates, extracted verbatim from the library under test, run as real shims
  cd "$SCRATCH" || exit 2
  mkkit tpl; putbin FRESH
  local t f
  mkdir -p "$SCRATCH/links" "$SCRATCH/l2" "$SCRATCH/nolib/toolbelt"
  for t in cli hook-sweep hook-guard hook-gate; do
    f="$KIT/toolbelt/t-$t.sh"
    tplfile "$t" "$f"; chmod 755 "$f"
    printf 'TPL-LINES-%s=%s\n' "$t" "$(grep -c . "$f")"
    ln -sf "$f" "$SCRATCH/links/abs-$t.sh"; ln -sf "../links/abs-$t.sh" "$SCRATCH/l2/hop-$t.sh"
    cp "$f" "$SCRATCH/nolib/toolbelt/t-$t.sh"
    doshow "$t-direct" "t-$t.sh" go a 'b c'
    doshow "$t-abs" "$SCRATCH/links/abs-$t.sh" go a
    doshow "$t-chain" "$SCRATCH/l2/hop-$t.sh" go a
    doshow "$t-nolib" "$SCRATCH/nolib/toolbelt/t-$t.sh" go a
    printf 'NOLIB-RC-%s=%s\n' "$t" "$(<"$SCRATCH/$t-nolib.rc")"
    printf 'CHAIN-OK-%s=%s\n' "$t" "$(grep -qx 'FAKE-FRESH' "$SCRATCH/$t-chain.out" && echo yes || echo no)"
    printf 'NOLIB-ASK-%s=%s\n' "$t" "$(grep -q '"permissionDecision":"ask"' "$SCRATCH/$t-nolib.out" && echo yes || echo no)"
  done
}
sc_bin_ro() {   # a non-writable <kit>/bin: the reason is named, the raw mktemp error is not shown
  if [ "$(id -u)" = 0 ]; then echo "SKIP-ROOT=1"; return; fi
  mkkit ro1; mkdir -p "$KIT/bin"; chmod a-w "$KIT/bin"
  doshow none shim.sh go
  probes
  chmod u+w "$KIT/bin"
  mkkit ro2; putbin OLD "$H_OLD"; chmod a-w "$KIT/bin"
  doshow stale shim.sh go
  probes
  chmod u+w "$KIT/bin"
  mkkit ro3; chmod a-w "$KIT"
  doshow nobindir shim.sh go
  chmod u+w "$KIT"
  mkkit ro4; mkdir -p "$KIT/bin"; : >"$KIT/bin/.rsdd.lock"; chmod a-w "$KIT/bin"
  doshow lockonly shim.sh go
  chmod u+w "$KIT/bin"
}
sc_scan_fail() {   # an unreadable subdirectory under rsdd/: the shell scan fails, the hash is UNAVAILABLE (never fresh)
  if [ "$(id -u)" = 0 ]; then echo "SKIP-ROOT=1"; return; fi
  mkkit sf; putbin FRESH
  local h; h="$(ref_hash "$KIT/rsdd")"
  chmod 000 "$KIT/rsdd/internal/deep"
  GOHASH="$h" doshow viago shim.sh go x
  probes
  SRCMODE=fail doshow degraded shim.sh go x
  probes
  chmod 755 "$KIT/rsdd/internal/deep"
}
sc_nocd() {   # the kit root cannot be resolved (cd fails at source time)
  mkkit nocd; putbin FRESH
  doshow nocd nocd.sh go
}

sc_hook_gate() {
  mkkit hg
  USE_RSDD_BIN='/no/"q"\b' doshow bad hook.sh go gate verify block a
  doshow nogo hook.sh nogo gate verify block
  GOMODE=fail doshow bfail hook.sh go gate verify block
  rm -rf "$KIT/rsdd"; doshow nosrc hook.sh go gate verify block
}
sc_hook_pass() {
  mkkit hp; putbin FRESH
  doshow sweep hook.sh go sweep verify block 'a b' ''
  FAKE_RC=3 doshow gate hook.sh go gate verify block x
  doshow guard hook.sh go guard verify block 'g h'
}
sc_hook_usage() {
  mkkit hu; putbin FRESH
  doshow none hook.sh go
  doshow one hook.sh go sweep
  doshow two hook.sh go sweep verify
  doshow badmode hook.sh go bogus verify block
}

if [ "${1:-}" = "--scenario" ]; then
  [ -f "${3:-}" ] || { echo "scenario: lib not found: ${3:-}" >&2; exit 2; }
  setup_world "$3"
  case "$2" in
    stale-*) sc_stale "${2#stale-}" ;;
    fp_change-*) sc_fp_change "${2#fp_change-}" ;;
    weirdpath-*) sc_weirdpath "${2#weirdpath-}" ;;
    *) "sc_${2//-/_}" ;;
  esac
  exit 0
fi

# ------------------------------------------------------------------------------------------------ main suite
ROOT="$(mktemp -d)" || exit 2
trap 'rm -rf "$ROOT"' EXIT
pass=0; fail=0
ok() { printf '  PASS  %-66s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
no() { printf '  FAIL  %-66s %s\n' "$1" "${2:-}"; fail=$((fail+1)); }
skip() { printf '  SKIP  %-66s %s\n' "$1" "${2:-}"; }

echo "== rsdd-exec.test.sh (SUT: lib/rsdd-exec.sh) =="
[ -f "$LIB" ] || { echo "FATAL: lib not found: $LIB" >&2; exit 2; }

scen() {   # NAME LIB -> report on stdout
  "$BASH_BIN" "$SELF" --scenario "$1" "$2" 2>&1
}
sect() {   # REPORT LABEL -> lines of section ## LABEL
  awk -v want="## $2" '/^## /{on=($0==want); next} on' <<<"$1"
}
chk() {    # NAME REPORT LABEL REGEX  — section matches (grep -E)
  local body; body="$(sect "$2" "$3")"
  if grep -qE -- "$4" <<<"$body"; then ok "$1"; else no "$1" "section [$3] lacks /$4/: $(head -n 6 <<<"$body" | tr '\n' '~')"; fi
}
nchk() {   # NAME REPORT LABEL REGEX  — section does NOT match
  local body; body="$(sect "$2" "$3")"
  if grep -qE -- "$4" <<<"$body"; then no "$1" "section [$3] has /$4/"; else ok "$1"; fi
}
pchk() {   # NAME REPORT REGEX — the probe lines match
  if grep -qE -- "$3" <<<"$2"; then ok "$1"; else no "$1" "report lacks /$3/"; fi
}
val_of() {   # REPORT KEY -> the value of the KEY=value probe line
  grep -m1 "^$2=" <<<"$1" | cut -d= -f2-
}
eqchk() {   # NAME REPORT KEY1 KEY2 — both probes hold the SAME well-formed sha256:<hex> hash
  local a b; a="$(val_of "$2" "$3")"; b="$(val_of "$2" "$4")"
  if [[ "$a" =~ ^sha256:[0-9a-f]{64}$ ]] && [ "$a" = "$b" ]; then ok "$1"; else no "$1" "$3=[$a] $4=[$b]"; fi
}
stdout_of() { sect "$1" "$2" | grep '^o| ' | cut -c4-; }
stderr_of() { sect "$1" "$2" | grep '^e| ' | cut -c4-; }

# expected fake-rsdd stdout for TAG and args (the shim prepends `verify block`)
expect_out() {   # TAG args...
  local tag="$1" a; shift
  printf 'FAKE-%s\nn=%s\n' "$tag" "$(($# + 2))"
  printf 'arg=%q\n' verify block
  for a in "$@"; do printf 'arg=%q\n' "$a"; done
}
args_case() {   # LABEL args...
  local l="$1" got want; shift
  got="$(stdout_of "$R" "$l")"; want="$(expect_out FRESH "$@")"
  if [ "$got" = "$want" ]; then ok "args [$l] pass through byte-exact"; else no "args [$l] pass through byte-exact" "got=[$got] want=[$want]"; fi
  if [ -z "$(stderr_of "$R" "$l")" ]; then ok "args [$l] stderr silent on a fresh binary"; else no "args [$l] stderr silent on a fresh binary" "$(stderr_of "$R" "$l")"; fi
}

# 1. arguments (list edges: first/middle/last special, single, none, empty, newline)
R="$(scen args "$LIB")"
args_case plain a b
args_case none
args_case one --only
args_case first --flag 'x y' mid last
args_case mid first '' 'two words' $'new\nline' '*' last
args_case last first 'a b'
args_case empty ''
chk "args: exit 0 on fresh binary" "$R" plain '^RC=0$'
pchk "args: fresh binary never triggers a build" "$R" '^GOCALLS=0$'

# 2. exit codes and stdin
R="$(scen exits "$LIB")"
for rc in 0 1 3 42; do chk "exit code $rc passes through" "$R" "rc$rc" "^RC=$rc\$"; done
R="$(scen stdin "$LIB")"
want="stdin=$(printf '%q' $'line1\nline2 x')"
chk "stdin reaches the binary" "$R" stdin "^o\| $(sed 's/[][\\.*^$|]/\\&/g' <<<"$want")\$"

# 3. staleness is a SOURCE-HASH comparison (the mtime of files plays no part)
for v in gomod gosum deepgo maingo; do
  R="$(scen "stale-$v" "$LIB")"
  chk "stale ($v content changed, mtime OLDER than the binary) -> rebuilt, new binary runs" "$R" stale '^o\| FAKE-NEW$'
  pchk "stale ($v) -> exactly one go build" "$R" '^GOCALLS=1$'
  pchk "stale ($v) -> go ran inside <kit>/rsdd" "$R" '^GOCWD=.*/k it/rsdd$'
  pchk "stale ($v) -> go build runs with CGO_ENABLED=0 (a cgo binary aborts in pthread_create under the test RLIMIT_AS cap)" "$R" '^GOCGO=0$'
  pchk "stale ($v) -> no temp file left in bin/" "$R" '^TMPLEFT=0$'
  pchk "stale ($v) -> the rebuild took the lock file" "$R" '^LOCK=yes$'
  eqchk "stale ($v) -> the build was stamped with the NEW tree hash" "$R" STAMP TREE
  eqchk "stale ($v) -> the rebuilt binary reports the new tree hash" "$R" BINHASH TREE
  nchk "stale ($v) -> no source-hash-unavailable line" "$R" stale 'source-hash-unavailable'
done
R="$(scen fresh "$LIB")"
chk "matching hash -> the binary runs" "$R" fresh '^o\| FAKE-OLDBIN$'
nchk "matching hash -> stderr silent" "$R" fresh '^e\| '
pchk "matching hash -> no go build" "$R" '^GOCALLS=0$'
pchk "matching hash -> no go run either (the shell hash is enough)" "$R" '^SRCRUNS=0$'
pchk "matching hash -> no lock file taken (the fresh path is lock-free)" "$R" '^LOCK=no$'
R="$(scen touched "$LIB")"
chk "touched but unchanged (mtime newer than the binary, same bytes) -> binary runs" "$R" touched '^o\| FAKE-OLDBIN$'
pchk "touched but unchanged -> NO rebuild" "$R" '^GOCALLS=0$'
nchk "touched but unchanged -> no rebuild attempt (stderr silent)" "$R" touched '^e\| '
R="$(scen unselected "$LIB")"
chk "changes outside the hashed set (_test.go, testdata/, README) -> binary runs" "$R" unsel '^o\| FAKE-OLDBIN$'
pchk "changes outside the hashed set -> no rebuild" "$R" '^GOCALLS=0$'
nchk "changes outside the hashed set -> no rebuild attempt (stderr silent)" "$R" unsel '^e\| '
R="$(scen mismatch "$LIB")"
chk "different hash -> rebuilt, new binary runs" "$R" mism '^o\| FAKE-NEW$'
pchk "different hash -> exactly one build" "$R" '^GOCALLS=1$'
eqchk "different hash -> the rebuild stamps the tree hash" "$R" STAMP TREE
eqchk "different hash -> the rebuilt binary reports the tree hash" "$R" BINHASH TREE
R="$(scen unknown "$LIB")"
chk "sha256:unknown -> rebuilt, new binary runs" "$R" unk '^o\| FAKE-NEW$'
pchk "sha256:unknown -> exactly one build" "$R" '^GOCALLS=1$'
eqchk "sha256:unknown -> the rebuild stamps the tree hash" "$R" STAMP TREE
R="$(scen garbage "$LIB")"
chk "a non-hash answer -> rebuilt" "$R" garb '^o\| FAKE-NEW$'
R="$(scen hashrc "$LIB")"
chk "the right hash with a non-zero exit -> rebuilt" "$R" hrc '^o\| FAKE-NEW$'
pchk "the right hash with a non-zero exit -> one build" "$R" '^GOCALLS=1$'
R="$(scen symbol "$LIB")"
LS="$(val_of "$R" LIBSYM)"; MS="$(val_of "$R" MAKESYM)"
if [ -n "$LS" ] && [ "$LS" = "$MS" ]; then ok "the -X symbol equals SOURCE_HASH_SYM of rsdd/Makefile"; else no "the -X symbol equals SOURCE_HASH_SYM of rsdd/Makefile" "lib=[$LS] makefile=[$MS]"; fi
R="$(scen fixture "$LIB")"
pchk "shell tree hash over the Go fixture equals expected-hash.txt" "$R" '^FIXTURE=OK$'
eqchk "the README pipeline (ref_hash) agrees with expected-hash.txt on the fixture" "$R" REF WANT
R="$(scen nosha "$LIB")"
chk "no sha tool + matching go hash -> binary runs" "$R" fresh '^o\| FAKE-OLD$'
pchk "no sha tool + matching go hash -> go run stood in, no build" "$R" '^SRCRUNS=1$'
nchk "no sha tool + go fallback worked -> no degraded line" "$R" fresh 'source-hash-unavailable'
chk "no sha tool + stale go hash -> rebuilt" "$R" stale '^o\| FAKE-NEW$'
R="$(scen hash_unavailable "$LIB")"
chk "hash unavailable (no sha tool, go fails) -> typed line" "$R" nosha '^e\| rsdd-exec: degraded: rsdd-source-hash-unavailable — .+'
chk "hash unavailable -> the existing binary runs" "$R" nosha '^o\| FAKE-OLD$'
chk "hash unavailable -> rc 0" "$R" nosha '^RC=0$'
chk "hash unavailable, go absent -> typed line names the fallback" "$R" nosha_nogo '^e\| rsdd-exec: degraded: rsdd-source-hash-unavailable — .*go not found'
chk "hash unavailable, go absent -> the existing binary runs" "$R" nosha_nogo '^o\| FAKE-OLD$'
[ "$(sect "$R" nosha | grep -c '^e| .*degraded: ')" = 1 ] && ok "hash unavailable -> exactly one degraded line" || no "hash unavailable -> exactly one degraded line"
pchk "hash unavailable -> never a rebuild (an unknown is not stale)" "$R" '^GOCALLS=0$'
chk "hash unavailable on an unknown-stale binary -> the old one still runs, typed line" "$R" stale_unknown '^e\| rsdd-exec: degraded: rsdd-source-hash-unavailable — '
R="$(scen weirdpath "$LIB")"
for v in backslash newline; do
  chk "path with a $v: shell hash unavailable, go fails -> typed line" "$R" "$v-fail" '^e\| rsdd-exec: degraded: rsdd-source-hash-unavailable — .*(newline or a backslash|out of step)'
  chk "path with a $v: shell hash unavailable, go fallback answers -> stale detected, rebuilt" "$R" "$v-go" '^o\| FAKE-NEW$'
done
R="$(scen empty_sel "$LIB")"
chk "empty selection -> typed line, never fresh" "$R" empty '^e\| rsdd-exec: degraded: rsdd-source-hash-unavailable — .*no source files matched'
chk "empty selection -> the existing binary runs" "$R" empty '^o\| FAKE-OLD$'

# 4. missing binary -> build; build output stays off stdout; temp file gone; binary executable
R="$(scen missing "$LIB")"
chk "missing binary -> built and run" "$R" build '^o\| FAKE-NEW$'
nchk "build output never on stdout" "$R" build '^o\| .*BUILDNOISE'
chk "build output reaches stderr" "$R" build '^e\| BUILDNOISE-STDOUT$'
pchk "built binary is executable" "$R" '^BINMODE=exec$'
pchk "built into <kit>/rsdd, once" "$R" '^GOCALLS=1$'
pchk "no temp file left after a build" "$R" '^TMPLEFT=0$'
pchk "kit path with a space works (probe shows it)" "$R" '^KIT=.*/k it$'

# 5. build failure
R="$(scen buildfail_old "$LIB")"
chk "build failed + old binary -> old one runs" "$R" bf '^o\| FAKE-OLD$'
chk "build failed + old binary -> notice on stderr" "$R" bf '^e\| rsdd-exec: notice: rebuild failed; running a binary older than its sources: .*/k it/bin/rsdd$'
pchk "build failed + old binary -> junk temp removed" "$R" '^TMPLEFT=0$'
R="$(scen buildfail_none "$LIB")"
chk "build failed + no binary -> rc 2" "$R" bf '^RC=2$'
chk "build failed + no binary -> exact degraded line" "$R" bf '^e\| degraded: rsdd-unavailable — build failed$'
nchk "build failed + no binary -> nothing on stdout" "$R" bf '^o\| '
pchk "build failed + no binary -> junk temp removed" "$R" '^TMPLEFT=0$'
[ "$(sect "$R" bf | grep -c '^e| degraded: ')" = 1 ] && ok "exactly one degraded line" || no "exactly one degraded line"

R="$(scen stampfail "$LIB")"
chk "stamp computation fails + no binary -> rc 2" "$R" none '^RC=2$'
chk "stamp computation fails + no binary -> build failed" "$R" none '^e\| degraded: rsdd-unavailable — build failed$'
chk "stamp computation fails + old binary -> notice, old runs" "$R" old '^e\| rsdd-exec: notice: rebuild failed; running a binary older than its sources: '
chk "stamp computation fails + old binary -> old one runs" "$R" old '^o\| FAKE-OLD$'
chk "a stamp that is not a hash is a failed build" "$R" garbage '^e\| degraded: rsdd-unavailable — build failed$'
pchk "failed stamp -> go build never ran" "$R" '^GOCALLS=0$'

# 6. go absent
R="$(scen nogo_old "$LIB")"
chk "stale + go absent -> old binary runs" "$R" nogo '^o\| FAKE-OLD$'
chk "stale + go absent -> notice" "$R" nogo '^e\| rsdd-exec: notice: go not found; running a binary older than its sources: .*/k it/bin/rsdd$'
R="$(scen nogo_none "$LIB")"
chk "no binary + go absent -> rc 2" "$R" nogo '^RC=2$'
chk "no binary + go absent -> degraded line" "$R" nogo '^e\| degraded: rsdd-unavailable — go not found$'
nchk "no binary + go absent -> nothing on stdout" "$R" nogo '^o\| '

# 7. no sources
R="$(scen nosrc "$LIB")"
chk "no binary + no sources -> rc 2" "$R" nosrc '^RC=2$'
chk "no binary + no sources -> degraded line names the path" "$R" nosrc '^e\| degraded: rsdd-unavailable — no sources at .*/k it/rsdd$'
nchk "no binary + no sources -> nothing on stdout" "$R" nosrc '^o\| '
R="$(scen binonly "$LIB")"
chk "binary without a sources dir -> binary runs silently" "$R" solo '^o\| FAKE-SOLO$'
nchk "binary without a sources dir -> no stderr" "$R" solo '^e\| '

# 8. RSDD_BIN
R="$(scen rsddbin "$LIB")"
chk "RSDD_BIN used as-is (path with a space)" "$R" env '^o\| FAKE-ENV$'
pchk "RSDD_BIN: no staleness check, no rebuild" "$R" '^GOCALLS=0$'
chk "RSDD_BIN works with no kit binary and no go" "$R" nokit '^o\| FAKE-ENV$'
R2="$R"
chk "empty RSDD_BIN is ignored (falls to the kit path)" "$R2" empty '^(RC=2|o\| )'
nchk "empty RSDD_BIN is not treated as a bad path" "$R2" empty 'RSDD_BIN not executable'
R="$(scen rsddbin_bad "$LIB")"
for l in missing noexec dir; do
  chk "RSDD_BIN [$l] -> rc 2" "$R" "$l" '^RC=2$'
  chk "RSDD_BIN [$l] -> degraded line" "$R" "$l" '^e\| degraded: rsdd-unavailable — RSDD_BIN not executable: .+'
  nchk "RSDD_BIN [$l] -> nothing on stdout" "$R" "$l" '^o\| '
done
pchk "bad RSDD_BIN never falls back to a build" "$R" '^GOCALLS=0$'

# 9. usage and shell hygiene
R="$(scen usage "$LIB")"
for l in zero one; do
  chk "usage: [$l] arg -> rc 2" "$R" "$l" '^RC=2$'
  chk "usage: [$l] arg -> usage line on stderr" "$R" "$l" '^e\| usage: rsdd_exec <group> <cmd>'
  nchk "usage: [$l] arg -> nothing on stdout" "$R" "$l" '^o\| '
done
nchk "sourcing the lib leaves the caller's shell options alone" "$R" zero 'OPTS-CHANGED'
chk "two args reach the binary" "$R" two '^o\| FAKE-FRESH$'
R="$(scen stale_strict "$LIB")"
chk "caller under set -euo pipefail: double source + stale rebuild" "$R" strict '^o\| FAKE-NEW$'
nchk "caller under set -euo pipefail: options unchanged" "$R" strict 'OPTS-CHANGED'
chk "caller without options: unchanged and runs" "$R" lenient '^o\| FAKE-NEW$|^o\| FAKE-OLD$'
nchk "caller without options: unchanged" "$R" lenient 'OPTS-CHANGED'
chk "strict caller: rc 0" "$R" strict '^RC=0$'

# 10. concurrent rebuild safety: flock serialises, the re-check after the lock avoids a second build, the rename is atomic
R="$(scen race "$LIB")"
if grep -q '^HANDSHAKE-TIMEOUT=' <<<"$R"; then no "race: handshake completed" "$(grep '^HANDSHAKE-TIMEOUT=' <<<"$R")"; else ok "race: handshake completed (B was blocked on the lock)"; fi
for l in A B; do
  chk "race: shim $l execs a COMPLETE binary" "$R" "$l" '^o\| FAKE-NEW$'
  chk "race: shim $l exit 0" "$R" "$l" '^RC=0$'
done
pchk "race: shim B ran a complete binary (B-COMPLETE)" "$R" '^B-COMPLETE=yes$'
pchk "race: two racing shims build exactly once" "$R" '^GOCALLS=1$'
pchk "race: no temp file left behind" "$R" '^TMPLEFT=0$'
pchk "race: the final binary on disk runs and prints the full marker" "$R" '^FINAL=FAKE-NEW$'
R="$(scen midbuild "$LIB")"
if grep -q '^HANDSHAKE-TIMEOUT=' <<<"$R"; then no "midbuild: handshake completed" "$(grep '^HANDSHAKE-TIMEOUT=' <<<"$R")"; else ok "midbuild: handshake completed"; fi
pchk "midbuild: while A builds, the binary on disk is still the old COMPLETE one" "$R" '^MID=FAKE-OLD$'
pchk "midbuild: after A the binary on disk is the new one" "$R" '^FINAL=FAKE-NEW$'
R="$(scen noflock "$LIB")"
chk "flock absent + stale -> one notice" "$R" stale '^e\| rsdd-exec: notice: flock not found; rebuilding without a lock$'
chk "flock absent + stale -> still rebuilt" "$R" stale '^o\| FAKE-NEW$'
chk "flock absent + no binary -> built" "$R" missing '^o\| FAKE-NEW$'
nchk "flock absent + fresh binary -> no notice (no lock is wanted)" "$R" fresh 'flock'
for l in stale missing; do
  if [ "$(sect "$R" "$l" | grep -c 'flock not found')" = 1 ]; then ok "flock absent [$l] -> the notice appears exactly once"; else no "flock absent [$l] -> the notice appears exactly once"; fi
done
R="$(scen stale_strict "$LIB")"
nchk "flock present -> no flock notice" "$R" strict 'flock not found'
R="$(scen lockfree "$LIB")"
if grep -q '^HANDSHAKE-TIMEOUT=' <<<"$R"; then no "lockfree: lock holder started" "$(grep '^HANDSHAKE-TIMEOUT=' <<<"$R")"; else ok "lockfree: lock holder started"; fi
chk "fresh binary + the lock held by another process -> still runs (not blocked)" "$R" fresh '^o\| FAKE-OLD$'
chk "fresh binary + the lock held by another process -> rc 0 (no timeout)" "$R" fresh '^RC=0$'

R="$(scen testdata_file "$LIB")"
chk "a regular file named testdata under vendor/ and embed/ is not hashed -> binary runs" "$R" tdfile '^o\| FAKE-OLDBIN$'
pchk "a regular file named testdata -> no rebuild" "$R" '^GOCALLS=0$'
nchk "a regular file named testdata -> stderr silent" "$R" tdfile '^e\| '
R="$(scen disagree "$LIB")"
chk "shell/go hash disagreement: first call runs the rebuilt binary" "$R" first '^o\| FAKE-NEW$'
chk "shell/go hash disagreement: first call prints the typed line" "$R" first '^e\| rsdd-exec: degraded: rsdd-source-hash-unavailable — shell and go source hashes disagree$'
[ "$(sect "$R" first | grep -c 'degraded: ')" = 1 ] && ok "disagreement: exactly one degraded line on the first call" || no "disagreement: exactly one degraded line on the first call"
chk "shell/go hash disagreement: second call runs the binary, rc 0" "$R" second '^o\| FAKE-NEW$'
chk "shell/go hash disagreement: second call still says so" "$R" second '^e\| rsdd-exec: degraded: rsdd-source-hash-unavailable — shell and go source hashes disagree$'
[ "$(sect "$R" second | grep -c 'degraded: ')" = 1 ] && ok "disagreement: exactly one degraded line on the second call" || no "disagreement: exactly one degraded line on the second call"
nchk "shell/go hash disagreement: the second call does not rebuild" "$R" second 'BUILDNOISE'
chk "shell/go hash disagreement: two consecutive calls build exactly once (no loop)" "$R" second '^GOCALLS=1$'
chk "shell/go hash disagreement: a changed source after it is rebuilt again" "$R" third '^e\| BUILDNOISE-STDERR$'
pchk "shell/go hash disagreement: the changed source costs exactly one more build" "$R" '^GOCALLS=2$'
R="$(scen disagree_noflock "$LIB")"
chk "flock absent + hash disagreement: first call runs the rebuilt binary" "$R" first '^o\| FAKE-NEW$'
chk "flock absent + hash disagreement: first call prints the typed line" "$R" first '^e\| rsdd-exec: degraded: rsdd-source-hash-unavailable — shell and go source hashes disagree$'
nchk "flock absent + hash disagreement: the second call does not rebuild" "$R" second 'BUILDNOISE'
nchk "flock absent + hash disagreement: the second call does not claim to rebuild (no flock notice)" "$R" second 'flock not found'
chk "flock absent + hash disagreement: two consecutive calls build exactly once (no loop)" "$R" second '^GOCALLS=1$'
pchk "flock absent + hash disagreement: a changed source costs exactly one more build" "$R" '^GOCALLS=2$'
R="$(scen lockbusy "$LIB")"
if grep -q '^HANDSHAKE-TIMEOUT=' <<<"$R"; then no "lockbusy: lock holder started" "$(grep '^HANDSHAKE-TIMEOUT=' <<<"$R")"; else ok "lockbusy: lock holder started"; fi
chk "lock busy + old binary -> the old binary runs" "$R" old '^o\| FAKE-OLD$'
chk "lock busy + old binary -> rc 0 (no hang)" "$R" old '^RC=0$'
chk "lock busy + old binary -> notice names the wait and the binary" "$R" old '^e\| rsdd-exec: notice: rebuild lock busy for 1s; running a binary older than its sources: .*/k it/bin/rsdd$'
chk "lock busy + no binary -> rc 2" "$R" none '^RC=2$'
chk "lock busy + no binary -> degraded line" "$R" none '^e\| degraded: rsdd-unavailable — rebuild lock busy$'
nchk "lock busy + no binary -> nothing on stdout" "$R" none '^o\| '
chk "lock busy + no binary, guard hook -> rc 0" "$R" guard '^RC=0$'
chk "lock busy + no binary, guard hook -> still answers ask" "$R" guard '^o\| .*"permissionDecision":"ask".*rebuild lock busy'
pchk "lock busy -> no go build" "$R" '^GOCALLS=0$'
R="$(scen lockwait_arg "$LIB")"
pchk "lock wait: default is 120 seconds" "$R" '^DEFARGS=-w 120 [0-9]+$'
pchk "lock wait: RSDD_EXEC_LOCK_WAIT=7 is handed to flock" "$R" '^VALUE1=\[7\] ARGS=-w 7 [0-9]+$'
for n in 2 3 4 5 6 7; do
  pchk "lock wait: invalid value #$n -> flock gets 120" "$R" "^VALUE$n=\\[.*\\] ARGS=-w 120 [0-9]+\$"
  chk "lock wait: invalid value #$n -> one notice" "$R" "v$n" '^e\| rsdd-exec: notice: RSDD_EXEC_LOCK_WAIT must be a positive integer, got .*; using 120$'
  [ "$(sect "$R" "v$n" | grep -c 'RSDD_EXEC_LOCK_WAIT must be')" = 1 ] && ok "lock wait: invalid value #$n -> the notice appears exactly once" || no "lock wait: invalid value #$n -> the notice appears exactly once"
done
nchk "lock wait: a valid value prints no notice" "$R" v1 'RSDD_EXEC_LOCK_WAIT'
R="$(scen shasum "$LIB")"
if grep -q '^SHASUM=ABSENT' <<<"$R"; then skip "shasum fallback" "shasum not installed (typed SKIP)"; else
  chk "shasum only: matching hash -> binary runs" "$R" fresh '^o\| FAKE-OLDBIN$'
  nchk "shasum only: matching hash -> stderr silent" "$R" fresh '^e\| '
  pchk "shasum only: matching hash -> no build, no go run" "$R" '^GOCALLS=0$'
  chk "shasum only: different hash -> rebuilt" "$R" stale '^o\| FAKE-NEW$'
  nchk "shasum only: different hash -> no source-hash-unavailable line" "$R" stale 'source-hash-unavailable'
fi
R="$(scen fixture_shasum "$LIB")"
if grep -q '^SHASUM=ABSENT' <<<"$R"; then skip "shasum fixture hash" "shasum not installed (typed SKIP)"; else
  pchk "shasum only: the shell tree hash over the Go fixture equals expected-hash.txt" "$R" '^FIXTURE=OK$'
fi
R="$(scen empty_strict "$LIB")"
chk "empty selection under set -euo pipefail -> typed line" "$R" strict '^e\| rsdd-exec: degraded: rsdd-source-hash-unavailable — .*no source files matched'
chk "empty selection under set -euo pipefail -> the existing binary runs" "$R" strict '^o\| FAKE-OLD$'
chk "empty selection under set -euo pipefail -> rc 0" "$R" strict '^RC=0$'
nchk "empty selection under set -euo pipefail -> no unbound variable" "$R" strict 'unbound'

# 11. hook mode: sweep / guard / gate
rt_chk() {   # NAME REPORT LABEL — jq round trip probe: ok, or a typed SKIP when jq is absent
  case "$(grep "^JQ-RT-$3=" <<<"$2")" in
    "JQ-RT-$3=ok") ok "$1" ;;
    "JQ-RT-$3=skip") skip "$1" "jq not installed (typed SKIP)" ;;
    *) no "$1" "$(grep "^JQ-RT-$3=" <<<"$2")" ;;
  esac
}
R="$(scen hook_sweep "$LIB")"
chk "hook sweep (bad RSDD_BIN): rc 0" "$R" weird '^RC=0$'
chk "hook sweep: degraded line on stderr" "$R" weird '^e\| degraded: rsdd-unavailable — RSDD_BIN not executable: '
rt_chk "hook sweep with jq: envelope is JSON; quote, backslash, tab and control char survive a round trip" "$R" weird
chk "hook sweep without jq: plain text headline (rsdd_hook_emit fallback)" "$R" plain '^o\| Research-SDD hooks DEGRADED: rsdd-unavailable — RSDD_BIN not executable: /plain/path$'
nchk "hook sweep without jq: no JSON" "$R" plain 'hookSpecificOutput'
chk "hook sweep: go absent -> headline names the reason" "$R" nogo2 'Research-SDD hooks DEGRADED: rsdd-unavailable — (go not found|no sources)'
nchk "hook sweep: available binary is not an error" "$R" nogo 'DEGRADED'
chk "hook sweep: available binary executes instead" "$R" nogo '^o\| FAKE-FRESH$'
R="$(scen hook_nohe "$LIB")"
chk "hook sweep: lib/hook-emit.sh missing -> plain headline, still rc 0" "$R" sweep '^o\| Research-SDD hooks DEGRADED: rsdd-unavailable — RSDD_BIN not executable: /plain/path \(lib/hook-emit.sh missing\)$'
chk "hook sweep: lib/hook-emit.sh missing -> rc 0" "$R" sweep '^RC=0$'

R="$(scen hook_guard "$LIB")"
ASK_RE='"hookSpecificOutput":\{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"Research-SDD guard DEGRADED: rsdd-unavailable — '
for l in weird weirdplain nogo nosrc; do
  chk "hook guard [$l]: rc 0" "$R" "$l" '^RC=0$'
  chk "hook guard [$l]: stdout is the PreToolUse ask decision (never an empty allow)" "$R" "$l" "^o\\| \\{$ASK_RE"
  chk "hook guard [$l]: degraded line on stderr" "$R" "$l" '^e\| degraded: rsdd-unavailable — '
  nchk "hook guard [$l]: never allow or deny" "$R" "$l" '"permissionDecision":"(allow|deny)"'
done
chk "hook guard without jq: quote, backslash, tab and control char escaped" "$R" weirdplain '/no/\\"q\\"\\\\b\\ttab\\u0001ctl"\}\}$'
rt_chk "hook guard with jq: decision JSON round trip (reason intact)" "$R" weird
rt_chk "hook guard without jq: escaped JSON parses and round-trips" "$R" weirdplain
chk "hook guard: available binary executes instead" "$R" avail '^o\| FAKE-FRESH$'
nchk "hook guard: available binary emits no decision" "$R" avail 'hookSpecificOutput'

R="$(scen hook_gate "$LIB")"
for l in bad nogo bfail nosrc; do
  chk "hook gate [$l]: rc 0 (allow)" "$R" "$l" '^RC=0$'
  nchk "hook gate [$l]: stdout empty" "$R" "$l" '^o\| '
  chk "hook gate [$l]: degraded line on stderr" "$R" "$l" '^e\| degraded: rsdd-unavailable — '
  chk "hook gate [$l]: state=allow branch=degraded line (the gates' fields, no target=)" "$R" "$l" '^e\| rsdd-exec-gate: state=allow branch=degraded \(rsdd-unavailable — .+\)$'
done
chk "hook gate: reason with quote and backslash printed verbatim" "$R" bad '^e\| rsdd-exec-gate: state=allow branch=degraded \(rsdd-unavailable — RSDD_BIN not executable: /no/"q"\\b\)$'
R="$(scen hook_pass "$LIB")"
chk "hook sweep with a binary: args pass through, no envelope" "$R" sweep '^o\| FAKE-FRESH$'
nchk "hook sweep with a binary: no JSON" "$R" sweep 'hookSpecificOutput'
chk "hook sweep with a binary: empty-string arg kept" "$R" sweep "^o\\| arg=''\$"
chk "hook gate with a binary: exit code passes through" "$R" gate '^RC=3$'
chk "hook guard with a binary: args pass through" "$R" guard '^o\| arg=g\\ h$'
R="$(scen hook_usage "$LIB")"
for l in none one two badmode; do
  chk "hook usage [$l] -> rc 2" "$R" "$l" '^RC=2$'
  chk "hook usage [$l] -> usage line" "$R" "$l" '^e\| usage: rsdd_exec_hook <sweep\|guard\|gate>'
  nchk "hook usage [$l] -> nothing on stdout" "$R" "$l" '^o\| '
done

# 11b. the documented shim templates, extracted from the library header and run verbatim
R="$(scen tpl "$LIB")"
blk() { awk '/# RSDD-SELF-DIR/ { on = 1 } on { sub(/^[ \t]+/, ""); print } on && /unset _rsdd_s/ { exit }' "$1"; }
CANON_BLK="$(blk "$HERE/../verify-registry-hook.sh")"
for t in cli hook-sweep hook-guard hook-gate; do
  pchk "template [$t]: extracted from the header (non-empty)" "$R" "^TPL-LINES-$t=[1-9]"
  tplfile() { awk -v n="$1" '$0 == "#   >>> TEMPLATE " n { on = 1; next } $0 == "#   <<< TEMPLATE" { on = 0 } on { sub(/^#       /, ""); print }' "$LIB" >"$2"; }
  tplfile "$t" "$ROOT/tpl-$t.sh"
  if [ -n "$CANON_BLK" ] && [ "$(blk "$ROOT/tpl-$t.sh")" = "$CANON_BLK" ]; then ok "template [$t]: idiom block equals verify-registry-hook.sh's"; else no "template [$t]: idiom block equals verify-registry-hook.sh's"; fi
  for v in direct abs chain; do
    chk "template [$t] $v: runs, rc 0" "$R" "$t-$v" '^RC=0$'
    chk "template [$t] $v: finds the lib and passes args through" "$R" "$t-$v" '^o\| FAKE-FRESH$'
    chk "template [$t] $v: first arg reaches the binary" "$R" "$t-$v" '^o\| arg=a$'
  done
  nchk "template [$t] chain: no self-dir degraded line" "$R" "$t-chain" 'self-dir symlink'
  pchk "template [$t]: relative two-hop symlink chain resolves" "$R" "^CHAIN-OK-$t=yes\$"
done
chk "template [cli] lib absent: rc 2" "$R" cli-nolib '^RC=2$'
chk "template [cli] lib absent: degraded line names the shim" "$R" cli-nolib '^e\| degraded: rsdd-unavailable — rsdd-exec.sh missing beside .*/nolib/toolbelt/t-cli.sh$'
nchk "template [cli] lib absent: nothing on stdout" "$R" cli-nolib '^o\| '
chk "template [hook-sweep] lib absent: announced on stdout, rc 0" "$R" hook-sweep-nolib '^o\| Research-SDD hook: lib/rsdd-exec.sh missing beside .*/t-hook-sweep.sh$'
chk "template [hook-sweep] lib absent: rc 0" "$R" hook-sweep-nolib '^RC=0$'
chk "template [hook-guard] lib absent: rc 0" "$R" hook-guard-nolib '^RC=0$'
chk "template [hook-guard] lib absent: fails closed to ask" "$R" hook-guard-nolib "^o\\| \\{\"hookSpecificOutput\":\\{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"ask\",\"permissionDecisionReason\":\"Research-SDD guard DEGRADED: rsdd-unavailable — rsdd-exec.sh missing beside "
chk "template [hook-guard] lib absent: degraded line on stderr" "$R" hook-guard-nolib '^e\| degraded: rsdd-unavailable — rsdd-exec.sh missing beside '
chk "template [hook-gate] lib absent: rc 0" "$R" hook-gate-nolib '^RC=0$'
nchk "template [hook-gate] lib absent: stdout empty" "$R" hook-gate-nolib '^o\| '
chk "template [hook-gate] lib absent: branch=degraded line" "$R" hook-gate-nolib '^e\| rsdd-exec-gate: state=allow branch=degraded \(rsdd-unavailable — rsdd-exec.sh missing beside '

# 11c. read-only bin dir, failed staleness scan, unresolvable kit root
R="$(scen bin_ro "$LIB")"
if grep -q '^SKIP-ROOT=1$' <<<"$R"; then
  skip "bin dir not writable: cases" "running as root (typed SKIP: root ignores permissions)"
else
  chk "bin not writable, no binary: rc 2" "$R" none '^RC=2$'
  chk "bin not writable, no binary: reason is the bin dir, not 'build failed'" "$R" none '^e\| degraded: rsdd-unavailable — bin dir not writable: .*/k it/bin$'
  nchk "bin not writable: raw mktemp error is silenced" "$R" none 'mktemp'
  nchk "bin not writable, no binary: no 'build failed' wording" "$R" none 'build failed'
  chk "bin not writable, stale binary: old binary runs" "$R" stale '^o\| FAKE-OLD$'
  chk "bin not writable, stale binary: notice names the bin dir" "$R" stale '^e\| rsdd-exec: notice: bin dir not writable: .*/k it/bin; running a binary older than its sources: '
  nchk "bin not writable, stale binary: raw mktemp error is silenced" "$R" stale 'mktemp'
  chk "kit dir not writable (bin/ cannot be created): reason is the bin dir" "$R" nobindir '^e\| degraded: rsdd-unavailable — bin dir not writable: .*/k it/bin$'
  chk "lock file exists but bin not writable (mktemp fails): reason is the bin dir" "$R" lockonly '^e\| degraded: rsdd-unavailable — bin dir not writable: .*/k it/bin$'
  nchk "lock file exists but bin not writable: raw mktemp error is silenced" "$R" lockonly 'mktemp'
fi
R="$(scen scan_fail "$LIB")"
if grep -q '^SKIP-ROOT=1$' <<<"$R"; then
  skip "failed shell scan is an unavailable hash" "running as root (typed SKIP: root can read every directory)"
else
  chk "unreadable subdir: shell scan fails, the go fallback proves it fresh -> binary runs" "$R" viago '^o\| FAKE-FRESH$'
  pchk "unreadable subdir -> the go fallback ran once, no build" "$R" '^SRCRUNS=1$'
  chk "unreadable subdir + go fails -> typed line (never silently fresh)" "$R" degraded '^e\| rsdd-exec: degraded: rsdd-source-hash-unavailable — scanning the sources failed'
  pchk "unreadable subdir + go fails -> no rebuild" "$R" '^GOCALLS=0$'
fi
R="$(scen nocd "$LIB")"
chk "kit root unresolvable (cd fails at source time) -> rc 2" "$R" nocd '^RC=2$'
chk "kit root unresolvable -> degraded line" "$R" nocd '^e\| degraded: rsdd-unavailable — cannot resolve the kit root$'
nchk "kit root unresolvable -> nothing on stdout" "$R" nocd '^o\| '

# 3b. the fingerprint fast path (#2599)
R="$(scen fp_fast "$LIB")"
chk "fp: first run verifies with one full hash" "$R" warm '^FILEHASHES=1$'
chk "fp: first run leaves a stamp" "$R" warm '^STAMPFILE=yes$'
chk "fp: unchanged tree -> the binary runs" "$R" again '^o\| FAKE-OLDBIN$'
chk "fp: unchanged tree -> NO second full hash (the fast path)" "$R" again '^AGAIN-NEW-HASHES=0$'
chk "fp: touched file (ctime moves) -> one more full hash" "$R" touched '^FILEHASHES=2$'
chk "fp: touched file, same bytes -> still fresh, binary runs" "$R" touched '^o\| FAKE-OLDBIN$'
pchk "fp: nothing ever rebuilt on a fresh tree" "$R" '^GOCALLS=0$'
R="$(scen fp_settle "$LIB")"
chk "fp: default settle window -> files written just now are not stamped" "$R" warm '^STAMPFILE=no$'
chk "fp: default settle window -> the run is still verified by the full hash" "$R" warm '^FILEHASHES=1$'
for v in edit add delete rename stampdir stampjunk badfind; do
  R="$(scen "fp_change-$v" "$LIB")"
  chk "fp [$v]: a stamped fresh state then changed -> rebuilt, new binary runs" "$R" changed '^o\| FAKE-NEW$'
  pchk "fp [$v]: exactly one go build" "$R" '^GOCALLS=1$'
done

# 12. overhead (report-only: wall-time assertions flake under load)
OV="$ROOT/ov"; mkdir -p "$OV/k it/toolbelt/lib" "$OV/k it/bin"
cp "$LIB" "$OV/k it/toolbelt/lib/rsdd-exec.sh"
printf '#!/usr/bin/env bash\nexit 0\n' >"$OV/k it/bin/rsdd"; chmod 755 "$OV/k it/bin/rsdd"
tplfile cli "$OV/k it/toolbelt/shim.sh"   # the documented CLI template, so the overhead includes the RSDD-SELF-DIR idiom
if [ -f "$LIB" ]; then
  N=200
  t0=$EPOCHREALTIME; for ((i = 0; i < N; i++)); do "$BASH_BIN" "$OV/k it/toolbelt/shim.sh" a >/dev/null 2>&1; done; t1=$EPOCHREALTIME
  for ((i = 0; i < N; i++)); do "$OV/k it/bin/rsdd" verify block a >/dev/null 2>&1; done; t2=$EPOCHREALTIME
  awk -v a="$t0" -v b="$t1" -v c="$t2" -v n="$N" 'BEGIN { s=(b-a)*1000/n; d=(c-b)*1000/n; printf "  INFO  overhead (report-only): shim %.2f ms/call, direct %.2f ms/call, resolution overhead %.2f ms/call (%d iterations)\n", s, d, s-d, n }'
fi

# ------------------------------------------------------------------------------------------------ summary
echo ""
total=$((pass+fail))
[ "$total" -gt 0 ] || { echo "FATAL: zero tests executed." >&2; exit 2; }
if [ "$fail" -gt 0 ]; then
  printf 'RESULT: %d passed / %d FAILED\n' "$pass" "$fail"
  printf '== %d passed · %d failed ==\n' "$pass" "$fail"
  [ "${1:-}" = "--prove-teeth" ] || exit 1
else
  printf 'RESULT: %d passed / 0 failed\n' "$pass"
  printf '== %d passed · 0 failed ==\n' "$pass"
  [ "${1:-}" = "--prove-teeth" ] || exit 0
fi

# ------------------------------------------------------------------------------------------------ teeth
# Every mutant is a COPY of the library built through lib/mutant.sh (refuses empty / identical / syntax-broken
# / live-tree mutants) under $ROOT. Every tooth runs the SAME scenario on the original (rc 0, must show the
# good marker) and on the mutant (rc 0, must show the bad marker or lose the good one): the scenario driver
# always exits 0, so the difference is carried by the report text, never by a crash.
echo ""
echo "== teeth: mutants of lib/rsdd-exec.sh =="
# shellcheck source=lib/mutant.sh
. "$HERE/lib/mutant.sh"
mutant_bootstrap mutant_chain mutant_built mutant_tooth mutant_or_count mutant_chain_or_count mutant_built_or_count mutant_crash_re || exit 2
# shellcheck disable=SC2034  # read by mutant_tooth (default original) in lib/mutant.sh
SUT="$LIB"
CRASH="$(mutant_crash_re bash cmd)" || exit 2
MUT="$ROOT/mut"; mkdir -p "$MUT"
# mk NAME EXPR... — build $MUT/NAME.sh from the SUT; a refusal counts one FAIL and returns 1.
mk() {
  local n="$1"; shift
  if mutant_chain_or_count fail "teeth $n: mutant build" "$LIB" "$MUT/$n.sh" "$@"; then
    ok "teeth $n: mutant differs from SUT and passes bash -n"; return 0
  fi
  return 1
}
# tt NAME SCENARIO tooth-opts... — scenario report, original vs mutant
tt() {
  local n="$1" sc="$2"; shift 2
  if mutant_tooth "teeth $n" 0 0 "$MUT/$n.sh" "$@" -- "$BASH_BIN" "$SELF" --scenario "$sc" @SUT@; then pass=$((pass+1)); else fail=$((fail+1)); fi
}

# --- the source-hash comparison (original: equal hash = fresh, any other answer = stale)
CMP='\[ "\$got" = "\$_RSDD_EXEC_TREE" \] || return 1'
mk hash-inverted "s#$CMP#[ \"\$got\" != \"\$_RSDD_EXEC_TREE\" ] || return 1#" &&
  tt hash-inverted fresh --good-has '^GOCALLS=0$' --bad-lacks '^GOCALLS=0$' --bad-lacks "$CRASH"
mk hash-always-fresh "s#$CMP#:#" &&
  tt hash-always-fresh mismatch --good-has '^o\| FAKE-NEW$' --bad-has '^o\| FAKE-OLD$' --bad-lacks "$CRASH"
mk hash-always-stale "s#$CMP#return 1#" &&
  tt hash-always-stale fresh --good-has '^GOCALLS=0$' --bad-lacks '^GOCALLS=0$' --bad-lacks "$CRASH"
mk unknown-is-fresh "s#$CMP#[ \"\$got\" = \"\$_RSDD_EXEC_TREE\" ] || [ \"\$got\" = sha256:unknown ] || return 1#" &&
  tt unknown-is-fresh unknown --good-has '^o\| FAKE-NEW$' --bad-has '^o\| FAKE-OLD$' --bad-lacks "$CRASH"
mk hash-exit-ignored 's#2>/dev/null </dev/null)" || return 1#2>/dev/null </dev/null)"#' &&
  tt hash-exit-ignored hashrc --good-has '^o\| FAKE-NEW$' --bad-has '^o\| FAKE-OLD$' --bad-lacks "$CRASH"
# mtime logic back in place of the hash: touched-but-unchanged rebuilds, a same-content-old-mtime change does not
mk mtime-fresh-touched "s#$CMP#[ -z \"\$(find \"\$2\" -type f -newer \"\$1\" -print -quit)\" ] || return 1#" &&
  tt mtime-fresh-touched touched --good-has '^GOCALLS=0$' --bad-lacks '^GOCALLS=0$' --bad-lacks "$CRASH"
mk mtime-fresh-content "s#$CMP#[ -z \"\$(find \"\$2\" -type f -newer \"\$1\" -print -quit)\" ] || return 1#" &&
  tt mtime-fresh-content stale-gomod --good-has '^o\| FAKE-NEW$' --bad-has '^o\| FAKE-OLD$' --bad-lacks "$CRASH"
# --- unavailable hash: typed, and never a rebuild
mk unavailable-rebuilds 's#^        \*) echo "rsdd-exec: degraded: rsdd-source-hash-unavailable#        *) need=1; echo "rsdd-exec: degraded: rsdd-source-hash-unavailable#' &&
  tt unavailable-rebuilds hash_unavailable --good-lacks 'rsdd-exec: notice: ' --bad-has 'rsdd-exec: notice: ' --bad-lacks "$CRASH"
mk unavailable-silent 's#echo "rsdd-exec: degraded: rsdd-source-hash-unavailable — \$_RSDD_EXEC_HWHY" >&2 ;;#: ;;#' &&
  tt unavailable-silent hash_unavailable --good-has '^e\| rsdd-exec: degraded: rsdd-source-hash-unavailable — ' --bad-lacks '^e\| rsdd-exec: degraded: rsdd-source-hash-unavailable' --bad-lacks "$CRASH"
mk go-fallback-skipped 's#_rsdd_exec_go_hash "\$1" && return 0#false#' &&
  tt go-fallback-skipped nosha --good-has '^SRCRUNS=1$' --bad-lacks '^SRCRUNS=1$' --bad-lacks "$CRASH"
mk find-failure-reason 's#FIND-FAILED) _RSDD_EXEC_HWHY="scanning the sources failed"; return 1 ;;#FIND-FAILED) ;;#' &&
  tt find-failure-reason scan_fail --good-has 'scanning the sources failed' --bad-lacks 'scanning the sources failed' --bad-lacks "$CRASH"
mk unsafe-path-accepted 's#_RSDD_EXEC_HWHY="a source path contains a newline or a backslash"; return 1#:#' 's#if \[ "\${line:64:1}" != " " \] || \[ "\${line:66}" != "\${files\[i\]}" \]; then _RSDD_EXEC_HWHY="\${sha\[0\]} answered out of step"; return 1; fi#:#' &&
  tt unsafe-path-accepted weirdpath-backslash --good-has '^e\| rsdd-exec: degraded: rsdd-source-hash-unavailable — ' --bad-lacks '^e\| rsdd-exec: degraded: rsdd-source-hash-unavailable' --bad-lacks "$CRASH"
mk empty-selection-accepted 's|if \[ "\${#files\[@\]}" -eq 0 \]; then _RSDD_EXEC_HWHY="no source files matched"; return 1; fi|:|' 's|if \[ "\${#lines\[@\]}" -ne "\${#files\[@\]}" \]; then _RSDD_EXEC_HWHY="\${sha\[0\]} answered out of step"; return 1; fi|:|' &&
  tt empty-selection-accepted empty_sel --good-has '^e\| rsdd-exec: degraded: rsdd-source-hash-unavailable — ' --bad-lacks '^e\| rsdd-exec: degraded: rsdd-source-hash-unavailable' --bad-lacks "$CRASH"
# --- the shell hash must keep equal to the Go side: each rule of the selection / manifest, on the shared fixture
FXG=(--good-has '^FIXTURE=OK$' --bad-lacks '^FIXTURE=OK$' --bad-lacks "$CRASH")
mk fixture-test-files "s# ! -name '\\*_test.go'##" && tt fixture-test-files fixture "${FXG[@]}"
mk fixture-embed "s# -o -path './embed/\\*' -o -path '\\*/embed/\\*'##" && tt fixture-embed fixture "${FXG[@]}"
mk fixture-vendor "s# -o -path './vendor/\\*'##" && tt fixture-vendor fixture "${FXG[@]}"
mk fixture-testdata "s# ! -path './testdata/\\*' ! -path '\\*/testdata/\\*'##" && tt fixture-testdata fixture "${FXG[@]}"
mk fixture-gomod "s# -o -path ./go.mod -o -path ./go.sum##" && tt fixture-gomod fixture "${FXG[@]}"
mk fixture-sort 's#LC_ALL=C sort -z#LC_ALL=C sort -rz#' && tt fixture-sort fixture "${FXG[@]}"
mk fixture-nul "s|printf '%s\\\\0%s\\\\n'|printf '%s %s\\\\n'|" && tt fixture-nul fixture "${FXG[@]}"
mk fixture-prefix 's|"${files\[i\]#./}"|"${files[i]}"|' && tt fixture-prefix fixture "${FXG[@]}"
mk unselected-rebuilds "s# ! -name '\\*_test.go'##" && tt unselected-rebuilds unselected --good-has '^GOCALLS=0$' --bad-lacks '^GOCALLS=0$' --bad-lacks "$CRASH"
# --- the fingerprint fast path (#2599): each guard removed makes a stale binary run silently, or the fast path vanish
FPB=(--good-has '^GOCALLS=1$' --bad-lacks '^GOCALLS=1$' --bad-lacks "$CRASH")
mk fp-guard-removed 's#if \[ -n "\$stamp" \] \&\& \[ "\$stamp" = "\$fp" \]; then return 0; fi#if [ -n "$stamp" ]; then return 0; fi#' &&
  tt fp-guard-removed fp_change-edit "${FPB[@]}"
mk fp-ignores-ctime 's#%T@\\t%C@#%T@#' &&
  tt fp-ignores-ctime fp_change-edit "${FPB[@]}"
mk fp-ignores-listing 's#"\$listing" "\$binline"#"" "$binline"#' &&
  tt fp-ignores-listing fp_change-add "${FPB[@]}"
mk fp-failure-is-fresh 's#^    if _rsdd_exec_fingerprint "\$2" "\$1"; then#    _rsdd_exec_fingerprint "$2" "$1" || return 0\n    if true; then#' &&
  tt fp-failure-is-fresh fp_change-badfind "${FPB[@]}"
mk fp-stamp-unread-is-fresh 's#stamp="\$(cat -- "\$(dirname -- "\$1")/.rsdd-fp" 2>/dev/null)" || stamp=""#stamp="$(cat -- "$(dirname -- "$1")/.rsdd-fp" 2>/dev/null)" || stamp="$fp"#' &&
  tt fp-stamp-unread-is-fresh fp_change-stampdir "${FPB[@]}"
mk fp-no-settle 's#local stamp="\$1" settle=2 ref#local stamp="$1" settle=0 ref#' &&
  tt fp-no-settle fp_settle --good-has '^STAMPFILE=no$' --bad-lacks '^STAMPFILE=no$' --bad-lacks "$CRASH"
mk fp-never-used 's#if \[ -n "\$stamp" \] \&\& \[ "\$stamp" = "\$fp" \]; then return 0; fi#:#' &&
  tt fp-never-used fp_fast --good-has '^AGAIN-NEW-HASHES=0$' --bad-lacks '^AGAIN-NEW-HASHES=0$' --bad-lacks "$CRASH"
# --- the stamp
mk stamp-dropped 's# -X \$_RSDD_EXEC_HASH_SYM=\$h##' &&
  tt stamp-dropped mismatch --good-has '^STAMP=sha256:[0-9a-f]{64}$' --bad-lacks '^STAMP=sha256:[0-9a-f]{64}$' --bad-lacks "$CRASH"
mk stamp-wrong-value 's#-X \$_RSDD_EXEC_HASH_SYM=\$h#-X $_RSDD_EXEC_HASH_SYM=sha256:0000000000000000000000000000000000000000000000000000000000000000#' &&
  tt stamp-wrong-value mismatch --good-lacks '^STAMP=sha256:0{64}$' --bad-has '^STAMP=sha256:0{64}$' --bad-lacks "$CRASH"
mk stamp-wrong-symbol 's#commands.sourceHash#commands.otherHash#' &&
  tt stamp-wrong-symbol symbol --good-has '^LIBSYM=.*\.sourceHash$' --bad-lacks '^LIBSYM=.*\.sourceHash$' --bad-lacks "$CRASH"
mk stamp-unvalidated 's#&& _rsdd_exec_valid_hash "\$h" && CGO_ENABLED=0 go build#\&\& CGO_ENABLED=0 go build#' &&
  tt stamp-unvalidated stampfail --good-lacks '^o\| FAKE-NEW$' --bad-has '^o\| FAKE-NEW$' --bad-lacks "$CRASH"
mk stamp-failure-ignored 's#h="\$(go run ./cmd/rsdd-srchash .)" && _rsdd_exec_valid_hash "\$h" && CGO_ENABLED=0 go build#h="$(go run ./cmd/rsdd-srchash .)"; CGO_ENABLED=0 go build#' &&
  tt stamp-failure-ignored stampfail --good-lacks '^o\| FAKE-NEW$' --bad-has '^o\| FAKE-NEW$' --bad-lacks "$CRASH"
# --- the lock
mk no-lock 's#flock -w "\$_RSDD_EXEC_LOCKWAIT" "\$lfd" || exit 12#:#' &&
  tt no-lock race --good-lacks '^HANDSHAKE-TIMEOUT' --good-has '^GOCALLS=1$' --bad-has '^HANDSHAKE-TIMEOUT=B-never-blocked' --bad-lacks "$CRASH"
mk no-recheck 's#if \[ "\$crc" -eq 0 \]; then exit 10; fi#:#' &&
  tt no-recheck race --good-has '^GOCALLS=1$' --bad-has '^GOCALLS=2$' --bad-lacks "$CRASH"
mk recheck-rc-unmapped 's#if \[ "\$brc" -eq 10 \]; then brc=0; fi#:#' &&
  tt recheck-rc-unmapped race --good-has '^B-COMPLETE=yes$' --bad-has '^B-COMPLETE=no$' --bad-lacks "$CRASH"
mk lock-on-fresh-path 's#_rsdd_exec_check "\$bin" "\$src" || crc=\$?#{ flock -x 9 \&\& _rsdd_exec_check "$bin" "$src"; } 9>>"$kit/bin/.rsdd.lock" || crc=$?#' &&
  tt lock-on-fresh-path lockfree --good-has '^RC=0$' --bad-has '^RC=124$' --bad-lacks "$CRASH"
mk flock-notice-swallowed 's#echo "rsdd-exec: notice: flock not found; rebuilding without a lock" >&2#:#' &&
  tt flock-notice-swallowed noflock --good-has '^e\| rsdd-exec: notice: flock not found; rebuilding without a lock$' --bad-lacks 'flock not found' --bad-lacks "$CRASH"
mk lock-create-rc 's#{ : >>"\$lock"; } 2>/dev/null || return 3#{ : >>"$lock"; } 2>/dev/null || return 1#' &&
  tt lock-create-rc bin_ro --good-lacks 'degraded: rsdd-unavailable — build failed' --bad-has 'degraded: rsdd-unavailable — build failed' --bad-lacks "$CRASH"
mk no-atomic-rename 's#-o "\$tmp" ./cmd/rsdd && chmod 755 "\$tmp" && mv -f "\$tmp" "\$bin"#-o "$bin" ./cmd/rsdd \&\& chmod 755 "$bin"#' &&
  tt no-atomic-rename midbuild --good-has '^MID=FAKE-OLD$' --bad-lacks '^MID=FAKE-OLD$' --bad-lacks '^HANDSHAKE-TIMEOUT' --bad-lacks "$CRASH"
# --- the static build (#2461): a cgo binary aborts in pthread_create under the test RLIMIT_AS cap
mk cgo-on 's#CGO_ENABLED=0 go build#go build#' &&
  tt cgo-on stale-gomod --good-has '^GOCGO=0$' --bad-has '^GOCGO=unset$' --bad-lacks "$CRASH"
mk swallow-degraded 's#printf '"'"'degraded: rsdd-unavailable — %s\\n'"'"' "\$1" >&2; return 2;#return 2;#' &&
  tt swallow-degraded nogo_none --good-has '^e\| degraded: rsdd-unavailable — go not found$' --bad-lacks '^e\| degraded: ' --bad-lacks "$CRASH"
mk degrade-rc0 's#"\$1" >&2; return 2; }#"$1" >\&2; return 0; }#' &&
  tt degrade-rc0 nogo_none --good-has '^RC=2$' --bad-has '^RC=0$' --bad-lacks "$CRASH"
mk degrade-stdout 's#"\$1" >&2; return 2; }#"$1"; return 2; }#' &&
  tt degrade-stdout nogo_none --good-lacks '^o\| ' --bad-has '^o\| degraded: ' --bad-lacks "$CRASH"
mk unquoted-args 's#"\$cmd" "\$@"$#"$cmd" $@#' &&
  tt unquoted-args args --good-has '^o\| arg=two\\ words$' --bad-lacks '^o\| arg=two\\ words$' --bad-lacks "$CRASH"
mk ignore-rsdd-bin 's#if \[ -n "\${RSDD_BIN:-}" \]; then#if false; then#' &&
  tt ignore-rsdd-bin rsddbin --good-has '^o\| FAKE-ENV$' --bad-lacks '^o\| FAKE-ENV$' --bad-lacks "$CRASH"
mk rsdd-bin-not-checked 's#if \[ ! -f "\$RSDD_BIN" \] || \[ ! -x "\$RSDD_BIN" \]; then#if false; then#' &&
  tt rsdd-bin-not-checked rsddbin_bad --good-has '^e\| degraded: rsdd-unavailable — RSDD_BIN not executable' --bad-lacks '^e\| degraded: ' --bad-lacks "$CRASH"
mk build-stdout 's#"\$bin" ) >&2#"$bin" )#' &&
  tt build-stdout missing --good-lacks '^o\| .*BUILDNOISE' --bad-has '^o\| .*BUILDNOISE' --bad-lacks "$CRASH"
mk no-chmod 's# \&\& chmod 755 "\$tmp"##' &&
  tt no-chmod missing --good-has '^o\| FAKE-NEW$' --bad-lacks '^o\| FAKE-NEW$'
mk no-tmp-cleanup "s#trap 'rm -f -- \"\$tmp\"' EXIT; ##" &&
  tt no-tmp-cleanup buildfail_none --good-has '^TMPLEFT=0$' --bad-has '^TMPLEFT=[1-9]' --bad-lacks "$CRASH"
mk no-old-fallback 's#if \[ "\$have" -eq 0 \]; then _RSDD_EXEC_WHY="\$why"; return 2; fi#_RSDD_EXEC_WHY="$why"; return 2#' &&
  tt no-old-fallback buildfail_old --good-has '^o\| FAKE-OLD$' --bad-lacks '^o\| FAKE-OLD$' --bad-lacks "$CRASH"
mk no-nogo-fallback 's#if \[ "\$have" -eq 0 \]; then _RSDD_EXEC_WHY="go not found"; return 2; fi#_RSDD_EXEC_WHY="go not found"; return 2#' &&
  tt no-nogo-fallback nogo_old --good-has '^o\| FAKE-OLD$' --bad-lacks '^o\| FAKE-OLD$' --bad-lacks "$CRASH"
mk usage-threshold 's#if \[ "\$\#" -lt 2 \]; then echo "usage: rsdd_exec <group>#if [ "$\#" -lt 1 ]; then echo "usage: rsdd_exec <group>#' &&
  tt usage-threshold usage --good-has '^e\| usage: rsdd_exec <group>' --good-lacks '^o\| arg=onlygroup$' --bad-has '^o\| arg=onlygroup$'
mk lib-sets-e '1a\
set -e' &&
  tt lib-sets-e usage --good-lacks 'OPTS-CHANGED' --bad-has 'OPTS-CHANGED' --bad-lacks "$CRASH"
mk no-nosrc 's#_RSDD_EXEC_WHY="no sources at \$src"; return 2#_RSDD_EXEC_WHY="no sources"; return 2#' &&
  tt no-nosrc nosrc --good-has 'no sources at .*/k it/rsdd$' --bad-lacks 'no sources at ' --bad-lacks "$CRASH"
# hook mode
JQ_ON=0; command -v jq >/dev/null 2>&1 && JQ_ON=1
ASKRE='"permissionDecision":"ask"'
mk sweep-rc2 's#^      return 0$#      return 2#' &&
  tt sweep-rc2 hook_sweep --good-has '^RC=0$' --bad-has '^RC=2$' --bad-lacks "$CRASH"
mk sweep-silent 's#^            rsdd_hook_emit .*$#            :#' &&
  tt sweep-silent hook_sweep --good-has '^## plain$' --good-has '^o\| Research-SDD hooks DEGRADED: rsdd-unavailable — RSDD_BIN not executable: /plain/path$' --bad-lacks '^o\| Research-SDD hooks DEGRADED' --bad-lacks "$CRASH"
if [ "$JQ_ON" = 1 ]; then
  mk sweep-unescaped 's#^            rsdd_hook_emit .*$#            printf '"'"'{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"Research-SDD hooks DEGRADED: rsdd-unavailable — %s"}}\n'"'"' "$_RSDD_EXEC_WHY"#' &&
    tt sweep-unescaped hook_sweep --good-has '^JQ-RT-weird=ok$' --bad-has '^JQ-RT-weird=bad$' --bad-lacks "$CRASH"
else
  skip "teeth sweep-unescaped" "jq not installed (typed SKIP)"
fi
mk gate-stdout 's#"\$_RSDD_EXEC_WHY" >&2 ;;$#"$_RSDD_EXEC_WHY" ;;#' &&
  tt gate-stdout hook_gate --good-lacks '^o\| ' --bad-has '^o\| rsdd-exec-gate: ' --bad-lacks "$CRASH"
mk gate-no-branch 's#rsdd-exec-gate: state=allow branch=degraded#rsdd-exec-gate: state=allow branch=ok#' &&
  tt gate-no-branch hook_gate --good-has 'branch=degraded \(rsdd-unavailable' --bad-lacks 'branch=degraded \(rsdd-unavailable' --bad-lacks "$CRASH"
mk hook-mode-open 's#case "\$mode" in sweep | guard | gate) ;; \*) echo .*esac$#:#' &&
  tt hook-mode-open hook_usage --good-lacks '^o\| arg=verify$' --bad-has '^o\| arg=verify$'
# guard mode
mk guard-empty-allow 's#^        guard) _rsdd_exec_ask .*$#        guard) : ;;#' &&
  tt guard-empty-allow hook_guard --good-has "$ASKRE" --bad-lacks "$ASKRE" --bad-lacks "$CRASH"
mk guard-allow 's#--arg d ask#--arg d allow#' 's#"permissionDecision":"ask"#"permissionDecision":"allow"#' &&
  tt guard-allow hook_guard --good-has "$ASKRE" --good-lacks '"permissionDecision":"allow"' --bad-has '"permissionDecision":"allow"' --bad-lacks "$ASKRE" --bad-lacks "$CRASH"
mk guard-deny 's#--arg d ask#--arg d deny#' 's#"permissionDecision":"ask"#"permissionDecision":"deny"#' &&
  tt guard-deny hook_guard --good-has "$ASKRE" --good-lacks '"permissionDecision":"deny"' --bad-has '"permissionDecision":"deny"' --bad-lacks "$ASKRE" --bad-lacks "$CRASH"
mk guard-lib-missing-allows '/SENTINEL-GUARD-FAIL-CLOSED/s#>&2; printf .*; exit 0; }#>\&2; exit 0; }#' &&
  tt guard-lib-missing-allows tpl --good-has '^NOLIB-ASK-hook-guard=yes$' --bad-has '^NOLIB-ASK-hook-guard=no$' --bad-lacks "$CRASH"
mk guard-lib-missing-allow-json '/SENTINEL-GUARD-FAIL-CLOSED/s#"permissionDecision":"ask"#"permissionDecision":"allow"#' &&
  tt guard-lib-missing-allow-json tpl --good-has '^NOLIB-ASK-hook-guard=yes$' --bad-has '^NOLIB-ASK-hook-guard=no$' --bad-lacks "$CRASH"
mk guard-json-unescaped 's#"\$(_rsdd_exec_json_escape "\$1")"#"$1"#' &&
  tt guard-json-unescaped hook_guard --good-has '/no/\\"q\\"\\\\b\\ttab\\u0001ctl"\}\}$' --bad-lacks '/no/\\"q\\"\\\\b\\ttab\\u0001ctl"\}\}$' --bad-lacks "$CRASH"
# documented templates (the header IS the test input: a drifted template must fail a case)
mk tpl-cli-exit0 '/SENTINEL-RSDD-EXEC-GUARD/s#exit 2; }#exit 0; }#' &&
  tt tpl-cli-exit0 tpl --good-has '^NOLIB-RC-cli=2$' --bad-has '^NOLIB-RC-cli=0$' --bad-lacks "$CRASH"
mk tpl-sweep-exit2 '/SENTINEL-HOOK-EMIT-GUARD/s#exit 0; }#exit 2; }#' &&
  tt tpl-sweep-exit2 tpl --good-has '^NOLIB-RC-hook-sweep=0$' --bad-has '^NOLIB-RC-hook-sweep=2$' --bad-lacks "$CRASH"
mk tpl-dirname '/^#       _RSDD_SELF=/s#_RSDD_SELF=.*; unset#_RSDD_SELF="$(dirname "$0")"; unset#' &&
  tt tpl-dirname tpl --good-has '^CHAIN-OK-cli=yes$' --bad-has '^CHAIN-OK-cli=no$' --bad-lacks "$CRASH"
# bin dir, scan failure, kit root
if [ "$(id -u)" != 0 ]; then
  mk bin-ro-build-failed 's#\(mktemp "\$kit/bin/.rsdd.XXXXXX" 2>/dev/null)" || return \)3#\11#' &&
    tt bin-ro-build-failed bin_ro --good-has 'bin dir not writable: ' --bad-has 'degraded: rsdd-unavailable — build failed' --bad-lacks "$CRASH"
  mk bin-ro-raw-error 's#mktemp "\$kit/bin/.rsdd.XXXXXX" 2>/dev/null#mktemp "$kit/bin/.rsdd.XXXXXX"#' &&
    tt bin-ro-raw-error bin_ro --good-lacks 'mktemp: ' --bad-has 'mktemp: ' --bad-lacks "$CRASH"
else
  skip "teeth bin-ro" "running as root (typed SKIP)"
fi
mk kit-root-unchecked 's#if \[ -z "\$kit" \]; then _RSDD_EXEC_WHY="cannot resolve the kit root"; return 2; fi#:#' &&
  tt kit-root-unchecked nocd --good-has 'cannot resolve the kit root' --bad-lacks 'cannot resolve the kit root' --bad-lacks "$CRASH"
# race: no atomic rename is covered above (handshake scenario)

# --- review batch for #2384: testdata files, hash disagreement, bounded lock wait, shasum, symlinks
mk fixture-symlink 's#find \. -type f#find -L . -type f#' && tt fixture-symlink fixture "${FXG[@]}"
mk testdata-file-kept "s# ! -name testdata##" &&
  tt testdata-file-kept testdata_file --good-has '^GOCALLS=0$' --bad-lacks '^GOCALLS=0$' --bad-lacks "$CRASH"
mk disagree-loops 's#if \[ "\$crc" -eq 1 \] \&\& _rsdd_exec_disagree_known "\$kit"; then exit 11; fi#:#' &&
  tt disagree-loops disagree --good-has '^GOCALLS=2$' --bad-lacks '^GOCALLS=2$' --bad-lacks "$CRASH"
mk noflock-skips-marker 's#      locked=0#      _rsdd_exec_build "$kit"; return#' &&
  tt noflock-skips-marker disagree_noflock --good-lacks '^GOCALLS=3$' --bad-has '^GOCALLS=3$' --bad-lacks "$CRASH"
mk disagree-unkeyed 's#\[ "\$marker" = "\$_RSDD_EXEC_GOT \$_RSDD_EXEC_TREE" \]#true#' &&
  tt disagree-unkeyed disagree --good-has '^GOCALLS=2$' --bad-lacks '^GOCALLS=2$' --bad-lacks "$CRASH"
mk disagree-silent 's#if \[ "\$brc" -eq 11 \]; then brc=0; echo [^;]*; fi#if [ "$brc" -eq 11 ]; then brc=0; fi#' &&
  tt disagree-silent disagree --good-has 'shell and go source hashes disagree' --bad-lacks 'shell and go source hashes disagree' --bad-lacks "$CRASH"
mk disagree-unrecorded 's#>"\$kit/bin/.rsdd-disagree" 2>/dev/null#>/dev/null 2>\&1#' &&
  tt disagree-unrecorded disagree --good-has '^GOCALLS=2$' --bad-lacks '^GOCALLS=2$' --bad-lacks "$CRASH"
mk lock-forever 's#flock -w "\$_RSDD_EXEC_LOCKWAIT" "\$lfd" || exit 12#flock -x "$lfd" || exit 12#' &&
  tt lock-forever lockbusy --good-has 'rebuild lock busy for 1s' --bad-lacks 'rebuild lock busy for 1s' --bad-lacks "$CRASH"
mk lock-busy-unmapped 's#12) why="rebuild lock busy"; note="rebuild lock busy for \${_RSDD_EXEC_LOCKWAIT}s" ;;#12) why="build failed"; note="rebuild failed" ;;#' &&
  tt lock-busy-unmapped lockbusy --good-has 'degraded: rsdd-unavailable — rebuild lock busy$' --bad-lacks 'degraded: rsdd-unavailable — rebuild lock busy$' --bad-lacks "$CRASH"
mk lockwait-env-ignored 's#_RSDD_EXEC_LOCKWAIT="\$RSDD_EXEC_LOCK_WAIT"#_RSDD_EXEC_LOCKWAIT=120#' &&
  tt lockwait-env-ignored lockwait_arg --good-has '^VALUE1=\[7\] ARGS=-w 7 ' --bad-lacks '^VALUE1=\[7\] ARGS=-w 7 ' --bad-lacks "$CRASH"
mk lockwait-zero-accepted 's#\^\[1-9\]\[0-9\]{0,8}\$#^[0-9]+$#' &&
  tt lockwait-zero-accepted lockwait_arg --good-has '^VALUE3=\[0\] ARGS=-w 120 ' --bad-lacks '^VALUE3=\[0\] ARGS=-w 120 ' --bad-lacks "$CRASH"
mk lockwait-notice-silent 's#else echo "rsdd-exec: notice: RSDD_EXEC_LOCK_WAIT must be[^"]*" >\&2; fi#else :; fi#' &&
  tt lockwait-notice-silent lockwait_arg --good-has 'RSDD_EXEC_LOCK_WAIT must be a positive integer' --bad-lacks 'RSDD_EXEC_LOCK_WAIT must be a positive integer' --bad-lacks "$CRASH"
mk lockwait-default 's#_RSDD_EXEC_LOCKWAIT=120$#_RSDD_EXEC_LOCKWAIT=5#' &&
  tt lockwait-default lockwait_arg --good-has '^DEFARGS=-w 120 ' --bad-lacks '^DEFARGS=-w 120 ' --bad-lacks "$CRASH"
if [ -n "$(type -P shasum)" ]; then
  SHG=(--good-has '^FIXTURE=OK$' --bad-lacks '^FIXTURE=OK$' --bad-lacks "$CRASH")
  mk shasum-offset 's#line:66#line:65#' && tt shasum-offset fixture_shasum "${SHG[@]}"
  mk shasum-algo 's#shasum -a 256 -b#shasum -a 1 -b#' && tt shasum-algo fixture_shasum "${SHG[@]}"
  mk shasum-missing 's#elif command -v shasum >/dev/null 2>&1; then sha=(shasum -a 256 -b)#elif false; then sha=(shasum)#' && tt shasum-missing fixture_shasum "${SHG[@]}"
else
  skip "teeth shasum-*" "shasum not installed (typed SKIP)"
fi

echo ""
total=$((pass+fail))
if [ "$fail" -gt 0 ]; then
  printf 'RESULT (with teeth): %d passed / %d FAILED\n' "$pass" "$fail"
  printf '== %d passed · %d failed ==\n' "$pass" "$fail"; exit 1
else
  printf 'RESULT (with teeth): %d passed / 0 failed\n' "$pass"
  printf '== %d passed · 0 failed ==\n' "$pass"; exit 0
fi
