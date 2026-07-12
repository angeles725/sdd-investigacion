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
#      never see because it only opens *.md/config text files. The content scan (4b) covers the working tree
#      only; for a high-sensitivity target, audit or squash history before the first push (scan-secrets does
#      not walk deleted history).
#   5. CREATE THEN VERIFY visibility BEFORE ANY PUSH — after create, read back `visibility`; if it is not
#      PRIVATE, attempt one forced `--visibility private` and re-read; if STILL not private, HARD ABORT:
#      warn loudly, remove the origin remote, and exit non-zero WITHOUT pushing. The push step is textually
#      AFTER and guarded by this confirmed-private check.
#   6. IDEMPOTENT — if `origin` already resolves, do nothing (never a duplicate repo).
#
# Usage: ensure-remote.sh <target-dir> [--yes] [--name <repo>]
#   default repo name: research-<basename-of-target-dir>, slugified to [a-z0-9-].
# Exit: 0 = remote present (created+pushed, or already existed) · 2 = bad args / not a git repo ·
#       3 = no consent · 4 = owner is an organization · 5 = secret leak (refused to push) ·
#       6 = visibility verification failed (HARD ABORT, no push) · 7 = tooling missing / git-or-gh op failed.

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

HERE="$(cd "$(dirname "$0")" && pwd)"
SCAN="$HERE/scan-secrets.sh"

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

# --- LAYER 4b: pre-push secret sweep (fail closed — no scanner means we cannot verify, so we refuse) --
# Covers CONTENT secrets in *.md/config text files. The content scan covers the working tree only; for a
# high-sensitivity target, audit or squash history before the first push (scan-secrets does not walk
# deleted history).
[ -f "$SCAN" ] || { echo "REFUSED: scan-secrets.sh not found at $SCAN — cannot verify the corpus before push." >&2; exit 7; }
if ! bash "$SCAN" "$target" >/dev/null 2>&1; then
  echo "REFUSED: scan-secrets.sh reported a high-confidence secret VALUE in the corpus — NOT pushing." >&2
  echo "         Redact it (cite structure, never value — SECRETS DISCIPLINE) and re-run." >&2
  exit 5
fi

# --- LAYER 4c: refuse any git-TRACKED secret-type FILE (belt for the binary types scan-secrets.sh cannot --
# open/see: *.pem/*.der/*.key/*.p12/*.pfx/id_rsa*/*.jks/*.keystore and the security/licenses/certificates/
# keystore/keyring dirs). A tracked binary key/cert would pass the content scan (it is never opened) and
# get pushed — this gate closes that gap with git's own pathspec matching (git's default `*` DOES cross
# `/`, so an extension pattern like `*.key` catches a key at ANY depth/location; the directory patterns
# are root-anchored to the corpus root, which is where the SECRETS DISCIPLINE places security/ etc.).
# FAIL CLOSED (mirror Layer 4b): if `ls-files` itself errors, we cannot verify — refuse rather than proceed.
if ! _tracked_raw="$(git -C "$target" ls-files -z -- \
  '*.pem' '*.der' '*.key' '*.p12' '*.pfx' 'id_rsa*' '*.jks' '*.keystore' \
  'security/*' 'licenses/*' 'certificates/*' 'keystore/*' 'keyring/*' 2>/dev/null)"; then
  echo "REFUSED: could not enumerate tracked files (git ls-files failed) — cannot verify no secret is tracked." >&2
  exit 7
fi
tracked_secrets="$(printf '%s' "$_tracked_raw" | tr '\0' ' ')"
if [ -n "${tracked_secrets// }" ]; then
  echo "REFUSED: secret-bearing file(s) are git-TRACKED and would be pushed: $tracked_secrets" >&2
  echo "         scan-secrets.sh cannot see these binary types. Untrack them first:" >&2
  echo "         git -C \"$target\" rm --cached <file> ; ensure they are in .gitignore ; commit ; re-run." >&2
  exit 5
fi

# --- LAYER 1 + 5: create PRIVATE, then VERIFY visibility BEFORE ANY push -----------------------------
echo ">> creating PRIVATE remote $owner/$repo"
if ! gh repo create "$owner/$repo" --private --source "$target" --remote origin --disable-wiki; then
  echo "REFUSED: gh repo create failed." >&2; exit 7
fi

read_vis() { gh repo view "$owner/$repo" --json visibility -q .visibility 2>/dev/null | tr '[:lower:]' '[:upper:]'; }
vis="$(read_vis)"
if [ "$vis" != "PRIVATE" ]; then
  echo "   visibility read back as '$vis' — forcing --visibility private once" >&2
  gh repo edit "$owner/$repo" --visibility private >/dev/null 2>&1 || true
  vis="$(read_vis)"
fi
if [ "$vis" != "PRIVATE" ]; then
  echo "!! HARD ABORT: a non-private repo exists at https://github.com/$owner/$repo — DELETE IT MANUALLY" >&2
  echo "   (this wrapper has NO delete_repo scope). Removing the origin remote and NOT pushing." >&2
  git -C "$target" remote remove origin >/dev/null 2>&1 || true
  exit 6
fi

# Push is textually AFTER and GUARDED BY the confirmed-private check above.
echo ">> confirmed PRIVATE — pushing corpus"
git -C "$target" push -u origin HEAD || { echo "REFUSED: push failed." >&2; exit 7; }
echo "== ensure-remote: private remote ready at https://github.com/$owner/$repo =="
exit 0
