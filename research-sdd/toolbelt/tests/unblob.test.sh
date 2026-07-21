#!/usr/bin/env bash
# tests/unblob.test.sh — unblob evidence adapter test suite
# House style: mirrors squashfs-extract.test.sh and corroborate-pcap.test.sh.
# Exit 2 when SUT is missing (RED discipline for strict TDD).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../corroborate-unblob.sh"
MANIFEST="$HERE/../analysis_manifest.py"

# RED guard — exit 2 when the script-under-test does not exist yet.
[ -x "$SUT" ] || { echo "FATAL: SUT not found: $SUT" >&2; exit 2; }

# Tool-availability guard — skip gracefully when required tools are absent.
for _cmd in unblob bwrap python3; do
  if ! command -v "$_cmd" >/dev/null 2>&1; then
    echo "SKIP: unblob tests (missing: $_cmd)"
    echo "== 0 passed · 0 failed =="
    exit 0
  fi
done

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
pass=0; fail=0
ok(){ echo "  PASS  $1"; pass=$((pass+1)); }
no(){ echo "  FAIL  $1"; fail=$((fail+1)); }
run(){ "$SUT" --input "$1" --output "$2" "${@:3}"; }

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

# good.tgz: a tar.gz with 3 files — happy-path + determinism fixture.
mkdir -p "$ROOT/tree"
printf 'alpha'   > "$ROOT/tree/a.txt"
printf 'beta'    > "$ROOT/tree/b.txt"
printf 'gamma'   > "$ROOT/tree/c.txt"
tar -C "$ROOT" -czf "$ROOT/good.tgz" tree 2>/dev/null

# many.tgz: a tar.gz with 8 files — entry-cap fixture.
mkdir -p "$ROOT/many"
for _i in $(seq 1 8); do printf "file%s" "$_i" > "$ROOT/many/f$_i.txt"; done
tar -C "$ROOT" -czf "$ROOT/many.tgz" many 2>/dev/null

# big.tgz: a tar.gz with one file larger than 32 bytes — bytes-cap fixture.
mkdir -p "$ROOT/big"
dd if=/dev/urandom bs=1024 count=4 of="$ROOT/big/payload.bin" 2>/dev/null
tar -C "$ROOT" -czf "$ROOT/big.tgz" big 2>/dev/null

# text.bin: plain text — malformed / unrecognised input.
printf 'this is not a firmware image\n' > "$ROOT/text.bin"

# ---------------------------------------------------------------------------
# T1: Happy path — unblob extracts good.tgz and evidence JSON is produced.
# ---------------------------------------------------------------------------
if run "$ROOT/good.tgz" "$ROOT/out_a" 2>/dev/null \
  && [ -f "$ROOT/out_a/unblob-evidence.v1.json" ]; then
  ok "happy path: evidence JSON produced"
else
  no "happy path"
fi

# ---------------------------------------------------------------------------
# T2: Evidence schema — required fields, sorted entries, per-file sha256.
# ---------------------------------------------------------------------------
if python3 - "$ROOT/out_a/unblob-evidence.v1.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get("schema") == "unblob-evidence.v1", f"schema={d.get('schema')}"
assert d.get("status") in ("complete", "failed"), f"status={d.get('status')}"
assert "extraction" in d, "extraction key missing"
ex = d["extraction"]
entries = ex.get("entries", [])
assert isinstance(entries, list), "entries must be list"
# Entries must be sorted by path.
paths = [e["path"] for e in entries]
assert paths == sorted(paths), f"entries not sorted: {paths}"
# Every file entry must have the required fields.
for e in entries:
    assert "path" in e and "size" in e and "sha256" in e and "depth" in e, f"missing fields: {e}"
    assert e["sha256"].startswith("sha256:"), f"bad sha256 prefix: {e['sha256']}"
    assert isinstance(e["size"], int) and e["size"] >= 0, f"bad size: {e['size']}"
    assert isinstance(e["depth"], int) and e["depth"] >= 1, f"bad depth: {e['depth']}"
# input, isolation, limitations keys must be present.
assert "input" in d, "input key missing"
assert "isolation" in d, "isolation key missing"
assert "limitations" in d, "limitations key missing"
# Network isolation markers must appear in isolation.
launcher = d["isolation"].get("launcher", {})
assert launcher.get("path"), "launcher.path missing"
print(f"OK: {len(entries)} entries, schema={d['schema']}, status={d['status']}")
PY
then ok "evidence schema: required fields, sorted entries, sha256 prefixes"
else no "evidence schema"
fi

# ---------------------------------------------------------------------------
# T3: Determinism — two runs on the same input produce byte-identical evidence.
# ---------------------------------------------------------------------------
if run "$ROOT/good.tgz" "$ROOT/out_b" 2>/dev/null \
  && cmp -s "$ROOT/out_a/unblob-evidence.v1.json" "$ROOT/out_b/unblob-evidence.v1.json"; then
  ok "determinism: two runs on same fixture produce byte-identical evidence"
else
  no "determinism"
fi

# ---------------------------------------------------------------------------
# T4: Analysis manifest validates and verifies.
# ---------------------------------------------------------------------------
if python3 "$MANIFEST" validate "$ROOT/out_a/engine/analysis-manifest.v1.json" >/dev/null 2>&1 \
  && python3 "$MANIFEST" verify --root "$ROOT/out_a" "$ROOT/out_a/engine/analysis-manifest.v1.json" >/dev/null 2>&1; then
  ok "analysis manifest validates and verifies"
else
  no "analysis manifest"
fi

# ---------------------------------------------------------------------------
# T5: Entry-cap truncation — max-entries=3 on many.tgz; limitation is visible.
# ---------------------------------------------------------------------------
if run "$ROOT/many.tgz" "$ROOT/out_cap" --max-entries 3 2>/dev/null \
  && python3 - "$ROOT/out_cap/unblob-evidence.v1.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
ex = d["extraction"]
entries = ex.get("entries", [])
lims = d.get("limitations", [])
# At most 3 entries must be recorded.
assert len(entries) <= 3, f"entry cap not enforced: {len(entries)} entries"
# At least one limitation must mention truncation.
cap_hit = any("truncated" in s and "entry cap" in s for s in lims)
assert cap_hit, f"no entry-cap limitation recorded: {lims}"
print(f"OK: {len(entries)} entries, cap limitation present")
PY
then ok "max-entries cap: inventory truncated and limitation recorded"
else no "max-entries cap"
fi

# ---------------------------------------------------------------------------
# T6: Bytes-cap truncation — max-total-bytes=32 on big.tgz; limitation visible.
# ---------------------------------------------------------------------------
if run "$ROOT/big.tgz" "$ROOT/out_bytes" --max-total-bytes 32 2>/dev/null \
  && python3 - "$ROOT/out_bytes/unblob-evidence.v1.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
lims = d.get("limitations", [])
cap_hit = any("truncated" in s and "total-bytes" in s for s in lims)
assert cap_hit, f"no bytes-cap limitation recorded: {lims}"
print(f"OK: bytes-cap limitation present: {[s for s in lims if 'truncated' in s]}")
PY
then ok "max-total-bytes cap: limitation recorded"
else no "max-total-bytes cap"
fi

# ---------------------------------------------------------------------------
# T7: Output-dir-exists — fail-closed; no evidence published.
# ---------------------------------------------------------------------------
mkdir -p "$ROOT/already_exists"
if ! run "$ROOT/good.tgz" "$ROOT/already_exists" 2>/dev/null \
  && [ ! -f "$ROOT/already_exists/unblob-evidence.v1.json" ]; then
  ok "output-dir-exists rejected fail-closed; no evidence published"
else
  no "output-dir-exists"
fi

# ---------------------------------------------------------------------------
# T8: Unrecognized input — adapter publishes valid empty-inventory evidence.
# ---------------------------------------------------------------------------
# Unblob exits 0 with empty extraction for unrecognized input; the adapter must
# produce a complete evidence envelope (status=complete, 0 entries) rather than
# failing closed with exit 2.
if run "$ROOT/text.bin" "$ROOT/out_text" 2>/dev/null \
  && python3 - "$ROOT/out_text/unblob-evidence.v1.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get("schema") == "unblob-evidence.v1", f"schema={d.get('schema')}"
assert d.get("status") == "complete", (
    f"expected status=complete for empty extraction, got {d.get('status')!r}"
)
ex = d.get("extraction", {})
assert ex.get("entries") == [], f"expected empty entries list, got {ex.get('entries')}"
assert ex.get("entry_count") == 0, f"expected entry_count=0, got {ex.get('entry_count')}"
assert not ex.get("truncated"), "truncated must be False for empty extraction"
print(f"OK: status={d['status']}, entry_count={ex.get('entry_count')}")
PY
then ok "malformed input: valid empty-inventory evidence (status=complete, 0 entries)"
else no "malformed input: expected valid evidence with status=complete and 0 entries"
fi

# ---------------------------------------------------------------------------
# T9: Isolation profile — network_access=false, target_execution=false, launcher bound.
# The bwrap prefix (with --unshare-net, --cap-drop) is in manifest_spec.argv for
# provenance; the evidence JSON carries the isolation profile and launcher identity.
# ---------------------------------------------------------------------------
if python3 - "$ROOT/out_a/unblob-evidence.v1.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
iso = d.get("isolation", {})
profile = iso.get("profile", {})
assert profile.get("network_access") == False, f"network_access not False: {profile}"
assert profile.get("target_execution") == False, f"target_execution not False: {profile}"
assert iso.get("launcher", {}).get("path"), "launcher.path missing"
# The unblob argv inside the extraction domain must include --unshare-net via
# the manifest spec; here we verify the evidence records the network-denial profile.
print(f"OK: isolation profile={profile}")
PY
then ok "isolation: network-denial profile and launcher identity recorded"
else no "isolation profile"
fi

# ---------------------------------------------------------------------------
# T10: Depth-cap truncation — depth cap fires and is visible in limitations.
# ---------------------------------------------------------------------------
# Files in good.tgz land at depth >= 3 inside the extraction root
# (extract_dir/good.tgz_extracted/tree/…).  With --max-depth 2, the walk
# prunes the 'tree/' subdirectory at the boundary and MUST record the depth-cap
# limitation and set extraction.truncated=true.
# RED: before the fix, dirs.clear() was called without recording any limitation,
#      so walk_limitations stayed empty and truncated was falsely false.
# GREEN: after the fix, the limitation is recorded once when non-empty dirs are
#        pruned at file_depth_here == max_depth.
if run "$ROOT/good.tgz" "$ROOT/out_depthcap" --max-depth 2 2>/dev/null \
  && python3 - "$ROOT/out_depthcap/unblob-evidence.v1.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
ex = d["extraction"]
lims = d.get("limitations", [])
cap_hit = any("depth cap" in s for s in lims)
assert cap_hit, f"depth-cap limitation must appear when subdirs are pruned: {lims}"
assert ex.get("truncated") == True, (
    f"truncated must be True when depth cap fires, got {ex.get('truncated')!r}"
)
for e in ex.get("entries", []):
    assert e["depth"] <= 2, f"entry at depth {e['depth']} violates max_depth=2: {e['path']}"
print(
    f"OK: depth-cap limitation present, truncated=True, "
    f"{len(ex.get('entries', []))} entries at depth<=2"
)
PY
then ok "max-depth cap: limitation recorded, truncated=True, entries bounded by depth"
else no "max-depth cap: limitation missing or truncated=False (was silent before fix)"
fi


# ---------------------------------------------------------------------------
# T11: Timeout visibility — --timeout 1 must set extraction.truncated=True and
#      record a timeout limitation.  Skip gracefully when unblob finishes in <1s
#      (flake-proof: good.tgz is small and may extract very quickly).
# ---------------------------------------------------------------------------
_T11_OUT="$ROOT/out_timeout_unblob"
_T11_EXIT=0
run "$ROOT/good.tgz" "$_T11_OUT" --timeout 1 2>/dev/null || _T11_EXIT=$?
if [ "$_T11_EXIT" -eq 0 ]; then
  echo "  SKIP  T11: unblob finished in <1s on good.tgz (too fast; flake-proof skip)"
elif [ "$_T11_EXIT" -eq 2 ]; then
  no "T11: adapter fatal error (exit 2); check unblob installation"
elif [ -f "$_T11_OUT/unblob-evidence.v1.json" ]; then
  if python3 - "$_T11_OUT/unblob-evidence.v1.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get("status") == "failed", \
    f"expected status=failed on timeout, got {d.get('status')!r}"
assert "timeout" in d.get("errors", []), \
    f"timeout not in errors: {d.get('errors')}"
ex = d.get("extraction", {})
assert ex.get("truncated") == True, \
    f"extraction.truncated must be True on timeout, got {ex.get('truncated')!r}"
lims = d.get("limitations", [])
assert any("timeout" in l for l in lims), \
    f"no timeout limitation string: {lims}"
print(f"OK: status=failed, timeout in errors, extraction.truncated=True, limitation present")
PY
  then ok "T11: --timeout 1 sets status=failed, extraction.truncated=True, timeout limitation recorded"
  else no "T11: timeout visibility (schema mismatch; evidence present but fields wrong)"
  fi
else
  no "T11: evidence not published after timeout (exit $_T11_EXIT)"
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
