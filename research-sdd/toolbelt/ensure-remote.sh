#!/usr/bin/env bash
# ensure-remote.sh — create a PRIVATE-BY-CONSTRUCTION GitHub remote for a Research-SDD corpus
# and push it (METHODOLOGY §15 "Remote"). The corpora DECOMPILE proprietary systems, so a public
# repo would leak the research — this wrapper makes a public remote UNREACHABLE by construction, not
# by convention. It is NEVER auto-invoked by the loop; the operator runs it once, per target, on consent.
#
# THE SIX-LAYER PRIVATE GUARD (each independently blocks a public leak):
#   1. NO PUBLIC CODE PATH — `--private` is hard-coded on the single `gh repo create`; there is no
#      --public flag and no env var that flips visibility. A public repo cannot be requested here.
#   2. FORCE A PERSONAL ACCOUNT — the owner is resolved from `gh api user` and REFUSED if it is an
#      organization (orgs can carry a default-public creation policy that would override our intent).
#   3. CONSENT GATE — refuses unless `--yes` (or RSDD_ALLOW_REMOTE=1) is present. Network mutation is
#      never implicit.
#   4. PRE-PUSH SECRET SWEEP (two gates) — seeds `.gitignore` with secret-bearing paths BEFORE the remote is
#      added and commits it so the pushed HEAD carries the patterns, then (4b) runs scan-secrets.sh over the
#      corpus and REFUSES on a high-confidence CONTENT hit in text files, and (4c) separately REFUSES if any
#      git-TRACKED file matches a secret-type pattern (*.pem/*.der/*.key/*.p12/*.pfx/id_rsa*/*.jks/*.keystore,
#      security/licenses/certificates/keystore/keyring dirs) — the binary/opaque types scan-secrets.sh can
#      never see because it only opens *.md/config text files. The content scan (4b) covers ALL committed
#      history reachable from HEAD (files across all commits + commit messages) via scan-secrets --committed.
#      4c has an explicit ALLOW list for deliberately committed PUBLIC assets: `.research-sdd/secret-files.conf`
#      (`allow <path-glob>`); an allowed path must be POSITIVELY identified as public material in every committed
#      revision (else refused), allowed paths are reported, stale entries flagged, private keys never allowable.
#   5. CREATE THEN VERIFY visibility BEFORE ANY PUSH — after create, read back `visibility`; if it is not
#      PRIVATE, attempt one forced `--visibility private` and re-read; if STILL not private, HARD ABORT:
#      warn loudly, remove the origin remote, and exit non-zero WITHOUT pushing. The push step is textually
#      AFTER and guarded by this confirmed-private check.
#   6. IDEMPOTENT — if `origin` already resolves, do nothing (never a duplicate repo).
#
# BOUNDS (kit issue #1841): `gh repo create`, `gh repo edit` and the visibility read-back are bounded and run with
# GH_PROMPT_DISABLED=1; the earlier owner lookups (`gh api user`, `gh api users/<owner>`) are not bounded yet. The read-back and
# `gh repo edit` use RSDD_GH_TIMEOUT (default 20 s); `gh repo create` uses its own RSDD_GH_CREATE_TIMEOUT (default 60 s).
# Both take a positive integer of seconds; anything else falls back to the default with a note. A create TIMEOUT is a
# typed DEGRADED + PARTIAL-STATE line (local origin set/absent, remote visibility) with the exact next step; with an
# origin already added the normal verify-then-push guard adopts the repo, otherwise exit 7 (or 6 if it is not private).
#
# Usage: ensure-remote.sh <target-dir> [--yes] [--name <repo>]
#   default repo name: research-<basename-of-target-dir>, slugified to [a-z0-9-].
# Exit: 0 = remote present (created+pushed, or already existed) · 2 = bad args / not a git repo ·
#       3 = no consent · 4 = owner is an organization · 5 = secret leak (refused to push) ·
#       6 = visibility verification failed (HARD ABORT, no push) · 7 = tooling missing / git-or-gh op failed ·
#       8 = dirty working tree (committed-content scan cannot equal what would be pushed).

set -uo pipefail

# --- args -------------------------------------------------------------------
target=""; consent=0; name=""
while [ $# -gt 0 ]; do
  case "$1" in
    --yes)  consent=1; shift;;
    --name) [ $# -ge 2 ] || { echo "REFUSED: --name requires a value" >&2; exit 2; }; name="$2"; shift 2;;
    -*)     echo "unknown flag: $1" >&2; exit 2;;
    *)      target="$1"; shift;;
  esac
done
[ -n "$target" ] && [ -d "$target" ] || { echo "usage: ensure-remote.sh <target-dir> [--yes] [--name <repo>]" >&2; exit 2; }
target="$(cd "$target" && pwd)"

# RSDD-SELF-DIR (kit #1675): own directory from BASH_SOURCE with symlinks followed - never $0 or the caller's cwd.
_rsdd_s="${BASH_SOURCE[0]}"; _rsdd_n=0
while [ -L "$_rsdd_s" ] && [ "$_rsdd_n" -lt 40 ]; do _rsdd_n=$((_rsdd_n + 1)); _rsdd_t="$(readlink -- "$_rsdd_s")" || break; case "$_rsdd_t" in /*) _rsdd_s="$_rsdd_t" ;; *) _rsdd_s="$(dirname -- "$_rsdd_s")/$_rsdd_t" ;; esac; done
if [ -L "$_rsdd_s" ]; then echo "${0##*/}: degraded: self-dir symlink resolution incomplete (hop limit or readlink failure) at $_rsdd_s" >&2; fi
_RSDD_SELF="$(CDPATH='' cd -- "$(dirname -- "$_rsdd_s")" && pwd -P)"; unset _rsdd_s _rsdd_n _rsdd_t
HERE="$_RSDD_SELF"
SCAN="$HERE/scan-secrets.sh"
# Shared bounded visibility probe (kit issue #1820): one default, GH_PROMPT_DISABLED=1, typed non-decided results.
# shellcheck source=lib/gh-visibility.sh
. "$HERE/lib/gh-visibility.sh" 2>/dev/null || { echo "REFUSED: lib/gh-visibility.sh not found next to this script — cannot verify visibility before push." >&2; exit 7; }

# target must already be a git repo (research-sdd-init.sh runs `git init` in the target — §15).
git -C "$target" rev-parse --git-dir >/dev/null 2>&1 || {
  echo "REFUSED: $target is not a git repository — run research-sdd-init.sh first." >&2; exit 2; }

# --- LAYER 6: idempotent — an existing origin short-circuits everything (no duplicate repo) ----------
if url="$(git -C "$target" remote get-url origin 2>/dev/null)" && [ -n "$url" ]; then
  echo "ensure-remote: origin already set ($url) — nothing to do."
  exit 0
fi

# --- LAYER 3: consent gate (before ANY network call) ------------------------------------------------
if [ "$consent" != 1 ] && [ "${RSDD_ALLOW_REMOTE:-}" != 1 ]; then
  echo "REFUSED: creating a remote pushes the corpus to GitHub. Re-run with --yes (or RSDD_ALLOW_REMOTE=1)" >&2
  echo "         when you consent to a PRIVATE GitHub remote for $(basename "$target")." >&2
  exit 3
fi

command -v gh  >/dev/null 2>&1 || { echo "REFUSED: gh CLI not found — cannot create a remote." >&2; exit 7; }

# --- LAYER 2: force a PERSONAL account (refuse an organization owner) --------------------------------
owner="$(gh api user -q .login 2>/dev/null)"
[ -n "$owner" ] || { echo "REFUSED: could not resolve your GitHub login (is gh authenticated?)." >&2; exit 7; }
if ! otype="$(gh api "users/$owner" -q .type 2>/dev/null)" || [ -z "$otype" ]; then
  echo "REFUSED: could not verify that owner '$owner' is a personal account (gh api failed)." >&2
  exit 7
fi
if [ "$otype" = "Organization" ]; then
  echo "REFUSED: resolved owner '$owner' is an ORGANIZATION — orgs can enforce a default-public creation" >&2
  echo "         policy that would override --private. Create under a personal account instead." >&2
  exit 4
fi

# repo name: default research-<basename>, slugified to [a-z0-9-]; --name overrides.
if [ -n "$name" ]; then repo="$name"; else repo="research-$(basename "$target")"; fi
repo="$(printf '%s' "$repo" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' | sed 's/-\{2,\}/-/g; s/^-//; s/-$//')"
[ -n "$repo" ] || { echo "REFUSED: could not derive a valid repo name." >&2; exit 2; }

echo "== ensure-remote: $(basename "$target") =="
echo "   owner : $owner (personal)"
echo "   repo  : $repo (PRIVATE)"

# --- LAYER 4a: seed .gitignore with secret-bearing paths BEFORE adding the remote -------------------
# Cross-checks the REDACTION CHECKLIST (PROMPT-LOOP): keys, certs, keystores/keyrings never get tracked.
# Research firmware dumps (*.bin) are deliberately LEFT to the operator's judgment.
gi="$target/.gitignore"
if [ -f "$gi" ] && [ -s "$gi" ] && [ "$(tail -c1 "$gi" 2>/dev/null)" != "" ]; then printf '\n' >> "$gi"; fi
for pat in 'security/' 'licenses/' 'certificates/' '*.pem' '*.der' '*.key' '*.p12' '*.pfx' \
           'id_rsa*' 'keystore/' 'keyring/' '*.jks' '*.keystore'; do
  grep -qxF "$pat" "$gi" 2>/dev/null || printf '%s\n' "$pat" >> "$gi"
done
# commit the seeded .gitignore so the pushed HEAD actually carries the ignore patterns (best-effort: a
# nothing-to-commit case must never abort the guard).
if ! git -C "$target" diff --quiet -- .gitignore 2>/dev/null || [ -n "$(git -C "$target" ls-files --others --exclude-standard -- .gitignore)" ]; then
  git -C "$target" add .gitignore && git -C "$target" commit -q -m "chore: ignore secret-bearing paths (ensure-remote)" -- .gitignore || true
fi

# --- LAYER 4b-pre: refuse on a dirty working tree (committed scan must equal what is pushed) -----
# scan-secrets --committed scans what HEAD contains; a dirty working tree means the working-tree
# content diverges from the committed HEAD, so a redaction only in the working tree (without
# committing) would pass the committed-content scan while the pushed HEAD still carries the secret
# (#955 Repro 2). Fail closed: if `git status` itself fails we cannot verify, so refuse.
if ! _wt_status="$(git -C "$target" status --porcelain 2>/dev/null)"; then
  echo "REFUSED: could not check working tree status (git status --porcelain failed) — cannot" >&2
  echo "         guarantee the committed-content scan matches what would be pushed." >&2
  exit 7
fi
if [ -n "$_wt_status" ]; then
  echo "REFUSED: the working tree is dirty — a redaction applied to the working tree without" >&2
  echo "         committing would pass the committed-content scan while the pushed HEAD still" >&2
  echo "         carries the original secret. Commit, add to .gitignore, or stash with" >&2
  echo "         'git stash -u', then re-run." >&2
  exit 8
fi

# --- LAYER 4b: pre-push secret sweep (fail closed — no scanner means we cannot verify, so we refuse) --
# Covers CONTENT secrets in *.md/config text files in COMMITTED content at HEAD (scan-secrets
# --committed). Previously scanned only the corpus working-tree subdir (#955).
[ -f "$SCAN" ] || { echo "REFUSED: scan-secrets.sh not found at $SCAN — cannot verify committed content before push." >&2; exit 7; }
_scan_rc=0
bash "$SCAN" --committed "$target" >/dev/null 2>&1 || _scan_rc=$?
case "$_scan_rc" in
  0) ;;  # clean committed content
  1) echo "REFUSED: scan-secrets.sh --committed found a high-confidence secret VALUE in the" >&2
     echo "         committed history — NOT pushing. The git history must be rewritten to remove" >&2
     echo "         the secret value (e.g. git filter-repo / BFG). Cite structure, not value —" >&2
     echo "         SECRETS DISCIPLINE applies." >&2
     exit 5 ;;
  3) echo "REFUSED: scan-secrets.sh --committed is degraded (git unavailable or no commits) —" >&2
     echo "         cannot verify committed content before push." >&2
     exit 7 ;;
  *) echo "REFUSED: scan-secrets.sh --committed failed (exit $_scan_rc) — cannot verify committed content before push." >&2
     exit 7 ;;
esac

# --- LAYER 4c: refuse any git-TRACKED secret-type FILE (belt for the binary types scan-secrets.sh cannot --
# open/see: *.pem/*.der/*.key/*.p12/*.pfx/id_rsa*/*.jks/*.keystore and the security/licenses/certificates/
# keystore/keyring dirs). A tracked binary key/cert would pass the content scan (it is never opened) and
# get pushed — this gate closes that gap with git's own pathspec matching (git's default `*` DOES cross
# `/`, so an extension pattern like `*.key` catches a key at ANY depth/location; the directory patterns
# are root-anchored to the corpus root, which is where the SECRETS DISCIPLINE places security/ etc.).
# FAIL CLOSED (mirror Layer 4b): if `ls-files` itself errors, we cannot verify — refuse rather than proceed.
# `ls-files -z` emits NUL-delimited paths; converting NUL→newline INSIDE the pipe (before the command
# substitution captures it) avoids bash's "ignored null byte in input" warning that a raw `$(... -z)` capture
# emits. `set -o pipefail` (top of file) makes a git failure still propagate as the substitution's non-zero
# exit, so the fail-closed refusal below is preserved. tr never fails, so a clean run stays exit 0.
if ! _tracked_raw="$(git -C "$target" ls-files -z -- \
  '*.pem' '*.der' '*.key' '*.p12' '*.pfx' 'id_rsa*' '*.jks' '*.keystore' \
  'security/*' 'licenses/*' 'certificates/*' 'keystore/*' 'keyring/*' 2>/dev/null | tr '\0' '\n')"; then
  echo "REFUSED: could not enumerate tracked files (git ls-files failed) — cannot verify no secret is tracked." >&2
  exit 7
fi

# 4c ALLOW LIST (kit issue #1943). A dual-use corpus can deliberately commit PUBLIC key/licence artifacts (public-key
# SPKI DERs, self-issued certs). `<target>/.research-sdd/secret-files.conf` lists them, one `allow <path-glob>` per
# line (`#` comments and blank lines ignored). The glob is matched against the refused tracked path the way git's
# default pathspec does (`*` crosses `/`). Rules, none silent (§7):
#   * allow is per path/glob — a blanket glob (only `*` `?` `/`), an absolute path or a `..` component is MALFORMED;
#   * a malformed line is a typed config error naming file:line (exit 2) — nothing is created or pushed;
#   * every allowed path is REPORTED as an `ALLOWED:` line; an entry matching no refused path is `STALE:` (non-fatal);
#   * POSITIVE identification (not a deny list): an allowed path is honoured only if EVERY committed blob of it is
#     positively identified as PUBLIC material. The blobs are every id (pre-image AND post-image of each raw line;
#     the all-zero id skipped) of `git log --all -m --full-history --no-renames --raw`, so side branches merged away
#     are walked too; each is read with `git cat-file blob` into a mktemp copy (removed on EXIT/INT/TERM) — never the
#     worktree, so assume-unchanged / an overwritten key cannot hide. A blob is public only if it is:
#       - PEM in which EVERY armour block is one of CERTIFICATE, PUBLIC KEY, RSA PUBLIC KEY, X509 CRL, TRUSTED
#         CERTIFICATE (any other armour anywhere refuses), whose base64 payload DECODES to DER that matches its label
#         (a certificate or SPKI for CERTIFICATE/PUBLIC KEY; RSAPublicKey; CertificateList; certificate + trust
#         SEQUENCE), whose in-block lines are all base64, and with no base64/hex line of 16+ characters outside blocks;
#       - DER that parses end-to-end as an X.509 Certificate (SEQUENCE{SEQUENCE{[0] version ...}, SEQUENCE, BIT STRING})
#         or as an SPKI whose AlgorithmIdentifier OID is a public-key algorithm (rsaEncryption, id-ecPublicKey,
#         Ed25519, Ed448, X25519, X448);
#       - a plain-text licence: no NUL/control bytes, no PRIVATE/SECRET/-----BEGIN/SSH2 markers, no run of 32+ hex
#         digits or 40+ base64 characters ANYWHERE in a line, and no line that is only 16+ hex digits once blanks and
#         colons are dropped (hex-byte dumps).
#     Anything else -> `REFUSED (not positively public): <path>` (exit 5). A Git LFS pointer blob (content not in the
#     repository) -> `REFUSED (LFS pointer: content not inspectable): <path>` (exit 5). Explicit private markers (PEM
#     PRIVATE KEY, DER PKCS#8/PKCS#1/SEC1 version-0/1 INTEGER, PuTTY-User-Key-File, AGE-SECRET-KEY, SSH2 armour) and
#     the keystore/identity file TYPES (id_rsa*, *.p12, *.pfx, *.jks, *.keystore) stay a hard refusal (exit 5). Any
#     git failure while reading history, a missing base64/od/mktemp, or a path with no committed blob, fails closed
#     (exit 7). Scope is unchanged: only what the patterns above refuse can be allowed (a NESTED licenses/ or
#     certificates/ dir is not refused).
# rsdd_tlv HEX OFFSET — parse one DER TLV at a char offset into d_tag d_len d_hdr (hdr in hex chars); 1 = malformed/overrun.
rsdd_tlv() {
  local h="$1" o="$2" lb nb
  d_tag="${h:o:2}"; lb="${h:o+2:2}"
  [ "${#d_tag}" = 2 ] && [ "${#lb}" = 2 ] || return 1
  if [ $((16#$lb)) -lt 128 ]; then d_len=$((16#$lb)); d_hdr=4
  else
    nb=$((16#$lb - 128))
    { [ "$nb" -ge 1 ] && [ "$nb" -le 3 ]; } || return 1
    [ "${#h}" -ge $((o+4+2*nb)) ] || return 1
    d_len=$((16#${h:o+4:2*nb})); d_hdr=$((4+2*nb))
  fi
  [ $((o+d_hdr+2*d_len)) -le "${#h}" ]
}
# rsdd_der_public HEX — 0 = X.509 Certificate or SPKI with a public-key OID, spanning the whole input; 1 = anything else.
rsdd_der_public() {
  local h="$1" top f_o f_hdr f_len nxt o_hdr o_len oid
  rsdd_tlv "$h" 0 && [ "$d_tag" = 30 ] || return 1
  top=$d_hdr; [ $((d_hdr+2*d_len)) = "${#h}" ] || return 1
  rsdd_tlv "$h" "$top" && [ "$d_tag" = 30 ] || return 1
  f_o=$top; f_hdr=$d_hdr; f_len=$d_len; nxt=$((f_o+f_hdr+2*f_len))
  case "${h:$((f_o+f_hdr)):10}" in
    a003020100|a003020101|a003020102)   # X.509: tbsCertificate{[0] version}, signatureAlgorithm, signatureValue
      rsdd_tlv "$h" "$nxt" && [ "$d_tag" = 30 ] || return 1
      nxt=$((nxt+d_hdr+2*d_len))
      rsdd_tlv "$h" "$nxt" && [ "$d_tag" = 03 ] || return 1
      [ $((nxt+d_hdr+2*d_len)) = "${#h}" ];;
    06*)                                # SPKI: AlgorithmIdentifier{OID, params}, subjectPublicKey BIT STRING
      rsdd_tlv "$h" "$((f_o+f_hdr))" && [ "$d_tag" = 06 ] || return 1
      o_hdr=$d_hdr; o_len=$d_len
      [ $((f_o+f_hdr+o_hdr+2*o_len)) -le "$nxt" ] || return 1
      oid="${h:$((f_o+f_hdr+o_hdr)):$((2*o_len))}"
      case "$oid" in 2a864886f70d010101|2a8648ce3d0201|2b6570|2b6571|2b656e|2b656f) :;; *) return 1;; esac
      rsdd_tlv "$h" "$nxt" && [ "$d_tag" = 03 ] || return 1
      [ $((nxt+d_hdr+2*d_len)) = "${#h}" ];;
    *) return 1;;
  esac
}
# rsdd_pem_block_ok LABEL HEX — the DER payload of one PEM block must really be what its label claims (public material).
rsdd_pem_block_ok() {
  local lab="$1" h="$2" o end t
  case "$lab" in
    CERTIFICATE|"PUBLIC KEY") rsdd_der_public "$h";;
    "RSA PUBLIC KEY")                    # PKCS#1 RSAPublicKey: SEQUENCE{INTEGER n, INTEGER e}
      rsdd_tlv "$h" 0 && [ "$d_tag" = 30 ] && [ $((d_hdr+2*d_len)) = "${#h}" ] || return 1
      o=$d_hdr
      for t in 02 02; do rsdd_tlv "$h" "$o" && [ "$d_tag" = "$t" ] || return 1; o=$((o+d_hdr+2*d_len)); done
      [ "$o" = "${#h}" ];;
    "X509 CRL")                          # CertificateList: SEQUENCE{tbsCertList, signatureAlgorithm, signatureValue}
      rsdd_tlv "$h" 0 && [ "$d_tag" = 30 ] && [ $((d_hdr+2*d_len)) = "${#h}" ] || return 1
      o=$d_hdr
      for t in 30 30 03; do rsdd_tlv "$h" "$o" && [ "$d_tag" = "$t" ] || return 1; o=$((o+d_hdr+2*d_len)); done
      [ "$o" = "${#h}" ];;
    "TRUSTED CERTIFICATE")               # a Certificate followed by one SEQUENCE of trust settings
      rsdd_tlv "$h" 0 || return 1
      end=$((d_hdr+2*d_len)); rsdd_der_public "${h:0:end}" || return 1
      [ "$end" = "${#h}" ] && return 0
      rsdd_tlv "$h" "$end" && [ "$d_tag" = 30 ] && [ $((end+d_hdr+2*d_len)) = "${#h}" ];;
    *) return 1;;
  esac
}
# rsdd_pem_public FILE — 0 only if EVERY armour block decodes (base64) to DER matching its label, every line inside a
# block is base64, and no line outside a block looks like encoded data (base64/hex run of 16+ characters).
rsdd_pem_public() {
  local l lab="" b64="" hex nblk=0 begin_re='^-----BEGIN (.*)-----$'
  while IFS= read -r l || [ -n "$l" ]; do
    l="${l%$'\r'}"
    if [ -z "$lab" ]; then
      if [[ "$l" =~ $begin_re ]]; then lab="${BASH_REMATCH[1]}"; b64=""; continue; fi
      if [[ "$l" =~ ^[A-Za-z0-9+/=]{16,}$ ]]; then return 1; fi
    elif [ "$l" = "-----END $lab-----" ]; then
      hex="$(printf '%s' "$b64" | base64 -d 2>/dev/null | od -An -v -tx1 | tr -d ' \n')" || return 1
      [ -n "$hex" ] && rsdd_pem_block_ok "$lab" "$hex" || return 1
      lab=""; nblk=$((nblk+1))
    else
      [[ "$l" =~ ^[A-Za-z0-9+/=]*$ ]] || return 1
      b64="$b64$l"
    fi
  done <"$1"
  [ -z "$lab" ] && [ "$nblk" -gt 0 ]
}
# rsdd_cnt GREP-ARGS... — print the matching-line count; return 2 if grep itself failed (exit >1).
rsdd_cnt() { local c rc; c="$(grep -ac "$@" 2>/dev/null)"; rc=$?; [ "$rc" -le 1 ] || return 2; printf '%s' "$c"; }
# rsdd_text_public FILE — 0 = positively public PEM armour or licence text; 1 = not; 2 = could not be read.
rsdd_text_public() {
  local f="$1" h hn n_all n_ok e_all e_ok rc l t lab='(CERTIFICATE|PUBLIC KEY|RSA PUBLIC KEY|X509 CRL|TRUSTED CERTIFICATE)'
  h="$(od -An -v -tx1 -N 65537 -- "$f" 2>/dev/null | tr -d ' \n')" || return 2
  [ -n "$h" ] && [ "${#h}" -le 131072 ] || return 1
  hn="$(tr -d '\000' <"$f" 2>/dev/null | od -An -v -tx1 -N 65537 | tr -d ' \n')" || return 2
  [ "${#hn}" = "${#h}" ] || return 1                         # NUL byte -> binary
  LC_ALL=C grep -aq $'[\001-\010\013\014\016-\037\177]' "$f" 2>/dev/null; rc=$?
  case "$rc" in 0) return 1;; 1) :;; *) return 2;; esac      # control bytes -> binary
  if grep -aq -- '-----BEGIN' "$f" 2>/dev/null; then
    n_all="$(rsdd_cnt -- '-----BEGIN' "$f")" || return 2
    n_ok="$(rsdd_cnt -E -- "^-----BEGIN $lab-----"$'\r''?$' "$f")" || return 2
    e_all="$(rsdd_cnt -- '-----END' "$f")" || return 2
    e_ok="$(rsdd_cnt -E -- "^-----END $lab-----"$'\r''?$' "$f")" || return 2
    [ "$n_all" -gt 0 ] && [ "$n_all" = "$n_ok" ] && [ "$e_all" = "$e_ok" ] && [ "$n_ok" = "$e_ok" ] || return 1
    rc=0; grep -aEq -- '-----(BEGIN|END).*-----(BEGIN|END)' "$f" 2>/dev/null || rc=$?
    case "$rc" in 1) rsdd_pem_public "$f"; return $?;; 0) return 1;; *) return 2;; esac
  fi
  grep -aEq -- 'PRIVATE|SECRET|---- BEGIN|PuTTY-User-Key-File' "$f" 2>/dev/null; rc=$?
  case "$rc" in 0) return 1;; 1) :;; *) return 2;; esac
  # key material hides as encoded runs ANYWHERE in a line, not only as whole lines: 32+ hex digits or 40+ base64 chars.
  grep -aEq -- '[0-9a-fA-F]{32,}' "$f" 2>/dev/null; rc=$?
  case "$rc" in 0) return 1;; 1) :;; *) return 2;; esac
  grep -aEq -- '[A-Za-z0-9+/=]{40,}' "$f" 2>/dev/null; rc=$?
  case "$rc" in 0) return 1;; 1) :;; *) return 2;; esac
  # ... and as hex-byte dumps ("00 11 22 ..." / "00:11:22:..."): a line of 16+ hex digits once blanks and colons go.
  while IFS= read -r l || [ -n "$l" ]; do
    t="${l//[[:space:]:]/}"
    if [ "${#t}" -ge 16 ] && [[ "$t" =~ ^[0-9a-fA-F]+$ ]]; then return 1; fi
  done <"$f"
  grep -aq '[[:alnum:]]' "$f" 2>/dev/null; rc=$?
  case "$rc" in 0) return 0;; 1) return 1;; *) return 2;; esac
}
# rsdd_classify FILE — 0 = positively public · 1 = explicit private-key marker · 2 = unreadable · 3 = not positively public
# · 4 = Git LFS pointer.
rsdd_classify() {
  local f="$1" h rc rest
  # A Git LFS pointer stands in for content that is not in this repository's objects: it cannot be inspected here.
  grep -aq -- '^version https://git-lfs.github.com/spec/v1' "$f" 2>/dev/null; rc=$?
  case "$rc" in 0) return 4;; 1) :;; *) return 2;; esac
  grep -aEq -- 'PRIVATE KEY( BLOCK)?-----|AGE-SECRET-KEY|PuTTY-User-Key-File|---- BEGIN SSH2' "$f" 2>/dev/null; rc=$?
  case "$rc" in 0) return 1;; 1) :;; *) return 2;; esac
  h="$(od -An -v -tx1 -N 65537 -- "$f" 2>/dev/null | tr -d ' \n')" || return 2
  if [ "${h:0:2}" = 30 ]; then
    case "${h:2:2}" in 81) rest="${h:6}";; 82) rest="${h:8}";; 83) rest="${h:10}";; 84) rest="${h:12}";; *) rest="${h:4}";; esac
    case "$rest" in 020100*|020101*) return 1;; esac
    if [ "${#h}" -le 131072 ] && rsdd_der_public "$h"; then return 0; fi
  fi
  rsdd_text_public "$f"; rc=$?
  case "$rc" in 0) return 0;; 1) return 3;; *) return 2;; esac
}
allow_globs=(); allow_lines=(); allow_hit=()
allow_conf="$target/.research-sdd/secret-files.conf"
allow_rel=".research-sdd/secret-files.conf"
if [ -e "$allow_conf" ] || [ -L "$allow_conf" ]; then
  if [ ! -f "$allow_conf" ] || [ ! -r "$allow_conf" ]; then
    echo "REFUSED: $allow_rel exists but is not a readable regular file — cannot read the allow list." >&2; exit 7
  fi
  _ln=0
  while IFS= read -r _l || [ -n "$_l" ]; do
    _ln=$((_ln+1)); _l="${_l%$'\r'}"
    read -r _kw _g _extra <<<"$_l"
    case "$_kw" in ''|'#'*) continue;; esac
    _why=""
    if [ "$_kw" != allow ]; then _why="unknown directive '$_kw'"
    elif [ -z "$_g" ]; then _why="'allow' needs a path glob"
    elif [ -n "$_extra" ]; then _why="exactly one path glob per line (got extra text)"
    elif [[ "$_g" == *'['* || "$_g" == *']'* ]]; then _why="bracket class in '$_g' (a glob may only use '*' and '?')"
    elif [[ "$_g" == *'!('* || "$_g" == *'@('* || "$_g" == *'+('* || "$_g" == *'*('* || "$_g" == *'?('* ]]; then
      _why="extglob operator in '$_g' (a glob may only use '*' and '?')"
    elif [ -z "$(printf '%s' "$_g" | tr -d '[]!()@+|*?/.')" ]; then _why="blanket glob '$_g' (needs at least one literal character)"
    else
      case "/$_g/" in //*) _why="absolute path '$_g' (use a path relative to the corpus root)";; esac
      case "/$_g/" in */../*) _why="'..' component in '$_g'";; esac
    fi
    if [ -n "$_why" ]; then
      echo "REFUSED: $allow_rel:$_ln: $_why — expected 'allow <path-glob>'." >&2
      exit 2
    fi
    allow_globs+=("$_g"); allow_lines+=("$_ln"); allow_hit+=(0)
  done < "$allow_conf"
fi

unallowed=""; priv_bad=""; notpub=""; lfsptr=""
# The blob copy lives in a mktemp file only while it is classified; EXIT/INT/TERM remove it if the run is cut short.
_tmp=""
rsdd_cleanup() { if [ -n "${_tmp:-}" ]; then rm -f "$_tmp"; fi; }
trap rsdd_cleanup EXIT
trap 'rsdd_cleanup; exit 130' INT
trap 'rsdd_cleanup; exit 143' TERM
if [ "${#allow_globs[@]}" -gt 0 ]; then
  for _t in base64 od mktemp; do
    command -v "$_t" >/dev/null 2>&1 || { echo "REFUSED: '$_t' not found — cannot positively identify allowed files." >&2; exit 7; }
  done
fi
while IFS= read -r _p; do
  [ -n "$_p" ] || continue
  _m=-1
  for _i in "${!allow_globs[@]}"; do
    # shellcheck disable=SC2053  # the unquoted right side is the glob
    if [[ $_p == ${allow_globs[$_i]} ]]; then allow_hit[_i]=1; [ "$_m" -ge 0 ] || _m=$_i; fi
  done
  if [ "$_m" -lt 0 ]; then unallowed="$unallowed $_p"; continue; fi
  case "${_p##*/}" in
    id_rsa*|*.p12|*.pfx|*.jks|*.keystore) priv_bad="$priv_bad $_p"; continue;;
  esac
  # EVERY committed blob of the path (all refs, merges included, side branches merged away too) is read from the
  # object store and classified, both the pre-image and the post-image id of every raw diff line.
  if ! _log="$(git --literal-pathspecs -C "$target" log --all -m --full-history --no-renames --format= --raw --no-abbrev -- "$_p" 2>/dev/null)"; then
    echo "REFUSED: could not read the git history of '$_p' (git log failed) — cannot verify it is public." >&2; exit 7
  fi
  _seen=" "; _nblob=0; _state=ok
  while read -r _m1 _m2 _old _new _st _rest; do
    case "$_m1" in :*) :;; *) continue;; esac
    for _id in "$_old" "$_new"; do
      case "$_id" in ''|*[!0-9a-f]*) echo "REFUSED: unparseable git history for '$_p' — cannot verify it is public." >&2; exit 7;; esac
      case "$_id" in *[!0]*) :;; *) continue;; esac          # all-zero id = no blob on that side
      case "$_seen" in *" $_id "*) continue;; esac
      _seen="$_seen$_id "; _nblob=$((_nblob+1))
      if ! _tmp="$(mktemp)"; then _tmp=""; echo "REFUSED: mktemp failed — cannot verify '$_p' is public." >&2; exit 7; fi
      if ! git -C "$target" cat-file blob "$_id" >"$_tmp" 2>/dev/null; then
        echo "REFUSED: could not read blob $_id of '$_p' (git cat-file failed) — cannot verify it is public." >&2; exit 7
      fi
      _rc=0; rsdd_classify "$_tmp" || _rc=$?
      rm -f "$_tmp"; _tmp=""
      case "$_rc" in
        0) :;;
        1) _state=priv; break;;
        3) _state=notpub; break;;
        4) _state=lfs; break;;
        *) echo "REFUSED: could not classify blob $_id of '$_p' — cannot verify it is public." >&2; exit 7;;
      esac
    done
    [ "$_state" = ok ] || break
  done <<<"$_log"
  if [ "$_nblob" = 0 ]; then
    echo "REFUSED: no committed blob found for '$_p' — cannot verify it is public." >&2; exit 7
  fi
  case "$_state" in
    priv)   priv_bad="$priv_bad $_p";;
    notpub) notpub="$notpub $_p";;
    lfs)    lfsptr="$lfsptr $_p";;
    *)      echo "ALLOWED: $_p ($allow_rel:${allow_lines[$_m]} allow ${allow_globs[$_m]}; $_nblob blob(s) positively public)";;
  esac
done <<<"$_tracked_raw"
for _i in "${!allow_globs[@]}"; do
  [ "${allow_hit[$_i]}" = 1 ] || echo "STALE: $allow_rel:${allow_lines[$_i]} 'allow ${allow_globs[$_i]}' matches no refused tracked path — remove it." >&2
done
if [ -n "${priv_bad// }" ]; then
  echo "REFUSED: allowed path(s) contain private key material or are keystore/identity files:$priv_bad" >&2
  echo "         a private key can never be allowed — untrack it (git rm --cached) and cite it by structure + sha256." >&2
  exit 5
fi
if [ -n "${lfsptr// }" ]; then
  for _p in $lfsptr; do echo "REFUSED (LFS pointer: content not inspectable): $_p" >&2; done
  echo "         the real content lives outside this repository's objects, so it cannot be shown to be public." >&2
  exit 5
fi
if [ -n "${notpub// }" ]; then
  for _p in $notpub; do echo "REFUSED (not positively public): $_p" >&2; done
  echo "         an allowed path must be positively identified as public (PEM cert/public key, DER cert/SPKI, licence text)" >&2
  echo "         in EVERY committed revision; anything else stays refused. Untrack it and cite it by structure + sha256." >&2
  exit 5
fi
tracked_secrets="${unallowed# }"
if [ -n "${tracked_secrets// }" ]; then
  echo "REFUSED: secret-bearing file(s) are git-TRACKED and would be pushed: $tracked_secrets" >&2
  echo "         scan-secrets.sh cannot see these binary types. Untrack them first:" >&2
  echo "         git -C \"$target\" rm --cached <file> ; ensure they are in .gitignore ; commit ; re-run." >&2
  exit 5
fi

# --- LAYER 1 + 5: create PRIVATE, then VERIFY visibility BEFORE ANY push -----------------------------
echo ">> creating PRIVATE remote $owner/$repo"
# read_vis prints PUBLIC|PRIVATE|INTERNAL when decided, else UNKNOWN(<typed state>) — a stalled, failing or
# unrecognised probe is NEVER PRIVATE (the guard below only passes on a literal PRIVATE).
read_vis() { if gh_visibility_probe gh "$owner/$repo"; then printf '%s' "$GHV_STATE"; else printf 'UNKNOWN(%s)' "$GHV_STATE"; fi; }

# `gh repo create` is bounded (kit issue #1841) by its OWN knob: RSDD_GH_CREATE_TIMEOUT seconds (a positive integer;
# default 60, larger than the read-only visibility probe's RSDD_GH_TIMEOUT default of 20 because a create is a write
# plus a remote add; anything else falls back to 60 with a note). GH_PROMPT_DISABLED=1 as for every bounded gh call.
GHV_BOUND_ENV=RSDD_GH_CREATE_TIMEOUT GHV_BOUND_DEFAULT=60 gh_bounded_run gh repo create "$owner/$repo" --private --source "$target" --remote origin --disable-wiki
create_rc=$?
if [ "${GHV_BAD_TIMEOUT:-0}" = 1 ]; then echo "   note: RSDD_GH_CREATE_TIMEOUT='${RSDD_GH_CREATE_TIMEOUT-60}' is not a positive integer — using the default 60s" >&2; fi
if [ "$create_rc" != 0 ]; then
  if [ "$GHV_STATE" != TIMEOUT ]; then
    echo "REFUSED: gh repo create failed." >&2; exit 7
  fi
  # A TIMEOUT leaves the outcome UNKNOWN: the repo may exist on GitHub and `--source --remote origin` may already have
  # added the local origin. Observe both READ-ONLY, name the partial state, and never assume either way.
  if cur_origin="$(git -C "$target" remote get-url origin 2>/dev/null)" && [ -n "$cur_origin" ]; then have_origin=configured; else have_origin=absent; fi
  tvis="$(read_vis)"
  echo "DEGRADED: gh repo create timed out after ${GHV_BOUND}s — PARTIAL-STATE local origin=$have_origin, remote $owner/$repo visibility=$tvis" >&2
  [ -n "${GHV_NOTE:-}" ] && echo "   $GHV_NOTE" >&2
  case "$tvis" in
    UNKNOWN*)
      # Visibility could not be read: the repo may exist with ANY visibility. Never adopt it and never call a re-run safe.
      # Remove the origin the create may have added so a re-run cannot short-circuit onto an unverified repo.
      # The removal's exit status is CHECKED (kit issue #1854): a failed removal leaves the unverified origin in place,
      # so the message must name it instead of claiming it is gone.
      origin_left=0
      if [ "$have_origin" = configured ]; then
        if ! git -C "$target" remote remove origin >/dev/null 2>&1; then origin_left=1; fi
      fi
      if [ "$origin_left" = 1 ]; then
        echo "   PARTIAL-STATE ORIGIN-LEFT: 'git remote remove origin' FAILED — the unverified local origin $cur_origin is STILL configured; the repo $owner/$repo may exist with an unknown visibility; nothing pushed." >&2
        echo "   Remove it by hand (git -C \"$target\" remote remove origin) — a re-run would short-circuit onto that unverified origin." >&2
      else
        echo "   PARTIAL-STATE UNKNOWN: the repo $owner/$repo may exist with an unknown visibility; any local origin was removed; nothing pushed." >&2
      fi
      echo "   Next: check https://github.com/$owner/$repo by hand (delete it, or set it private) BEFORE re-running ensure-remote.sh — a re-run is NOT safe until its visibility is known." >&2
      exit 7 ;;
  esac
  if [ "$have_origin" = configured ]; then
    # Adopt: fall through to the SAME create-then-verify guard below. It re-reads visibility, forces private once,
    # hard-aborts (exit 6, origin removed, no push) unless the repo is confirmed PRIVATE, and only then pushes. A re-run
    # after any abort starts clean (no origin left behind), so it can never short-circuit onto an unverified repo.
    echo "   next: local origin is configured — verifying the existing remote below; it is pushed ONLY if confirmed PRIVATE." >&2
  else
    case "$tvis" in
      PRIVATE)
        echo "   the repo exists PRIVATE but no local origin was added. Nothing pushed. Next: git -C \"$target\" remote add origin https://github.com/$owner/$repo.git" >&2
        echo "   and push it yourself (git push -u origin HEAD --no-follow-tags); re-running this script would fail on 'repo already exists'." >&2
        exit 7 ;;
      *)
        echo "!! HARD ABORT: a non-private repo ($tvis) exists at https://github.com/$owner/$repo — DELETE IT MANUALLY" >&2
        echo "   (this wrapper has NO delete_repo scope). Nothing pushed; no local origin was added." >&2
        exit 6 ;;
    esac
  fi
fi

vis="$(read_vis)"
if [ "$vis" != "PRIVATE" ]; then
  echo "   visibility read back as '$vis' — forcing --visibility private once" >&2
  # Bounded (kit issue #1841). The outcome is deliberately NOT trusted either way: a timed-out or failed edit is typed
  # DEGRADED and the re-read below is the only authority on what the repo is now.
  if ! gh_bounded_run gh repo edit "$owner/$repo" --visibility private >/dev/null 2>&1; then
    if [ "$GHV_STATE" = TIMEOUT ]; then
      echo "   DEGRADED: gh repo edit timed out after ${GHV_BOUND}s — outcome unknown, re-reading visibility" >&2
      if [ -n "${GHV_NOTE:-}" ]; then echo "   $GHV_NOTE" >&2; fi
    else
      echo "   DEGRADED: gh repo edit failed (exit ${GHV_RC}) — re-reading visibility" >&2
    fi
  fi
  vis="$(read_vis)"
fi
if [ "$vis" != "PRIVATE" ]; then
  echo "!! HARD ABORT: a non-private repo exists at https://github.com/$owner/$repo — DELETE IT MANUALLY" >&2
  echo "   (this wrapper has NO delete_repo scope). Attempting to remove the origin remote; NOT pushing." >&2
  # The removal's status is CHECKED (kit issue #1854), exactly as on the UNKNOWN path: a failed removal that leaves an
  # origin behind is named, never silent. (A failed removal with no origin left is the old silent no-op.)
  git -C "$target" remote remove origin >/dev/null 2>&1; abort_rm_rc=$?
  if [ "$abort_rm_rc" != 0 ] && left_origin="$(git -C "$target" remote get-url origin 2>/dev/null)" && [ -n "$left_origin" ]; then
    echo "   PARTIAL-STATE ORIGIN-LEFT: 'git remote remove origin' FAILED — the local origin $left_origin is STILL configured and points at a NON-PRIVATE repo. Remove it by hand (git -C \"$target\" remote remove origin)." >&2
  fi
  exit 6
fi

# Push is textually AFTER and GUARDED BY the confirmed-private check above.
echo ">> confirmed PRIVATE — pushing corpus"
# m4: --no-follow-tags prevents annotated tag messages (which may contain secrets) from being
# pushed when push.followTags=true is set in the repo or global config.
git -C "$target" push -u origin HEAD --no-follow-tags || { echo "REFUSED: push failed." >&2; exit 7; }
echo "== ensure-remote: private remote ready at https://github.com/$owner/$repo =="
exit 0
