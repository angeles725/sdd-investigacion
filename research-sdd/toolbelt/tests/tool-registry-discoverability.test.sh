#!/usr/bin/env bash
# tool-registry-discoverability.test.sh — every artifact-processing wrapper script must have its
# basename listed in tool-registry.md so the loop can discover it via profile-target.sh.
#
# Scope: genuine artifact-routing wrappers only. Gates (verify-*, scan-secrets), lifecycle
# scripts, and pure-plumbing helpers are intentionally excluded from the assertion set.
#
# Usage: tool-registry-discoverability.test.sh [--prove-teeth]
# Exit: 0 all pass · 1 any failure · 2 harness error.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TB="$(cd "$HERE/.." && pwd)"
REGISTRY="$TB/tool-registry.md"

[ -f "$REGISTRY" ] || { echo "FATAL: tool-registry.md not found: $REGISTRY" >&2; exit 2; }

pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
echo "== tool-registry-discoverability.test.sh =="

# Artifact-processing wrappers that MUST appear in tool-registry.md.
# These are the shell-script wrappers the loop routes artifact types to via profile-target.sh.
# Do NOT add gates (verify-*, scan-secrets), lifecycle scripts, or pure-plumbing helpers.
WRAPPERS=(
  corroborate-capa.sh
  corroborate-floss.sh
  corroborate-java.sh
  corroborate-kaitai.sh
  corroborate-native.sh
  corroborate-pcap.sh
  corroborate-unblob.sh
  decompile-java.sh
  decompile-native.sh
  decompile-net.sh
  extract-pdf.sh
  fetch-doc.sh
  jvm-callgraph.sh
  pcap-flows.sh
  pslint.sh
  render-drawing.sh
  scan-firmware.sh
  squashfs-extract.sh
  zip-metadata.sh
  zip-stored.sh
)

check_registry() {
  local reg="$1" w
  for w in "${WRAPPERS[@]}"; do
    if grep -qF "$w" "$reg"; then
      ok "discoverable: $w"
    else
      no "NOT in registry: $w"
    fi
  done
}

check_registry "$REGISTRY"

# ======================== NEGATIVE CONTROL — --prove-teeth ==========================
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: remove jvm-callgraph.sh row from a registry copy; check must flag it --"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  mutant="$tmp/tool-registry.md"
  grep -v 'jvm-callgraph' "$REGISTRY" > "$mutant"
  mut_fail=0
  for w in "${WRAPPERS[@]}"; do
    grep -qF "$w" "$mutant" || mut_fail=$((mut_fail+1))
  done
  if [ "$mut_fail" -gt 0 ]; then
    ok "teeth: $mut_fail wrapper(s) flagged as undiscoverable in mutated registry (check bites)"
  else
    no "teeth: removal of jvm-callgraph.sh row was NOT detected — check is toothless"
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
