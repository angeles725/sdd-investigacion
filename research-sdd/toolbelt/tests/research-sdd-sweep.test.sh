#!/usr/bin/env bash
# research-sdd-sweep.test.sh — Test suite for the OpenCode plugin adapter.
#
# Covers:
#   A1. Structural: module exports deriveKitDir and imports realpathSync (fix applied)
#   A2. Mechanism: inline probe — realpathSync follows symlink to canonical kit dir
#   A3. Behavioral: module.deriveKitDir() called from the real module via symlink
#       resolves to the canonical research-sdd/ dir (up-2 from toolbelt/opencode/).
#       RESEARCH_SDD_KIT is unset so the env ?? short-circuit does NOT fire.
#   B.  Invariant: module survives import+handler with bad RESEARCH_SDD_KIT; 0 banners
#
# --prove-teeth adds:
#   tooth A2: without realpathSync the probe gives wrong dir (A2 has real coverage)
#   tooth A3: an up-1 mutant of deriveKitDir makes A3 go RED (up-2 is load-bearing)
#
# Note: null-catch mutation is NOT practical — catch requires realpathSync() to fail,
#       which does not happen under normal module loading (see comment below).
#
# Usage: research-sdd-sweep.test.sh [--prove-teeth]
# Exit:  0 all pass  ·  1 one+ failed  ·  2 harness error

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REAL_TS="$HERE/../opencode/research-sdd-sweep.ts"
# tests/ -> toolbelt/ -> research-sdd/
CANONICAL_KIT_DIR="$(cd "$HERE/../.." && pwd)"

# ── Guard: require node + --experimental-strip-types ─────────────────────────
if ! command -v node >/dev/null 2>&1; then
  printf 'SKIP: node not found — research-sdd-sweep.test.sh skipped\n'
  exit 0
fi
if ! node --experimental-strip-types --eval 'process.exit(0)' >/dev/null 2>&1; then
  printf 'SKIP: node --experimental-strip-types not supported — skipped\n'
  exit 0
fi
[ -f "$REAL_TS" ] || {
  printf 'FATAL: SUT not found: %s\n' "$REAL_TS" >&2
  exit 2
}

pass=0; fail=0
ok() { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT

# ── Shared: fake-plugins dir with symlink to the real module ──────────────────
FAKE_PLUGINS="$ROOT/fake-plugins"
mkdir -p "$FAKE_PLUGINS"
ln -s "$REAL_TS" "$FAKE_PLUGINS/research-sdd-sweep.ts"

# ── A1: structural ────────────────────────────────────────────────────────────
# Both 'export function deriveKitDir' (the named export) and 'realpathSync'
# (the import) must be present.  RED before the export is added; GREEN after.
if grep -q 'export function deriveKitDir' "$REAL_TS" \
   && grep -q 'realpathSync' "$REAL_TS"; then
  ok "A1: module exports deriveKitDir and imports realpathSync"
else
  no "A1: module missing 'export function deriveKitDir' or 'realpathSync'"
fi

# ── A2: mechanism probe ───────────────────────────────────────────────────────
# Inline probe validates the realpathSync pattern that deriveKitDir() uses.
# Loads via the fake-plugins symlink; realpathSync must resolve to canonical.
DERIVED_KIT="$(node --experimental-strip-types --input-type=module 2>&1 <<PROBE
import { realpathSync } from "fs"
import { fileURLToPath } from "url"
import path from "path"
const self = realpathSync(fileURLToPath("file://$FAKE_PLUGINS/research-sdd-sweep.ts"))
const kitDir = path.resolve(path.dirname(self), "..", "..")
process.stdout.write(kitDir)
PROBE
)"

if [ "$DERIVED_KIT" = "$CANONICAL_KIT_DIR" ]; then
  ok "A2: realpathSync probe follows symlink to canonical kit dir"
else
  no "A2: expected '$CANONICAL_KIT_DIR', got '$DERIVED_KIT'"
fi

# ── A3: module.deriveKitDir() called from the real exported function ──────────
# Import the REAL MODULE (not an inline re-implementation) via the symlink.
# RESEARCH_SDD_KIT is unset in a subshell so the env ?? short-circuit does NOT
# fire — deriveKitDir() is the live code path that populates KIT_DIR.
# The exported function is called again directly to capture its return value.
A3_OUT="$ROOT/a3-out.txt"
A3_ERR="$ROOT/a3-err.txt"
A3_RC=0
(
  unset RESEARCH_SDD_KIT
  node --experimental-strip-types --input-type=module <<A3IMPORTER
import { pathToFileURL } from "url"
const { deriveKitDir } = await import(pathToFileURL("$FAKE_PLUGINS/research-sdd-sweep.ts").href)
process.stdout.write(deriveKitDir())
A3IMPORTER
) >"$A3_OUT" 2>"$A3_ERR" || A3_RC=$?

A3_RESULT="$(cat "$A3_OUT" 2>/dev/null)"
if [ "$A3_RC" -eq 0 ] && [ "$A3_RESULT" = "$CANONICAL_KIT_DIR" ]; then
  ok "A3: module.deriveKitDir() via symlink resolves to canonical kit dir"
else
  a3_err="$(cat "$A3_ERR" 2>/dev/null)"
  no "A3: expected '$CANONICAL_KIT_DIR' — exit=$A3_RC result='$A3_RESULT' err=$a3_err"
fi

# ── B: module survives import+handler with bad RESEARCH_SDD_KIT ───────────────
# Import the actual module with a bad kit path.  The handler must not crash
# and must push 0 banners for an unknown session directory.
B_OUT="$ROOT/b-out.txt"
B_ERR="$ROOT/b-err.txt"
B_RC=0
RESEARCH_SDD_KIT=/nonexistent-bad-kit-for-test \
  node --experimental-strip-types --input-type=module \
  >"$B_OUT" 2>"$B_ERR" <<IMPORTER || B_RC=$?
import { pathToFileURL } from "url"
const { default: factory } = await import(pathToFileURL("$REAL_TS").href)
const handlers = await factory({ directory: "/tmp/no-such-session-dir-sweep-test" })
const output = { system: [] }
await handlers["experimental.chat.system.transform"]({ sessionID: "b-session" }, output)
process.stdout.write("banners:" + String(output.system.length) + "\n")
IMPORTER

if [ "$B_RC" -eq 0 ] && grep -q "^banners:0$" "$B_OUT" 2>/dev/null; then
  ok "B: module survives import+handler with bad kit; 0 banners pushed"
else
  b_out="$(cat "$B_OUT" 2>/dev/null)"
  b_err="$(cat "$B_ERR" 2>/dev/null)"
  no "B: expected exit=0 + banners:0 — exit=$B_RC out=$b_out err=$b_err"
fi

# ── Mutation teeth (--prove-teeth) ────────────────────────────────────────────
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: A2 realpathSync-omission + A3 up-1 mutant --"

  # Tooth A2: without realpathSync, symlink is NOT followed → wrong dir → A2 fails.
  BAD_KIT="$(node --experimental-strip-types --input-type=module 2>&1 <<BADPROBE
import { fileURLToPath } from "url"
import path from "path"
const self = fileURLToPath("file://$FAKE_PLUGINS/research-sdd-sweep.ts")
const kitDir = path.resolve(path.dirname(self), "..", "..")
process.stdout.write(kitDir)
BADPROBE
)"
  if [ "$BAD_KIT" != "$CANONICAL_KIT_DIR" ]; then
    ok "tooth A2: without realpathSync, symlink gives wrong dir — A2 has teeth"
  else
    no "tooth A2: without realpathSync, still got canonical dir — A2 has no teeth"
  fi

  # Tooth A3: up-1 mutant of deriveKitDir() (resolve one level instead of two).
  # Place the mutant at toolbelt/opencode/ inside a fake-kit tree so that
  # realpathSync resolves to a path where up-1 vs up-2 is meaningful:
  #   canonical:  $TOOTH_KIT/toolbelt/opencode/… → up-2 → $TOOTH_KIT  (correct)
  #   mutant up-1: → $TOOTH_KIT/toolbelt/opencode/… → up-1 → $TOOTH_KIT/toolbelt (WRONG)
  TOOTH_KIT="$ROOT/tooth-kit"
  mkdir -p "$TOOTH_KIT/toolbelt/opencode"
  MUTANT_UP1="$TOOTH_KIT/toolbelt/opencode/research-sdd-sweep.ts"
  sed 's|resolve(path\.dirname(self), "\.\.", "\.\.")|resolve(path.dirname(self), "..")|' \
    "$REAL_TS" > "$MUTANT_UP1"

  TOOTH_PLUGINS="$ROOT/fake-plugins-tooth"
  mkdir -p "$TOOTH_PLUGINS"
  ln -s "$MUTANT_UP1" "$TOOTH_PLUGINS/research-sdd-sweep.ts"

  T_OUT="$ROOT/tooth-a3-out.txt"
  T_RC=0
  (
    unset RESEARCH_SDD_KIT
    node --experimental-strip-types --input-type=module <<TIMPORTER
import { pathToFileURL } from "url"
const { deriveKitDir } = await import(pathToFileURL("$TOOTH_PLUGINS/research-sdd-sweep.ts").href)
process.stdout.write(deriveKitDir())
TIMPORTER
  ) >"$T_OUT" 2>/dev/null || T_RC=$?

  T_RESULT="$(cat "$T_OUT" 2>/dev/null)"
  # up-2 from $TOOTH_KIT/toolbelt/opencode → $TOOTH_KIT (correct)
  # up-1 mutant from same location → $TOOTH_KIT/toolbelt (WRONG)
  if [ "$T_RC" -ne 0 ]; then
    no "tooth A3: up-1 mutant crashed (exit=$T_RC) — cannot confirm behavioral difference"
  elif [ "$T_RESULT" != "$TOOTH_KIT" ]; then
    ok "tooth A3: up-1 mutant → '$T_RESULT' ≠ kit dir '$TOOTH_KIT' — A3 has teeth"
  else
    no "tooth A3: up-1 mutant resolved to correct kit dir — A3 has no teeth"
  fi

  # Note: null-catch mutation tooth is NOT practical.  The catch in deriveKitDir()
  # fires only when realpathSync() throws (permission error, broken link, etc.), which
  # does not happen under normal module loading.  Mocking realpathSync requires a test
  # framework not available in this bash+node setup.  The teeth above cover the
  # load-bearing behavior: realpathSync is necessary (A2) and up-2 is necessary (A3).
fi

printf '== %d passed · %d failed ==\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
