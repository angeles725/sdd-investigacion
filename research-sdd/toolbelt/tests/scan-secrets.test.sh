#!/usr/bin/env bash
# scan-secrets.test.sh — RED-FIRST harness for scan-secrets.sh (kit-audit #4, SECRETS DISCIPLINE mechanization).
#
# The discriminating behaviour: FLAG high-confidence secret VALUES (PEM private keys, known token prefixes)
# that leaked into a corpus, while NEVER flagging the COMPLIANT convention — a secret cited by its `sha256`
# + byte-count (the kit's own "cite STRUCTURE not VALUE" rule). The sha256 whitelist is the load-bearing
# anti-false-positive: corpora are full of hashes and byte dumps.
#
# scan-secrets.sh is a compatibility shim over `rsdd secrets scan` (Go). The black-box cases below run through it; the
# detector itself is pinned in Go (research-sdd/rsdd/internal/core/secretscan: a 280-case differential against the frozen
# script, a golden replay, unit tests, package teeth). --prove-teeth mutates the SHIM (arguments, command name, exit code,
# --toolbelt, the library guard); the old controls that edited the retired script body are typed SKIPs naming the Go tests.
#
# Usage: scan-secrets.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../scan-secrets.sh"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
# The cases that stubbed or edited the bash internals moved to Go (research-sdd/rsdd/internal/core/secretscan, internal/secretscan):
#   25, 26 (grep failing on the NUL scan / count) -> TestGoldenReplay scope-unreadable-file, scope-unreadable-dir, ff-entry-unreadable,
#                                                    scope-nul-two-files, scope-nul-byte-clean
#   FF18 (grep stub exiting 2 per flag)           -> the same read-error cases
#   47, 48, 59 (mktemp failing, awk absent), 70 (tr stub) -> TestCommittedScanNeedsOnlyGit
#   71, 72, 73 (the SUT's awk header validation)  -> TestValidHeaderBoundaries, TestEnumerateFailsClosed
SUT_IS_SHIM=0; grep -q "rsdd_exec" "$SUT" && SUT_IS_SHIM=1
MUT=""
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP" ${MUT:+"$MUT"}' EXIT
pass=0; fail=0; skips=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
skip(){ printf '  SKIP  %s\n' "$1"; skips=$((skips+1)); }
# a minimal corpus dir with one block file
newcorpus(){ local d="$1"; mkdir -p "$d"; printf '# Block 1 — t\n\n> legend\n\n---\n\n' > "$d/t-block1.md"; }
runrc(){ bash "$SUT" "$1" >/dev/null 2>&1; echo $?; }
runout(){ bash "$SUT" "$1" 2>&1; }
# --- mutation-control helpers (kit issues #943, #1299) ---------------------------------------------
# Every mutant is built as a COPY of the shim under $MUT (a temp dir outside the live tree) by
# lib/mutant.sh, which REFUSES an empty, byte-identical, syntax-broken or live-tree mutant; each
# control then asserts the GOOD verdict on the original AND the SPECIFIC BAD verdict on the mutant.
# shellcheck source=lib/mutant.sh
. "$HERE/lib/mutant.sh"
mutant_bootstrap mutant_sed mutant_tooth || exit 2
MUT="$(mktemp -d)"
# The exact-verdict runner is shared: lib/mutant.sh mutant_tooth (#1299). It prints its own FAIL/PASS line and
# returns non-zero on failure; the adapter only COUNTS. Patterns in this suite match case-insensitively.
# shellcheck disable=SC2034  # read by the sourced mutant_tooth
MUTANT_TOOTH_ICASE=1
tooth(){ if mutant_tooth "$@"; then pass=$((pass+1)); else fail=$((fail+1)); fi; }

echo "== scan-secrets.test.sh =="

# 1 — a PEM PRIVATE KEY block in a corpus file → FAIL (exit 1), flagged.
d="$TMP/pem"; newcorpus "$d"
{ echo "Leaked key:"; echo "-----BEGIN RSA PRIVATE KEY-----"; echo "MIIEowIBAAKCAQEA1234567890abcdef"; echo "-----END RSA PRIVATE KEY-----"; } >> "$d/t-block1.md"
[ "$(runrc "$d")" = 1 ] && ok "PEM private key → exit 1" || no "PEM private key not caught (exit $(runrc "$d"))"

# 2 — AWS access key id → FAIL.
d="$TMP/aws"; newcorpus "$d"; echo "aws_access_key_id = AKIAIOSFODNN7EXAMPLE" >> "$d/t-block1.md"
[ "$(runrc "$d")" = 1 ] && ok "AWS AKIA key → exit 1" || no "AWS AKIA key not caught"

# 3 — GitHub PAT (ghp_...) → FAIL.
d="$TMP/gh"; newcorpus "$d"; echo "token: ghp_0123456789abcdefghijklmnopqrstuvwxyz" >> "$d/t-block1.md"
[ "$(runrc "$d")" = 1 ] && ok "GitHub ghp_ token → exit 1" || no "GitHub token not caught"

# 4 — JWT (eyJ...eyJ...) → FAIL.
d="$TMP/jwt"; newcorpus "$d"; echo "auth: eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abc123DEF456" >> "$d/t-block1.md"
[ "$(runrc "$d")" = 1 ] && ok "JWT → exit 1" || no "JWT not caught"

# 5 — LOAD-BEARING anti-FP: a sha256 citation (the COMPLIANT convention) must NOT be flagged.
d="$TMP/sha"; newcorpus "$d"
echo "Config backed up to scratchpad, cited by hash: sha256: e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 (byte-count 4096)." >> "$d/t-block1.md"
[ "$(runrc "$d")" = 0 ] && ok "sha256 citation NOT flagged (exit 0) — compliant convention" || no "sha256 citation false-flagged (exit $(runrc "$d"))"

# 6 — a TRUNCATED sha256 in a SOURCES.md row must not be flagged either.
d="$TMP/sha2"; newcorpus "$d"; mkdir -p "$d/sources"
printf '| File | sha256 | Blocks |\n|---|---|---|\n| a.pdf | 04adf2b… | B1 |\n' > "$d/sources/SOURCES.md"
[ "$(runrc "$d")" = 0 ] && ok "truncated sha256 in SOURCES.md not flagged" || no "truncated sha256 false-flagged"

# 7 — a hex byte dump / 0x value (decompiler output) must not be flagged.
d="$TMP/hex"; newcorpus "$d"; echo "The live register held 0x87B961A9; memory dump: DE AD BE EF 01 02 03 04." >> "$d/t-block1.md"
[ "$(runrc "$d")" = 0 ] && ok "hex dump / 0x value not flagged" || no "hex dump false-flagged"

# 8 — a clean corpus → exit 0, says clean.
d="$TMP/clean"; newcorpus "$d"; echo "Extends BComponent [CERT]. The password is stored in the keyring (structure only)." >> "$d/t-block1.md"
out="$(runout "$d")"
if [ "$(runrc "$d")" = 0 ] && grep -qiE 'clean|no .*secret|0 ' <<<"$out"; then ok "clean corpus → exit 0"
else no "clean corpus exit=$(runrc "$d") :: $out"; fi

# 9 — a credential assignment with a real literal value → ADVISORY WARN, but exit stays 0 (never block on a guess).
d="$TMP/cred"; newcorpus "$d"; echo 'password = "S3cr3tHunter2Value"' >> "$d/t-block1.md"
out="$(runout "$d")"
if [ "$(runrc "$d")" = 0 ] && grep -qE '^[[:space:]]+WARN ' <<<"$out"; then ok "credential assignment → advisory WARN, exit 0"
else no "credential-assignment advisory wrong: exit=$(runrc "$d") :: $out"; fi

# 10 — a PLACEHOLDER credential (not a real value) must NOT WARN.
d="$TMP/ph"; newcorpus "$d"
{ echo 'password = "<REDACTED>"'; echo 'api_key: xxxxxx'; echo 'token = $ENV_TOKEN'; } >> "$d/t-block1.md"
out="$(runout "$d")"
if [ "$(runrc "$d")" = 0 ] && ! grep -qE '^[[:space:]]+WARN ' <<<"$out"; then ok "placeholder credentials not flagged"
else no "placeholder credential false-warned :: $(grep -E '^[[:space:]]+WARN ' <<<"$out")"; fi

# 11 — bad args → exit 2.
[ "$(bash "$SUT" 2>/dev/null; echo $?)" = 2 ] && ok "no args → exit 2" || no "no-args not exit 2"

# 12 — vendored trees (node_modules) are EXCLUDED: a PEM key in node_modules is a library fixture, not a leak.
d="$TMP/vendored"; newcorpus "$d"; mkdir -p "$d/node_modules/jose"
{ echo "-----BEGIN PRIVATE KEY-----"; echo "MIIBVgIBADANBg"; echo "-----END PRIVATE KEY-----"; } > "$d/node_modules/jose/import.js"
# also a real .md leak alongside, to prove the scan still runs (exit 1 from the .md, NOT from node_modules)
[ "$(runrc "$d")" = 0 ] && ok "PEM inside node_modules ignored (vendored, not corpus content)" \
  || no "node_modules PEM false-flagged (exit $(runrc "$d"))"

# 13 — a substring like 'saltedPassword ='/'certAliasAndPassword' must NOT WARN (word-boundary guard).
d="$TMP/substr"; newcorpus "$d"
{ echo "saltedPassword = PBKDF2WithHmacSHA256(pw, salt, 100000)"; echo "public static final Property certAliasAndPassword = newProperty(4);"; } >> "$d/t-block1.md"
out="$(runout "$d")"
if [ "$(runrc "$d")" = 0 ] && ! grep -qE '^[[:space:]]+WARN ' <<<"$out"; then ok "'saltedPassword'/'certAliasAndPassword' substring not WARNed (word boundary)"
else no "substring password false-WARNed :: $(grep -E '^[[:space:]]+WARN ' <<<"$out")"; fi

# 14 — a truncated/illustrative value (`token: 'abc123...'`) and a markdown-link capture must NOT WARN.
d="$TMP/illus"; newcorpus "$d"
{ echo "example: { token: 'abc123...' }"; echo "- [30.8 password: ClearProgPwdPanel](#308-password-clearprogpwdpanel)"; } >> "$d/t-block1.md"
out="$(runout "$d")"
if [ "$(runrc "$d")" = 0 ] && ! grep -qE '^[[:space:]]+WARN ' <<<"$out"; then ok "truncated '...' value + markdown-link not WARNed"
else no "illustrative value false-WARNed :: $(grep -E '^[[:space:]]+WARN ' <<<"$out")"; fi

# 15 — snake_case naming (aws_secret_access_key) must WARN — the `_` word-boundary fix (was silently missed).
d="$TMP/snake"; newcorpus "$d"; echo 'aws_secret_access_key = wJalrXUtnFEMI9K7value' >> "$d/t-block1.md"
out="$(runout "$d")"
grep -qE '^[[:space:]]+WARN ' <<<"$out" && ok "snake_case aws_secret_access_key → WARN (underscore boundary)" \
  || no "snake_case secret missed :: $out"

# 16 — a multi-assignment line (password=X;timeout=30) must keep X, not degrade to '30' (non-greedy fix).
d="$TMP/multi"; newcorpus "$d"; echo 'password=RealSecretPass9;timeout=30' >> "$d/t-block1.md"
out="$(runout "$d")"
if grep -qE '^[[:space:]]+WARN ' <<<"$out"; then ok "multi-assignment value not destroyed by greedy extraction → WARN"
else no "multi-assignment value lost (greedy sed regression) :: $out"; fi

# 17 — a bare-hex TOKEN with no hash context must WARN (hex-whitelist is context-gated, not shape-only).
d="$TMP/hextok"; newcorpus "$d"; echo 'token = a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2' >> "$d/t-block1.md"
grep -qE '^[[:space:]]+WARN ' <<<"$(runout "$d")" && ok "bare-hex token (no hash context) → WARN, not swallowed" \
  || no "bare-hex token swallowed by the hash whitelist"

# 18 — BUT a hex value cited as a hash (line says sha256) stays exempt (compliant convention still holds).
d="$TMP/hexhash"; newcorpus "$d"
echo 'token = e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855  # sha256 of the config body' >> "$d/t-block1.md"
grep -qE '^[[:space:]]+WARN ' <<<"$(runout "$d")" && no "hash-context hex wrongly WARNed (compliant citation)" \
  || ok "hex value cited as sha256 stays exempt (context-gated)"

# 19 — ASIA (AWS STS session) key id → high-confidence LEAK (exit 1).
d="$TMP/asia"; newcorpus "$d"; echo 'aws_session = ASIAIOSFODNN7EXAMPLE' >> "$d/t-block1.md"
[ "$(runrc "$d")" = 1 ] && ok "ASIA session key → exit 1" || no "ASIA session key missed (exit $(runrc "$d"))"

# 20 — a NUL byte that makes grep skip a whole file must be SURFACED with a real count (NOT the always-present
#      summary substring — that was a tautology). Assert the ⚠ note line with a count >= 1.
d="$TMP/nul"; newcorpus "$d"; printf 'note\x00 -----BEGIN RSA PRIVATE KEY-----\n' >> "$d/t-block1.md"
grep -qE '[1-9][0-9]* in-scope file.*NUL byte' <<<"$(runout "$d")" && ok "NUL-byte file surfaced with a count (no silent blind spot)" \
  || no "NUL-byte file not detected/reported :: $(grep -i nul <<<"$(runout "$d")")"

# 21 — NEGATIVE for the NUL detector: a clean corpus must report NO NUL-byte note (guards against a false count).
d="$TMP/nonul"; newcorpus "$d"; echo "ordinary text, no nulls here [CERT]." >> "$d/t-block1.md"
grep -qE 'NUL byte' <<<"$(runout "$d")" && no "clean corpus false-reported a NUL-byte file" \
  || ok "clean corpus reports no NUL-byte note (detector not a false-positive tautology)"

# 22 — the identifier broadening must NOT WARN on ordinary superstring words (tokenizer/secretariat/passwordless).
d="$TMP/superstr"; newcorpus "$d"
{ echo 'tokenizer = somelongvalue1'; echo 'secretariat = presidentName9'; echo 'passwordless = true12345'; } >> "$d/t-block1.md"
out="$(runout "$d")"
if ! grep -qE '^[[:space:]]+WARN ' <<<"$out"; then ok "superstring words (tokenizer/secretariat/passwordless) not WARNed"
else no "identifier broadening over-matches ordinary words :: $(grep -E '^[[:space:]]+WARN ' <<<"$out")"; fi

# 23 — TEMPLATE-ANCHOR (SECURITY false-negative): a block-shaped kit TEMPLATE must never anchor the corpus
#      root and silently narrow the secret scan to the wrong subtree. Fixture (the reviewer's repro):
#      a-templates/block.template.md (placeholder) + b-corpus/foo-block1.md carrying a REAL AWS key. The
#      resolution must SKIP the template and anchor on b-corpus/ so the key is scanned → exit 1. RED before
#      the fix: the template is the shallowest *block*.md (a- sorts first), anchors corpus=a-templates/, and
#      the real key in b-corpus/ is never scanned → false-clean exit 0. This is a fail-OPEN security bug.
d="$TMP/template-anchor"; mkdir -p "$d/a-templates" "$d/b-corpus"
printf '# <SUBJECT> — Block <k>\n\n> placeholder legend, no real content.\n' > "$d/a-templates/block.template.md"
printf '# Block 1\n\naws_access_key_id = AKIAIOSFODNN7EXAMPLE\n' > "$d/b-corpus/foo-block1.md"
out="$(runout "$d")"
if [ "$(runrc "$d")" = 1 ] && ! grep -q 'corpus root: a-templates/' <<<"$out"; then
  ok "TEMPLATE-ANCHOR: template skipped, real corpus scanned, AWS key caught (exit 1)"
else no "template-anchor: exit $(runrc "$d") (want 1) · corpus=$(grep -o 'corpus root: [^ ]*' <<<"$out")"; fi

# 24 — POSITIVE CONTROL: a normal single-block corpus with NO template still scans correctly. A real AWS key
#      in the only block → caught (exit 1). Pins that the *.template.md exclusion does not break ordinary
#      corpus resolution / scanning.
d="$TMP/no-template"; mkdir -p "$d/corpus"
printf '# Block 1\n\naws_access_key_id = AKIAIOSFODNN7EXAMPLE\n' > "$d/corpus/foo-block1.md"
[ "$(runrc "$d")" = 1 ] && ok "POSITIVE: template-free corpus scans + catches the key (exit 1)" || no "no-template corpus exit=$(runrc "$d") (want 1)"

# 27 — --committed mode: a GitHub token in committed root NOTES.md is flagged even when the corpus
#      subdir is clean (Repro 1 from #955: default scan covers the corpus working-tree subdir only;
#      `git push` sends the entire committed HEAD, including root-level files the scan never sees).
d="$TMP/committed-root-token"
mkdir -p "$d/corpus"
git -C "$d" init -q 2>/dev/null
git -C "$d" config user.email "test@test" && git -C "$d" config user.name "test"
printf '# Block 1\n\nresearch note\n' > "$d/corpus/t-block1.md"
printf 'token: ghp_0123456789abcdefghijklmnopqrstuvwxyz\n' > "$d/NOTES.md"
git -C "$d" add corpus/t-block1.md NOTES.md && git -C "$d" commit -q -m "init" 2>/dev/null
wt_rc27="$(runrc "$d")"
cm_rc27="$(bash "$SUT" --committed "$d" >/dev/null 2>&1; echo $?)"
if [ "$wt_rc27" = 0 ] && [ "$cm_rc27" = 1 ]; then
  ok "27 --committed catches root NOTES.md token missed by default (Repro 1 #955)"
else
  no "27 repro-1: wt_rc=$wt_rc27 (want 0, default misses it) cm_rc=$cm_rc27 (want 1, committed catches it)"
fi

# 28 — --committed mode: a secret redacted ONLY in the working tree without committing is still
#      caught in the committed content (Repro 2 from #955: operator redacts in WT, re-runs, rc 0
#      → false-clean, but push sends HEAD which still carries the original secret).
d="$TMP/committed-redacted-wt"
mkdir -p "$d/corpus"
git -C "$d" init -q 2>/dev/null
git -C "$d" config user.email "test@test" && git -C "$d" config user.name "test"
printf 'token: ghp_0123456789abcdefghijklmnopqrstuvwxyz\n' > "$d/corpus/t-block1.md"
git -C "$d" add corpus/t-block1.md && git -C "$d" commit -q -m "init" 2>/dev/null
printf 'token: REDACTED\n' > "$d/corpus/t-block1.md"   # redact in WT without committing
wt_rc28="$(runrc "$d")"                                  # default mode: sees WT → clean → 0
cm_rc28="$(bash "$SUT" --committed "$d" >/dev/null 2>&1; echo $?)"  # committed: sees HEAD → 1
if [ "$wt_rc28" = 0 ] && [ "$cm_rc28" = 1 ]; then
  ok "28 --committed catches WT-redacted secret still in committed HEAD (Repro 2 #955)"
else
  no "28 repro-2: wt_rc=$wt_rc28 (want 0) cm_rc=$cm_rc28 (want 1)"
fi

# 29 — --committed mode with git absent → typed DEGRADED exit (never silent pass, never exit 0).
d_deg="$TMP/committed-no-git"; mkdir -p "$d_deg"
_stub_no_git="$TMP/no-git-bin"; mkdir -p "$_stub_no_git"
for _b in bash grep head sed tr mktemp dirname basename; do
  _bp="$(type -P "$_b" 2>/dev/null)" && [ -n "$_bp" ] && ln -sf "$_bp" "$_stub_no_git/$_b" 2>/dev/null || true
done
cm_out29="$(PATH="$_stub_no_git" bash "$SUT" --committed "$d_deg" 2>&1)"
cm_rc29=$?
if [ "$cm_rc29" != 0 ] && <<<"$cm_out29" grep -qiE 'degraded|git not'; then
  ok "29 --committed with git absent → non-zero + typed DEGRADED message"
else
  no "29 --committed no-git: rc=$cm_rc29 (want non-0) out=$cm_out29"
fi

# 30 — --committed mode, clean committed content across full repo → exit 0.
d="$TMP/committed-clean-repo"
mkdir -p "$d/corpus"
git -C "$d" init -q 2>/dev/null
git -C "$d" config user.email "test@test" && git -C "$d" config user.name "test"
printf '# Block 1\n\nresearch note, no secrets here\n' > "$d/corpus/t-block1.md"
printf '# Notes\n\nAll clear.\n' > "$d/NOTES.md"
git -C "$d" add corpus/t-block1.md NOTES.md && git -C "$d" commit -q -m "init" 2>/dev/null
cm_rc30="$(bash "$SUT" --committed "$d" >/dev/null 2>&1; echo $?)"
[ "$cm_rc30" = 0 ] && ok "30 --committed on clean committed repo → exit 0" \
  || no "30 --committed clean: rc=$cm_rc30 (want 0)"

# 31 — --committed catches PEM key (B1: -e flag required so pattern is not parsed as git option).
d_t31="$TMP/committed-pem-repo"
mkdir -p "$d_t31/corpus"
git -C "$d_t31" init -q 2>/dev/null
git -C "$d_t31" config user.email "test@test" && git -C "$d_t31" config user.name "test"
printf '# Block 1\n\n-----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEA1234567890abcdef\n-----END RSA PRIVATE KEY-----\n' \
  > "$d_t31/corpus/t-block1.md"
git -C "$d_t31" add corpus/t-block1.md && git -C "$d_t31" commit -q -m "init" 2>/dev/null
cm_rc31="$(bash "$SUT" --committed "$d_t31" >/dev/null 2>&1; echo $?)"
[ "$cm_rc31" = 1 ] && ok "31 --committed catches PEM key in corpus .md → exit 1 (B1 -e flag)" \
  || no "31 --committed PEM: rc=$cm_rc31 (want 1)"

# 32 — --committed catches GitHub token in nested .env* (B2: :(glob)**/.env*).
d_t32="$TMP/committed-dotenv-repo"
mkdir -p "$d_t32/corpus"
git -C "$d_t32" init -q 2>/dev/null
git -C "$d_t32" config user.email "test@test" && git -C "$d_t32" config user.name "test"
printf '# Block 1\n\nresearch note\n' > "$d_t32/corpus/t-block1.md"
printf 'GH_TOKEN=ghp_0123456789abcdefghijklmnopqrstuvwxyz\n' > "$d_t32/corpus/.env.local"
git -C "$d_t32" add corpus/t-block1.md corpus/.env.local && git -C "$d_t32" commit -q -m "init" 2>/dev/null
cm_rc32="$(bash "$SUT" --committed "$d_t32" >/dev/null 2>&1; echo $?)"
[ "$cm_rc32" = 1 ] && ok "32 --committed catches token in nested .env.local → exit 1 (B2 :(glob)**/.env*)" \
  || no "32 --committed nested .env*: rc=$cm_rc32 (want 1)"

# 33 — --committed catches GitHub token in nested config.* (B2: :(glob)**/config.*).
d_t33="$TMP/committed-config-repo"
mkdir -p "$d_t33/corpus"
git -C "$d_t33" init -q 2>/dev/null
git -C "$d_t33" config user.email "test@test" && git -C "$d_t33" config user.name "test"
printf '# Block 1\n\nresearch note\n' > "$d_t33/corpus/t-block1.md"
printf 'api_key = ghp_0123456789abcdefghijklmnopqrstuvwxyz\n' > "$d_t33/corpus/config.yaml"
git -C "$d_t33" add corpus/t-block1.md corpus/config.yaml && git -C "$d_t33" commit -q -m "init" 2>/dev/null
cm_rc33="$(bash "$SUT" --committed "$d_t33" >/dev/null 2>&1; echo $?)"
[ "$cm_rc33" = 1 ] && ok "33 --committed catches token in nested config.yaml → exit 1 (B2 :(glob)**/config.*)" \
  || no "33 --committed nested config.*: rc=$cm_rc33 (want 1)"

# 34 — --committed catches GitHub token in nested credentials file (B2: :(glob)**/credentials).
d_t34="$TMP/committed-credentials-repo"
mkdir -p "$d_t34/corpus"
git -C "$d_t34" init -q 2>/dev/null
git -C "$d_t34" config user.email "test@test" && git -C "$d_t34" config user.name "test"
printf '# Block 1\n\nresearch note\n' > "$d_t34/corpus/t-block1.md"
printf 'token=ghp_0123456789abcdefghijklmnopqrstuvwxyz\n' > "$d_t34/corpus/credentials"
git -C "$d_t34" add corpus/t-block1.md corpus/credentials && git -C "$d_t34" commit -q -m "init" 2>/dev/null
cm_rc34="$(bash "$SUT" --committed "$d_t34" >/dev/null 2>&1; echo $?)"
[ "$cm_rc34" = 1 ] && ok "34 --committed catches token in nested credentials → exit 1 (B2 :(glob)**/credentials)" \
  || no "34 --committed nested credentials: rc=$cm_rc34 (want 1)"

# 35 — --committed: rev-list enumeration fails (rc ≥ 2) → typed DEGRADED exit 3, not silent pass (B3).
# Probe passes (rev-parse works); only "rev-list HEAD" exits 2 to simulate enumeration failure.
# M4: updated from "log --format= --raw" to "rev-list HEAD" (plumbing enumeration, #969 Round 5).
REAL_GIT35="$(type -P git 2>/dev/null)"
d_t35="$TMP/committed-revlist-fail"
mkdir -p "$d_t35/corpus"
git -C "$d_t35" init -q 2>/dev/null
git -C "$d_t35" config user.email "test@test" && git -C "$d_t35" config user.name "test"
printf '# Block 1\n\nresearch note\n' > "$d_t35/corpus/t-block1.md"
git -C "$d_t35" add corpus/t-block1.md && git -C "$d_t35" commit -q -m "init" 2>/dev/null
_stub_bad_revlist="$TMP/bad-revlist-bin"; mkdir -p "$_stub_bad_revlist"
printf '#!/bin/bash\ncase "$*" in\n  *"rev-list HEAD"*) exit 2 ;;\n  *) exec "%s" "$@" ;;\nesac\n' \
  "$REAL_GIT35" > "$_stub_bad_revlist/git"; chmod +x "$_stub_bad_revlist/git"
cm_out35="$(PATH="$_stub_bad_revlist:$PATH" bash "$SUT" --committed "$d_t35" 2>&1)"
cm_rc35=$?
if [ "$cm_rc35" = 3 ] && <<<"$cm_out35" grep -qi 'degraded'; then
  ok "35 --committed git log --raw rc2 → typed DEGRADED exit 3, not silent pass (B3)"
else
  no "35 --committed log --raw fail: rc=$cm_rc35 (want 3) out=$cm_out35"
fi

# --- --files-from <list> (kit issue #1015): scan EXACTLY an explicit NUL-delimited file set -------------------
# The archive secrets gate hands scan-secrets the file set it packages. Default mode narrows to the shallowest
# block directory (unchanged, pinned by FF1); --files-from does not narrow and refuses empty/absent lists
# distinctly (§7: absent-input exit 2 · empty-input exit 3 · no-match exit 0 with a typed line).
ff_root="$TMP/ff"; mkdir -p "$ff_root/blocks" "$ff_root/other"
printf '# Block 1\nBody.\n' > "$ff_root/blocks/t-block1.md"
printf 'note: AKIAIOSFODNN7EXAMPLE\n' > "$ff_root/notes.md"
printf 'clean\n' > "$ff_root/other/clean.md"
ff_list="$TMP/ff.list"
printf '%s\0%s\0%s\0' "$ff_root/blocks/t-block1.md" "$ff_root/notes.md" "$ff_root/other/clean.md" > "$ff_list"
[ "$(runrc "$ff_root")" = 0 ] && ok "FF1 default mode unchanged: notes.md outside the narrowed block dir is NOT scanned (exit 0)" \
  || no "FF1 default mode changed (exit $(runrc "$ff_root"))"
bash "$SUT" --files-from "$ff_list" "$ff_root" >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && ok "FF2 --files-from scans the listed notes.md outside the block dir → exit 1" || no "FF2 files-from missed notes.md (exit $rc)"
printf '%s\0%s\0' "$ff_root/blocks/t-block1.md" "$ff_root/other/clean.md" > "$TMP/ff-excl.list"
bash "$SUT" --files-from "$TMP/ff-excl.list" "$ff_root" >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && ok "FF3 --files-from scans EXACTLY the list: unlisted notes.md is not read (exit 0)" || no "FF3 scanned an unlisted file (exit $rc)"
out="$(bash "$SUT" --files-from "$TMP/no-such.list" "$ff_root" 2>&1)"; rc=$?
[ "$rc" = 2 ] && grep -qi 'list file not found' <<<"$out" && ok "FF4 absent list file → exit 2 (absent-input)" || no "FF4 absent list: exit $rc (want 2)"
: > "$TMP/empty.list"
out="$(bash "$SUT" --files-from "$TMP/empty.list" "$ff_root" 2>&1)"; rc=$?
[ "$rc" = 3 ] && grep -qi 'DEGRADED.*empty' <<<"$out" && ok "FF5 empty list → exit 3 DEGRADED naming 'empty' (empty-input, distinct from absent)" \
  || no "FF5 empty list: exit $rc :: $(head -2 <<<"$out")"
out="$(bash "$SUT" --files-from 2>&1)"; rc=$?
[ "$rc" = 2 ] && grep -qi 'requires a list' <<<"$out" && ok "FF6 --files-from with no value → exit 2" || no "FF6 value-less --files-from: exit $rc"
out="$(bash "$SUT" --committed --files-from "$ff_list" "$ff_root" 2>&1)"; rc=$?
[ "$rc" = 2 ] && grep -qi 'cannot be combined' <<<"$out" && ok "FF7 --files-from combined with --committed → exit 2" || no "FF7 files-from+committed: exit $rc (want 2)"
printf '%s\0' "$ff_root/gone.md" > "$TMP/ff-gone.list"
out="$(bash "$SUT" --files-from "$TMP/ff-gone.list" "$ff_root" 2>&1)"; rc=$?
[ "$rc" = 3 ] && grep -qi 'DEGRADED' <<<"$out" && ok "FF8 listed path that does not exist → exit 3 DEGRADED (never a silent clean)" || no "FF8 vanished entry: exit $rc"
mkdir -p "$TMP/ff-outside"; printf 'x: AKIAIOSFODNN7EXAMPLE\n' > "$TMP/ff-outside/o.md"
printf '%s\0' "$TMP/ff-outside/o.md" > "$TMP/ff-out.list"
out="$(bash "$SUT" --files-from "$TMP/ff-out.list" "$ff_root" 2>&1)"; rc=$?
[ "$rc" = 3 ] && grep -qi 'DEGRADED.*outside' <<<"$out" && ok "FF9 listed path outside the target → exit 3 DEGRADED" || no "FF9 outside entry: exit $rc :: $(head -2 <<<"$out")"
mkdir -p "$ff_root/node_modules/pkg" "$ff_root/notscope"
printf 'k: AKIAIOSFODNN7EXAMPLE\n' > "$ff_root/node_modules/pkg/v.md"; printf 'k: AKIAIOSFODNN7EXAMPLE\n' > "$ff_root/notscope/s.txt"
printf '%s\0%s\0' "$ff_root/node_modules/pkg/v.md" "$ff_root/notscope/s.txt" > "$TMP/ff-scope.list"
out="$(bash "$SUT" --files-from "$TMP/ff-scope.list" "$ff_root" 2>&1)"; rc=$?
[ "$rc" = 0 ] && grep -qE 'file set: 2 listed · 0 in scope' <<<"$out" \
  && ok "FF10 vendored dir + out-of-scope extension are filtered by scan-secrets' own scope; zero in scope is a TYPED no-match line (exit 0)" \
  || no "FF10 scope filter: exit $rc :: $(grep -E 'file set|LEAK' <<<"$out" | head -2)"
printf '%s\0' "$ff_root/notes.md" | bash "$SUT" --files-from - "$ff_root" >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && ok "FF11 --files-from - reads the list from stdin" || no "FF11 stdin list: exit $rc"
printf 'k: AKIAIOSFODNN7EXAMPLE\n' > "$ff_root/other/new
line.md"
printf '%s\0' "$ff_root/other/new
line.md" > "$TMP/ff-nl.list"
bash "$SUT" --files-from "$TMP/ff-nl.list" "$ff_root" >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && ok "FF12 NUL-delimited list: a filename containing a newline is scanned (exit 1)" || no "FF12 newline filename: exit $rc"
ln -s "$TMP/ff-outside/o.md" "$ff_root/other/link.md"
printf '%s\0' "$ff_root/other/link.md" > "$TMP/ff-ln.list"
out="$(bash "$SUT" --files-from "$TMP/ff-ln.list" "$ff_root" 2>&1)"; rc=$?
[ "$rc" = 0 ] && grep -qE '1 skipped \(not a regular file\)' <<<"$out" \
  && ok "FF13 a listed symlink is never dereferenced: skipped and counted (exit 0, parity with grep -r)" \
  || no "FF13 symlink entry: exit $rc :: $(grep -E 'file set|LEAK' <<<"$out" | head -2)"
printf 'password = Zq8xK2mP9vRt\n' > "$ff_root/other/adv.md"
printf '%s\0' "$ff_root/other/adv.md" > "$TMP/ff-adv.list"
out="$(bash "$SUT" --files-from "$TMP/ff-adv.list" "$ff_root" 2>&1)"; rc=$?
[ "$rc" = 0 ] && grep -q 'WARN ' <<<"$out" && ok "FF14 advisory tier works over a list: WARN, exit 0" || no "FF14 advisory over list: exit $rc"
printf 'k: AKIAIOSFODNN7EXAMPLE\n\0\n' > "$ff_root/other/nul.md"
printf '%s\0' "$ff_root/other/nul.md" > "$TMP/ff-nul.list"
out="$(bash "$SUT" --files-from "$TMP/ff-nul.list" "$ff_root" 2>&1)"
grep -qE '1 in-scope file\(s\) contain a NUL byte' <<<"$out" && ok "FF15 NUL-byte skip report works over a list" || no "FF15 NUL report missing :: $(grep -E 'NUL|summary' <<<"$out")"

# --- round-2 hardening of --files-from + output (kit #1015 review): unreadable files, read errors, redaction, path forms ---
# FF16 — an unreadable IN-SCOPE entry must be DEGRADED (exit 3), never a clean scan that silently skipped it.
if [ "$(id -u)" = 0 ]; then skip "FF16/FF17 unreadable-file cases: running as root (chmod 000 does not block root)"
else
  printf 'k: AKIAIOSFODNN7EXAMPLE\n' > "$ff_root/other/locked.md"; chmod 000 "$ff_root/other/locked.md"
  printf '%s\0' "$ff_root/other/locked.md" > "$TMP/ff-locked.list"
  out="$(bash "$SUT" --files-from "$TMP/ff-locked.list" "$ff_root" 2>&1)"; rc=$?
  [ "$rc" = 3 ] && grep -qi 'DEGRADED.*not readable' <<<"$out" && ok "FF16 unreadable in-scope entry → exit 3 DEGRADED (never ok)" || no "FF16 unreadable entry: exit $rc :: $(head -2 <<<"$out")"
  # FF17 — default mode: a grep read error (unreadable file) is DEGRADED, not a clean (none).
  mkdir -p "$TMP/ff-def-locked"; newcorpus "$TMP/ff-def-locked"
  printf 'x\n' > "$TMP/ff-def-locked/locked.md"; chmod 000 "$TMP/ff-def-locked/locked.md"
  out="$(bash "$SUT" "$TMP/ff-def-locked" 2>&1)"; rc=$?
  [ "$rc" = 3 ] && grep -qi 'DEGRADED: grep read error' <<<"$out" && ok "FF17 default mode: unreadable file → exit 3 DEGRADED (grep read error)" || no "FF17 default unreadable: exit $rc :: $(head -2 <<<"$out")"
  chmod 644 "$ff_root/other/locked.md" "$TMP/ff-def-locked/locked.md"
fi
# FF19 — OUTPUT NEVER CARRIES A SECRET VALUE (default, --files-from and --committed), only path:line + a label.
mkdir -p "$TMP/redact"; printf 'a\n# Block\nk = AKIAIOSFODNN7EXAMPLE\npassword = Zq8xK2mP9vRt\n' > "$TMP/redact/t-block1.md"
printf '%s\0' "$TMP/redact/t-block1.md" > "$TMP/redact.list"
out="$(bash "$SUT" "$TMP/redact" 2>&1)"
{ ! grep -qE 'AKIAIOSFODNN7|Zq8xK2mP9vRt' <<<"$out"; } && grep -q 'LEAK!.*t-block1.md:3' <<<"$out" && grep -q 'WARN .*t-block1.md:4' <<<"$out" \
  && ok "FF19 default mode: LEAK/WARN lines carry path:line, never the value" || no "FF19 default redaction :: $(grep -E 'LEAK|WARN' <<<"$out" | head -3)"
out="$(bash "$SUT" --files-from "$TMP/redact.list" "$TMP/redact" 2>&1)"
{ ! grep -qE 'AKIAIOSFODNN7|Zq8xK2mP9vRt' <<<"$out"; } && grep -q 'LEAK!.*t-block1.md:3' <<<"$out" \
  && ok "FF19 --files-from: no value in output" || no "FF19 list redaction :: $(grep -E 'LEAK|WARN' <<<"$out" | head -3)"
git -C "$TMP/redact" init -q -b main; git -C "$TMP/redact" config user.email t@example.com; git -C "$TMP/redact" config user.name t
git -C "$TMP/redact" add -A; git -C "$TMP/redact" commit -q -m "msg with ghp_0123456789abcdefghijklmnopqrstuvwxyz inside"
out="$(bash "$SUT" --committed "$TMP/redact" 2>&1)"
{ ! grep -qE 'AKIAIOSFODNN7|Zq8xK2mP9vRt|ghp_0123456789' <<<"$out"; } && grep -q 'LEAK!.*t-block1.md@' <<<"$out" && grep -q 'LEAK!.*\[commit msg\]' <<<"$out" \
  && ok "FF19 --committed: file hits and commit-message hits carry no value" || no "FF19 committed redaction :: $(grep -E 'LEAK|WARN' <<<"$out" | head -4 | cut -c1-120)"
# FF20 — path forms: '.'/'..' components, a symlinked directory in the path, a directory symlink leaving the target.
printf '%s\0' "$ff_root/other/../notes.md" > "$TMP/ff-dotdot.list"
out="$(bash "$SUT" --files-from "$TMP/ff-dotdot.list" "$ff_root" 2>&1)"; rc=$?
[ "$rc" = 3 ] && grep -qi "DEGRADED.*component" <<<"$out" && ok "FF20 entry with a '..' component → exit 3 DEGRADED" || no "FF20 dotdot: exit $rc :: $(head -2 <<<"$out")"
printf '%s\0' "$ff_root/./notes.md" > "$TMP/ff-dot.list"
bash "$SUT" --files-from "$TMP/ff-dot.list" "$ff_root" >/dev/null 2>&1; rc=$?
[ "$rc" = 3 ] && ok "FF20 entry with a '.' component → exit 3 DEGRADED" || no "FF20 dot: exit $rc"
ln -s "$ff_root/other" "$ff_root/linkdir"
printf '%s\0' "$ff_root/linkdir/clean.md" > "$TMP/ff-linkdir.list"
out="$(bash "$SUT" --files-from "$TMP/ff-linkdir.list" "$ff_root" 2>&1)"; rc=$?
[ "$rc" = 3 ] && grep -qi 'symlinked directory' <<<"$out" && ok "FF20 entry reached through a symlinked directory (inside the target) → exit 3 DEGRADED" || no "FF20 linkdir: exit $rc :: $(head -2 <<<"$out")"
ln -s "$TMP/ff-outside" "$ff_root/outlink"
printf '%s\0' "$ff_root/outlink/o.md" > "$TMP/ff-outlink.list"
out="$(bash "$SUT" --files-from "$TMP/ff-outlink.list" "$ff_root" 2>&1)"; rc=$?
[ "$rc" = 3 ] && ok "FF20 entry whose canonical directory is OUTSIDE the target → exit 3 DEGRADED (secret not read)" || no "FF20 outlink: exit $rc"

# NEGATIVE CONTROL — neuter the PEM detector; the private-key fixture must then NOT be flagged.

# 36 — --committed catches a token that was in a past commit but deleted from HEAD (MAJOR1 history scan).
d_t36="$TMP/history-past-commit"
mkdir -p "$d_t36/corpus"
git -C "$d_t36" init -q 2>/dev/null
git -C "$d_t36" config user.email "test@test" && git -C "$d_t36" config user.name "test"
printf 'token: ghp_0123456789abcdefghijklmnopqrstuvwxyz\n' > "$d_t36/corpus/t-block1.md"
git -C "$d_t36" add corpus/t-block1.md && git -C "$d_t36" commit -q -m "init with token" 2>/dev/null
printf '# redacted — token removed\n' > "$d_t36/corpus/t-block1.md"
git -C "$d_t36" add corpus/t-block1.md && git -C "$d_t36" commit -q -m "redact token from HEAD" 2>/dev/null
wt_rc36="$(runrc "$d_t36")"
cm_rc36="$(bash "$SUT" --committed "$d_t36" >/dev/null 2>&1; echo $?)"
if [ "$wt_rc36" = 0 ] && [ "$cm_rc36" = 1 ]; then
  ok "36 --committed catches past-commit token deleted from HEAD (MAJOR1 all-history)"
else
  no "36 history-scan: wt_rc=$wt_rc36 (want 0) cm_rc=$cm_rc36 (want 1)"
fi

# 37 — --committed catches a token VALUE embedded in a commit message (MAJOR1 commit messages).
d_t37="$TMP/commit-msg-secret"
mkdir -p "$d_t37/corpus"
git -C "$d_t37" init -q 2>/dev/null
git -C "$d_t37" config user.email "test@test" && git -C "$d_t37" config user.name "test"
printf '# clean\n' > "$d_t37/corpus/t-block1.md"
git -C "$d_t37" add corpus/t-block1.md
git -C "$d_t37" commit -q -m "debug: leaked ghp_0123456789abcdefghijklmnopqrstuvwxyz in session" 2>/dev/null
cm_rc37="$(bash "$SUT" --committed "$d_t37" >/dev/null 2>&1; echo $?)"
[ "$cm_rc37" = 1 ] && ok "37 --committed catches GitHub token embedded in commit message (MAJOR1)" \
  || no "37 commit-msg token: rc=$cm_rc37 (want 1)"

# 38 — --committed catches a secret in a NUL-byte .md file via -a/--text flag (MAJOR2).
# git grep -I skips files with NUL bytes (treats them as binary); -a treats all files as text.
d_t38="$TMP/binary-nul-secret"
mkdir -p "$d_t38/corpus"
git -C "$d_t38" init -q 2>/dev/null
git -C "$d_t38" config user.email "test@test" && git -C "$d_t38" config user.name "test"
printf '# header\x00\nGH_TOKEN=ghp_0123456789abcdefghijklmnopqrstuvwxyz\n' > "$d_t38/corpus/t-block1.md"
git -C "$d_t38" add corpus/t-block1.md && git -C "$d_t38" commit -q -m "init" 2>/dev/null
cm_rc38="$(bash "$SUT" --committed "$d_t38" >/dev/null 2>&1; echo $?)"
[ "$cm_rc38" = 1 ] && ok "38 --committed catches token in NUL-byte .md file (-a/--text flag, MAJOR2)" \
  || no "38 binary -a: rc=$cm_rc38 (want 1)"

# 39 — --committed refuses when target is a subdirectory of its git repo (MAJOR3).
# Pathspecs evaluated from a subdir silently miss files outside it.
d_t39root="$TMP/toplevel-mismatch-root"
d_t39sub="$d_t39root/subproject"
mkdir -p "$d_t39sub/corpus"
git -C "$d_t39root" init -q 2>/dev/null
git -C "$d_t39root" config user.email "test@test" && git -C "$d_t39root" config user.name "test"
printf '# root note\n' > "$d_t39root/NOTES.md"
printf '# clean\n' > "$d_t39sub/corpus/t-block1.md"
git -C "$d_t39root" add NOTES.md subproject && git -C "$d_t39root" commit -q -m "init" 2>/dev/null
cm_out39="$(bash "$SUT" --committed "$d_t39sub" 2>&1)"
cm_rc39="$(bash "$SUT" --committed "$d_t39sub" 2>/dev/null; echo $?)"
if [ "$cm_rc39" = 3 ] && <<<"$cm_out39" grep -qiE 'subdir|subdirectory|toplevel|repo root'; then
  ok "39 --committed refuses when target is a subdirectory of its git repo → exit 3 (MAJOR3)"
else
  no "39 MAJOR3 subdir: rc=$cm_rc39 (want 3) out=$(printf '%s' "$cm_out39" | sed -n 1,2p)"
fi

# 40 — --committed advisory is case-insensitive: PASSWORD= (uppercase) must WARN (MINOR: -i restored).
d_t40="$TMP/advisory-uppercase"
mkdir -p "$d_t40/corpus"
git -C "$d_t40" init -q 2>/dev/null
git -C "$d_t40" config user.email "test@test" && git -C "$d_t40" config user.name "test"
printf 'PASSWORD=Secretvalue123xyz\n' > "$d_t40/corpus/config.yaml"
git -C "$d_t40" add corpus && git -C "$d_t40" commit -q -m "init" 2>/dev/null
out40="$(bash "$SUT" --committed "$d_t40" 2>&1)"
if grep -qE '^[[:space:]]+WARN ' <<<"$out40"; then
  ok "40 --committed advisory case-insensitive: PASSWORD= uppercase WARN (-i restored, MINOR)"
else
  no "40 advisory -i: no WARN for PASSWORD= :: $(grep -E '^\s*WARN' <<<"$out40" || echo '(none)')"
fi


# --------------------------------------------------------------------------
# B1 — blob dedup via first-seen path: in-scope copy missed when sha first
# encountered at an out-of-scope or excluded path (adversarial re-review B1).
# --------------------------------------------------------------------------

# 41 — B1: same blob committed as a.txt (excluded) + notes.md (in-scope); only the .txt
#      path appears in rev-list --objects so the in-scope .md copy is never scanned.
#      --committed must catch the token via the notes.md path.
d_t41="$TMP/b1-outofscope-first"
mkdir -p "$d_t41"
git -C "$d_t41" init -q 2>/dev/null
git -C "$d_t41" config user.email "t@t" && git -C "$d_t41" config user.name "t"
printf '# b\n' > "$d_t41/corpus-block1.md"
printf 'token=ghp_0123456789abcdefghijklmnopqrstuvwxyz\n' > "$d_t41/a.txt"
cp "$d_t41/a.txt" "$d_t41/notes.md"           # identical content → same blob sha
git -C "$d_t41" add corpus-block1.md a.txt notes.md && git -C "$d_t41" commit -q -m "init" 2>/dev/null
cm_rc41="$(bash "$SUT" --committed "$d_t41" >/dev/null 2>&1; echo $?)"
[ "$cm_rc41" = 1 ] && ok "41 B1 out-of-scope first path: in-scope notes.md copy detected → exit 1" \
  || no "41 B1 out-of-scope first path: rc=$cm_rc41 (want 1) — in-scope copy missed"

# 42 — B1: same blob committed at decompiled/x.md (excluded) + zz.md (in-scope);
#      the decompiled path sorts first alphabetically.
d_t42="$TMP/b1-excluded-first"
mkdir -p "$d_t42/d/decompiled"
git -C "$d_t42" init -q 2>/dev/null
git -C "$d_t42" config user.email "t@t" && git -C "$d_t42" config user.name "t"
printf '# b\n' > "$d_t42/corpus-block1.md"
printf 'token=ghp_0123456789abcdefghijklmnopqrstuvwxyz\n' > "$d_t42/d/decompiled/x.md"
cp "$d_t42/d/decompiled/x.md" "$d_t42/zz.md"  # same sha, in-scope path
git -C "$d_t42" add . && git -C "$d_t42" commit -q -m "init" 2>/dev/null
cm_rc42="$(bash "$SUT" --committed "$d_t42" >/dev/null 2>&1; echo $?)"
[ "$cm_rc42" = 1 ] && ok "42 B1 excluded path first: in-scope zz.md copy detected → exit 1" \
  || no "42 B1 excluded path first: rc=$cm_rc42 (want 1) — in-scope copy missed"

# 43 — B1: git mv n.md → n.txt; HEAD has only n.txt but the blob was first introduced
#      as n.md (in-scope). rev-list --objects HEAD only sees n.txt → missed.
d_t43="$TMP/b1-git-mv"
mkdir -p "$d_t43"
git -C "$d_t43" init -q 2>/dev/null
git -C "$d_t43" config user.email "t@t" && git -C "$d_t43" config user.name "t"
printf 'token=ghp_0123456789abcdefghijklmnopqrstuvwxyz\n' > "$d_t43/n.md"
git -C "$d_t43" add n.md && git -C "$d_t43" commit -q -m "add n.md" 2>/dev/null
git -C "$d_t43" mv n.md n.txt && git -C "$d_t43" commit -q -m "rename to .txt" 2>/dev/null
cm_rc43="$(bash "$SUT" --committed "$d_t43" >/dev/null 2>&1; echo $?)"
[ "$cm_rc43" = 1 ] && ok "43 B1 git mv .md→.txt: older commit's .md blob detected → exit 1" \
  || no "43 B1 git mv: rc=$cm_rc43 (want 1) — .md blob in older commit missed"

# --------------------------------------------------------------------------
# B4 — grep -E without -a drops lines with invalid UTF-8 bytes (Latin-1, CRLF+\xe9).
# --------------------------------------------------------------------------

# 44 — B4: Latin-1 byte (\xf1) on the same line as a GitHub token; grep -E without -a
#      drops the line under a UTF-8 locale → token invisible.
d_t44="$TMP/b4-latin1"
mkdir -p "$d_t44"
git -C "$d_t44" init -q 2>/dev/null
git -C "$d_t44" config user.email "t@t" && git -C "$d_t44" config user.name "t"
printf 'contrase\xf1a del token: ghp_0123456789abcdefghijklmnopqrstuvwxyz\n' > "$d_t44/a.md"
git -C "$d_t44" add a.md && git -C "$d_t44" commit -q -m "init" 2>/dev/null
cm_rc44="$(LC_ALL=C.UTF-8 bash "$SUT" --committed "$d_t44" >/dev/null 2>&1; echo $?)"
[ "$cm_rc44" = 1 ] && ok "44 B4 Latin-1 byte on secret line: token detected under C.UTF-8 locale → exit 1" \
  || no "44 B4 Latin-1: rc=$cm_rc44 (want 1) — invalid UTF-8 byte caused line to be dropped"

# 45 — B4: PEM header with CRLF and a Latin-1 byte on the same line.
d_t45="$TMP/b4-crlf-latin1"
mkdir -p "$d_t45"
git -C "$d_t45" init -q 2>/dev/null
git -C "$d_t45" config user.email "t@t" && git -C "$d_t45" config user.name "t"
printf 'clave \xe9: -----BEGIN RSA PRIVATE KEY-----\r\nMIIabc\r\n' > "$d_t45/k.md"
git -C "$d_t45" add k.md && git -C "$d_t45" commit -q -m "init" 2>/dev/null
cm_rc45="$(LC_ALL=C.UTF-8 bash "$SUT" --committed "$d_t45" >/dev/null 2>&1; echo $?)"
[ "$cm_rc45" = 1 ] && ok "45 B4 CRLF + Latin-1 on PEM line: key detected → exit 1" \
  || no "45 B4 CRLF+Latin-1 PEM: rc=$cm_rc45 (want 1) — line dropped due to invalid bytes"

# --------------------------------------------------------------------------
# B3 — unchecked errors: rev-list exits 1 treated as ok, mktemp failure,
#      awk missing from PATH.
# --------------------------------------------------------------------------

# 46 — B3: git log (or rev-list) exits 1 (non-fatal by old ">= 2" check) → must be DEGRADED.
REAL_GIT46="$(type -P git 2>/dev/null)"
d_t46="$TMP/b3-revlist-exit1"
mkdir -p "$d_t46"
git -C "$d_t46" init -q 2>/dev/null
git -C "$d_t46" config user.email "t@t" && git -C "$d_t46" config user.name "t"
printf '# clean\n' > "$d_t46/a.md"
git -C "$d_t46" add a.md && git -C "$d_t46" commit -q -m "init" 2>/dev/null
_stub46="$TMP/stub-git-exit1"; mkdir -p "$_stub46"
# Stub: intercept rev-list HEAD (the enumeration plumbing) and exit 1.
# With M4 the enumeration is: git rev-list HEAD | git diff-tree --stdin ...
# Making rev-list exit 1 sets PIPESTATUS[0]=1 → DEGRADED check fires.
printf '#!/bin/bash\ncase "$*" in\n  *"rev-list HEAD"*) exit 1 ;;\n  *) exec "%s" "$@" ;;\nesac\n' \
  "$REAL_GIT46" > "$_stub46/git"; chmod +x "$_stub46/git"
cm_out46="$(PATH="$_stub46:$PATH" bash "$SUT" --committed "$d_t46" 2>&1)"
cm_rc46=$?
if [ "$cm_rc46" = 3 ] && <<<"$cm_out46" grep -qi 'degraded'; then
  ok "46 B3 git log/rev-list exit 1: DEGRADED exit 3 (any non-zero is failure)"
else
  no "46 B3 rev-list exit 1: rc=$cm_rc46 (want 3) — exit-1 was treated as ok (old >=2 check)"
fi

# 49 — B2: corrupt a loose blob object so cat-file fails → must be DEGRADED exit 3.
d_t49="$TMP/b2-catfile-fail"
mkdir -p "$d_t49"
git -C "$d_t49" init -q 2>/dev/null
git -C "$d_t49" config user.email "t@t" && git -C "$d_t49" config user.name "t"
printf 'token=ghp_0123456789abcdefghijklmnopqrstuvwxyz\n' > "$d_t49/n.md"
git -C "$d_t49" add n.md && git -C "$d_t49" commit -q -m "init" 2>/dev/null
_bsha49="$(git -C "$d_t49" rev-parse HEAD:n.md 2>/dev/null)"
_bfile49="$d_t49/.git/objects/${_bsha49:0:2}/${_bsha49:2}"
chmod u+w "$_bfile49" && printf 'x' > "$_bfile49"    # corrupt the loose object
cm_out49="$(bash "$SUT" --committed "$d_t49" 2>&1)"
cm_rc49=$?
if [ "$cm_rc49" = 3 ] && <<<"$cm_out49" grep -qi 'degraded'; then
  ok "49 B2 corrupt blob: cat-file failure → DEGRADED exit 3"
else
  no "49 B2 cat-file fail: rc=$cm_rc49 (want 3) — cat-file exit unchecked, empty content read as clean"
fi

# --------------------------------------------------------------------------
# B5 — path with special characters injected into sed delimiter.
# --------------------------------------------------------------------------

# 50 — B5: path containing a pipe '|' is used as sed delimiter → sed command breaks,
#      output lost, token invisible. Must catch the token.
d_t50="$TMP/b5-pipe-in-path"
mkdir -p "$d_t50"
git -C "$d_t50" init -q 2>/dev/null
git -C "$d_t50" config user.email "t@t" && git -C "$d_t50" config user.name "t"
printf 'token=ghp_0123456789abcdefghijklmnopqrstuvwxyz\n' > "$d_t50/a|b.md"
git -C "$d_t50" add . && git -C "$d_t50" commit -q -m "init" 2>/dev/null
cm_rc50="$(bash "$SUT" --committed "$d_t50" >/dev/null 2>&1; echo $?)"
[ "$cm_rc50" = 1 ] && ok "50 B5 path with pipe '|': token detected despite special char in path → exit 1" \
  || no "50 B5 pipe in path: rc=$cm_rc50 (want 1) — sed injection swallowed token"

# --------------------------------------------------------------------------
# M1 — git replace hides secret commits from rev-list but not from push.
# --------------------------------------------------------------------------

# 51 — M1: create a secret commit, then replace it with a clean stand-in via git replace.
#      Without --no-replace-objects, rev-list follows the replacement and misses the secret.
d_t51="$TMP/m1-git-replace"
mkdir -p "$d_t51"
git -C "$d_t51" init -q 2>/dev/null
git -C "$d_t51" config user.email "t@t" && git -C "$d_t51" config user.name "t"
printf '# base\n' > "$d_t51/a.md"
git -C "$d_t51" add a.md && git -C "$d_t51" commit -q -m "base" 2>/dev/null
printf 'token=ghp_0123456789abcdefghijklmnopqrstuvwxyz\n' > "$d_t51/n.md"
git -C "$d_t51" add n.md && git -C "$d_t51" commit -q -m "secret" 2>/dev/null
_bad_t51="$(git -C "$d_t51" rev-parse HEAD)"
git -C "$d_t51" rm -q n.md && git -C "$d_t51" commit -q -m "clean" 2>/dev/null
# Create a clean replacement for the secret commit (same tree as the base)
# shellcheck disable=SC1083  # ^{tree} is git revision syntax, not shell brace expansion
_good_t51="$(git -C "$d_t51" commit-tree "$(git -C "$d_t51" rev-parse HEAD~2^{tree})" \
  -p "$(git -C "$d_t51" rev-parse HEAD~2)" -m "secret-clean-replacement" 2>/dev/null)"
git -C "$d_t51" replace "$_bad_t51" "$_good_t51" 2>/dev/null
# Verify replacement is active (normal rev-list should not see the secret blob)
_normal_count="$(git -C "$d_t51" rev-list --objects HEAD 2>/dev/null | grep -c 'n\.md' || echo 0)"
cm_rc51="$(bash "$SUT" --committed "$d_t51" >/dev/null 2>&1; echo $?)"
if [ "$cm_rc51" = 1 ]; then
  ok "51 M1 git replace: --no-replace-objects bypasses replacement, secret commit detected → exit 1"
else
  no "51 M1 git replace: rc=$cm_rc51 (want 1) — git replace hid the secret commit (normal count: $_normal_count)"
fi

# --------------------------------------------------------------------------
# B5/NUL-safe — path with embedded newline (RS="\0" fix).
# --------------------------------------------------------------------------

# 52 — B5/NUL-safe: secret in a file whose path contains an embedded newline.
#      Without RS="\0" awk, the path is split at the newline and the blob sha is lost → exit 0.
#      With RS="\0", the full path is one record, sha_cur is preserved, token detected → exit 1.
d_t52="$TMP/b5-newline-in-path"
mkdir -p "$d_t52"
git -C "$d_t52" init -q 2>/dev/null
git -C "$d_t52" config user.email "t@t" && git -C "$d_t52" config user.name "t"
printf 'token=ghp_0123456789abcdefghijklmnopqrstuvwxyz\n' > "$d_t52/x
y.md"
git -C "$d_t52" add . && git -C "$d_t52" commit -q -m "init" 2>/dev/null
cm_rc52="$(bash "$SUT" --committed "$d_t52" >/dev/null 2>&1; echo $?)"
[ "$cm_rc52" = 1 ] && ok "52 B5 path with embedded newline: token detected via RS=\"\\0\" enum → exit 1" \
  || no "52 B5 newline in path: rc=$cm_rc52 (want 1) — path split, blob sha lost, token missed"


# --------------------------------------------------------------------------
# R4-969 — leading ':' path, gitlink mode 160000, grafts, unchecked mktemps,
#           git log rc=1 for commit messages.
# --------------------------------------------------------------------------

# 53 — A: file named ':notes.md' containing a GitHub token is skipped by the old awk
#      parser (the ':' prefix matches /^:/ and is treated as a diff header, losing its blob sha).
#      --committed must catch the token → exit 1.
d_t53="$TMP/r4-colon-sibling"
mkdir -p "$d_t53"
git -C "$d_t53" init -q 2>/dev/null
git -C "$d_t53" config user.email "t@t" && git -C "$d_t53" config user.name "t"
printf '# clean\n' > "$d_t53/README.md"
printf 'token=ghp_0123456789abcdefghijklmnopqrstuvwxyz\n' > "$d_t53/:notes.md"
git -C "$d_t53" add . && git -C "$d_t53" commit -q -m "init" 2>/dev/null
cm_rc53="$(bash "$SUT" --committed "$d_t53" >/dev/null 2>&1; echo $?)"
[ "$cm_rc53" = 1 ] && ok "53 leading ':' path :notes.md: token detected → exit 1 (A: state-machine fix)" \
  || no "53 leading ':' path: rc=$cm_rc53 (want 1) — :notes.md blob skipped by old /^:/ header rule"

# 54 — A: nested ':dir/x.md' path — same issue but under a subdirectory.
d_t54="$TMP/r4-colon-nested"
mkdir -p "$d_t54/:dir"
git -C "$d_t54" init -q 2>/dev/null
git -C "$d_t54" config user.email "t@t" && git -C "$d_t54" config user.name "t"
printf 'token=ghp_0123456789abcdefghijklmnopqrstuvwxyz\n' > "$d_t54/:dir/x.md"
git -C "$d_t54" add . && git -C "$d_t54" commit -q -m "init" 2>/dev/null
cm_rc54="$(bash "$SUT" --committed "$d_t54" >/dev/null 2>&1; echo $?)"
[ "$cm_rc54" = 1 ] && ok "54 nested ':dir/x.md': token detected → exit 1 (A: state-machine fix)" \
  || no "54 nested ':dir/x.md': rc=$cm_rc54 (want 1)"

# 55 — A: ':notes.md' as the ONLY committed .md file (no clean sibling to confuse the parser).
d_t55="$TMP/r4-colon-only"
mkdir -p "$d_t55"
git -C "$d_t55" init -q 2>/dev/null
git -C "$d_t55" config user.email "t@t" && git -C "$d_t55" config user.name "t"
printf 'token=ghp_0123456789abcdefghijklmnopqrstuvwxyz\n' > "$d_t55/:notes.md"
git -C "$d_t55" add . && git -C "$d_t55" commit -q -m "init" 2>/dev/null
cm_rc55="$(bash "$SUT" --committed "$d_t55" >/dev/null 2>&1; echo $?)"
[ "$cm_rc55" = 1 ] && ok "55 ':notes.md' only file: token detected → exit 1 (A: state-machine fix)" \
  || no "55 ':notes.md' only file: rc=$cm_rc55 (want 1)"

# 56 — A: gitlink entry (submodule, mode 160000) at path 'notes.md' (matches .md include) must
#      be SKIPPED, not cat-file'd into DEGRADED. Without the fix the submodule's commit SHA is
#      treated as a blob SHA, 'notes.md' matches .md include, git cat-file blob <commit-sha>
#      fails → DEGRADED exit 3. After fix: gitlink is detected by mode 160000 in the header
#      and skipped; secret.md is still scanned → exit 1.
#      Uses git plumbing (update-index --cacheinfo) to ensure a genuine mode-160000 entry
#      regardless of whether `git submodule add` works on this platform.
_sub_t56="$TMP/r4-sub-repo56"
mkdir -p "$_sub_t56"
git -C "$_sub_t56" init -q 2>/dev/null
git -C "$_sub_t56" config user.email "t@t" && git -C "$_sub_t56" config user.name "t"
printf '# sub\n' > "$_sub_t56/r.md"
git -C "$_sub_t56" add r.md && git -C "$_sub_t56" commit -q -m "sub init" 2>/dev/null
_sub_sha56="$(git -C "$_sub_t56" rev-parse HEAD 2>/dev/null)"
d_t56="$TMP/r4-gitlink56"
mkdir -p "$d_t56"
git -C "$d_t56" init -q 2>/dev/null
git -C "$d_t56" config user.email "t@t" && git -C "$d_t56" config user.name "t"
printf 'token=ghp_0123456789abcdefghijklmnopqrstuvwxyz\n' > "$d_t56/secret.md"
# Manually stage a mode-160000 gitlink at path 'notes.md' using git update-index --cacheinfo
# so this works even when `git submodule add` is unavailable or restricted.
git -C "$d_t56" update-index --add --cacheinfo "160000,$_sub_sha56,notes.md" 2>/dev/null
# .gitmodules required for a valid submodule tree (does not affect the scan)
printf '[submodule "notes.md"]\n\tpath = notes.md\n\turl = file://%s\n' "$_sub_t56" > "$d_t56/.gitmodules"
git -C "$d_t56" add secret.md .gitmodules && git -C "$d_t56" commit -q -m "add secret + gitlink notes.md" 2>/dev/null
cm_rc56="$(bash "$SUT" --committed "$d_t56" >/dev/null 2>&1; echo $?)"
[ "$cm_rc56" = 1 ] && ok "56 gitlink 'notes.md' (mode 160000, matches .md) skipped: secret.md scanned → exit 1 (not DEGRADED)" \
  || no "56 gitlink 'notes.md': rc=$cm_rc56 (want 1 — DEGRADED 3 means gitlink commit-sha was cat-file'd as blob)"

# 57 — A: .git/info/grafts non-empty → DEGRADED exit 3 (grafts alter visible history so
#      scan scope may diverge from what git push would send).
d_t57="$TMP/r4-grafts"
mkdir -p "$d_t57"
git -C "$d_t57" init -q 2>/dev/null
git -C "$d_t57" config user.email "t@t" && git -C "$d_t57" config user.name "t"
printf '# clean\n' > "$d_t57/a.md"
git -C "$d_t57" add a.md && git -C "$d_t57" commit -q -m "init" 2>/dev/null
_head_t57="$(git -C "$d_t57" rev-parse HEAD 2>/dev/null)"
mkdir -p "$d_t57/.git/info"
printf '%s %s\n' "$_head_t57" "$_head_t57" > "$d_t57/.git/info/grafts"
cm_out57="$(bash "$SUT" --committed "$d_t57" 2>&1)"
cm_rc57=$?
if [ "$cm_rc57" = 3 ] && <<<"$cm_out57" grep -qi 'degraded'; then
  ok "57 .git/info/grafts non-empty → DEGRADED exit 3 (grafts may hide commits from scan)"
else
  no "57 grafts: rc=$cm_rc57 (want 3) — grafts not detected :: $(printf '%s' "$cm_out57" | sed -n 1,2p)"
fi

# 58 — M5: rev-list|cat-file --batch for commit objects: if cat-file --batch exits non-zero →
#      must be DEGRADED exit 3 (PIPESTATUS[1] ≠ 0 → scan incomplete).
REAL_GIT58="$(type -P git 2>/dev/null)"
d_t58="$TMP/r4-cmsg-rc1"
mkdir -p "$d_t58"
git -C "$d_t58" init -q 2>/dev/null
git -C "$d_t58" config user.email "t@t" && git -C "$d_t58" config user.name "t"
printf '# clean\n' > "$d_t58/a.md"
git -C "$d_t58" add a.md && git -C "$d_t58" commit -q -m "debug: ghp_0123456789abcdefghijklmnopqrstuvwxyz" 2>/dev/null
_stub_t58="$TMP/r4-stub-cmsg"; mkdir -p "$_stub_t58"
# stub: intercept cat-file --batch (commit scan) and exit 1 to simulate a pipe failure.
# cat-file blob <sha> (blob scan) passes through; only the batch/stdin mode is intercepted.
printf '#!/bin/bash\nfor _a in "$@"; do [ "$_a" = "--batch" ] && exit 1; done\nexec "%s" "$@"\n' \
  "$REAL_GIT58" > "$_stub_t58/git"; chmod +x "$_stub_t58/git"
cm_out58="$(PATH="$_stub_t58:$PATH" bash "$SUT" --committed "$d_t58" 2>&1)"
cm_rc58=$?
if [ "$cm_rc58" = 3 ] && <<<"$cm_out58" grep -qi 'degraded'; then
  ok "58 M5: cat-file --batch rc=1 for commit scan → DEGRADED exit 3 (PIPESTATUS[1] ≠ 0)"
else
  no "58 cat-file --batch rc=1: rc=$cm_rc58 (want 3) :: $(printf '%s' "$cm_out58" | sed -n 1,2p)"
fi

# 60 — M4: log.showSignature=true causes porcelain git log to inject SSH/GPG verification text
#      into the NUL-separated diff stream; the awk state machine misreads the verification line as
#      an unexpected record → fail-closed (or drops the real path → blob not scanned → false clean).
#      Fix: rev-list|diff-tree plumbing is immune to log.* config.
#      Fixture uses real SSH signing (ssh-keygen ed25519) so log.showSignature actually verifies
#      and emits verification text — a fake-gpg stub produced only a dummy PGP block that git never
#      accepted, so the commit fell back to unsigned and the showSignature path never fired.
d_t60="$TMP/repo_t60"
_gcfg60="$TMP/gitconfig_t60"
_sshkey60="$TMP/id_ed25519_t60"
_sshallowed60="$TMP/allowed_signers_t60"
git init -q "$d_t60"
git -C "$d_t60" config user.email "test@test.com"
git -C "$d_t60" config user.name "Test"
ssh-keygen -t ed25519 -N '' -f "$_sshkey60" -q 2>/dev/null
_sshpub60="$(cat "${_sshkey60}.pub" 2>/dev/null)"
printf 'test@test.com namespaces="git" %s\n' "$_sshpub60" > "$_sshallowed60"
cat > "$_gcfg60" << GCFGEOF
[gpg]
  format = ssh
[user]
  signingkey = ${_sshkey60}
[gpg "ssh"]
  allowedSignersFile = ${_sshallowed60}
[log]
  showSignature = true
GCFGEOF
# Commit 1: clean a.md (unsigned, no config)
printf 'clean\n' > "$d_t60/a.md"
git -C "$d_t60" add a.md
git -C "$d_t60" commit -q -m "add a.md"
# Commit 2: s.md with ghp token, signed with real SSH key
printf 'token=ghp_0123456789abcdefghijklmnopqrstuvwxyz\n' > "$d_t60/s.md"
git -C "$d_t60" add s.md
GIT_CONFIG_GLOBAL="$_gcfg60" git -C "$d_t60" commit -S -q -m "signed commit with token" 2>/dev/null \
  || git -C "$d_t60" commit -q -m "signed commit with token (ssh unavailable)"
# Assert the commit is actually signed; otherwise the showSignature path never fires and the test
# only proves the plumbing doesn't break on an unsigned commit — not that it handles signatures.
if ! grep -q '^gpgsig' < <(git -C "$d_t60" cat-file commit HEAD); then
  # Not a pass: emit a typed skip so the suite still surfaces the gap
  echo "  SKIP:60: SSH signing unavailable in this environment — commit has no gpgsig, showSignature path untested" >&2
  skip "60: SSH signing unavailable — showSignature path untested (see SKIP:60 above)"
else
  t60_out="$(GIT_CONFIG_GLOBAL="$_gcfg60" bash "$SUT" --committed "$d_t60" 2>&1)"
  t60_rc=$?
  if [ "$t60_rc" = 1 ] && <<<"$t60_out" grep -q 'LEAK'; then
    ok "60: log.showSignature=true does not cause plumbing enumeration to miss signed-commit blob (exit 1)"
  else
    no "60: log.showSignature=true scan: rc=$t60_rc (want 1) :: $(printf '%s' "$t60_out" | sed -n 1,3p)"
  fi
fi

# 61 — M4: log.diffMerges=off suppresses merge-commit diffs in porcelain git log; a secret added
#      only in a merge commit (evil merge, not present in any parent) is never enumerated → exit 0.
#      Fix: rev-list|diff-tree -m generates one diff per parent regardless of log.diffMerges config.
d_t61="$TMP/repo_t61"
_gcfg61="$TMP/gitconfig_t61"
git init -q "$d_t61"
git -C "$d_t61" config user.email "t@t.com"
git -C "$d_t61" config user.name "Test"
# main: a.md
printf 'content a\n' > "$d_t61/a.md"
git -C "$d_t61" add a.md
git -C "$d_t61" commit -q -m "add a.md"
_t61_main="$(git -C "$d_t61" symbolic-ref --short HEAD 2>/dev/null || echo main)"
# branch-b: b.md
git -C "$d_t61" checkout -q -b branch-b
printf 'content b\n' > "$d_t61/b.md"
git -C "$d_t61" add b.md
git -C "$d_t61" commit -q -m "add b.md"
# back to main, merge without auto-commit so we can add evil-merge file
git -C "$d_t61" checkout -q "$_t61_main"
# --no-ff forces a real merge commit (two parents) even for a fast-forward-eligible branch.
# Without --no-ff git would fast-forward and the "merge commit" would have only one parent,
# making log.diffMerges=off irrelevant (it only suppresses multi-parent commit diffs).
git -C "$d_t61" merge -q --no-commit --no-ff branch-b 2>/dev/null || true
# Evil merge: s.md added only in the merge commit (not in any parent)
printf 'token=ghp_0123456789abcdefghijklmnopqrstuvwxyz\n' > "$d_t61/s.md"
git -C "$d_t61" add s.md
git -C "$d_t61" commit -q -m "merge branch-b (evil: added s.md in merge commit only)"
# Delete s.md in next commit so it lives only in the merge commit in history
git -C "$d_t61" rm -q s.md
git -C "$d_t61" commit -q -m "remove s.md"
# GIT_CONFIG_GLOBAL with log.diffMerges=off (suppresses merge-commit diffs in git log)
printf '[log]\n  diffMerges = off\n' > "$_gcfg61"
t61_out="$(GIT_CONFIG_GLOBAL="$_gcfg61" bash "$SUT" --committed "$d_t61" 2>&1)"
t61_rc=$?
if [ "$t61_rc" = 1 ] && <<<"$t61_out" grep -q 'LEAK'; then
  ok "61: log.diffMerges=off does not hide evil-merge secret via plumbing enumeration (exit 1)"
else
  no "61: log.diffMerges=off scan: rc=$t61_rc (want 1) :: $(printf '%s' "$t61_out" | sed -n 1,3p)"
fi

# 62 — M5: i18n.logOutputEncoding=UTF-16 causes git log to re-encode output to UTF-16 LE (BOM
#      prefix + null bytes between every ASCII char); grep -naE patterns require consecutive ASCII
#      bytes → token missed (false clean). Fix: rev-list|cat-file --batch reads stored bytes
#      directly — output encoding never applies.
d_t62="$TMP/repo_t62"
_gcfg62="$TMP/gitconfig_t62"
git init -q "$d_t62"
git -C "$d_t62" config user.email "t@t.com" && git -C "$d_t62" config user.name "Test"
printf 'clean\n' > "$d_t62/a.md"; git -C "$d_t62" add a.md; git -C "$d_t62" commit -q -m "init"
git -C "$d_t62" commit -q --allow-empty \
  -m "logenc: token=ghp_0123456789abcdefghijklmnopqrstuvwxyz in message" 2>/dev/null
printf '[i18n]\n  logOutputEncoding = UTF-16\n' > "$_gcfg62"
t62_out="$(GIT_CONFIG_GLOBAL="$_gcfg62" bash "$SUT" --committed "$d_t62" 2>&1)"
t62_rc=$?
if [ "$t62_rc" = 1 ] && <<<"$t62_out" grep -q 'LEAK'; then
  ok "62: i18n.logOutputEncoding=UTF-16 does not hide token in commit message (raw cat-file scan)"
else
  no "62: logOutputEncoding=UTF-16: rc=$t62_rc (want 1) :: $(printf '%s' "$t62_out" | sed -n 1,3p)"
fi

# 63 — M5: i18n.commitEncoding=UTF-16 adds an 'encoding UTF-16' header to the commit object; git
#      log applies that declared encoding to its output (re-encodes to UTF-16 LE), so grep misses
#      the ASCII token. The raw object stores the message as ASCII bytes regardless of the header.
#      Fix: cat-file --batch returns those raw ASCII bytes → grep finds the token.
d_t63="$TMP/repo_t63"
_gcfg63="$TMP/gitconfig_t63"
git init -q "$d_t63"
git -C "$d_t63" config user.email "t@t.com" && git -C "$d_t63" config user.name "Test"
printf 'clean\n' > "$d_t63/a.md"; git -C "$d_t63" add a.md
printf '[i18n]\n  commitEncoding = UTF-16\n' > "$_gcfg63"
GIT_CONFIG_GLOBAL="$_gcfg63" git -C "$d_t63" commit -q -m "init" 2>/dev/null
GIT_CONFIG_GLOBAL="$_gcfg63" git -C "$d_t63" commit -q --allow-empty \
  -m "commitenc: secret=ghp_0123456789abcdefghijklmnopqrstuvwxyz" 2>/dev/null
t63_out="$(GIT_CONFIG_GLOBAL="$_gcfg63" bash "$SUT" --committed "$d_t63" 2>&1)"
t63_rc=$?
if [ "$t63_rc" = 1 ] && <<<"$t63_out" grep -q 'LEAK'; then
  ok "63: i18n.commitEncoding=UTF-16 does not hide token in commit message (raw cat-file scan)"
else
  no "63: commitEncoding=UTF-16: rc=$t63_rc (want 1) :: $(printf '%s' "$t63_out" | sed -n 1,3p)"
fi

# 64 — M5: secret value in author name is invisible to git log --format="%s%n%b" (only subject
#      and body are output); cat-file --batch returns the raw commit object including the author
#      header line, so the pattern is found. Closes #987 item 1.
d_t64="$TMP/repo_t64"
git init -q "$d_t64"
git -C "$d_t64" config user.email "t@t.com"
git -C "$d_t64" -c "user.name=ghp_0123456789abcdefghijklmnopqrstuvwxyz TestUser" \
  commit -q --allow-empty -m "normal commit message" 2>/dev/null
t64_out="$(bash "$SUT" --committed "$d_t64" 2>&1)"
t64_rc=$?
if [ "$t64_rc" = 1 ] && <<<"$t64_out" grep -q 'LEAK'; then
  ok "64: secret in author name detected via raw commit object scan (cat-file, closes #987 item 1)"
else
  no "64: author-name secret: rc=$t64_rc (want 1) :: $(printf '%s' "$t64_out" | sed -n 1,3p)"
fi

# 65 — M5: GIT_GRAFT_FILE env set → DEGRADED exit 3.
#      GIT_GRAFT_FILE overrides the grafts file location; the info/grafts check is bypassed by
#      git itself, so scan scope may diverge. Like info/grafts, refuse rather than scan silently.
d_t65="$TMP/repo_t65"
_graft65="$TMP/graft_file_t65"
git init -q "$d_t65"
git -C "$d_t65" config user.email "t@t" && git -C "$d_t65" config user.name "t"
printf '# clean\n' > "$d_t65/a.md"; git -C "$d_t65" add a.md; git -C "$d_t65" commit -q -m "init"
_head_t65="$(git -C "$d_t65" rev-parse HEAD 2>/dev/null)"
printf '%s %s\n' "$_head_t65" "$_head_t65" > "$_graft65"
t65_out="$(GIT_GRAFT_FILE="$_graft65" bash "$SUT" --committed "$d_t65" 2>&1)"
t65_rc=$?
if [ "$t65_rc" = 3 ] && <<<"$t65_out" grep -qi 'degraded'; then
  ok "65: GIT_GRAFT_FILE set → DEGRADED exit 3 (env overrides info/grafts check)"
else
  no "65: GIT_GRAFT_FILE: rc=$t65_rc (want 3) :: $(printf '%s' "$t65_out" | sed -n 1,2p)"
fi

# 66 — B6: UTF-16LE .env blob with BOM; NUL bytes hide ASCII token from grep -a.
# Fix: NUL-stripped rescan catches it.
d_t66="$TMP/repo_t66"
mkdir -p "$d_t66/corpus"
git -C "$d_t66" init -q 2>/dev/null
git -C "$d_t66" config user.email "test@test" && git -C "$d_t66" config user.name "test"
printf '\xff\xfe' > "$d_t66/corpus/secret.env"
printf 'GITHUB_TOKEN=ghp_0123456789abcdefghijklmnopqrstuvwxyz\r\n' | iconv -t UTF-16LE >> "$d_t66/corpus/secret.env"
git -C "$d_t66" add corpus/secret.env && git -C "$d_t66" commit -q -m "init" 2>/dev/null
t66_rc=$(bash "$SUT" --committed "$d_t66" >/dev/null 2>&1; echo $?)
[ "$t66_rc" = 1 ] && ok "66: UTF-16LE .env blob NUL-stripped rescan catches GitHub token (B6)" \
  || no "66: UTF-16LE .env: rc=$t66_rc (want 1)"

# 67 — B6: UTF-16BE .env blob (no BOM)
d_t67="$TMP/repo_t67"
mkdir -p "$d_t67/corpus"
git -C "$d_t67" init -q 2>/dev/null
git -C "$d_t67" config user.email "test@test" && git -C "$d_t67" config user.name "test"
printf 'GITHUB_TOKEN=ghp_0123456789abcdefghijklmnopqrstuvwxyz\n' | iconv -t UTF-16BE > "$d_t67/corpus/secret.env"
git -C "$d_t67" add corpus/secret.env && git -C "$d_t67" commit -q -m "init" 2>/dev/null
t67_rc=$(bash "$SUT" --committed "$d_t67" >/dev/null 2>&1; echo $?)
[ "$t67_rc" = 1 ] && ok "67: UTF-16BE .env blob NUL-stripped rescan catches GitHub token (B6)" \
  || no "67: UTF-16BE .env: rc=$t67_rc (want 1)"

# 68 — B6: UTF-32LE .env blob (no BOM)
d_t68="$TMP/repo_t68"
mkdir -p "$d_t68/corpus"
git -C "$d_t68" init -q 2>/dev/null
git -C "$d_t68" config user.email "test@test" && git -C "$d_t68" config user.name "test"
printf 'GITHUB_TOKEN=ghp_0123456789abcdefghijklmnopqrstuvwxyz\n' | iconv -t UTF-32LE > "$d_t68/corpus/secret.env"
git -C "$d_t68" add corpus/secret.env && git -C "$d_t68" commit -q -m "init" 2>/dev/null
t68_rc=$(bash "$SUT" --committed "$d_t68" >/dev/null 2>&1; echo $?)
[ "$t68_rc" = 1 ] && ok "68: UTF-32LE .env blob NUL-stripped rescan catches GitHub token (B6)" \
  || no "68: UTF-32LE .env: rc=$t68_rc (want 1)"

# 69 — B6 unconditional: a grep wrapper that rejects -P (exits 2) must never cause rc=0.
# Confirms the NUL-stripped rescan does not rely on a -P detector that could silently fail open.
# With unconditional B6 (no -P gate), the advisory grep (-naiP) hits the wrapper → DEGRADED (rc=3).
# Expected: rc=1 (token caught before advisory) OR rc=3 (DEGRADED) — never rc=0 (silent miss).
_nopcre_dir="$TMP/nopcre_bin"
mkdir -p "$_nopcre_dir"
cat > "$_nopcre_dir/grep" << 'GREPWRAP'
#!/bin/sh
# Wrapper: reject -P (PCRE) with exit 2 to simulate a non-PCRE grep
for _a in "$@"; do
  case "$_a" in *P*) exit 2 ;; esac
done
exec /usr/bin/grep "$@"
GREPWRAP
chmod +x "$_nopcre_dir/grep"
t69_rc=$(PATH="$_nopcre_dir:$PATH" bash "$SUT" --committed "$d_t66" >/dev/null 2>&1; echo $?)
[ "$t69_rc" != 0 ] && ok "69: -P-rejecting grep gives rc=$t69_rc (not 0) — B6 never fails open silently" \
  || no "69: -P-rejecting grep gave rc=0 — B6 fails open silently (PCRE detector race)"


# ---- Teeth for the shim itself --------------------------------------------------------------------------------
if [ "${1:-}" = "--prove-teeth" ] && [ "$SUT_IS_SHIM" = 1 ]; then
  echo "-- teeth: mutation controls for scan-secrets.sh (shim) --"
  # The retired controls sed the old script body, which is gone: each is a typed SKIP naming the Go tests that replace it.
  skip "teeth (old detector mutants) patterns, advisory filters, scope globs: TestGoldenReplay hc-*, adv-*, scope-* and the unit tests of internal/core/secretscan"
  skip "teeth (old history mutants) enumeration, NUL strip, commit objects, grafts, replace refs: TestGoldenReplay hist-*, TestValidHeaderBoundaries, TestEnumerateFailsClosed"
  skip "teeth (old --files-from mutants) canonical-directory and entry checks: TestGoldenReplay ff-* cases"
  # mkshim NAME [SEDEXPR] -> a (mutant) shim with the lib beside it, in a kit layout: $MUT/NAME/toolbelt, $MUT/NAME/TARGETS.md
  mkshim() {
    local d="$MUT/$1/toolbelt"
    mkdir -p "$d/lib" && cp "$HERE/../lib/rsdd-exec.sh" "$d/lib/"   # stage-libs-ok: the shim sources only lib/rsdd-exec.sh
    printf '| livecorp | live-install |\n' > "$MUT/$1/TARGETS.md"
    if [ -z "${2:-}" ]; then cp "$SUT" "$d/scan-secrets.sh"; return 0; fi
    mutant_sed "$SUT" "$d/scan-secrets.sh" "$2" >/dev/null 2>&1 || { no "teeth $1: could not build the mutant (refused by lib/mutant.sh)"; return 1; }
  }
  mkdir -p "$TMP/live/livecorp" "$TMP/live/leak"
  printf 'clean\n' > "$TMP/live/livecorp/a.md"; printf 'Leaked: AKIAIOSFODNN7EXAMPLE\n' > "$TMP/live/leak/a.md"
  SHIM_LINE='^rsdd_exec secrets scan --toolbelt "\$_RSDD_SELF" "\$@"'
  GOODSHIM="$MUT/good/toolbelt/scan-secrets.sh"
  mkshim good "" || exit 2
  if mkshim A 's#'"$SHIM_LINE"'#rsdd_exec secrets scan --toolbelt "$_RSDD_SELF"#'; then
    tooth "teeth(shim-args): arguments no longer forwarded → the scan has no target and refuses" 1 2 "$MUT/A/toolbelt/scan-secrets.sh" \
      --orig "$GOODSHIM" -- bash @SUT@ "$TMP/live/leak"
  fi
  if mkshim B 's#^rsdd_exec secrets scan #rsdd_exec secrets scans #'; then
    tooth "teeth(shim-command): wrong subcommand name → an unknown command, not a scan" 1 2 "$MUT/B/toolbelt/scan-secrets.sh" \
      --orig "$GOODSHIM" -- bash @SUT@ "$TMP/live/leak"
  fi
  if mkshim D 's#'"$SHIM_LINE"'#( rsdd_exec secrets scan --toolbelt "$_RSDD_SELF" "$@" ); exit 0#'; then
    tooth "teeth(shim-exit): exit code laundered to 0 → a leak no longer fails the caller" 1 0 "$MUT/D/toolbelt/scan-secrets.sh" \
      --orig "$GOODSHIM" -- bash @SUT@ "$TMP/live/leak"
  fi
  if mkshim E 's#--toolbelt "\$_RSDD_SELF" ##'; then
    tooth "teeth(shim-toolbelt): the shim's directory is no longer handed over → TARGETS.md is not found, no live-install reminder" 0 0 "$MUT/E/toolbelt/scan-secrets.sh" \
      --orig "$GOODSHIM" --good-has 'LIVE-INSTALL' --bad-lacks 'LIVE-INSTALL' -- bash @SUT@ "$TMP/live/livecorp"
  fi
  # the library guard: a shim with no lib beside it says so and exits 2; a mutant that exits 0 there hides a missing binary
  mkdir -p "$MUT/Cgood" "$MUT/C"
  cp "$SUT" "$MUT/Cgood/scan-secrets.sh"
  if mutant_sed "$SUT" "$MUT/C/scan-secrets.sh" 's#exit 2; }   \# SENTINEL-RSDD-EXEC-GUARD#exit 0; }   \# SENTINEL-RSDD-EXEC-GUARD#' >/dev/null 2>&1; then
    tooth "teeth(shim-guard): missing-library guard exits 0 → a missing rsdd reads as a clean scan" 2 0 "$MUT/C/scan-secrets.sh" \
      --orig "$MUT/Cgood/scan-secrets.sh" --good-has 'rsdd-exec.sh missing' -- bash @SUT@ "$TMP/live/leak"
  else no "teeth(shim-guard): could not build the mutant (refused by lib/mutant.sh)"; fi
fi

[ "$skips" -gt 0 ] && echo "== $pass passed · $fail failed · $skips skipped ==" || echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
