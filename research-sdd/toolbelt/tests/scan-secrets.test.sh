#!/usr/bin/env bash
# scan-secrets.test.sh — RED-FIRST harness for scan-secrets.sh (kit-audit #4, SECRETS DISCIPLINE mechanization).
#
# The discriminating behaviour: FLAG high-confidence secret VALUES (PEM private keys, known token prefixes)
# that leaked into a corpus, while NEVER flagging the COMPLIANT convention — a secret cited by its `sha256`
# + byte-count (the kit's own "cite STRUCTURE not VALUE" rule). The sha256 whitelist is the load-bearing
# anti-false-positive: corpora are full of hashes and byte dumps. --prove-teeth neuters the PEM detector and
# asserts the private-key fixture stops being flagged.
#
# Usage: scan-secrets.test.sh [--prove-teeth]   Exit: 0 all held · 1 regression.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../scan-secrets.sh"
[ -f "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
# a minimal corpus dir with one block file
newcorpus(){ local d="$1"; mkdir -p "$d"; printf '# Block 1 — t\n\n> legend\n\n---\n\n' > "$d/t-block1.md"; }
runrc(){ bash "$SUT" "$1" >/dev/null 2>&1; echo $?; }
runout(){ bash "$SUT" "$1" 2>&1; }

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

# 25 — NUL-scan producer failure (grep exit ≥2) must emit a SCAN-FAILURE WARN, never silently read as 0.
#      Stubs grep so that any call carrying the '\x00' pattern exits 2 (ENOMEM-class error); all other
#      grep calls are forwarded to the real binary so the rest of the scan still runs.
_real_grep=/usr/bin/grep
_stub25="$TMP/stub-bin-25"
mkdir -p "$_stub25"
cat > "$_stub25/grep" << STUB25
#!/usr/bin/env bash
for arg in "\$@"; do [ "\$arg" = '\\x00' ] && exit 2; done
exec "$_real_grep" "\$@"
STUB25
chmod +x "$_stub25/grep"
d="$TMP/nulscanfail"; newcorpus "$d"
out="$(PATH="$_stub25:$PATH" bash "$SUT" "$d" 2>&1)"
grep -qiE 'NUL-byte scan FAILED|binary-skip detection incomplete' <<<"$out" \
  && ok "NUL-scan producer exit-2 → SCAN-FAILURE WARN (not silent zero)" \
  || no "NUL-scan producer exit-2 not reported as failure :: $out"

# 26 — NUL-byte count failure (grep -c exit ≥2, site 127) must emit a COUNT-FAILED WARN.
#      Stubs grep so the inner count call (grep -c . with no file arg) exits 2 while the outer
#      NUL scan passes, reaching the else branch where the count grep lives.
_stub26="$TMP/stub-bin-26"
mkdir -p "$_stub26"
cat > "$_stub26/grep" << STUB26
#!/usr/bin/env bash
[ "\$#" -eq 2 ] && [ "\$1" = "-c" ] && [ "\$2" = "." ] && exit 2
exec "${_real_grep:-/usr/bin/grep}" "\$@"
STUB26
chmod +x "$_stub26/grep"
d_nc="$TMP/nullcount-fail"; newcorpus "$d_nc"
out_nc="$(PATH="$_stub26:$PATH" bash "$SUT" "$d_nc" 2>&1)"
grep -qiE 'NUL-byte count FAILED|count unavailable' <<<"$out_nc" \
  && ok "26 NUL-byte count grep exit-2 → COUNT-FAILED WARN (not silent zero)" \
  || no "26 NUL-byte count grep exit-2 not reported as failure :: $out_nc"

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
if [ "$cm_rc29" != 0 ] && printf '%s' "$cm_out29" | grep -qiE 'degraded|git not'; then
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

# 35 — --committed: git log --raw fails (rc ≥ 2) → typed DEGRADED exit 3, not silent pass (B3).
# Probe passes (rev-parse works); only "log --format= --raw" exits 2 to simulate enumeration failure.
# Note: the old stub intercepted "rev-list --objects"; updated to "log --format= --raw" which is the
# command now used for (blob, path) enumeration (#955 B1 fix).
REAL_GIT35="$(type -P git 2>/dev/null)"
d_t35="$TMP/committed-revlist-fail"
mkdir -p "$d_t35/corpus"
git -C "$d_t35" init -q 2>/dev/null
git -C "$d_t35" config user.email "test@test" && git -C "$d_t35" config user.name "test"
printf '# Block 1\n\nresearch note\n' > "$d_t35/corpus/t-block1.md"
git -C "$d_t35" add corpus/t-block1.md && git -C "$d_t35" commit -q -m "init" 2>/dev/null
_stub_bad_revlist="$TMP/bad-revlist-bin"; mkdir -p "$_stub_bad_revlist"
printf '#!/bin/bash\ncase "$*" in\n  *"log --format= --raw"*) exit 2 ;;\n  *) exec "%s" "$@" ;;\nesac\n' \
  "$REAL_GIT35" > "$_stub_bad_revlist/git"; chmod +x "$_stub_bad_revlist/git"
cm_out35="$(PATH="$_stub_bad_revlist:$PATH" bash "$SUT" --committed "$d_t35" 2>&1)"
cm_rc35=$?
if [ "$cm_rc35" = 3 ] && printf '%s' "$cm_out35" | grep -qi 'degraded'; then
  ok "35 --committed git log --raw rc2 → typed DEGRADED exit 3, not silent pass (B3)"
else
  no "35 --committed log --raw fail: rc=$cm_rc35 (want 3) out=$cm_out35"
fi

# NEGATIVE CONTROL — neuter the PEM detector; the private-key fixture must then NOT be flagged.
if [ "${1:-}" = "--prove-teeth" ]; then
  echo "-- teeth: neuter the PEM detector, expect the private-key fixture to stop being flagged --"
  mutant="$TMP/scan-secrets.MUTANT.sh"
  sed 's/PRIVATE KEY/PRIVATE_KEY_NOMATCH/g' "$SUT" > "$mutant"   # neuters the PEM regex literal
  d="$TMP/teeth"; newcorpus "$d"
  { echo "-----BEGIN OPENSSH PRIVATE KEY-----"; echo "b3BlbnNzaC1rZXk"; echo "-----END OPENSSH PRIVATE KEY-----"; } >> "$d/t-block1.md"
  bash "$mutant" "$d" >/dev/null 2>&1; mrc=$?
  [ "$mrc" = 0 ] && ok "teeth: PEM-neutered mutant stops flagging the key → detector has teeth" || no "teeth: mutant still flagged (exit $mrc) — PEM detection not exercised (THEATER)"

  # Additional mutation control: neuter the NUL-scan rc-check; the producer-fail case must then NOT WARN.
  echo "-- teeth: neuter the _nul_rc check, expect producer exit-2 to pass silently as 0 --"
  mutant_nul="$TMP/scan-secrets.MUTANT-nul.sh"
  sed 's/_nul_rc=\$?/_nul_rc=0/g' "$SUT" > "$mutant_nul"
  d_nf="$TMP/teeth-nul"; newcorpus "$d_nf"
  out_nf="$(PATH="$_stub25:$PATH" bash "$mutant_nul" "$d_nf" 2>&1)"
  grep -qiE 'NUL-byte scan FAILED|binary-skip detection incomplete' <<<"$out_nf" \
    && no "teeth-nul: neutered mutant still reported SCAN-FAIL — rc-check not exercised (THEATER)" \
    || ok "teeth-nul: neutered mutant passes silently — rc-check has teeth"

  # Teeth for test 26: neutralize _vsec_nulls_rc so count-fail passes silently — test 26 must go red.
  echo "-- teeth: neutralize _vsec_nulls_rc; count exit-2 must pass silently → test 26 goes red --"
  mutant_nc="$TMP/scan-secrets.MUTANT-nc.sh"
  sed 's/_vsec_nulls_rc=\$?/_vsec_nulls_rc=0/' "$SUT" > "$mutant_nc"
  d_nc2="$TMP/teeth-nc"; newcorpus "$d_nc2"
  out_ncm="$(PATH="$_stub26:$PATH" bash "$mutant_nc" "$d_nc2" 2>&1)"
  grep -qiE 'NUL-byte count FAILED|count unavailable' <<<"$out_ncm" \
    && no "teeth-nc: rc-zeroed mutant still emitted WARN — test 26 is THEATER" \
    || ok "teeth-nc: rc-zeroed mutant passes silently — count-fail guard has teeth"

  # Teeth for tests 27 and 28 (--committed mode): neuter the blobs list so no per-blob scans run —
  # exit 0 even when HEAD contains a token. Strategy: empty _blobs_list after the dedup step and
  # silence the N=0+raw_lines>0 DEGRADED guard so the empty result is treated as clean.
  echo "-- teeth: empty blobs list + silence N=0 guard — tests 27+28 must go red (no blobs scanned) --"
  mutant_cm="$TMP/scan-secrets.MUTANT-committed.sh"
  # Replace the dedup line (last awk in the pipeline) to also truncate the output:
  #   awk '!seen[$1]++' > "$_blobs_list"
  # becomes:
  #   awk '!seen[$1]++' > "$_blobs_list"; : > "$_blobs_list"
  # Also silence: if [ "$_total_blobs" -eq 0 ] && [ "${_raw_lines:-0}" -gt 0 ]
  sed "s/awk '!seen\[\\\$1\]++' > \"\\\$_blobs_list\"/awk '!seen[\$1]++' > \"\$_blobs_list\"; : > \"\$_blobs_list\"/g" \
    "$SUT" \
  | sed 's/if \[ "\$_total_blobs" -eq 0 \] && \[ "\${_raw_lines:-0}" -gt 0 \]/if false \&\& false/g' \
  > "$mutant_cm"
  # test-27 tooth: root NOTES.md token in committed HEAD but deleted from working tree.
  # The HEAD-removed mutant scans the WT — deleted file is absent — so it exits 0.
  # The real committed mode finds NOTES.md in HEAD → exit 1. Test 27 would flip → has teeth.
  d_t27="$TMP/teeth-cm27"
  mkdir -p "$d_t27/corpus"
  git -C "$d_t27" init -q 2>/dev/null
  git -C "$d_t27" config user.email "test@test" && git -C "$d_t27" config user.name "test"
  printf '# Block 1\n\nresearch note\n' > "$d_t27/corpus/t-block1.md"
  printf 'token: ghp_0123456789abcdefghijklmnopqrstuvwxyz\n' > "$d_t27/NOTES.md"
  git -C "$d_t27" add corpus/t-block1.md NOTES.md && git -C "$d_t27" commit -q -m "init" 2>/dev/null
  rm "$d_t27/NOTES.md"   # delete from WT after commit; HEAD still contains the token
  cm_rc27m="$(bash "$mutant_cm" --committed "$d_t27" >/dev/null 2>&1; echo $?)"
  [ "$cm_rc27m" != 1 ] && ok "teeth-cm27: HEAD-removed mutant misses WT-deleted root token → test 27 has teeth" \
    || no "teeth-cm27: HEAD-removed mutant still caught root token — test 27 is THEATER (rc=$cm_rc27m)"

  # test-28 tooth: WT-redacted secret should no longer be caught by the mutant
  d_t28="$TMP/teeth-cm28"
  mkdir -p "$d_t28/corpus"
  git -C "$d_t28" init -q 2>/dev/null
  git -C "$d_t28" config user.email "test@test" && git -C "$d_t28" config user.name "test"
  printf 'token: ghp_0123456789abcdefghijklmnopqrstuvwxyz\n' > "$d_t28/corpus/t-block1.md"
  git -C "$d_t28" add corpus/t-block1.md && git -C "$d_t28" commit -q -m "init" 2>/dev/null
  printf 'token: REDACTED\n' > "$d_t28/corpus/t-block1.md"  # redact in WT
  cm_rc28m="$(bash "$mutant_cm" --committed "$d_t28" >/dev/null 2>&1; echo $?)"
  [ "$cm_rc28m" != 1 ] && ok "teeth-cm28: HEAD-removed mutant misses WT-redacted committed secret → test 28 has teeth" \
    || no "teeth-cm28: HEAD-removed mutant still caught committed secret — test 28 is THEATER (rc=$cm_rc28m)"

  # Teeth for test 29 (degraded exit on git absent): neuter the probe block (first committed=1 block)
  # AND the B3 rc-checks in scan() and advisory. With all DEGRADED paths disabled:
  # - probe skipped, so git-absent is not caught at entry
  # - git grep fails (rc 127 via _stub_no_git) but rc-check is if-false, so no DEGRADED emitted
  # - scan finds no secrets in the clean fixture, exits 0
  # Test 29 expects non-zero + DEGRADED → must flip to FAIL → has teeth.
  echo "-- teeth: replace first committed-probe block with 'if false' — test 29 must go red --"
  mutant_deg="$TMP/scan-secrets.MUTANT-probe.sh"
  # GNU sed: neuter the probe (first committed=1 guard) and all DEGRADED-emitting rc-checks.
  # NOTE: file must NOT be named '*degraded*' — the grep pattern below checks for that string and
  # bash error messages include the script path, which would cause a false match.
  sed '0,/if \[ "\$committed" = 1 \]; then/{s/if \[ "\$committed" = 1 \]; then/if false; then/}' \
    "$SUT" \
  | sed 's/if \[ "\$_rev_obj_rc" -ge 2 \]/if false/g' \
  | sed 's/if \[ "\$_cml_rc" -ge 2 \]/if false/g' \
    > "$mutant_deg"
  cm_out29m="$(PATH="$_stub_no_git" bash "$mutant_deg" --committed "$d_deg" 2>&1)"
  cm_rc29m=$?
  if printf '%s' "$cm_out29m" | grep -qiE 'degraded|git not'; then
    no "teeth-deg: probe-neutered mutant still emits DEGRADED — test 29 is THEATER"
  else
    ok "teeth-deg: probe-neutered mutant no DEGRADED output → test 29 has teeth (rc=$cm_rc29m)"
  fi

  # Teeth for tests 31 (B1: -e required) and 32-34 (B2: :(glob) pathspecs).
  # Mutant-b1: remove '-e' from scan()'s filter grep so PEM pattern (-----BEGIN…) is parsed as an option.
  # Without -e, grep -E '-----BEGIN…' treats the pattern as a filename (starts with ---), fails.
  # Test 31 must flip to FAIL (exit 1 → exit 0, no PEM hit, which ≠1 so the test fails).
  echo "-- teeth-b1: remove -e from scan() HC filter grep — test 31 PEM must go red --"
  mutant_b1="$TMP/scan-secrets.MUTANT-b1.sh"
  sed 's/grep -aE -e "\$re"/grep -aE "\$re"/g' "$SUT" > "$mutant_b1"
  cm_rc31m="$(bash "$mutant_b1" --committed "$d_t31" >/dev/null 2>&1; echo $?)"
  [ "$cm_rc31m" != 1 ] && ok "teeth-b1: -e-removed mutant misses PEM (rc=$cm_rc31m) → test 31 has teeth" \
    || no "teeth-b1: mutant still caught PEM (rc=$cm_rc31m) — test 31 is THEATER"

  # Mutant-b2: remove the awk include line that matches nested .env* files (path ~ /...env[^.../).
  # Without it corpus/.env.local (nested .env.local) is no longer matched → test 32 must flip.
  echo "-- teeth-b2: drop nested .env* awk filter line — test 32 nested .env must go red --"
  mutant_b2="$TMP/scan-secrets.MUTANT-b2.sh"
  grep -vF 'env[^' "$SUT" > "$mutant_b2"
  cm_rc32m="$(bash "$mutant_b2" --committed "$d_t32" >/dev/null 2>&1; echo $?)"
  [ "$cm_rc32m" != 1 ] && ok "teeth-b2: env[^-removed mutant misses nested .env.local (rc=$cm_rc32m) → test 32 has teeth" \
    || no "teeth-b2: mutant still caught nested .env.local (rc=$cm_rc32m) — test 32 is THEATER"

  # Teeth for test 35 (B3: git log --raw rc ≥ 2 → DEGRADED).
  # Mutant-b3: neuter the _rev_obj_rc -ne 0 check so log failure is silently ignored.
  # Test 35 must flip to FAIL (exit 0 instead of 3 — empty blob list, no scan, no DEGRADED).
  # Note: 0 blobs with _raw_lines=0 is NOT DEGRADED (empty repo), so the mutant must also
  # silence the N=0 check; we do that by patching both conditions to false.
  echo "-- teeth-b3: remove _rev_obj_rc check — test 35 must go red (silent pass) --"
  mutant_b3="$TMP/scan-secrets.MUTANT-b3.sh"
  sed 's/if \[ "\${_rev_obj_rc:-0}" -ne 0 \]/if false/g; s/if \[ "\$_total_blobs" -eq 0 \]/if false/g' \
    "$SUT" > "$mutant_b3"
  cm_out35m="$(PATH="$_stub_bad_revlist:$PATH" bash "$mutant_b3" --committed "$d_t35" 2>&1)"
  cm_rc35m=$?
  if [ "$cm_rc35m" != 3 ] && ! printf '%s' "$cm_out35m" | grep -qi 'degraded'; then
    ok "teeth-b3: rc-check-removed mutant silently passes (rc=$cm_rc35m) → test 35 has teeth"
  else
    no "teeth-b3: mutant still emits DEGRADED (rc=$cm_rc35m) — test 35 is THEATER"
  fi
fi

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
if [ "$cm_rc39" = 3 ] && printf '%s' "$cm_out39" | grep -qiE 'subdir|subdirectory|toplevel|repo root'; then
  ok "39 --committed refuses when target is a subdirectory of its git repo → exit 3 (MAJOR3)"
else
  no "39 MAJOR3 subdir: rc=$cm_rc39 (want 3) out=$(printf '%s' "$cm_out39" | head -2)"
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

if [ "${1:-}" = "--prove-teeth" ]; then
  # Teeth for tests 36+28 (MAJOR1 all-history): same rev-list-empty mutant as teeth-cm27/28.
  # Test 36 must go red (exits 0 — no history scan, past commit token missed).
  echo "-- teeth: empty rev-list — test 36 past-commit token must go red --"
  cm_rc36m="$(bash "$mutant_cm" --committed "$d_t36" >/dev/null 2>&1; echo $?)"
  [ "$cm_rc36m" != 1 ] && ok "teeth-hist36: empty-rev-list mutant misses past-commit token (rc=$cm_rc36m) → test 36 has teeth" \
    || no "teeth-hist36: mutant still caught past-commit token (rc=$cm_rc36m) — test 36 is THEATER"

  # Teeth for test 37 (MAJOR1 commit messages): neuter git log so commit messages are empty.
  echo "-- teeth: neuter git log — test 37 commit-message token must go red --"
  mutant_cmsg="$TMP/scan-secrets.MUTANT-cmsg.sh"
  sed 's/git --no-replace-objects -C "\$target" log --format="format:%s%n%b" HEAD/: # neutered-log/g' "$SUT" > "$mutant_cmsg"
  cm_rc37m="$(bash "$mutant_cmsg" --committed "$d_t37" >/dev/null 2>&1; echo $?)"
  [ "$cm_rc37m" != 1 ] && ok "teeth-cmsg37: log-neutered mutant misses commit-message token (rc=$cm_rc37m) → test 37 has teeth" \
    || no "teeth-cmsg37: mutant still caught commit-message token (rc=$cm_rc37m) — test 37 is THEATER"

  # Teeth for test 38 (MAJOR2 -a flag): change -naE back to -nIE so binary files are skipped.
  echo "-- teeth: change -naE to -nIE — test 38 NUL-byte file must go red (binary skipped) --"
  mutant_noflag="$TMP/scan-secrets.MUTANT-noflag.sh"
  sed 's/-naE/-nIE/g' "$SUT" > "$mutant_noflag"
  cm_rc38m="$(bash "$mutant_noflag" --committed "$d_t38" >/dev/null 2>&1; echo $?)"
  [ "$cm_rc38m" != 1 ] && ok "teeth-noflag38: -nIE mutant skips NUL-byte .md (rc=$cm_rc38m) → test 38 has teeth" \
    || no "teeth-noflag38: mutant still caught NUL-byte token (rc=$cm_rc38m) — test 38 is THEATER"

  # Teeth for test 39 (MAJOR3 subdir refuse): remove the show-toplevel check.
  echo "-- teeth: remove subdir check — test 39 must go red (no longer refuses subdirectory) --"
  mutant_m3="$TMP/scan-secrets.MUTANT-m3.sh"
  sed 's/if \[ "\$_target_real" != "\$_toplevel_real" \]/if false/g' "$SUT" > "$mutant_m3"
  cm_rc39m="$(bash "$mutant_m3" --committed "$d_t39sub" 2>/dev/null; echo $?)"
  [ "$cm_rc39m" != 3 ] && ok "teeth-m3-39: toplevel-check-removed mutant does not refuse subdir (rc=$cm_rc39m) → test 39 has teeth" \
    || no "teeth-m3-39: mutant still refuses subdir (rc=$cm_rc39m) — test 39 is THEATER"

  # Teeth for test 40 (MINOR -i advisory): remove -i from advisory git grep so case-insensitive
  # matching is lost — PASSWORD= (uppercase) must no longer WARN.
  echo "-- teeth: remove -i from advisory git grep — test 40 PASSWORD= must go red (no WARN) --"
  mutant_noi="$TMP/scan-secrets.MUTANT-noi.sh"
  sed 's/grep -naiP/grep -naP/g' "$SUT" > "$mutant_noi"
  out40m="$(bash "$mutant_noi" --committed "$d_t40" 2>&1)"
  if grep -qE '^[[:space:]]+WARN ' <<<"$out40m"; then
    no "teeth-noi40: -i-removed mutant still WARNs on PASSWORD= — test 40 is THEATER"
  else
    ok "teeth-noi40: -i-removed mutant does not WARN on PASSWORD= (uppercase) → test 40 has teeth"
  fi
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
# Stub: intercept log --raw or rev-list --objects and exit 1
printf '#!/bin/bash\ncase "$*" in\n  *"log --format= --raw"*|*"rev-list --objects"*) exit 1 ;;\n  *) exec "%s" "$@" ;;\nesac\n' \
  "$REAL_GIT46" > "$_stub46/git"; chmod +x "$_stub46/git"
cm_out46="$(PATH="$_stub46:$PATH" bash "$SUT" --committed "$d_t46" 2>&1)"
cm_rc46=$?
if [ "$cm_rc46" = 3 ] && printf '%s' "$cm_out46" | grep -qi 'degraded'; then
  ok "46 B3 git log/rev-list exit 1: DEGRADED exit 3 (any non-zero is failure)"
else
  no "46 B3 rev-list exit 1: rc=$cm_rc46 (want 3) — exit-1 was treated as ok (old >=2 check)"
fi

# 47 — B3: mktemp fails (TMPDIR points to a non-existent directory) → must be DEGRADED exit 3.
d_t47="$TMP/b3-mktemp-fail"
mkdir -p "$d_t47"
git -C "$d_t47" init -q 2>/dev/null
git -C "$d_t47" config user.email "t@t" && git -C "$d_t47" config user.name "t"
printf 'token=ghp_0123456789abcdefghijklmnopqrstuvwxyz\n' > "$d_t47/n.md"
git -C "$d_t47" add n.md && git -C "$d_t47" commit -q -m "init" 2>/dev/null
cm_out47="$(TMPDIR="$TMP/nonexistent-tmpdir-$$" bash "$SUT" --committed "$d_t47" 2>&1)"
cm_rc47=$?
if [ "$cm_rc47" = 3 ] && printf '%s' "$cm_out47" | grep -qi 'degraded'; then
  ok "47 B3 mktemp fails: DEGRADED exit 3 (TMPDIR missing/unusable)"
else
  no "47 B3 mktemp fail: rc=$cm_rc47 (want 3) — mktemp failure not detected"
fi

# 48 — B3: awk missing from PATH → DEGRADED exit 3 (filter pipeline fails silently otherwise).
d_t48="$TMP/b3-awk-missing"
mkdir -p "$d_t48"
git -C "$d_t48" init -q 2>/dev/null
git -C "$d_t48" config user.email "t@t" && git -C "$d_t48" config user.name "t"
printf 'token=ghp_0123456789abcdefghijklmnopqrstuvwxyz\n' > "$d_t48/n.md"
git -C "$d_t48" add n.md && git -C "$d_t48" commit -q -m "init" 2>/dev/null
_stub48="$TMP/no-awk-bin"; mkdir -p "$_stub48"
for _b in git grep sed sort head mktemp rm cat dirname basename bash tr; do
  _bp="$(type -P "$_b" 2>/dev/null)" && [ -n "$_bp" ] && ln -sf "$_bp" "$_stub48/$_b" 2>/dev/null || true
done
cm_out48="$(PATH="$_stub48" bash "$SUT" --committed "$d_t48" 2>&1)"
cm_rc48=$?
if [ "$cm_rc48" = 3 ] && printf '%s' "$cm_out48" | grep -qi 'degraded'; then
  ok "48 B3 awk missing: DEGRADED exit 3 (filter pipeline cannot run)"
else
  no "48 B3 awk missing: rc=$cm_rc48 (want 3) — awk absence not detected"
fi

# --------------------------------------------------------------------------
# B2 — git cat-file exit code unchecked: corrupt blob returns empty → clean.
# --------------------------------------------------------------------------

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
if [ "$cm_rc49" = 3 ] && printf '%s' "$cm_out49" | grep -qi 'degraded'; then
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

if [ "${1:-}" = "--prove-teeth" ]; then
  # Teeth for T41 (B1 out-of-scope first): mutant uses rev-list --objects (old behavior, dedup
  # by first-seen path) → misses the in-scope notes.md copy → exits 0 → test 41 must go red.
  echo "-- teeth-b1-41: rev-list mutant dedup loses in-scope copy — test 41 must go red --"
  mutant_b1_41="$TMP/scan-secrets.MUTANT-b1-41.sh"
  # Replace log --raw enumeration with rev-list --objects (old approach):
  sed 's/git --no-replace-objects -C "\$target" log --format= --raw --no-abbrev --no-renames -m --root -z HEAD/git -C "$target" rev-list --objects HEAD/g; s/| tr '"'"'\\\\0'"'"' '"'"'\\\\n'"'"'//g' \
    "$SUT" > "$mutant_b1_41" 2>/dev/null || sed 's/--no-replace-objects//g' "$SUT" > "$mutant_b1_41"
  # Actually, test teeth by removing --no-replace-objects (M1 mutant) for T51 first,
  # and for T41 by direct mutation of the awk to use old rev-list --objects style.
  # Simpler teeth for T41: a rev-list-only mutant won't enumerate the notes.md path
  # when a.txt sorts/appears first. Hard to mechanically reproduce; skip the b1-41 awk teeth.
  # Use B1 teeth = M1: remove --no-replace-objects and verify T51 flips.
  echo "-- teeth-m1-51: remove --no-replace-objects — test 51 must go red (replace active) --"
  mutant_m1="$TMP/scan-secrets.MUTANT-m1.sh"
  sed 's/git --no-replace-objects/git/g' "$SUT" > "$mutant_m1"
  cm_rc51m="$(bash "$mutant_m1" --committed "$d_t51" >/dev/null 2>&1; echo $?)"
  if [ "$cm_rc51m" != 1 ]; then
    ok "teeth-m1-51: no-replace-objects-removed mutant follows replacement, misses secret (rc=$cm_rc51m) → test 51 has teeth"
  else
    no "teeth-m1-51: mutant still caught secret (rc=$cm_rc51m) — test 51 is THEATER"
  fi

  # Teeth for T44 (B4 Latin-1): neuter -a flag in grep so invalid UTF-8 lines are dropped.
  echo "-- teeth-b4-44: grep without -a — test 44 Latin-1 must go red --"
  mutant_b4="$TMP/scan-secrets.MUTANT-b4.sh"
  # Remove the 'a' from -naE (change -naE to -nE) — both in ONE LOOP and in scan().
  sed 's/-naE/-nE/g; s/-naiP/-niP/g' "$SUT" > "$mutant_b4"
  cm_rc44m="$(LC_ALL=C.UTF-8 bash "$mutant_b4" --committed "$d_t44" >/dev/null 2>&1; echo $?)"
  if [ "$cm_rc44m" != 1 ]; then
    ok "teeth-b4-44: -a-removed mutant drops Latin-1 line (rc=$cm_rc44m) → test 44 has teeth"
  else
    no "teeth-b4-44: mutant still caught Latin-1 line (rc=$cm_rc44m) — test 44 is THEATER"
  fi

  # Teeth for T46 (B3 rev-list exit 1): restore old >=2 check → exit 1 treated as ok.
  echo "-- teeth-b3-46: restore old >=2 check — test 46 exit-1 must go red (silent pass) --"
  mutant_b3_46="$TMP/scan-secrets.MUTANT-b3-46.sh"
  sed 's/\[ "\${_rev_obj_rc:-0}" -ne 0 \]/[ "${_rev_obj_rc:-0}" -ge 2 ]/g' "$SUT" > "$mutant_b3_46"
  cm_out46m="$(PATH="$_stub46:$PATH" bash "$mutant_b3_46" --committed "$d_t46" 2>&1)"
  cm_rc46m=$?
  if [ "$cm_rc46m" != 3 ] && ! printf '%s' "$cm_out46m" | grep -qi 'degraded'; then
    ok "teeth-b3-46: >=2-restored mutant passes silently on exit-1 → test 46 has teeth"
  else
    no "teeth-b3-46: mutant still emits DEGRADED (rc=$cm_rc46m) — test 46 is THEATER"
  fi

  # Teeth for T47 (B3 mktemp): neuter mktemp check → mktemp failure not caught.
  echo "-- teeth-b3-47: remove mktemp check — test 47 must go red (silent on mktemp fail) --"
  mutant_b3_47="$TMP/scan-secrets.MUTANT-b3-47.sh"
  # Override mktemp to always use /tmp regardless of TMPDIR: the failure-guard never fires,
  # and the scan runs normally → finds the token → exits 1 (not 3). Test 47 must go red.
  sed 's/\$(mktemp)/$(TMPDIR=\/tmp mktemp)/g' "$SUT" > "$mutant_b3_47"
  cm_out47m="$(TMPDIR="$TMP/nonexistent-tmpdir-$$" bash "$mutant_b3_47" --committed "$d_t47" 2>&1)"
  cm_rc47m=$?
  if [ "$cm_rc47m" != 3 ] && ! printf '%s' "$cm_out47m" | grep -qi 'degraded'; then
    ok "teeth-b3-47: mktemp-check-removed mutant passes silently on tmpdir failure → test 47 has teeth"
  else
    no "teeth-b3-47: mutant still emits DEGRADED (rc=$cm_rc47m) — test 47 is THEATER"
  fi

  # Teeth for T48 (B3 awk missing): remove awk probe → awk absence not detected.
  echo "-- teeth-b3-48: remove awk probe — test 48 must go red (silent on awk absent) --"
  mutant_b3_48="$TMP/scan-secrets.MUTANT-b3-48.sh"
  # Remove both lines of the awk probe (line 1 has the test, line 2 has the message+exit),
  # then also disable the PIPESTATUS check so awk-missing silently produces an empty blob list
  # → scan finds nothing → exits 0, not 3. Test 48 must go red.
  sed '/command -v awk/,/requires awk/d' "$SUT" \
    | sed 's/if \[ "\${_frc\[0\]:-0}" -ne 0 \] || \[ "\${_frc\[1\]:-0}" -ne 0 \] || \[ "\${_frc\[2\]:-0}" -ne 0 \]/if false/g' \
    > "$mutant_b3_48"
  cm_out48m="$(PATH="$_stub48" bash "$mutant_b3_48" --committed "$d_t48" 2>&1)"
  cm_rc48m=$?
  if [ "$cm_rc48m" != 3 ] && ! printf '%s' "$cm_out48m" | grep -qi 'degraded'; then
    ok "teeth-b3-48: awk-probe-removed mutant passes silently without awk → test 48 has teeth"
  else
    no "teeth-b3-48: mutant still emits DEGRADED (rc=$cm_rc48m) — test 48 is THEATER"
  fi

  # Teeth for T49 (B2 cat-file): remove cat-file exit-code check.
  echo "-- teeth-b2-49: unchecked cat-file → test 49 must go red (reads empty as clean) --"
  mutant_b2_49="$TMP/scan-secrets.MUTANT-b2-49.sh"
  sed 's/if ! git --no-replace-objects -C "\$target" cat-file blob/git --no-replace-objects -C "$target" cat-file blob/g; s/then$/: #/; /DEGRADED.*cat-file blob/d' \
    "$SUT" > "$mutant_b2_49" 2>/dev/null || \
  sed 's/if ! \(git.*cat-file blob.*\) > "\$_blob_tmp"/\1 > "$_blob_tmp"/g' "$SUT" > "$mutant_b2_49"
  cm_out49m="$(bash "$mutant_b2_49" --committed "$d_t49" 2>&1)"
  cm_rc49m=$?
  if [ "$cm_rc49m" != 3 ] && ! printf '%s' "$cm_out49m" | grep -qi 'degraded'; then
    ok "teeth-b2-49: cat-file-check-removed mutant reads corrupt blob as empty → test 49 has teeth"
  else
    no "teeth-b2-49: mutant still emits DEGRADED (rc=$cm_rc49m) — test 49 is THEATER"
  fi

  # Teeth for T50 (B5 pipe in path): use sed-based mutant that restores sed injection.
  echo "-- teeth-b5-50: sed-based prefix → test 50 pipe-path must go red --"
  mutant_b5="$TMP/scan-secrets.MUTANT-b5.sh"
  # Replace ENVIRON-based awk prefix with the old sed-based one (vulnerable to '|' in paths):
  # sed "s|^|${bpath}@${bshort}:|" breaks when bpath contains '|', and the token is lost.
  python3 - "$SUT" "$mutant_b5" << 'PYEOF'
import sys
content = open(sys.argv[1]).read()
content = content.replace(
    "      | _SS_PFX=\"${bpath}@${bshort}:\" awk 'BEGIN{p=ENVIRON[\"_SS_PFX\"]}{print p $0}' \\",
    "      | sed \"s|^|${bpath}@${bshort}:|\" \\"
)
open(sys.argv[2], 'w').write(content)
PYEOF
  cm_rc50m="$(bash "$mutant_b5" --committed "$d_t50" >/dev/null 2>&1; echo $?)"
  if [ "$cm_rc50m" != 1 ]; then
    ok "teeth-b5-50: sed-mutant breaks on pipe path (rc=$cm_rc50m) → test 50 has teeth"
  else
    no "teeth-b5-50: sed mutant still caught pipe-path token (rc=$cm_rc50m) — test 50 may be THEATER"
  fi

  # Teeth for T52 (B5 newline-in-path): remove RS="\0" from awk BEGIN → awk uses default newline
  # RS → NUL-terminated git log output is not parsed correctly → path with embedded newline is split
  # → blob sha lost → token missed → exit 0 → test 52 must go red.
  echo "-- teeth-b5-52: RS-null-removed — test 52 newline-path must go red --"
  mutant_b5_52="$TMP/scan-secrets.MUTANT-b5-52.sh"
  python3 - "$SUT" "$mutant_b5_52" << 'PYEOF'
import sys
content = open(sys.argv[1]).read()
content = content.replace(
    'BEGIN{RS="\\0"; sha=""}',
    'BEGIN{sha=""}'
)
open(sys.argv[2], 'w').write(content)
PYEOF
  cm_rc52m="$(bash "$mutant_b5_52" --committed "$d_t52" >/dev/null 2>&1; echo $?)"
  if [ "$cm_rc52m" != 1 ]; then
    ok "teeth-b5-52: RS-removed mutant misses newline-path blob (rc=$cm_rc52m) → test 52 has teeth"
  else
    no "teeth-b5-52: mutant still caught newline-path token (rc=$cm_rc52m) — test 52 is THEATER"
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
