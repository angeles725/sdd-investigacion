#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../pcap-flows.sh"; MANIFEST="$HERE/../analysis_manifest.py"
[ -x "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }
if ! command -v tshark >/dev/null 2>&1 || ! command -v bwrap >/dev/null 2>&1; then
  echo "  SKIP  tshark or bwrap not in PATH — suite skipped (tool-missing)"
  echo "== 0 passed · 0 failed =="; exit 0
fi
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT; pass=0; fail=0
ok(){ echo "  PASS  $1"; pass=$((pass+1)); }; no(){ echo "  FAIL  $1"; fail=$((fail+1)); }
run(){ "$SUT" --input "$ROOT/fixture.pcap" --output "$1" "${@:2}"; }

# Mint a deterministic pcap with one TCP stream carrying payload "HELLO".
# Two packets: SYN (seq=1000) + PSH|ACK (seq=1001, data=b"HELLO").
# tshark dissects streams regardless of checksum validity, so we skip them.
python3 - "$ROOT/fixture.pcap" <<'PY'
import struct,sys
E=bytes(6)*2+b'\x08\x00'; S=bytes([192,168,1,1]); D=bytes([192,168,1,2])
def mk(ts,sp,dp,sq,ak,fl,data):
    t=struct.pack('>HHIIHHHH',sp,dp,sq,ak,(5<<12)|fl,65535,0,0)+data
    i=struct.pack('>BBHHHBBH4s4s',0x45,0,20+len(t),1,0x4000,64,6,0,S,D)
    f=E+i+t; return struct.pack('<IIII',ts,0,len(f),len(f))+f
H=struct.pack('<IHHiIII',0xa1b2c3d4,2,4,0,0,65535,1)
open(sys.argv[1],'wb').write(H+mk(1,4321,80,1000,0,0x002,b'')+mk(2,4321,80,1001,1001,0x018,b'HELLO'))
PY

# T1: determinism — two runs on the same fixture must be byte-identical
if run "$ROOT/a" && run "$ROOT/b" \
  && cmp -s "$ROOT/a/pcap-flows.v1.json" "$ROOT/b/pcap-flows.v1.json"; then
  ok "two runs on same fixture produce byte-identical evidence"
else no "determinism"; fi

# T2: evidence schema — conversations list and per-stream follow digest present
if python3 - "$ROOT/a/pcap-flows.v1.json" <<'PY'
import json,sys; d=json.load(open(sys.argv[1]))
assert d['schema']=='pcap-flows.v1' and d['status']=='complete', d['status']
c=d['conversations']['tcp']; assert c and 'endpoint_a' in c[0] and isinstance(c[0]['frames_total'],int)
f=d['tcp_stream_follows']; assert f and f[0]['payload_sha256'].startswith('sha256:') and isinstance(f[0]['payload_bytes'],int)
PY
then ok "evidence schema: conversations and stream follow digest fields present"
else no "evidence schema"; fi

# T3: analysis manifest — validate structure and verify artifact hashes
if python3 "$MANIFEST" validate "$ROOT/a/engine/analysis-manifest.v1.json" \
  && python3 "$MANIFEST" verify --root "$ROOT/a" "$ROOT/a/engine/analysis-manifest.v1.json"; then
  ok "analysis-manifest validates and all artifact hashes verify"
else no "manifest verification"; fi

# T4: network isolation — argv must contain bwrap markers
if python3 - "$ROOT/a/pcap-flows.v1.json" <<'PY'
import json,sys; d=json.load(open(sys.argv[1])); a=d['conversations']['argv']
assert '--unshare-net' in a and '--cap-drop' in a
PY
then ok "bwrap network-denial markers present in recorded conversations argv"
else no "isolation markers in argv"; fi

# T5: payload stored as sha256 digest (sha256:<64 hex chars>), not raw bytes
if python3 - "$ROOT/a/pcap-flows.v1.json" <<'PY'
import json,re,sys; d=json.load(open(sys.argv[1]))
p=re.compile(r'^sha256:[0-9a-f]{64}$')
assert all(p.match(f['payload_sha256']) for f in d['tcp_stream_follows'])
PY
then ok "per-stream payload stored as sha256 digest, not raw bytes"
else no "payload digest format"; fi

# T6: negative — non-pcap input rejected with clean error message
printf 'not a pcap file\n' > "$ROOT/garbage.txt"
if ! "$SUT" --input "$ROOT/garbage.txt" --output "$ROOT/garbage-out" 2>"$ROOT/err.txt" \
   && grep -q 'pcap-flows:.*not a pcap' "$ROOT/err.txt"; then
  ok "non-pcap input rejected with clean AdapterError message"
else no "non-pcap rejection"; fi

# ── Unit: directional count swap + payload_complete (T7-T10) ─────────────────
# RED: T7 fails before the endpoint-swap fix; T9/T10 fail before payload_complete fix.
# T8 is a triangulation control that verifies the no-swap path is already correct.
if python3 - "$HERE/../pcap_flows.py" <<'PY'
import sys, importlib.util
spec = importlib.util.spec_from_file_location("pcap_flows", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
# T7: left endpoint sorts greater → directional counts must be swapped with endpoints
SYNTH = "===\nTCP Conversations\n192.168.1.9:80 <-> 192.168.1.2:4321 5 1000 3 200 8 1200\n===\n"
c = m._parse_conversations(SYNTH, "tcp")[0]
assert c['endpoint_a'] == '192.168.1.2:4321', f"endpoint_a={c['endpoint_a']}"
assert c['frames_a2b'] == 5, f"frames_a2b={c['frames_a2b']} want 5 (was b2a before swap)"
assert c['bytes_a2b'] == 1000 and c['frames_b2a'] == 3 and c['bytes_b2a'] == 200
# T8: left endpoint already smaller → no swap, counts unchanged (triangulation)
SYNTH2 = "===\nTCP Conversations\n192.168.1.2:4321 <-> 192.168.1.9:80 5 1000 3 200 8 1200\n===\n"
c2 = m._parse_conversations(SYNTH2, "tcp")[0]
assert c2['frames_b2a'] == 5 and c2['frames_a2b'] == 3, f"no-swap: b2a={c2['frames_b2a']} a2b={c2['frames_a2b']}"
# T9: odd-length hex line → bytes.fromhex raises ValueError → payload_complete=False
SYNTH3 = "===\nNode 0: 127.0.0.1:1\nNode 1: 127.0.0.1:2\nabc\n===\n"
r = m._parse_follow(SYNTH3, 0)
assert 'payload_complete' in r, "payload_complete field missing from _parse_follow result"
assert r['payload_complete'] is False, f"expected False, got {r['payload_complete']}"
# T10: valid even-length hex → payload_complete=True (triangulation for T9)
SYNTH4 = "===\nNode 0: 127.0.0.1:1\nNode 1: 127.0.0.1:2\n48454c4c4f\n===\n"
r2 = m._parse_follow(SYNTH4, 0)
assert r2.get('payload_complete') is True, f"expected True, got {r2.get('payload_complete')}"
assert r2['client_bytes'] == 5, f"client_bytes={r2['client_bytes']} want 5"
PY
then ok "unit: directional count swap + payload_complete flag"
else no "unit: directional count swap or payload_complete (CRITICAL+WARNING)"; fi

# ── Integration: per-stream follow capped by --max-streams (T11) ─────────────
# RED: fails before MAX_STREAMS fix (--max-streams arg not recognized).
python3 - "$ROOT/multi.pcap" <<'PY'
import struct, sys
E=bytes(6)*2+b'\x08\x00'; S=bytes([192,168,1,1]); D=bytes([192,168,1,2])
def mk(ts,sp,dp,sq,ak,fl,d):
    t=struct.pack('>HHIIHHHH',sp,dp,sq,ak,(5<<12)|fl,65535,0,0)+d
    i=struct.pack('>BBHHHBBH4s4s',0x45,0,20+len(t),1,0x4000,64,6,0,S,D)
    f=E+i+t; return struct.pack('<IIII',ts,0,len(f),len(f))+f
H=struct.pack('<IHHiIII',0xa1b2c3d4,2,4,0,0,65535,1)
pkts=(mk(1,4321,80,1000,0,0x002,b'')+mk(2,4321,80,1001,1001,0x018,b'A')+
      mk(3,4322,80,2000,0,0x002,b'')+mk(4,4322,80,2001,2001,0x018,b'B')+
      mk(5,4323,80,3000,0,0x002,b'')+mk(6,4323,80,3001,3001,0x018,b'C'))
open(sys.argv[1],'wb').write(H+pkts)
PY
if "$SUT" --input "$ROOT/multi.pcap" --output "$ROOT/multi-out" --max-streams 2 \
  && python3 - "$ROOT/multi-out/pcap-flows.v1.json" <<'PY'
import json, sys; d=json.load(open(sys.argv[1]))
assert d.get('streams_truncated') is True, f"streams_truncated={d.get('streams_truncated')}"
assert d.get('streams_analyzed') == 2, f"streams_analyzed={d.get('streams_analyzed')}"
assert d.get('stream_count_total') == 3, f"stream_count_total={d.get('stream_count_total')}"
assert len(d['tcp_stream_follows']) == 2, f"follows={len(d['tcp_stream_follows'])}"
PY
then ok "--max-streams cap: streams_truncated=true + counts visible in evidence"
else no "--max-streams cap + streams_truncated evidence (CRITICAL DoS fix)"; fi

echo "== $pass passed · $fail failed =="; [ "$fail" -eq 0 ]
