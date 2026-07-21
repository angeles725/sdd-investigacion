#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$HERE/corroborate_pcap.py" --manifest-cli "$HERE/analysis_manifest.py" "$@"
