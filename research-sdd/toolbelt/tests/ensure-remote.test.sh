#!/usr/bin/env bash
# ensure-remote.test.sh — TEETH for the PRIVATE-BY-CONSTRUCTION remote guard (ensure-remote.sh).
#
# WHY THIS SHAPE. ensure-remote.sh is the ONLY sanctioned way a corpus (which decompiles proprietary
# systems) touches GitHub. A single leak — a public repo, a push before visibility is confirmed private,
# a push carrying a secret, an implicit network call — defeats the whole point. This suite PINS that the
# six-layer guard actually holds against the REAL script, under a FULLY HERMETIC sandbox where NO real
# gh/git/network call can happen. Every assertion is GREEN against the current script; the teeth (below)
# mutate the guard and prove the assertions would go RED, so this is not characterization theater.
#
# HERMETIC SANDBOX (mirrors install-tool.test.sh). Each case runs a COPY of the SUT under a PATH that
# contains ONLY "$box/bin": argv-LOGGING dispatch stubs for `gh` and `git` (they append their argv to a
# per-box calls.log and NEVER reach the network), a symlinked real `bash` (the SUT runs `bash "$SCAN"`),
# and symlinks to the real coreutils the covered paths invoke (dirname/basename/tr/sed/grep/tail). A fake
# `scan-secrets.sh` is dropped NEXT TO the SUT copy (the SUT resolves SCAN="$HERE/scan-secrets.sh"), so
# the pre-push secret sweep outcome is controlled by SCAN_EXIT, not the host. bash is invoked by ABSOLUTE
# path ($BASH_BIN) so the hermetic PATH cannot hide the interpreter. Determinism comes from the box: the
# stubs read control values (owner type, visibility, origin presence, create/scan exit) from env vars set
# per case — a real repo is NEVER created, a real remote is NEVER contacted.
#
# Usage: ensure-remote.test.sh                (run the suite)
#        ensure-remote.test.sh --prove-teeth  (run suite + the mutation teeth proofs)
# Exit: 0 = every assertion held · 1 = a regression · 2 = harness error (SUT / required tool missing).

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../ensure-remote.sh"
[ -f "$SUT" ] || { echo "FATAL: script under test not found: $SUT" >&2; exit 2; }

# --- resolve real binaries ONCE, before we restrict the PATH ----------------
BASH_BIN="$(type -P bash)"; [ -n "$BASH_BIN" ] || { echo "FATAL: bash not found on PATH" >&2; exit 2; }
CORE_UTILS=(dirname basename tr sed grep tail)   # every external cmd the covered paths invoke
CORE_PATHS=()
for u in "${CORE_UTILS[@]}"; do
  p="$(type -P "$u")"; [ -n "$p" ] || { echo "FATAL: required coreutil '$u' not on PATH" >&2; exit 2; }
  CORE_PATHS+=("$p")
done

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
pass=0; fail=0
ok() { printf '  PASS  %-52s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
no() { printf '  FAIL  %-52s %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

# --- control knobs (defaults = the "happy" private path) --------------------
reset_ctl() {
  GIT_HAS_ORIGIN=0 GIT_PUSH_EXIT=0 GH_OWNER=tester GH_OWNER_TYPE=User \
  GH_CREATE_EXIT=0 GH_VIS=PRIVATE SCAN_EXIT=0 GIT_TRACKED_SECRETS="" \
  GIT_GITIGNORE_DIRTY=0 GH_USERS_EXIT=0 GIT_STATUS_DIRTY=0 GIT_STATUS_FAIL=0
}

# --- stub factories ---------------------------------------------------------
# git stub: logs argv, then dispatches on the subcommand keyword. rev-parse always
#   succeeds (target IS a repo); `remote get-url origin` prints a url only when
#   GIT_HAS_ORIGIN=1 (else exit 1 = no origin); `ls-files -z ...` (the LAYER-4c
#   tracked-secret query) prints GIT_TRACKED_SECRETS (NUL-terminated) when set,
#   else nothing (no tracked secret); `status --porcelain` emits "M file.md" when
#   GIT_STATUS_DIRTY=1; push honours GIT_PUSH_EXIT; every other git call (incl.
#   `remote remove origin`, plain `ls-files --others`, `diff --quiet`, `add`,
#   `commit`) is logged and exits 0.
mk_git_stub() {
  local box="$1"
  {
    printf '#!%s\n' "$BASH_BIN"
    printf 'echo "git $*" >> "%s/calls.log"\n' "$box"
    cat <<'EOF'
case " $* " in
  *" rev-parse "*) exit 0 ;;
  *" get-url "*)
    if [ "${GIT_HAS_ORIGIN:-0}" = 1 ]; then
      echo "https://github.com/tester/research-target.git"; exit 0
    else
      exit 1
    fi ;;
  *" ls-files "*"-z "*)
    if [ -n "${GIT_TRACKED_SECRETS:-}" ]; then printf '%s\0' "${GIT_TRACKED_SECRETS}"; fi
    exit 0 ;;
  *" diff --quiet "*) exit "${GIT_GITIGNORE_DIRTY:-0}" ;;
  *" status "*) [ "${GIT_STATUS_FAIL:-0}" = 1 ] && exit 1; [ "${GIT_STATUS_DIRTY:-0}" = 1 ] && printf 'M file.md\n'; exit 0 ;;
  *" push "*) exit "${GIT_PUSH_EXIT:-0}" ;;
  *) exit 0 ;;
esac
EOF
  } > "$box/bin/git"
  chmod +x "$box/bin/git"
}

# gh stub: logs argv, dispatches on the gh subcommand. `api user` -> login;
#   `api users/<login>` -> account type (User|Organization); `repo create` honours
#   GH_CREATE_EXIT; `repo view` prints GH_VIS (the SUT uppercases it); `repo edit` is a no-op.
mk_gh_stub() {
  local box="$1"
  {
    printf '#!%s\n' "$BASH_BIN"
    printf 'echo "gh $*" >> "%s/calls.log"\n' "$box"
    cat <<'EOF'
case " $* " in
  *" repo create "*) exit "${GH_CREATE_EXIT:-0}" ;;
  *" repo view "*)   echo "${GH_VIS:-PRIVATE}"; exit 0 ;;
  *" repo edit "*)   exit 0 ;;
  *" api users/"*)   echo "${GH_OWNER_TYPE:-User}"; exit "${GH_USERS_EXIT:-0}" ;;
  *" api user "*)    echo "${GH_OWNER:-tester}"; exit 0 ;;
  *) exit 0 ;;
esac
EOF
  } > "$box/bin/gh"
  chmod +x "$box/bin/gh"
}

# mkbox <name> : isolated case dir. Copies the SUT, drops the fake scan-secrets.sh
#   next to it (SCAN=$HERE/scan-secrets.sh), builds the hermetic bin/ (coreutils +
#   bash symlinks + git/gh stubs), and an empty target dir the SUT will `cd` into. Echoes dir.
mkbox() {
  local box="$ROOT/$1" i
  mkdir -p "$box/bin" "$box/home" "$box/target"
  cp "$SUT" "$box/ensure-remote.sh"
  : > "$box/calls.log"
  { printf '#!%s\n' "$BASH_BIN"
    printf 'echo "scan-secrets $*" >> "%s/calls.log"\n' "$box"
    printf 'exit "${SCAN_EXIT:-0}"\n'; } > "$box/scan-secrets.sh"
  chmod +x "$box/scan-secrets.sh"
  for i in "${!CORE_UTILS[@]}"; do ln -s "${CORE_PATHS[$i]}" "$box/bin/${CORE_UTILS[$i]}"; done
  ln -s "$BASH_BIN" "$box/bin/bash"
  mk_git_stub "$box"
  mk_gh_stub "$box"
  printf '%s' "$box"
}

# run <box> [args...] : invoke the SUT copy with a HERMETIC PATH and the control
#   knobs exported into its env (the stubs read them). Combined output -> OUT, exit -> RC.
run() {
  local box="$1"; shift
  # shellcheck disable=SC2034  # OUT captured for debugging parity with sibling suites; cases assert on RC + calls.log
  OUT="$(PATH="$box/bin" HOME="$box/home" \
        GIT_HAS_ORIGIN="$GIT_HAS_ORIGIN" GIT_PUSH_EXIT="$GIT_PUSH_EXIT" \
        GH_OWNER="$GH_OWNER" GH_OWNER_TYPE="$GH_OWNER_TYPE" \
        GH_CREATE_EXIT="$GH_CREATE_EXIT" GH_VIS="$GH_VIS" SCAN_EXIT="$SCAN_EXIT" \
        GIT_TRACKED_SECRETS="$GIT_TRACKED_SECRETS" \
        GIT_GITIGNORE_DIRTY="$GIT_GITIGNORE_DIRTY" GH_USERS_EXIT="$GH_USERS_EXIT" \
        GIT_STATUS_DIRTY="$GIT_STATUS_DIRTY" GIT_STATUS_FAIL="$GIT_STATUS_FAIL" \
        "$BASH_BIN" "$box/ensure-remote.sh" "$@" 2>&1)"; RC=$?
}

calls()          { cat "$1/calls.log" 2>/dev/null; }
has_call()       { grep -q "$2" "$1/calls.log" 2>/dev/null; }               # box, needle
# a `gh repo create` was logged AND every create line carries --private.
create_all_private() {
  local box="$1"
  grep -q 'repo create' "$box/calls.log" 2>/dev/null || return 1
  # here-string (not a producer pipe): under load `grep … | grep -q` can EPIPE the
  # producer and, with pipefail, misreport. Guard above guarantees ≥1 create line.
  local creates; creates=$(grep 'repo create' "$box/calls.log" 2>/dev/null)
  ! grep -qv -- '--private' <<<"$creates"
}

echo "== ensure-remote.test.sh (SUT: $(basename "$SUT")) =="

# ---------------------------------------------------------------------------
# 1 — NO PUBLIC CODE PATH. On the happy private path, `gh repo create` is logged
#     and EVERY create line carries --private (there is no public creation path).
reset_ctl
box="$(mkbox c1-create-private)"
run "$box" "$box/target" --yes
if [ "$RC" = 0 ] && create_all_private "$box"; then
  ok "1 create is ALWAYS --private" "(exit $RC)"
else
  no "1 create is ALWAYS --private" "exit=$RC calls=[$(calls "$box")]"
fi

# 2 — VISIBILITY GUARD. gh reports the created repo as PUBLIC -> the SUT HARD-ABORTS:
#     exit 6, removes the origin remote, and NEVER pushes.
reset_ctl; GH_VIS=PUBLIC
box="$(mkbox c2-public-abort)"
run "$box" "$box/target" --yes
if [ "$RC" = 6 ] && has_call "$box" 'remote remove origin' && ! has_call "$box" 'git .* push'; then
  ok "2 PUBLIC read-back -> abort 6, drop origin, no push" "(exit $RC)"
else
  no "2 PUBLIC read-back -> abort 6, drop origin, no push" \
     "exit=$RC(want 6) push=$(has_call "$box" 'git .* push' && echo YES || echo no) calls=[$(calls "$box")]"
fi

# 3 — SECRET SWEEP. scan-secrets.sh returns non-zero (a high-confidence secret hit) ->
#     the SUT REFUSES with exit 5 and NEVER reaches `gh repo create`.
reset_ctl; SCAN_EXIT=1
box="$(mkbox c3-secret-refuse)"
run "$box" "$box/target" --yes
if [ "$RC" = 5 ] && ! has_call "$box" 'repo create'; then
  ok "3 secret hit -> refuse 5, NO repo create" "(exit $RC)"
else
  no "3 secret hit -> refuse 5, NO repo create" "exit=$RC(want 5) calls=[$(calls "$box")]"
fi

# 4 — CONSENT GATE. No --yes and no RSDD_ALLOW_REMOTE -> refuse exit 3 BEFORE any
#     network tool is touched (no `gh` line is ever logged).
reset_ctl
box="$(mkbox c4-no-consent)"
run "$box" "$box/target"
if [ "$RC" = 3 ] && ! has_call "$box" '^gh '; then
  ok "4 no consent -> refuse 3, NO gh call" "(exit $RC)"
else
  no "4 no consent -> refuse 3, NO gh call" "exit=$RC(want 3) calls=[$(calls "$box")]"
fi

# 5 — IDEMPOTENT. An existing origin short-circuits everything: exit 0, no `gh repo create`.
reset_ctl; GIT_HAS_ORIGIN=1
box="$(mkbox c5-existing-origin)"
run "$box" "$box/target" --yes
if [ "$RC" = 0 ] && ! has_call "$box" 'repo create'; then
  ok "5 existing origin -> exit 0, NO repo create" "(exit $RC)"
else
  no "5 existing origin -> exit 0, NO repo create" "exit=$RC(want 0) calls=[$(calls "$box")]"
fi

# 6 — PERSONAL-ACCOUNT GUARD. Owner resolves to an ORGANIZATION -> refuse exit 4
#     BEFORE creating anything (orgs can enforce a default-public policy).
reset_ctl; GH_OWNER_TYPE=Organization
box="$(mkbox c6-org-refuse)"
run "$box" "$box/target" --yes
if [ "$RC" = 4 ] && ! has_call "$box" 'repo create'; then
  ok "6 org owner -> refuse 4, NO repo create" "(exit $RC)"
else
  no "6 org owner -> refuse 4, NO repo create" "exit=$RC(want 4) calls=[$(calls "$box")]"
fi

# 7 — SUCCESS PATH PUSHES. On the happy path `git ... push` is actually logged
#     (a dropped or short-circuited push must be caught, not just RC=0).
reset_ctl
box="$(mkbox c7-push-logged)"
run "$box" "$box/target" --yes
if [ "$RC" = 0 ] && has_call "$box" 'git .* push'; then
  ok "7 happy path -> git push IS logged" "(exit $RC)"
else
  no "7 happy path -> git push IS logged" "exit=$RC calls=[$(calls "$box")]"
fi

# 8 — TRACKED SECRET-TYPE FILE (LAYER 4c). A git-TRACKED *.pem is present ->
#     the SUT REFUSES with exit 5 and NEVER pushes (the FIX-1 teeth: this is
#     the security regression test for the binary-type gap scan-secrets.sh
#     cannot see).
reset_ctl; GIT_TRACKED_SECRETS="secret.pem"
box="$(mkbox c8-tracked-secret-refuse)"
run "$box" "$box/target" --yes
if [ "$RC" = 5 ] && ! has_call "$box" 'git .* push'; then
  ok "8 tracked *.pem -> refuse 5, NO push" "(exit $RC)"
else
  no "8 tracked *.pem -> refuse 5, NO push" "exit=$RC(want 5) calls=[$(calls "$box")]"
fi

# 9 — GITIGNORE SEEDED. The secret-type patterns (LAYER 4a) actually land in
#     the target's .gitignore before any push is attempted.
reset_ctl
box="$(mkbox c9-gitignore-seeded)"
run "$box" "$box/target" --yes
gi="$box/target/.gitignore"
missing=""
for pat in 'security/' 'licenses/' 'certificates/' '*.pem' '*.der' '*.key' '*.p12' '*.pfx' \
           'id_rsa*' 'keystore/' 'keyring/' '*.jks' '*.keystore'; do
  grep -qxF "$pat" "$gi" 2>/dev/null || missing="$missing $pat"
done
if [ -f "$gi" ] && [ -z "$missing" ]; then
  ok "9 .gitignore seeded with all secret-type patterns" "(exit $RC)"
else
  no "9 .gitignore seeded with all secret-type patterns" "missing=[$missing] file=$([ -f "$gi" ] && echo present || echo ABSENT)"
fi

# 10 — FIX-2: the LAYER-4a .gitignore seed COMMIT is RESTRICTED to .gitignore. The SUT commits with an
#     explicit `-- .gitignore` pathspec so a pre-staged UNRELATED file cannot be swept into the
#     ensure-remote commit. Force the seeded .gitignore to read as dirty (GIT_GITIGNORE_DIRTY=1) so the
#     commit path actually runs, then assert the logged `git commit` carries the `-- .gitignore` pathspec.
reset_ctl; GIT_GITIGNORE_DIRTY=1
box="$(mkbox c10-gitignore-scoped-commit)"
run "$box" "$box/target" --yes
if [ "$RC" = 0 ] && has_call "$box" 'commit .* -- .gitignore'; then
  ok "10 .gitignore commit scoped to '-- .gitignore' (no unrelated sweep-in)" "(exit $RC)"
else
  no "10 .gitignore commit scoped to '-- .gitignore' (no unrelated sweep-in)" "exit=$RC calls=[$(calls "$box")]"
fi

# 11 — FIX-3: `gh api users/<owner>` FAILS (owner account type is unverifiable) → the SUT REFUSES with
#     exit 7 BEFORE creating anything (fail-closed: an owner it cannot confirm is personal never proceeds
#     to repo creation, since an org could carry a default-public policy).
reset_ctl; GH_USERS_EXIT=1
box="$(mkbox c11-owner-unverifiable)"
run "$box" "$box/target" --yes
if [ "$RC" = 7 ] && ! has_call "$box" 'repo create'; then
  ok "11 owner type unverifiable (gh api users/ fails) → refuse 7, NO repo create" "(exit $RC)"
else
  no "11 owner type unverifiable (gh api users/ fails) → refuse 7, NO repo create" "exit=$RC(want 7) calls=[$(calls "$box")]"
fi

# 12 — FIX-4: `--name` given with NO following value → the SUT refuses with exit 2 during arg parsing,
#     BEFORE any gh/network call (a dangling flag must never fall through to repo creation).
reset_ctl
box="$(mkbox c12-name-no-value)"
run "$box" "$box/target" --name
if [ "$RC" = 2 ] && ! has_call "$box" '^gh '; then
  ok "12 --name with no value → refuse 2, NO gh call" "(exit $RC)"
else
  no "12 --name with no value → refuse 2, NO gh call" "exit=$RC(want 2) calls=[$(calls "$box")]"
fi

# 13 — EXEC BIT. The tracked SUT must carry the executable bit (100755 in git) so that
#     the documented direct-invocation `run $KIT/toolbelt/ensure-remote.sh $target --yes`
#     (research-sdd-init.sh:152) succeeds without `permission denied` / ENOEXEC.
#     The existing cases 1-12 all invoke via "$BASH_BIN" "$box/ensure-remote.sh" and
#     therefore cannot catch a missing exec bit — this case pins the tracked mode.
if [ -x "$SUT" ]; then
  ok "13 SUT is directly executable (tracked git mode must be 100755)"
else
  no "13 SUT is directly executable (tracked git mode must be 100755)" \
     "mode=$(stat -c '%a' "$SUT" 2>/dev/null || echo unknown) — not executable; need chmod+git update-index"
fi

# 14 — DIRTY WORKING TREE (LAYER 4b-pre). git status --porcelain reports uncommitted changes →
#      the SUT refuses exit 8 BEFORE any scan, create, or push. The guard ensures the
#      committed-content scan (#955 fix) actually covers what will be pushed: if the WT is
#      dirty, a redaction only in the WT would pass the scan while HEAD still has the secret.
reset_ctl; GIT_STATUS_DIRTY=1
box="$(mkbox c14-dirty-tree)"
run "$box" "$box/target" --yes
if [ "$RC" = 8 ] && ! has_call "$box" 'repo create' && ! has_call "$box" 'git .* push'; then
  ok "14 dirty working tree -> refuse 8, NO create or push" "(exit $RC)"
else
  no "14 dirty working tree -> refuse 8, NO create or push" \
     "exit=$RC(want 8) calls=[$(calls "$box")]"
fi

# 15 — SCAN --COMMITTED FLAG. On the happy path, scan-secrets.sh is invoked with the
#      --committed flag so it scans committed HEAD content of the full repo, not the
#      corpus working-tree subdir only (#955).
reset_ctl
box="$(mkbox c15-scan-committed)"
run "$box" "$box/target" --yes
if [ "$RC" = 0 ] && has_call "$box" 'scan-secrets --committed'; then
  ok "15 scan-secrets called with --committed flag on happy path" "(exit $RC)"
else
  no "15 scan-secrets called with --committed flag on happy path" \
     "exit=$RC calls=[$(calls "$box")]"
fi

# 16 — SCAN DEGRADED (LAYER 4b). scan-secrets.sh exits 3 (DEGRADED: git unavailable or
#      no commits) → the SUT REFUSES with exit 7 and NEVER reaches `gh repo create` or push.
reset_ctl; SCAN_EXIT=3
box="$(mkbox c16-scan-degraded)"
run "$box" "$box/target" --yes
if [ "$RC" = 7 ] && ! has_call "$box" 'repo create' && ! has_call "$box" 'git .* push'; then
  ok "16 scan DEGRADED (exit 3) -> refuse 7, NO create or push" "(exit $RC)"
else
  no "16 scan DEGRADED (exit 3) -> refuse 7, NO create or push" \
     "exit=$RC(want 7) calls=[$(calls "$box")]"
fi

# 17 — SCAN UNKNOWN ERROR (LAYER 4b). scan-secrets.sh exits 2 (any unexpected non-0/non-1
#      exit) → the SUT REFUSES with exit 7 (fail-closed) and NEVER reaches create or push.
reset_ctl; SCAN_EXIT=2
box="$(mkbox c17-scan-unknown)"
run "$box" "$box/target" --yes
if [ "$RC" = 7 ] && ! has_call "$box" 'repo create' && ! has_call "$box" 'git .* push'; then
  ok "17 scan unknown error (exit 2) -> refuse 7, NO create or push" "(exit $RC)"
else
  no "17 scan unknown error (exit 2) -> refuse 7, NO create or push" \
     "exit=$RC(want 7) calls=[$(calls "$box")]"
fi

# 18 — GIT STATUS FAILURE (LAYER 4b-pre). git status --porcelain itself fails
#      (e.g. not a repo, permission error) → the SUT refuses exit 7 BEFORE any
#      scan, create, or push. Fail-closed: cannot verify WT matches HEAD if
#      git-status is broken (#955 Repro 2).
reset_ctl; GIT_STATUS_FAIL=1
box="$(mkbox c18-git-status-fail)"
run "$box" "$box/target" --yes
if [ "$RC" = 7 ] && ! has_call "$box" 'repo create' && ! has_call "$box" 'git .* push'; then
  ok "18 git status failure -> refuse 7, NO create or push" "(exit $RC)"
else
  no "18 git status failure -> refuse 7, NO create or push" \
     "exit=$RC(want 7) calls=[$(calls "$box")]"
fi

# ---------------------------------------------------------------------------
# TEETH (negative control). Mutate the guard two ways and prove each assertion
# above would FLIP to failure — otherwise those assertions are theater.
if [ "${1:-}" = "--prove-teeth" ]; then
  content="$(cat "$SUT")"

  # T1 — drop --private from the single `gh repo create`. Case 1's invariant
  #      ("every create line carries --private") must now be VIOLATED.
  echo "-- teeth 1: drop --private from 'gh repo create', expect a NON-private create --"
  orig1='gh repo create "$owner/$repo" --private --source "$target" --remote origin --disable-wiki'
  new1='gh repo create "$owner/$repo" --source "$target" --remote origin --disable-wiki'
  if [[ "$content" != *"$orig1"* ]]; then
    no "teeth1: build --private mutant" "create anchor not found — SUT drifted?"
  else
    reset_ctl
    box="$(mkbox teeth1-no-private)"
    printf '%s\n' "${content//"$orig1"/"$new1"}" > "$box/ensure-remote.sh"
    run "$box" "$box/target" --yes
    # here-string over a captured var (not a producer pipe) to avoid pipefail EPIPE
    # under load; -n guard preserves the empty-input semantics of `grep … | grep -v`.
    creates=$(grep 'repo create' "$box/calls.log" 2>/dev/null)
    if [ -n "$creates" ] && grep -qv -- '--private' <<<"$creates"; then
      ok "teeth1: mutant logs a create WITHOUT --private" "(case 1 has teeth)"
    else
      no "teeth1: mutant logs a create WITHOUT --private" "mutant kept --private — case 1 is THEATER; calls=[$(calls "$box")]"
    fi
  fi

  # T2 — drop the `exit 6` hard-abort so the SUT falls through and PUSHES even
  #      when visibility read back as PUBLIC. Case 2's "no push" must now be VIOLATED.
  echo "-- teeth 2: drop the exit-6 hard-abort, expect a PUSH despite PUBLIC visibility --"
  orig2='  exit 6'
  new2='  : # MUTANT: hard-abort removed, falls through to push'
  if [[ "$content" != *"$orig2"* ]]; then
    no "teeth2: build hard-abort mutant" "exit-6 anchor not found — SUT drifted?"
  else
    reset_ctl; GH_VIS=PUBLIC
    box="$(mkbox teeth2-push-public)"
    printf '%s\n' "${content//"$orig2"/"$new2"}" > "$box/ensure-remote.sh"
    run "$box" "$box/target" --yes
    if has_call "$box" 'git .* push'; then
      ok "teeth2: mutant PUSHES despite PUBLIC visibility" "(case 2 has teeth)"
    else
      no "teeth2: mutant PUSHES despite PUBLIC visibility" "mutant did NOT push — case 2 is THEATER; calls=[$(calls "$box")]"
    fi
  fi

  # T3 — drop the LAYER-4c tracked-secret-type exit-5 guard so the SUT falls
  #      through and PUSHES even with a git-TRACKED *.pem present. Case 8's
  #      "no push" must now be VIOLATED — this proves FIX-1 has teeth.
  echo "-- teeth 3: drop the LAYER-4c tracked-secret exit-5 guard, expect a PUSH despite a tracked *.pem --"
  orig3='  exit 5
fi

# --- LAYER 1 + 5: create PRIVATE, then VERIFY visibility BEFORE ANY push -----------------------------'
  new3='  : # MUTANT: tracked-secret gate exit removed, falls through to push
fi

# --- LAYER 1 + 5: create PRIVATE, then VERIFY visibility BEFORE ANY push -----------------------------'
  if [[ "$content" != *"$orig3"* ]]; then
    no "teeth3: build tracked-secret mutant" "LAYER 4c exit-5 anchor not found — SUT drifted?"
  else
    reset_ctl; GIT_TRACKED_SECRETS="secret.pem"
    box="$(mkbox teeth3-push-tracked-secret)"
    printf '%s\n' "${content//"$orig3"/"$new3"}" > "$box/ensure-remote.sh"
    run "$box" "$box/target" --yes
    if has_call "$box" 'git .* push'; then
      ok "teeth3: mutant PUSHES despite a tracked *.pem" "(case 8 / FIX-1 has teeth)"
    else
      no "teeth3: mutant PUSHES despite a tracked *.pem" "mutant did NOT push — case 8 is THEATER; calls=[$(calls "$box")]"
    fi
  fi

  # T4 — strip the exec bit from a copy of the SUT; case 13's [ -x "$SUT" ] must now
  #      be VIOLATED. Proves the exec-bit check is not theater: a non-executable copy
  #      correctly fails the assertion, matching what the tracked 100644 state produced
  #      before the fix.
  echo "-- teeth 4: strip exec bit from SUT copy, expect [ -x ] to FAIL --"
  tmp_sut="$(mktemp)"
  cp "$SUT" "$tmp_sut"
  chmod -x "$tmp_sut"
  if [ ! -x "$tmp_sut" ]; then
    ok "teeth4: non-exec mutant fails [ -x ] — case 13 has teeth"
  else
    no "teeth4: non-exec mutant still executable — case 13 is THEATER"
  fi
  rm -f "$tmp_sut"

  # T5 — drop the dirty-tree exit-8 guard so the SUT falls through and proceeds
  #      (scan → create → push) despite a dirty working tree. Case 14's "refuse 8"
  #      must now be VIOLATED — proves the dirty-tree guard has teeth.
  echo "-- teeth 5: drop dirty-tree exit-8 guard, expect proceed (not exit 8) despite dirty WT --"
  orig5='  exit 8
fi

# --- LAYER 4b: pre-push secret sweep'
  new5='  : # MUTANT: dirty-tree exit-8 removed
fi

# --- LAYER 4b: pre-push secret sweep'
  if [[ "$content" != *"$orig5"* ]]; then
    no "teeth5: build dirty-tree mutant" "exit-8 anchor not found — SUT drifted?"
  else
    reset_ctl; GIT_STATUS_DIRTY=1
    box="$(mkbox teeth5-dirty-proceeds)"
    printf '%s\n' "${content//"$orig5"/"$new5"}" > "$box/ensure-remote.sh"
    run "$box" "$box/target" --yes
    if [ "$RC" != 8 ]; then
      ok "teeth5: dirty-tree mutant proceeds (exit $RC, not 8) — case 14 has teeth"
    else
      no "teeth5: dirty-tree mutant still exits 8 — case 14 is THEATER; calls=[$(calls "$box")]"
    fi
  fi

  # M1 — neuter the case-3 (DEGRADED) branch so SCAN_EXIT=3 falls through as clean.
  #      Case 16's "refuse 7" must now FLIP to failure — proves the branch has teeth.
  echo "-- teeth M1: neuter case-3 DEGRADED branch, SCAN_EXIT=3 must NOT refuse --"
  origM1='  3) echo "REFUSED: scan-secrets.sh --committed is degraded (git unavailable or no commits) —" >&2
     echo "         cannot verify committed content before push." >&2
     exit 7 ;;'
  newM1='  3) ;; # MUTANT: degraded branch neutered'
  if [[ "$content" != *"$origM1"* ]]; then
    no "teeth-M1: build degraded-neuter mutant" "case-3 anchor not found — SUT drifted?"
  else
    reset_ctl; SCAN_EXIT=3
    box="$(mkbox teethM1-scan-deg)"
    printf '%s\n' "${content//"$origM1"/"$newM1"}" > "$box/ensure-remote.sh"
    run "$box" "$box/target" --yes
    if [ "$RC" != 7 ]; then
      ok "teeth-M1: degraded mutant proceeds (exit $RC) — case 16 has teeth"
    else
      no "teeth-M1: degraded mutant still exits 7 — case 16 is THEATER; calls=[$(calls "$box")]"
    fi
  fi

  # M2 — neuter the wildcard (*) branch so unknown scan exit codes fall through as clean.
  #      Case 17's "refuse 7" must now FLIP to failure — proves the catch-all has teeth.
  echo "-- teeth M2: neuter wildcard scan-error branch, SCAN_EXIT=2 must NOT refuse --"
  origM2='  *) echo "REFUSED: scan-secrets.sh --committed failed (exit $_scan_rc) — cannot verify committed content before push." >&2
     exit 7 ;;'
  newM2='  *) ;; # MUTANT: wildcard scan-error branch neutered'
  if [[ "$content" != *"$origM2"* ]]; then
    no "teeth-M2: build wildcard-neuter mutant" "wildcard anchor not found — SUT drifted?"
  else
    reset_ctl; SCAN_EXIT=2
    box="$(mkbox teethM2-scan-unk)"
    printf '%s\n' "${content//"$origM2"/"$newM2"}" > "$box/ensure-remote.sh"
    run "$box" "$box/target" --yes
    if [ "$RC" != 7 ]; then
      ok "teeth-M2: wildcard mutant proceeds (exit $RC) — case 17 has teeth"
    else
      no "teeth-M2: wildcard mutant still exits 7 — case 17 is THEATER; calls=[$(calls "$box")]"
    fi
  fi

  # M3 — remove the git-status failure guard so a `git status` error falls through
  #      as clean. Case 18's "refuse 7" must now FLIP — proves the fail-closed
  #      git-status check has teeth.
  echo "-- teeth M3: remove git-status failure guard, GIT_STATUS_FAIL=1 must NOT refuse 7 --"
  origM3='if ! _wt_status="$(git -C "$target" status --porcelain 2>/dev/null)"; then
  echo "REFUSED: could not check working tree status (git status --porcelain failed) — cannot" >&2
  echo "         guarantee the committed-content scan matches what would be pushed." >&2
  exit 7
fi'
  newM3='if ! _wt_status="$(git -C "$target" status --porcelain 2>/dev/null)"; then
  : # MUTANT: git-status failure guard removed
fi'
  if [[ "$content" != *"$origM3"* ]]; then
    no "teeth-M3: build git-status-fail mutant" "git-status failure guard not found — SUT drifted?"
  else
    reset_ctl; GIT_STATUS_FAIL=1
    box="$(mkbox teethM3-git-status-fail)"
    printf '%s\n' "${content//"$origM3"/"$newM3"}" > "$box/ensure-remote.sh"
    run "$box" "$box/target" --yes
    if [ "$RC" != 7 ]; then
      ok "teeth-M3: git-status-fail mutant proceeds (exit $RC) — case 18 has teeth"
    else
      no "teeth-M3: git-status-fail mutant still exits 7 — case 18 is THEATER; calls=[$(calls "$box")]"
    fi
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
