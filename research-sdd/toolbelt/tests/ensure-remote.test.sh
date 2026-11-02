#!/usr/bin/env bash
# ensure-remote.test.sh — black-box contract for the ensure-remote.sh SHIM (kit issue #2460; ported from bash).
#
# The PRIVATE-BY-CONSTRUCTION remote guard is the Go command `rsdd corpus ensure-remote`
# (research-sdd/rsdd/internal/corpus/ensureremote). Its six-layer guard, the allow list, the positive-identification
# classifier, the history walk and every create/verify/timeout path used to be pinned here by 117 cases and ~50 sed
# mutants of the script, driven by stub gh/git on a hermetic PATH (about a minute of process spawning). They are Go
# tests now, driven by an injected fake runner and fake gh: no process, no sleep, no network (guard-to-test table at
# the head of flow_test.go; cases.md of the port maps every old case to its Go test).
#
# What stays here is what only the shim can show, through the real binary:
#   * the shim shape and its executable bit (research-sdd-init.sh runs the script directly);
#   * argument and exit-code pass-through (usage, not a git repo, no consent, existing origin);
#   * the --toolbelt wiring: scan-secrets.sh is resolved beside THIS shim (a sentinel scanner proves it ran);
#   * the E1 end-to-end: the REAL scan-secrets.sh + a real git repo where `git replace` hides a secret commit;
#   * ONE full happy path against real git: a stub gh adds a local bare repo as origin, nothing touches a network;
#   * the typed degraded state when rsdd is missing.
#
# TEETH (tests/lib/mutant.sh): three mutants of the SHIM — drop --toolbelt (the sentinel scanner no longer runs),
# point it at another command (the usage contract changes) and strip the exec bit.
#
# Usage: ensure-remote.test.sh                (run the suite)
#        ensure-remote.test.sh --prove-teeth  (run suite + the mutation teeth proofs)
# Exit: 0 = every assertion held · 1 = a regression · 2 = harness error (SUT / required tool missing).

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../ensure-remote.sh"
[ -f "$SUT" ] || { echo "FATAL: script under test not found: $SUT" >&2; exit 2; }
# shellcheck source=lib/stage-libs.sh
. "$HERE/lib/stage-libs.sh"   # rsdd_stage_libs: stage every toolbelt/lib file into a sandbox toolbelt

for t in git bash; do command -v "$t" >/dev/null 2>&1 || { echo "FATAL: required tool '$t' not on PATH" >&2; exit 2; }; done
REAL_SCAN="$HERE/../scan-secrets.sh"

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
pass=0; fail=0
ok() { printf '  PASS  %-66s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
no() { printf '  FAIL  %-66s %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

echo "== ensure-remote.test.sh (SUT: $(basename "$SUT")) =="

# A kit-shaped copy: the shim resolves rsdd from <toolbelt>/../rsdd (lib/rsdd-exec.sh), so the copy sits in a dir whose
# rsdd/ links to the real module and any rebuild (RSDD_BIN unset, as in CI) lands in $ROOT/<kit>/bin, never in the kit.
# mkkit NAME — creates $ROOT/NAME/{rsdd -> module, toolbelt/{lib/rsdd-exec.sh}} and echoes the toolbelt dir.
mkkit() {
  local k="$ROOT/$1"
  mkdir -p "$k/toolbelt/lib" && ln -s "$(CDPATH='' cd -P -- "$HERE/../../rsdd" && pwd -P)" "$k/rsdd" \
    || { echo "FATAL: could not stage kit $1" >&2; exit 2; }
  cp "$HERE/../lib/rsdd-exec.sh" "$k/toolbelt/lib/" || { echo "FATAL: could not stage rsdd-exec.sh" >&2; exit 2; }   # stage-libs-ok: the shim sources only lib/rsdd-exec.sh
  printf '%s' "$k/toolbelt"
}
TB="$(mkkit kit)"; cp "$SUT" "$TB/"; SHIM="$TB/ensure-remote.sh"

# A sentinel scanner beside the shim: records its argv, then exits with SCAN_EXIT.
cat > "$TB/scan-secrets.sh" <<'S'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${SCAN_LOG:?}"
exit "${SCAN_EXIT:-0}"
S
chmod +x "$TB/scan-secrets.sh"

# ---- stub gh: logs its argv; `repo create` adds a LOCAL BARE repo as origin (what --source --remote origin does) ----
STUB="$ROOT/stub"; mkdir -p "$STUB"
cat > "$STUB/gh" <<'S'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >> "${GH_LOG:?}"
case "$*" in
  "api user -q .login") echo tester ;;
  "api users/tester -q .type") echo User ;;
  "repo create "*) src=""; prev=""; for a in "$@"; do [ "$prev" = --source ] && src="$a"; prev="$a"; done
                   git -C "$src" remote add origin "${BARE:?}" ;;
  "repo view "*) echo "${GH_VIS:-PRIVATE}" ;;
  *) exit 0 ;;
esac
S
chmod +x "$STUB/gh"

# Hermetic git: no host configuration, a fixed identity.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export HOME="$ROOT/home"; mkdir -p "$HOME"
export GH_LOG="$ROOT/gh.log" SCAN_LOG="$ROOT/scan.log"

# mkrepo NAME — a real git repo with one commit; echoes its path.
mkrepo() {
  local d="$ROOT/$1"; mkdir -p "$d"
  git -C "$d" init -q -b main && printf '# corpus\n' > "$d/a.md" && git -C "$d" add a.md && git -C "$d" commit -q -m base \
    || { echo "FATAL: could not build repo $1" >&2; exit 2; }
  printf '%s' "$d"
}
# run SHIM-OR-OTHER ARGV... ; sets OUT (stdout), ERR (stderr), RC. The stub gh leads PATH; the sentinel logs are reset.
run() {
  local e="$ROOT/err"; : > "$GH_LOG"; : > "$SCAN_LOG"
  OUT="$(PATH="$STUB:$PATH" "$@" 2>"$e")"; RC=$?; ERR="$(cat "$e")"
}
has()  { grep -qE -- "$1" <<<"$OUT"; }
hasE() { grep -qE -- "$1" <<<"$ERR"; }

# ---- shim shape ----------------------------------------------------------------------------------------------------
sut_code="$(grep -v '^[[:space:]]*#' "$SUT")"   # the executable lines only: the header documents the guard
grep -q '^rsdd_exec corpus ensure-remote ' "$SUT" && [[ "$sut_code" != *'gh repo'* && "$sut_code" != *'git -C'* ]] \
  && ok "1 the script is a shim for rsdd corpus ensure-remote (no guard logic left)" || no "1 shim shape"

# 2 — EXEC BIT. The tracked SUT must carry the executable bit (100755 in git) so the documented direct invocation
#     (`run $KIT/toolbelt/ensure-remote.sh $target --yes`, research-sdd-init.sh) works. sut_is_exec is the SAME predicate
#     the exec-bit tooth mutates against.
sut_is_exec() { [ -x "$1" ]; }
if sut_is_exec "$SUT"; then ok "2 SUT is directly executable (tracked git mode must be 100755)"
else no "2 SUT is directly executable" "mode=$(stat -c '%a' "$SUT" 2>/dev/null || echo unknown)"; fi

# ---- argument and exit-code pass-through ---------------------------------------------------------------------------
run bash "$SHIM"
{ [ "$RC" = 2 ] && [ "$ERR" = "usage: ensure-remote.sh <target-dir> [--yes] [--name <repo>]" ] && [ -z "$OUT" ]; } \
  && ok "3 no target -> rc 2 with the legacy usage line" || no "3 usage" "rc=$RC err=$ERR"
run bash "$SHIM" "$ROOT/home" --name
{ [ "$RC" = 2 ] && [ "$ERR" = "REFUSED: --name requires a value" ] && [ ! -s "$GH_LOG" ]; } \
  && ok "4 --name without a value -> rc 2, no gh call" || no "4 --name" "rc=$RC err=$ERR"
run bash "$SHIM" "$ROOT/home" --bogus
{ [ "$RC" = 2 ] && [ "$ERR" = "unknown flag: --bogus" ]; } && ok "5 unknown flag -> rc 2" || no "5 unknown flag" "rc=$RC err=$ERR"
mkdir -p "$ROOT/plain"
run bash "$SHIM" "$ROOT/plain" --yes
{ [ "$RC" = 2 ] && hasE '^REFUSED: .*/plain is not a git repository — run research-sdd-init.sh first\.$' && [ ! -s "$GH_LOG" ]; } \
  && ok "6 not a git repository -> rc 2, no gh call" || no "6 not a repo" "rc=$RC err=$ERR"
REPO="$(mkrepo nc)"
run bash "$SHIM" "$REPO"
{ [ "$RC" = 3 ] && hasE '^REFUSED: creating a remote pushes the corpus to GitHub\. Re-run with --yes \(or RSDD_ALLOW_REMOTE=1\)$' \
  && hasE '^         when you consent to a PRIVATE GitHub remote for nc\.$' && [ ! -s "$GH_LOG" ]; } \
  && ok "7 no consent -> rc 3 before any gh call" || no "7 no consent" "rc=$RC err=$ERR gh=$(cat "$GH_LOG")"
REPO="$(mkrepo oo)"; git -C "$REPO" remote add origin https://github.com/tester/research-oo.git
run bash "$SHIM" "$REPO" --yes
{ [ "$RC" = 0 ] && [ "$OUT" = "ensure-remote: origin already set (https://github.com/tester/research-oo.git) — nothing to do." ] && [ ! -s "$GH_LOG" ]; } \
  && ok "8 existing origin -> rc 0, nothing to do, no gh call" || no "8 idempotent" "rc=$RC out=$OUT"

# ---- the --toolbelt wiring: the scanner beside the shim runs (sentinel) and its verdict decides -----------------------
REPO="$(mkrepo tb)"
run env SCAN_EXIT=1 bash "$SHIM" "$REPO" --yes
{ [ "$RC" = 5 ] && grep -qx -- "--committed $REPO" "$SCAN_LOG" && hasE '^REFUSED: scan-secrets\.sh --committed found a high-confidence secret VALUE' \
  && ! grep -q 'repo create' "$GH_LOG"; } \
  && ok "9 the scanner beside the shim runs with --committed and its hit refuses (rc 5, no create)" || no "9 toolbelt wiring" "rc=$RC scan=$(cat "$SCAN_LOG") err=$ERR"

# ---- E1 end-to-end: the REAL scan-secrets.sh; git-replace hides a secret commit from rev-list ------------------------
TBE="$(mkkit kite)"; cp "$SUT" "$TBE/"; cp "$REAL_SCAN" "$TBE/scan-secrets.sh"; rsdd_stage_libs "$TBE" 2>/dev/null || true
d="$ROOT/e1-repo"; mkdir -p "$d"
git -C "$d" init -q -b main; printf '# base\n' > "$d/a.md"; git -C "$d" add a.md; git -C "$d" commit -q -m base
printf 'token=ghp_0123456789abcdefghijklmnopqrstuvwxyz\n' > "$d/n.md"; git -C "$d" add n.md; git -C "$d" commit -q -m secret
bad="$(git -C "$d" rev-parse HEAD)"
git -C "$d" rm -q n.md; git -C "$d" commit -q -m clean
# shellcheck disable=SC1083  # ^{tree} is git revision syntax, not shell brace expansion
good="$(git -C "$d" commit-tree "$(git -C "$d" rev-parse 'HEAD~2^{tree}')" -p "$(git -C "$d" rev-parse HEAD~2)" -m secret-clean-replacement)"
git -C "$d" replace "$bad" "$good"
run bash "$TBE/ensure-remote.sh" "$d" --yes
remotes="$(git -C "$d" remote)"
{ [ "$RC" = 5 ] && ! grep -q 'repo create' "$GH_LOG" && [ -z "$remotes" ]; } \
  && ok "10 E1: real scan + git replace -> refused (rc 5), nothing created, no origin" || no "10 E1 end-to-end" "rc=$RC err=$ERR gh=$(cat "$GH_LOG")"

# ---- one full happy path: real git, stub gh, a local bare repo as the 'remote' ------------------------------------------
BARE="$ROOT/bare.git"; git init -q --bare -b main "$BARE"; export BARE
REPO="$(mkrepo happy)"
run bash "$SHIM" "$REPO" --yes
want_head="$(git -C "$REPO" rev-parse HEAD)"
{ [ "$RC" = 0 ] && has '^>> creating PRIVATE remote tester/research-happy$' && has '^>> confirmed PRIVATE — pushing corpus$' \
  && has '^== ensure-remote: private remote ready at https://github.com/tester/research-happy ==$' \
  && [ "$(git -C "$BARE" rev-parse main 2>/dev/null)" = "$want_head" ] \
  && grep -qx 'gh repo create tester/research-happy --private --source '"$REPO"' --remote origin --disable-wiki' "$GH_LOG"; } \
  && ok "11 full run: created --private, verified PRIVATE, pushed to the bare origin" || no "11 happy path" "rc=$RC out=$OUT err=$ERR"
gi="$REPO/.gitignore"; miss=""
for pat in 'security/' 'licenses/' 'certificates/' '*.pem' '*.der' '*.key' '*.p12' '*.pfx' 'id_rsa*' 'keystore/' 'keyring/' '*.jks' '*.keystore'; do
  grep -qxF -- "$pat" "$gi" 2>/dev/null || miss="$miss $pat"
done
committed_gi="$(git -C "$REPO" show HEAD:.gitignore)"
{ [ -z "$miss" ] && grep -qxF '*.pem' <<<"$committed_gi" && [ -z "$(git -C "$REPO" status --porcelain)" ]; } \
  && ok "12 .gitignore seeded with every secret-type pattern and committed (the pushed HEAD carries it)" || no "12 gitignore" "missing=[$miss]"
run bash "$SHIM" "$REPO" --yes
{ [ "$RC" = 0 ] && has '^ensure-remote: origin already set ' && ! grep -q 'repo create' "$GH_LOG"; } \
  && ok "13 re-run on the pushed repo -> idempotent no-op" || no "13 re-run" "rc=$RC out=$OUT"

# PUBLIC read-back through the real binary: forced private once, still public -> HARD ABORT 6, origin removed, no push.
BARE2="$ROOT/bare2.git"; git init -q --bare -b main "$BARE2"
REPO="$(mkrepo pub)"
run env BARE="$BARE2" GH_VIS=PUBLIC bash "$SHIM" "$REPO" --yes
remotes="$(git -C "$REPO" remote)"
{ [ "$RC" = 6 ] && hasE '^!! HARD ABORT: a non-private repo exists at https://github.com/tester/research-pub' \
  && [ -z "$remotes" ] && ! git -C "$BARE2" rev-parse main >/dev/null 2>&1; } \
  && ok "14 PUBLIC read-back -> rc 6, origin removed, nothing pushed" || no "14 public abort" "rc=$RC err=$ERR"

# ---- typed degraded state when rsdd is missing ----------------------------------------------------------------------
run env RSDD_BIN=/nonexistent/rsdd bash "$SHIM" "$REPO" --yes
{ [ "$RC" = 2 ] && hasE '^degraded: rsdd-unavailable'; } && ok "15 no rsdd binary -> typed degraded: rsdd-unavailable, never a silent pass" || no "15 rsdd missing" "rc=$RC err=$ERR"

# ---- TEETH ---------------------------------------------------------------------------------------------------------
if [ "${1:-}" = "--prove-teeth" ]; then
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  mutant_bootstrap mutant_built mutant_crash_re || exit 2
  # mkmut LABEL EXPR — a mutant of the shim (sed EXPR), vetted by lib/mutant.sh, in its own kit-shaped copy. Sets MTB.
  mkmut() {
    local d; d="$(mkkit "kit-$1")"; MTB="$d"
    mutant_chain "$1" "$SUT" "$d/ensure-remote.sh" "$2" && return 0
    no "$1: mutant refused by lib/mutant.sh" "tooth not run"
    echo "== $pass passed · $fail failed =="; exit 1
  }

  # T1 — drop --toolbelt: the sentinel scanner beside the shim no longer runs, so case 9's hit cannot refuse.
  echo "-- teeth 1: drop --toolbelt from the shim, expect the scanner beside it NOT to run --"
  mkmut teeth1-no-toolbelt 's| --toolbelt "\$_RSDD_SELF"||'
  cp "$TB/scan-secrets.sh" "$MTB/scan-secrets.sh"
  REPO="$(mkrepo t1)"
  run env SCAN_EXIT=1 bash "$MTB/ensure-remote.sh" "$REPO" --yes
  if ! grep -qx -- "--committed $REPO" "$SCAN_LOG"; then ok "teeth1: without --toolbelt the shim's own scanner is not used — case 9 has teeth"
  else no "teeth1: the sentinel scanner still ran — case 9 is THEATER" "rc=$RC"; fi

  # T2 — point the shim at another command: case 3's usage contract must change.
  echo "-- teeth 2: shim dispatches to another command, expect the usage contract to break --"
  mkmut teeth2-wrong-command 's|rsdd_exec corpus ensure-remote|rsdd_exec corpus nonesuch|'
  run bash "$MTB/ensure-remote.sh"
  if [ "$ERR" != "usage: ensure-remote.sh <target-dir> [--yes] [--name <repo>]" ]; then ok "teeth2: a wrong dispatch loses the legacy usage line — case 3 has teeth"
  else no "teeth2: usage line unchanged under the mutant — case 3 is THEATER"; fi

  # T3 — strip the exec bit from a copy of the SUT; case 2's predicate must say no (and say yes for the real SUT).
  echo "-- teeth 3: strip exec bit from SUT copy, expect [ -x ] to FAIL --"
  tmp_sut="$(mktemp)"; cp "$SUT" "$tmp_sut"; chmod -x "$tmp_sut"
  if sut_is_exec "$SUT" && ! sut_is_exec "$tmp_sut"; then ok "teeth3: case 2's predicate passes the real SUT and rejects the non-exec mutant — case 2 has teeth"
  else no "teeth3: case 2's predicate cannot tell exec from non-exec — case 2 is THEATER"; fi
  rm -f "$tmp_sut"
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
