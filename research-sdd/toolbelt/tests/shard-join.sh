#!/usr/bin/env bash
#
# shard-join.sh — prove a set of `run-all.sh --shard I/N --shard-manifest PATH` manifests is the
# whole gate (kit issue #2114). The join step of the sharded CI run: exit 0 only when EVERY suite
# of the full discovered list ran EXACTLY ONCE and passed, in a complete set of green shards.
#
# Usage: shard-join.sh [--expected FILE] [--shards N] [--strict-skip] MANIFEST...
#
#   --expected FILE  the full suite list, one repo-relative path per line. Default: the output of
#                    `run-all.sh --list-suites` next to this script (the single discovery source,
#                    so the join cannot drift from the runner's own globs). A missing, unreadable
#                    or EMPTY list is a typed failure, never "nothing expected, nothing missing".
#   --shards N       the shard count the caller (the CI matrix) expects; cross-checked against
#                    every manifest header, so a matrix and a header that agree on the wrong N
#                    are still caught.
#   --strict-skip    treat a SKIP suite as a finding (default: reported, not failing — the local
#                    gate also tolerates skipped suites as long as something passed).
#
# Manifest format (written by run-all.sh): line 1 `# shard I/N suites=K exit=RC`, then K lines
# `<repo-relative suite path> <PASS|FAIL|SKIP>`.
#
# Findings (each on its own line, prefix `JOIN:`):
#   ABSENT manifest            the path is not a readable regular file
#   CORRUPT manifest           bad/missing header, malformed line, or K != the number of lines
#   SHARD FAILED               the shard's own run-all.sh exit code was non-zero (hermeticity,
#                              teeth, clean-tmp ... gates fail a shard with every suite PASS)
#   SHARD COUNT MISMATCH       headers disagree on N, or differ from --shards, or the number of
#                              manifests is not N
#   MISSING SHARD / DUPLICATE SHARD   shard index I absent / present twice
#   MISSING SUITE / DUPLICATED SUITE / UNEXPECTED SUITE   coverage against the expected list
#   FAILED SUITE / SKIPPED SUITE      outcome (SKIPPED only under --strict-skip)
#
# Exit: 0 = complete and green · 1 = at least one finding · 2 = usage error.
# Never prints OK unless it actually read the expected list and every manifest (anti-silent-zero, §7).

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
USAGE="usage: shard-join.sh [--expected FILE] [--shards N] [--strict-skip] MANIFEST..."

expected_file=""
want_shards=""
strict_skip=""
manifests=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --expected) [[ $# -ge 2 ]] || { echo "--expected needs a FILE; $USAGE" >&2; exit 2; }; expected_file="$2"; shift ;;
    --expected=*) expected_file="${1#--expected=}" ;;
    --shards) [[ $# -ge 2 ]] || { echo "--shards needs N; $USAGE" >&2; exit 2; }; want_shards="$2"; shift ;;
    --shards=*) want_shards="${1#--shards=}" ;;
    --strict-skip) strict_skip=1 ;;
    -*) echo "unknown flag: $1; $USAGE" >&2; exit 2 ;;
    *) manifests+=("$1") ;;
  esac
  shift
done
if [[ -n "$want_shards" && ! "$want_shards" =~ ^[1-9][0-9]{0,2}$ ]]; then
  echo "invalid --shards value '$want_shards': need a positive integer; $USAGE" >&2
  exit 2
fi
if [[ ${#manifests[@]} -eq 0 ]]; then
  echo "no manifests given (an empty download must never read as a pass); $USAGE" >&2
  exit 2
fi

findings=()
add() { findings+=("JOIN: $1"); }

# --- expected list -------------------------------------------------------------------------------
expected=()
list_bad=""
if [[ -n "$expected_file" ]]; then
  if [[ ! -f "$expected_file" || ! -r "$expected_file" ]]; then
    list_bad=1; add "EXPECTED LIST ABSENT: '$expected_file' is not a readable file"
  else
    mapfile -t expected < <(grep -v '^[[:space:]]*$' "$expected_file")
  fi
else
  if ! _list="$(bash "$SCRIPT_DIR/run-all.sh" --list-suites 2>/dev/null)"; then
    list_bad=1; add "EXPECTED LIST UNAVAILABLE: 'run-all.sh --list-suites' failed (install corpus absent or runner broken)"
  else
    mapfile -t expected < <(printf '%s\n' "$_list" | grep -v '^[[:space:]]*$')
  fi
fi
if [[ ${#expected[@]} -eq 0 && -z "$list_bad" ]]; then
  add "EXPECTED LIST EMPTY: zero suites expected, which cannot be a pass"
fi

# --- manifests -----------------------------------------------------------------------------------
declare -A seen_count=() seen_result=() shard_seen=()
shard_n=""
hdr_re='^# shard ([0-9]+)/([0-9]+) suites=([0-9]+) exit=([0-9]+)$'
line_re='^([^[:space:]]+) (PASS|FAIL|SKIP)$'
valid_manifests=0
for m in "${manifests[@]}"; do
  if [[ ! -f "$m" || ! -r "$m" ]]; then add "ABSENT manifest: '$m' is not a readable file"; continue; fi
  mapfile -t _lines < "$m"
  if [[ ${#_lines[@]} -eq 0 ]]; then add "CORRUPT manifest: '$m' is empty (no header)"; continue; fi
  if [[ ! "${_lines[0]}" =~ $hdr_re ]]; then add "CORRUPT manifest: '$m' has no valid header line"; continue; fi
  h_i=$((10#${BASH_REMATCH[1]})); h_n=$((10#${BASH_REMATCH[2]})); h_k=$((10#${BASH_REMATCH[3]})); h_rc=$((10#${BASH_REMATCH[4]}))
  bad=""; _suites=(); _results=()
  for ((_x = 1; _x < ${#_lines[@]}; _x++)); do
    if [[ "${_lines[$_x]}" =~ $line_re ]]; then _suites+=("${BASH_REMATCH[1]}"); _results+=("${BASH_REMATCH[2]}")
    else bad="line $((_x + 1)) malformed"; break; fi
  done
  if [[ -z "$bad" && ${#_suites[@]} -ne $h_k ]]; then bad="header declares suites=$h_k but ${#_suites[@]} line(s) follow (truncated?)"; fi
  if [[ -z "$bad" && ( $h_i -lt 1 || $h_i -gt $h_n ) ]]; then bad="shard index $h_i outside 1..$h_n"; fi
  if [[ -n "$bad" ]]; then add "CORRUPT manifest: '$m' $bad"; continue; fi
  valid_manifests=$((valid_manifests + 1))
  if [[ -z "$shard_n" ]]; then shard_n="$h_n"
  elif [[ "$shard_n" != "$h_n" ]]; then add "SHARD COUNT MISMATCH: '$m' says N=$h_n, an earlier manifest says N=$shard_n"; fi
  if [[ -n "$want_shards" && "$h_n" != "$want_shards" ]]; then add "SHARD COUNT MISMATCH: '$m' says N=$h_n but --shards $want_shards was expected"; fi
  shard_seen["$h_i"]=$(( ${shard_seen[$h_i]:-0} + 1 ))
  if [[ $h_rc -ne 0 ]]; then add "SHARD FAILED: shard $h_i/$h_n exited $h_rc ('$m')"; fi
  for ((_x = 0; _x < ${#_suites[@]}; _x++)); do
    seen_count["${_suites[$_x]}"]=$(( ${seen_count[${_suites[$_x]}]:-0} + 1 ))
    seen_result["${_suites[$_x]}"]="${_results[$_x]}"
  done
done

# --- shard set completeness ----------------------------------------------------------------------
n_expect="${want_shards:-$shard_n}"
if [[ -n "$n_expect" ]]; then
  if [[ ${#manifests[@]} -ne $n_expect ]]; then add "SHARD COUNT MISMATCH: $n_expect shard(s) expected but ${#manifests[@]} manifest(s) given"; fi
  for ((_i = 1; _i <= n_expect; _i++)); do
    case "${shard_seen[$_i]:-0}" in
      0) add "MISSING SHARD: shard $_i/$n_expect has no valid manifest" ;;
      1) ;;
      *) add "DUPLICATE SHARD: shard $_i/$n_expect appears ${shard_seen[$_i]} times" ;;
    esac
  done
elif [[ $valid_manifests -eq 0 ]]; then
  add "NO VALID MANIFEST: none of the ${#manifests[@]} manifest(s) could be read, so no shard count is known"
fi

# --- suite coverage and outcome ------------------------------------------------------------------
declare -A is_expected=()
for s in "${expected[@]+"${expected[@]}"}"; do is_expected["$s"]=1; done
for s in "${expected[@]+"${expected[@]}"}"; do
  c="${seen_count[$s]:-0}"
  if [[ "$c" -eq 0 ]]; then add "MISSING SUITE: $s ran in no shard"
  elif [[ "$c" -gt 1 ]]; then add "DUPLICATED SUITE: $s ran $c times"
  fi
  if [[ "$c" -ge 1 ]]; then
    case "${seen_result[$s]}" in
      FAIL) add "FAILED SUITE: $s" ;;
      SKIP) [[ -z "$strict_skip" ]] || add "SKIPPED SUITE: $s (--strict-skip)" ;;
    esac
  fi
done
while IFS= read -r s; do
  [[ -n "$s" && "${is_expected[$s]+set}" != set ]] && add "UNEXPECTED SUITE: $s is not in the expected list"
done < <(printf '%s\n' "${!seen_count[@]}" | LC_ALL=C sort)

if [[ ${#findings[@]} -eq 0 ]]; then
  echo "Shard join: OK — ${#manifests[@]} shard(s), ${#expected[@]} suite(s), each ran exactly once and passed"
  exit 0
fi
printf '%s\n' "${findings[@]}"
echo "Shard join: FAIL — ${#findings[@]} finding(s) over ${#manifests[@]} manifest(s) and ${#expected[@]} expected suite(s)"
exit 1
