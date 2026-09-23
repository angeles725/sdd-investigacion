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
pass=0; fail=0; skips=0
ok(){ printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
skip(){ printf '  SKIP  %s\n' "$1"; skips=$((skips+1)); }
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
  | sed 's/if \[ "\${_rev_obj_pstat\[0\]:-0}" -ne 0 \] || \[ "\${_rev_obj_pstat\[1\]:-0}" -ne 0 \]; then/if false; then/g' \
  | sed 's/if \[ "\$_cml_rc" -ne 0 \]/if false/g' \
  | sed 's/if \[ "\${_cmsg_rev_pstat\[0\]:-0}" -ne 0 \] || \[ "\${_cmsg_rev_pstat\[1\]:-0}" -ne 0 \]; then/if false; then/g' \
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

  # Teeth for test 35 (B3: rev-list enumeration rc ≥ 2 → DEGRADED).
  # Mutant-b3: neuter the PIPESTATUS check so rev-list failure is silently ignored.
  # M4: the check now uses _rev_obj_pstat[0] and [1] instead of _rev_obj_rc.
  # Test 35 must flip to FAIL (exit 0 instead of 3 — empty blob list, no scan, no DEGRADED).
  # Note: 0 blobs with _raw_lines=0 is NOT DEGRADED (empty repo), so the mutant must also
  # silence the N=0 check; we do that by patching both conditions to false.
  echo "-- teeth-b3: remove _rev_obj_pstat check — test 35 must go red (silent pass) --"
  mutant_b3="$TMP/scan-secrets.MUTANT-b3.sh"
  sed 's/if \[ "\${_rev_obj_pstat\[0\]:-0}" -ne 0 \] || \[ "\${_rev_obj_pstat\[1\]:-0}" -ne 0 \]; then/if false; then/g;
       s/if \[ "\$_total_blobs" -eq 0 \]/if false/g' \
    "$SUT" \
  | sed 's/if \[ "\${_cmsg_rev_pstat\[0\]:-0}" -ne 0 \] || \[ "\${_cmsg_rev_pstat\[1\]:-0}" -ne 0 \]; then/if false; then/g' \
    > "$mutant_b3"
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
  # M4 changed the command to span two lines with -c log.showSignature=false; use Python to match
  # the multi-line form reliably.
  echo "-- teeth: neuter git log — test 37 commit-message token must go red --"
  mutant_cmsg="$TMP/scan-secrets.MUTANT-cmsg.sh"
  python3 - "$SUT" "$mutant_cmsg" << 'PYCMSG37'
import sys
lines = open(sys.argv[1]).readlines()
# Replace the rev-list|cat-file --batch commit-message scan pipeline and its PIPESTATUS guard
# with a no-op: _cmsg_tmp stays as an empty mktemp file, _cmsg_rev_pstat=(0 0) so no DEGRADED.
# M5: the block spans 9 lines starting with the git rev-list line that is followed by
# > "$_cmsg_tmp" two lines later and _cmsg_rev_pstat= one line after that.
out = []
i = 0
replaced = False
while i < len(lines):
    if (not replaced
            and '  git --no-replace-objects -C "$target" rev-list HEAD 2>/dev/null \\' in lines[i]
            and i + 2 < len(lines) and '> "$_cmsg_tmp"' in lines[i + 2]
            and i + 3 < len(lines) and '_cmsg_rev_pstat' in lines[i + 3]):
        # Skip 9 lines: pipeline (3) + _cmsg_rev_pstat= (1) + # B3 comment (1) + if...fi (4)
        out.append('  : # neutered-catfile\n')
        out.append('  _cmsg_rev_pstat=(0 0)\n')
        i += 9
        replaced = True
    else:
        out.append(lines[i])
        i += 1
if not replaced:
    import sys as _sys; print("WARN: cmsg37 catfile block not found in SUT", file=_sys.stderr)
open(sys.argv[2], 'w').write(''.join(out))
PYCMSG37
  cm_rc37m="$(bash "$mutant_cmsg" --committed "$d_t37" >/dev/null 2>&1; echo $?)"
  [ "$cm_rc37m" != 1 ] && ok "teeth-cmsg37: log-neutered mutant misses commit-message token (rc=$cm_rc37m) → test 37 has teeth" \
    || no "teeth-cmsg37: mutant still caught commit-message token (rc=$cm_rc37m) — test 37 is THEATER"

  # Teeth for test 38 (MAJOR2 -a flag): change -naE back to -nIE so binary files are skipped.
  # B6 rescan is also neutered — otherwise the NUL-stripped copy catches the token despite -nIE.
  # Together these prove the main scan path (not B6) is what T38 exercises.
  echo "-- teeth: change -naE to -nIE + neuter B6 rescan — test 38 NUL-byte file must go red --"
  mutant_noflag="$TMP/scan-secrets.MUTANT-noflag.sh"
  python3 - "$SUT" "$mutant_noflag" << 'PYNOFLAG38'
import sys, re
content = open(sys.argv[1]).read()
# 1. Change main HC grep flag from -naE to -nIE (skips binary files)
content = content.replace('-naE', '-nIE')
# 2. Neuter B6 unconditional NUL-stripped rescan: replace the NUL-stripped grep with 'true'
#    (after -naE→-nIE the NUL-stripped copy has no NULs, so -nIE treats it as text and still
#    finds the token; must replace the grep itself to prove the main-scan path drives T38).
content = re.sub(
    r'    grep -nIE \\\n(      -e [^\n]+\n)+      "\$_nul_tmp" 2>/dev/null \\',
    r'    true 2>/dev/null \\',
    content
)
open(sys.argv[2], 'w').write(content)
PYNOFLAG38
  cm_rc38m="$(bash "$mutant_noflag" --committed "$d_t38" >/dev/null 2>&1; echo $?)"
  [ "$cm_rc38m" = 0 ] && ok "teeth-noflag38: -nIE+no-B6 mutant misses NUL-byte .md token (rc=0 = false clean) → test 38 has teeth" \
    || no "teeth-noflag38: mutant rc=$cm_rc38m (want 0=false clean) — test 38 is THEATER"

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
# Stub: intercept rev-list HEAD (the enumeration plumbing) and exit 1.
# With M4 the enumeration is: git rev-list HEAD | git diff-tree --stdin ...
# Making rev-list exit 1 sets PIPESTATUS[0]=1 → DEGRADED check fires.
printf '#!/bin/bash\ncase "$*" in\n  *"rev-list HEAD"*) exit 1 ;;\n  *) exec "%s" "$@" ;;\nesac\n' \
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

  # Teeth for T46 (B3 rev-list exit 1): restore old >=2 check on the PIPESTATUS checks so
  # rev-list exit-1 is treated as ok → scan proceeds silently → test 46 must go red.
  # M4: PIPESTATUS checks use _rev_obj_pstat[0] and [1]; neutering both to -ge 2 restores the
  # old fail-open behaviour where rc=1 from rev-list is silently ignored.
  echo "-- teeth-b3-46: restore >=2 on pstat[0] and pstat[1] — test 46 exit-1 must go red (silent pass) --"
  mutant_b3_46="$TMP/scan-secrets.MUTANT-b3-46.sh"
  sed 's/\[ "\${_rev_obj_pstat\[0\]:-0}" -ne 0 \]/[ "${_rev_obj_pstat[0]:-0}" -ge 2 ]/g;
       s/\[ "\${_rev_obj_pstat\[1\]:-0}" -ne 0 \]/[ "${_rev_obj_pstat[1]:-0}" -ge 2 ]/g;
       s/\[ "\${_cmsg_rev_pstat\[0\]:-0}" -ne 0 \]/[ "${_cmsg_rev_pstat[0]:-0}" -ge 2 ]/g;
       s/\[ "\${_cmsg_rev_pstat\[1\]:-0}" -ne 0 \]/[ "${_cmsg_rev_pstat[1]:-0}" -ge 2 ]/g' \
    "$SUT" > "$mutant_b3_46"
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
# Match the state-machine awk BEGIN (includes expect_path=0 since the A-fix).
content = content.replace(
    'BEGIN{RS="\\0"; sha=""; expect_path=0}',
    'BEGIN{sha=""; expect_path=0}'
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
if [ "$cm_rc57" = 3 ] && printf '%s' "$cm_out57" | grep -qi 'degraded'; then
  ok "57 .git/info/grafts non-empty → DEGRADED exit 3 (grafts may hide commits from scan)"
else
  no "57 grafts: rc=$cm_rc57 (want 3) — grafts not detected :: $(printf '%s' "$cm_out57" | head -2)"
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
if [ "$cm_rc58" = 3 ] && printf '%s' "$cm_out58" | grep -qi 'degraded'; then
  ok "58 M5: cat-file --batch rc=1 for commit scan → DEGRADED exit 3 (PIPESTATUS[1] ≠ 0)"
else
  no "58 cat-file --batch rc=1: rc=$cm_rc58 (want 3) :: $(printf '%s' "$cm_out58" | head -2)"
fi

# 59 — B: _cmsg_tmp mktemp fails on the 8th mktemp call → DEGRADED exit 3.
#      In --committed mode: mktemp calls are _rev_obj_tmp(1), _blobs_list(2), _hc_hits_tmp(3),
#      _adv_raw(4), _blob_tmp(5), _nul_tmp(6, B6 unconditional per blob), _adv_dedup(7),
#      _cmsg_tmp(8). The 8th is unchecked pre-fix (with 1 blob in the fixture).
#      Pre-fix: _cmsg_tmp="" → "> """ redirect fails with rc=1 → -ge 2 check misses it →
#      commit message scan silently empty → false clean exit 0 (secret in commit msg passes).
_count59="$TMP/r4-mktemp-count59"
printf '0\n' > "$_count59"
_stub59="$TMP/r4-stub-mk59"; mkdir -p "$_stub59"
cat > "$_stub59/mktemp" << MKTEMP59
#!/bin/bash
n=\$(cat "$_count59" 2>/dev/null); n=\$((n+1))
printf '%s\n' "\$n" > "$_count59"
[ "\$n" -ge 8 ] && exit 1
exec /usr/bin/mktemp "\$@"
MKTEMP59
chmod +x "$_stub59/mktemp"
for _b in git bash grep sed sort head wc tr awk rm cat dirname basename printf; do
  _bp="$(type -P "$_b" 2>/dev/null)"; [ -n "$_bp" ] && ln -sf "$_bp" "$_stub59/$_b" 2>/dev/null || true
done
d_t59="$TMP/r4-cmsg-mktemp"
mkdir -p "$d_t59"
git -C "$d_t59" init -q 2>/dev/null
git -C "$d_t59" config user.email "t@t" && git -C "$d_t59" config user.name "t"
printf '# clean\n' > "$d_t59/a.md"
git -C "$d_t59" add a.md && git -C "$d_t59" commit -q -m "debug: ghp_0123456789abcdefghijklmnopqrstuvwxyz" 2>/dev/null
printf '0\n' > "$_count59"   # reset counter before actual scan
cm_out59="$(PATH="$_stub59:$PATH" bash "$SUT" --committed "$d_t59" 2>&1)"
cm_rc59=$?
if [ "$cm_rc59" = 3 ] && printf '%s' "$cm_out59" | grep -qi 'degraded'; then
  ok "59 B: _cmsg_tmp mktemp fail (8th call) → DEGRADED exit 3 (unchecked mktemp fix)"
else
  no "59 _cmsg_tmp mktemp fail: rc=$cm_rc59 (want 3) :: $(printf '%s' "$cm_out59" | head -3)"
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
if ! git -C "$d_t60" cat-file commit HEAD | grep -q '^gpgsig'; then
  # Not a pass: emit a typed skip so the suite still surfaces the gap
  echo "  SKIP:60: SSH signing unavailable in this environment — commit has no gpgsig, showSignature path untested" >&2
  skip "60: SSH signing unavailable — showSignature path untested (see SKIP:60 above)"
else
  t60_out="$(GIT_CONFIG_GLOBAL="$_gcfg60" bash "$SUT" --committed "$d_t60" 2>&1)"
  t60_rc=$?
  if [ "$t60_rc" = 1 ] && printf '%s' "$t60_out" | grep -q 'LEAK'; then
    ok "60: log.showSignature=true does not cause plumbing enumeration to miss signed-commit blob (exit 1)"
  else
    no "60: log.showSignature=true scan: rc=$t60_rc (want 1) :: $(printf '%s' "$t60_out" | head -3)"
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
if [ "$t61_rc" = 1 ] && printf '%s' "$t61_out" | grep -q 'LEAK'; then
  ok "61: log.diffMerges=off does not hide evil-merge secret via plumbing enumeration (exit 1)"
else
  no "61: log.diffMerges=off scan: rc=$t61_rc (want 1) :: $(printf '%s' "$t61_out" | head -3)"
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
if [ "$t62_rc" = 1 ] && printf '%s' "$t62_out" | grep -q 'LEAK'; then
  ok "62: i18n.logOutputEncoding=UTF-16 does not hide token in commit message (raw cat-file scan)"
else
  no "62: logOutputEncoding=UTF-16: rc=$t62_rc (want 1) :: $(printf '%s' "$t62_out" | head -3)"
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
if [ "$t63_rc" = 1 ] && printf '%s' "$t63_out" | grep -q 'LEAK'; then
  ok "63: i18n.commitEncoding=UTF-16 does not hide token in commit message (raw cat-file scan)"
else
  no "63: commitEncoding=UTF-16: rc=$t63_rc (want 1) :: $(printf '%s' "$t63_out" | head -3)"
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
if [ "$t64_rc" = 1 ] && printf '%s' "$t64_out" | grep -q 'LEAK'; then
  ok "64: secret in author name detected via raw commit object scan (cat-file, closes #987 item 1)"
else
  no "64: author-name secret: rc=$t64_rc (want 1) :: $(printf '%s' "$t64_out" | head -3)"
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
if [ "$t65_rc" = 3 ] && printf '%s' "$t65_out" | grep -qi 'degraded'; then
  ok "65: GIT_GRAFT_FILE set → DEGRADED exit 3 (env overrides info/grafts check)"
else
  no "65: GIT_GRAFT_FILE: rc=$t65_rc (want 3) :: $(printf '%s' "$t65_out" | head -2)"
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

if [ "${1:-}" = "--prove-teeth" ]; then
  # Teeth for T53 (leading ':' path): insert an early-skip inside Rule 1 for records starting
  # with ':' — the old bug. ':notes.md' arrives at Rule 1 (expect_path=1), the colon check fires,
  # sha is cleared and expect_path reset to 0 → blob is never emitted → exit 0 (the real danger).
  # The mutant must give rc=0, not just rc≠1 — rc=3 (DEGRADED) would not prove the secret is missed.
  # Note: adding !/^:/ to Rule 1's condition would push ':notes.md' into Rule 2's fail-closed
  # validation, giving DEGRADED exit 3; instead we insert a skip INSIDE Rule 1 so it is consumed
  # there (silently) and never reaches the fail-closed path.
  echo "-- teeth-r4-53: colon-path early-skip in Rule 1 — :notes.md sha cleared → rc=0 --"
  mutant_t53="$TMP/scan-secrets.MUTANT-r4-53.sh"
  python3 - "$SUT" "$mutant_t53" << 'PYEOF53'
import sys
content = open(sys.argv[1]).read()
# Insert a colon-path early-exit INSIDE Rule 1 (before the path is processed).
# When ':notes.md' arrives with expect_path=1, the /^:/ check fires: sha is cleared, state reset,
# and `next` is called. The real blob sha is lost → blob not scanned → exit 0 (false clean).
# This does NOT add !/^:/ to Rule 1's condition — that would push ':notes.md' to Rule 2's
# fail-closed validator, giving DEGRADED (rc=3) instead of the intended silent pass (rc=0).
content = content.replace(
    'expect_path && length($0) > 0 {\n  expect_path = 0\n  if (sha == "") next',
    'expect_path && length($0) > 0 {\n  if ($0 ~ /^:/) { expect_path = 0; sha = ""; next }  # MUTANT: old colon-path skip bug\n  expect_path = 0\n  if (sha == "") next'
)
open(sys.argv[2], 'w').write(content)
PYEOF53
  _m53rc=$(bash "$mutant_t53" --committed "$d_t53" >/dev/null 2>&1; echo $?)
  [ "$_m53rc" = 0 ] \
    && ok "teeth-r4-53: colon-skip mutant silently misses :notes.md (rc=0 = false clean) → test 53 has teeth" \
    || no "teeth-r4-53: mutant did not pass silently (rc=$_m53rc, want 0) — check mutation"

  # Teeth for T56 (gitlink): restore old awk without 160000 skip → cat-file fails on submod sha → DEGRADED.
  echo "-- teeth-r4-56: remove gitlink skip — test 56 must go red (DEGRADED on cat-file) --"
  mutant_t56="$TMP/scan-secrets.MUTANT-r4-56.sh"
  python3 - "$SUT" "$mutant_t56" << 'PYEOF56'
import sys
content = open(sys.argv[1]).read()
# Remove the gitlink skip line: if ($2 == "160000") { sha = ""; expect_path = 1; next }
import re
content = re.sub(r'  if \(\$2 == "160000"\).*?next\s*\}.*?\n', '', content)
open(sys.argv[2], 'w').write(content)
PYEOF56
  _m56rc=$(bash "$mutant_t56" --committed "$d_t56" >/dev/null 2>&1; echo $?)
  [ "$_m56rc" != 1 ] && ok "teeth-r4-56: gitlink-skip-removed mutant DEGRADED on submod sha (rc=$_m56rc) → test 56 has teeth" \
    || no "teeth-r4-56: mutant still exited 1 on gitlink (rc=$_m56rc) — test 56 is THEATER"

  # Teeth for T57 (grafts): remove grafts check → DEGRADED no longer emitted → test 57 must go red.
  echo "-- teeth-r4-57: remove grafts check — test 57 must go red (no longer DEGRADED) --"
  mutant_t57="$TMP/scan-secrets.MUTANT-r4-57.sh"
  python3 - "$SUT" "$mutant_t57" << 'PYEOF57'
import sys, re
content = open(sys.argv[1]).read()
# Remove the grafts detection block
content = re.sub(
    r'  # Graft file check.*?fi\n',
    '',
    content,
    flags=re.DOTALL
)
open(sys.argv[2], 'w').write(content)
PYEOF57
  _m57out=$(bash "$mutant_t57" --committed "$d_t57" 2>&1)
  _m57rc=$?
  if [ "$_m57rc" != 3 ] && ! printf '%s' "$_m57out" | grep -qi 'degraded'; then
    ok "teeth-r4-57: grafts-check-removed mutant proceeds (rc=$_m57rc) → test 57 has teeth"
  else
    no "teeth-r4-57: mutant still DEGRADED (rc=$_m57rc) — test 57 is THEATER"
  fi

  # Teeth for T58 (git log rc=1): restore old -ge 2 check → rc=1 treated as ok → exit 0.
  echo "-- teeth-r4-58: remove _cmsg_rev_pstat PIPESTATUS check — test 58 cat-file rc=1 must go red --"
  mutant_t58="$TMP/scan-secrets.MUTANT-r4-58.sh"
  python3 - "$SUT" "$mutant_t58" << 'PYEOF58'
import sys, re
content = open(sys.argv[1]).read()
# Neuter the _cmsg_rev_pstat PIPESTATUS guard so cat-file failing silently produces an empty scan.
content = re.sub(
    r'  if \[ "\$\{_cmsg_rev_pstat\[0\]:-0\}" -ne 0 \] \|\| \[ "\$\{_cmsg_rev_pstat\[1\]:-0\}" -ne 0 \]; then\n.*?fi\n',
    '  if false; then\n    : # neutered cmsg_rev_pstat\n  fi\n',
    content,
    flags=re.DOTALL
)
open(sys.argv[2], 'w').write(content)
PYEOF58
  _m58out=$(PATH="$_stub_t58:$PATH" bash "$mutant_t58" --committed "$d_t58" 2>&1)
  _m58rc=$?
  if [ "$_m58rc" != 3 ] && ! printf '%s' "$_m58out" | grep -qi 'degraded'; then
    ok "teeth-r4-58: _cmsg_rev_pstat-removed mutant ignores cat-file rc=1 (rc=$_m58rc) → test 58 has teeth"
  else
    no "teeth-r4-58: mutant still DEGRADED (rc=$_m58rc) — test 58 is THEATER"
  fi

  # Teeth for T59 (unchecked _cmsg_tmp mktemp): remove the mktemp check for _cmsg_tmp AND
  # restore the old -ge 2 check AND remove the _cmsg_hits_tmp mktemp check.
  # With stub failing on call ≥ 8: call 8 (_cmsg_tmp) and call 9 (_cmsg_hits_tmp) both fail.
  # Without both guards removed, one of them still catches the failure → DEGRADED.
  echo "-- teeth-r4-59: remove _cmsg_tmp + _cmsg_hits_tmp checks + restore -ge 2 — test 59 must go red --"
  mutant_t59="$TMP/scan-secrets.MUTANT-r4-59.sh"
  python3 - "$SUT" "$mutant_t59" << 'PYEOF59'
import sys, re
content = open(sys.argv[1]).read()
# Remove the _cmsg_tmp mktemp check
content = re.sub(
    r'(_cmsg_tmp="\$\(mktemp\)") \|\| \{[^}]+\}',
    r'\1',
    content
)
# Remove the _cmsg_hits_tmp mktemp check (M4 addition; also fails on call 9 with the stub)
content = re.sub(
    r'(_cmsg_hits_tmp="\$\(mktemp\)") \|\| \{[^}]+rm[^}]+exit 3;\s*\}',
    r'\1',
    content
)
# Neuter the _cmsg_rev_pstat PIPESTATUS guard (M5 addition): with _cmsg_tmp="" the redirect to
# "" fails, making cat-file exit non-zero; without this guard that failure would be caught.
content = re.sub(
    r'  if \[ "\$\{_cmsg_rev_pstat\[0\]:-0\}" -ne 0 \] \|\| \[ "\$\{_cmsg_rev_pstat\[1\]:-0\}" -ne 0 \]; then\n.*?fi\n',
    '  if false; then\n    : # neutered cmsg_rev_pstat\n  fi\n',
    content,
    flags=re.DOTALL
)
# Neuter the cmsg grep rc check (M4 addition; also needs neutering)
content = content.replace(
    'if [ "$_cmsg_grep_rc" -ge 2 ]',
    'if false'
)
open(sys.argv[2], 'w').write(content)
PYEOF59
  printf '0\n' > "$_count59"
  _m59out=$(PATH="$_stub59:$PATH" bash "$mutant_t59" --committed "$d_t59" 2>&1)
  _m59rc=$?
  if [ "$_m59rc" != 3 ] && ! printf '%s' "$_m59out" | grep -qi 'degraded'; then
    ok "teeth-r4-59: _cmsg_tmp-check-removed mutant passes silently (rc=$_m59rc) → test 59 has teeth"
  else
    no "teeth-r4-59: mutant still DEGRADED (rc=$_m59rc) — test 59 is THEATER"
  fi

  # Teeth for T60 (log.showSignature): restore the exact round-4 porcelain git log --raw -m
  # enumeration; run against the real SSH-signed T60 fixture with log.showSignature=true.
  # With a real signed commit, git log injects the SSH verification line ("Good "git" signature…")
  # BEFORE the first NUL-delimited diff record. This non-header text trips fail-closed awk Rule 3
  # → DEGRADED (rc≠1 proves the scan breaks). If T60 was skipped (no gpgsig), skip teeth too.
  echo "-- teeth-r4-60: porcelain-log-with-m (round-4 exact) + showSignature — awk Rule 3 must fire --"
  if ! git -C "$d_t60" cat-file commit HEAD 2>/dev/null | grep -q '^gpgsig'; then
    echo "  SKIP:teeth-r4-60: T60 commit has no gpgsig; cannot prove showSignature teeth without a signed commit"
  else
    mutant_t60="$TMP/scan-secrets.MUTANT-r4-60.sh"
    python3 - "$SUT" "$mutant_t60" << 'PYEOF60'
import sys, re
content = open(sys.argv[1]).read()
# Restore porcelain git log --raw -m enumeration (exact round-4 command).
content = re.sub(
    r'  git --no-replace-objects -C "\$target" rev-list HEAD.*?_rev_obj_pstat=\(".*?"\)',
    '  git --no-replace-objects -C "$target" log \\\n'
    '    --format= --raw --no-abbrev --no-renames -m --root -z HEAD 2>/dev/null \\\n'
    '    > "$_rev_obj_tmp"\n'
    '  _rev_obj_pstat=($? 0)',
    content,
    flags=re.DOTALL
)
open(sys.argv[2], 'w').write(content)
PYEOF60
    _m60rc=$(GIT_CONFIG_GLOBAL="$_gcfg60" bash "$mutant_t60" --committed "$d_t60" >/dev/null 2>&1; echo $?)
    [ "$_m60rc" != 1 ] \
      && ok "teeth-r4-60: porcelain-log+showSignature mutant breaks (rc=$_m60rc≠1) → test 60 has teeth" \
      || no "teeth-r4-60: porcelain-log+showSignature mutant still found token (rc=1) — test 60 is THEATER"
  fi

  # Teeth for T61 (log.diffMerges=off): restore the exact round-4 porcelain git log --raw -m
  # enumeration; run with log.diffMerges=off in GIT_CONFIG_GLOBAL.
  # In git 2.55.0, log.diffMerges=off config overrides the explicit -m flag in git log porcelain
  # (unlike plumbing diff-tree which -m always controls independently of log.* config).
  # Result: merge commit diffs suppressed → evil-merge blob not enumerated → exit 0 (false clean).
  echo "-- teeth-r4-61: porcelain-log-with-m (round-4 exact) + diffMerges=off — must miss evil-merge --"
  mutant_t61="$TMP/scan-secrets.MUTANT-r4-61.sh"
  python3 - "$SUT" "$mutant_t61" << 'PYEOF61'
import sys, re
content = open(sys.argv[1]).read()
# Restore porcelain git log --raw -m enumeration (exact round-4 command with -m).
# log.diffMerges=off in GIT_CONFIG_GLOBAL overrides -m → merge diffs suppressed.
content = re.sub(
    r'  git --no-replace-objects -C "\$target" rev-list HEAD.*?_rev_obj_pstat=\(".*?"\)',
    '  git --no-replace-objects -C "$target" log \\\n'
    '    --format= --raw --no-abbrev --no-renames -m --root -z HEAD 2>/dev/null \\\n'
    '    > "$_rev_obj_tmp"\n'
    '  _rev_obj_pstat=($? 0)',
    content,
    flags=re.DOTALL
)
open(sys.argv[2], 'w').write(content)
PYEOF61
  _m61rc=$(GIT_CONFIG_GLOBAL="$_gcfg61" bash "$mutant_t61" --committed "$d_t61" >/dev/null 2>&1; echo $?)
  [ "$_m61rc" != 1 ] \
    && ok "teeth-r4-61: porcelain-log-with-m+diffMerges=off mutant misses evil-merge (rc=$_m61rc≠1) → test 61 has teeth" \
    || no "teeth-r4-61: porcelain-log-with-m mutant still found evil-merge (rc=1) — test 61 is THEATER"

  # Teeth for T62/T63/T64 (M5 raw commit object scan): restore the old git log --format=%s%n%b
  # commit-message scan. One shared mutant covers all three because all three exploit the same
  # gap: the old scan outputs text via git log (re-encoded or format-limited) while cat-file
  # returns raw stored bytes immune to encoding and including all commit-object fields.
  echo "-- teeth-m5-62/63/64: old git-log commit scan — logOutputEncoding/commitEncoding/author miss --"
  mutant_m5="$TMP/scan-secrets.MUTANT-m5.sh"
  python3 - "$SUT" "$mutant_m5" << 'PYEOF_M5'
import sys, re
content = open(sys.argv[1]).read()
# Replace the rev-list|cat-file --batch commit scan with the old git log --format=%s%n%b approach.
old_block = re.search(
    r'  git --no-replace-objects -C "\$target" rev-list HEAD 2>/dev/null \\\n'
    r'    \| git --no-replace-objects -C "\$target" cat-file --batch 2>/dev/null \\\n'
    r'    > "\$_cmsg_tmp"\n'
    r'  _cmsg_rev_pstat=\(".*?"\)\n'
    r'  # B3.*?\n'
    r'  if \[.*?\]; then\n'
    r'.*?fi\n',
    content,
    flags=re.DOTALL
)
if old_block:
    content = content[:old_block.start()] + (
        '  git --no-replace-objects -c log.showSignature=false -C "$target" \\\n'
        '      log --format="format:%s%n%b" HEAD > "$_cmsg_tmp" 2>/dev/null\n'
        '  _cml_rc=$?\n'
        '  if [ "$_cml_rc" -ne 0 ]; then\n'
        '    echo "DEGRADED: git log failed (rc=$_cml_rc) — commit message scan incomplete" >&2\n'
        '    rm -f "$_cmsg_tmp"; exit 3\n'
        '  fi\n'
    ) + content[old_block.end():]
else:
    import sys as _sys; print("WARN: m5 block not found in SUT", file=_sys.stderr)
open(sys.argv[2], 'w').write(content)
PYEOF_M5
  _m62rc=$(GIT_CONFIG_GLOBAL="$_gcfg62" bash "$mutant_m5" --committed "$d_t62" >/dev/null 2>&1; echo $?)
  [ "$_m62rc" = 0 ] \
    && ok "teeth-m5-62: old git-log mutant misses logOutputEncoding=UTF-16 token (rc=0 = false clean) → test 62 has teeth" \
    || no "teeth-m5-62: old git-log mutant rc=$_m62rc (want 0=false clean) — test 62 is THEATER"
  _m63rc=$(GIT_CONFIG_GLOBAL="$_gcfg63" bash "$mutant_m5" --committed "$d_t63" >/dev/null 2>&1; echo $?)
  [ "$_m63rc" = 0 ] \
    && ok "teeth-m5-63: old git-log mutant misses commitEncoding=UTF-16 token (rc=0 = false clean) → test 63 has teeth" \
    || no "teeth-m5-63: old git-log mutant rc=$_m63rc (want 0=false clean) — test 63 is THEATER"
  _m64rc=$(bash "$mutant_m5" --committed "$d_t64" >/dev/null 2>&1; echo $?)
  [ "$_m64rc" = 0 ] \
    && ok "teeth-m5-64: old git-log mutant misses secret in author name (rc=0 = false clean) → test 64 has teeth" \
    || no "teeth-m5-64: old git-log mutant rc=$_m64rc (want 0=false clean) — test 64 is THEATER"

  # Teeth for T65 (GIT_GRAFT_FILE): remove the GIT_GRAFT_FILE env check.
  # Without the check, the scan proceeds despite the env override → no DEGRADED.
  echo "-- teeth-r4-65: remove GIT_GRAFT_FILE check — test 65 must go red (no DEGRADED) --"
  mutant_t65="$TMP/scan-secrets.MUTANT-r4-65.sh"
  python3 - "$SUT" "$mutant_t65" << 'PYEOF65'
import sys, re
content = open(sys.argv[1]).read()
# Remove the GIT_GRAFT_FILE detection block
content = re.sub(
    r'  # M5: GIT_GRAFT_FILE env.*?fi\n',
    '',
    content,
    flags=re.DOTALL
)
open(sys.argv[2], 'w').write(content)
PYEOF65
  _m65out=$(GIT_GRAFT_FILE="$_graft65" bash "$mutant_t65" --committed "$d_t65" 2>&1)
  _m65rc=$?
  if [ "$_m65rc" != 3 ] && ! printf '%s' "$_m65out" | grep -qi 'degraded'; then
    ok "teeth-r4-65: GIT_GRAFT_FILE-check-removed mutant proceeds silently (rc=$_m65rc) → test 65 has teeth"
  else
    no "teeth-r4-65: mutant still DEGRADED (rc=$_m65rc) — test 65 is THEATER"
  fi

  # Teeth for T66-T68 (B6 NUL-stripped rescan): replace the NUL-stripped grep with 'true'
  # so it produces no output → token missed → rc=0 (false clean, the real danger).
  # The scan is now unconditional so the mutant targets the grep, not a gate.
  echo "-- teeth-b6: replace NUL-stripped grep with true — test 66 UTF-16LE must go red (rc=0) --"
  mutant_b6="$TMP/scan-secrets.MUTANT-b6.sh"
  python3 - "$SUT" "$mutant_b6" << 'PYEOF_B6'
import sys, re
content = open(sys.argv[1]).read()
# Replace the multi-line NUL-stripped HC grep (grep -naE ... "$_nul_tmp" 2>/dev/null \) with
# 'true 2>/dev/null \' so it produces no output — awk still runs on empty stdin, appending nothing.
content = re.sub(
    r'    grep -naE \\\n(      -e [^\n]+\n)+      "\$_nul_tmp" 2>/dev/null \\',
    r'    true 2>/dev/null \\',
    content
)
if '    true 2>/dev/null \\' not in content:
    print("WARN: B6 NUL-stripped grep not found in SUT", file=sys.stderr)
open(sys.argv[2], 'w').write(content)
PYEOF_B6
  _m66rc=$(bash "$mutant_b6" --committed "$d_t66" >/dev/null 2>&1; echo $?)
  [ "$_m66rc" = 0 ] \
    && ok "teeth-b6: NUL-stripped-grep-replaced-with-true mutant misses UTF-16LE token (rc=0) → test 66 has teeth" \
    || no "teeth-b6: mutant rc=$_m66rc (want 0=false clean) — test 66 is THEATER"
fi

[ "$skips" -gt 0 ] && echo "== $pass passed · $fail failed · $skips skipped ==" || echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ] || exit 1
