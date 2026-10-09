#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; SUT="$HERE/../corroborate-pcap.sh"; MANIFEST="$HERE/../analysis_manifest.py"
TOOLBELT="$(dirname "$HERE")"; PYSUT="$TOOLBELT/corroborate_pcap.py"
# --prove-teeth child run: `--teeth-child <staged corroborate_pcap.py>` points the suite at a staged mutant
# tree. An argument, not an environment variable, so a caller's ambient env can never swap the SUT of a plain run.
if [ "${1:-}" = "--teeth-child" ]; then
  [ -f "${2:-}" ] || { echo "FATAL: --teeth-child needs an existing staged SUT file, got [${2:-}]" >&2; exit 2; }
  SUT="$(dirname "$2")/corroborate-pcap.sh"; PYSUT="$2"
  echo "TEETH-CHILD: SUT=$PYSUT"
fi
[ -x "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
if ! command -v tshark >/dev/null 2>&1 || ! command -v capinfos >/dev/null 2>&1; then
  echo "SKIP: tshark/capinfos not in PATH — suite skipped (tool-missing)"
  echo "== 0 passed · 0 failed =="; exit 0
fi
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT; pass=0; fail=0
ok(){ echo "  PASS  $1"; pass=$((pass+1)); }; no(){ echo "  FAIL  $1"; fail=$((fail+1)); }
run(){ "$SUT" --input "$ROOT/fixture.pcap" --output "$1" "${@:2}"; }

# Mint a deterministic 1-packet (Ethernet/ARP) pcap fixture
python3 - "$ROOT/fixture.pcap" <<'PY'
import struct, sys
hdr = struct.pack('<IHHiIII', 0xa1b2c3d4, 2, 4, 0, 0, 65535, 1)
eth = bytes(6) + bytes(6) + b'\x08\x06'
arp = struct.pack('>HHBBH', 1, 0x0800, 6, 4, 1) + bytes(6) + b'\xc0\xa8\x01\x01' + bytes(6) + b'\xc0\xa8\x01\x64'
pkt = eth + arp
pkt_hdr = struct.pack('<IIII', 1000000, 0, len(pkt), len(pkt))
open(sys.argv[1], 'wb').write(hdr + pkt_hdr + pkt)
PY

# T1: determinism — two runs on the same fixture must be byte-identical
if run "$ROOT/a" && run "$ROOT/b" \
  && cmp -s "$ROOT/a/pcap-evidence.v1.json" "$ROOT/b/pcap-evidence.v1.json"; then
  ok "two runs on same fixture produce byte-identical evidence"
else no "determinism"; fi

# T2: evidence schema — required fields and values
if python3 - "$ROOT/a/pcap-evidence.v1.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d['schema'] == 'pcap-evidence.v1' and d['status'] == 'complete'
s = d['capinfos']['summary']
assert s['packet_count'] == 1, f"packet_count={s['packet_count']}"
assert s['encapsulation'] == 'Ethernet', f"encapsulation={s['encapsulation']}"
assert isinstance(s['file_size_bytes'], int) and s['file_size_bytes'] > 0
assert isinstance(s['data_size_bytes'], int) and s['data_size_bytes'] > 0
assert isinstance(s['capture_duration_s'], float)
phs = d['protocol_hierarchy']['protocols']
names = [p['protocol'] for p in phs]
assert 'eth' in names, f"eth missing; got {names}"
assert all('level' in p and 'frames' in p and 'bytes' in p for p in phs)
PY
then ok "evidence schema: capinfos summary and protocol hierarchy fields present"
else no "evidence schema"; fi

# T3: analysis manifest — validate structure and verify artifact hashes
if python3 "$MANIFEST" validate "$ROOT/a/engine/analysis-manifest.v1.json" \
  && python3 "$MANIFEST" verify --root "$ROOT/a" "$ROOT/a/engine/analysis-manifest.v1.json"; then
  ok "analysis-manifest validates and all artifact hashes verify"
else no "manifest verification"; fi

# T4: network isolation — argv must contain bwrap markers
if python3 - "$ROOT/a/pcap-evidence.v1.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
argv = d['protocol_hierarchy']['argv']
assert '--unshare-net' in argv, f"--unshare-net missing from argv"
assert '--cap-drop' in argv, f"--cap-drop missing from argv"
PY
then ok "bwrap network-denial markers present in recorded protocol_hierarchy argv"
else no "isolation markers in argv"; fi

# T5: negative — non-pcap input must fail with a clean error message
printf 'not a pcap file\n' > "$ROOT/garbage.txt"
if ! "$SUT" --input "$ROOT/garbage.txt" --output "$ROOT/garbage-out" 2>"$ROOT/err.txt" \
   && grep -q 'corroborate-pcap:.*not a pcap' "$ROOT/err.txt"; then
  ok "non-pcap input is rejected with a clean AdapterError message"
else no "non-pcap rejection"; fi

# T6: negative — symlink input is rejected (identity() uses O_NOFOLLOW)
ln -s "$ROOT/fixture.pcap" "$ROOT/link.pcap"
if ! "$SUT" --input "$ROOT/link.pcap" --output "$ROOT/link-out" 2>/dev/null; then
  ok "symlink input is rejected by O_NOFOLLOW identity check"
else no "symlink input rejection"; fi

# T7: root refusal — geteuid()==0 rejected before any I/O, with 'root or set-id' in stderr
# RED: fails before refuse_privileged_execution() is added to corroborate_pcap (no guard, message absent).
if python3 - "$PYSUT" <<'PY'
import importlib.util, io, sys
from contextlib import redirect_stderr
spec = importlib.util.spec_from_file_location("corroborate_pcap", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.os.geteuid = lambda: 0
buf = io.StringIO()
with redirect_stderr(buf):
    result = m.main(['--input', 'x', '--output', 'y', '--manifest-cli', 'z'])
assert result == 2, f"expected exit 2 for root, got {result}"
msg = buf.getvalue()
assert "root or set-id" in msg, f"expected 'root or set-id' in stderr, got: {msg!r}"
PY
then ok "root execution (geteuid==0) refused before I/O — 'root or set-id' in stderr (fail-closed)"
else no "root refusal"; fi


# ---------------------------------------------------------------------------
# --prove-teeth: mutation controls (kit issue #2053). Each mutant is a staged copy of the REAL
# corroborate_pcap.py (wrapper, manifest CLI and lib/ staged beside it); the whole suite is re-run
# with `--teeth-child <staged py>` and the named case must FAIL for its own reason: the bite
# pattern is the case's FAIL label (or its assertion text), and any crash-class output
# (ImportError, SyntaxError, NameError, AttributeError, ...) disqualifies the mutant.
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "--prove-teeth" ]]; then
  echo "-- teeth: mutation controls (determinism, bwrap markers, symlink input, root refusal) --"
  # shellcheck source=lib/mutant.sh
  . "$HERE/lib/mutant.sh"
  mutant_bootstrap mutant_chain_or_count mutant_tooth mutant_crash_re || exit 2
  _MUT="$(mktemp -d)"; trap 'rm -rf "$ROOT" "$_MUT"' EXIT
  _builds_failed=0; _LIBEXPR=""
  _CRASH="$(mutant_crash_re imp)|SyntaxError|IndentationError|NameError|AttributeError|TypeError|KeyError|UnboundLocalError"
  # _tooth LABEL BITE_REGEX SED_EXPR... : sed-mutates corroborate_pcap.py; a non-empty _LIBEXPR also
  # mutates a private copy of lib/adapter_core.py with that expression.
  _tooth() {
    local label="$1" want="$2" d; shift 2
    d="$_MUT/${label%%:*}"; mkdir -p "$d"
    cp "$TOOLBELT/corroborate-pcap.sh" "$TOOLBELT/analysis_manifest.py" "$d/"
    if [ -n "$_LIBEXPR" ]; then
      mkdir -p "$d/lib"; cp "$TOOLBELT"/lib/*.py "$d/lib/"
      MUTANT_SYNTAX=none mutant_chain_or_count _builds_failed "$label (adapter_core)" "$TOOLBELT/lib/adapter_core.py" "$d/lib/adapter_core.py" "$_LIBEXPR" || return 1
    else
      ln -s "$TOOLBELT/lib" "$d/lib"
    fi
    MUTANT_SYNTAX=none mutant_chain_or_count _builds_failed "$label" "$TOOLBELT/corroborate_pcap.py" "$d/corroborate_pcap.py" "$@" || return 1
    mutant_tooth "$label: case goes RED with the mutant" 0 1 "$d/corroborate_pcap.py" --orig "$TOOLBELT/corroborate_pcap.py" \
      --bad-has "$want" --bad-lacks "$_CRASH" -- \
      bash "$HERE/corroborate-pcap.test.sh" --teeth-child @SUT@
  }
  _t() { if _tooth "$@"; then pass=$((pass+1)); else fail=$((fail+1)); fi; }
  _t "cp-nondeterministic: evidence gains a random nonce" "FAIL  determinism" \
    's/"capinfos": {"argv": capinfos_cmd,/"capinfos": {"nonce": os.urandom(8).hex(), "argv": capinfos_cmd,/'
  _t "cp-net-open: --unshare-net dropped from the sandbox argv" "FAIL  isolation markers in argv" \
    's/prefix = sandbox(bwrap, env)/prefix = [a for a in sandbox(bwrap, env) if a != "--unshare-net"]/'
  _LIBEXPR='s/ | getattr(os, "O_NOFOLLOW", 0)//'
  _t "cp-follow-symlink: O_NOFOLLOW removed from every open on the input path" "FAIL  symlink input rejection" \
    's/ | getattr(os, "O_NOFOLLOW", 0)//'
  _LIBEXPR=""
  _t "cp-root-guard: refuse_privileged_execution() removed from main()" "expected (exit 2 for root|'root or set-id' in stderr)" \
    's/^        refuse_privileged_execution()$/        pass/'
  rm -rf "$_MUT"
fi

echo "== $pass passed · $fail failed =="; [ "$fail" -eq 0 ]
