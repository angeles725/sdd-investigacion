#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/tool-env.sh
source "$HERE/lib/tool-env.sh"
ghidra_home="$(rsdd_resolve_ghidra_home)" || { echo 'corroborate-ghidra: Ghidra unavailable' >&2; exit 2; }
java_home="$(rsdd_resolve_java_home)" || { echo 'corroborate-ghidra: Java 21 unavailable' >&2; exit 2; }
ghidra_home="$(realpath "$ghidra_home")"; java_home="$(realpath "$java_home")"
bwrap="${RSDD_BWRAP:-$(command -v bwrap 2>/dev/null || true)}"
safe_file(){ local p; p="$(realpath -e -- "$1")" || return; [ -f "$p" ] && [ -x "$p" ] || return; printf '%s\n' "$p"; }
java="$(safe_file "$java_home/bin/java")" || { echo 'corroborate-ghidra: unsafe Java executable' >&2; exit 2; }
bwrap="$(safe_file "$bwrap")" || { echo 'corroborate-ghidra: Bubblewrap unavailable' >&2; exit 2; }
manifest="$(realpath -e -- "${RSDD_MANIFEST_CLI:-$HERE/analysis_manifest.py}")"; [ -f "$manifest" ] || { echo 'corroborate-ghidra: manifest CLI unavailable' >&2; exit 2; }
test_args=(); [ "${RSDD_TEST_ONLY_UNTRUSTED_BWRAP:-0}" = 1 ] && test_args=(--test-only-untrusted-bwrap)
exec python3 "$HERE/corroborate_ghidra.py" \
  --ghidra-home "$ghidra_home" --analyze-headless "$ghidra_home/support/analyzeHeadless" \
  --java "$java" --exporter "$HERE/ghidra/CuratedEvidenceExporter.java" \
  --bwrap "$bwrap" --manifest-cli "$manifest" "${test_args[@]}" "$@"
