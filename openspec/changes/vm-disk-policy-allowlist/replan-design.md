# Replan design — vm-disk-policy-allowlist (issue #61 / finding F2)

Status: DESIGN ONLY. No source or test file was written by this pass.
Scope: correction of commit `62e3542` on branch `research-sdd/vm-disk-policy-allowlist`.
Register: English, neutral/professional.

---

## 1. VERDICT

**A bounded correction is sufficient. No larger re-scope and no new follow-up
issue is warranted.** This is non-blocking hardening.

Rationale: the three 4R defects share one root — "the surface was strengthened
cosmetically (flags added to `_REQUIRED`, an exemption added, a denylist added)
but the CHECK MECHANISMS stayed the same weak shapes: `set(argv)` membership and
`str.startswith`". That root is fixable with three localized mechanism swaps
inside `check_disk_policy`, each independently testable. The only genuine design
question — "is a real allowlist well-defined here?" — resolves cleanly to YES
(Section 2) because the qemu-inner flag surface the emitters produce is small,
closed, and enumerable (11 flags). Nothing here requires new modules, new data
flow, or cross-file redesign. The reincidence was a *test-quality* failure, not
an architectural one: the previous rounds added rules whose tests asserted "some
GateError fired" rather than "THIS rule fired via its unique fragment, and a
mutation proves the assertion bites". The correction plan (Section 3) fixes the
mechanisms AND upgrades every touched rule's test to fragment-asserted +
mutation-proven, including mutation-by-relocation, which is the specific gap that
let defect 1 ship twice.

All three defects were reproduced empirically against the current
`lib/vm_disk_policy.py` before planning (harness run 2026-07-23):

- DEFECT 1 CONFIRMED: `--unshare-pid` / `--cap-drop ALL` / `--tmpfs` relocated
  from the bwrap prefix into the qemu-inner slice (after `--`) → plan PASSES.
  bwrap never receives the teeth, yet the required-flag set check is satisfied.
- DEFECT 2 CONFIRMED: `-mtdblock /path` appended → plan PASSES. The flag is not
  in the 10-entry `_BLOCK_DEVICE_FORBIDDEN` set, produces no `-drive`, and skips
  every per-drive check.
- DEFECT 3a CONFIRMED: a writable-persistent scratch renamed to
  `/input/scratch.img` → plan PASSES with `run_dir` set. The `startswith("/input/")`
  exemption suppresses the run_dir scope check that pre-#61 applied
  unconditionally. This is a REGRESSION.
- DEFECT 3b CONFIRMED: `-drive file=/input/../etc/shadow,...` → plan PASSES. The
  raw prefix check treats the traversal path as a sandbox-internal input.

---

## 2. ALLOWLIST DECISION

**Chosen: option (a) — a structural allowlist over the qemu-inner flag surface,
implemented as a "flag-shaped token" rule.** This subsumes and REPLACES the
`_BLOCK_DEVICE_FORBIDDEN` denylist entirely.

### 2.1 Justification against real emitter output

The full set of single-dash (qemu-inner) flags either emitter produces, verified
by inspecting `detonate_plan.build_plan` and `trace_plan.build_plan`:

| Flag | detonate | trace | value shape |
| --- | --- | --- | --- |
| `-kernel` | yes | yes | path (no leading `-`) |
| `-m` | yes | yes | `256` |
| `-smp` | yes | yes | `1` |
| `-accel` | yes | yes | `tcg` |
| `-nic` | yes | yes | `none` |
| `-nodefaults` | yes | yes | (boolean) |
| `-sandbox` | yes | yes | `on,...` |
| `-nographic` | yes | yes | (boolean) |
| `-no-reboot` | yes | yes | (boolean) |
| `-append` | no | yes | `init=/rsdd-agent rsdd.tracer=...` |
| `-drive` | yes | yes | `file=...` spec |

That is a **closed set of 11 flags**. Every legitimate qemu-inner flag begins
with `-`; every legitimate *value* token (`256`, `tcg`, `none`, `on,...`, the
kernel path, the `-append` string, the `-drive` spec) does **not** begin with
`-`. This property makes a true allowlist both well-defined and arity-free:

> **R-INNER-ALLOWLIST**: within the qemu-inner slice (tokens after the first
> `--`), every token that is flag-shaped (`tok.startswith("-")`) MUST be a member
> of `_QEMU_INNER_ALLOWED`. Any flag-shaped token not in the set → GateError.

Why option (a) beats the alternatives here:

- It delivers a *real, positive* property ("only these flags may appear"), which
  is exactly what the issue title ("move from denylist to allowlist") demands.
- It is arity-independent: we do not need to know how many values each flag
  consumes, because we only gate flag-shaped tokens and let value tokens pass.
  Block-device introducers — `-hda`, `-mtdblock`, `-blockdev`, `-pflash`, `-sd`,
  and every future one — are flag-shaped and absent from the set, so they are
  rejected *by construction*, closing defect 2's open-ended gap.
- It makes `_BLOCK_DEVICE_FORBIDDEN` dead weight. Enumerate-and-forbid is
  strictly weaker than enumerate-and-permit over the same closed surface, so the
  denylist is **removed**, not kept.

Rejected: option (b) (defensible denylist) — it cannot close the `-mtdblock`
class of gap without re-enumerating QEMU's entire block-device vocabulary, and it
keeps the misleading "allowlist" name over denylist mechanics. Rejected: option
(c) (hybrid) — redundant once (a) gates the whole inner flag surface; the
per-`-drive` spec checks (`format=raw`, readonly, snapshot, exactly-1-scratch,
R-REACH, R-SCOPE-ALL) already constrain *within* `-drive`, so a second denylist
layer adds no property.

### 2.2 Ordering within the inner slice

Specific diagnostics must win over the generic allowlist catch-all. Inner-slice
scan order:

1. `_FORBIDDEN` membership (`-netdev`, `-net`, `-enable-kvm`, …) → specific msg.
2. `-device` + denied-prefix value → specific msg.
3. `_VALUE_OK` predicate for inner flags (`-nic`, `-accel`, `-sandbox`, `-smp`).
4. `-drive` classification.
5. **R-INNER-ALLOWLIST catch-all**: flag-shaped and not in `_QEMU_INNER_ALLOWED`
   → generic reject. (A forbidden flag never reaches here; it fires at step 1.)

`_FORBIDDEN` is retained for message quality even though the allowlist would also
reject those flags — an operator seeing "forbidden network backend -netdev" is
better served than "unknown inner flag -netdev".

### 2.3 Residual risk (documented)

- A value token engineered to begin with `-` would be misclassified as a flag and
  rejected (false positive), not accepted — fail-closed, acceptable. No current
  emitter value is flag-shaped.
- The allowlist governs the *inner* slice only. Flag-shaped tokens in the bwrap
  prefix are already constrained by R-BWRAP-DENY plus bwrap's own strict argument
  parser (an unknown `-hda` before `--` makes bwrap itself error out before qemu
  is reached); a block device cannot reach QEMU through the prefix.

---

## 3. DEFECT 1 — teeth check must be slice-scoped (root mechanism fix)

Current: `present = set(argv)` and the `_VALUE_OK` loop both scan the FULL argv.
`bwrap_prefix` is computed (line ~174-175) but not used for the required check.

Fix: partition `_REQUIRED` and the value predicates by the slice each flag is
actually interpreted in, and check each against that slice.

- `_REQUIRED_BWRAP = {--unshare-net, --unshare-pid, --cap-drop, --tmpfs}` checked
  as a subset of `set(bwrap_prefix)`.
- The `--` separator is required by `"--" in argv` (its presence is what defines
  the two slices; keep as its own check).
- `_REQUIRED_INNER = {-nic, -accel, -smp, -nodefaults, -sandbox}` checked as a
  subset of `set(inner)` where `inner = argv[sep_idx+1:]`.
- `_VALUE_OK` split: `--cap-drop` predicate enforced while scanning `bwrap_prefix`;
  `-nic/-accel/-sandbox/-smp` predicates enforced while scanning `inner`.

A single `set(argv)` cannot express "this flag must be in THIS half", which is why
the fix is a partition, not a tweak.

---

## 4. DEFECT 3 — scope exemption must be path-safe and scratch must always scope

Current (line ~231-242): every drive path is scope-checked EXCEPT those matching
`dp.startswith(_SANDBOX_INPUT_PREFIX)`. Two holes: a writable scratch named
`/input/scratch.img` is exempted (regression), and `/input/../etc/shadow` is
treated as sandbox-internal.

Fix, two parts:

1. **The scratch path is ALWAYS run_dir-scoped**, unconditionally, before the
   loop — restoring pre-#61 behaviour. The exemption may never apply to
   `scratch_drive_path`.
2. **The exemption is segment-based and restricted to the two known read-only
   DESTs.** Replace `startswith` with: normalize via `posixpath.normpath(dp)`,
   then admit the exemption only when the normalized path is exactly one of
   `{_SAMPLE_GUEST_PATH, _ROOTFS_GUEST_PATH}` (i.e. `/input/sample`,
   `/input/rootfs`). `normpath("/input/../etc/shadow") == "/etc/shadow"`, which is
   not in the set, so it falls through to the run_dir scope check and is rejected.
   A future third RO input is added by extending that explicit set, not by
   widening a prefix.

This also removes the now-unnecessary `_SANDBOX_INPUT_PREFIX` prefix semantics
(the constant may be dropped or repurposed to the explicit DEST set).

---

## 5. SECONDARY items (folded in)

- **`--cap-drop` wrong-value message**: the generic `_VALUE_OK` failure message
  (`"planned_argv {tok} value {nxt!r} violates containment"`) states neither the
  expected `ALL` nor a rule name. Give `--cap-drop` a dedicated branch (or a
  per-flag message map) reading e.g. `"--cap-drop must be 'ALL' (partial drop
  insufficient) (R-CAP-DROP)"`. ~3 lines.
- **Cross-reference R-BIND-RW at the exemption site**: add a one-line comment at
  the scratch-always-scoped code noting the interaction with R-BIND-RW (the rw
  bind is already pinned to `scratch_drive_path`). ~1 line.
- **Step-2 comment header**: update the "Token scan" header block (line ~167-168)
  to mention R-INNER-ALLOWLIST alongside the existing forbidden/device/value list.
  ~2 lines.
- **Fixture duplication (`_GOOD_ARGV`, 12 identical tokens across
  `detonate-exec.test.sh` and `trace-exec.test.sh`)**: **leave a precise `#62`
  note, do NOT factor now.** Factoring a shared fixture is exactly the
  `vm_exec_common.py` extraction #62 owns; doing it here would pre-empt that
  change's design and touch two exec-test files this correction otherwise does not
  need to modify. Add a `# NOTE(#62): _GOOD_ARGV is duplicated verbatim in
  trace-exec.test.sh; extract to a shared exec-test fixture during vm_exec_common
  extraction.` comment at both sites. ~2 lines total.

---

## 6. CORRECTION PLAN — TDD slices

Every slice below is RED-first: write the failing assertion, watch it fail for the
stated reason, implement, watch it pass. Every rule gets a fragment-asserted test
via `assert_gate_error_msg(fn, label, fragment)` AND at least one mutation
obligation. Where a positional bypass is possible, the mutation is **relocation**,
not deletion — deletion alone is what let defect 1 pass review twice.

Fragments are the load-bearing contract: each rule emits a UNIQUE substring and
the test asserts exactly that substring, so a test cannot be satisfied by an
unrelated rule firing.

### Slice A — Defect 1: slice-scoped required flags + value predicates

Test file: `tests/vm-disk-policy.test.sh`.

- **A1 (deletion)** — `VDP-T10c` (`--unshare-pid` dropped from prefix). Fragment
  `--unshare-pid`. Already present in diff; keep.
- **A2 (RELOCATION, new)** — `VDP-T10c-reloc`: remove `--unshare-pid` from the
  bwrap prefix and re-insert it AFTER the `--` separator. Fragment `--unshare-pid`.
  MUST be RED against the current `set(argv)` code (it passes today — confirmed by
  harness) and GREEN after the slice fix. This is the mutation that proves the
  range fix.
- **A3 (RELOCATION, new)** — `VDP-T10a-reloc`: relocate `--cap-drop ALL` into the
  inner slice, dropping it from the prefix. Fragment `--cap-drop`. RED today.
- **A4 (RELOCATION, new)** — `VDP-T10d-reloc`: relocate `--tmpfs /tmp/rsdd` into
  the inner slice. Fragment `--tmpfs`. RED today.
- **A5 (deletion, keep)** — `VDP-T10a/b/d/e` existing deletion/value cases stay,
  but retarget fragments to the specific rule names (`--cap-drop` value case gets
  fragment `R-CAP-DROP`).
- **A6 (inner-flag deletion)** — new `VDP-T13`: drop `-sandbox` from the inner
  slice → fragment `-sandbox` (or `R-INNER-REQ`). Proves inner-required check.
- **A7 (inner-flag relocation)** — new `VDP-T13-reloc`: move `-smp 1` BEFORE the
  `--` (into the bwrap prefix). Fragment for the inner-required rule. RED today
  (full-argv set is satisfied), GREEN after fix.

Change: `lib/vm_disk_policy.py` §1 (required check) split into bwrap-side and
inner-side subset checks; `_VALUE_OK` loop split so each predicate runs in its
own slice; add `_REQUIRED_BWRAP`, `_REQUIRED_INNER` frozensets (may derive `inner`
once and reuse for Slice B). Est. **~28 authored lines** (module), **~40 lines**
(tests, incl. the four relocation cases).

Mutation obligation: deletion (A1, A6) AND relocation (A2, A3, A4, A7). A
reviewer MUST verify each relocation test goes RED when run against the pre-fix
module.

### Slice B — Defect 2: R-INNER-ALLOWLIST replaces the denylist

Test file: `tests/vm-disk-policy.test.sh`.

- **B1** — rewrite `VDP-T11` to iterate the block-device flags AND add at least
  one flag NOT previously enumerated (`-mtdblock`, `-nvme`) to prove the property
  is closed-set, not enumerated. Fragment `R-INNER-ALLOWLIST`. Each case appends
  the flag after the inner command; expects reject.
- **B2 (positive/negative boundary)** — new `VDP-T11-pos`: assert that a
  legitimate inner flag NOT in the block-device list but IN the allowlist
  (`-no-reboot`, `-nographic`) still PASSES (guards against an over-broad
  allowlist that rejects sanctioned flags). Uses `assert_passes`.
- **B3 (mutation)** — deletion mutation: removing `-no-reboot` from
  `_QEMU_INNER_ALLOWED` must turn `VDP-T7` (well-formed argv) RED. Documented as a
  reviewer mutation check (allowlist completeness is proven by the happy-path
  test going red when a needed entry is removed).

Change: `lib/vm_disk_policy.py` — add `_QEMU_INNER_ALLOWED` frozenset (11 entries,
commented); add the flag-shaped catch-all as inner-slice step 5; **remove**
`_BLOCK_DEVICE_FORBIDDEN` and its check block. Est. **~18 authored lines added,
~20 removed** (module), **~15 lines** (tests).

Mutation obligation: deletion (remove an allowlist entry → happy path RED, B3) AND
the closed-set proof (B1's non-enumerated flag). No relocation applies (the rule
is inherently slice-scoped).

### Slice C — Defect 3: path-safe exemption + always-scope scratch

Test file: `tests/vm-disk-policy.test.sh`.

- **C1 (regression)** — new `VDP-T14`: writable-persistent scratch at
  `/input/scratch.img` with `run_dir` set → fragment `R-SCOPE-ALL`. RED today
  (confirmed by harness), GREEN after the always-scope-scratch fix.
- **C2 (traversal)** — new `VDP-T15`: `-drive file=/input/../etc/shadow,...`
  (with matching `--ro-bind` so R-REACH is not what fires) → fragment
  `R-SCOPE-ALL`. RED today.
- **C3 (positive)** — extend/keep `VDP-T7`: the genuine `/input/sample` and
  `/input/rootfs` DESTs still PASS (exemption still works for the two real DESTs).
- **C4 (mutation)** — mutation-by-substitution: changing the normalized-DEST set
  check back to `startswith("/input/")` must turn C1 and C2 RED (reviewer check).

Change: `lib/vm_disk_policy.py` §4 — unconditional scratch scope check before the
loop; replace `startswith(_SANDBOX_INPUT_PREFIX)` with
`posixpath.normpath(dp) in {_SAMPLE_GUEST_PATH, _ROOTFS_GUEST_PATH}`; import
`posixpath` (or `os.path.normpath` on posix); add R-BIND-RW cross-ref comment.
Est. **~14 authored lines** (module), **~18 lines** (tests).

Mutation obligation: substitution (C4) AND the regression case (C1) which is
itself a behavioural mutation guard against the #61 exemption.

### Slice D — Secondary polish

- `--cap-drop` dedicated message (`R-CAP-DROP`) — covered by A5 fragment retarget.
- Step-2 comment header mentions R-INNER-ALLOWLIST.
- `# NOTE(#62)` fixture-duplication markers at both `_GOOD_ARGV` sites in
  `detonate-exec.test.sh` and `trace-exec.test.sh`.

Est. **~8 authored lines** total across three files (2 of them test comments).

### Budget

**Line ceiling: 160 authored net lines** across `lib/vm_disk_policy.py` (~60 net,
after removing the ~20-line denylist) and the three test files (~90). Justified:
three mechanism swaps, each needing positive + negative + mutation coverage, plus
four new relocation cases that are the reincidence-prevention core. This is within
a single bounded correction transaction; the standing `min(200, ceil(orig/2))`
correction budget is not exceeded. If implementation trends past 160 authored
lines, STOP and re-scope rather than grind — but the plan is sized to land under.

---

## 7. What remains operator-verified-only / untestable offline

- **bwrap actually enforces the teeth**: the policy proves the flags are present
  in the correct slice; it cannot prove the host `bwrap` binary honours
  `--unshare-pid` / `--cap-drop ALL` / `--tmpfs` at runtime. Kernel-namespace and
  capability enforcement is an operator/runtime property, verified only during a
  live gated `--allow-exec` run.
- **QEMU's real flag semantics**: R-INNER-ALLOWLIST asserts only sanctioned flags
  appear; it does not model what a permitted flag's value could do at the QEMU
  level (e.g. an `-append` kernel cmdline value). Value-level containment for
  `-append` is out of scope for this correction and remains a runtime concern.
- **Path identity under the sandbox**: the scope check reasons about the argv
  strings, not the host inode the executor ultimately binds. That the substituted
  per-run scratch path is inside the real run_dir on disk is an executor/runtime
  guarantee, exercised only in a live run.
- **`-drive` interface/backend nuances** (e.g. `if=`, cache modes) beyond
  `format`, `readonly`, `snapshot` remain unmodelled by design.
