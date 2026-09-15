#!/usr/bin/env python3
"""Niagara N4 install-directory security-posture auditor.

Read-only directory scan; no subprocesses, no network I/O, no writes to input.
Inspects a niagara_home directory tree and reports per-check security findings
as key-sorted JSON evidence.

SECRETS DISCIPLINE: emits check IDs, verdicts, and safe structural descriptions
only.  Never emits property values that are credentials, key material, certificate
content, or password hashes.

Check IDs follow the source corpus check set (SEC-01..SEC-16; SEC-13 is not
defined by the source tool and is absent here).  Network-dependent checks
(SEC-04, SEC-09, SEC-14) and keystore-password checks (SEC-02 partial, SEC-11
partial) always return MANUAL in install-audit mode.

Exit codes:
  0  complete  -- valid install root, checks ran (findings may be present)
  1  walk error -- root exists but an internal failure occurred;
                   status:failed JSON emitted
  2  I/O error  -- absent, not-a-directory, or symlink root; no JSON emitted
"""
import argparse
import errno
import json
import os
import re
import stat as _stat
import sys
import zipfile

SCHEMA = "niagara-audit.v1"

# Caps to bound memory and execution time
_MAX_PROPS_BYTES   = 512 * 1024       # 512 KiB — system.properties cap
_MAX_BOG_BYTES     = 4 * 1024 * 1024  # 4 MiB   — plaintext .bog read cap
_MAX_BOG_INFLATE   = 32 * 1024 * 1024 # 32 MiB  — ZIP file.xml inflate cap
_MAX_JAR_SCAN      = 5000             # max JARs to inspect for SEC-15
_MAX_LICENSE_SCAN  = 200              # max .license files for SEC-06
_MAX_MODULE_XML    = 64 * 1024        # 64 KiB — per-JAR module.xml cap

_O_NOFOLLOW = getattr(os, 'O_NOFOLLOW', 0)
_O_CLOEXEC  = getattr(os, 'O_CLOEXEC', 0)


# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

def _check(cid, sev, title, verdict, observed, secure, note=""):
    """Build a check result dict (always key-sorted by JSON dump)."""
    return {
        "id": cid,
        "note": note,
        "observed": observed,
        "secure": secure,
        "severity": sev,
        "title": title,
        "verdict": verdict,
    }


def _write_json(path, data):
    """Write key-sorted JSON to path; refuse symlinks and pre-existing files."""
    content = (json.dumps(data, indent=2, sort_keys=True) + "\n").encode("utf-8")
    fd = os.open(
        str(path),
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | _O_NOFOLLOW | _O_CLOEXEC,
        0o600,
    )
    try:
        os.write(fd, content)
    finally:
        os.close(fd)


# ---------------------------------------------------------------------------
# Containment guard
# ---------------------------------------------------------------------------

def _inside_root(home, subpath):
    """Return True iff subpath resolves (via realpath) inside home.
    Used to prevent following intermediate directory symlinks out of the
    install root.  Never raises; returns False on any OS error.
    """
    try:
        real_home = os.path.realpath(home)
        real_sub  = os.path.realpath(subpath)
    except OSError:
        return False
    return real_sub == real_home or real_sub.startswith(real_home + os.sep)


# ---------------------------------------------------------------------------
# Property and file readers (all reject symlinks)
# ---------------------------------------------------------------------------

def _read_props(home):
    """Read system.properties from niagara_home.
    Returns dict: key -> (value_str, is_commented).
    Never raises; returns empty dict on any I/O failure.
    Rejects subdirectory symlinks that escape the install root.
    """
    props = {}
    for rel in ("defaults/system.properties", "system.properties"):
        p = os.path.join(home, rel)
        # Containment: if parent dir symlinks outside home, skip.
        parent = os.path.dirname(p)
        if parent != home and not _inside_root(home, parent):
            continue
        try:
            info = os.lstat(p)
        except OSError:
            continue
        if _stat.S_ISLNK(info.st_mode) or not _stat.S_ISREG(info.st_mode):
            continue
        if info.st_size > _MAX_PROPS_BYTES:
            continue
        try:
            with open(p, encoding="utf-8", errors="replace") as fh:
                for line in fh:
                    m = re.match(
                        r"\s*(#?)\s*(niagara\.[\w.]+|program\.[\w.]+)\s*=\s*(.*)", line
                    )
                    if m:
                        props[m.group(2)] = (m.group(3).strip(), m.group(1) == "#")
        except OSError:
            continue
        break  # first match wins; defaults/ takes priority
    return props


def _read_bog(path):
    """Decode a .bog station-config file for SEC-08/10/12 attribute parsing.

    Returns (xml_text, bog_format):
      bog_format  'zip'       — decompressed file.xml from a ZIP .bog
                  'plaintext' — read directly as UTF-8 text
                  'unknown'   — binary content; neither ZIP nor readable text
                  'error'     — file unreadable, symlink, or non-regular
                  'truncated' — ZIP file.xml exceeds _MAX_BOG_INFLATE cap

    Never raises.  Rejects symlinks and non-regular files.
    """
    try:
        info = os.lstat(path)
    except OSError:
        return ("", "error")
    if _stat.S_ISLNK(info.st_mode) or not _stat.S_ISREG(info.st_mode):
        return ("", "error")

    # Try ZIP (.bog stations are deflate-compressed ZIPs containing file.xml)
    try:
        if zipfile.is_zipfile(path):
            with zipfile.ZipFile(path, "r") as z:
                if "file.xml" not in z.namelist():
                    return ("", "unknown")
                # LENGTH-BOUNDED read: never trust the file_size header field.
                # A forged ZIP entry (tiny declared size, huge actual payload) could
                # cause unbounded decompression and OOM if z.read() were used directly.
                # f.read(CAP+1) stops decompression at CAP+1 bytes regardless of the
                # declared file_size; len > CAP then signals truncation.
                with z.open("file.xml") as f:
                    data = f.read(_MAX_BOG_INFLATE + 1)
                if len(data) > _MAX_BOG_INFLATE:
                    return ("", "truncated")
                xml = data.decode("utf-8", "replace")
                return (xml, "zip")
    except Exception:
        pass

    # Fallback: try plaintext read (platform.bog and older formats are plaintext)
    read_size = min(info.st_size, _MAX_BOG_BYTES)
    try:
        with open(path, "rb") as fh:
            raw = fh.read(read_size)
        # Reject obvious binary: null bytes in first 512 bytes indicate non-text
        if b"\x00" in raw[:512]:
            return ("", "unknown")
        text = raw.decode("utf-8", "replace")
        return (text, "plaintext")
    except OSError:
        return ("", "error")


def _scan_licenses(home):
    """Scan security/licenses/*.license for relaxation attributes.
    Returns:
      None  — directory absent, unreadable, or resolves outside install root
              (§7: distinguishes absent-input from empty-input)
      list  — (filename, attribute) pairs found (may be empty → PASS)
    """
    licdir = os.path.join(home, "security", "licenses")
    # Containment: reject symlinks pointing outside the install root
    if not _inside_root(home, licdir):
        return None
    hits = []
    try:
        entries = sorted(os.listdir(licdir))
    except OSError:
        return None  # absent/unreadable dir
    relax_attrs = ("skipModuleValidation", "smDeveloperMode", "unreleasedSoftware")
    for i, fname in enumerate(entries):
        if i >= _MAX_LICENSE_SCAN:
            break
        if not fname.endswith(".license"):
            continue
        fpath = os.path.join(licdir, fname)
        try:
            info = os.lstat(fpath)
        except OSError:
            continue
        if _stat.S_ISLNK(info.st_mode) or not _stat.S_ISREG(info.st_mode):
            continue
        try:
            text = open(fpath, encoding="utf-8", errors="replace").read(64 * 1024)
        except OSError:
            continue
        for attr in relax_attrs:
            if re.search(attr + r'\s*=\s*"?true', text) or (
                attr in text and "developer" in text
            ):
                hits.append((fname, attr))
    return hits


def _scan_keyring_perms(home):
    """Scan modules/*.jar META-INF/module.xml for KeyRingPermission.
    Returns (all_holders, wildcard_holders, wildcard_unsigned, jars_scanned, jars_total).
    Caps scan at _MAX_JAR_SCAN jars; skips symlinks and subdirs escaping home root.
    """
    moddir = os.path.join(home, "modules")
    # Containment: reject if modules/ symlinks outside home
    if not _inside_root(home, moddir):
        return [], [], [], 0, 0
    all_h, wild, wild_uns = [], [], []
    try:
        entries = sorted(os.listdir(moddir))
    except OSError:
        return all_h, wild, wild_uns, 0, 0
    jar_entries = [e for e in entries if e.endswith(".jar")]
    jars_total = len(jar_entries)
    count = 0
    for fname in jar_entries:
        if count >= _MAX_JAR_SCAN:
            break
        fpath = os.path.join(moddir, fname)
        try:
            info = os.lstat(fpath)
        except OSError:
            continue
        if _stat.S_ISLNK(info.st_mode):
            continue
        count += 1
        try:
            with zipfile.ZipFile(fpath) as z:
                names = z.namelist()
                if "META-INF/module.xml" not in names:
                    continue
                # LENGTH-BOUNDED read: same zip-bomb defence as _read_bog.
                # Untrusted modules/*.jar is an attacker-reachable path (SEC-15
                # audits modules that declare KeyRingPermission).  A forged entry
                # with a tiny declared file_size but a large compressed payload
                # could cause unbounded decompression; f.read(CAP+1) bounds it.
                with z.open("META-INF/module.xml") as f:
                    xml_data = f.read(_MAX_MODULE_XML + 1)
                if len(xml_data) > _MAX_MODULE_XML:
                    continue
                xml = xml_data.decode("utf-8", "replace")
        except Exception:
            continue
        if "KeyRingPermission" not in xml:
            continue
        all_h.append(fname)
        vals = re.findall(r'KeyRingPermission"[^>]*?(?:name|target)="([^"]*)"', xml)
        if "*" in vals:
            wild.append(fname)
            signed = any(
                n.startswith("META-INF/") and n.upper().endswith((".RSA", ".DSA", ".EC"))
                for n in names
            )
            if not signed:
                wild_uns.append(fname)
    return all_h, wild, wild_uns, count, jars_total


# ---------------------------------------------------------------------------
# Check runner
# ---------------------------------------------------------------------------

def run_audit(home, station_bog):
    """Run all checks against install root. Returns list of check dicts."""
    checks = []
    props = _read_props(home)

    # ------------------------------------------------------------------
    # Pre-compute station bog content (shared for SEC-08/10/12)
    # ------------------------------------------------------------------
    if station_bog is None:
        _bog_fmt = "not_provided"
        _bog_xml = ""
    elif not os.path.exists(station_bog) or not os.path.isfile(station_bog) \
            or os.path.islink(station_bog):
        _bog_fmt = "not_found"
        _bog_xml = ""
    else:
        _bog_xml, _bog_fmt = _read_bog(station_bog)

    def _bog_manual_observed(cid_hint=""):
        """Return MANUAL observed string based on bog format."""
        if _bog_fmt == "not_provided":
            return "not checked (no --station config.bog provided)"
        if _bog_fmt == "not_found":
            return "not checked (station file not found or not a regular file)"
        if _bog_fmt == "truncated":
            return "not checked (ZIP file.xml exceeds 32 MiB inflate cap)"
        if _bog_fmt in ("unknown",):
            return "not checked (station file format unrecognized: not a ZIP bog or plaintext)"
        if _bog_fmt in ("error",):
            return "not checked (station file could not be read)"
        return "not checked"

    # SEC-01 (crit) — moduleVerificationMode
    v, commented = props.get("niagara.moduleVerificationMode", (None, True))
    _sec01_fail = v is None or commented or v.lower() == "low"
    checks.append(_check(
        "SEC-01", "crit", "moduleVerificationMode",
        "FAIL" if _sec01_fail else "PASS",
        "(unset)" if v is None else ("(commented)" if commented else v),
        "high",
        "low allows an unsigned module requesting NETWORK_COMMUNICATION to load",
    ))

    # SEC-02 (crit) — truststore presence (password check requires keytool)
    ts_path = os.path.join(home, "security", "truststore.jks")
    try:
        ts_info = os.lstat(ts_path)
        ts_present = not _stat.S_ISLNK(ts_info.st_mode) and _stat.S_ISREG(ts_info.st_mode)
    except OSError:
        ts_present = False
    checks.append(_check(
        "SEC-02", "crit", "truststore.jks default password",
        "MANUAL",
        "present" if ts_present else "absent",
        "non-default store password",
        "password check requires keytool: keytool -list -keystore <path> -storepass changeit",
    ))

    # SEC-03 (crit) — security/ filesystem ACLs (platform-specific; MANUAL on Linux)
    secdir = os.path.join(home, "security")
    sec_present = os.path.isdir(secdir) and not os.path.islink(secdir)
    checks.append(_check(
        "SEC-03", "crit", "security/ filesystem ACLs",
        "MANUAL",
        "directory present" if sec_present else "directory absent",
        "Admin/SYSTEM only",
        "ACL check requires icacls.exe (Windows); verify with icacls <home>\\security",
    ))

    # SEC-04 (crit) — default TLS certificate (live probe; MANUAL in install-audit mode)
    checks.append(_check(
        "SEC-04", "crit", "station TLS certificate",
        "MANUAL",
        "not checked (requires live port probe)",
        "CA-issued certificate replacing the factory self-signed default",
        "use --host with the source tool for live TLS check on ports 443 and 5011",
    ))

    # SEC-05 (high) — commandLinePropertyBlacklist covers skip levers
    v, commented = props.get("niagara.commandLinePropertyBlacklist", (None, True))
    if not v or commented:
        sec05_covered = False
        sec05_observed = "disabled/absent"
    else:
        sec05_covered = "skipModuleValidation" in v and "ignoreVerificationMode" in v
        sec05_observed = "full" if sec05_covered else "partial (missing skip levers)"
    checks.append(_check(
        "SEC-05", "high", "commandLinePropertyBlacklist covers skip levers",
        "FAIL" if not sec05_covered else "PASS",
        sec05_observed,
        "includes skipModuleValidation + commissioning.ignoreVerificationMode",
        "-Dniagara.classLoader.skipModuleValidation can disable chain validation at launch",
    ))

    # SEC-06 (high) — license attributes relaxing signature validation
    # _scan_licenses returns None for absent/unreadable/escaping dir → NA
    lic_hits = _scan_licenses(home)
    if lic_hits is None:
        checks.append(_check(
            "SEC-06", "high", "license attributes relaxing signature validation",
            "NA",
            "security/licenses/ absent, unreadable, or outside install root",
            "no developer/unreleased/smDeveloper flags in any license",
            "",
        ))
    else:
        checks.append(_check(
            "SEC-06", "high", "license attributes relaxing signature validation",
            "FAIL" if lic_hits else "PASS",
            f"{len(lic_hits)} relaxation attribute(s) found" if lic_hits else "none found",
            "no developer/unreleased/smDeveloper flags in any license",
            "; ".join(f"{f}:{a}" for f, a in sorted(set(lic_hits))) if lic_hits else "",
        ))

    # SEC-07 (high) — program.requireSigning
    v, commented = props.get("program.requireSigning", (None, True))
    _sec07_bad = v is None or commented or v.lower() == "false"
    checks.append(_check(
        "SEC-07", "high", "program.requireSigning (BProgram bytecode)",
        "FAIL" if _sec07_bad else "PASS",
        "false/default" if _sec07_bad else v,
        "true",
        "superuser BProgram runs arbitrary bytecode unsigned when false or absent",
    ))

    # SEC-08 (high) — allowProgramRuntimeExec (requires --station .bog)
    if _bog_fmt in ("zip", "plaintext"):
        exec_on = bool(re.search(
            r'allowProgramRuntimeExec\s*=\s*["\']?true', _bog_xml, re.IGNORECASE
        ))
        checks.append(_check(
            "SEC-08", "high", "allowProgramRuntimeExec",
            "FAIL" if exec_on else "PASS",
            "true" if exec_on else "false/default",
            "false",
            "Runtime.exec() from BProgram is permitted when true",
        ))
    else:
        checks.append(_check(
            "SEC-08", "high", "allowProgramRuntimeExec",
            "MANUAL",
            _bog_manual_observed("SEC-08"),
            "false",
            "pass --station <config.bog> to enable this check",
        ))

    # SEC-09 (high) — platform daemon plaintext port 3011 (live probe; MANUAL)
    checks.append(_check(
        "SEC-09", "high", "platform daemon plaintext port 3011",
        "MANUAL",
        "not checked (requires live port probe)",
        "sslOnly=true (port 5011 only)",
        "use --host with the source tool for live port check",
    ))

    # SEC-10 (high) — syslog offload to external SIEM (requires --station .bog)
    if _bog_fmt in ("zip", "plaintext"):
        has_syslog = bool(re.search(
            r'(?:SyslogService|BSyslogSettings)', _bog_xml
        ))
        syslog_enabled = bool(re.search(
            r'enabled\s*=\s*["\']?true', _bog_xml, re.IGNORECASE
        ))
        sys_on = has_syslog and syslog_enabled
        checks.append(_check(
            "SEC-10", "high", "syslog offload to external SIEM",
            "FAIL" if not sys_on else "PASS",
            "enabled" if sys_on else "disabled/absent",
            "enabled with serverHost and TLS transport configured",
            "the only tamper-resistance for the local audit/history record",
        ))
    else:
        checks.append(_check(
            "SEC-10", "high", "syslog offload to external SIEM",
            "MANUAL",
            _bog_manual_observed("SEC-10"),
            "enabled with serverHost and TLS transport configured",
            "pass --station <config.bog> to enable this check",
        ))

    # SEC-11 (med) — weak signing keys / FIPS (file-presence only; full check needs keytool)
    fips_path = os.path.join(home, "jre", "lib", "security", "cacerts.bcfks")
    fips_present = os.path.isfile(fips_path) and not os.path.islink(fips_path)
    checks.append(_check(
        "SEC-11", "med", "weak signing keys / FIPS",
        "MANUAL",
        (
            f"truststore.jks: {'present' if ts_present else 'absent'}; "
            f"FIPS indicator (cacerts.bcfks): {'present' if fips_present else 'absent'}"
        ),
        "all keys >= 2048 bit; FIPS keystore (cacerts.bcfks) present",
        "key size check requires keytool; FIPS indicator: jre/lib/security/cacerts.bcfks",
    ))

    # SEC-12 (med) — config.bog at-rest encoding (requires --station .bog)
    # reversibleEncodingKeySource: "external" (or any non-none value) → PASS
    # absent or "none" → FAIL (passwords stored reversibly in the clear)
    if _bog_fmt in ("zip", "plaintext"):
        m = re.search(
            r'reversibleEncodingKeySource\s*=\s*["\']?(\w+)', _bog_xml, re.IGNORECASE
        )
        if m:
            val = m.group(1).lower()
            encoded = val not in ("none", "false", "0", "")
        else:
            encoded = False
        checks.append(_check(
            "SEC-12", "med", "config.bog at-rest encoding",
            "PASS" if encoded else "FAIL",
            "external/encoded" if encoded else "none (plaintext)",
            "reversibleEncodingKeySource set to external or equivalent",
            "reversibleEncodingKeySource=none leaves reversible passwords in the clear",
        ))
    else:
        checks.append(_check(
            "SEC-12", "med", "config.bog at-rest encoding",
            "MANUAL",
            _bog_manual_observed("SEC-12"),
            "reversibleEncodingKeySource set to external or equivalent",
            "pass --station <config.bog> to enable this check",
        ))

    # SEC-14 (med) — Fox/HTTP plaintext ports (live probe; MANUAL in install-audit mode)
    checks.append(_check(
        "SEC-14", "med", "Fox/HTTP plaintext ports (1911/80)",
        "MANUAL",
        "not checked (requires live port probe)",
        "TLS-only endpoints (4911/443)",
        "use --host with the source tool for live port check on 1911 and 80",
    ))

    # SEC-15 (med) — KeyRingPermission wildcard in unsigned module
    moddir = os.path.join(home, "modules")
    if os.path.isdir(moddir) and not os.path.islink(moddir):
        all_h, wild, wild_uns, jars_scanned, jars_total = _scan_keyring_perms(home)
        risk = len(wild_uns) > 0
        truncated = jars_scanned < jars_total
        scan_note = (
            f"scanned {jars_scanned} of {jars_total} JAR(s)"
            + (" (truncated)" if truncated else "")
        )
        checks.append(_check(
            "SEC-15", "med", "KeyRingPermission wildcard in unsigned module",
            "FAIL" if risk else "PASS",
            (
                f"{len(all_h)} module(s) declare KeyRingPermission; "
                f"{len(wild)} wildcard (name=*); "
                f"{len(wild_uns)} wildcard AND unsigned; "
                + scan_note
            ),
            "no wildcard KeyRingPermission in an unsigned module",
            (
                f"{len(wild_uns)} unsigned wildcard holder(s) detected"
                if risk else
                "all wildcard holders are signed (or no wildcard holders found)"
            ),
        ))
    else:
        checks.append(_check(
            "SEC-15", "med", "KeyRingPermission wildcard in unsigned module",
            "NA",
            "modules/ directory absent",
            "no wildcard KeyRingPermission in an unsigned module",
            "",
        ))

    # SEC-16 (med) — local data record integrity (architectural; always FAIL)
    checks.append(_check(
        "SEC-16", "med", "local data record integrity (audit/history/backup)",
        "FAIL",
        "unsigned by design (architectural limitation)",
        "syslog offload to external SIEM (see SEC-10) provides tamper-resistance",
        "Niagara signs code modules but not data records; no configuration toggle exists",
    ))

    return checks


# ---------------------------------------------------------------------------
# Main command
# ---------------------------------------------------------------------------

def cmd_audit(args):
    """Audit install root. Returns exit code."""
    home = args.install_root

    # Strip trailing path separator: os.lstat("link/") follows the link on POSIX.
    home = home.rstrip(os.sep) or os.sep

    # --- Input validation: reject absent, non-directory, and symlink roots ---
    try:
        lstat_result = os.lstat(home)
    except OSError:
        sys.stderr.write(
            f"niagara-security-audit: {home}: {os.strerror(errno.ENOENT)}\n"
        )
        return 2

    if _stat.S_ISLNK(lstat_result.st_mode):
        sys.stderr.write(
            f"niagara-security-audit: {home}: is a symbolic link (rejected)\n"
        )
        return 2

    # os.stat follows symlinks; after the S_ISLNK guard above this is safe.
    # Using stat (not lstat) ensures the S_ISDIR check is on the real target type
    # even if the symlink check is mutated away — making M1 detectable.
    stat_result = os.stat(home)
    if not _stat.S_ISDIR(stat_result.st_mode):
        sys.stderr.write(
            f"niagara-security-audit: {home}: not a directory\n"
        )
        return 2

    errors = []
    try:
        checks = run_audit(home, args.station)
    except Exception as exc:
        errors.append(str(exc))
        checks = []

    n_pass   = sum(1 for c in checks if c["verdict"] == "PASS")
    n_fail   = sum(1 for c in checks if c["verdict"] == "FAIL")
    n_manual = sum(1 for c in checks if c["verdict"] == "MANUAL")
    n_na     = sum(1 for c in checks if c["verdict"] == "NA")

    result = {
        "checks": checks,
        "errors": errors,
        "install_root": home,
        "limitations": [
            "Network-dependent checks (SEC-04, SEC-09, SEC-14) are always MANUAL.",
            "Keystore password and key-size checks (SEC-02 partial, SEC-11) require keytool.",
            "Filesystem ACL checks (SEC-03) require platform tooling (icacls on Windows).",
            "Station-config checks (SEC-08, SEC-10, SEC-12) require --station <config.bog>.",
            "SEC-13 is not defined by the source corpus check set.",
        ],
        "schema": SCHEMA,
        "status": "failed" if errors else "complete",
        "summary": {
            "checks_fail":   n_fail,
            "checks_manual": n_manual,
            "checks_na":     n_na,
            "checks_pass":   n_pass,
            "checks_run":    len(checks),
        },
    }

    try:
        _write_json(args.output, result)
    except OSError as exc:
        sys.stderr.write(f"niagara-security-audit: output error: {exc}\n")
        return 2

    return 1 if errors else 0


# ---------------------------------------------------------------------------
# Argument parser
# ---------------------------------------------------------------------------

def _build_parser():
    p = argparse.ArgumentParser(
        prog="niagara-security-audit",
        description=(
            "Read-only Niagara N4 install-directory security-posture auditor. "
            "No subprocesses, no network I/O, no writes to input."
        ),
    )
    p.add_argument(
        "install_root", metavar="INSTALL_ROOT",
        help="Niagara N4 install directory (niagara_home)",
    )
    p.add_argument(
        "--station", default=None, metavar="FILE",
        help="station config.bog for SEC-08/SEC-10/SEC-12 checks",
    )
    p.add_argument(
        "--output", required=True, metavar="JSON",
        help="output JSON evidence file (must not already exist)",
    )
    return p


def main():
    args = _build_parser().parse_args()
    sys.exit(cmd_audit(args))


if __name__ == "__main__":
    main()
