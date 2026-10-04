#!/usr/bin/env bash
# scripts-manifest.sh — the ONE SCRIPTS-MANIFEST.md row parser (kit issues #1207, #1659).
# Sourced (never executed); consumers MUST fail closed:
#   # shellcheck source=lib/scripts-manifest.sh
#   . "$_smlib"
#   declare -F scripts_manifest_rows >/dev/null 2>&1 || { echo "<script>: helper lib/scripts-manifest.sh failed to define scripts_manifest_rows" >&2; exit 2; }
# Consumers: verify-block.sh (MANIFEST! check), clean-check.sh (UNMANIFESTED-SCRIPT). Two private parsers used to
# drift (one took any first cell, header row included, with no sha check; the other was path-correct and
# required the sha cell) — an edit here is checked against both.
#
# scripts_manifest_rows <target-dir> <manifest-file>
#   A manifest is a markdown table, one row per preserved script, first cell the script and second the sha256:
#     | script | sha256 | run/step | block | executed-on | remote-sha256 | role |
#   A row is VALID only when its 2nd cell (backticks and blanks removed) is exactly 64 hex digits. The header and
#   separator rows therefore never match (their 2nd cell is `sha256` / `---`), and a row whose sha cell is a
#   placeholder (`TODO`, `-`, a short digest) lists nothing.
#   The first cell is resolved against the directory of ITS OWN manifest: a `sources/...` cell is already
#   target-relative; any other cell (a leading `./` is dropped) is relative to the manifest's directory.
#   stdout, per valid row, two tab-separated lines `<target-relative path><TAB><sha256 lowercase>`:
#     1. the resolved path of the cell;   2. <manifest dir>/<basename of the cell> (so `a.sh` and `./a.sh` both
#     list sources/probes/<dir>/a.sh).
#   <manifest-file> must live under <target-dir> (a path outside it has no target-relative form: rc 2).
#   Return: 0 = parsed (possibly ZERO valid rows — absent/empty/no-match are the caller's to tell apart by the
#   manifest's own existence) · 2 = missing argument, unreadable manifest, manifest outside the target, or awk failure.
#   Callers needing basenames only: `scripts_manifest_rows ... | awk -F'\t' '{ n = split($1, q, "/"); print q[n] }'`.
#
# FUNCTIONS ONLY — no `set` options here (a sourced `set` would mutate the caller's shell options).

if ! declare -F scripts_manifest_rows >/dev/null 2>&1; then
  scripts_manifest_rows() {
    local target="${1:-}" mf="${2:-}" md
    [ -n "$target" ] && [ -n "$mf" ] || { echo "scripts-manifest: called with fewer than 2 arguments" >&2; return 2; }
    [ -f "$mf" ] && [ -r "$mf" ] || { echo "scripts-manifest: cannot read manifest $mf" >&2; return 2; }
    target="${target%/}"
    case "$mf" in "$target"/*) ;; *) echo "scripts-manifest: manifest $mf is not under target $target" >&2; return 2 ;; esac
    md="${mf#"$target"/}"; md="${md%/*}"
    SM_MD="$md" awk -F'|' '
      /^[[:space:]]*\|/ {
        a = $2; b = $3
        gsub(/[`[:space:]]/, "", a); gsub(/[`[:space:]]/, "", b)
        sub(/^\.\//, "", a)
        n = split(a, parts, "/")
        if (a != "" && b ~ /^[0-9a-fA-F]+$/ && length(b) == 64) {   # SM-ROW
          md = ENVIRON["SM_MD"]
          full = (a ~ /^sources\//) ? a : md "/" a
          print full "\t" tolower(b)
          print md "/" parts[n] "\t" tolower(b)
        }
      }' "$mf" || { echo "scripts-manifest: awk failed reading $mf" >&2; return 2; }
  }
fi
