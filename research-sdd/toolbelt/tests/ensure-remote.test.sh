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
REAL_GIT="$(type -P git)"; [ -n "$REAL_GIT" ] || { echo "FATAL: git not found on PATH" >&2; exit 2; }
CORE_UTILS=(dirname basename tr sed grep tail mktemp cat rm env sleep od)   # every external cmd the covered paths invoke
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
    printf 'REALGIT="%s"\n' "$REAL_GIT"
    cat <<'EOF'
case " $* " in
  *" rev-parse "*) exit 0 ;;
  # History queries (Layer 4c allow list, kit issue #1943). In a box whose target is a REAL repo they go to the
  # real git; otherwise they are faked: `log` reports one blob per queried path and `cat-file` serves the
  # target's worktree file for it (a missing file makes cat-file fail, as a missing object would).
  *" log "*|*" cat-file "*)
    if [ -d "$BOX/target/.git" ]; then exec "$REALGIT" "$@"; fi
    case " $* " in
      *" log "*)
        p="${@: -1}"; n=$(( $(cat "$BOX/blobn" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$BOX/blobn"
        sha="$(printf '%040x' "$n")"; printf '%s\n' "$p" > "$BOX/blob.$sha"
        printf ':100644 100644 %040d %s M\t%s\n' 0 "$sha" "$p"; exit 0 ;;
      *)
        sha="${@: -1}"; p="$(cat "$BOX/blob.$sha")" || exit 1
        cat "$BOX/target/$p" || exit 1; exit 0 ;;
    esac ;;
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
# sut_is_exec is the SAME predicate teeth 4 mutates against (kit issue #1576: tooth 4 used to re-test `chmod`
# with an inline [ -x ], so a regression in case 13's own predicate could not turn it red).
sut_is_exec() { [ -x "$1" ]; }
if sut_is_exec "$SUT"; then
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
# 27+ — kit issue #1943: LAYER 4c explicit ALLOW list (<target>/.research-sdd/secret-files.conf, `allow <glob>`).
#   Allowed matches are REPORTED (never silent), an entry that matches nothing is STALE, a malformed line is a
#   typed config error (exit 2), and private-key bytes inside an allowed path are NEVER allowable (exit 5).
CONF_REL=".research-sdd/secret-files.conf"
nl=$'\n'
# put_conf BOX LINE... — write the allow list (one argument per line).
put_conf() { local box="$1"; shift; mkdir -p "$box/target/.research-sdd"; printf '%s\n' "$@" > "$box/target/$CONF_REL"; }
# hexfile HEX — write the bytes spelled by a hex string to stdout (byte-literal, hermetic fixtures).
hexfile() { printf "$(printf '%s' "$1" | sed 's/../\\x&/g')"; }
# put_pub BOX REL KIND — fixture bytes at REL under the target.
#   KIND: spki | pkcs8 | pkcs8s | sec1 | pkcs1 | pempub | pempriv | pemenc
put_pub() {
  local box="$1" rel="$2" kind="$3"; mkdir -p "$(dirname "$box/target/$rel")"
  case "$kind" in
    spki)    hexfile 3015300d06092a864886f70d0101010500030400deadbe > "$box/target/$rel";;
    pkcs8)   printf '\x30\x82\x04\xbd\x02\x01\x00\x30\x0d\x06\x09\x2a\x86\x48\x86\xf7\x0d\x01\x01\x01' > "$box/target/$rel";;
    pkcs8s)  printf '\x30\x2e\x02\x01\x00\x30\x05\x06\x03\x2b\x65\x70\x04\x22\x04\x20' > "$box/target/$rel";;
    sec1)    printf '\x30\x77\x02\x01\x01\x04\x20\x11\x22\x33' > "$box/target/$rel";;
    pkcs1)   printf '\x30\x82\x04\xa4\x02\x01\x00\x02\x82\x01\x01\x00' > "$box/target/$rel";;
    pempub)  printf -- '-----BEGIN PUBLIC KEY-----\nMFkwEwYH\n-----END PUBLIC KEY-----\n' > "$box/target/$rel";;
    pempriv) printf -- '-----BEGIN RSA PRIVATE KEY-----\nMIIEow\n-----END RSA PRIVATE KEY-----\n' > "$box/target/$rel";;
    ed25519) hexfile 302a300506032b6570032100aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa > "$box/target/$rel";;
    cert)    hexfile 30133008a003020102020101300306012a030200ab > "$box/target/$rel";;
    certv1)  hexfile 30133008a003020100020101300306012a030200ab > "$box/target/$rel";;
    encpk8)  hexfile 301b300f06092a864886f70d01050d300205000408aabbccddeeff0011 > "$box/target/$rel";;
    p12)     hexfile 3082010a020103308201023082006d06092a864886f70d010701a0 > "$box/target/$rel";;
    jks)     hexfile feedfeed000000020000000100000001 > "$box/target/$rel";;
    gpgsec)  hexfile 95010d0400a1b2c3d4e5f60001020304 > "$box/target/$rel";;
    badoid)  hexfile 3015300d06092a864886f70d0101050500030400deadbe > "$box/target/$rel";;
    nulonly) hexfile 4d4954204c6963656e736500746578740a > "$box/target/$rel";;
    ctrl)    printf 'MIT License\001 text\n' > "$box/target/$rel";;
    secrettxt) printf 'MIT License\nthis file carries a SECRET value\n' > "$box/target/$rel";;
    ppk)     printf 'PuTTY-User-Key-File-3: ssh-ed25519\nEncryption: none\nComment: x\nPublic-Lines: 1\nAAAAC3Nza\nPrivate-Lines: 1\nAAAAIB\nPrivate-MAC: ab\n' > "$box/target/$rel";;
    age)     printf '# created: 2026\nAGE-SECRET-KEY-1QQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQ\n' > "$box/target/$rel";;
    ssh2)    printf -- '---- BEGIN SSH2 ENCRYPTED PRIVATE KEY ----\nProc-Type: 4,ENCRYPTED\nAAAA\n---- END SSH2 ENCRYPTED PRIVATE KEY ----\n' > "$box/target/$rel";;
    rawb64)  printf 'MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgabcdefghijklmnop\nqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrs\n' > "$box/target/$rel";;
    licence) printf 'MIT License\n\nCopyright (c) 2026 Example\n\nPermission is hereby granted, free of charge, to any person obtaining a copy.\n' > "$box/target/$rel";;
    pemcert) printf -- '-----BEGIN CERTIFICATE-----\nMIIBkTCB\n-----END CERTIFICATE-----\n' > "$box/target/$rel";;
    pemmixed) printf -- '-----BEGIN CERTIFICATE-----\nMIIBkTCB\n-----END CERTIFICATE-----\n-----BEGIN EC PARAMETERS-----\nBggq\n-----END EC PARAMETERS-----\n' > "$box/target/$rel";;
    pemenc)  printf -- '-----BEGIN ENCRYPTED PRIVATE KEY-----\nMIIFH\n-----END ENCRYPTED PRIVATE KEY-----\n' > "$box/target/$rel";;
  esac
}
outl() { tr '\n' '|' <<<"$OUT"; }

# 27 — SINGLE allowed public key: exits 0, pushes, and the allow is REPORTED as a typed ALLOWED line.
reset_ctl; GIT_TRACKED_SECRETS="pub.der"
box="$(mkbox c27-allow-single)"; put_conf "$box" "allow pub.der"; put_pub "$box" pub.der spki
run "$box" "$box/target" --yes
if [ "$RC" = 0 ] && has_call "$box" 'git .* push' && grep -q '^ALLOWED: pub.der ' <<<"$OUT"; then
  ok "27 single allowed public DER -> push, ALLOWED line reported" "(exit $RC)"
else no "27 single allowed public DER -> push, ALLOWED line reported" "exit=$RC out=[$(outl)]"; fi

# 28 — list edges (FIRST / MIDDLE / LAST / ALL) over three tracked secret-type files. Each un-allowed position is
#      refused (exit 5, no push) and named; the other two are still reported ALLOWED.
files=(a.der dir/b.pem c.key)
for pos in 0 1 2; do
  reset_ctl; GIT_TRACKED_SECRETS="${files[0]}${nl}${files[1]}${nl}${files[2]}"
  box="$(mkbox c28-edge-$pos)"; lines=()
  for i in 0 1 2; do
    put_pub "$box" "${files[$i]}" pempub
    [ "$i" = "$pos" ] || lines+=("allow ${files[$i]}")
  done
  put_conf "$box" "${lines[@]}"
  run "$box" "$box/target" --yes
  want="${files[$pos]}"
  if [ "$RC" = 5 ] && ! has_call "$box" 'git .* push' && grep -q "^REFUSED: .*${want}" <<<"$OUT" \
     && [ "$(grep -c '^ALLOWED: ' <<<"$OUT")" = 2 ]; then
    ok "28 only position $pos un-allowed -> refuse 5 naming ${want}, 2 ALLOWED" "(exit $RC)"
  else no "28 only position $pos un-allowed -> refuse 5 naming ${want}, 2 ALLOWED" "exit=$RC out=[$(outl)]"; fi
done
reset_ctl; GIT_TRACKED_SECRETS="${files[0]}${nl}${files[1]}${nl}${files[2]}"
box="$(mkbox c28-edge-all)"
for f in "${files[@]}"; do put_pub "$box" "$f" pempub; done
put_conf "$box" "allow a.der" "allow dir/b.pem" "allow c.key"
run "$box" "$box/target" --yes
if [ "$RC" = 0 ] && has_call "$box" 'git .* push' && [ "$(grep -c '^ALLOWED: ' <<<"$OUT")" = 3 ]; then
  ok "28 all three allowed -> push, 3 ALLOWED lines" "(exit $RC)"
else no "28 all three allowed -> push, 3 ALLOWED lines" "exit=$RC out=[$(outl)]"; fi

# 29 — allow is per path/glob, never a blanket: one allowed file leaves an unrelated tracked secret refused.
reset_ctl; GIT_TRACKED_SECRETS="pub.der${nl}other.pem"
box="$(mkbox c29-not-blanket)"; put_conf "$box" "allow pub.der"; put_pub "$box" pub.der spki; put_pub "$box" other.pem pempub
run "$box" "$box/target" --yes
if [ "$RC" = 5 ] && ! has_call "$box" 'git .* push' && grep -q '^REFUSED: .*other.pem' <<<"$OUT" && ! grep -q '^REFUSED: .*pub.der' <<<"$OUT"; then
  ok "29 unrelated tracked secret stays refused (allow is not a blanket)" "(exit $RC)"
else no "29 unrelated tracked secret stays refused (allow is not a blanket)" "exit=$RC out=[$(outl)]"; fi

# 30 — STALE entries (FIRST / MIDDLE / LAST / SINGLE position) are reported once, never fatal, never silent.
for spec in "first:allow gone1.der|allow pub.der" "middle:allow pub.der|allow gone1.der|allow pub.der" \
            "last:allow pub.der|allow gone1.der" "single:allow gone1.der"; do
  lab="${spec%%:*}"; body="${spec#*:}"; IFS='|' read -r -a conflines <<<"$body"
  reset_ctl; GIT_TRACKED_SECRETS="pub.der"
  [ "$lab" = single ] && GIT_TRACKED_SECRETS=""
  box="$(mkbox c30-stale-$lab)"; put_conf "$box" "${conflines[@]}"; put_pub "$box" pub.der spki
  run "$box" "$box/target" --yes
  if [ "$RC" = 0 ] && grep -q '^STALE: .*gone1.der' <<<"$OUT" && [ "$(grep -c '^STALE: ' <<<"$OUT")" = 1 ]; then
    ok "30 stale allow entry ($lab) reported once, run continues" "(exit $RC)"
  else no "30 stale allow entry ($lab) reported once, run continues" "exit=$RC out=[$(outl)]"; fi
done

# 31 — MALFORMED lines are typed config errors (exit 2, line number named, NO repo create), at FIRST / MIDDLE / LAST / SINGLE.
bad31=0; n31=0
for bad in "allow" "deny x.der" "allow a.der b.der" "allow *" "allow **/*" "allow ../x.der" "allow /abs/x.der" "frob" \
           'allow *[!/]' 'allow [!/]*' 'allow *.*' 'allow !(zz)' 'allow @(*)' 'allow +(a)' 'allow a[bc].der' 'allow ?(x).der'; do
  for where in first middle last single; do
    reset_ctl; GIT_TRACKED_SECRETS="pub.der"; n31=$((n31+1))
    box="$(mkbox "c31-$where-${bad//[^a-z]/_}")"; put_pub "$box" pub.der spki
    case "$where" in
      first)  put_conf "$box" "$bad" "allow pub.der" "# c"; ln_no=1;;
      middle) put_conf "$box" "allow pub.der" "$bad" "# c"; ln_no=2;;
      last)   put_conf "$box" "# c" "allow pub.der" "$bad"; ln_no=3;;
      single) put_conf "$box" "$bad"; ln_no=1;;
    esac
    run "$box" "$box/target" --yes
    if [ "$RC" = 2 ] && grep -q "secret-files.conf:$ln_no: " <<<"$OUT" && ! has_call "$box" 'repo create'; then :; else
      bad31=$((bad31+1)); no "31 malformed '$bad' ($where) -> exit 2 naming line $ln_no, no create" "exit=$RC out=[$(outl)]"
    fi
  done
done
[ "$bad31" = 0 ] && ok "31 malformed lines (16 shapes x first/middle/last/single = $n31) -> exit 2 naming the line, no repo create"

# 32 — a private key can NEVER be allowed: PEM private (plain + encrypted), DER PKCS#8 (long + short), SEC1, PKCS#1.
for kind in pempriv pemenc pkcs8 pkcs8s sec1 pkcs1; do
  reset_ctl; GIT_TRACKED_SECRETS="k.der"
  box="$(mkbox c32-priv-$kind)"; put_conf "$box" "allow k.der"; put_pub "$box" k.der "$kind"
  run "$box" "$box/target" --yes
  if [ "$RC" = 5 ] && ! has_call "$box" 'git .* push' && grep -q '^REFUSED: .*private key' <<<"$OUT" && ! grep -q '^ALLOWED: k.der' <<<"$OUT"; then
    ok "32 private key ($kind) in an allowed path -> refuse 5, never ALLOWED" "(exit $RC)"
  else no "32 private key ($kind) in an allowed path -> refuse 5, never ALLOWED" "exit=$RC out=[$(outl)]"; fi
done
# 32b — a private key in the LAST of several allowed files still refuses (list edge).
reset_ctl; GIT_TRACKED_SECRETS="a.der${nl}b.der${nl}c.der"
box="$(mkbox c32-priv-last)"; put_conf "$box" "allow *.der"
put_pub "$box" a.der spki; put_pub "$box" b.der spki; put_pub "$box" c.der pkcs8
run "$box" "$box/target" --yes
if [ "$RC" = 5 ] && ! has_call "$box" 'git .* push' && grep -q '^REFUSED: .*c.der' <<<"$OUT"; then
  ok "32b private key in the LAST allowed file -> refuse 5" "(exit $RC)"
else no "32b private key in the LAST allowed file -> refuse 5" "exit=$RC out=[$(outl)]"; fi

# 33 — an allowed path that cannot be read (listed by git, absent on disk) cannot be verified -> fail closed, exit 7.
reset_ctl; GIT_TRACKED_SECRETS="ghost.der"
box="$(mkbox c33-unreadable)"; put_conf "$box" "allow ghost.der"
run "$box" "$box/target" --yes
if [ "$RC" = 7 ] && ! has_call "$box" 'git .* push'; then
  ok "33 allowed path unreadable -> fail closed 7, no push" "(exit $RC)"
else no "33 allowed path unreadable -> fail closed 7, no push" "exit=$RC out=[$(outl)]"; fi

# 34 — comments/blank lines accepted; glob crosses '/' like git's pathspec; a root licenses/ dir is allowable too.
reset_ctl; GIT_TRACKED_SECRETS="licenses/lic.txt${nl}deep/x/pub.der"
box="$(mkbox c34-globs)"; put_conf "$box" "# public assets" "" "allow licenses/*" "   allow   *.der   "
put_pub "$box" licenses/lic.txt pempub; put_pub "$box" deep/x/pub.der spki
run "$box" "$box/target" --yes
if [ "$RC" = 0 ] && [ "$(grep -c '^ALLOWED: ' <<<"$OUT")" = 2 ]; then
  ok "34 comments/blanks/globs accepted (licenses/*, *.der)" "(exit $RC)"
else no "34 comments/blanks/globs accepted (licenses/*, *.der)" "exit=$RC out=[$(outl)]"; fi

# 35 — a comments-only allow list allows nothing: the tracked secret is still refused.
reset_ctl; GIT_TRACKED_SECRETS="pub.der"
box="$(mkbox c35-empty-conf)"; put_conf "$box" "# nothing allowed"; put_pub "$box" pub.der spki
run "$box" "$box/target" --yes
if [ "$RC" = 5 ] && ! has_call "$box" 'git .* push'; then
  ok "35 comments-only allow list allows nothing -> refuse 5" "(exit $RC)"
else no "35 comments-only allow list allows nothing -> refuse 5" "exit=$RC out=[$(outl)]"; fi

# 36 — keystore / identity file TYPES hold private keys by construction: never allowable, whatever their bytes.
for nm in store.p12 id.pfx app.jks my.keystore id_rsa; do
  reset_ctl; GIT_TRACKED_SECRETS="$nm"
  box="$(mkbox "c36-$nm")"; put_conf "$box" "allow $nm"; put_pub "$box" "$nm" pempub
  run "$box" "$box/target" --yes
  if [ "$RC" = 5 ] && ! has_call "$box" 'git .* push' && grep -q "^REFUSED: .*${nm}" <<<"$OUT"; then
    ok "36 keystore/identity type ($nm) is never allowable -> refuse 5" "(exit $RC)"
  else no "36 keystore/identity type ($nm) is never allowable -> refuse 5" "exit=$RC out=[$(outl)]"; fi
done

# 37 — POSITIVE identification (kit issue #1943 follow-up): only material positively identified as public is honoured.
#      Real public material -> ALLOWED: PEM cert / PEM public key / DER cert / DER SPKI (RSA + Ed25519) / licence text.
for spec in "x.pem:pemcert" "x.pem:pempub" "x.der:cert" "x.der:certv1" "x.der:spki" "x.der:ed25519" "licenses/LICENSE:licence"; do
  rel="${spec%%:*}"; kind="${spec#*:}"
  reset_ctl; GIT_TRACKED_SECRETS="$rel"
  box="$(mkbox "c37-pos-$kind")"; put_conf "$box" "allow $rel"; put_pub "$box" "$rel" "$kind"
  run "$box" "$box/target" --yes
  if [ "$RC" = 0 ] && has_call "$box" 'git .* push' && grep -q "^ALLOWED: $rel " <<<"$OUT"; then
    ok "37 positively public ($kind) -> ALLOWED, push" "(exit $RC)"
  else no "37 positively public ($kind) -> ALLOWED, push" "exit=$RC out=[$(outl)]"; fi
done

# 38 — everything else is refused as NOT POSITIVELY PUBLIC (exit 5, no push), the path named on a typed line.
for spec in "x.der:encpk8" "x.der:p12" "security/ks:jks" "security/secring.gpg:gpgsec" "k.key:rawb64" "x.pem:pemmixed" \
            "x.der:badoid" "licenses/n.txt:nulonly" "licenses/c.txt:ctrl" "licenses/s.txt:secrettxt" \
            "x.der:ppk" "k.key:age" "k.key:ssh2" "x.pem:pempriv"; do
  rel="${spec%%:*}"; kind="${spec#*:}"
  reset_ctl; GIT_TRACKED_SECRETS="$rel"
  box="$(mkbox "c38-neg-$kind")"; put_conf "$box" "allow $rel"; put_pub "$box" "$rel" "$kind"
  run "$box" "$box/target" --yes
  if [ "$RC" = 5 ] && ! has_call "$box" 'git .* push' && ! grep -q '^ALLOWED: ' <<<"$OUT" && grep -q "^REFUSED.*: .*$rel" <<<"$OUT"; then
    case "$kind" in encpk8|p12|jks|gpgsec|rawb64|pemmixed|badoid|nulonly|ctrl|secrettxt)
      grep -q "^REFUSED (not positively public): $rel" <<<"$OUT" || no "38 $kind refused with the typed 'not positively public' line" "out=[$(outl)]";; esac
    ok "38 non-public material ($kind) refused -> exit 5, no push" "(exit $RC)"
  else no "38 non-public material ($kind) refused -> exit 5, no push" "exit=$RC out=[$(outl)]"; fi
done

# rgit BOX ARGS... — the REAL git inside a box (history queries from the SUT also reach real git there).
rgit() { local b="$1"; shift; GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 "$REAL_GIT" -C "$b/target" -c user.name=t -c user.email=t@t "$@"; }
# real_commit BOX REL KIND — commit fixture bytes at REL.
real_commit() { put_pub "$1" "$2" "$3"; rgit "$1" add -- "$2" >/dev/null 2>&1; rgit "$1" commit -q -m "c $3" >/dev/null 2>&1; }

# 39 — HISTORY: EVERY committed blob of an allowed path must be public, whatever the worktree says now. A private key
#      committed FIRST / in the MIDDLE / LAST of three revisions is refused even though the worktree looks public.
for pos in 0 1 2; do
  reset_ctl; GIT_TRACKED_SECRETS="k.der"
  box="$(mkbox "c39-hist-$pos")"; rgit "$box" init -q >/dev/null 2>&1; put_conf "$box" "allow k.der"
  kinds=(cert cert cert); kinds[pos]=pkcs8
  for kd in "${kinds[@]}"; do real_commit "$box" k.der "$kd"; done
  put_pub "$box" k.der cert
  run "$box" "$box/target" --yes
  if [ "$RC" = 5 ] && ! has_call "$box" 'git .* push' && grep -q '^REFUSED.*k.der' <<<"$OUT" && ! grep -q '^ALLOWED: ' <<<"$OUT"; then
    ok "39 private blob in history (revision $pos of 3) -> refuse 5" "(exit $RC)"
  else no "39 private blob in history (revision $pos of 3) -> refuse 5" "exit=$RC out=[$(outl)]"; fi
done
# 39b — private committed, then OVERWRITTEN by a public cert in a later commit (the C1 shape) -> refuse.
reset_ctl; GIT_TRACKED_SECRETS="k.der"
box="$(mkbox c39b-overwrite)"; rgit "$box" init -q >/dev/null 2>&1; put_conf "$box" "allow k.der"
real_commit "$box" k.der pkcs8; real_commit "$box" k.der cert
run "$box" "$box/target" --yes
if [ "$RC" = 5 ] && ! has_call "$box" 'git .* push'; then ok "39b private-then-public overwrite -> refuse 5" "(exit $RC)"
else no "39b private-then-public overwrite -> refuse 5" "exit=$RC out=[$(outl)]"; fi
# 39c — the same with `update-index --assume-unchanged` hiding a public-looking worktree edit.
reset_ctl; GIT_TRACKED_SECRETS="k.der"
box="$(mkbox c39c-assume-unchanged)"; rgit "$box" init -q >/dev/null 2>&1; put_conf "$box" "allow k.der"
real_commit "$box" k.der pkcs8; rgit "$box" update-index --assume-unchanged k.der; put_pub "$box" k.der cert
run "$box" "$box/target" --yes
if [ "$RC" = 5 ] && ! has_call "$box" 'git .* push'; then ok "39c assume-unchanged hiding a private blob -> refuse 5" "(exit $RC)"
else no "39c assume-unchanged hiding a private blob -> refuse 5" "exit=$RC out=[$(outl)]"; fi
# 39d — all revisions public -> ALLOWED (the history check does not over-refuse).
reset_ctl; GIT_TRACKED_SECRETS="k.der"
box="$(mkbox c39d-hist-public)"; rgit "$box" init -q >/dev/null 2>&1; put_conf "$box" "allow k.der"
real_commit "$box" k.der cert; real_commit "$box" k.der spki
run "$box" "$box/target" --yes
if [ "$RC" = 0 ] && grep -q '^ALLOWED: k.der ' <<<"$OUT"; then ok "39d every revision public -> ALLOWED" "(exit $RC)"
else no "39d every revision public -> ALLOWED" "exit=$RC out=[$(outl)]"; fi
# 39e — a git failure while reading history fails closed (exit 7): .git exists but is not a repository.
reset_ctl; GIT_TRACKED_SECRETS="k.der"
box="$(mkbox c39e-git-fails)"; mkdir -p "$box/target/.git"; put_conf "$box" "allow k.der"; put_pub "$box" k.der cert
run "$box" "$box/target" --yes
if [ "$RC" = 7 ] && ! has_call "$box" 'git .* push'; then ok "39e history read fails -> fail closed 7" "(exit $RC)"
else no "39e history read fails -> fail closed 7" "exit=$RC out=[$(outl)]"; fi

# 41 — a path that is tracked in the stub's view but has NO committed blob in the real history cannot be verified: exit 7.
reset_ctl; GIT_TRACKED_SECRETS="k.der"
box="$(mkbox c41-no-blob)"; rgit "$box" init -q >/dev/null 2>&1; put_conf "$box" "allow k.der"
real_commit "$box" other.txt licence; put_pub "$box" k.der cert
run "$box" "$box/target" --yes
if [ "$RC" = 7 ] && ! has_call "$box" 'git .* push'; then ok "41 allowed path with no committed blob -> fail closed 7" "(exit $RC)"
else no "41 allowed path with no committed blob -> fail closed 7" "exit=$RC out=[$(outl)]"; fi

# 40 — REAL openssl artefacts (skipped, typed, when openssl is absent; cases 37-39 keep the core hermetic).
OPENSSL_BIN="$(type -P openssl || true)"
if [ -z "$OPENSSL_BIN" ]; then
  echo "  SKIP  40 real openssl artefacts (openssl not on PATH) — cases 37-39 carry the byte-literal fixtures"
else
  osd="$ROOT/openssl-fixtures"; mkdir -p "$osd"
  if "$OPENSSL_BIN" req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout "$osd/ec.key" -out "$osd/cert.pem" \
       -subj /CN=t -days 2 >/dev/null 2>&1 \
     && "$OPENSSL_BIN" x509 -in "$osd/cert.pem" -outform DER -out "$osd/cert.der" >/dev/null 2>&1 \
     && "$OPENSSL_BIN" pkey -in "$osd/ec.key" -pubout -out "$osd/pub.pem" >/dev/null 2>&1 \
     && "$OPENSSL_BIN" pkey -in "$osd/ec.key" -pubout -outform DER -out "$osd/pub.der" >/dev/null 2>&1 \
     && "$OPENSSL_BIN" pkey -in "$osd/ec.key" -outform DER -out "$osd/priv8.der" >/dev/null 2>&1 \
     && "$OPENSSL_BIN" pkcs8 -topk8 -in "$osd/ec.key" -outform DER -v2 aes-256-cbc -passout pass:x -out "$osd/enc8.der" >/dev/null 2>&1 \
     && "$OPENSSL_BIN" pkcs12 -export -inkey "$osd/ec.key" -in "$osd/cert.pem" -passout pass:x -out "$osd/bundle.p12" >/dev/null 2>&1; then
    for spec in "x.pem:cert.pem:0" "x.der:cert.der:0" "x.pem:pub.pem:0" "x.der:pub.der:0" \
                "x.der:priv8.der:5" "x.der:enc8.der:5" "x.der:bundle.p12:5" "x.key:ec.key:5"; do
      IFS=: read -r rel src want <<<"$spec"
      reset_ctl; GIT_TRACKED_SECRETS="$rel"
      box="$(mkbox "c40-${src//./-}")"; put_conf "$box" "allow $rel"; mkdir -p "$(dirname "$box/target/$rel")"; cp "$osd/$src" "$box/target/$rel"
      run "$box" "$box/target" --yes
      if [ "$RC" = "$want" ]; then ok "40 openssl $src as $rel -> exit $want" "(exit $RC)"
      else no "40 openssl $src as $rel -> exit $want" "exit=$RC out=[$(outl)]"; fi
    done
  else
    echo "  SKIP  40 real openssl artefacts (openssl could not generate the fixtures) — cases 37-39 carry the byte-literal fixtures"
  fi
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
  # Control: the unmutated copy must satisfy case 13's predicate (the predicate can say yes), AND the stripped copy
  # must make that SAME predicate say no (it can say no). Both halves use sut_is_exec, not an inline test.
  if sut_is_exec "$SUT" && ! sut_is_exec "$tmp_sut"; then
    ok "teeth4: case 13's predicate passes the real SUT and rejects the non-exec mutant — case 13 has teeth"
  else
    no "teeth4: case 13's predicate cannot tell exec from non-exec — case 13 is THEATER"
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
    ctx="$(grep -A1 'gh repo create timed out' "$box/out.txt")"
    if ! grep -q 'DEGRADED: no setsid' <<<"$ctx"; then ok "teeth31: without the print the note is lost — case 22j has teeth"
    else no "teeth31: note still printed under the mutant — case 22j is THEATER"; fi
  fi
  echo "-- teeth 32: edit-timeout note dropped, expect case 22k to go red --"
  origM='if [ -n "${GHV_NOTE:-}" ]; then echo "   $GHV_NOTE" >&2; fi'
  if [[ "$content" != *"$origM"* ]]; then
    no "teeth32: build dropped-edit-note mutant" "edit-note anchor not found — SUT drifted?"
  else
    teeth_box teeth32-edit-note-dropped "$origM" ':'; box="$TBOX"
    GH_VIS=PUBLIC GH_EDIT_SLEEP=30 RSDD_GH_TIMEOUT=1 run_capped "$box"
    ctx="$(grep -A1 'gh repo edit timed out' "$box/out.txt")"
    if ! grep -q 'DEGRADED: no setsid' <<<"$ctx"; then ok "teeth32: without the print the edit note is lost — case 22k has teeth"
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

  # teeth 40-49 (kit issue #1943) — each mutant removes ONE rule of the Layer-4c allow list; the case that pins that
  # rule must now be VIOLATED. tooth_allow LABEL ORIG NEW TRACKED FILEKIND CONF... -> RC/OUT/box of the mutant run.
  tooth_allow() {
    local lab="$1" orig="$2" new="$3" tracked="$4" kind="$5" f; shift 5
    if [[ "$content" != *"$orig"* ]]; then no "$lab: build mutant" "anchor not found — SUT drifted?"; return 1; fi
    teeth_box "$lab" "$orig" "$new"; box="$TBOX"
    GIT_TRACKED_SECRETS="$tracked"; put_conf "$box" "$@"
    for f in $tracked; do put_pub "$box" "$f" "$kind"; done
    run "$box" "$box/target" --yes; return 0
  }
  echo "-- teeth 40-49: remove one allow-list rule at a time, expect the pinning case to go red --"
  tooth_allow teeth40-allow-never-matches 'if [[ $_p == ${allow_globs[$_i]} ]]; then' 'if false; then' pub.der spki "allow pub.der" \
    && { [ "$RC" != 0 ] && ok "teeth40: allow that never matches -> allowed file refused — case 27 has teeth" \
         || no "teeth40: mutant still pushes (rc=$RC) — case 27 is THEATER"; }
  # The explicit private markers are a second line behind positive identification: with one removed the file is still
  # refused (not positively public) but the typed PRIVATE-KEY refusal of case 32 is lost.
  tooth_allow teeth41-pem-marker-off "grep -aEq -- 'PRIVATE KEY( BLOCK)?-----|AGE-SECRET-KEY|PuTTY-User-Key-File|---- BEGIN SSH2' \"\$f\"" "grep -aEq -- 'NEVER-MATCHES-xyz' \"\$f\"" k.der pempriv "allow k.der" \
    && { ! grep -q '^REFUSED: .*private key' <<<"$OUT" && ok "teeth41: private-marker check off -> typed private-key refusal lost — case 32 has teeth" \
         || no "teeth41: mutant still reports the private-key refusal (rc=$RC) — case 32 (PEM) is THEATER"; }
  tooth_allow teeth42-der-marker-off '020100*|020101*) return 1;; esac' '020100*|020101*) :;; esac' k.der pkcs8 "allow k.der" \
    && { ! grep -q '^REFUSED: .*private key' <<<"$OUT" && ok "teeth42: DER PKCS#8 marker off -> typed private-key refusal lost — case 32 has teeth" \
         || no "teeth42: mutant still reports the private-key refusal (rc=$RC) — case 32 (DER) is THEATER"; }
  tooth_allow teeth43-stale-silent '[ "${allow_hit[$_i]}" = 1 ] ||' 'true ||' pub.der spki "allow gone1.der" \
    && { ! grep -q '^STALE: ' <<<"$OUT" && ok "teeth43: stale reporting off -> no STALE line — case 30 has teeth" \
         || no "teeth43: mutant still reports STALE — case 30 is THEATER"; }
  tooth_allow teeth44-malformed-accepted 'if [ -n "$_why" ]; then' 'if false; then' pub.der spki "deny pub.der" \
    && { [ "$RC" != 2 ] && ok "teeth44: malformed line accepted -> no exit 2 — case 31 has teeth" \
         || no "teeth44: mutant still exits 2 — case 31 is THEATER"; }
  tooth_allow teeth45-blanket-accepted "elif [ -z \"\$(printf '%s' \"\$_g\" | tr -d '[]!()@+|*?/.')\" ]; then" 'elif false; then' pub.der spki "allow *" \
    && { [ "$RC" != 2 ] && ok "teeth45: blanket glob accepted -> no exit 2 — case 31 (allow *) has teeth" \
         || no "teeth45: mutant still exits 2 — case 31 (allow *) is THEATER"; }
  tooth_allow teeth46-allowed-silent '*)      echo "ALLOWED:' '*)      : "ALLOWED:' pub.der spki "allow pub.der" \
    && { ! grep -q '^ALLOWED: ' <<<"$OUT" && ok "teeth46: ALLOWED reporting off -> silent allow — case 27 has teeth" \
         || no "teeth46: mutant still reports ALLOWED — case 27 is THEATER"; }
  tooth_allow teeth47-catfile-fail-open 'if ! git -C "$target" cat-file blob "$_new" >"$_tmp" 2>/dev/null; then' 'git -C "$target" cat-file blob "$_new" >"$_tmp" 2>/dev/null; if false; then' ghost.der none "allow ghost.der" \
    && { [ "$RC" != 7 ] && ok "teeth47: cat-file failure ignored -> no fail-closed 7 (rc=$RC) — case 33 has teeth" \
         || no "teeth47: mutant still fails closed 7 — case 33 is THEATER"; }
  tooth_allow teeth48-blanket-allow 'unallowed="$unallowed $_p"; continue; fi' ': ; continue; fi' $'pub.der\nother.pem' spki "allow pub.der" \
    && { [ "$RC" = 0 ] && ok "teeth48: un-allowed tracked secret ignored -> pushed — case 29 has teeth" \
         || no "teeth48: mutant still refuses (rc=$RC) — case 29 is THEATER"; }
  tooth_allow teeth49-keystore-name 'id_rsa*|*.p12|*.pfx|*.jks|*.keystore) priv_bad=' 'id_rsa*|NEVER-xyz) priv_bad=' store.p12 pempub "allow store.p12" \
    && { [ "$RC" = 0 ] && ok "teeth49: keystore type check off -> a .p12 is pushed — case 36 has teeth" \
         || no "teeth49: mutant still refuses (rc=$RC) — case 36 is THEATER"; }

  # teeth 50-60 (positive identification, history, W3 globs). Each removes ONE rule; the pinning case must go red.
  tooth_allow teeth50-oid-allowlist-off '2a864886f70d010101|2a8648ce3d0201|2b6570|2b6571|2b656e|2b656f) :;; *) return 1;; esac' '*) :;; esac' x.der badoid "allow x.der" \
    && { [ "$RC" = 0 ] && ok "teeth50: SPKI OID allow-list off -> unknown-algorithm DER pushed — case 38 (badoid) has teeth" \
         || no "teeth50: mutant still refuses (rc=$RC) — case 38 (badoid) is THEATER"; }
  tooth_allow teeth51-pem-exclusive-off '[ "$n_all" -gt 0 ] && [ "$n_all" = "$n_ok" ] && [ "$e_all" = "$e_ok" ] && [ "$n_ok" = "$e_ok" ] || return 1' '[ "$n_ok" -gt 0 ] || return 1' x.pem pemmixed "allow x.pem" \
    && { [ "$RC" = 0 ] && ok "teeth51: PEM exclusivity off -> a PEM with foreign armour is pushed — case 38 (pemmixed) has teeth" \
         || no "teeth51: mutant still refuses (rc=$RC) — case 38 (pemmixed) is THEATER"; }
  tooth_allow teeth52-nul-check-off '[ "${#hn}" = "${#h}" ] || return 1' ':' licenses/n.txt nulonly "allow licenses/n.txt" \
    && { [ "$RC" = 0 ] && ok "teeth52: NUL check off -> binary 'licence' pushed — case 38 (nulonly) has teeth" \
         || no "teeth52: mutant still refuses (rc=$RC) — case 38 (nulonly) is THEATER"; }
  tooth_allow teeth53-ctrl-check-off "LC_ALL=C grep -aq \$'[\\001-\\010\\013\\014\\016-\\037\\177]' \"\$f\"" "LC_ALL=C grep -aq 'NEVER-xyz' \"\$f\"" licenses/c.txt ctrl "allow licenses/c.txt" \
    && { [ "$RC" = 0 ] && ok "teeth53: control-byte check off -> binary 'licence' pushed — case 38 (ctrl) has teeth" \
         || no "teeth53: mutant still refuses (rc=$RC) — case 38 (ctrl) is THEATER"; }
  tooth_allow teeth54-base64-line-off "grep -aEq -- '^[A-Za-z0-9+/=]{64,}'\$'\\r''?\$' \"\$f\"" "grep -aEq -- 'NEVER-xyz' \"\$f\"" k.key rawb64 "allow k.key" \
    && { [ "$RC" = 0 ] && ok "teeth54: base64-body check off -> unarmoured key pushed — case 38 (rawb64) has teeth" \
         || no "teeth54: mutant still refuses (rc=$RC) — case 38 (rawb64) is THEATER"; }
  tooth_allow teeth55-text-marker-off "grep -aEq -- 'PRIVATE|SECRET|---- BEGIN|PuTTY-User-Key-File' \"\$f\"" "grep -aEq -- 'NEVER-xyz' \"\$f\"" licenses/s.txt secrettxt "allow licenses/s.txt" \
    && { [ "$RC" = 0 ] && ok "teeth55: text-marker check off -> 'SECRET' licence pushed — case 38 (secrettxt) has teeth" \
         || no "teeth55: mutant still refuses (rc=$RC) — case 38 (secrettxt) is THEATER"; }
  tooth_allow teeth56-bracket-off "elif [[ \"\$_g\" == *'['* || \"\$_g\" == *']'* ]]; then" 'elif false; then' pub.der spki 'allow a[bc].der' \
    && { [ "$RC" != 2 ] && ok "teeth56: bracket-class check off -> no exit 2 — case 31 (a[bc].der) has teeth" \
         || no "teeth56: mutant still exits 2 — case 31 (bracket) is THEATER"; }
  tooth_allow teeth57-extglob-off "elif [[ \"\$_g\" == *'!('* ||" "elif [[ \"\$_g\" == *'NEVERX'* ||" pub.der spki 'allow !(zz)' \
    && { [ "$RC" != 2 ] && ok "teeth57: extglob check off -> no exit 2 — case 31 (!(zz)) has teeth" \
         || no "teeth57: mutant still exits 2 — case 31 (extglob) is THEATER"; }
  tooth_allow teeth58-dot-literal-off "tr -d '[]!()@+|*?/.')" "tr -d '[]!()@+|*?/')" pub.der spki 'allow *.*' \
    && { [ "$RC" != 2 ] && ok "teeth58: '.' counted as literal -> *.* accepted — case 31 (*.*) has teeth" \
         || no "teeth58: mutant still exits 2 — case 31 (*.*) is THEATER"; }
  # teeth 59/60 — history: scan only the newest commit; accept a path that has no committed blob.
  if [[ "$content" != *'log --all -m --no-renames'* ]]; then no "teeth59: build mutant" "history anchor not found — SUT drifted?"
  else
    teeth_box teeth59-latest-only 'log --all -m --no-renames' 'log -1 --all -m --no-renames'; box="$TBOX"
    GIT_TRACKED_SECRETS="k.der"; rgit "$box" init -q >/dev/null 2>&1; put_conf "$box" "allow k.der"
    real_commit "$box" k.der pkcs8; real_commit "$box" k.der cert
    run "$box" "$box/target" --yes
    if [ "$RC" = 0 ]; then ok "teeth59: history limited to the newest commit -> overwritten private key pushed — case 39b has teeth"
    else no "teeth59: mutant still refuses (rc=$RC) — case 39b is THEATER"; fi
  fi
  if [[ "$content" != *'if [ "$_nblob" = 0 ]; then'* ]]; then no "teeth60: build mutant" "no-blob anchor not found — SUT drifted?"
  else
    teeth_box teeth60-no-blob-ok 'if [ "$_nblob" = 0 ]; then' 'if false; then'; box="$TBOX"
    GIT_TRACKED_SECRETS="k.der"; rgit "$box" init -q >/dev/null 2>&1; put_conf "$box" "allow k.der"
    real_commit "$box" other.txt licence; put_pub "$box" k.der cert
    run "$box" "$box/target" --yes
    if [ "$RC" = 0 ]; then ok "teeth60: path without a committed blob accepted -> pushed unverified — case 41 has teeth"
    else no "teeth60: mutant still fails closed (rc=$RC) — case 41 is THEATER"; fi
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
