"""Regenerates the serial-frame-analyze fixtures and golden documents from the frozen legacy script.

usage (from research-sdd/rsdd/internal/serial):  python3 -I testdata/gen_analyze.py

Documents of the cases in FULL are kept whole (<name>.json); every other case keeps only the sha256 of the bytes
(<name>.sha256), which keeps the repository small and still pins every byte.

Writes testdata/frames/*.log (the extra fixtures below; the seven original ones are kept as they are) and, for
every case in CASES, testdata/golden/<name>.{args,rc,stderr,json}: the arguments (with {TMP} standing for the
test's temporary directory), the legacy exit code, its stderr and the evidence document it wrote.
The Go tests (analyze_test.go) replay every case against the Go command and require the same bytes.
"""
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
PKG = os.path.dirname(HERE)
LEGACY = os.path.join(HERE, "legacy", "serial_frame_analyze.py")
F = "testdata/frames/"

EXTRA = {
    # two lengths with the same count: the first one seen is the most common
    "ties.log": "0.0 len=5 01 02 03 04 05\n0.1 len=3 0a 0b 0c\n0.2 len=3 0a 0b 0d\n0.3 len=5 01 02 03 04 06\n",
    # one position with 8 distinct values (sample_hex keeps 6), one constant, one with two values
    "variab.log": "".join(f"{i * 0.1:.1f} len=3 81 {v:02x} {i % 2:02x}\n" for i, v in enumerate([9, 3, 7, 1, 8, 2, 6, 4, 3, 9])),
    # errors mixed with valid frames: 3-digit token, zero padded token, len mismatch, junk, comment, blank
    "badhex.log": (
        "# header\n\n"
        "0.0 len=3 81 00 17\n"
        "0.1 len=3 81 1ff 17\n"
        "0.2 len=3 0081 000 0017\n"
        "0.3 len=4 81 00 17\n"
        "this is not a frame\n"
        "0.4 len=2 zz yy\n"
        "0.5 len=007 01 02 03 04 05 06 07\n"
        "0.6 len = 3 aa bb cc\n"
        "0.7 len=3  aa  bb  cc  \n"
        "0.8 len=99999999999999999999 01\n"
    ),
    # sixty-plus character junk line, repr quoting, a tab, a backslash
    "junk.log": "x" * 70 + "\nit's a \"quoted\" line\nit's only\ttab\\slash\n",
    # line endings and separators that str.splitlines() honours; line numbers count them all
    "endings.log": "0.0 len=1 aa\r0.1 len=1 bb\r\n0.2 len=1 cc\x0b0.3 len=1 dd\x0c0.4 len=1 ee\x1c0.5 len=1 ff\x1d\x1e0.6 len=1 00 # c 0.7 len=1 11\x85\n\n  ",
    "nofinalnl.log": "0.0 len=2 aa bb\n0.1 len=2 aa cc",
    # Unicode digits, whitespace and a stray tab around the length
    "unicode.log": "0.0 len=٣ aa bb cc\n0.1 len=٣ aa bb cc\n0.2　len=3 aa bb cc\n0.3 len=٠٠٣ aa bb cc\n0.4 len=3\taa bb cc\n0.5 len=1\x1faa\n",
    # a second len= after a first that does not match
    "second.log": "0.0 len=2 zz len=2 aa bb\n0.1 len=2 aa bb len=2\n",
}
# invalid UTF-8: a truncated 3-byte sequence, a lone continuation, an overlong lead, a surrogate
BINARY = {
    "invalid_utf8.log": b"0.0 len=2 aa bb\n\xe2\x82 bad \x80 x \xc0\xaf y \xed\xa0\x80 z \xf0\x90\x80 \xf4\x90\x80\x80 end\n0.1 len=2 aa bb\n",
    "nul.log": b"0.0 len=2 aa bb\n\x00\x00junk\n",
    "cr_only.log": b"0.0 len=1 aa\r0.1 len=1 bb\r",
}
# frames for diff: ties for the representative frame, types present on one side only
DIFF_A = "0.0 len=3 81 00 01\n0.1 len=3 81 00 02\n0.2 len=3 81 00 02\n0.3 len=4 90 01 02 03\n0.4 len=2 55 66\n"
DIFF_B = "0.0 len=3 81 00 09\n0.1 len=3 81 00 02\n0.2 len=3 81 00 09\n0.3 len=3 82 00 00\n0.4 len=2 55 66\n"
EXTRA["diff_a.log"] = DIFF_A
EXTRA["diff_b.log"] = DIFF_B
# two shared types of the same length told apart by the first byte, and a representative chosen among equals
EXTRA["hist.log"] = "0.0 len=5 01 02 03 04 05\n0.1 len=3 0a 0b 0c\n0.2 len=3 0a 0b 0d\n0.3 len=3 0a 0b 0e\n0.4 len=2 aa bb\n0.5 len=2 aa bc\n"
# the most frequent frame of a group is not the first one seen
EXTRA["diff_e.log"] = "0.0 len=3 81 00 01\n0.1 len=3 81 00 02\n0.2 len=3 81 00 02\n"
EXTRA["diff_f.log"] = "0.0 len=3 81 00 02\n"
EXTRA["diff_c.log"] = "0.0 len=3 81 00 01\n0.1 len=3 81 00 02\n0.2 len=3 20 05 06\n0.3 len=3 20 07 08\n0.4 len=2 aa bb\n"
EXTRA["diff_d.log"] = "0.0 len=3 20 05 09\n0.1 len=3 20 07 08\n0.2 len=3 81 00 02\n0.3 len=3 81 00 01\n0.4 len=2 aa cc\n"
# every checksum family once, with a mixed-in bad frame, a short frame and a skip-first checksum
def crc16_modbus(d):
    c = 0xFFFF
    for b in d:
        c ^= b
        for _ in range(8):
            c = (c >> 1) ^ 0xA001 if c & 1 else c >> 1
    return c
def frame(body, tail):
    return " ".join(f"{x:02x}" for x in body + tail)
lines = []
for i, body in enumerate([[0x10, 0x20], [0x11, 0x21], [0x12, 0x22]]):
    lines.append(f"{i}.0 len={len(body) + 1} {frame(body, [sum(body) & 0xFF])}")
for i, body in enumerate([[0x01, 0x02, 0x03], [0x04, 0x05, 0x06]]):
    c = crc16_modbus(body)
    lines.append(f"9.{i} len={len(body) + 2} {frame(body, [c & 0xFF, c >> 8])}")
lines.append("8.0 len=2 aa bb")
lines.append("8.1 len=5 01 02 03 04 05")
EXTRA["mixed_sums.log"] = "\n".join(lines) + "\n"
# skip-first sum8: the first byte is excluded from the body
EXTRA["skip_sum.log"] = "".join(f"{i}.0 len=4 ff {a:02x} {b:02x} {(a + b) & 0xFF:02x}\n" for i, (a, b) in enumerate([(1, 2), (3, 4), (5, 6)]))
EXTRA["onlyshort.log"] = "0.0 len=1 aa\n0.1 len=2 aa bb\n"

FULL = {"stats_basic", "stats_empty", "stats_badhex", "diff_basic_basic_b", "checksum_mixed_sums", "checksum_crc-modbus", "stats_malformed"}
CASES = {}
def case(name, *args):
    CASES[name] = list(args)

for log in ["hist", "basic", "empty", "malformed", "ties", "variab", "badhex", "junk", "endings", "nofinalnl", "unicode",
            "second", "invalid_utf8", "nul", "cr_only", "onlyshort"]:
    case(f"stats_{log}", "stats", "--input", F + log + ".log", "--output", "{TMP}/out.json")
for log in ["basic", "checksum", "crc-modbus", "crc-ccitt", "empty", "malformed", "badhex", "mixed_sums", "skip_sum",
            "onlyshort", "ties", "unicode", "invalid_utf8"]:
    case(f"checksum_{log}", "checksum", "--input", F + log + ".log", "--output", "{TMP}/out.json")
for a, b in [("basic", "basic_b"), ("basic", "basic"), ("diff_a", "diff_b"), ("diff_b", "diff_a"), ("diff_c", "diff_d"), ("diff_e", "diff_f"), ("diff_f", "diff_e"), ("diff_d", "diff_c"), ("empty", "empty"),
             ("empty", "basic"), ("basic", "empty"), ("malformed", "basic"), ("basic", "malformed"),
             ("badhex", "basic"), ("junk", "empty"), ("ties", "variab")]:
    case(f"diff_{a}_{b}", "diff", "--input-a", F + a + ".log", "--input-b", F + b + ".log", "--output", "{TMP}/out.json")
case("stats_absent", "stats", "--input", F + "no-such.log", "--output", "{TMP}/out.json")
case("diff_absent_a", "diff", "--input-a", F + "no-such.log", "--input-b", F + "basic.log", "--output", "{TMP}/out.json")
case("diff_absent_b", "diff", "--input-a", F + "basic.log", "--input-b", F + "no-such.log", "--output", "{TMP}/out.json")
case("stats_out_dir_missing", "stats", "--input", F + "basic.log", "--output", "{TMP}/no/such/dir/out.json")
case("checksum_out_dir_missing", "checksum", "--input", F + "basic.log", "--output", "{TMP}/no/such/dir/out.json")
case("diff_out_dir_missing", "diff", "--input-a", F + "basic.log", "--input-b", F + "basic.log", "--output", "{TMP}/no/such/dir/out.json")
case("stats_failed_out_dir_missing", "stats", "--input", F + "malformed.log", "--output", "{TMP}/no/such/dir/out.json")
case("stats_equals_form", "stats", "--input=" + F + "basic.log", "--output={TMP}/out.json")
case("stats_prefix_form", "stats", "--inp", F + "basic.log", "--out", "{TMP}/out.json")
case("diff_equals_form", "diff", "--input-a=" + F + "basic.log", "--input-b=" + F + "basic_b.log", "--output={TMP}/out.json")


def run(args, tmp):
    args = [a.replace("{TMP}", tmp) for a in args]
    p = subprocess.run([sys.executable, "-I", LEGACY] + args, cwd=PKG, capture_output=True)
    return p.returncode, p.stdout.decode(), p.stderr.decode()


def main():
    os.makedirs(os.path.join(HERE, "frames"), exist_ok=True)
    for name, text in EXTRA.items():
        with open(os.path.join(HERE, "frames", name), "w", encoding="utf-8", newline="") as f:
            f.write(text)
    for name, raw in BINARY.items():
        with open(os.path.join(HERE, "frames", name), "wb") as f:
            f.write(raw)
    gdir = os.path.join(HERE, "golden")
    shutil.rmtree(gdir, ignore_errors=True)
    os.makedirs(gdir)
    for name, args in CASES.items():
        tmp = tempfile.mkdtemp()
        try:
            rc, out, err = run(args, tmp)
            assert out == "", (name, out)
            with open(os.path.join(gdir, name + ".args"), "w") as f:
                json.dump(args, f)
            with open(os.path.join(gdir, name + ".rc"), "w") as f:
                f.write(f"{rc}\n")
            with open(os.path.join(gdir, name + ".stderr"), "w") as f:
                f.write(err.replace(tmp, "{TMP}"))
            produced = os.path.join(tmp, "out.json")
            if os.path.exists(produced):
                if name in FULL:
                    shutil.copy(produced, os.path.join(gdir, name + ".json"))
                else:
                    with open(produced, "rb") as f, open(os.path.join(gdir, name + ".sha256"), "w") as g:
                        g.write(hashlib.sha256(f.read()).hexdigest() + "\n")
        finally:
            shutil.rmtree(tmp)
    print(len(CASES), "cases")


main()
