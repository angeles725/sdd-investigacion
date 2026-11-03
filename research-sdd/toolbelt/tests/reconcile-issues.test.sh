#!/usr/bin/env bash
# reconcile-issues.test.sh — wiring suite for the reconcile-issues.sh compatibility shim (kit issue #2563).
#
# The script is a rsdd_exec shim over `rsdd retro reconcile`; the audit itself (every classification, the delta
# grammar, the closed-issue classes, --all, live gh, the usage and probe states) is tested in Go, in
# research-sdd/rsdd/internal/retro/reconcile, against the frozen legacy script (testdata/legacy): see the case map
# in odd/tasks/reconcile-issues-go.md (Log, L6). This suite proves only the wiring the Go tests cannot see:
#   1 the shim reaches the Go command and its stdout, stderr and exit code come back unchanged
#   2 the kit root is the shim's own directory (--toolbelt), also through a symlink to the shim
#   3 arguments pass through in order, including flags after the retro and --all
#   4 gh is looked up on the caller's PATH (the live path)
#   5 a missing lib/rsdd-exec.sh is a typed degraded (exit 2), never a silent pass
#
# Usage: reconcile-issues.test.sh                (run the suite)
#        reconcile-issues.test.sh --prove-teeth  (run suite + mutation teeth on the shim)
# Exit: 0 = all pass · 1 = failure · 2 = harness error

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../reconcile-issues.sh"
[ -f "$SUT" ] || { echo "FATAL: script under test not found: $SUT" >&2; exit 2; }
EXEC_LIB="$HERE/../lib/rsdd-exec.sh"
[ -f "$EXEC_LIB" ] || { echo "FATAL: rsdd-exec helper not found" >&2; exit 2; }
BASH_BIN="$(type -P bash)"; [ -n "$BASH_BIN" ] || { echo "FATAL: bash not on PATH" >&2; exit 2; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
# The shim runs the Go command: the caller's RSDD_BIN, else one build into the temp dir (degraded, never a pass,
# without go).
if [ -z "${RSDD_BIN:-}" ]; then
  command -v go >/dev/null 2>&1 || { echo "FATAL: no rsdd binary: RSDD_BIN unset and go not found (degraded, not a pass)" >&2; exit 2; }
  ( cd "$HERE/../../rsdd" && go build -o "$ROOT/rsdd" ./cmd/rsdd ) || { echo "FATAL: go build ./cmd/rsdd failed" >&2; exit 2; }
  RSDD_BIN="$ROOT/rsdd"
fi
export RSDD_BIN
pass=0; fail=0
ok() { printf '  PASS  %-60s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
no() { printf '  FAIL  %-60s %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

# mkbox <name> [shim]: a kit-shaped sandbox (shim + lib/rsdd-exec.sh, TARGETS.md registering the directory target-foo as reg-name, one pending retro
# with rows 1 and 2) and a cache that tracks row 1 only. Prints the box path.
mkbox() {
  local shim="${2:-$SUT}" box="$ROOT/$1"
  mkdir -p "$box/research-sdd/toolbelt/lib" "$box/rh/target-foo/retros" "$box/bin"
  cp "$shim" "$box/research-sdd/toolbelt/reconcile-issues.sh"
  cp "$EXEC_LIB" "$box/research-sdd/toolbelt/lib/rsdd-exec.sh"
  printf '# targets\n\n| # | Target | Path |\n|---|---|---|\n| 1 | reg-name | `%s` |\n' "$box/rh/target-foo" > "$box/research-sdd/TARGETS.md"
  printf '<!-- review-status: pending -->\n# retro\n\n## Proposed kit deltas\n\n| # | Proposed change | Target (file) | Evidence | Type | Priority |\n|---|---|---|---|---|---|\n| 1 | first change | CLAUDE.md | B1 | fix | HIGH |\n| 2 | second change | CLAUDE.md | B1 | fix | HIGH |\n' > "$box/rh/target-foo/retros/r.md"
  printf 'Source retro: reg-name/retros/r.md · 1\n' > "$box/cache.txt"
  printf '%s' "$box"
}

# mkgh <box>: a gh on PATH that logs its calls and answers the open listing with row 1 of r.md.
mkgh() {
  printf '#!%s\nprintf "%%s\\n" "gh $*" >> "%s/gh.log"\ncase "$1 $2" in "auth status") exit 0 ;; "issue list") printf "Source retro: reg-name/retros/r.md · 1\\n\\036\\n" ;; esac\n' "$BASH_BIN" "$1" > "$1/bin/gh"
  chmod +x "$1/bin/gh"
}

# run <shim-path> <args...>: sets OUT (stdout), ERR (stderr) and RC. PATH keeps the real tools; the box's bin comes first.
run() {
  local shim="$1" box; shift
  box="$(dirname "$shim")/../.."
  local errf="$ROOT/stderr.txt"
  OUT="$(cd "$box" && PATH="$box/bin:$PATH" "$BASH_BIN" "$shim" "$@" 2>"$errf")"; RC=$?
  ERR="$(cat "$errf")"
}

echo "== reconcile-issues.test.sh =="

# 1 — the shim reaches the Go command; findings on stdout, exit 0.
box="$(mkbox case-wiring)"
run "$box/research-sdd/toolbelt/reconcile-issues.sh" --issues-cache "$box/cache.txt" "$box/rh/target-foo/retros/r.md"
if [ "$RC" = 0 ] && [ "$OUT" = $'tracked: row 1 — open issue found in r.md\nuntracked: row 2 — no open issue found for this delta in r.md' ] \
   && grep -q '^closed-lookup: skipped for r.md' <<<"$ERR"; then
  ok "1 wiring: shim → rsdd retro reconcile; stdout, stderr and exit 0 come back" "(exit $RC)"
else
  no "1 wiring: shim → rsdd retro reconcile" "rc=$RC out=[$OUT] err=[$ERR]"
fi

# 1b — the exit code of a typed failure comes back unchanged (absent-input = 1), stderr carries the typed state.
run "$box/research-sdd/toolbelt/reconcile-issues.sh" --issues-cache "$box/cache.txt" "$box/rh/target-foo/retros/none.md"
if [ "$RC" = 1 ] && [ -z "$OUT" ] && grep -q '^absent-input: retro not found: ' <<<"$ERR"; then
  ok "1b wiring: absent-input → exit 1 + typed stderr line" "(exit $RC)"
else
  no "1b wiring: absent-input → exit 1" "rc=$RC out=[$OUT] err=[$ERR]"
fi

# 2 — the kit root is the shim's own directory: TARGETS.md of the box names target-foo, so the signature matches;
#     through a symlink to the shim the same box answers (the physical directory of the SHIM, not the link's).
mkdir -p "$ROOT/elsewhere"
ln -s "$box/research-sdd/toolbelt/reconcile-issues.sh" "$ROOT/elsewhere/reconcile-issues.sh"
OUT="$(cd "$ROOT/elsewhere" && "$BASH_BIN" ./reconcile-issues.sh --issues-cache "$box/cache.txt" "$box/rh/target-foo/retros/r.md" 2>&1)"; RC=$?
if [ "$RC" = 0 ] && grep -q '^tracked: row 1' <<<"$OUT"; then
  ok "2 wiring: kit root = the shim's physical directory (also through a symlink)" "(exit $RC)"
else
  no "2 wiring: kit root through a symlink" "rc=$RC out=[$OUT]"
fi

# 3 — arguments pass through in order: flags after the retro, and --all with the fleet summary.
run "$box/research-sdd/toolbelt/reconcile-issues.sh" "$box/rh/target-foo/retros/r.md" --issues-cache "$box/cache.txt"
r3a="$RC|$OUT"
run "$box/research-sdd/toolbelt/reconcile-issues.sh" --all --issues-cache "$box/cache.txt"
if [ "${r3a%%|*}" = 0 ] && grep -q '^tracked: row 1' <<<"${r3a#*|}" && [ "$RC" = 0 ] \
   && grep -q '^fleet-summary: tracked=1 untracked=1 shipped=0 borderline=0 regressed=0 orphaned=0 degraded=0 out-of-scope=0 retros=1$' <<<"$OUT"; then
  ok "3 wiring: arguments pass through (flag after the retro; --all + fleet-summary)" "(exit $RC)"
else
  no "3 wiring: argument passthrough" "a=[$r3a] rc=$RC out=[$OUT]"
fi
run "$box/research-sdd/toolbelt/reconcile-issues.sh"
if [ "$RC" = 1 ] && grep -q '^usage: reconcile-issues.sh <retro.md> | --all$' <<<"$ERR"; then
  ok "3b wiring: no arguments → usage + exit 1" "(exit $RC)"
else
  no "3b wiring: no arguments → usage" "rc=$RC err=[$ERR]"
fi

# 4 — the live path finds gh on the caller's PATH (and nothing is asked of it with a cache).
box4="$(mkbox case-live)"; mkgh "$box4"
run "$box4/research-sdd/toolbelt/reconcile-issues.sh" "$box4/rh/target-foo/retros/r.md"
if [ "$RC" = 0 ] && grep -q '^tracked: row 1' <<<"$OUT" && grep -q '^gh issue list --repo angeles725/sdd-investigacion --state open ' "$box4/gh.log"; then
  ok "4 wiring: gh is looked up on PATH (live open listing)" "(exit $RC)"
else
  no "4 wiring: gh on PATH" "rc=$RC out=[$OUT] err=[$ERR] log=[$(cat "$box4/gh.log" 2>/dev/null)]"
fi

# 5 — a missing lib/rsdd-exec.sh is typed degraded + exit 2.
box5="$(mkbox case-nolib)"; rm -f "$box5/research-sdd/toolbelt/lib/rsdd-exec.sh"
run "$box5/research-sdd/toolbelt/reconcile-issues.sh" --issues-cache "$box5/cache.txt" "$box5/rh/target-foo/retros/r.md"
if [ "$RC" = 2 ] && [ -z "$OUT" ] && grep -q '^degraded: rsdd-unavailable — rsdd-exec.sh missing beside ' <<<"$ERR"; then
  ok "5 wiring: missing rsdd-exec.sh → degraded rsdd-unavailable + exit 2" "(exit $RC)"
else
  no "5 wiring: missing rsdd-exec.sh" "rc=$RC out=[$OUT] err=[$ERR]"
fi

# 6 — the shim carries no audit logic of its own and only the one dispatch line.
if [ "$(grep -c 'rsdd_exec ' "$SUT")" = 1 ] && grep -q '^rsdd_exec retro reconcile --toolbelt "\$_RSDD_SELF" "\$@"$' "$SUT" && [ "$(wc -l < "$SUT")" -le 12 ]; then
  ok "6 wiring: the script is the rsdd_exec shim (one dispatch line, no audit logic)" "()"
else
  no "6 wiring: the script is the rsdd_exec shim" "lines=$(wc -l < "$SUT")"
fi

# ---------------------------------------------------------------------------
# TEETH (negative controls for --prove-teeth): a broken shim must turn a wiring case red.
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: mutation controls on the shim --"
  # tooth <label> <sed-expr> <case-pattern>: mutate a copy of the shim, run it in a fresh box, and require that the
  # wiring case (cache + retro, tracked row 1) no longer holds.
  tooth() {
    local label="$1" expr="$2" mut="$ROOT/mutant-$1.sh" mb
    sed "$expr" "$SUT" > "$mut"
    if cmp -s "$mut" "$SUT"; then no "$label teeth" "the mutation changed nothing (anchor drifted)"; return; fi
    mb="$(mkbox "teeth-$label" "$mut")"
    run "$mb/research-sdd/toolbelt/reconcile-issues.sh" --issues-cache "$mb/cache.txt" "$mb/rh/target-foo/retros/r.md"
    if [ "$RC" = 0 ] && grep -q '^tracked: row 1' <<<"$OUT"; then
      no "$label teeth" "the mutant still passes the wiring case: THEATER (rc=$RC out=[$OUT])"
    else
      ok "$label teeth: mutant turns the wiring case red" "(exit $RC)"
    fi
  }
  tooth T1-command 's/^rsdd_exec retro reconcile /rsdd_exec retro stage-issues /'
  tooth T2-passthrough 's/ "\$@"$//'
  tooth T3-toolbelt 's/ --toolbelt "\$_RSDD_SELF"//'
  tooth T4-self-dir 's/_RSDD_SELF="\$(CDPATH='"''"' cd -- "\$(dirname -- "\$_rsdd_s")" \&\& pwd -P)"/_RSDD_SELF="\/nonexistent"/'
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
