"""native-binary pack for lint_block.py (kit #1206/#1365): native-binary evidence floor.

  R9  a [CERT] / [CERT-hw] / [CERT-live] claim about a NATIVE binary (a *.dll / *.so / *.exe / *.dylib
      file name, or the words PE32 / ELF / Mach-O / "PE binary|file|image|header|section" /
      Authenticode) whose paragraph, list item or table row lacks any of: the binary's sha256 (64 hex),
      an address anchor (`0x` + 3 or more hex digits, or VA/RVA/offset followed by hex), and two
      distinct instruments from the allowlist below.

Trigger is per clause; the requirement is per UNIT because the sha256 / address / instruments of one
claim routinely sit in neighbouring sentences or cells. [CERT-doc] / [CERT-web] / [INFER] make no byte
claim and never trigger. `.sys` / `.ocx` are not native extensions here (`javax.baja.sys` is a Java
package). Vocabulary derived from the niagara5-research reference linter. Waive with
`<!-- lint-waive: R9 reason=... -->`. Loaded with `lint-block.sh --pack native-binary`.
"""
import re

R9_MARKER_RE = re.compile(r"\[CERT(?:-hw|-live)?\]")
R9_NATIVE_RE = re.compile(
    r"\b[\w.+-]+\.(?:dll|so(?:\.\d+)*|exe|dylib)\b(?![\w/-]|\.[A-Za-z])"
    r"|\bPE32\+?|\bELF(?:32|64)?\b|\bMach-O\b|\bPE\s+(?:binary|binaries|file|image|header|section)s?\b"
    r"|\bAuthenticode\b")
R9_SHA256_RE = re.compile(r"(?<![0-9A-Fa-f])[0-9A-Fa-f]{64}(?![0-9A-Fa-f])")
# The lookahead `(?=[0-9A-Fa-f]*\d)` requires at least one digit in the hex run after VA/RVA/offset:
# English words made only of hex letters ("offset decade", "VA faded") are not addresses.
R9_ANCHOR_RE = re.compile(
    r"\b0x[0-9A-Fa-f]{3,}\b|\b(?:VA|RVA|offset)\s*[:=]?\s*(?=[0-9A-Fa-f]*\d)[0-9A-Fa-f]{4,}\b")
# `nm` and `strings` are ordinary words/units: they count only inside a backtick code span.
# `r2` (radare2's CLI) counts only in exactly that lower-case spelling: matched case-insensitively it
# would collide with the rule id "R2" (waivers, cross-references) and count it as an instrument.
R9_INSTRUMENTS = {
    "readelf", "objdump", "r2", "radare2", "rabin2", "ghidra", "pefile", "pelib", "osslsigncode",
    "ilspycmd", "ilspy", "diec", "dumpbin", "otool", "ldd", "gdb", "lldb", "capstone", "xxd",
    "hexdump", "binwalk", "debug/pe", "debug/gosym", "debug/elf", "gosym",
}
R9_CODE_ONLY_INSTRUMENTS = {"nm", "strings"}
R9_INSTRUMENT_RE = re.compile(
    r"(?<![\w/])(" + "|".join(re.escape(n) for n in sorted(R9_INSTRUMENTS, key=len, reverse=True))
    + r")(?![\w])", re.IGNORECASE)
R9_CODE_SPAN_RE = re.compile(r"`([^`]*)`")


def instruments(text):
    found = set()
    for m in R9_INSTRUMENT_RE.finditer(text):
        name = m.group(1)
        if name == "R2":
            continue  # the rule id "R2", not radare2 (the regex is case-insensitive; only lower-case r2 counts)
        found.add(name.lower())
    for span in R9_CODE_SPAN_RE.findall(text):
        for name in R9_CODE_ONLY_INSTRUMENTS:
            if re.search(r"(?<![\w/-])" + name + r"(?![\w-])", span):
                found.add(name)
    return found


def build(api):
    def rule_r9(doc):
        out = []
        for u in doc.units:
            if u.kind not in api.CLAIM_KINDS:
                continue
            # Trigger: some clause pairs an evidence marker with native-binary context. The three
            # requirements below are then checked over the WHOLE unit (they sit in neighbouring clauses).
            makes_native_claim = any(R9_MARKER_RE.search(c) and R9_NATIVE_RE.search(c)
                                     for c in api.clauses(u.text))
            if not makes_native_claim:
                continue
            doc.cov["r9_triggers"] += 1
            if doc.waived("R9", u):
                continue
            missing = []
            if not R9_SHA256_RE.search(u.text):
                missing.append("no sha256 (64 hex) of the binary")
            if not R9_ANCHOR_RE.search(u.text):
                missing.append("no address anchor (0x... VA or file offset)")
            n = len(instruments(u.text))
            if n < 2:
                missing.append(f"{n} of 2 instruments named (allowlist R9_INSTRUMENTS)")
            if missing:
                out.append((u.line, "R9", f"native-binary claim: {'; '.join(missing)}: {api.excerpt(u.text)}"))
        return out
    return [("R9", rule_r9)]
