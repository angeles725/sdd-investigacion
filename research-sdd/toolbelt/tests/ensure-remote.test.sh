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
CORE_UTILS=(dirname basename tr sed grep tail mktemp cat rm env sleep)   # every external cmd the covered paths invoke
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
    printf 'BOX="%s"\n' "$box"
    cat <<'EOF'
case " $* " in
  *" rev-parse "*) exit 0 ;;
  *" remote remove "*) [ -n "${GIT_REMOTE_REMOVE_FAIL:-}" ] && exit 1; rm -f "$BOX/origin-added"; exit 0 ;;
  *" get-url "*)
    if [ -e "$BOX/origin-added" ]; then echo "https://github.com/tester/research-target.git"; exit 0; fi
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
    printf 'BOX="%s"\n' "$box"
    cat <<'EOF'
case " $* " in
  *" repo create "*) echo "create PROMPT=${GH_PROMPT_DISABLED-UNSET}" >> "$BOX/env.log"
                     [ -n "${GH_CREATE_ADDS_ORIGIN:-}" ] && : > "$BOX/origin-added"
                     [ -n "${GH_CREATE_SLEEP:-}" ] && { echo $$ >> "$BOX/stub.pids"; exec sleep "$GH_CREATE_SLEEP"; }
                     exit "${GH_CREATE_EXIT:-0}" ;;
  *" repo view "*)   [ -n "${GH_VIEW_SLEEP:-}" ] && { echo $$ >> "$BOX/stub.pids"; exec sleep "$GH_VIEW_SLEEP"; }
                     [ -n "${GH_VIEW_EXIT:-}" ] && exit "$GH_VIEW_EXIT"
                     if [ -e "$BOX/edited" ] && [ -n "${GH_VIS_AFTER_EDIT:-}" ]; then echo "$GH_VIS_AFTER_EDIT"; exit 0; fi
                     echo "${GH_VIS:-PRIVATE}"; exit 0 ;;
  *" repo edit "*)   echo "edit PROMPT=${GH_PROMPT_DISABLED-UNSET}" >> "$BOX/env.log"
                     : > "$BOX/edited"
                     [ -n "${GH_EDIT_SLEEP:-}" ] && { echo $$ >> "$BOX/stub.pids"; exec sleep "$GH_EDIT_SLEEP"; }
                     exit "${GH_EDIT_EXIT:-0}" ;;
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
  mkdir -p "$box/lib"; cp "$HERE/../lib/gh-visibility.sh" "$box/lib/gh-visibility.sh" 2>/dev/null || true
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

# reap_stubs <box> — kill any stub `sleep` a killed/hung SUT left behind (the stubs record their pid before exec).
reap_stubs() { local q; [ -f "$1/stub.pids" ] || return 0; while read -r q; do [ -n "$q" ] && kill "$q" 2>/dev/null; done < "$1/stub.pids"; : > "$1/stub.pids"; }
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

# 19 — m4: push carries --no-follow-tags to prevent annotated tag messages from being
#      pushed when push.followTags=true is set.  The calls.log must contain the flag.
reset_ctl
box="$(mkbox m4-no-follow-tags)"
run "$box" "$box/target" --yes
if [ "$RC" = 0 ] && has_call "$box" 'push .* --no-follow-tags'; then
  ok "19 m4 push carries --no-follow-tags (followTags guard)" "(exit $RC)"
else
  no "19 m4 push --no-follow-tags" "exit=$RC(want 0) calls=[$(calls "$box")]"
fi

# 20 — E1 end-to-end: ensure-remote calls the REAL scan-secrets; git-replace hides a
#      secret commit from normal rev-list (M1 scenario). With --no-replace-objects the
#      real scan detects it → ensure-remote must REFUSE (exit 5, no push logged).
SCAN_SUT="$HERE/../scan-secrets.sh"
REAL_GIT20="$(type -P git 2>/dev/null)"
if [ -z "$REAL_GIT20" ] || [ ! -f "$SCAN_SUT" ]; then
  no "20 E1 end-to-end: real git or scan-secrets unavailable — skip" ""
else
  # Build real repo with M1 scenario (secret commit hidden by git replace)
  d_E1="$ROOT/e1-repo"
  mkdir -p "$d_E1"
  git -C "$d_E1" init -q 2>/dev/null
  git -C "$d_E1" config user.email "t@t" && git -C "$d_E1" config user.name "t"
  printf '# base\n' > "$d_E1/a.md"
  git -C "$d_E1" add a.md && git -C "$d_E1" commit -q -m "base" 2>/dev/null
  printf 'token=ghp_0123456789abcdefghijklmnopqrstuvwxyz\n' > "$d_E1/n.md"
  git -C "$d_E1" add n.md && git -C "$d_E1" commit -q -m "secret" 2>/dev/null
  _bad_E1="$(git -C "$d_E1" rev-parse HEAD)"
  git -C "$d_E1" rm -q n.md && git -C "$d_E1" commit -q -m "clean" 2>/dev/null
  # shellcheck disable=SC1083  # ^{tree} is git revision syntax, not shell brace expansion
  _good_E1="$(git -C "$d_E1" commit-tree \
    "$(git -C "$d_E1" rev-parse HEAD~2^{tree})" \
    -p "$(git -C "$d_E1" rev-parse HEAD~2)" -m "secret-clean-replacement" 2>/dev/null)"
  git -C "$d_E1" replace "$_bad_E1" "$_good_E1" 2>/dev/null
  # Build hermetic box: real git + real scan-secrets + stub gh + all utils scan needs
  box_E1="$ROOT/e1-box"
  mkdir -p "$box_E1/bin" "$box_E1/home"
  cp "$SUT" "$box_E1/ensure-remote.sh"
  mkdir -p "$box_E1/lib"; cp "$HERE/../lib/gh-visibility.sh" "$box_E1/lib/gh-visibility.sh" 2>/dev/null || true
  cp "$SCAN_SUT" "$box_E1/scan-secrets.sh"
  : > "$box_E1/calls.log"
  for i in "${!CORE_UTILS[@]}"; do ln -s "${CORE_PATHS[$i]}" "$box_E1/bin/${CORE_UTILS[$i]}"; done
  ln -s "$BASH_BIN" "$box_E1/bin/bash"
  ln -s "$REAL_GIT20" "$box_E1/bin/git"
  for _b in awk wc sort head mktemp rm; do
    _bp="$(type -P "$_b" 2>/dev/null)"
    [ -n "$_bp" ] && ln -sf "$_bp" "$box_E1/bin/$_b" 2>/dev/null || true
  done
  mk_gh_stub "$box_E1"
  # shellcheck disable=SC2034  # OUT_E1 captured for debugging parity; cases assert on RC + calls.log
  OUT_E1="$(PATH="$box_E1/bin" HOME="$box_E1/home" \
    GIT_HAS_ORIGIN=0 GH_OWNER=tester GH_OWNER_TYPE=User \
    GH_CREATE_EXIT=0 GH_VIS=PRIVATE SCAN_EXIT=0 \
    GIT_TRACKED_SECRETS="" GIT_GITIGNORE_DIRTY=0 GH_USERS_EXIT=0 \
    GIT_STATUS_DIRTY=0 GIT_STATUS_FAIL=0 \
    "$BASH_BIN" "$box_E1/ensure-remote.sh" "$d_E1" --yes 2>&1)"
  RC_E1=$?
  if [ "$RC_E1" = 5 ] && ! grep -q 'push' "$box_E1/calls.log" 2>/dev/null; then
    ok "20 E1 end-to-end: real scan + git replace → ensure-remote refuses (exit 5, no push)" "(exit $RC_E1)"
  else
    no "20 E1 end-to-end: git replace M1" "exit=$RC_E1(want 5) calls=[$(cat "$box_E1/calls.log" 2>/dev/null | tr '\n' '|')]"
  fi
fi

# 21 — kit issue #1820: a STALLED `gh repo view` must not hang the visibility read-back. The probe is bounded
#      (RSDD_GH_TIMEOUT); an unreadable visibility is UNKNOWN, never PRIVATE -> the SUT HARD-ABORTS (exit 6),
#      drops origin and never pushes. The SUT runs under a harness cap so a hung (pre-fix) SUT is a FAIL, not a hang.
reset_ctl
box="$(mkbox c21-stalled-gh)"
OUT21="$box/out.txt"; T21=$SECONDS
GH_VIEW_SLEEP=30 RSDD_GH_TIMEOUT=1 PATH="$box/bin" HOME="$box/home" GIT_HAS_ORIGIN=0 GH_OWNER=tester GH_OWNER_TYPE=User \
  GH_CREATE_EXIT=0 GH_VIS=PRIVATE SCAN_EXIT=0 GIT_TRACKED_SECRETS="" GIT_GITIGNORE_DIRTY=0 GH_USERS_EXIT=0 \
  GIT_STATUS_DIRTY=0 GIT_STATUS_FAIL=0 "$BASH_BIN" "$box/ensure-remote.sh" "$box/target" --yes >"$OUT21" 2>&1 &
P21=$!
( sleep 20; kill -9 "$P21" 2>/dev/null ) >/dev/null 2>&1 &
W21=$!
wait "$P21" 2>/dev/null; RC21=$?
kill "$W21" 2>/dev/null; wait "$W21" 2>/dev/null
EL21=$((SECONDS-T21))
reap_stubs "$box"
if [ "$RC21" = 6 ] && [ "$EL21" -lt 18 ] && ! has_call "$box" 'git .* push' && grep -q 'TIMEOUT' "$OUT21"; then
  ok "21 stalled gh -> bounded, UNKNOWN != PRIVATE -> abort 6, no push" "(exit $RC21, ${EL21}s)"
else
  no "21 stalled gh -> bounded, UNKNOWN != PRIVATE -> abort 6, no push" "exit=$RC21(want 6) ${EL21}s push=$(has_call "$box" 'git .* push' && echo YES || echo no) out=[$(tr '\n' '|' <"$OUT21")]"
fi

# run_capped <box> — run the SUT with the stall knobs inherited from the caller's env prefix, under a 20 s
#   harness cap (a hung SUT is a FAIL, not a hang). Output -> $box/out.txt, exit -> RCX, elapsed seconds -> ELX.
run_capped() {
  local box="$1" t0=$SECONDS p w
  PATH="$box/bin" HOME="$box/home" GIT_HAS_ORIGIN=0 GH_OWNER=tester GH_OWNER_TYPE=User SCAN_EXIT=0 \
    GIT_TRACKED_SECRETS="" GIT_GITIGNORE_DIRTY=0 GH_USERS_EXIT=0 GIT_STATUS_DIRTY=0 GIT_STATUS_FAIL=0 \
    "$BASH_BIN" "$box/ensure-remote.sh" "$box/target" --yes >"$box/out.txt" 2>&1 &
  p=$!
  ( sleep 20; kill -9 "$p" 2>/dev/null ) >/dev/null 2>&1 &
  w=$!
  wait "$p" 2>/dev/null; RCX=$?
  kill "$w" 2>/dev/null; wait "$w" 2>/dev/null
  ELX=$((SECONDS-t0))
  reap_stubs "$box"
}

# 22 — kit issue #1841: a STALLED `gh repo create` is bounded by ITS OWN knob (RSDD_GH_CREATE_TIMEOUT), typed DEGRADED
#      with the observed PARTIAL-STATE, never a hang, never a push. Nothing created (no origin, repo not found) -> exit 7.
reset_ctl
box="$(mkbox c22-create-stall)"
GH_CREATE_SLEEP=30 RSDD_GH_CREATE_TIMEOUT=1 GH_VIEW_EXIT=1 run_capped "$box"
if [ "$RCX" = 7 ] && [ "$ELX" -lt 18 ] && ! has_call "$box" 'git .* push' && grep -q 'DEGRADED' "$box/out.txt" && grep -q 'gh repo create' "$box/out.txt" \
   && grep -q 'PARTIAL-STATE local origin=absent, remote tester/research-target visibility=UNKNOWN' "$box/out.txt" && grep -q 'PARTIAL-STATE UNKNOWN' "$box/out.txt" \
   && grep -q 'BEFORE re-running' "$box/out.txt" && ! grep -qi '(safe)' "$box/out.txt"; then
  ok "22 stalled gh repo create, nothing created -> bounded, PARTIAL-STATE named, exit 7, no push" "(exit $RCX, ${ELX}s)"
else
  no "22 stalled gh repo create, nothing created -> bounded, PARTIAL-STATE named, exit 7, no push" "exit=$RCX(want 7) ${ELX}s out=[$(tr '\n' '|' <"$box/out.txt")]"
fi
# 22f — re-run on that partial state (no stall now) is safe and completes: creates, verifies PRIVATE, pushes once.
GH_VIS=PRIVATE run_capped "$box"
if [ "$RCX" = 0 ] && [ "$(grep -c 'git .* push' "$box/calls.log")" = 1 ]; then ok "22f re-run after a nothing-created timeout -> completes, exactly one push" "(exit $RCX)"
else no "22f re-run after a nothing-created timeout -> completes, exactly one push" "exit=$RCX out=[$(tr '\n' '|' <"$box/out.txt")]"; fi

# 22h — create timed out AFTER adding the origin and the visibility CANNOT be read -> typed UNKNOWN, origin REMOVED, no push,
#       no "safe" re-run advice.
reset_ctl
box="$(mkbox c22h-origin-unknown)"
GH_CREATE_ADDS_ORIGIN=1 GH_CREATE_SLEEP=30 RSDD_GH_CREATE_TIMEOUT=1 GH_VIEW_EXIT=1 run_capped "$box"
if [ "$RCX" = 7 ] && ! has_call "$box" 'git .* push' && has_call "$box" 'git .* remote remove origin' && grep -q 'PARTIAL-STATE UNKNOWN' "$box/out.txt" \
   && grep -q 'BEFORE re-running' "$box/out.txt" && ! grep -qi '(safe)' "$box/out.txt"; then
  ok "22h origin added + visibility unreadable -> UNKNOWN, origin removed, no push, no safe-rerun claim" "(exit $RCX)"
else no "22h origin added + visibility unreadable -> UNKNOWN, origin removed, no push" "exit=$RCX out=[$(tr '\n' '|' <"$box/out.txt")]"; fi

# 22i — kit issue #1854: the same UNKNOWN path, but the origin removal FAILS -> the origin is still configured, so the
#       script must say so (typed ORIGIN-LEFT line naming the url), must NOT claim it was removed, still refuses 7, no push.
reset_ctl
box="$(mkbox c22i-origin-left)"
GIT_REMOTE_REMOVE_FAIL=1 GH_CREATE_ADDS_ORIGIN=1 GH_CREATE_SLEEP=30 RSDD_GH_CREATE_TIMEOUT=1 GH_VIEW_EXIT=1 run_capped "$box"
if [ "$RCX" = 7 ] && ! has_call "$box" 'git .* push' && has_call "$box" 'git .* remote remove origin' \
   && grep -q 'PARTIAL-STATE ORIGIN-LEFT: .*https://github.com/tester/research-target.git' "$box/out.txt" \
   && ! grep -q 'any local origin was removed' "$box/out.txt" && grep -q 'BEFORE re-running' "$box/out.txt"; then
  ok "22i origin removal fails -> typed ORIGIN-LEFT naming the url, no 'removed' claim, exit 7, no push" "(exit $RCX)"
else no "22i origin removal fails -> typed ORIGIN-LEFT naming the url, no 'removed' claim, exit 7, no push" "exit=$RCX out=[$(tr '\n' '|' <"$box/out.txt")]"; fi

# 22j — kit issue #1854: the create-timeout DEGRADED line carries the watchdog's typed GHV_NOTE (the hermetic box has no
#       timeout/setsid, so the bound is the child-only watchdog and the lib says so).
reset_ctl
box="$(mkbox c22j-create-note)"
GH_CREATE_SLEEP=30 RSDD_GH_CREATE_TIMEOUT=1 GH_VIEW_EXIT=1 run_capped "$box"
ctx="$(grep -A1 'gh repo create timed out' "$box/out.txt")"
if [ "$RCX" = 7 ] && grep -q 'DEGRADED: no setsid' <<<"$ctx"; then
  ok "22j create-timeout DEGRADED line is followed by the watchdog's GHV_NOTE" "(exit $RCX)"
else no "22j create-timeout DEGRADED line is followed by the watchdog's GHV_NOTE" "exit=$RCX ctx=[$(tr '\n' '|' <<<"$ctx")]"; fi

# 22k — kit issue #1854: the edit-timeout DEGRADED line carries GHV_NOTE too.
reset_ctl
box="$(mkbox c22k-edit-note)"
GH_VIS=PUBLIC GH_EDIT_SLEEP=30 RSDD_GH_TIMEOUT=1 run_capped "$box"
ctx="$(grep -A1 'gh repo edit timed out' "$box/out.txt")"
if [ "$RCX" = 6 ] && grep -q 'DEGRADED: no setsid' <<<"$ctx"; then
  ok "22k edit-timeout DEGRADED line is followed by the watchdog's GHV_NOTE" "(exit $RCX)"
else no "22k edit-timeout DEGRADED line is followed by the watchdog's GHV_NOTE" "exit=$RCX ctx=[$(tr '\n' '|' <<<"$ctx")]"; fi

# 22l — kit issue #1854: the exit-6 hard abort checks its origin removal too: a failed removal -> typed ORIGIN-LEFT naming the
#       url, no "removing" claim as fact, still exit 6, no push.
reset_ctl
box="$(mkbox c22l-abort-origin-left)"
GIT_REMOTE_REMOVE_FAIL=1 GH_CREATE_ADDS_ORIGIN=1 GH_VIS=PUBLIC run_capped "$box"
if [ "$RCX" = 6 ] && ! has_call "$box" 'git .* push' && has_call "$box" 'git .* remote remove origin' \
   && grep -q 'PARTIAL-STATE ORIGIN-LEFT: .*https://github.com/tester/research-target.git' "$box/out.txt" \
   && ! grep -q 'Removing the origin remote' "$box/out.txt"; then
  ok "22l hard abort + origin removal fails -> typed ORIGIN-LEFT naming the url, exit 6, no push" "(exit $RCX)"
else no "22l hard abort + origin removal fails -> typed ORIGIN-LEFT naming the url, exit 6, no push" "exit=$RCX out=[$(tr '\n' '|' <"$box/out.txt")]"; fi

# 22b — create timed out AFTER adding the local origin, repo is PRIVATE -> the existing repo is adopted: verified, then pushed.
reset_ctl
box="$(mkbox c22b-origin-private)"
GH_CREATE_ADDS_ORIGIN=1 GH_CREATE_SLEEP=30 RSDD_GH_CREATE_TIMEOUT=1 GH_VIS=PRIVATE run_capped "$box"
if [ "$RCX" = 0 ] && has_call "$box" 'git .* push' && grep -q 'PARTIAL-STATE local origin=configured, remote tester/research-target visibility=PRIVATE' "$box/out.txt"; then
  ok "22b origin added + repo PRIVATE -> adopted, pushed, exit 0" "(exit $RCX, ${ELX}s)"
else
  no "22b origin added + repo PRIVATE -> adopted, pushed, exit 0" "exit=$RCX out=[$(tr '\n' '|' <"$box/out.txt")]"
fi
# 22b2 — and a re-run on the adopted state is the idempotent no-op (origin already set, no second create/push).
GH_VIS=PRIVATE run_capped "$box"
if [ "$RCX" = 0 ] && grep -q 'origin already set' "$box/out.txt" && [ "$(grep -c 'repo create' "$box/calls.log")" = 1 ] && [ "$(grep -c 'git .* push' "$box/calls.log")" = 1 ]; then
  ok "22b2 re-run on the adopted state -> idempotent no-op" "(exit $RCX)"
else no "22b2 re-run on the adopted state -> idempotent no-op" "exit=$RCX out=[$(tr '\n' '|' <"$box/out.txt")]"; fi

# 22c — origin added + repo PUBLIC -> HARD ABORT 6, origin removed, NEVER a push; a re-run starts clean (no stale origin).
reset_ctl
box="$(mkbox c22c-origin-public)"
GH_CREATE_ADDS_ORIGIN=1 GH_CREATE_SLEEP=30 RSDD_GH_CREATE_TIMEOUT=1 GH_VIS=PUBLIC run_capped "$box"
if [ "$RCX" = 6 ] && ! has_call "$box" 'git .* push' && has_call "$box" 'git .* remote remove origin' \
   && grep -q 'PARTIAL-STATE local origin=configured, remote tester/research-target visibility=PUBLIC' "$box/out.txt" && grep -q 'DELETE IT MANUALLY' "$box/out.txt"; then
  ok "22c origin added + repo PUBLIC -> abort 6, origin removed, no push" "(exit $RCX, ${ELX}s)"
else
  no "22c origin added + repo PUBLIC -> abort 6, origin removed, no push" "exit=$RCX out=[$(tr '\n' '|' <"$box/out.txt")]"
fi
GH_VIS=PUBLIC run_capped "$box"
if [ "$RCX" = 6 ] && ! has_call "$box" 'git .* push' && ! grep -q 'origin already set' "$box/out.txt"; then
  ok "22c2 re-run on a still-PUBLIC repo -> aborts 6 again, never pushes, never short-circuits on a stale origin" "(exit $RCX)"
else no "22c2 re-run on a still-PUBLIC repo -> aborts 6 again, never pushes" "exit=$RCX out=[$(tr '\n' '|' <"$box/out.txt")]"; fi

# 22d — create timed out, repo exists PRIVATE but the local origin was NOT added -> exit 7 with the exact manual step, no push.
reset_ctl
box="$(mkbox c22d-noorigin-private)"
GH_CREATE_SLEEP=30 RSDD_GH_CREATE_TIMEOUT=1 GH_VIS=PRIVATE run_capped "$box"
if [ "$RCX" = 7 ] && ! has_call "$box" 'git .* push' && grep -q 'PARTIAL-STATE local origin=absent, remote tester/research-target visibility=PRIVATE' "$box/out.txt" \
   && grep -q 'remote add origin https://github.com/tester/research-target.git' "$box/out.txt"; then
  ok "22d no origin + repo PRIVATE -> exit 7, exact manual next step, no push" "(exit $RCX)"
else no "22d no origin + repo PRIVATE -> exit 7, exact manual next step, no push" "exit=$RCX out=[$(tr '\n' '|' <"$box/out.txt")]"; fi

# 22e — create timed out, repo exists PUBLIC (no local origin) -> abort 6, no push.
reset_ctl
box="$(mkbox c22e-noorigin-public)"
GH_CREATE_SLEEP=30 RSDD_GH_CREATE_TIMEOUT=1 GH_VIS=PUBLIC run_capped "$box"
if [ "$RCX" = 6 ] && ! has_call "$box" 'git .* push' && grep -q 'PARTIAL-STATE local origin=absent, remote tester/research-target visibility=PUBLIC' "$box/out.txt" && grep -q 'DELETE IT MANUALLY' "$box/out.txt"; then
  ok "22e no origin + repo PUBLIC -> abort 6, no push" "(exit $RCX)"
else no "22e no origin + repo PUBLIC -> abort 6, no push" "exit=$RCX out=[$(tr '\n' '|' <"$box/out.txt")]"; fi

# 22g — the create bound is its OWN knob: RSDD_GH_TIMEOUT=1 (the probe's) does NOT cut a 3 s create (default 60 s);
#       a garbage RSDD_GH_CREATE_TIMEOUT falls back to the default with a note.
reset_ctl
box="$(mkbox c22g-create-knob)"
GH_CREATE_SLEEP=3 RSDD_GH_TIMEOUT=1 RSDD_GH_CREATE_TIMEOUT=abc GH_VIS=PRIVATE run_capped "$box"
if [ "$RCX" = 0 ] && has_call "$box" 'git .* push' && grep -q "RSDD_GH_CREATE_TIMEOUT='abc' is not a positive integer — using the default 60s" "$box/out.txt"; then
  ok "22g create uses RSDD_GH_CREATE_TIMEOUT (default 60), not the probe's RSDD_GH_TIMEOUT; garbage -> default + note" "(exit $RCX, ${ELX}s)"
else no "22g create uses RSDD_GH_CREATE_TIMEOUT (default 60), not the probe's RSDD_GH_TIMEOUT" "exit=$RCX ${ELX}s out=[$(tr '\n' '|' <"$box/out.txt")]"; fi

# 23 — kit issue #1841: a STALLED `gh repo edit` is bounded and typed DEGRADED, visibility is RE-READ after it
#      (no assumption the edit did or did not land); still PUBLIC -> HARD-ABORT 6, no push.
reset_ctl
box="$(mkbox c23-edit-stall-public)"
GH_VIS=PUBLIC GH_EDIT_SLEEP=30 RSDD_GH_TIMEOUT=1 run_capped "$box"
if [ "$RCX" = 6 ] && [ "$ELX" -lt 18 ] && ! has_call "$box" 'git .* push' && grep -q 'DEGRADED' "$box/out.txt" \
   && grep -q 'gh repo edit' "$box/out.txt" && [ "$(grep -c 'gh repo view' "$box/calls.log")" -ge 2 ]; then
  ok "23 stalled gh repo edit -> bounded, DEGRADED, re-read, still PUBLIC -> abort 6" "(exit $RCX, ${ELX}s)"
else
  no "23 stalled gh repo edit -> bounded, DEGRADED, re-read, still PUBLIC -> abort 6" "exit=$RCX(want 6) ${ELX}s out=[$(tr '\n' '|' <"$box/out.txt")]"
fi

# 24 — kit issue #1841: the edit timed out but LANDED (re-read says PRIVATE) -> the re-read, not the timeout, decides: push.
reset_ctl
box="$(mkbox c24-edit-stall-landed)"
GH_VIS=PUBLIC GH_VIS_AFTER_EDIT=PRIVATE GH_EDIT_SLEEP=30 RSDD_GH_TIMEOUT=1 run_capped "$box"
if [ "$RCX" = 0 ] && has_call "$box" 'git .* push' && grep -q 'DEGRADED' "$box/out.txt"; then
  ok "24 edit timed out but landed (re-read PRIVATE) -> pushes, exit 0" "(exit $RCX, ${ELX}s)"
else
  no "24 edit timed out but landed (re-read PRIVATE) -> pushes, exit 0" "exit=$RCX(want 0) out=[$(tr '\n' '|' <"$box/out.txt")]"
fi

# 25 — kit issue #1841: create and edit run with GH_PROMPT_DISABLED=1 (even when the caller exported 0).
reset_ctl
box="$(mkbox c25-prompt-disabled)"
GH_PROMPT_DISABLED=0 GH_VIS=PUBLIC GH_VIS_AFTER_EDIT=PRIVATE run_capped "$box"
if [ "$RCX" = 0 ] && grep -qx 'create PROMPT=1' "$box/env.log" && grep -qx 'edit PROMPT=1' "$box/env.log"; then
  ok "25 gh repo create/edit run with GH_PROMPT_DISABLED=1" "(exit $RCX)"
else
  no "25 gh repo create/edit run with GH_PROMPT_DISABLED=1" "exit=$RCX env.log=[$(tr '\n' '|' <"$box/env.log" 2>/dev/null)]"
fi

# 26 — a fast-failing `gh repo create` stays the old refusal (exit 7), not reported as a timeout.
reset_ctl
box="$(mkbox c26-create-fails)"
GH_CREATE_EXIT=1 run_capped "$box"
if [ "$RCX" = 7 ] && grep -q 'gh repo create failed' "$box/out.txt" && ! grep -q 'timed out' "$box/out.txt"; then
  ok "26 failing gh repo create -> exit 7, not reported as a timeout" "(exit $RCX)"
else
  no "26 failing gh repo create -> exit 7, not reported as a timeout" "exit=$RCX out=[$(tr '\n' '|' <"$box/out.txt")]"
fi

# ---------------------------------------------------------------------------
# TEETH (negative control). Mutate the guard two ways and prove each assertion
# above would FLIP to failure — otherwise those assertions are theater.
if [ "${1:-}" = "--prove-teeth" ]; then
  content="$(cat "$SUT")"
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  declare -F mutant_built >/dev/null 2>&1 || { echo "FATAL: lib/mutant.sh did not define mutant_built" >&2; exit 2; }
  # mut_sub LABEL ORIG NEW OUT — bash-substitute ORIG→NEW in the SUT text into OUT, then vet OUT with
  # lib/mutant.sh (refuses an identical, empty, syntax-broken or live-tree mutant). A refusal records a
  # FAIL and the run STOPS (mk_or_stop pattern), so a tooth never runs on a refused mutant path.
  mut_sub() {
    printf '%s\n' "${content//"$2"/"$3"}" > "$4"
    mutant_built "$1 mutant build" "$SUT" "$4" && return 0
    no "$1: mutant refused by lib/mutant.sh" "tooth not run"
    echo "== $pass passed · $fail failed =="; exit 1
  }

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
    mut_sub "teeth1" "$orig1" "$new1" "$box/ensure-remote.sh"
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
    mut_sub "teeth2" "$orig2" "$new2" "$box/ensure-remote.sh"
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
    mut_sub "teeth3" "$orig3" "$new3" "$box/ensure-remote.sh"
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
    mut_sub "teeth5" "$orig5" "$new5" "$box/ensure-remote.sh"
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
    mut_sub "teeth-M1" "$origM1" "$newM1" "$box/ensure-remote.sh"
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
    mut_sub "teeth-M2" "$origM2" "$newM2" "$box/ensure-remote.sh"
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
    mut_sub "teeth-M3" "$origM3" "$newM3" "$box/ensure-remote.sh"
    run "$box" "$box/target" --yes
    if [ "$RC" != 7 ]; then
      ok "teeth-M3: git-status-fail mutant proceeds (exit $RC) — case 18 has teeth"
    else
      no "teeth-M3: git-status-fail mutant still exits 7 — case 18 is THEATER; calls=[$(calls "$box")]"
    fi
  fi

  # m4 — remove --no-follow-tags from push: case 19's calls.log must NO LONGER carry the flag.
  echo "-- teeth m4: remove --no-follow-tags from push — case 19 must go red --"
  origm4='git -C "$target" push -u origin HEAD --no-follow-tags || { echo "REFUSED: push failed." >&2; exit 7; }'
  newm4='git -C "$target" push -u origin HEAD || { echo "REFUSED: push failed." >&2; exit 7; }'
  if [[ "$content" != *"$origm4"* ]]; then
    no "teeth-m4: build no-follow-tags mutant" "--no-follow-tags anchor not found — SUT drifted?"
  else
    reset_ctl
    box="$(mkbox teeth-m4-no-follow-tags)"
    mut_sub "teeth-m4" "$origm4" "$newm4" "$box/ensure-remote.sh"
    run "$box" "$box/target" --yes
    if [ "$RC" = 0 ] && ! has_call "$box" 'push .* --no-follow-tags'; then
      ok "teeth-m4: --no-follow-tags-removed mutant push lacks flag → case 19 has teeth"
    else
      no "teeth-m4: mutant still carries --no-follow-tags (rc=$RC) — case 19 is THEATER; calls=[$(calls "$box")]"
    fi
  fi

  # T6 (kit issue #1820) — revert read_vis to the pre-fix UNBOUNDED probe; case 21's stalled gh must now hang
  #      (killed by the harness cap) instead of aborting 6 — proves the bound is what case 21 pins.
  echo "-- teeth 21: unbounded read_vis, expect case 21's stalled gh to HANG (harness-killed) --"
  orig21='read_vis() { if gh_visibility_probe gh "$owner/$repo"; then printf '"'"'%s'"'"' "$GHV_STATE"; else printf '"'"'UNKNOWN(%s)'"'"' "$GHV_STATE"; fi; }'
  new21='read_vis() { gh repo view "$owner/$repo" --json visibility -q .visibility 2>/dev/null | tr '"'"'[:lower:]'"'"' '"'"'[:upper:]'"'"'; }'
  if [[ "$content" != *"$orig21"* ]]; then
    no "teeth21: build unbounded-probe mutant" "read_vis anchor not found — SUT drifted?"
  else
    reset_ctl
    box="$(mkbox teeth21-unbounded)"
    mut_sub "teeth21" "$orig21" "$new21" "$box/ensure-remote.sh"
    GH_VIEW_SLEEP=30 RSDD_GH_TIMEOUT=1 PATH="$box/bin" HOME="$box/home" GIT_HAS_ORIGIN=0 GH_OWNER=tester GH_OWNER_TYPE=User \
      GH_CREATE_EXIT=0 GH_VIS=PRIVATE SCAN_EXIT=0 GIT_TRACKED_SECRETS="" GIT_GITIGNORE_DIRTY=0 GH_USERS_EXIT=0 \
      GIT_STATUS_DIRTY=0 GIT_STATUS_FAIL=0 "$BASH_BIN" "$box/ensure-remote.sh" "$box/target" --yes >"$box/out.txt" 2>&1 &
    PT=$!
    ( sleep 8; kill -9 "$PT" 2>/dev/null ) >/dev/null 2>&1 &
    WT=$!
    wait "$PT" 2>/dev/null; RCT=$?
    kill "$WT" 2>/dev/null; wait "$WT" 2>/dev/null
    reap_stubs "$box"
    if [ "$RCT" = 137 ]; then ok "teeth21: unbounded probe hangs (killed rc=137) — case 21 has teeth"
    else no "teeth21: unbounded mutant did not hang (rc=$RCT) — case 21 is THEATER"; fi
  fi

  # teeth 22-24 (kit issue #1841) — each mutant is run through the SAME run_capped as cases 22/23 on a box whose SUT
  #      copy is the mutant; the case's invariant must now be VIOLATED.
  # teeth_box LABEL ORIG NEW — fresh box named after LABEL, SUT copy replaced by the vetted mutant. Sets TBOX.
  teeth_box() {
    local b; reset_ctl; b="$ROOT/$1"; mkbox "$1" >/dev/null
    mut_sub "$1" "$2" "$3" "$b/ensure-remote.sh"
    TBOX="$b"
  }
  origC='GHV_BOUND_DEFAULT=60 gh_bounded_run gh repo create'
  origE='if ! gh_bounded_run gh repo edit'
  if [[ "$content" != *"$origC"* || "$content" != *"$origE"* ]]; then
    no "teeth22/23: build unbounded create/edit mutants" "gh_bounded_run anchors not found — SUT drifted?"
  else
    echo "-- teeth 22: unbounded gh repo create, expect case 22's stalled create to HANG (harness-killed) --"
    teeth_box teeth22-create-unbounded "$origC" 'GHV_BOUND_DEFAULT=60 gh repo create'; box="$TBOX"
    GH_CREATE_SLEEP=30 RSDD_GH_CREATE_TIMEOUT=1 run_capped "$box"
    if [ "$RCX" = 137 ]; then ok "teeth22: unbounded create hangs (killed rc=137) — case 22 has teeth"
    else no "teeth22: unbounded create did not hang (rc=$RCX) — case 22 is THEATER"; fi
    echo "-- teeth 23: unbounded gh repo edit, expect case 23's stalled edit to HANG (harness-killed) --"
    teeth_box teeth23-edit-unbounded "$origE" 'if ! gh repo edit'; box="$TBOX"
    GH_VIS=PUBLIC GH_EDIT_SLEEP=30 RSDD_GH_TIMEOUT=1 run_capped "$box"
    if [ "$RCX" = 137 ]; then ok "teeth23: unbounded edit hangs (killed rc=137) — case 23 has teeth"
    else no "teeth23: unbounded edit did not hang (rc=$RCX) — case 23 is THEATER"; fi
  fi

  # T10 — trust the edit without re-reading (vis=PRIVATE after the edit): case 23's still-PUBLIC repo must now be PUSHED.
  echo "-- teeth 24: assume the edit landed (no re-read), expect a PUSH to a still-PUBLIC repo --"
  origR=$'  fi\n  vis="$(read_vis)"\nfi'
  newR=$'  fi\n  vis=PRIVATE\nfi'
  if [[ "$content" != *"$origR"* ]]; then
    no "teeth24: build no-reread mutant" "re-read anchor not found — SUT drifted?"
  else
    teeth_box teeth24-no-reread "$origR" "$newR"; box="$TBOX"
    GH_VIS=PUBLIC GH_EDIT_SLEEP=30 RSDD_GH_TIMEOUT=1 run_capped "$box"
    if has_call "$box" 'git .* push'; then ok "teeth24: without the re-read a PUBLIC repo is pushed — case 23 has teeth"
    else no "teeth24: mutant did not push (rc=$RCX) — case 23 is THEATER"; fi
  fi

  # teeth 25 — adopt a timed-out create WITHOUT verifying: treat origin=configured as PRIVATE (skip the guard). A PUBLIC
  #   repo with an added origin must now be PUSHED (case 22c's invariant violated).
  echo "-- teeth 25: adopt the timed-out create unverified, expect a PUSH to a PUBLIC repo --"
  origA=$'    echo "   next: local origin is configured'
  if [[ "$content" != *"$origA"* ]]; then
    no "teeth25: build adopt-unverified mutant" "adopt anchor not found — SUT drifted?"
  else
    teeth_box teeth25-adopt-unverified "$origA" $'    vis=PRIVATE; skip_guard=1\n    echo "   next: local origin is configured'; box="$TBOX"
    # the guard below compares "$vis"; recompute it only when skip_guard is unset
    printf '%s\n' "$(sed 's|^vis="\$(read_vis)"$|[ -n "${skip_guard:-}" ] \|\| vis="$(read_vis)"|' "$box/ensure-remote.sh")" > "$box/ensure-remote.sh"
    GH_CREATE_ADDS_ORIGIN=1 GH_CREATE_SLEEP=30 RSDD_GH_CREATE_TIMEOUT=1 GH_VIS=PUBLIC run_capped "$box"
    if has_call "$box" 'git .* push'; then ok "teeth25: an unverified adopt pushes a PUBLIC repo — case 22c has teeth"
    else no "teeth25: mutant did not push (rc=$RCX) — case 22c is THEATER"; fi
  fi

  # teeth 26 — a create timeout with NO origin and a PUBLIC repo falls to the generic exit 7 instead of the hard abort 6.
  echo "-- teeth 26: no-origin PUBLIC repo is not a hard abort, expect exit != 6 --"
  origP=$'      *)\n        echo "!! HARD ABORT: a non-private repo ($tvis)'
  if [[ "$content" != *"$origP"* ]]; then
    no "teeth26: build public-not-aborted mutant" "PUBLIC anchor not found — SUT drifted?"
  else
    teeth_box teeth26-public-soft "$origP" $'      *)\n        exit 7\n        echo "!! HARD ABORT: a non-private repo ($tvis)'; box="$TBOX"
    GH_CREATE_SLEEP=30 RSDD_GH_CREATE_TIMEOUT=1 GH_VIS=PUBLIC run_capped "$box"
    if [ "$RCX" != 6 ]; then ok "teeth26: soft-failing a PUBLIC repo loses abort 6 — case 22e has teeth"
    else no "teeth26: mutant still aborts 6 — case 22e is THEATER"; fi
  fi

  # teeth 28 — the UNKNOWN branch keeps the origin (drop the removal): case 22h must go red.
  echo "-- teeth 28: UNKNOWN partial state keeps the origin, expect no 'remote remove origin' --"
  origU='if ! git -C "$target" remote remove origin >/dev/null 2>&1; then origin_left=1; fi'
  if [[ "$content" != *"$origU"* ]]; then
    no "teeth28: build keep-origin mutant" "UNKNOWN anchor not found — SUT drifted?"
  else
    teeth_box teeth28-unknown-keeps-origin "$origU" ':'; box="$TBOX"
    GH_CREATE_ADDS_ORIGIN=1 GH_CREATE_SLEEP=30 RSDD_GH_CREATE_TIMEOUT=1 GH_VIEW_EXIT=1 run_capped "$box"
    if ! has_call "$box" 'git .* remote remove origin'; then ok "teeth28: without the removal the origin stays — case 22h has teeth"
    else no "teeth28: origin still removed under the mutant — case 22h is THEATER"; fi
  fi
  # teeth 29 — the UNKNOWN branch is dead (falls through to adopt/safe-rerun wording): case 22 must go red.
  echo "-- teeth 29: UNKNOWN branch dead, expect the 'PARTIAL-STATE UNKNOWN' line to vanish --"
  origV='    UNKNOWN*)
      # Visibility could not be read'
  if [[ "$content" != *"$origV"* ]]; then
    no "teeth29: build dead-unknown mutant" "UNKNOWN case anchor not found — SUT drifted?"
  else
    teeth_box teeth29-unknown-dead "$origV" $'    NEVERMATCH_UNKNOWN)\n      # Visibility could not be read'; box="$TBOX"
    GH_CREATE_SLEEP=30 RSDD_GH_CREATE_TIMEOUT=1 GH_VIEW_EXIT=1 run_capped "$box"
    if ! grep -q 'PARTIAL-STATE UNKNOWN' "$box/out.txt"; then ok "teeth29: without the UNKNOWN branch the typed state is lost — case 22 has teeth"
    else no "teeth29: UNKNOWN line still printed — case 22 is THEATER"; fi
  fi

  # teeth 30 (kit issue #1854) — the removal's exit status is ignored again (message claims removal): case 22i must go red.
  echo "-- teeth 30: removal failure ignored, expect the ORIGIN-LEFT line to vanish --"
  origR='if ! git -C "$target" remote remove origin >/dev/null 2>&1; then'
  if [[ "$content" != *"$origR"* ]]; then
    no "teeth30: build ignored-removal mutant" "removal-check anchor not found — SUT drifted?"
  else
    teeth_box teeth30-removal-unchecked "$origR" 'git -C "$target" remote remove origin >/dev/null 2>&1 || :; if false; then'; box="$TBOX"
    GIT_REMOTE_REMOVE_FAIL=1 GH_CREATE_ADDS_ORIGIN=1 GH_CREATE_SLEEP=30 RSDD_GH_CREATE_TIMEOUT=1 GH_VIEW_EXIT=1 run_capped "$box"
    if ! grep -q 'PARTIAL-STATE ORIGIN-LEFT' "$box/out.txt"; then ok "teeth30: an unchecked removal loses the typed leftover line — case 22i has teeth"
    else no "teeth30: ORIGIN-LEFT still printed under the mutant — case 22i is THEATER"; fi
  fi

  # teeth 31-33 (kit issue #1854, review round)
  echo "-- teeth 31: create-timeout note dropped, expect case 22j to go red --"
  origN='[ -n "${GHV_NOTE:-}" ] && echo "   $GHV_NOTE" >&2'
  if [[ "$content" != *"$origN"* ]]; then
    no "teeth31: build dropped-note mutant" "create-note anchor not found — SUT drifted?"
  else
    teeth_box teeth31-create-note-dropped "$origN" ':'; box="$TBOX"
    GH_CREATE_SLEEP=30 RSDD_GH_CREATE_TIMEOUT=1 GH_VIEW_EXIT=1 run_capped "$box"
    if ! grep -A1 'gh repo create timed out' "$box/out.txt" | grep -q 'DEGRADED: no setsid'; then ok "teeth31: without the print the note is lost — case 22j has teeth"
    else no "teeth31: note still printed under the mutant — case 22j is THEATER"; fi
  fi
  echo "-- teeth 32: edit-timeout note dropped, expect case 22k to go red --"
  origM='if [ -n "${GHV_NOTE:-}" ]; then echo "   $GHV_NOTE" >&2; fi'
  if [[ "$content" != *"$origM"* ]]; then
    no "teeth32: build dropped-edit-note mutant" "edit-note anchor not found — SUT drifted?"
  else
    teeth_box teeth32-edit-note-dropped "$origM" ':'; box="$TBOX"
    GH_VIS=PUBLIC GH_EDIT_SLEEP=30 RSDD_GH_TIMEOUT=1 run_capped "$box"
    if ! grep -A1 'gh repo edit timed out' "$box/out.txt" | grep -q 'DEGRADED: no setsid'; then ok "teeth32: without the print the edit note is lost — case 22k has teeth"
    else no "teeth32: note still printed under the mutant — case 22k is THEATER"; fi
  fi
  echo "-- teeth 33: abort-path removal status ignored, expect the ORIGIN-LEFT line to vanish (case 22l) --"
  origA='>/dev/null 2>&1; abort_rm_rc=$?'
  if [[ "$content" != *"$origA"* ]]; then
    no "teeth33: build ignored-abort-removal mutant" "abort-removal anchor not found — SUT drifted?"
  else
    teeth_box teeth33-abort-removal-unchecked "$origA" '>/dev/null 2>&1; abort_rm_rc=0'; box="$TBOX"
    GIT_REMOTE_REMOVE_FAIL=1 GH_CREATE_ADDS_ORIGIN=1 GH_VIS=PUBLIC run_capped "$box"
    if ! grep -q 'PARTIAL-STATE ORIGIN-LEFT' "$box/out.txt"; then ok "teeth33: an unchecked abort-path removal loses the typed line — case 22l has teeth"
    else no "teeth33: ORIGIN-LEFT still printed under the mutant — case 22l is THEATER"; fi
  fi

  # teeth 27 — the create bound reuses the probe's knob (RSDD_GH_TIMEOUT): case 22g's 3 s create must now be cut off.
  echo "-- teeth 27: create bound taken from RSDD_GH_TIMEOUT, expect case 22g's create to time out --"
  origK='GHV_BOUND_ENV=RSDD_GH_CREATE_TIMEOUT GHV_BOUND_DEFAULT=60 gh_bounded_run gh repo create'
  if [[ "$content" != *"$origK"* ]]; then
    no "teeth27: build shared-knob mutant" "create knob anchor not found — SUT drifted?"
  else
    teeth_box teeth27-shared-knob "$origK" 'gh_bounded_run gh repo create'; box="$TBOX"
    GH_CREATE_SLEEP=3 RSDD_GH_TIMEOUT=1 GH_VIS=PRIVATE run_capped "$box"
    if [ "$RCX" != 0 ]; then ok "teeth27: a shared knob cuts the 3 s create (exit $RCX) — case 22g has teeth"
    else no "teeth27: create still completes under the mutant — case 22g is THEATER"; fi
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
