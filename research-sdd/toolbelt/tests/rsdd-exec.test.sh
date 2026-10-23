#!/usr/bin/env bash
# rsdd-exec.test.sh — suite for lib/rsdd-exec.sh, the compatibility-shim helper of the Go port (kit issue #2275).
#
# Hermetic: every case builds a temp kit layout (<tmp>/<case>/k it/{toolbelt/lib,rsdd,bin}) holding a COPY of
# the library, a FAKE `rsdd` binary (echoes its argv as `%q` lines, stdin and a chosen exit code) and a FAKE
# `go` (writes a binary to the -o path, fails, or is slow). Nothing touches the real research-sdd/ tree and Go
# itself is never needed. The kit path contains a space on purpose.
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
  for t in bash env mktemp mv rm find mkdir dirname cat sleep touch chmod ls readlink; do
    p="$(type -P "$t")" || { echo "FATAL: tool $t missing" >&2; exit 2; }
    ln -s "$p" "$FARM/$t"
  done
  p="$(type -P jq)" && ln -s "$p" "$JQD/jq"
  cat >"$SCRATCH/body" <<'EOF'
#!/usr/bin/env bash
echo "FAKE-@TAG@"
printf 'n=%s\n' "$#"
for a in "$@"; do printf 'arg=%q\n' "$a"; done
if [ -n "${FAKE_READ_STDIN:-}" ]; then printf 'stdin=%q\n' "$(cat)"; fi
exit "${FAKE_RC:-0}"
EOF
  cat >"$GOBIN/go" <<'EOF'
#!/usr/bin/env bash
if [ "$#" -ne 4 ] || [ "$1" != build ] || [ "$2" != -o ] || [ "$4" != ./cmd/rsdd ]; then echo "fake go: unexpected args: $*" >&2; exit 64; fi
out="$3"
printf '%s\n' "$PWD" >> "$FAKE_GO_LOG"
echo "BUILDNOISE-STDOUT"
echo "BUILDNOISE-STDERR" >&2
body="$(<"$FAKE_BODY")"; body="${body//@TAG@/"${FAKE_GO_TAG:-NEW}"}"
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
  cp "$HERE/../lib/hook-emit.sh" "$KIT/toolbelt/lib/hook-emit.sh"
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
  : >"$SCRATCH/go.log"
}

putbin() {   # TAG [DATE] — fake rsdd at KIT/bin/rsdd; DATE absent = now
  mkdir -p "$KIT/bin"
  local body; body="$(<"$SCRATCH/body")"; printf '%s\n' "${body//@TAG@/"$1"}" >"$KIT/bin/rsdd"
  chmod 755 "$KIT/bin/rsdd"
  if [ -n "${2:-}" ]; then touch -d "$2" "$KIT/bin/rsdd"; fi
}

# dorun LABEL SCRIPT PM args... — PM go|nogo. Env knobs: GOMODE GOTAG GOSLEEP FAKE_RC READ_STDIN STDIN_FILE USE_RSDD_BIN
dorun() {
  local label="$1" script="$2" pm="$3" p; shift 3
  case "$pm" in go) p="$GOBIN:$FARM" ;; gojq) p="$GOBIN:$FARM:$JQD" ;; nogojq) p="$FARM:$JQD" ;; *) p="$FARM" ;; esac
  local sp="$KIT/toolbelt/$script"; case "$script" in /*) sp="$script" ;; esac
  local -a ev=(PATH="$p" FAKE_GO_LOG="$SCRATCH/go.log" FAKE_GO_MODE="${GOMODE:-ok}" FAKE_GO_TAG="${GOTAG:-NEW}" FAKE_BODY="$SCRATCH/body"
    FAKE_RC="${FAKE_RC:-0}" FAKE_READ_STDIN="${READ_STDIN:-}" FAKE_GO_READY="${READY_FILE:-}" FAKE_GO_RELEASE="${RELEASE_FILE:-}")
  if [ -n "${USE_RSDD_BIN+x}" ]; then ev+=(RSDD_BIN="$USE_RSDD_BIN"); fi
  env -u RSDD_BIN "${ev[@]}" "$BASH_BIN" "$sp" "$@" <"${STDIN_FILE:-/dev/null}" >"$SCRATCH/$label.out" 2>"$SCRATCH/$label.err"
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
probes() {   # build-side probes: how often fake go ran, where, what is left in bin/
  printf 'GOCALLS=%s\n' "$(grep -c . "$SCRATCH/go.log")"
  printf 'GOCWD=%s\n' "$(head -n 1 "$SCRATCH/go.log" 2>/dev/null)"
  printf 'KIT=%s\n' "$KIT"
  printf 'TMPLEFT=%s\n' "$(find "$KIT/bin" -maxdepth 1 -name '.rsdd.*' 2>/dev/null | grep -c .)"
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
sc_stale() {   # VARIANT: gomod | gosum | deepgo | maingo
  local v="${1:-gomod}" f
  mkkit "stale-$v"; putbin OLD '2021-01-01 00:00:00'
  case "$v" in
    gomod) f="$KIT/rsdd/go.mod" ;; gosum) f="$KIT/rsdd/go.sum" ;;
    deepgo) f="$KIT/rsdd/internal/deep/deep.go" ;; *) f="$KIT/rsdd/cmd/rsdd/main.go" ;;
  esac
  touch -d '2022-01-01 00:00:00' "$f"
  doshow stale shim.sh go x
  probes
}
sc_stale_strict() {
  mkkit stalestrict; putbin OLD '2021-01-01 00:00:00'; touch -d '2022-01-01 00:00:00' "$KIT/rsdd/go.mod"
  doshow strict strict.sh go x
  probes
  doshow lenient direct.sh go verify block y
}
sc_equal() {   # a source with the SAME mtime as the binary is not newer
  mkkit equal; putbin OLD '2021-01-01 00:00:00'; touch -d '2021-01-01 00:00:00' "$KIT/rsdd/go.mod"
  doshow equal shim.sh go
  probes
}
sc_missing() {
  mkkit missing
  doshow build shim.sh go z
  probes
  printf 'BINMODE=%s\n' "$([ -x "$KIT/bin/rsdd" ] && echo exec || echo noexec)"
}
sc_buildfail_old() {
  mkkit bfo; putbin OLD '2021-01-01 00:00:00'; touch -d '2022-01-01 00:00:00' "$KIT/rsdd/go.mod"
  GOMODE=fail doshow bf shim.sh go
  probes
}
sc_buildfail_none() {
  mkkit bfn
  GOMODE=fail doshow bf shim.sh go
  probes
}
sc_nogo_old() {
  mkkit ngo; putbin OLD '2021-01-01 00:00:00'; touch -d '2022-01-01 00:00:00' "$KIT/rsdd/go.mod"
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
  mkkit binonly; putbin SOLO '2021-01-01 00:00:00'; rm -rf "$KIT/rsdd"
  doshow solo shim.sh nogo
  probes
}
sc_rsddbin() {
  mkkit rb; putbin KITBIN '2021-01-01 00:00:00'; touch -d '2022-01-01 00:00:00' "$KIT/rsdd/go.mod"
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
wait_until() {   # FN — poll FN up to ~5 s; rc 1 = typed timeout
  local i
  for ((i = 0; i < 100; i++)); do "$1" && return 0; sleep 0.05; done
  return 1
}
_ready() { [ -e "$SCRATCH/ready" ]; }
_b_settled() { [ -e "$SCRATCH/B.rc" ] || [ "$(grep -c . "$SCRATCH/go.log")" -ge 2 ]; }
sc_race() {
  mkkit race
  ( GOMODE=slow READY_FILE="$SCRATCH/ready" RELEASE_FILE="$SCRATCH/release" dorun A shim.sh go ra ) &
  if ! wait_until _ready; then echo "HANDSHAKE-TIMEOUT=A-never-signalled-ready"; : >"$SCRATCH/release"; wait; return; fi
  ( GOMODE=slow READY_FILE="$SCRATCH/ready" RELEASE_FILE="$SCRATCH/release" dorun B shim.sh go rb ) &
  # B either finished (it ran the half-written file) or reached its own go build: only then release A.
  wait_until _b_settled || echo "HANDSHAKE-TIMEOUT=B-never-settled"
  : >"$SCRATCH/release"
  wait
  show A; show B
  printf 'B-COMPLETE=%s\n' "$(grep -qx 'FAKE-NEW' "$SCRATCH/B.out" && echo yes || echo no)"
  probes
  local final=""
  if [ -x "$KIT/bin/rsdd" ]; then final="$("$KIT/bin/rsdd" 2>&1 | head -n 1)"; fi
  printf 'FINAL=%s\n' "$final"
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
  mkkit ro2; putbin OLD '2021-01-01 00:00:00'; touch -d '2022-01-01 00:00:00' "$KIT/rsdd/go.mod"; chmod a-w "$KIT/bin"
  doshow stale shim.sh go
  probes
  chmod u+w "$KIT/bin"
  mkkit ro3; chmod a-w "$KIT"
  doshow nobindir shim.sh go
  chmod u+w "$KIT"
}
sc_scan_fail() {   # an unreadable subdirectory under rsdd/: the scan fails, a failed scan counts as stale
  if [ "$(id -u)" = 0 ]; then echo "SKIP-ROOT=1"; return; fi
  mkkit sf; putbin FRESH
  chmod 000 "$KIT/rsdd/internal/deep"
  doshow scan shim.sh go x
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

# 3. staleness (every trigger file, mtime via touch -d) and its boundary
for v in gomod gosum deepgo maingo; do
  R="$(scen "stale-$v" "$LIB")"
  chk "stale ($v newer than binary) -> rebuilt, new binary runs" "$R" stale '^o\| FAKE-NEW$'
  pchk "stale ($v) -> exactly one go build" "$R" '^GOCALLS=1$'
  pchk "stale ($v) -> go ran inside <kit>/rsdd" "$R" '^GOCWD=.*/k it/rsdd$'
  pchk "stale ($v) -> no temp file left in bin/" "$R" '^TMPLEFT=0$'
done
R="$(scen equal "$LIB")"
chk "source with the same mtime as the binary is fresh" "$R" equal '^o\| FAKE-OLD$'
pchk "same-mtime source -> no build" "$R" '^GOCALLS=0$'

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

# 10. concurrent rebuild safety (deterministic handshake: A signals ready, B starts, A is released afterwards)
R="$(scen race "$LIB")"
if grep -q '^HANDSHAKE-TIMEOUT=' <<<"$R"; then no "race: handshake completed" "$(grep '^HANDSHAKE-TIMEOUT=' <<<"$R")"; else ok "race: handshake completed (no typed timeout)"; fi
for l in A B; do
  chk "race: shim $l execs a COMPLETE binary" "$R" "$l" '^o\| FAKE-NEW$'
  chk "race: shim $l exit 0" "$R" "$l" '^RC=0$'
done
pchk "race: shim B ran a complete binary (B-COMPLETE)" "$R" '^B-COMPLETE=yes$'
pchk "race: no temp file left behind" "$R" '^TMPLEFT=0$'
pchk "race: the final binary on disk runs and prints the full marker" "$R" '^FINAL=FAKE-NEW$'

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
fi
R="$(scen scan_fail "$LIB")"
if grep -q '^SKIP-ROOT=1$' <<<"$R"; then
  skip "failed staleness scan counts as stale" "running as root (typed SKIP: root can read every directory)"
else
  chk "unreadable subdir under rsdd/: the failed scan counts as stale -> rebuilt" "$R" scan '^o\| FAKE-NEW$'
  pchk "unreadable subdir under rsdd/: exactly one build ran" "$R" '^GOCALLS=1$'
fi
R="$(scen nocd "$LIB")"
chk "kit root unresolvable (cd fails at source time) -> rc 2" "$R" nocd '^RC=2$'
chk "kit root unresolvable -> degraded line" "$R" nocd '^e\| degraded: rsdd-unavailable — cannot resolve the kit root$'
nchk "kit root unresolvable -> nothing on stdout" "$R" nocd '^o\| '

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

mk skip-stale 's#\[ "\$rc" -ne 0 \] || \[ -n "\$hit" \]#false#' &&
  tt skip-stale stale-gomod --good-has '^o\| FAKE-NEW$' --bad-has '^o\| FAKE-OLD$' --bad-lacks "$CRASH"
mk stale-no-gomod 's# -o -name go.mod -o -name go.sum##' &&
  tt stale-no-gomod stale-gomod --good-has '^o\| FAKE-NEW$' --bad-has '^o\| FAKE-OLD$' --bad-lacks "$CRASH"
mk stale-inverted 's#-newer "\$1"#! -newer "$1"#' &&
  tt stale-inverted equal --good-has '^o\| FAKE-OLD$' --bad-has '^o\| FAKE-NEW$' --bad-lacks "$CRASH"
mk no-atomic-rename 's#go build -o "\$tmp" ./cmd/rsdd \&\& chmod 755 "\$tmp" \&\& mv -f "\$tmp" "\$bin"#go build -o "$bin" ./cmd/rsdd \&\& chmod 755 "$bin"#' &&
  tt no-atomic-rename race --good-has '^B-COMPLETE=yes$' --bad-has '^B-COMPLETE=no$' --bad-lacks '^HANDSHAKE-TIMEOUT' --bad-lacks "$CRASH"
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
  mk scan-failure-not-stale 's#\[ "\$rc" -ne 0 \] || ##' &&
    tt scan-failure-not-stale scan_fail --good-has '^o\| FAKE-NEW$' --bad-has '^o\| FAKE-FRESH$' --bad-lacks "$CRASH"
else
  skip "teeth bin-ro / scan-failure" "running as root (typed SKIP)"
fi
mk kit-root-unchecked 's#if \[ -z "\$kit" \]; then _RSDD_EXEC_WHY="cannot resolve the kit root"; return 2; fi#:#' &&
  tt kit-root-unchecked nocd --good-has 'cannot resolve the kit root' --bad-lacks 'cannot resolve the kit root' --bad-lacks "$CRASH"
# race: no atomic rename is covered above (handshake scenario)

echo ""
total=$((pass+fail))
if [ "$fail" -gt 0 ]; then
  printf 'RESULT (with teeth): %d passed / %d FAILED\n' "$pass" "$fail"
  printf '== %d passed · %d failed ==\n' "$pass" "$fail"; exit 1
else
  printf 'RESULT (with teeth): %d passed / 0 failed\n' "$pass"
  printf '== %d passed · 0 failed ==\n' "$pass"; exit 0
fi
