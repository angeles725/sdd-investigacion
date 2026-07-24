#!/usr/bin/env bash
# process-integrity.test.sh — Cross-slice invariant registry integrity check.
#
# What this checks (all offline, no network):
#   REQ-1  Registry Presence    — FAIL if registry missing or unparseable.
#   REQ-2  Well-Formedness      — every INV entry has id, statement, origin,
#                                  status, asserted-by; status ∈ {enforced,pending}.
#   REQ-3  Enforced Are Real    — every enforced entry names ≥1 test file that
#                                  exists AND every named test ID appears in that
#                                  file (design extension: ID-level verification,
#                                  not only file existence).
#   REQ-4  Pending Are Tracked  — bidirectional map consistency.
#   REQ-5  Promotion Discipline — offline portion covered by REQ-3; PR-level
#                                  obligation documented in invariants.md Rules.
#   REQ-6  Suite Integration    — auto-discovered by run-all.sh (this file).
#
# Usage:
#   bash process-integrity.test.sh
#
# Override registry path for CI or manual checks:
#   INVARIANTS_REGISTRY=/path/to/other.md bash process-integrity.test.sh
#
# STRICT TDD: RED fixture tests appear before the GREEN test; each RED fixture
# must be rejected with the expected error fragment; GREEN must pass.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
REGISTRY_PATH="${INVARIANTS_REGISTRY:-$REPO_ROOT/openspec/invariants.md}"

python3 - "$REGISTRY_PATH" "$REPO_ROOT" <<'PYEOF'
import re, sys, tempfile
from pathlib import Path

registry_path = Path(sys.argv[1])
repo_root     = Path(sys.argv[2])
tests_root    = repo_root / "research-sdd" / "toolbelt" / "tests"

passed = 0
failed = 0

def ok(n):
    global passed
    passed += 1
    print(f"  PASS  {n}")

def nok(n, r=""):
    global failed
    failed += 1
    print(f"  FAIL  {n}" + (f": {r}" if r else ""))


# ── What this check cannot see (acknowledged limits) ──────────────────────────
#   (a) Semantic assertion quality: whether a named test ACTUALLY asserts the
#       invariant is not verified here — delegated to registry Rules 5–6 and
#       human review at promotion time.
#   (b) Label matching is an approximation: the first colon/space-delimited
#       token of a double-quoted literal.  Strings not using that shape are
#       invisible.  .mjs test files are accepted for file existence only; their
#       IDs are not checked.
#   (c) Deleting the HIGHEST-numbered INV entry is not detected (no gap forms).

# ── Parse helpers ──────────────────────────────────────────────────────────────

FILE_RE     = re.compile(r'tests/[\w./-]+\.test\.(sh|mjs)')
BACKTICK_RE = re.compile(r'`([^`\n]+)`')
PAREN_RE    = re.compile(r'\(([^)]+)\)', re.DOTALL)


def is_test_id(s: str) -> bool:
    """Return True if s looks like a test-case label.

    Test IDs start with an uppercase letter and contain only letters, digits,
    hyphens, underscores, or slashes (slash separates paired IDs like RED6/RED7).
    Flags (--foo), paths (/tmp/...), backtick content with spaces, and descriptive
    fragments (complete-token) are excluded.
    """
    s = s.strip()
    if not s or not s[0].isupper():
        return False
    if ' ' in s or s.startswith('-') or s.startswith('/'):
        return False
    if any(c in s for c in '=[]{}().#@:'):
        return False
    if re.match(r'^INV-\d+$', s):          # invariant references are never test IDs
        return False
    return bool(re.match(r'^[A-Z][A-Za-z0-9_/-]*$', s))


def extract_ids_from_segment(text: str) -> list:
    """Return test-case IDs found in the text segment that follows a file reference.

    Looks in two places:
    1. Backtick-quoted tokens that match the test-ID pattern.
    2. First word of each semicolon/comma-separated part inside parentheses.

    Slash-separated IDs (e.g. RED6/RED7) are split into individual IDs.
    """
    ids: list = []

    for m in BACKTICK_RE.finditer(text):
        token = m.group(1).strip()
        if is_test_id(token):
            for sub in token.split('/'):
                sub = sub.strip()
                if sub and is_test_id(sub) and sub not in ids:
                    ids.append(sub)

    for m in PAREN_RE.finditer(text):
        for part in re.split(r'[;,]', m.group(1)):
            part = part.strip()
            if not part:
                continue
            words = part.split()
            if not words:
                continue
            first = words[0].rstrip('.,;:`').strip('`')
            if is_test_id(first):
                for sub in first.split('/'):
                    sub = sub.strip()
                    if sub and is_test_id(sub) and sub not in ids:
                        ids.append(sub)

    return ids


def extract_declared_labels(file_text: str) -> set:
    """Return test-case labels declared in a test file.

    Scans every double-quoted string literal in the file.  For each, the
    portion before the first ':' or ' ' is treated as a potential label.
    Slash-separated paired labels (e.g. RED2/GREEN) are split individually.
    Only tokens passing is_test_id() are included.

    This approach works for direct ok("LABEL: ...") / nok("LABEL", ...) calls
    and for helper-wrapped calls like assert_gate_error_msg(fn, "LABEL: ...", ...)
    and assert_passes(fn, "LABEL: ...").
    """
    labels: set = set()
    for m in re.finditer(r'"([^"\\\n]+)"', file_text):
        raw = m.group(1)
        first_part = re.split(r'[: ]', raw)[0].rstrip('.,;')
        for sub in first_part.split('/'):
            sub = sub.strip()
            if sub and is_test_id(sub):
                labels.add(sub)
    return labels


def parse_asserted_by(asserted_by_text: str) -> dict:
    """Return {relative_file_path: [test_id, ...]} from an Asserted-by field.

    For each tests/X.test.sh reference, collects test IDs from the text segment
    that follows it (up to the next file reference).  An empty ID list means only
    file existence is checked.  The same file may appear multiple times; IDs are
    merged across occurrences.
    """
    result: dict = {}
    file_matches = list(FILE_RE.finditer(asserted_by_text))
    for i, match in enumerate(file_matches):
        file_path = match.group(0)
        seg_start = match.end()
        seg_end   = file_matches[i + 1].start() if i + 1 < len(file_matches) \
                    else len(asserted_by_text)
        ids = extract_ids_from_segment(asserted_by_text[seg_start:seg_end])
        if file_path not in result:
            result[file_path] = []
        for tid in ids:
            if tid not in result[file_path]:
                result[file_path].append(tid)
    return result


def parse_entries(text: str):
    """Parse INV entries from registry text.

    Returns a list of dicts with keys id, statement, origin, status, asserted_by,
    or None when no INV entries are found (unparseable registry).
    """
    reg_start = text.find('## Registry')
    content   = text[reg_start:] if reg_start != -1 else text

    blocks  = re.split(r'\n(?=### INV-\d+)', content)
    entries = []

    for block in blocks:
        if not block.startswith('### INV-'):
            continue

        entry: dict = {}

        m = re.match(r'### (INV-\d+)', block)
        if not m:
            continue
        entry['id'] = m.group(1)

        ms = re.search(
            r'\*\*Statement:\*\*\s*(.*?)(?=\n-\s*\*\*[A-Z]|\Z)', block, re.DOTALL)
        entry['statement'] = ms.group(1).strip() if ms else ''

        mo = re.search(
            r'-\s*\*\*Origin:\*\*\s*(.*?)(?=\n-\s*\*\*[A-Z]|\Z)', block, re.DOTALL)
        entry['origin'] = mo.group(1).strip() if mo else ''

        mst = re.search(r'-\s*\*\*Status:\*\*\s*`([^`]*)`', block)
        entry['status'] = mst.group(1).strip() if mst else ''

        # Asserted by: capture until next top-level bullet or end of block.
        # This stops before additional bullets such as "- **Known gap:**".
        mab = re.search(
            r'-\s*\*\*Asserted by:\*\*\s*(.*?)(?=\n-\s*\*\*|\Z)', block, re.DOTALL)
        entry['asserted_by'] = mab.group(1).strip() if mab else ''

        entries.append(entry)

    return entries if entries else None


def parse_open_map(text: str) -> set:
    """Return the set of INV IDs that appear as structured rows in the Open map.

    Only table rows (| INV-N | ...) and list items (- INV-N ...) are counted as
    rows.  Prose mentions of invariant numbers (e.g. "established INV-6 above")
    are intentionally ignored.
    """
    sentinel = '## Open invariants map'
    start = text.find(sentinel)
    if start == -1:
        return set()
    ids: set = set()
    for line in text[start:].splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith('#'):
            continue
        if stripped.startswith('|'):
            cells = [c.strip() for c in stripped.split('|') if c.strip()]
            if cells and re.match(r'^INV-\d+$', cells[0]):
                ids.add(cells[0])
        elif stripped[0] in '-*+':
            m = re.match(r'^[-*+]\s+(INV-\d+)', stripped)
            if m:
                ids.add(m.group(1))
    return ids


# ── Core check function ────────────────────────────────────────────────────────

def check_registry(reg_path: Path, repo_root: Path) -> tuple:
    """Check registry at reg_path for structural integrity.

    Returns (ok: bool, errors: list[str]).
    """
    # REQ-1: Presence
    if not reg_path.exists():
        return False, [f"registry not found: {reg_path}"]
    try:
        text = reg_path.read_text(encoding='utf-8')
    except Exception as exc:
        return False, [f"cannot read registry: {exc}"]

    entries = parse_entries(text)
    if entries is None:
        return False, ["registry unparseable: no INV entries found"]

    errors: list = []

    # REQ-2: Well-Formedness (uniqueness, contiguity, fields, status)
    seen_ids: set = set()
    for entry in entries:
        eid = entry.get('id', '?')
        if eid in seen_ids:
            errors.append(f"duplicate invariant id: {eid}")
        seen_ids.add(eid)
    inv_nums = sorted(int(re.match(r'^INV-(\d+)$', e['id']).group(1))
                      for e in entries if re.match(r'^INV-(\d+)$', e.get('id', '')))
    if inv_nums:
        inv_set = set(inv_nums)
        for i in range(1, inv_nums[-1] + 1):
            if i not in inv_set:
                errors.append(f"non-contiguous INV sequence: INV-{i} missing")
    for entry in entries:
        eid = entry.get('id', '?')
        for field in ('statement', 'origin', 'status', 'asserted_by'):
            if not entry.get(field):
                errors.append(f"{eid}: missing required field '{field}'")
        st = entry.get('status', '')
        if st and st not in ('enforced', 'pending'):
            errors.append(f"{eid}: invalid status '{st}' (must be enforced or pending)")

    if errors:
        return False, errors

    # REQ-3: Enforced Invariants Are Real (+ design extension: ID-level check)
    for entry in entries:
        if entry['status'] != 'enforced':
            continue
        eid      = entry['id']
        file_ids = parse_asserted_by(entry['asserted_by'])
        if not file_ids:
            errors.append(f"{eid}: enforced but no test files named in 'Asserted by'")
            continue
        # F2: every .sh-backed entry must name ≥1 parseable test ID
        # (.mjs files: file existence accepted; label IDs not required there)
        sh_total_ids = sum(len(v) for rel, v in file_ids.items()
                           if not rel.endswith('.mjs'))
        all_mjs = all(rel.endswith('.mjs') for rel in file_ids)
        if not all_mjs and sh_total_ids == 0:
            errors.append(
                f"{eid}: enforced entry names no parseable test IDs"
                f" — add at least one real test label to 'Asserted by'")
        for rel_path, ids in file_ids.items():
            abs_path = repo_root / "research-sdd" / "toolbelt" / rel_path
            if not abs_path.exists():
                errors.append(f"{eid}: named test file not found: {rel_path}")
                continue
            if rel_path.endswith('.mjs'):
                continue  # .mjs: file existence accepted; label IDs not verified
            file_text = abs_path.read_text(encoding='utf-8')
            labels = extract_declared_labels(file_text)   # F4: label-aware check
            for tid in ids:
                if tid not in labels:
                    errors.append(
                        f"{eid}: test ID '{tid}' not found as a label in {rel_path}")

    # REQ-4: Pending Invariants Are Tracked (bidirectional)
    open_map    = parse_open_map(text)
    pending_ids = {e['id'] for e in entries if e['status'] == 'pending'}
    entry_map   = {e['id']: e for e in entries}

    for pid in pending_ids:
        if pid not in open_map:
            errors.append(f"{pid}: pending but absent from open-invariants map")

    for mid in open_map:
        if mid not in entry_map:
            errors.append(f"open-map references non-existent invariant: {mid}")
        elif entry_map[mid]['status'] != 'pending':
            errors.append(
                f"open-map references {mid} but its status is "
                f"'{entry_map[mid]['status']}' (must be pending)")

    if errors:
        return False, errors
    return True, []


# ── Test helpers ───────────────────────────────────────────────────────────────

def write_fixture(td: str, name: str, content: str) -> Path:
    p = Path(td) / name
    p.write_text(content, encoding='utf-8')
    return p


def assert_fails_with(label: str, reg_path: Path, fragment: str) -> None:
    ok_flag, msgs = check_registry(reg_path, repo_root)
    if ok_flag:
        nok(label, "check PASSED but expected FAIL")
        return
    combined = " | ".join(msgs)
    if fragment.lower() in combined.lower():
        ok(f"{label}: caught with expected message fragment '{fragment}'")
    else:
        nok(label,
            f"check failed but wrong message — expected '{fragment}' in: {combined!r}")


def assert_passes(label: str, reg_path: Path) -> None:
    ok_flag, msgs = check_registry(reg_path, repo_root)
    if ok_flag:
        ok(f"{label}: registry is valid — check PASSED")
    else:
        nok(label, "check FAILED unexpectedly: " + " | ".join(msgs))


# ── RED fixture tests ──────────────────────────────────────────────────────────
#
# Each fixture contains exactly ONE defect.  The check must reject it and the
# error message must contain the fragment listed in assert_fails_with().
# Written before GREEN so that a vacuous-pass bug is caught immediately.

with tempfile.TemporaryDirectory() as td:

    # RED01 — missing registry file
    missing = Path(td) / "no-such-registry.md"
    assert_fails_with("RED01-missing-file", missing, "not found")

    # RED02 — entry missing required field (no Status line)
    fix02 = write_fixture(td, "fix02.md", """\
## Registry

### INV-1 — test entry

**Statement:** Every entry must declare its enforcement status.

- **Origin:** fixture for missing-field test.
- **Asserted by:** `tests/gate.test.sh` (RED1).

## Open invariants map to open issues

No open invariants remain.
""")
    assert_fails_with("RED02-missing-field", fix02, "missing required field 'status'")

    # RED03 — invalid status value
    fix03 = write_fixture(td, "fix03.md", """\
## Registry

### INV-1 — test entry

**Statement:** Status must be enforced or pending, not an arbitrary string.

- **Origin:** fixture for invalid-status test.
- **Status:** `bogus`
- **Asserted by:** `tests/gate.test.sh` (RED1).

## Open invariants map to open issues

No open invariants remain.
""")
    assert_fails_with("RED03-invalid-status", fix03, "invalid status 'bogus'")

    # RED04 — enforced entry names a file that does not exist on disk
    fix04 = write_fixture(td, "fix04.md", """\
## Registry

### INV-1 — test entry

**Statement:** Every named test file must exist on disk.

- **Origin:** fixture for missing-test-file test.
- **Status:** `enforced`
- **Asserted by:** `tests/nonexistent-xyz-abc.test.sh` (RED1).

## Open invariants map to open issues

No open invariants remain.
""")
    assert_fails_with("RED04-missing-testfile", fix04, "nonexistent-xyz-abc.test.sh")

    # RED05 — enforced entry names a real file but a test ID that is absent from it
    # This is the design extension: file existence alone is not sufficient.
    fix05 = write_fixture(td, "fix05.md", """\
## Registry

### INV-1 — test entry

**Statement:** Named test IDs must appear as labels in the named test file.

- **Origin:** fixture for missing-test-id test (design extension).
- **Status:** `enforced`
- **Asserted by:** `tests/gate.test.sh` (RED-NONEXISTENT-9999).

## Open invariants map to open issues

No open invariants remain.
""")
    assert_fails_with("RED05-missing-testid", fix05, "RED-NONEXISTENT-9999")

    # RED06 — pending entry absent from open-invariants map
    fix06 = write_fixture(td, "fix06.md", """\
## Registry

### INV-1 — test entry

**Statement:** Pending invariants must be tracked in the open-invariants map.

- **Origin:** fixture for pending-not-in-map test.
- **Status:** `pending`
- **Asserted by:** none yet.

## Open invariants map to open issues

No open invariants remain.
""")
    assert_fails_with(
        "RED06-pending-not-in-map", fix06, "pending but absent from open-invariants map")

    # RED07 — open-map row references an enforced entry (not pending)
    fix07 = write_fixture(td, "fix07.md", """\
## Registry

### INV-1 — test entry

**Statement:** Open-map rows must reference only pending entries, not enforced ones.

- **Origin:** fixture for enforced-in-map test.
- **Status:** `enforced`
- **Asserted by:** `tests/qemu-exec.test.sh` (RED1).

## Open invariants map to open issues

| INV-1 | Issue #99 |
""")
    assert_fails_with("RED07-enforced-in-map", fix07, "open-map references INV-1")

    # RED08 — enforced entry names a test ID that exists in the file only as
    # a comment token, not as a real test label.  The old raw-substring check
    # accepted this; the label-aware check (F4) must reject it.
    # "Popen" appears in tests/detonate-exec.test.sh only inside # comments.
    fix08 = write_fixture(td, "fix08.md", """\
## Registry

### INV-1 — test entry

**Statement:** Named IDs must appear as declared test labels, not just in comments.

- **Origin:** fixture for prose-only test-id test (F4 regression guard).
- **Status:** `enforced`
- **Asserted by:** `tests/detonate-exec.test.sh` (Popen).

## Open invariants map to open issues

No open invariants remain.
""")
    assert_fails_with("RED08-prose-only-id", fix08, "Popen")

    # RED09 — enforced entry names test files but zero parseable test IDs.
    # gate.test.sh labels are all prose-style (lowercase first word), so none
    # pass is_test_id().  The F2 check must fire before the per-ID loop runs.
    fix09 = write_fixture(td, "fix09.md", """\
## Registry

### INV-1 — test entry

**Statement:** Enforced entries must name at least one parseable test label.

- **Origin:** fixture for no-parseable-ids test (F2 regression guard).
- **Status:** `enforced`
- **Asserted by:** `tests/gate.test.sh` — authorization contract tests.

## Open invariants map to open issues

No open invariants remain.
""")
    assert_fails_with("RED09-no-test-ids", fix09, "no parseable test IDs")

    # RED10 — registry exists but unparseable (no INV entries → empty file)
    fix10 = write_fixture(td, "fix10.md",
        "## Registry\n\n_No entries yet._\n\n## Open invariants map\n\nNone.\n")
    assert_fails_with("RED10-unparseable", fix10, "unparseable")

    # RED11 — enforced entry with no test files in Asserted-by (prose only)
    fix11 = write_fixture(td, "fix11.md", """\
## Registry

### INV-1 — test entry

**Statement:** Enforced invariants must name at least one test file.

- **Origin:** fixture for enforced-no-files test.
- **Status:** `enforced`
- **Asserted by:** Verified during code review; no automated test yet.

## Open invariants map

No open invariants remain.
""")
    assert_fails_with("RED11-no-test-files", fix11, "no test files named")

    # RED12 — open-map row references an invariant id absent from registry
    fix12 = write_fixture(td, "fix12.md", """\
## Registry

### INV-1 — test entry

**Statement:** Open-map rows must reference real registry entries.

- **Origin:** fixture for unknown-id-in-open-map test.
- **Status:** `enforced`
- **Asserted by:** `tests/gate.test.sh` (RED1).

## Open invariants map

| INV-99 | Issue #999 |
""")
    assert_fails_with("RED12-map-unknown-id", fix12, "non-existent invariant")

    # RED13-dup-id — two ### INV-1 entries → duplicate id error (P2-4)
    _blk = ("**Statement:** S.\n- **Origin:** f.\n"
            "- **Status:** `enforced`\n- **Asserted by:** `tests/gate.test.sh` (RED1).\n")
    fix13 = write_fixture(td, "fix13.md",
        "## Registry\n\n### INV-1 — a\n\n" + _blk
        + "\n### INV-1 — b\n\n" + _blk
        + "\n## Open invariants map\n\nNo open invariants remain.\n")
    assert_fails_with("RED13-dup-id", fix13, "duplicate invariant id")

    # RED14-gap — INV-1 and INV-3 present, INV-2 deleted → contiguity error (P2-5)
    fix14 = write_fixture(td, "fix14.md", """\
## Registry

### INV-1 — first

**Statement:** S1.
- **Origin:** f.
- **Status:** `enforced`
- **Asserted by:** `tests/gate.test.sh` (RED1).

### INV-3 — third

**Statement:** S3.
- **Origin:** f.
- **Status:** `enforced`
- **Asserted by:** `tests/gate.test.sh` (RED1).

## Open invariants map

No open invariants remain.
""")
    assert_fails_with("RED14-gap", fix14, "missing")

# Temp dir cleaned up; RED fixtures removed from disk.

# ── GREEN — real registry must pass ───────────────────────────────────────────

assert_passes("GREEN-real-registry", registry_path)

# ── Summary ───────────────────────────────────────────────────────────────────

print(f"\n== {passed} passed · {failed} failed ==")
sys.exit(0 if failed == 0 else 1)
PYEOF
