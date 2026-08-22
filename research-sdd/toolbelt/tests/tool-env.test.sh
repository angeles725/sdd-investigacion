#!/usr/bin/env bash
# tool-env.test.sh — observable contract for Research-SDD tool resolution.
#
# This suite deliberately tests only the integration boundary we own: stable
# off-PATH resolution, command-local pkg-config enrichment, usable-vs-found
# classification, and the existing decompiler wrapper contract. External tool
# behavior belongs to the tools themselves, not to this harness.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/../lib/tool-env.sh"
DETECT="$HERE/../detect-tools.sh"
JAVA_WRAPPER="$HERE/../decompile-java.sh"
[ -f "$LIB" ] || { echo "FATAL: script under test not found: $LIB" >&2; exit 2; }
[ -f "$DETECT" ] && [ -f "$JAVA_WRAPPER" ] || { echo "FATAL: tool wrapper missing" >&2; exit 2; }

# shellcheck source=../lib/tool-env.sh
source "$LIB"

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
pass=0; fail=0
ok() { printf '  PASS  %-52s %s\n' "$1" "${2:-}"; pass=$((pass+1)); }
no() { printf '  FAIL  %-52s %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

mkexec() { # mkexec <path> <body>
  local p="$1" body="$2"
  mkdir -p "$(dirname "$p")"
  printf '#!/usr/bin/env bash\n%s\n' "$body" > "$p"
  chmod +x "$p"
}

mkjar() { # mkjar <path> <expected-class>
  python3 - "$1" "$2" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as archive:
    archive.writestr("META-INF/MANIFEST.MF", "Manifest-Version: 1.0\n")
    archive.writestr(sys.argv[2], b"class")
PY
}

echo "== tool-env.test.sh =="

# 1 — Hyperscan discovery enriches only the pkg-config child process. Linuxbrew
# pkg-config may shadow the distro binary, but the parent shell must stay clean.
mkdir -p "$ROOT/system-pc"
: > "$ROOT/system-pc/libhs.pc"
mkexec "$ROOT/bin/pkg-config" \
  'case ":${PKG_CONFIG_PATH:-}:" in *:"$RSDD_TEST_PC_DIR":*) echo 5.4.0; exit 0;; *) exit 1;; esac'
before="${PKG_CONFIG_PATH-__unset__}"
OUT="$(RSDD_SYSTEM_PKGCONFIG_PATH="$ROOT/system-pc" RSDD_TEST_PC_DIR="$ROOT/system-pc" \
  PKG_CONFIG_BIN="$ROOT/bin/pkg-config" rsdd_pkg_config --modversion libhs 2>&1)"; RC=$?
after="${PKG_CONFIG_PATH-__unset__}"
if [ "$RC" = 0 ] && [ "$OUT" = 5.4.0 ] && [ "$after" = "$before" ]; then
  ok "1 Hyperscan pkg-config path is command-local" "(version=$OUT)"
else
  no "1 Hyperscan pkg-config path is command-local" "exit=$RC before=$before after=$after out=[$OUT]"
fi

# 2 — Stable off-PATH roots win without versioned Cellar pins. A broken JAVA_HOME
# must not hide the usable Java 21 under the stable Homebrew opt symlink; jars and
# Ghidra resolve from portable HOME/opt locations.
BREW="$ROOT/brew"; HOME_FAKE="$ROOT/home"
mkexec "$BREW/opt/openjdk@21/bin/java" 'echo '\''openjdk version "21.0.1"'\'' >&2; exit 0'
mkexec "$BREW/opt/openjdk@21/bin/javap" 'echo 21.0.1; exit 0'
mkexec "$BREW/opt/ghidra/libexec/support/analyzeHeadless" 'echo Headless Analyzer Usage: analyzeHeadless; exit 1'
mkdir -p "$HOME_FAKE/.local/share/research-sdd-tools/java"
: > "$HOME_FAKE/.local/share/research-sdd-tools/java/vineflower.jar"
: > "$HOME_FAKE/.local/share/research-sdd-tools/java/cfr.jar"
: > "$HOME_FAKE/.local/share/research-sdd-tools/java/procyon.jar"
_tool_home="$HOME_FAKE/.local/share/research-sdd-tools"
jhome="$(HOME="$HOME_FAKE" JAVA_HOME="$ROOT/broken-java" RSDD_BREW_PREFIX="$BREW" rsdd_resolve_java_home 2>/dev/null)"
vf="$(HOME="$HOME_FAKE" RSDD_BREW_PREFIX="$BREW" rsdd_resolve_java_jar vineflower 2>/dev/null)"
cfr_j="$(HOME="$HOME_FAKE" RSDD_BREW_PREFIX="$BREW" rsdd_resolve_java_jar cfr 2>/dev/null)"
procyon_j="$(HOME="$HOME_FAKE" RSDD_BREW_PREFIX="$BREW" rsdd_resolve_java_jar procyon 2>/dev/null)"
gh="$(HOME="$HOME_FAKE" RSDD_BREW_PREFIX="$BREW" rsdd_resolve_ghidra_home 2>/dev/null)"
if [ "$jhome" = "$BREW/opt/openjdk@21" ] \
   && [ "$vf" = "$_tool_home/java/vineflower.jar" ] \
   && [ "$cfr_j" = "$_tool_home/java/cfr.jar" ] \
   && [ "$procyon_j" = "$_tool_home/java/procyon.jar" ] \
   && [ "$gh" = "$BREW/opt/ghidra/libexec" ]; then
  ok "2 stable off-PATH Java/JAR/Ghidra resolution" "(canonical tool-home; no Cellar pin)"
else
  no "2 stable off-PATH Java/JAR/Ghidra resolution" "java=[$jhome] vf=[$vf] cfr=[$cfr_j] procyon=[$procyon_j] gh=[$gh]"
fi

# 3 — A file being executable is not enough. The capability report must classify
# a found-but-broken tool as UNUSABLE, while reporting the newly supported CLI
# families when their smoke commands work.
BIN="$ROOT/cap-bin"; mkdir -p "$BIN"
mkexec "$BIN/gdb" 'exit 9'
for tool in gdb-multiarch strace ltrace tshark tcpdump qemu-system-x86_64 qemu-arm-static qemu-img; do
  mkexec "$BIN/$tool" 'echo tool-version-1; exit 0'
done
CACHE="$ROOT/capabilities.txt"
PATH="$BIN:$PATH" RSDD_BREW_PREFIX="$BREW" HOME="$HOME_FAKE" \
  bash "$DETECT" --cache "$CACHE" --quiet >/dev/null
if grep -Eq '^  gdb +UNUSABLE +' "$CACHE" \
   && grep -Eq '^  tshark +AVAILABLE +' "$CACHE" \
   && grep -Eq '^  tcpdump +AVAILABLE +' "$CACHE" \
   && grep -Eq '^  gdb-multiarch +AVAILABLE +' "$CACHE" \
   && grep -Eq '^  strace +AVAILABLE +' "$CACHE" \
   && grep -Eq '^  ltrace +AVAILABLE +' "$CACHE" \
   && grep -Eq '^  QEMU system +AVAILABLE +' "$CACHE" \
   && grep -Eq '^  QEMU user-static +AVAILABLE +' "$CACHE"; then
  ok "3 capability report proves usability + new APT tools" "(broken gdb rejected)"
else
  no "3 capability report proves usability + new APT tools" "$(tr '\n' '|' < "$CACHE")"
fi

# 5 — Detection may inspect mutable decompiler archives, but must never execute
# them. Integrity, expected entry class, and a stable digest are sufficient.
if ! command -v unzip >/dev/null 2>&1; then
  echo "  SKIP  5 JAR probe is structural and engine-specific (unzip absent)"
else
mkjar "$ROOT/structural-vf.jar" org/jetbrains/java/decompiler/main/decompiler/ConsoleDecompiler.class
mkexec "$ROOT/probe-java/bin/java" \
  'printf '\''%s\n'\'' "$*" >> "$RSDD_JAVA_CALLS"; echo '\''openjdk version "21.0.1"'\'' >&2'
mkexec "$ROOT/probe-java/bin/javap" 'exit 0'
: > "$ROOT/java-calls"
STRUCT_CACHE="$ROOT/structural-capabilities.txt"
JAVA_HOME="$ROOT/probe-java" RSDD_JAVA_CALLS="$ROOT/java-calls" \
  VINEFLOWER_JAR="$ROOT/structural-vf.jar" HOME="$HOME_FAKE" RSDD_BREW_PREFIX="$BREW" \
  bash "$DETECT" --cache "$STRUCT_CACHE" --quiet >/dev/null
if JAVA_HOME="$ROOT/probe-java" RSDD_JAVA_CALLS="$ROOT/java-calls" \
     rsdd_probe_java_jar vineflower "$ROOT/structural-vf.jar" \
   && ! grep -q '^-jar ' "$ROOT/java-calls" \
   && grep -Eq '^  Vineflower \(jar\) +AVAILABLE +.*sha256=[0-9a-f]{64}' "$STRUCT_CACHE" \
   && ! rsdd_probe_java_jar cfr "$ROOT/structural-vf.jar"; then
  ok "5 JAR probe is structural and engine-specific" "(digest recorded; archive never executed)"
else
  no "5 JAR probe is structural and engine-specific" "java execution or invalid acceptance"
fi
fi

# 6 — Java and Ghidra probes are bounded even when an executable hangs.
SLOW_JAVA="$ROOT/slow-java"; SLOW_GHIDRA="$ROOT/slow-ghidra"
# sleep 8 (> the _t6_bound of 6000ms below): if the timeout wrapper is applied
# but a single probe ignores SIGTERM (rc=124), it runs the full 8s and the
# wall-clock clause still catches it — closes the single-probe-hang blind spot.
mkexec "$SLOW_JAVA/bin/java" 'sleep 8; echo '\''openjdk version "21.0.1"'\'' >&2'
mkexec "$SLOW_JAVA/bin/javap" 'exit 0'
mkexec "$SLOW_GHIDRA/support/analyzeHeadless" 'echo Headless Analyzer Usage; sleep 8'
_T6_PROBE_TIMEOUT=0.1                    # seconds; also exported as RSDD_PROBE_TIMEOUT below
start="$(date +%s%N)"
RSDD_PROBE_TIMEOUT="$_T6_PROBE_TIMEOUT" rsdd_java_21_usable "$SLOW_JAVA"; java_rc=$?
JAVA_HOME="$BREW/opt/openjdk@21" RSDD_PROBE_TIMEOUT="$_T6_PROBE_TIMEOUT" rsdd_probe_ghidra "$SLOW_GHIDRA"; ghidra_rc=$?
elapsed_ms=$(( (10#$(date +%s%N) - 10#$start) / 1000000 ))
# Scale the wall-clock bound off the configured probe timeout so the guard stays meaningful
# under scheduling load. Each probe makes at most one full-length timeout call; a 40x
# multiplier plus 2 000 ms fixed slack gives 6 000 ms at 0.1 s — comfortably above the
# observed 3 797 ms load spike (17x unloaded) while remaining well below a genuine 2-probe
# hang (two 5 s sleeps = ~10 000 ms). A genuine hang where both probes exit 0 is caught
# first by the rc assertions (java_rc=0 or ghidra_rc=0); the wall-clock bound catches the
# case where probes exit non-zero but stall well beyond the timeout. Same rationale as #74.
_t6_ms=$(awk "BEGIN{printf \"%d\", $_T6_PROBE_TIMEOUT * 1000}")
_t6_bound=$(( 40 * _t6_ms + 2000 ))
if [ "$java_rc" -ne 0 ] && [ "$ghidra_rc" -ne 0 ] && [ "$elapsed_ms" -lt "$_t6_bound" ]; then
  ok "6 Java and Ghidra probes time out" "(${elapsed_ms}ms < ${_t6_bound}ms)"
else
  no "6 Java and Ghidra probes time out" "java=$java_rc ghidra=$ghidra_rc elapsed=${elapsed_ms}ms (bound ${_t6_bound}ms)"
fi

# 7 — Explicit invalid overrides are authoritative: never hide a typo by
# silently selecting a different local installation.
invalid_ok=1
for spec in vineflower:VINEFLOWER_JAR cfr:CFR_JAR procyon:PROCYON_JAR; do
  name="${spec%%:*}"; var="${spec#*:}"
  if env "$var=$ROOT/missing.jar" HOME="$HOME_FAKE" RSDD_BREW_PREFIX="$BREW" \
      bash -c 'source "$1"; rsdd_resolve_java_jar "$2"' _ "$LIB" "$name" >/dev/null 2>&1; then
    invalid_ok=0
  fi
done
for var in ANALYZE_HEADLESS GHIDRA_HOME GHIDRA_INSTALL_DIR; do
  if env "$var=$ROOT/missing-ghidra" RSDD_BREW_PREFIX="$BREW" \
      bash -c 'source "$1"; rsdd_resolve_ghidra_home' _ "$LIB" >/dev/null 2>&1; then
    invalid_ok=0
  fi
done
if [ "$invalid_ok" = 1 ]; then ok "7 invalid explicit overrides fail closed"
else no "7 invalid explicit overrides fail closed"; fi

# 8 — Probe the resolved Python console script itself. pipx commonly exposes a
# symlink in ~/.local/bin with no sibling python executable.
mkdir -p "$ROOT/python-target" "$ROOT/python-bin"
mkexec "$ROOT/python-target/marker" '[ "${RSDD_TEST_SLOW:-0}" = 0 ] || sleep 5; [ "${1:-}" = --help ]'
mkexec "$ROOT/python-target/docling" '[ "${1:-}" = --help ]'
ln -s "$ROOT/python-target/marker" "$ROOT/python-bin/marker_single"
ln -s "$ROOT/python-target/docling" "$ROOT/python-bin/docling"
PY_CACHE="$ROOT/python-capabilities.txt"
PATH="$ROOT/python-bin:$PATH" HOME="$HOME_FAKE" RSDD_BREW_PREFIX="$BREW" \
  bash "$DETECT" --cache "$PY_CACHE" --quiet >/dev/null
RSDD_TEST_SLOW=1 RSDD_PYTHON_PROBE_TIMEOUT=0.1 PATH="$ROOT/python-bin:$PATH" \
  HOME="$HOME_FAKE" RSDD_BREW_PREFIX="$BREW" \
  bash "$DETECT" --cache "$PY_CACHE.slow" --quiet >/dev/null
if grep -Eq '^  marker +AVAILABLE +' "$PY_CACHE" \
   && grep -Eq '^  docling +AVAILABLE +' "$PY_CACHE" \
   && grep -Eq '^  marker +UNUSABLE +' "$PY_CACHE.slow"; then
  ok "8 pipx/symlink Python entrypoints are direct + bounded"
else
  no "8 pipx/symlink Python entrypoints are probed directly" "$(grep -E 'marker|docling' "$PY_CACHE" | tr '\n' '|')"
fi

# 4 — Backward-compatible decompile-java invocation still accepts the existing
# env overrides, but now reaches them through the shared resolver.
mkdir -p "$ROOT/wrapper-java/bin" "$ROOT/out"
mkexec "$ROOT/wrapper-java/bin/java" \
  'if [ "${1:-}" = -version ]; then echo '\''openjdk version "21.0.1"'\'' >&2; else printf '\''%s\n'\'' "$*" > "$RSDD_CALLS"; fi; exit 0'
mkexec "$ROOT/wrapper-java/bin/javap" 'exit 0'
: > "$ROOT/vineflower.jar"; : > "$ROOT/input.jar"
RSDD_CALLS="$ROOT/calls" JAVA_HOME="$ROOT/wrapper-java" VINEFLOWER="$ROOT/vineflower.jar" \
  bash "$JAVA_WRAPPER" "$ROOT/input.jar" "$ROOT/out" --engine vineflower >/dev/null 2>&1; RC=$?
if [ "$RC" = 0 ] && grep -Fq -- "-jar $ROOT/vineflower.jar $ROOT/input.jar $ROOT/out" "$ROOT/calls"; then
  ok "4 existing decompile-java env overrides still work" "(exit $RC)"
else
  no "4 existing decompile-java env overrides still work" "exit=$RC calls=[$(cat "$ROOT/calls" 2>/dev/null)]"
fi

# ── Prove-teeth (--prove-teeth) ──────────────────────────────────────────────
# teeth 2: test-2 assertion must fail when the canonical tool-home candidates
# are removed from the resolver. A mutant that replaces $tool_home/java/ with
# a non-existent prefix makes all three JAR resolvers return empty — if the
# assertion were to pass on that mutant, the test has no teeth.
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: canonical tool-home JAR candidates must be required by test 2 --"
  TMP_TEETH="$(mktemp -d)"
  trap 'rm -rf "$ROOT" "$TMP_TEETH"' EXIT
  sed 's|\$tool_home/java/|/dev/null/no-such-dir/|g' "$LIB" > "$TMP_TEETH/tool-env-mut.sh"
  vf_mut="$(HOME="$HOME_FAKE" RSDD_BREW_PREFIX="$BREW" \
    bash -c 'source "$1"; rsdd_resolve_java_jar vineflower' _ "$TMP_TEETH/tool-env-mut.sh" 2>/dev/null)"
  cfr_mut="$(HOME="$HOME_FAKE" RSDD_BREW_PREFIX="$BREW" \
    bash -c 'source "$1"; rsdd_resolve_java_jar cfr' _ "$TMP_TEETH/tool-env-mut.sh" 2>/dev/null)"
  procyon_mut="$(HOME="$HOME_FAKE" RSDD_BREW_PREFIX="$BREW" \
    bash -c 'source "$1"; rsdd_resolve_java_jar procyon' _ "$TMP_TEETH/tool-env-mut.sh" 2>/dev/null)"
  if [ -z "$vf_mut" ] && [ -z "$cfr_mut" ] && [ -z "$procyon_mut" ]; then
    ok "teeth 2: canonical-home removal breaks all three JAR resolvers (test-2 assertion has teeth)"
  else
    no "teeth 2: mutant still resolved JAR(s) — test-2 assertion has no teeth: vf=[$vf_mut] cfr=[$cfr_mut] procyon=[$procyon_mut]"
  fi
fi

printf '== %d passed · %d failed ==\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
