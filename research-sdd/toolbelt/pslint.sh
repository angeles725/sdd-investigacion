#!/usr/bin/env bash
# pslint.sh — PowerShell syntax check via local pwsh.
#
# Runs [System.Management.Automation.Language.Parser]::ParseFile so a
# syntax error in a .ps1 script is caught before it reaches a production
# host.  Validates parse correctness only; it does NOT execute the script
# and does NOT cover runtime differences between PowerShell 5.1 and 7
# (WMI, COM, Windows-native executables).  Those remain site-level checks.
#
# Two fleet targets ship PowerShell: HotelHilton (tools/*.ps1) and
# logosoft (plc-client/*.ps1).  Run this before pushing to either site.
#
# NOTE: readlink -f is GNU coreutils.  All other toolbelt scripts that
# canonicalise paths already rely on it (decompile-java.sh:23 et al.),
# so that is the established kit convention here too.
#
# Usage:
#   pslint.sh <file.ps1> [file.ps1 ...]
#
# Exit codes:
#   0  all files parsed with zero errors
#   1  at least one file has syntax errors, or a file was missing,
#      or a parse run failed (verifier error)
#   2  bad arguments (no files given)
#   3  pwsh not found on PATH
#
# READ-ONLY: never modifies any .ps1 file.
set -euo pipefail

command -v pwsh >/dev/null 2>&1 || { printf 'pslint: pwsh not found; install via "brew install powershell"\n' >&2; exit 3; }  # PL-PWSH-CHECK

[[ $# -gt 0 ]] || { printf 'usage: pslint.sh <file.ps1> [file.ps1 ...]\n' >&2; exit 2; }

rc=0
for f in "$@"; do
    [[ -f "$f" ]] || { printf 'MISS   %s\n' "$f" >&2; rc=1; continue; }  # PL-FILE-CHECK

    # GNU readlink -f: established kit convention (decompile-java.sh:23).
    abs="$(readlink -f -- "$f")"

    # Pass the path via an environment variable, NOT interpolated into the
    # PowerShell command text.  A path with a single quote or other
    # PowerShell-significant characters embedded directly in
    # ParseFile('$path') would break the literal-string delimiter or change
    # what gets parsed.  Environment variable values are never interpreted
    # as PowerShell syntax.
    pwsh_out=""
    pwsh_rc=0
    pwsh_out="$(PSLINT_PATH="$abs" pwsh -NoProfile -NonInteractive -Command '
        $path = $env:PSLINT_PATH
        $e = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$e)
        if ($e -and $e.Count) {
            $e | ForEach-Object { "L{0}:{1}  {2}" -f $_.Extent.StartLineNumber, $_.Extent.StartColumnNumber, $_.Message }
        }
    ')" || pwsh_rc=$?

    # A non-zero pwsh exit is a verifier failure, not a parse finding.
    # An unavailable or failed verifier must never be reported as a pass
    # (CLAUDE.md §7 anti-silent-zero doctrine).
    if [[ "$pwsh_rc" -ne 0 ]]; then
        printf 'ERROR  %s  (pwsh exited %s — verifier failed; result unavailable)\n' "$f" "$pwsh_rc" >&2
        rc=1
        continue
    fi

    if [[ -n "$pwsh_out" ]]; then  # PL-ERRORS-CHECK
        printf 'FAIL   %s\n' "$f"
        printf '%s\n' "$pwsh_out" | sed 's/^/       /'
        rc=1
        continue
    fi
    lc=$(wc -l < "$f"); printf 'OK     %s  (%s lines)\n' "$f" "${lc// /}"
done

exit "$rc"
