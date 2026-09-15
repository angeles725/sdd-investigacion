# `niagara-audit.v1`

`niagara-security-audit.sh <INSTALL_ROOT> --output <evidence.json>`
inspects a Niagara N4 install directory tree and emits per-check security
findings as a deterministic key-sorted JSON evidence envelope.

Uses only Python stdlib; no external tools, no network I/O, no subprocesses,
no writes to the install tree.  Read-only directory scan.

## Invocation

```bash
niagara-security-audit.sh /path/to/niagara_home --output audit.json
niagara-security-audit.sh /path/to/niagara_home --station config.bog --output audit.json
```

## Trust Boundary and Accepted Input

Any non-symlink directory that is a candidate Niagara N4 install root
(`niagara_home`).  Reads: `defaults/system.properties`, `security/`,
`security/licenses/`, `modules/*.jar` META-INF, and an optional
`--station <config.bog>`.

- **Symlink install root**: rejected; exit 2, no evidence emitted.
  Trailing path separators are stripped before the lstat guard, so
  `niagara_home/` with a trailing slash is rejected as well.
- **Absent or non-directory root**: exit 2, no evidence emitted.
- **Empty directory** (no Niagara files): exit 0, `status: complete`;
  checks run and produce MANUAL or NA — `checks_run > 0` proves the
  instrument looked.
- **Valid install root**: exit 0, `status: complete`; checks ran.

Intermediate directory symlinks (`defaults/`, `security/licenses/`,
`modules/`) that resolve outside the install root are skipped and never
followed — the doc claim "no symlink followed out of the install root"
is enforced by a realpath containment check before reading each subdir.
Regular-file symlinks inside the install tree are also silently skipped.

## Station Config (`--station <config.bog>`)

A real `config.bog` is a deflate-compressed ZIP archive containing
`file.xml`.  `--station` enables SEC-08, SEC-10, and SEC-12:

- **ZIP .bog**: `file.xml` is read with a length-bounded read (stops at
  32 MiB + 1 byte); if the actual decompressed size exceeds 32 MiB the
  entry is treated as truncated and SEC-08/10/12 return MANUAL.  The cap
  is enforced on the actual decompressed bytes, not on the ZIP header's
  declared `file_size` field (which is attacker-controlled and must not be
  trusted as a decompression bound).  Note: a ZIP bog with two `file.xml`
  entries is valid per the ZIP spec; the last-wins entry could carry
  `exec=true` while an earlier entry is benign — this is an existing
  limitation of single-pass `namelist()`/`open()` processing.
- **Plaintext .bog** (e.g. `platform.bog`): read directly as UTF-8 text
  and parsed with the same attribute regexes.
- **Binary / unrecognized format**: SEC-08/10/12 return MANUAL with a
  "format unrecognized" reason — never a false PASS or FAIL.
- **Provided but missing/unreadable**: MANUAL with a distinct
  "station file not found or not a regular file" observed string,
  distinguishable from the not-provided MANUAL.

Real N4 attribute names checked:

| Check | Attribute | Secure value |
|-------|-----------|--------------|
| SEC-08 | `allowProgramRuntimeExec` | absent or `false` |
| SEC-10 | `SyslogService`/`BSyslogSettings` `enabled` | `true` |
| SEC-12 | `reversibleEncodingKeySource` | any non-`none` value (e.g. `external`) |

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Complete — valid install root, all checks ran (FAIL findings may be present) |
| 1 | Walk error — root exists but an internal failure occurred (`status:failed` JSON emitted) |
| 2 | I/O error — absent, not-a-directory, or symlink root (no JSON emitted) |

## Evidence Schema (`niagara-audit.v1.json`)

| Field | Content |
|-------|---------|
| `schema` | `"niagara-audit.v1"` |
| `status` | `"complete"` or `"failed"` |
| `install_root` | Path supplied as `INSTALL_ROOT` argument |
| `checks` | Ordered list of check objects (see Check Object below) |
| `summary.checks_run` | Total number of check objects emitted |
| `summary.checks_pass` | Checks with `verdict: "PASS"` |
| `summary.checks_fail` | Checks with `verdict: "FAIL"` |
| `summary.checks_manual` | Checks with `verdict: "MANUAL"` (require live probe or external tooling) |
| `summary.checks_na` | Checks with `verdict: "NA"` (prerequisite absent, e.g. modules/ missing) |
| `errors` | Internal error strings; non-empty iff `status: failed` |
| `limitations` | Static disclaimer strings |

### Check Object

| Field | Content |
|-------|---------|
| `id` | Check identifier (SEC-01..SEC-16; SEC-13 not defined by source) |
| `severity` | `"crit"`, `"high"`, or `"med"` |
| `title` | Human-readable check name |
| `verdict` | `"PASS"`, `"FAIL"`, `"MANUAL"`, or `"NA"` |
| `observed` | Safe structural description of what was found — NEVER a secret value, key, or hash |
| `secure` | Expected secure baseline for comparison |
| `note` | Optional advisory or remediation hint |

### Check IDs and Coverage

| ID | Severity | Title | Automatable in install-audit |
|----|----------|-------|------------------------------|
| SEC-01 | crit | moduleVerificationMode | Yes (reads system.properties) |
| SEC-02 | crit | truststore.jks default password | Partial: presence only; password check is MANUAL (requires keytool) |
| SEC-03 | crit | security/ filesystem ACLs | MANUAL (requires icacls/OS tooling) |
| SEC-04 | crit | station TLS certificate | MANUAL (requires live port probe) |
| SEC-05 | high | commandLinePropertyBlacklist covers skip levers | Yes (reads system.properties) |
| SEC-06 | high | license attributes relaxing signature validation | Yes if `security/licenses/` present; NA if absent |
| SEC-07 | high | program.requireSigning | Yes (reads system.properties) |
| SEC-08 | high | allowProgramRuntimeExec | Yes with --station (ZIP inflated); MANUAL without |
| SEC-09 | high | platform daemon plaintext port 3011 | MANUAL (requires live port probe) |
| SEC-10 | high | syslog offload to external SIEM | Yes with --station (ZIP inflated); MANUAL without |
| SEC-11 | med | weak signing keys / FIPS | Partial: file presence only; key sizes MANUAL (requires keytool) |
| SEC-12 | med | config.bog at-rest encoding | Yes with --station (ZIP inflated); MANUAL without |
| SEC-14 | med | Fox/HTTP plaintext ports (1911/80) | MANUAL (requires live port probe) |
| SEC-15 | med | KeyRingPermission wildcard in unsigned module | Yes (reads modules/*.jar META-INF/module.xml) |
| SEC-16 | med | local data record integrity | Always FAIL (architectural limitation; no config knob) |

SEC-13 is not defined in the source corpus check set and is absent here.

## Anti-Silent-Zero (§7 Compliance)

Three states are always distinguishable:

| State | Exit | JSON | Indicator |
|-------|------|------|-----------|
| absent-or-not-dir | 2 | none | install root missing, not a directory, or a symlink |
| empty/no-niagara-files | 0 | `status: "complete"`, `checks_run > 0` | directory exists; file-based checks run but find no properties |
| valid install | 0 | `status: "complete"`, verdicts mixed PASS/FAIL/MANUAL | properties and/or modules found; checks ran |

`checks_run > 0` always holds for any valid directory input, proving the
instrument ran.  Individual checks return MANUAL or NA when their prerequisite
files are absent, distinguishing "not checked" from "checked and passed."

SEC-06 distinguishes absent `security/licenses/` (NA) from present-but-empty
(PASS) from present-with-relaxation-attributes (FAIL).

SEC-15 always includes a `scanned N of M JAR(s)` count in `observed`; when
`N < M` the string adds `(truncated)` — truncation is always visible.

## Secrets Discipline

The `observed` field in every check contains only safe structural descriptions:
property names, boolean values, file presence/absence indicators, and counts.
It NEVER contains actual passwords, private key material, certificate content,
or the raw text of sensitive configuration files.

## Caps and Truncation

| Cap | Value | Purpose |
|-----|-------|---------|
| `_MAX_PROPS_BYTES` | 512 KiB | system.properties read cap |
| `_MAX_BOG_BYTES` | 4 MiB | plaintext .bog read cap |
| `_MAX_BOG_INFLATE` | 32 MiB | ZIP file.xml decompression cap (bounded read) |
| `_MAX_JAR_SCAN` | 5000 | max JARs inspected for SEC-15 |
| `_MAX_LICENSE_SCAN` | 200 | max .license files for SEC-06 |
| `_MAX_MODULE_XML` | 64 KiB | per-JAR module.xml decompression cap (bounded read) |

`_MAX_BOG_INFLATE` and `_MAX_MODULE_XML` are enforced via length-bounded
reads (`f.read(CAP + 1)`), not via the ZIP header's `file_size` field.
The declared `file_size` is an attacker-controlled value and must not be
used as the decompression bound.  Files or JARs exceeding their caps are
skipped; SEC-15 always reports the actual scan count vs total JAR count,
so truncation is always visible.

## Non-Goals

- No live network probes (SEC-04, SEC-09, SEC-14 are always MANUAL).
- No subprocess calls (keytool, openssl, icacls).
- No modification of the install tree.
- SEC-13, SEC-17, SEC-18 are not defined by the source corpus check set.

## Output Layout

```
audit.json      # key-sorted JSON (this schema)
```

The output path must not already exist; symlinks and pre-existing files are
refused with exit 2 via `O_CREAT|O_EXCL|O_NOFOLLOW`.
