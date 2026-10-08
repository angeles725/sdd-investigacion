#!/usr/bin/env bash
# mutant.sh — sourceable helper for mutation controls ("teeth"), kit issue #943.
#
# Root class: a tooth reports ok when the mutated run merely DIFFERS from the good run, so a
# mutant that never applied, was empty, crashed on a syntax error, or was written into the live
# tree all "bite" for the wrong reason. This helper builds a mutant as a COPY of the real SUT in a
# temp dir and REFUSES to hand back one that cannot be a real mutation. A mutant refused for being
# empty, identical, not valid bash, or for a failed sed is removed, so a caller that ignores the
# return code finds nothing to run. A placement/symlink refusal (8, 9) never deletes anything: the
# path is not known to be the helper's own file.
#
#   mutant_sed    ORIG OUT SED_ARGS...   placement checks, then sed SED_ARGS... ORIG > OUT, then
#                                        the content checks of mutant_verify
#   mutant_verify ORIG OUT               the SAME checks (placement, symlink, content) for a
#                                        mutant built some other way (awk, a heredoc, a copy)
#   mutant_chain  LABEL ORIG OUT EXPR...   one sed stage (-e EXPR) per EXPR, each of which must change
#                                        ORIG ON ITS OWN (a dead stage hides behind a live one
#                                        otherwise), then mutant_sed's checks. Stages run in ONE pass,
#                                        so a stage cannot depend on text an earlier stage introduces:
#                                        make such a mutation a single s///, or build it another way
#                                        and check it with mutant_built. Multi-line EXPRs (c\ / a\) work.
#   mutant_built  LABEL ORIG OUT           mutant_verify for a mutant built another way (awk, python3,
#                                        bash surgery), with the failure reported in suite format
#   mutant_py_replace LABEL ORIG OLD NEW OUT
#                                        the shared builder for a Python-SUT mutant: replace the FIRST
#                                        literal OLD in ORIG with NEW (multi-line OK), write OUT, then
#                                        mutant_built's checks under MUTANT_SYNTAX=none plus a python3
#                                        compile() of OUT. Placement is checked BEFORE the write, so a
#                                        symlink / live-tree OUT is never written through. rc 0 ok ·
#                                        rc 2 setup failure (ORIG unreadable, empty OLD, OLD absent from
#                                        ORIG) · rc 3 refused (OLD == NEW, placement or content refusal,
#                                        python3 missing, not valid Python); a refused OUT is removed
#                                        and the reason goes to STDERR, not stdout (unlike mutant_chain).
#   mutant_or_count COUNTER CMD [ARGS...]
#                                        runs CMD and, when it returns non-zero, adds exactly ONE to the
#                                        caller's variable COUNTER (any scope the caller can see; an
#                                        unset COUNTER starts at 0), then returns CMD's rc unchanged. A
#                                        COUNTER that is not an identifier, starts with the helper's
#                                        reserved `_moc_` prefix, or is not a number is a loud
#                                        `  FAIL  mutant_or_count: ...` and rc 2 without running CMD.
#   mutant_chain_or_count COUNTER LABEL ORIG OUT EXPR...   mutant_or_count COUNTER mutant_chain ...
#   mutant_built_or_count COUNTER LABEL ORIG OUT           mutant_or_count COUNTER mutant_built ...
#                                        the count-once contract in one place: a call site cannot
#                                        forget, or double, the `else fail=$((fail+1))` branch.
#   mutant_cleanup_register PATH         register an ABSOLUTE path (not / ) for `rm -rf --` at shell
#                                        exit. One registry, one EXIT trap: the first call chains
#                                        whatever EXIT trap already exists (`_mutant_cleanup_run; <old>`)
#                                        and later calls only append, so a suite never installs (and
#                                        never replaces) a trap itself. A trap the suite re-installed
#                                        after a registration is re-chained on the next call. A refused
#                                        path (empty, relative, /) is rc 2 and never registered. The
#                                        chained trap restores the exiting status in $? before a pre-
#                                        existing trap runs, so that trap still sees the real status. A
#                                        caller's own trap must be installed BEFORE the first
#                                        registration or be followed by another registration.
#   mutant_tooth  LABEL GOOD_RC BAD_RC MUTANT [--orig P] [--good-has RE] [--good-lacks RE]
#                 [--bad-has RE] [--bad-lacks RE] -- ARGV...
#                                        runs ARGV on the original ('@SUT@' in any ARGV word is replaced
#                                        by P, default $SUT) and again on MUTANT; PASS only when the
#                                        original exits EXACTLY GOOD_RC (and its output matches
#                                        --good-has / not --good-lacks) AND the mutant exits EXACTLY
#                                        BAD_RC (and matches --bad-has / not --bad-lacks): a crashing
#                                        mutant (any other rc) is THEATER, not teeth. Patterns are grep
#                                        -E, case-sensitive unless MUTANT_TOOTH_ICASE is non-empty.
#                                        GOOD_RC == BAD_RC with neither --bad-has nor --bad-lacks is
#                                        REFUSED (FAIL, rc 1): such a tooth cannot tell mutant from original.
#
# Counting contract (chain / built / tooth): they NEVER touch the caller's counters. Each prints its
# own `  FAIL  <label>...` line to stdout on failure (mutant_tooth also `  PASS  <label> [...]`) and
# returns non-zero on failure; success of chain/built is silent and returns 0. The caller counts, e.g.
#   mk(){ mutant_chain "$@" || { fail=$((fail+1)); return 1; }; }
#   tt(){ if mutant_tooth "$@"; then pass=$((pass+1)); else fail=$((fail+1)); fi; }
#   mk L "$SUT" "$MUT/m.sh" 's/a/b/' && tt L 1 0 "$MUT/m.sh" -- bash @SUT@ "$dir"
# mutant_chain returns 10 for a dead stage (message names the stage number and EXPR); any other
# non-zero is the rc of mutant_sed / mutant_verify below. mutant_tooth returns 1 on every failure.
#
# Return codes (distinct, so a test can assert the SPECIFIC refusal, not "any failure"):
#   0 ok · 2 original absent/unreadable · 3 original or mutant empty · 4 mutant byte-identical to
#   the original (the mutation never applied) · 5 mutant is not valid bash (bash -n) · 6 sed failed
#   · 7 OUT is the same path as ORIG · 8 OUT is in the live tree (the tree ORIG lives in) or not
#   under the temp root (kit issue #1156: a mutant written beside the SUT lands in the live tree)
#   · 9 OUT is a symlink (a write would go THROUGH it to another file)
#
# "The live tree" is the git work tree containing ORIG (`git rev-parse --show-toplevel`), or ORIG's
# own physical directory when git is absent or ORIG is not in a work tree (git is run with
# GIT_DIR / GIT_WORK_TREE / GIT_COMMON_DIR removed). A git-ignored OUT is exempt from the live-tree
# test. Placement is TWO independent conditions: OUT must NOT be at or under the live tree, AND must be under the temp
# root. The second alone is not enough — a clone under /tmp, or a TMPDIR that is an ancestor of the
# kit, puts the live tree under the temp root.
#
# Environment:
#   MUTANT_SYNTAX=none   skip the `bash -n` check (mutants of non-bash files). Default: bash.
#   MUTANT_TMPROOT       the directory OUT must live under. Default: ${TMPDIR:-/tmp}.
#
#   MUTANT_TOOTH_DEBUG   when non-empty, mutant_tooth also prints diagnostic detail to STDERR: the
#                        label, original and mutant paths, ARGV, both exit codes and both outputs.
#                        Unset (default): nothing extra is printed; stdout is identical either way.
#
# FUNCTIONS ONLY — source it, never execute it. No `set` options here: a sourced `set` would
# mutate the calling suite's shell options.

# _mutant_debug <text...> — stderr diagnostic line; callers gate it on MUTANT_TOOTH_DEBUG.
_mutant_debug() { printf 'MUTANT_TOOTH_DEBUG: %s\n' "$*" >&2; }

_mutant_refuse() { printf 'mutant: REFUSED — %s\n' "$1" >&2; }

# _mutant_realdir <dir> — physical path of an existing directory; fails (no output) otherwise.
_mutant_realdir() { (cd -P -- "$1" 2>/dev/null && pwd -P); }

# _mutant_under <path> <root> — true when path equals root or lies below it (both physical).
_mutant_under() { [ "$1" = "$2" ] || [ "${1#"$2"/}" != "$1" ]; }

# _mutant_git <dir> <git-args...> — git in <dir> with the repository-selecting environment removed:
# an inherited GIT_DIR / GIT_WORK_TREE would otherwise redirect the lookup to a DIFFERENT repo and
# the "live tree" would silently be the wrong one.
_mutant_git() { local d="$1"; shift; env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR git -C "$d" "$@"; }

# _mutant_live_root <orig> — physical root of the tree ORIG lives in; fails (no output) when ORIG's
# directory cannot be resolved.
_mutant_live_root() {
  local odir top=""
  odir="$(_mutant_realdir "$(dirname -- "$1")")" || return 1
  [ -n "$odir" ] || return 1
  if command -v git >/dev/null 2>&1; then
    top="$(_mutant_git "$odir" rev-parse --show-toplevel 2>/dev/null)" || top=""
    [ -n "$top" ] && top="$(_mutant_realdir "$top")"
  fi
  printf '%s' "${top:-$odir}"
}

# _mutant_check_out <orig> <out> — symlink + placement. Returns 0, 8 or 9.
_mutant_check_out() {
  local orig="$1" out="$2" root real_out real_root live
  # SENTINEL-SYMLINK-CHECK
  if [ -L "$out" ]; then
    _mutant_refuse "OUT '$out' is a symlink — a write would go through it to another file"; return 9
  fi
  real_out="$(_mutant_realdir "$(dirname -- "$out")")"
  live="$(_mutant_live_root "$orig")"
  if [ -z "$real_out" ]; then
    _mutant_refuse "OUT directory '$(dirname -- "$out")' does not exist"; return 8
  fi
  # SENTINEL-LIVE-TREE-CHECK
  # A git-IGNORED OUT is exempt: it is not part of the tracked tree and cannot be committed, which is
  # what makes TMPDIR=<repo>/.tmp (ignored) usable. An un-ignored path in the same repo is refused.
  if [ -z "$live" ] || { _mutant_under "$real_out" "$live" \
       && ! _mutant_git "$live" check-ignore -q -- "$real_out/$(basename -- "$out")" 2>/dev/null; }; then
    _mutant_refuse "OUT '$out' is in the live tree (${live:-unresolved}) — a mutant must be built in a temp copy, never beside the SUT"; return 8
  fi
  root="${MUTANT_TMPROOT:-${TMPDIR:-/tmp}}"
  real_root="$(_mutant_realdir "$root")"
  # SENTINEL-TMPROOT-CHECK
  if [ -z "$real_root" ] || ! _mutant_under "$real_out" "$real_root"; then
    _mutant_refuse "OUT '$out' is not under the temp root '$root'"; return 8
  fi
  return 0
}

mutant_verify() {
  local orig="$1" out="$2" rc
  # SENTINEL-VERIFY-ORIG-CHECK
  if [ ! -f "$orig" ] || [ ! -r "$orig" ]; then
    _mutant_refuse "original '$orig' is not a readable file"; return 2
  fi
  if [ ! -s "$orig" ]; then
    _mutant_refuse "original is empty: '$orig'"; return 3
  fi
  # SENTINEL-SELF-CHECK
  if [ "$orig" -ef "$out" ]; then
    _mutant_refuse "OUT and ORIG are the same path ('$out'); never overwrite the SUT"; return 7
  fi
  _mutant_check_out "$orig" "$out"; rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  # SENTINEL-NOT-PRODUCED-CHECK
  if [ ! -f "$out" ]; then
    _mutant_refuse "mutant '$out' was not produced"; return 2
  fi
  # SENTINEL-EMPTY-CHECK
  if [ ! -s "$out" ]; then
    _mutant_refuse "mutant is empty: '$out'"; rm -f -- "$out"; return 3
  fi
  # SENTINEL-IDENTICAL-CHECK
  if cmp -s -- "$orig" "$out"; then
    _mutant_refuse "mutant is byte-identical to the original — the mutation never applied"; rm -f -- "$out"; return 4
  fi
  # SENTINEL-SYNTAX-CHECK
  if [ "${MUTANT_SYNTAX:-bash}" != none ]; then
    local synerr
    if ! synerr="$(bash -n "$out" 2>&1)"; then
      _mutant_refuse "mutant is not valid bash (bash -n): $synerr"; rm -f -- "$out"; return 5
    fi
  fi
  return 0
}

mutant_sed() {
  local orig="$1" out="$2" rc
  shift 2
  # SENTINEL-SED-ORIG-CHECK
  if [ ! -f "$orig" ] || [ ! -r "$orig" ]; then
    _mutant_refuse "original '$orig' is not a readable file"; return 2
  fi
  if [ ! -s "$orig" ]; then
    _mutant_refuse "original is empty: '$orig'"; return 3
  fi
  # SENTINEL-SELF-CHECK
  if [ "$orig" -ef "$out" ]; then
    _mutant_refuse "OUT and ORIG are the same path ('$out'); never overwrite the SUT"; return 7
  fi
  # Placement BEFORE anything is written (mutant_verify repeats it; this one guards the sed write).
  _mutant_check_out "$orig" "$out"; rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  # SENTINEL-SED-FAIL-CHECK
  if ! sed "$@" "$orig" > "$out"; then
    _mutant_refuse "sed failed building '$out'"; rm -f -- "$out"; return 6
  fi
  mutant_verify "$orig" "$out"
}

# mutant_chain LABEL ORIG OUT EXPR... — see header. Dead-stage check first, then mutant_sed.
mutant_chain() {
  local label="$1" orig="$2" out="$3" e rc err n=0
  shift 3
  local -a args=()
  if [ "$#" -eq 0 ]; then
    printf '  FAIL  %s: mutant_chain given no sed stage\n' "$label"; return 1
  fi
  for e in "$@"; do
    n=$((n + 1))
    # SENTINEL-CHAIN-DEAD-STAGE
    if sed -e "$e" "$orig" 2>/dev/null | cmp -s - "$orig"; then
      printf '  FAIL  %s: sed stage %d matches nothing in the original (silent no-op) :: [%s]\n' "$label" "$n" "$e"
      return 10
    fi
    args+=(-e "$e")
  done
  err="$(mutant_sed "$orig" "$out" "${args[@]}" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '  FAIL  %s: mutant refused by lib/mutant.sh (rc=%d) :: %s\n' "$label" "$rc" "$err"
  fi
  return "$rc"
}

# mutant_built LABEL ORIG OUT — see header.
mutant_built() {
  local label="$1" orig="$2" out="$3" rc err
  err="$(mutant_verify "$orig" "$out" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '  FAIL  %s: mutant refused by lib/mutant.sh (rc=%d) :: %s\n' "$label" "$rc" "$err"
  fi
  return "$rc"
}

# mutant_py_replace LABEL ORIG OLD NEW OUT — see header.
mutant_py_replace() {
  local label="$1" orig="$2" old="$3" new="$4" out="$5" c
  if [ ! -f "$orig" ] || [ ! -r "$orig" ]; then
    echo "MUTANT-SETUP-FAIL: $label: original '$orig' is not a readable file" >&2; return 2
  fi
  if [ -z "$old" ]; then
    echo "MUTANT-SETUP-FAIL: $label: empty anchor -- an empty OLD matches everywhere" >&2; return 2
  fi
  c="$(cat "$orig")"
  [[ "$c" == *"$old"* ]] || { echo "MUTANT-SETUP-FAIL: $label: anchor not found -- SUT changed?" >&2; return 2; }
  if [ "$old" = "$new" ]; then
    echo "mutant $label: OLD and NEW are identical -- the mutation cannot apply" >&2; return 3
  fi
  # Placement BEFORE the write: a symlink or live-tree OUT must never be written through.
  if [ "$orig" -ef "$out" ]; then
    _mutant_refuse "OUT and ORIG are the same path ('$out'); never overwrite the SUT"; return 3
  fi
  _mutant_check_out "$orig" "$out" || return 3
  printf '%s\n' "${c/"$old"/"$new"}" > "$out"
  # Defense in depth: the checks above already make an empty / identical / misplaced OUT impossible.
  MUTANT_SYNTAX=none mutant_built "$label" "$orig" "$out" >&2 || return 3
  if ! command -v python3 >/dev/null 2>&1; then
    echo "MUTANT-SETUP-FAIL: $label: degraded -- python3 not found, cannot syntax-check the mutant" >&2
    rm -f -- "$out"; return 3
  fi
  # SENTINEL-PY-COMPILE
  python3 -c 'import sys; compile(open(sys.argv[1]).read(), sys.argv[1], "exec")' "$out" 2>/dev/null \
    || { echo "mutant $label is not valid Python" >&2; rm -f -- "$out"; return 3; }
}

# mutant_or_count COUNTER CMD [ARGS...] — see header.
mutant_or_count() {
  # The helper's own locals carry a reserved _moc_ prefix: ${!_moc_name} must resolve the CALLER's
  # variable, so a counter named like a plain local (rc, c, counter) would otherwise be shadowed.
  local _moc_name="${1:-}" _moc_rc
  if [[ ! "$_moc_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || [[ "$_moc_name" == _moc_* ]] || [ "$#" -lt 2 ]; then
    printf '  FAIL  mutant_or_count: bad counter name or no command [%s]\n' "$_moc_name"; return 2
  fi
  if [[ ! "${!_moc_name:-0}" =~ ^[0-9]+$ ]]; then
    printf '  FAIL  mutant_or_count: counter %s is not a number [%s]\n' "$_moc_name" "${!_moc_name}"; return 2
  fi
  shift
  "$@"; _moc_rc=$?
  # SENTINEL-COUNT-ONCE
  if [ "$_moc_rc" -ne 0 ]; then printf -v "$_moc_name" '%d' $(( ${!_moc_name:-0} + 1 )); fi
  return "$_moc_rc"
}
mutant_chain_or_count() { mutant_or_count "${1:-}" mutant_chain "${@:2}"; }
mutant_built_or_count() { mutant_or_count "${1:-}" mutant_built "${@:2}"; }

# _MUTANT_CLEANUP_PATHS is the one registry; _mutant_cleanup_run is the one cleaner.
_MUTANT_CLEANUP_PATHS=()
_mutant_cleanup_run() {
  local p
  for p in "${_MUTANT_CLEANUP_PATHS[@]+"${_MUTANT_CLEANUP_PATHS[@]}"}"; do
    rm -rf -- "$p"
  done
}

# mutant_cleanup_register PATH — see header.
mutant_cleanup_register() {
  local p="${1:-}" prev cmd=""
  # An empty path is caught by the relative-path test (both sides of the comparison are empty).
  if [ "${p#/}" = "$p" ] || [ "$p" = / ]; then
    printf 'mutant_cleanup_register: REFUSED — path must be a non-empty absolute path other than / (got [%s])\n' "$p" >&2
    return 2
  fi
  _MUTANT_CLEANUP_PATHS+=("$p")
  # SENTINEL-CLEANUP-INSTALL
  prev="$(trap -p EXIT)"
  case "$prev" in
    *_mutant_cleanup_run*) ;;   # already chained (and still in place): nothing to install
    *)
      if [ -n "$prev" ]; then eval "set -- $prev"; cmd="$3"; fi   # trap -p prints: trap -- 'CMD' EXIT
      # shellcheck disable=SC2064,SC2154
      # The status the script is exiting with is captured first and restored before the chained trap
      # runs, so a trap that reads $? sees the real status, not the cleanup's.
      trap "__mrc=\$?; _mutant_cleanup_run; (exit \"\$__mrc\")${cmd:+; $cmd}" EXIT ;;
  esac
}

# mutant_tooth LABEL GOOD_RC BAD_RC MUTANT [opts] -- ARGV... — see header.
mutant_tooth() {
  local label="$1" grc="$2" brc="$3" mut="$4"
  local ghas="" glack="" bhas="" black="" orig="${SUT:-}" a gout mout grc_a mrc_a why="" gi="" rc
  shift 4
  [ -z "${MUTANT_TOOTH_ICASE:-}" ] || gi="-i"
  while [ "${1:-}" != -- ]; do
    # SENTINEL-TOOTH-MISUSE
    case "${1:-}" in
      --orig) orig="${2:-}" ;; --good-has) ghas="${2:-}" ;; --good-lacks) glack="${2:-}" ;;
      --bad-has) bhas="${2:-}" ;; --bad-lacks) black="${2:-}" ;;
      '') printf '  FAIL  %s: mutant_tooth missing the "--" before ARGV\n' "$label"; return 1 ;;
      *) printf '  FAIL  %s: mutant_tooth bad option [%s]\n' "$label" "${1:-}"; return 1 ;;
    esac
    [ "$#" -ge 2 ] || { printf '  FAIL  %s: mutant_tooth option [%s] needs a value\n' "$label" "$1"; return 1; }
    shift 2
  done
  shift
  if [ "$#" -eq 0 ]; then printf '  FAIL  %s: mutant_tooth has no ARGV after "--"\n' "$label"; return 1; fi
  if [ -z "$orig" ]; then printf '  FAIL  %s: mutant_tooth has no original (pass --orig or set $SUT)\n' "$label"; return 1; fi
  if [ ! -f "$mut" ]; then printf '  FAIL  %s: mutant file absent [%s] — the builder failed\n' "$label" "$mut"; return 1; fi
  # SENTINEL-TOOTH-NONDISCRIMINATING
  if [ "$grc" = "$brc" ] && [ -z "$bhas" ] && [ -z "$black" ]; then
    printf '  FAIL  %s: mutant_tooth cannot discriminate — GOOD_RC == BAD_RC (%s) and no --bad-has/--bad-lacks pattern supplied\n' "$label" "$grc"; return 1
  fi
  local -a gc=() mc=()
  for a in "$@"; do gc+=("${a//@SUT@/"$orig"}"); mc+=("${a//@SUT@/"$mut"}"); done
  gout="$("${gc[@]}" 2>&1)"; grc_a=$?
  mout="$("${mc[@]}" 2>&1)"; mrc_a=$?
  if [ -n "${MUTANT_TOOTH_DEBUG:-}" ]; then
    _mutant_debug "$label: original=$orig mutant=$mut argv=[$*]"
    _mutant_debug "$label: original rc=$grc_a (want $grc) output=[$gout]"
    _mutant_debug "$label: mutant rc=$mrc_a (want $brc) output=[$mout]"
  fi
  [ "$grc_a" = "$grc" ] || why="original rc=$grc_a (want $grc)"
  # SENTINEL-TOOTH-PATTERNS
  if [ -n "$ghas" ] && ! grep -qE $gi -- "$ghas" <<<"$gout"; then why="$why; original output lacks /$ghas/"; fi
  if [ -n "$glack" ] && grep -qE $gi -- "$glack" <<<"$gout"; then why="$why; original output matches /$glack/"; fi
  # SENTINEL-TOOTH-BADRC
  [ "$mrc_a" = "$brc" ] || why="$why; mutant rc=$mrc_a (want $brc)"
  if [ -n "$bhas" ] && ! grep -qE $gi -- "$bhas" <<<"$mout"; then why="$why; mutant output lacks /$bhas/"; fi
  if [ -n "$black" ] && grep -qE $gi -- "$black" <<<"$mout"; then why="$why; mutant output still matches /$black/"; fi
  if [ -z "$why" ]; then
    printf '  PASS  %s [original rc=%s → mutant rc=%s]\n' "$label" "$grc" "$brc"; rc=0
  else
    printf '  FAIL  %s — THEATER:%s\n' "$label" "${why#;}"; rc=1
  fi
  return "$rc"
}

# ── Shared VM-executor tooth kit (kit issue #1576) ───────────────────────────────────────────────
# detonate-exec.test.sh and trace-exec.test.sh prove the SHARED run_vm source (lib/vm_boot_core.py)
# with the same three real-SUT mutants and the same focused `--tooth` scenario runner; only the
# executor names differ. Both halves live here, parameterised by those names, so the two suites can
# no longer drift apart.
#
#   mutant_vm_tooth_py_src            prints the Python source of `_tooth_run(name, plan_flags, mod, cls)`.
#                                     The suite exports it as RSDD_TOOTH_PY and its embedded python
#                                     does `exec(os.environ["RSDD_TOOTH_PY"], globals())` (the scenario
#                                     body needs the suite's own cli / _shims / _elf / _GOOD_ARGV /
#                                     tempfile / json / Path / os, so it runs in the suite's globals).
#                                     plan_flags is a callable(elf_path) -> list of `plan` CLI flags.
#   mutant_vm_core_teeth EXEC HERE SELF SUT_EXEC MUT
#                                     the bash --prove-teeth section: stage a mini-tree, run the
#                                     unmutated staging control for the three scenarios, then build and
#                                     run the three mutants (run_dir identity reuse, BaseException path
#                                     no longer reaps run_dir, a second orphaned run_dir). EXEC is the
#                                     executor stem (`detonate` | `trace`: lib/<EXEC>_exec.py,
#                                     <EXEC>_plan.py), HERE the suite's tests dir, SELF the suite
#                                     script (re-invoked as `bash SELF --tooth <scenario> <exec.py>`),
#                                     SUT_EXEC the original lib/<EXEC>_exec.py, MUT a temp root. It
#                                     prints its own PASS/FAIL lines and reports through the globals
#                                     MVC_PASS / MVC_FAIL (the caller adds them to its own counters).
mutant_vm_tooth_py_src() {
  cat <<'PY'
def _tooth_run(name, plan_flags, mod, cls):
    import glob as _g, shutil as _sh, uuid as _u, importlib as _il
    import docker_common as _dc_t; from gate import GateError as _GE_t
    _ex_t = _il.import_module(mod)
    made = []
    def _cleanup():
        for _d in made: _sh.rmtree(_d, ignore_errors=True)
    if name == "red11":
        # RED11 body run twice with TOOTH_UUID set: a SUT that reuses a run_dir identity
        # hands back a dir that the second run already finds in its before-set.
        _uid = _u.uuid4().hex; verdict = "fresh"
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td); p = _shims(tmp); elf = _elf(tmp)
            for _i in (1, 2):
                before = set(_g.glob("/tmp/rsdd/rsdd-*"))
                r = cli("plan", *plan_flags(elf), "--output", str(tmp / f"out{_i}"), "--allow-exec",
                        xe={"PATH": p, "RSDD_EXEC_EXECUTOR": "", "TOOTH_UUID": _uid})
                try: sl = json.loads(r.stdout).get("serial_log", "")
                except Exception: sl = ""
                if r.returncode != 0 or not sl:
                    _cleanup(); print(f"TOOTH_RED11=error:rc={r.returncode}"); return
                rd = str(Path(sl).parent); made.append(rd)
                if rd in before or not Path(rd).exists(): verdict = "preexisting"
        _cleanup(); print(f"TOOTH_RED11={verdict}"); return
    if name in ("inv5", "alloc"):
        # INV5-earlyfail body: pre_boot GateError (sentinel absent) after the run_dir allocation.
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td); p = _shims(tmp)
            _plan = {"qemu_binary": "qemu-system-x86_64", "planned_argv": list(_GOOD_ARGV)}
            _old = os.environ.get("PATH", ""); os.environ["PATH"] = p
            _orig = _dc_t.make_run_subdir
            def _track(run_uuid, root=_dc_t._DEFAULT_RSDD_ROOT):
                rd = _orig(run_uuid, root); made.append(rd); return rd
            _dc_t.make_run_subdir = _track
            try:
                raised = None
                try: getattr(_ex_t, cls)(tmp / "out").evaluate(_plan)
                except Exception as e: raised = e
            finally:
                os.environ["PATH"] = _old; _dc_t.make_run_subdir = _orig
        if not (isinstance(raised, _GE_t) and "not found in planned_argv" in str(raised)):
            _cleanup(); print(f"TOOTH_{name.upper()}=error:{type(raised).__name__}"); return
        if name == "alloc":
            n = len(made); _cleanup(); print(f"TOOTH_ALLOC={n}"); return
        leaked = [d for d in made if Path(d).exists()]
        _cleanup(); print("TOOTH_INV5=" + ("leaked" if leaked else "reaped")); return
    print(f"TOOTH_ERROR=unknown scenario {name}")
PY
}

mutant_vm_core_teeth() {
  local ex="$1" here="$2" self="$3" sut_exec="$4" mut="$5"
  local crash='Traceback|ImportError|ModuleNotFoundError|SyntaxError'
  local core="$here/../lib/vm_boot_core.py" s o rc k
  MVC_PASS=0; MVC_FAIL=0
  # stage NAME: copy lib/*.py and the top-level modules into $mut/NAME/
  _mvc_stage() {
    mkdir -p "$mut/$1/lib" && cp "$here/../lib/"*.py "$mut/$1/lib/" && cp "$here/../"*.py "$mut/$1/" \
      && [ -f "$mut/$1/lib/${ex}_exec.py" ] && [ -f "$mut/$1/${ex}_plan.py" ] && [ -f "$mut/$1/lib/vm_boot_core.py" ]
  }
  # build LABEL NAME SED-EXPR: stage, mutate vm_boot_core.py (a dead anchor makes mutant_chain refuse),
  # then compile() it. A failure is counted ONCE here; the caller then skips the tooth.
  _mvc_build() {
    if ! _mvc_stage "$2"; then echo "  FAIL  $1: staging the mini-tree failed"; MVC_FAIL=$((MVC_FAIL+1)); return 1; fi
    if ! MUTANT_SYNTAX=none mutant_chain "$1" "$core" "$mut/$2/lib/vm_boot_core.py" "$3"; then MVC_FAIL=$((MVC_FAIL+1)); return 1; fi
    if ! python3 -c 'import sys; compile(open(sys.argv[1]).read(), sys.argv[1], "exec")' "$mut/$2/lib/vm_boot_core.py"; then
      echo "  FAIL  $1: mutant does not compile"; MVC_FAIL=$((MVC_FAIL+1)); return 1
    fi
  }
  _mvc_tt() { if mutant_tooth "$@"; then MVC_PASS=$((MVC_PASS+1)); else MVC_FAIL=$((MVC_FAIL+1)); fi; }
  # Staging control: the UNMUTATED staged tree must give the good verdicts on every scenario, else a
  # staging gap (missing import) would make each mutant "bite" by crashing.
  if _mvc_stage clean; then
    for s in red11:fresh inv5:reaped alloc:1; do
      o="$(bash "$self" --tooth "${s%%:*}" "$mut/clean/lib/${ex}_exec.py" 2>&1)"; rc=$?
      k="$(tr '[:lower:]' '[:upper:]' <<<"${s%%:*}")"
      if [ "$rc" -eq 0 ] && grep -qE "^TOOTH_${k}=${s##*:}\$" <<<"$o" && ! grep -qE "$crash" <<<"$o"; then
        echo "  PASS  teeth-staging-control-${s%%:*}: unmutated staged tree gives TOOTH_${k}=${s##*:}"; MVC_PASS=$((MVC_PASS+1))
      else
        echo "  FAIL  teeth-staging-control-${s%%:*}: rc=$rc output=[$o]"; MVC_FAIL=$((MVC_FAIL+1))
      fi
    done
  else
    echo "  FAIL  teeth-staging-control: staging the clean mini-tree failed"; MVC_FAIL=$((MVC_FAIL+1))
  fi
  # mutant 1 — run_dir identity: run_vm hands out a caller-chosen (reusable) run_dir identity.
  if _mvc_build teeth-mut-red11 red11 's|^    run_dir = _dc.make_run_subdir(uuid.uuid4().hex)$|    run_dir = _dc.make_run_subdir(__import__("os").environ.get("TOOTH_UUID") or uuid.uuid4().hex)|'; then
    _mvc_tt teeth-mut-red11 0 0 "$mut/red11/lib/${ex}_exec.py" --orig "$sut_exec" \
      --good-has '^TOOTH_RED11=fresh$' --good-lacks "$crash" \
      --bad-has '^TOOTH_RED11=preexisting$' --bad-lacks "$crash" -- bash "$self" --tooth red11 @SUT@
  fi
  # mutant 2 — cleanup: the BaseException path no longer reaps run_dir (INV-5 directory half).
  if _mvc_build teeth-mut-inv5 inv5 '/^    except BaseException:$/{n;s/^        shutil\.rmtree(run_dir, ignore_errors=True)$/        pass/;}'; then
    _mvc_tt teeth-mut-inv5 0 0 "$mut/inv5/lib/${ex}_exec.py" --orig "$sut_exec" \
      --good-has '^TOOTH_INV5=reaped$' --good-lacks "$crash" \
      --bad-has '^TOOTH_INV5=leaked$' --bad-lacks "$crash" -- bash "$self" --tooth inv5 @SUT@
  fi
  # mutant 3 — single allocation: run_vm allocates a second, orphaned run_dir.
  if _mvc_build teeth-mut-alloc alloc 's|^    run_dir = _dc.make_run_subdir(uuid.uuid4().hex)$|    _dc.make_run_subdir(uuid.uuid4().hex)\n    run_dir = _dc.make_run_subdir(uuid.uuid4().hex)|'; then
    _mvc_tt teeth-mut-alloc 0 0 "$mut/alloc/lib/${ex}_exec.py" --orig "$sut_exec" \
      --good-has '^TOOTH_ALLOC=1$' --good-lacks "$crash" \
      --bad-has '^TOOTH_ALLOC=2$' --bad-lacks "$crash" -- bash "$self" --tooth alloc @SUT@
  fi
  unset -f _mvc_stage _mvc_build _mvc_tt
}
