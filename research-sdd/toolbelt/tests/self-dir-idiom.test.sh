#!/usr/bin/env bash
# self-dir-idiom.test.sh — the shared RSDD-SELF-DIR idiom (kit issue #1675): every script that locates its own
# directory carries the SAME block, and that block resolves the real directory through relative symlink chains,
# from an unrelated cwd, with CDPATH exported, and says so (one typed stderr line) when it cannot.
#
# Cases
#   parity       every toolbelt/install script carrying the marker holds the canonical block byte-for-byte
#                (leading indentation aside), and so does the idiom section of tool-registry.md
#   chain        a >=2-link chain of RELATIVE symlinks in other directories, invoked from an unrelated cwd
#   cdpath       CDPATH exported + a relative invocation must not land in a decoy directory
#   degraded     hop limit hit, or readlink failing, prints one `<script>: degraded: self-dir symlink resolution ...`
#   help         the installer's --help works through a symlink with a DIFFERENT name
#   install.sh   install/install.sh follows a symlinked file like the idiom
# Mutation controls (--prove-teeth) run each probe against a mutant of a real script's idiom.
# Probe mode (used by the teeth): self-dir-idiom.test.sh --probe chain|cdpath|degraded-hop|degraded-readlink|clean|help FILE
#   builds a scenario around FILE and prints `OK <case>` or `BAD <case> ...`.
#
# Exit: 0 all held · 1 regression · 2 harness error

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"  # LINT-CD-PHYSICAL-OK: test driver locating its SUT; run from the kit checkout by path
SELF="$HERE/self-dir-idiom.test.sh"
TB="$(cd "$HERE/.." && pwd)"  # LINT-CD-PHYSICAL-OK: as above
KITDIR="$(cd "$TB/.." && pwd)"  # LINT-CD-PHYSICAL-OK: as above
# shellcheck disable=SC2034 # read by lib/mutant.sh (mutant_tooth) as the original each mutant is compared with
SUT="$TB/sweep-tools-hook.sh"

CANON="$(cat <<'EOF'
# RSDD-SELF-DIR (kit #1675): own directory from BASH_SOURCE with symlinks followed - never $0 or the caller's cwd.
_rsdd_s="${BASH_SOURCE[0]}"; _rsdd_n=0
while [ -L "$_rsdd_s" ] && [ "$_rsdd_n" -lt 40 ]; do _rsdd_n=$((_rsdd_n + 1)); _rsdd_t="$(readlink -- "$_rsdd_s")" || break; case "$_rsdd_t" in /*) _rsdd_s="$_rsdd_t" ;; *) _rsdd_s="$(dirname -- "$_rsdd_s")/$_rsdd_t" ;; esac; done
if [ -L "$_rsdd_s" ]; then echo "${0##*/}: degraded: self-dir symlink resolution incomplete (hop limit or readlink failure) at $_rsdd_s" >&2; fi
_RSDD_SELF="$(CDPATH='' cd -- "$(dirname -- "$_rsdd_s")" && pwd -P)"; unset _rsdd_s _rsdd_n _rsdd_t
EOF
)"

# block_of FILE -> the idiom block (marker line through the unset line), leading whitespace stripped
block_of() { awk '/# RSDD-SELF-DIR/ { on = 1 } on { sub(/^[ \t]+/, ""); print } on && /unset _rsdd_s/ { exit }' "$1"; }

# probe_script FILE OUT -> a script made of FILE's idiom block that prints the resolved directory
probe_script() {
  { printf '#!/usr/bin/env bash\n'; block_of "$1"; printf 'echo "RSDD_SELF=$_RSDD_SELF"\n'; } > "$2"
  chmod +x "$2"
}

probe() {   # probe CASE FILE
  local case_="$1" file="$2" t real out err rc i
  t="$(mktemp -d)" || { echo "BAD $case_ no tmpdir"; return 0; }
  t="$(cd "$t" && pwd -P)"  # LINT-CD-PHYSICAL-OK: scratch dir canonicalisation
  mkdir -p "$t/real/sub" "$t/l1" "$t/l2" "$t/other/deep" "$t/decoy/sub"
  real="$t/real/sub"
  probe_script "$file" "$real/probe.sh"
  case "$case_" in
    chain|clean)
      ln -s ../real/sub/probe.sh "$t/l2/link2"; ln -s ../l2/link2 "$t/l1/link1"
      out="$(cd "$t/other/deep" && bash ../../l1/link1 2>"$t/err")"; err="$(cat "$t/err")"
      if [ "$out" = "RSDD_SELF=$real" ] && { [ "$case_" = chain ] || [ -z "$err" ]; }; then echo "OK $case_"
      else echo "BAD $case_ got=[$out] err=[$err]"; fi ;;
    cdpath)
      out="$(cd "$t/real" && CDPATH="$t/decoy" bash sub/probe.sh 2>&1)"
      if [ "$out" = "RSDD_SELF=$real" ]; then echo "OK cdpath"; else echo "BAD cdpath got=[$out]"; fi ;;
    degraded-hop)   # the kernel stops at 40 links itself, so lower the idiom's own limit to make it reachable
      sed -i 's/-lt 40/-lt 3/' "$real/probe.sh"
      mkdir -p "$t/chain"; ln -s ../real/sub/probe.sh "$t/chain/c0"
      for i in 1 2 3 4 5 6; do ln -s "c$((i - 1))" "$t/chain/c$i"; done
      out="$(bash "$t/chain/c6" 2>"$t/err")"; err="$(cat "$t/err")"
      if [ "$(grep -c 'probe.sh: degraded: self-dir symlink resolution\|c6: degraded: self-dir symlink resolution' <<<"$err")" -eq 1 ] && [ -n "$out" ]; then echo "OK degraded-hop"
      else echo "BAD degraded-hop err=[$err] out=[$out]"; fi ;;
    degraded-readlink)
      mkdir -p "$t/shim"; printf '#!/bin/sh\nexit 1\n' > "$t/shim/readlink"; chmod +x "$t/shim/readlink"
      ln -s ../real/sub/probe.sh "$t/l1/link1"
      out="$(PATH="$t/shim:$PATH" bash "$t/l1/link1" 2>"$t/err")"; err="$(cat "$t/err")"
      if [ "$(grep -c 'degraded: self-dir symlink resolution' <<<"$err")" -eq 1 ] && [ -n "$out" ]; then echo "OK degraded-readlink"
      else echo "BAD degraded-readlink err=[$err] out=[$out]"; fi ;;
    help)   # FILE is the installer
      mkdir -p "$t/kit/install" "$t/bin"
      cp "$file" "$t/kit/install/research-sdd-install.sh"; cp "$KITDIR/install/adapters.sh" "$t/kit/install/adapters.sh"
      ln -s ../kit/install/research-sdd-install.sh "$t/bin/rsdd-inst"
      out="$(cd "$t/other" && bash ../bin/rsdd-inst --help 2>&1)"; rc=$?
      if [ "$rc" -eq 0 ] && grep -q '^Usage:' <<<"$out" && grep -q -- '--harness' <<<"$out"; then echo "OK help"
      else echo "BAD help rc=$rc out=[$(head -c 200 <<<"$out")]"; fi ;;
    *) echo "BAD unknown case $case_" ;;
  esac
  rm -rf "$t"
}

if [ "${1:-}" = "--probe" ]; then probe "$2" "$3"; exit 0; fi

pass=0; fail=0
ok() { echo "  PASS  $1"; pass=$((pass + 1)); }
no() { echo "  FAIL  $1"; fail=$((fail + 1)); }
echo "== self-dir-idiom.test.sh =="

# ---- parity: the canonical block everywhere --------------------------------
nblk=0; nbad=0; badlist=""
for f in "$TB"/*.sh "$TB"/lib/*.sh "$KITDIR"/install/*.sh; do
  grep -q '# RSDD-SELF-DIR' "$f" || continue
  nblk=$((nblk + 1))
  [ "$(block_of "$f")" = "$CANON" ] || { nbad=$((nbad + 1)); badlist="$badlist $(basename "$f")"; }
done
if [ "$nblk" -ge 39 ] && [ "$nbad" -eq 0 ]; then ok "parity: $nblk scripts carry the canonical block byte-for-byte"
else no "parity: $nblk scripts carry the marker (want >=39), $nbad differ:$badlist"; fi
if [ "$(block_of "$TB/tool-registry.md" 2>/dev/null)" = "$CANON" ]; then ok "parity: the tool-registry.md idiom section holds the canonical block"
else no "parity: tool-registry.md idiom block differs from the canonical block"; fi

# ---- behaviour on the real idiom -------------------------------------------
for c in chain clean cdpath degraded-hop degraded-readlink; do
  r="$(probe "$c" "$SUT")"
  case "$r" in OK*) ok "$c: $r" ;; *) no "$c: $r" ;; esac
done
r="$(probe help "$KITDIR/install/research-sdd-install.sh")"
case "$r" in OK*) ok "help: installer --help through a differently named symlink" ;; *) no "help: $r" ;; esac

# install/install.sh: a symlinked FILE resolves SELF/KIT to the real directory (--help is rc 0 and reads its own header)
t="$(mktemp -d)"; mkdir -p "$t/bin" "$t/other"
ln -s "$KITDIR/install/install.sh" "$t/bin/ins-link"
out="$(cd "$t/other" && bash ../bin/ins-link --help 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && [ -n "$out" ]; then ok "install.sh: --help through a symlinked file (rc 0, header printed)"; else no "install.sh --help via symlink: rc=$rc out=[$(head -c 200 <<<"$out")]"; fi
# the resolved SELF must be the real install dir: source the script under a symlink and print SELF
out="$(cd "$t/other" && bash -c 'source ../bin/ins-link; printf "%s\n" "$SELF"' 2>&1 | tail -1)"
if [ "$out" = "$(cd -P "$KITDIR/install" && pwd -P)" ]; then ok "install.sh: sourced through a symlinked file, SELF is the real install dir"; else no "install.sh SELF through a symlink: [$out]"; fi
rm -rf "$t"

# ---- Teeth -----------------------------------------------------------------
# shellcheck source=lib/mutant.sh
. "$HERE/lib/mutant.sh"
mutant_bootstrap mutant_chain mutant_tooth || exit 2
tooth() { if mutant_tooth "$@"; then pass=$((pass + 1)); else fail=$((fail + 1)); fi; }
mk_sed() { mkdir -p "$(dirname "$2")"; mutant_chain "$1" "$3" "$2" "${@:4}" || { fail=$((fail + 1)); return 1; }; }

if [ "${1:-}" = "--prove-teeth" ]; then
  MUT="$(mktemp -d)"
  M='sweep-tools-hook.sh'
  echo "-- teeth: each facet of the idiom must be load-bearing --"
  # symlink loop disabled -> the chain resolves the link's own directory
  mk_sed "teeth loop" "$MUT/loop/$M" "$SUT" 's#^while \[ -L "\$_rsdd_s" \] &&#while false \&\&#' \
    && tooth "teeth loop: symlink loop disabled -> chain not followed" 0 0 "$MUT/loop/$M" \
         --good-has 'OK chain' --bad-has 'BAD chain' -- bash "$SELF" --probe chain @SUT@
  # relative target not joined to the link's directory
  mk_sed "teeth join" "$MUT/join/$M" "$SUT" 's#\*) _rsdd_s="\$(dirname -- "\$_rsdd_s")/\$_rsdd_t" ;;#*) _rsdd_s="$_rsdd_t" ;;#' \
    && tooth "teeth join: relative target not joined -> chain from an unrelated cwd breaks" 0 0 "$MUT/join/$M" \
         --good-has 'OK chain' --bad-has 'BAD chain' -- bash "$SELF" --probe chain @SUT@
  # CDPATH neutralisation removed
  mk_sed "teeth cdpath" "$MUT/cdp/$M" "$SUT" 's#CDPATH=[^ ]* cd --#cd --#' \
    && tooth "teeth cdpath: CDPATH= removed -> decoy directory wins" 0 0 "$MUT/cdp/$M" \
         --good-has 'OK cdpath' --bad-has 'BAD cdpath' -- bash "$SELF" --probe cdpath @SUT@
  # degraded line removed
  mk_sed "teeth degraded" "$MUT/deg/$M" "$SUT" '/^if \[ -L "\$_rsdd_s" \]; then echo/d' \
    && { tooth "teeth degraded (hop): line removed -> silent fallback" 0 0 "$MUT/deg/$M" \
           --good-has 'OK degraded-hop' --bad-has 'BAD degraded-hop' -- bash "$SELF" --probe degraded-hop @SUT@
         tooth "teeth degraded (readlink): line removed -> silent fallback" 0 0 "$MUT/deg/$M" \
           --good-has 'OK degraded-readlink' --bad-has 'BAD degraded-readlink' -- bash "$SELF" --probe degraded-readlink @SUT@; }
  # a spurious message on the clean path
  mk_sed "teeth clean" "$MUT/clean/$M" "$SUT" 's#^if \[ -L "\$_rsdd_s" \]; then echo#if true; then echo#' \
    && tooth "teeth clean: message printed on a clean resolution -> noisy" 0 0 "$MUT/clean/$M" \
         --good-has 'OK clean' --bad-has 'BAD clean' -- bash "$SELF" --probe clean @SUT@
  # installer --help reverted to "$SELF/$(basename "$0")"
  INST="$KITDIR/install/research-sdd-install.sh"
  mk_sed "teeth help" "$MUT/help/research-sdd-install.sh" "$INST" 's#"\${BASH_SOURCE\[0\]}" | sed#"$SELF/$(basename "$0")" | sed#' \
    && tooth "teeth help: usage reads \$SELF/\$(basename \$0) -> --help via a renamed symlink is empty" 0 0 "$MUT/help/research-sdd-install.sh" \
         --orig "$INST" --good-has 'OK help' --bad-has 'BAD help' -- bash "$SELF" --probe help @SUT@
  rm -rf "$MUT"
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
