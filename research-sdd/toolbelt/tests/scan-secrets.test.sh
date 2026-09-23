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

# 35 — --committed: git grep fails (rc ≥ 2) → typed DEGRADED exit 3, not silent pass (B3 rc capture).
# Probe passes (rev-parse works); only grep exits 2 to simulate a git error during scan.
REAL_GIT35="$(type -P git 2>/dev/null)"
d_t35="$TMP/committed-grep-fail"
mkdir -p "$d_t35/corpus"
git -C "$d_t35" init -q 2>/dev/null
git -C "$d_t35" config user.email "test@test" && git -C "$d_t35" config user.name "test"
printf '# Block 1\n\nresearch note\n' > "$d_t35/corpus/t-block1.md"
git -C "$d_t35" add corpus/t-block1.md && git -C "$d_t35" commit -q -m "init" 2>/dev/null
_stub_bad_grep="$TMP/bad-grep-bin"; mkdir -p "$_stub_bad_grep"
printf '#!/bin/bash\ncase "$*" in\n  *" grep "*) exit 2 ;;\n  *) exec "%s" "$@" ;;\nesac\n' \
  "$REAL_GIT35" > "$_stub_bad_grep/git"; chmod +x "$_stub_bad_grep/git"
cm_out35="$(PATH="$_stub_bad_grep:$PATH" bash "$SUT" --committed "$d_t35" 2>&1)"
cm_rc35=$?
if [ "$cm_rc35" = 3 ] && printf '%s' "$cm_out35" | grep -qi 'degraded'; then
  ok "35 --committed git grep rc2 → typed DEGRADED exit 3, not silent pass (B3)"
else
  no "35 --committed git grep fail: rc=$cm_rc35 (want 3) out=$cm_out35"
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

  # Teeth for tests 27 and 28 (--committed mode): remove HEAD from the git grep so it falls back to
  # the working tree — tests 27 and 28 must then FAIL (committed-mode token not caught in the WT).
  echo "-- teeth: remove HEAD from 'git grep … HEAD' — tests 27+28 must go red (WT scan, not committed) --"
  mutant_cm="$TMP/scan-secrets.MUTANT-committed.sh"
  sed 's/git -C "\$target" grep -nIE -e "\$re" HEAD/git -C "$target" grep -nIE "$re"/g' "$SUT" > "$mutant_cm"
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
  # GNU sed: neuter the probe (first committed=1 guard) and both B3 rc-checks.
  # NOTE: file must NOT be named '*degraded*' — the grep pattern below checks for that string and
  # bash error messages include the script path, which would cause a false match.
  sed '0,/if \[ "\$committed" = 1 \]; then/{s/if \[ "\$committed" = 1 \]; then/if false; then/}' \
    "$SUT" \
  | sed 's/if \[ "\$_scan_rc" -ge 2 \]/if false/g; s/if \[ "\$_adv_rc" -ge 2 \]/if false/g' \
    > "$mutant_deg"
  cm_out29m="$(PATH="$_stub_no_git" bash "$mutant_deg" --committed "$d_deg" 2>&1)"
  cm_rc29m=$?
  if printf '%s' "$cm_out29m" | grep -qiE 'degraded|git not'; then
    no "teeth-deg: probe-neutered mutant still emits DEGRADED — test 29 is THEATER"
  else
    ok "teeth-deg: probe-neutered mutant no DEGRADED output → test 29 has teeth (rc=$cm_rc29m)"
  fi

  # Teeth for tests 31 (B1: -e required) and 32-34 (B2: :(glob) pathspecs).
  # Mutant-b1: remove '-e' from the committed git grep in scan() → PEM pattern parsed as option → rc 129 → 0 hits.
  # Test 31 must flip to FAIL (exit 0 instead of 1).
  echo "-- teeth-b1: remove -e from committed git grep — test 31 PEM must go red --"
  mutant_b1="$TMP/scan-secrets.MUTANT-b1.sh"
  sed 's/grep -nIE -e "\$re" HEAD/grep -nIE "\$re" HEAD/g' "$SUT" > "$mutant_b1"
  cm_rc31m="$(bash "$mutant_b1" --committed "$d_t31" >/dev/null 2>&1; echo $?)"
  [ "$cm_rc31m" != 1 ] && ok "teeth-b1: -e-removed mutant misses PEM (rc=$cm_rc31m) → test 31 has teeth" \
    || no "teeth-b1: mutant still caught PEM (rc=$cm_rc31m) — test 31 is THEATER"

  # Mutant-b2: replace :(glob)**/.env* with .env* (root-anchored) → nested .env.local missed.
  # Test 32 must flip to FAIL (exit 0 instead of 1).
  echo "-- teeth-b2: root-anchor .env* pathspec — test 32 nested .env must go red --"
  mutant_b2="$TMP/scan-secrets.MUTANT-b2.sh"
  sed "s|':(glob)\*\*/.env\*'|'.env*'|g" "$SUT" > "$mutant_b2"
  cm_rc32m="$(bash "$mutant_b2" --committed "$d_t32" >/dev/null 2>&1; echo $?)"
  [ "$cm_rc32m" != 1 ] && ok "teeth-b2: root-anchored .env* mutant misses nested .env.local (rc=$cm_rc32m) → test 32 has teeth" \
    || no "teeth-b2: mutant still caught nested .env.local (rc=$cm_rc32m) — test 32 is THEATER"

  # Teeth for test 35 (B3: git grep rc ≥ 2 → DEGRADED).
  # Mutant-b3: remove the rc ≥ 2 check so git grep errors are silently passed.
  # Test 35 must flip to FAIL (exit 0 instead of 3).
  echo "-- teeth-b3: remove git grep rc check — test 35 must go red (silent pass) --"
  mutant_b3="$TMP/scan-secrets.MUTANT-b3.sh"
  # Neuter the _scan_rc ≥ 2 check in scan() and the _adv_rc ≥ 2 check in advisory.
  sed 's/if \[ "\$_scan_rc" -ge 2 \]/if false/g; s/if \[ "\$_adv_rc" -ge 2 \]/if false/g' \
    "$SUT" > "$mutant_b3"
  REAL_GIT35="$(type -P git 2>/dev/null)"
  cm_out35m="$(PATH="$_stub_bad_grep:$PATH" bash "$mutant_b3" --committed "$d_t35" 2>&1)"
  cm_rc35m=$?
  if [ "$cm_rc35m" != 3 ] && ! printf '%s' "$cm_out35m" | grep -qi 'degraded'; then
    ok "teeth-b3: rc-check-removed mutant silently passes (rc=$cm_rc35m) → test 35 has teeth"
  else
    no "teeth-b3: mutant still emits DEGRADED (rc=$cm_rc35m) — test 35 is THEATER"
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
