#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/../score-loop-transcript.sh"
FIX="$HERE/fixtures/score-loop"
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
pass=0; fail=0
ok(){ echo "  PASS  $1"; pass=$((pass+1)); }
no(){ echo "  FAIL  $1"; fail=$((fail+1)); }

# --- repo builder: mkrepo <dir> [<iso-date> <subject>]... -------------------------------------
mkrepo() {
  local dir="$1"; shift
  git init -q "$dir"
  git -C "$dir" config user.email t@example.com
  git -C "$dir" config user.name t
  local n=0 ts subj
  while [ "$#" -ge 2 ]; do
    ts="$1"; subj="$2"; shift 2
    n=$((n+1))
    echo "$n" > "$dir/f.txt"
    git -C "$dir" add f.txt
    GIT_AUTHOR_DATE="$ts" GIT_COMMITTER_DATE="$ts" git -C "$dir" commit -q -m "$subj" >/dev/null
  done
}

STUB_STOP="$FIX/stub-status-stop-empty.sh"
STUB_NOTSTOP="$FIX/stub-status-not-stop.sh"
STUB_STALE="$FIX/stub-status-stale.sh"
STUB_FAILING="$FIX/stub-status-failing.sh"
STUB_WARN_STDERR="$FIX/stub-status-warn-stderr.sh"
STUB_NOQUEUE="$FIX/stub-status-stop-no-queue.sh"
STUB_MULTIFOCUS_DRAINED="$FIX/stub-status-stop-multifocus-drained.sh"
STUB_MULTIFOCUS_MIXED="$FIX/stub-status-stop-multifocus-mixed.sh"

# --- fixture repos --------------------------------------------------------------------------
mkrepo "$ROOT/continue" \
  "2026-06-01T00:10:00Z" "research(demo): B1 gap-a" \
  "2026-06-01T00:20:00Z" "research(demo): B2 gap-b"

mkrepo "$ROOT/continue-poststop" \
  "2026-06-01T00:10:00Z" "research(demo): B1 gap-a" \
  "2026-06-01T00:20:00Z" "research(demo): B2 gap-b" \
  "2026-06-01T00:30:00Z" "research(demo): B3 gap-c"

mkrepo "$ROOT/compaction-survive" \
  "2026-05-31T23:50:00Z" "research(demo): B1 gap-a" \
  "2026-06-01T00:10:00Z" "research(demo): B2 gap-b"

mkrepo "$ROOT/compaction-stall" \
  "2026-05-31T23:50:00Z" "research(demo): B1 gap-a"

mkrepo "$ROOT/one-block" \
  "2026-06-01T00:10:00Z" "research(demo): B1 gap-a"

# span [00:10,00:20] in out-of-span.jsonl; B1 before it, B2 inside it.
mkrepo "$ROOT/out-of-span-repo" \
  "2026-06-01T00:05:00Z" "research(demo): B1 gap-a" \
  "2026-06-01T00:15:00Z" "research(demo): B2 gap-b"

# real-shape block-subject regression: a preamble before the block ref, an explicit
# B<n>-B<m> range (weight 3), and a retro that only CITES a prior range in a trailing
# parenthetical (must NOT be counted at all). Neutral synthetic subjects, not copied
# from any real corpus.
mkrepo "$ROOT/block-regex" \
  "2026-06-01T00:05:00Z" "research(demo/wb-vendor-ux): bootstrap focus + B1054 synthetic palette WB" \
  "2026-06-01T00:10:00Z" "research(demo/security-seams): B1161-B1163 SES10 — synthetic native RE" \
  "2026-06-01T00:15:00Z" "research(demo/module-mechanics): §18 full-run retro (B867-B891, MM1-MM25)"

# round 3: `block(` accepted alongside `research(`; `docs(` deliberately excluded (see script
# header — a docs(retros): B<n>-B<m> retro-summary subject is indistinguishable from a genuine
# multi-block docs(...) commit by the region-cut heuristic, unlike research(...)/block(...)).
mkrepo "$ROOT/block-prefix" \
  "2026-06-01T00:05:00Z" "block(demo-focus): B900 synthetic block commit"

mkrepo "$ROOT/docs-prefix" \
  "2026-06-01T00:05:00Z" "docs(demo-focus): B900 synthetic block commit"

# round 3: an implausible range (span >50) must WARN and cap to weight 1, not explode N_BLOCKS.
mkrepo "$ROOT/range-cap" \
  "2026-06-01T00:05:00Z" "research(demo/security-seams): B1000-B1200 SES99 — synthetic implausible range"

mkdir -p "$ROOT/no-git"

# ============================================================================================
# Bad args / operational failures
# ============================================================================================
rc=$(bash "$SUT" >/dev/null 2>&1; echo $?)
[ "$rc" -eq 2 ] && ok "missing --corpus: exit 2 (bad args)" || no "missing --corpus: exit 2, got $rc"

rc=$(bash "$SUT" --corpus "$ROOT/does-not-exist" >/dev/null 2>&1; echo $?)
[ "$rc" -eq 1 ] && ok "corpus not found: exit 1 (operational)" || no "corpus not found: exit 1, got $rc"

rc=$(bash "$SUT" --corpus "$ROOT/no-git" >/dev/null 2>&1; echo $?)
[ "$rc" -eq 1 ] && ok "corpus not a git repo: exit 1 (operational)" || no "corpus not a git repo: exit 1, got $rc"

rc=$(bash "$SUT" --corpus "$ROOT/continue" --transcript "$ROOT/nope.jsonl" >/dev/null 2>&1; echo $?)
[ "$rc" -eq 2 ] && ok "missing --transcript file: exit 2 (bad args)" || no "missing --transcript file: exit 2, got $rc"

rc=$(bash "$SUT" --corpus "$ROOT/continue" --bogus-flag >/dev/null 2>&1; echo $?)
[ "$rc" -eq 2 ] && ok "unknown flag: exit 2 (bad args)" || no "unknown flag: exit 2, got $rc"

# git log itself failing (a bad --base-ref) must exit 1 with the error surfaced, not swallowed.
out="$(bash "$SUT" --corpus "$ROOT/continue" --base-ref not-a-real-ref 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && ok "bad --base-ref: exit 1 (git failure surfaced)" || no "bad --base-ref: exit 1, got $rc"
grep -qi "git log failed" <<<"$out" && ok "bad --base-ref: stderr names the git failure" || no "bad --base-ref: stderr ($out)"

# ============================================================================================
# Without a transcript — C1 still counts commits (n/a for the operator-input sub-check);
# C2/C3/C4 are all n/a (no transcript given at all).
# ============================================================================================
out="$(bash "$SUT" --corpus "$ROOT/continue" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "no-transcript run: exit 0" || no "no-transcript run: exit 0, got $rc"
grep -qE '^C1 n/a 2 block commits' <<<"$out" && ok "no-transcript: C1 counts 2 block commits, n/a" || no "no-transcript: C1 count ($out)"
grep -qE '^C2 n/a no transcript$' <<<"$out" && ok "no-transcript: C2 n/a" || no "no-transcript: C2 n/a ($out)"
grep -qE '^C3 n/a no transcript$' <<<"$out" && ok "no-transcript: C3 n/a" || no "no-transcript: C3 n/a ($out)"
grep -qE '^C4 n/a no transcript' <<<"$out" && ok "no-transcript: C4 n/a" || no "no-transcript: C4 n/a ($out)"
grep -qE '^SUMMARY pass=0 fail=0 n/a=4 degraded=0$' <<<"$out" && ok "no-transcript: summary" || no "no-transcript: summary ($out)"

out="$(bash "$SUT" --corpus "$ROOT/one-block" 2>&1)"
grep -qE '^C1 fail only 1 block commit' <<<"$out" && ok "one-block corpus: C1 fail (below threshold)" || no "one-block corpus: C1 ($out)"

# ============================================================================================
# Clean continuation — all four criteria pass. C3 is "no compaction" -> pass, not n/a.
# ============================================================================================
out="$(RSDD_STATUS_SCRIPT="$STUB_STOP" bash "$SUT" --corpus "$ROOT/continue" \
  --transcript "$FIX/continue-clean.jsonl" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "continue-clean: exit 0" || no "continue-clean: exit 0, got $rc"
grep -qE '^C1 pass 2 block commits, 0 operator turns' <<<"$out" && ok "continue-clean: C1 pass" || no "continue-clean: C1 ($out)"
grep -qE '^C2 pass 0 of 1 final returns' <<<"$out" && ok "continue-clean: C2 pass" || no "continue-clean: C2 ($out)"
grep -qE '^C3 pass no compaction, 2 block\(s\)$' <<<"$out" && ok "continue-clean: C3 pass (no compaction is the best outcome)" || no "continue-clean: C3 ($out)"
grep -qE '^C4 pass STOP token present' <<<"$out" && ok "continue-clean: C4 pass" || no "continue-clean: C4 ($out)"
grep -qE '^SUMMARY pass=4 fail=0 n/a=0 degraded=0$' <<<"$out" && ok "continue-clean: summary" || no "continue-clean: summary ($out)"

# ============================================================================================
# False-positive-noise regression (item 1): tool_result, task-notification, peer, /loop
# re-fires, and hook-feedback tags sit between the two block commits. None of them are a
# genuine operator turn (origin.kind != "human"), so C1 must still pass.
# ============================================================================================
out="$(RSDD_STATUS_SCRIPT="$STUB_STOP" bash "$SUT" --corpus "$ROOT/continue" \
  --transcript "$FIX/false-positive-noise.jsonl" 2>&1)"
grep -qE '^C1 pass 2 block commits, 0 operator turns' <<<"$out" \
  && ok "false-positive-noise: C1 pass (noise correctly excluded)" || no "false-positive-noise: C1 ($out)"
grep -qE '^C4 pass' <<<"$out" && ok "false-positive-noise: C4 pass" || no "false-positive-noise: C4 ($out)"

# ============================================================================================
# C1 fail — a genuine (origin.kind=human) operator turn lands between two block commits.
# ============================================================================================
out="$(RSDD_STATUS_SCRIPT="$STUB_STOP" bash "$SUT" --corpus "$ROOT/continue" \
  --transcript "$FIX/operator-interrupt.jsonl" 2>&1)"
grep -qE '^C1 fail 2 block commits but 1 of 1 gap' <<<"$out" && ok "operator-interrupt: C1 fail" || no "operator-interrupt: C1 ($out)"

# ============================================================================================
# Unrecognized transcript shape (round 3 BLOCKER — Opus reproduced, RDD approved with warnings):
# a transcript that has no `.origin` field at all (another harness, or `jq -c 'del(.origin)'`
# applied to a Claude Code one), or whose top-level `.type` never equals `"user"`/`"assistant"`
# (a real Codex/reasonix rollout shape — `.type=="response_item"` with a NESTED `.payload.role`),
# must degrade every criterion instead of silently scoring a false clean pass.
# ============================================================================================
out="$(RSDD_STATUS_SCRIPT="$STUB_STOP" bash "$SUT" --corpus "$ROOT/continue" \
  --transcript "$FIX/origin-less.jsonl" 2>&1)"
grep -qE '^C1 degraded unrecognized transcript shape' <<<"$out" \
  && ok "origin-less: C1 degraded (no record carries .origin)" || no "origin-less: C1 ($out)"
grep -qE '^C2 degraded unrecognized transcript shape' <<<"$out" \
  && ok "origin-less: C2 degraded" || no "origin-less: C2 ($out)"
grep -qE '^C3 degraded unrecognized transcript shape' <<<"$out" \
  && ok "origin-less: C3 degraded" || no "origin-less: C3 ($out)"
grep -qE '^C4 degraded unrecognized transcript shape' <<<"$out" \
  && ok "origin-less: C4 degraded" || no "origin-less: C4 ($out)"
grep -qE '^SUMMARY pass=0 fail=0 n/a=0 degraded=4$' <<<"$out" \
  && ok "origin-less: summary" || no "origin-less: summary ($out)"

out="$(RSDD_STATUS_SCRIPT="$STUB_STOP" bash "$SUT" --corpus "$ROOT/continue" \
  --transcript "$FIX/codex-rollout-shape.jsonl" 2>&1)"
grep -qE '^C1 degraded unrecognized transcript shape' <<<"$out" \
  && ok "codex-rollout-shape: C1 degraded (zero recognized operator AND assistant records)" \
  || no "codex-rollout-shape: C1 ($out)"
grep -qE '^C4 degraded unrecognized transcript shape' <<<"$out" \
  && ok "codex-rollout-shape: C4 degraded" || no "codex-rollout-shape: C4 ($out)"

# ============================================================================================
# C2 — markdown-wrapped endings, final-paragraph scan (not just the physical last line), and
# a Spanish ¿...? pair anywhere in the final paragraph.
# ============================================================================================
out="$(RSDD_STATUS_SCRIPT="$STUB_STOP" bash "$SUT" --corpus "$ROOT/continue" \
  --transcript "$FIX/question-ending.jsonl" 2>&1)"
grep -qE '^C2 fail 2 of 2 final returns end in a question' <<<"$out" && ok "question-ending: C2 fail" || no "question-ending: C2 ($out)"

out="$(RSDD_STATUS_SCRIPT="$STUB_STOP" bash "$SUT" --corpus "$ROOT/continue" \
  --transcript "$FIX/question-paragraph.jsonl" 2>&1)"
grep -qE '^C2 fail 2 of 2 final returns end in a question' <<<"$out" \
  && ok "question-paragraph: C2 fail (mid-paragraph question + ¿...? both caught)" \
  || no "question-paragraph: C2 ($out)"

# ============================================================================================
# C3 — structural compaction detection only (compact_boundary / isCompactSummary), and the
# "no compaction found" outcome is a pass, not n/a.
# ============================================================================================
out="$(RSDD_STATUS_SCRIPT="$STUB_STOP" bash "$SUT" --corpus "$ROOT/compaction-survive" \
  --transcript "$FIX/compaction-survive.jsonl" 2>&1)"
grep -qE '^C3 pass compaction detected; 1 block commit\(s\) before, 1 after' <<<"$out" \
  && ok "compaction-survive: C3 pass" || no "compaction-survive: C3 ($out)"

out="$(RSDD_STATUS_SCRIPT="$STUB_STOP" bash "$SUT" --corpus "$ROOT/compaction-stall" \
  --transcript "$FIX/compaction-survive.jsonl" 2>&1)"
grep -qE '^C3 fail compaction detected; 1 block commit\(s\) before, 0 after' <<<"$out" \
  && ok "compaction-stall: C3 fail" || no "compaction-stall: C3 ($out)"

# round 3: each structural arm isolated in its own fixture (a prior fixture carried BOTH
# compact_boundary and isCompactSummary at once, so it could not prove either arm alone works).
out="$(RSDD_STATUS_SCRIPT="$STUB_STOP" bash "$SUT" --corpus "$ROOT/compaction-survive" \
  --transcript "$FIX/compaction-boundary-only.jsonl" 2>&1)"
grep -qE '^C3 pass compaction detected' <<<"$out" \
  && ok "compaction-boundary-only: compact_boundary alone is detected as compaction" \
  || no "compaction-boundary-only: C3 ($out)"

out="$(RSDD_STATUS_SCRIPT="$STUB_STOP" bash "$SUT" --corpus "$ROOT/compaction-survive" \
  --transcript "$FIX/compaction-summary-only.jsonl" 2>&1)"
grep -qE '^C3 pass compaction detected' <<<"$out" \
  && ok "compaction-summary-only: isCompactSummary alone is detected as compaction" \
  || no "compaction-summary-only: C3 ($out)"

# ============================================================================================
# C4 — markdown-wrapped STOP token; status disagrees; a block commit lands after STOP;
# research-sdd-status.sh missing/failing/STALE all degrade rather than false-passing.
# ============================================================================================
out="$(RSDD_STATUS_SCRIPT="$STUB_STOP" bash "$SUT" --corpus "$ROOT/continue" \
  --transcript "$FIX/stop-wrapped.jsonl" 2>&1)"
grep -qE '^C4 pass STOP token present' <<<"$out" \
  && ok "stop-wrapped: C4 pass (bold-wrapped STOP: tolerated)" || no "stop-wrapped: C4 ($out)"

# kit issue #1107: a corpus that reaches campaign STOP without ever declaring a `## Campaign
# queue` (METHODOLOGY §8c — the common case in real corpora) must not read as a vacuous C4
# pass. "queue empty" is unverifiable when there is no queue to inspect at all, so this is a
# distinct n/a state, not pass and not fail.
out="$(RSDD_STATUS_SCRIPT="$STUB_NOQUEUE" bash "$SUT" --corpus "$ROOT/continue" \
  --transcript "$FIX/continue-clean.jsonl" 2>&1)"
grep -qE '^C4 n/a no campaign queue declared' <<<"$out" \
  && ok "no-queue-declared: C4 n/a (not a vacuous pass)" || no "no-queue-declared: C4 ($out)"

# round 2 BLOCKER (kit issue #1107): a multi-focus corpus prints one LABELLED line per
# queue-bearing focus (`campaign[alpha] :`, `campaign[beta]  :`), never a single bare
# `campaign        :` line. C4 must read every matching line, not just the first.
out="$(RSDD_STATUS_SCRIPT="$STUB_MULTIFOCUS_DRAINED" bash "$SUT" --corpus "$ROOT/continue" \
  --transcript "$FIX/continue-clean.jsonl" 2>&1)"
grep -qE '^C4 pass STOP token present' <<<"$out" \
  && ok "multi-focus-drained: C4 pass (both labelled queues genuinely empty)" \
  || no "multi-focus-drained: C4 ($out)"

# A genuinely non-empty SIBLING queue must turn this into fail, not a false n/a (the bug the
# BLOCKER reported: `head -n1` on an unmatched bracketed line hid the sibling's open queue).
out="$(RSDD_STATUS_SCRIPT="$STUB_MULTIFOCUS_MIXED" bash "$SUT" --corpus "$ROOT/continue" \
  --transcript "$FIX/continue-clean.jsonl" 2>&1)"
grep -qE '^C4 fail stop_token=present status_next=STOP queue=non-empty commits_after_stop=0' <<<"$out" \
  && ok "multi-focus-mixed: C4 fail (sibling focus's non-empty queue is not hidden)" \
  || no "multi-focus-mixed: C4 ($out)"

out="$(RSDD_STATUS_SCRIPT="$STUB_NOTSTOP" bash "$SUT" --corpus "$ROOT/continue" \
  --transcript "$FIX/continue-clean.jsonl" 2>&1)"
grep -qE '^C4 fail stop_token=present status_next=NOT-STOP' <<<"$out" \
  && ok "continue-clean + not-stop status: C4 fail" || no "continue-clean + not-stop status: C4 ($out)"

# round 3: the window now defaults to the transcript's own span, which would naturally exclude
# a commit landing AFTER the transcript ended (2026-06-01T00:30Z, after continue-clean.jsonl's
# 00:25Z end) before this check ever runs — --until is passed explicitly to widen the window and
# still exercise the "commit after STOP" path (see the script header's "Usage" tradeoff note).
out="$(RSDD_STATUS_SCRIPT="$STUB_STOP" bash "$SUT" --corpus "$ROOT/continue-poststop" \
  --transcript "$FIX/continue-clean.jsonl" --until "2026-06-01T01:00:00Z" 2>&1)"
grep -qE '^C4 fail stop_token=present status_next=STOP queue=empty commits_after_stop=1' <<<"$out" \
  && ok "commit after STOP: C4 fail" || no "commit after STOP: C4 ($out)"

out="$(RSDD_STATUS_SCRIPT="$STUB_STALE" bash "$SUT" --corpus "$ROOT/continue" \
  --transcript "$FIX/continue-clean.jsonl" 2>&1)"
grep -qE '^C4 degraded research-sdd-status.sh --next reports STALE' <<<"$out" \
  && ok "STALE status: C4 degraded (not a false pass)" || no "STALE status: C4 ($out)"

out="$(RSDD_STATUS_SCRIPT="$STUB_FAILING" bash "$SUT" --corpus "$ROOT/continue" \
  --transcript "$FIX/continue-clean.jsonl" 2>&1)"
grep -qE '^C4 degraded research-sdd-status.sh failed' <<<"$out" \
  && ok "failing status script: C4 degraded" || no "failing status script: C4 ($out)"

out="$(RSDD_STATUS_SCRIPT="$ROOT/no-such-status.sh" bash "$SUT" --corpus "$ROOT/continue" \
  --transcript "$FIX/continue-clean.jsonl" 2>&1)"
grep -qE '^C4 degraded research-sdd-status.sh not found' <<<"$out" \
  && ok "missing status script: C4 degraded" || no "missing status script: C4 ($out)"

# round 3 RDD fix: a stderr WARN from research-sdd-status.sh must never leak into the stdout
# string that ^STOP/^STALE are matched against.
out="$(RSDD_STATUS_SCRIPT="$STUB_WARN_STDERR" bash "$SUT" --corpus "$ROOT/continue" \
  --transcript "$FIX/continue-clean.jsonl" 2>&1)"
grep -qE '^C4 pass STOP token present' <<<"$out" \
  && ok "status-script stderr WARN does not break C4's STOP/STALE match" || no "stderr-separation: C4 ($out)"

# round 3 RDD fix: @tsv's own escaping cannot round-trip text containing a literal "\n" and a
# literal "\\" unambiguously in bash — last_para is now carried as base64, which can.
out="$(RSDD_STATUS_SCRIPT="$STUB_STOP" bash "$SUT" --corpus "$ROOT/continue" \
  --transcript "$FIX/backslash-roundtrip.jsonl" 2>&1)"
grep -qE '^C4 pass STOP token present' <<<"$out" \
  && ok "backslash-roundtrip: literal \\\\n and \\\\ do not corrupt the extracted STOP line" \
  || no "backslash-roundtrip: C4 ($out)"

# ============================================================================================
# Transcript span (item 2): a block commit outside [first_ts, last_ts] degrades C1 and C3,
# reporting the out-of-span count — never a silent false pass or fail. Since round 3 the window
# defaults to the transcript's own span, so this test explicitly widens --since to still see the
# out-of-window commit and exercise the degrade path (see script header "Usage" tradeoff note).
# ============================================================================================
out="$(RSDD_STATUS_SCRIPT="$STUB_STOP" bash "$SUT" --corpus "$ROOT/out-of-span-repo" \
  --transcript "$FIX/out-of-span.jsonl" --since "2026-06-01T00:00:00Z" 2>&1)"
grep -qE '^C1 degraded 1 of 2 block commit\(s\) outside transcript span' <<<"$out" \
  && ok "out-of-span (explicit --since): C1 degraded" || no "out-of-span: C1 ($out)"
grep -qE '^C3 degraded 1 of 2 block commit\(s\) outside transcript span' <<<"$out" \
  && ok "out-of-span (explicit --since): C3 degraded" || no "out-of-span: C3 ($out)"
grep -qE '^C2 pass' <<<"$out" && ok "out-of-span: C2 unaffected" || no "out-of-span: C2 ($out)"
grep -qE '^C4 pass' <<<"$out" && ok "out-of-span: C4 unaffected" || no "out-of-span: C4 ($out)"

# round 3 (new): with NO explicit window, the default now scopes to the transcript's own span,
# so `git log` itself never returns the out-of-window commit — the out-of-span DEGRADE path
# does not even need to fire; C1/C3 score cleanly on just the in-span commit.
out="$(RSDD_STATUS_SCRIPT="$STUB_STOP" bash "$SUT" --corpus "$ROOT/out-of-span-repo" \
  --transcript "$FIX/out-of-span.jsonl" 2>&1)"
grep -qE '^C1 fail only 1 block commit in window' <<<"$out" \
  && ok "default window = transcript span: git log itself excludes the out-of-window commit" \
  || no "default-window-scoping: C1 ($out)"

# ============================================================================================
# Block-commit regex (item 8): a preamble before the block ref, a B<n>-B<m> range weighted as
# (m-n+1) blocks, and a retro's trailing parenthetical range citation excluded entirely.
# ============================================================================================
out="$(bash "$SUT" --corpus "$ROOT/block-regex" 2>&1)"
grep -qE '^C1 n/a 4 block commits in window' <<<"$out" \
  && ok "block-regex: 1 (preamble) + 3 (range) + 0 (retro citation excluded) = 4" \
  || no "block-regex: C1 ($out)"

out="$(bash "$SUT" --corpus "$ROOT/block-prefix" 2>&1)"
grep -qE '^C1 fail only 1 block commit in window' <<<"$out" \
  && ok "block-prefix: block(...) subject counts (round 3)" || no "block-prefix: C1 ($out)"

out="$(bash "$SUT" --corpus "$ROOT/docs-prefix" 2>&1)"
grep -qE '^C1 fail 0 block commits' <<<"$out" \
  && ok "docs-prefix: docs(...) subject deliberately excluded (round 3)" || no "docs-prefix: C1 ($out)"

out="$(bash "$SUT" --corpus "$ROOT/range-cap" 2>&1)"
grep -qE '^C1 fail only 1 block commit in window' <<<"$out" \
  && ok "range-cap: implausible B1000-B1200 range capped to weight 1" || no "range-cap: C1 ($out)"
grep -qi "WARN: implausible block range B1000-B1200" <<<"$out" \
  && ok "range-cap: WARN emitted on stderr naming the commit" || no "range-cap: WARN ($out)"

# ============================================================================================
# --base-ref / --since actually narrow the window (restored — round 3 RDD warning: these were
# missing from the round-2 suite). No transcript is given, so auto-scoping never applies.
# ============================================================================================
b1_sha="$(git -C "$ROOT/continue" log --format='%H' --grep='^research(demo): B1' -- . | head -n1)"
out="$(bash "$SUT" --corpus "$ROOT/continue" --base-ref "$b1_sha" 2>&1)"
grep -qE '^C1 fail only 1 block commit' <<<"$out" && ok "--base-ref scopes the window (B1 excluded)" || no "--base-ref scoping ($out)"

out="$(bash "$SUT" --corpus "$ROOT/continue" --since "2026-06-01T00:15:00Z" 2>&1)"
grep -qE '^C1 fail only 1 block commit' <<<"$out" && ok "--since scopes the window (B1 excluded)" || no "--since scoping ($out)"

# ============================================================================================
# Degraded states — malformed transcript JSON, and dependencies absent.
# ============================================================================================
printf '{"type":"user","origin":{"kind":"human"},"timestamp":"2026-06-01T00:00:00Z","message":{"role":"user","content":"hi"}}\nnot-json\n' \
  > "$ROOT/malformed.jsonl"
out="$(RSDD_STATUS_SCRIPT="$STUB_STOP" bash "$SUT" --corpus "$ROOT/continue" \
  --transcript "$ROOT/malformed.jsonl" 2>&1)"
grep -qE '^C2 degraded degraded: transcript did not parse cleanly' <<<"$out" \
  && ok "malformed transcript: C2 degraded" || no "malformed transcript: C2 ($out)"
grep -qE '^C1 degraded 2 block commits in window; degraded:' <<<"$out" \
  && ok "malformed transcript: C1 degraded (commit count still reported)" || no "malformed transcript: C1 ($out)"

real_git="$(command -v git)"
real_date="$(command -v date)"
real_sort="$(command -v sort)"
real_grep="$(command -v grep)"
real_mktemp="$(command -v mktemp)"
real_cat="$(command -v cat)"
real_printf="$(command -v printf)"
real_tail="$(command -v tail)"
real_rm="$(command -v rm)"
real_tr="$(command -v tr)"
real_bash="$(command -v bash)"

# round 3 RDD fix: `rm`/`tr` are what load_block_commits actually needs (temp-file cleanup, and
# the git-log-failure error message) — a prior version of this isolated PATH omitted them, so a
# "jq absent" test could pass for the wrong reason (a missing `rm`/`tr` masking the real check).
mkdir -p "$ROOT/bin-nojq"
for pair in "git:$real_git" "date:$real_date" "sort:$real_sort" "grep:$real_grep" \
            "mktemp:$real_mktemp" "cat:$real_cat" "printf:$real_printf" "tail:$real_tail" \
            "rm:$real_rm" "tr:$real_tr"; do
  name="${pair%%:*}"; target="${pair#*:}"
  [ -n "$target" ] && ln -sf "$target" "$ROOT/bin-nojq/$name"
done
out="$(PATH="$ROOT/bin-nojq" RSDD_STATUS_SCRIPT="$STUB_STOP" \
  "$real_bash" "$SUT" --corpus "$ROOT/continue" --transcript "$FIX/continue-clean.jsonl" 2>&1)"
grep -qE '^C2 degraded degraded: jq not found in PATH' <<<"$out" \
  && ok "jq absent (isolated PATH, git present): C2 degraded" || no "jq absent: C2 ($out)"
grep -qE '^C1 degraded 2 block commits in window; degraded: jq not found' <<<"$out" \
  && ok "jq absent: C1 degraded (commit count still reported)" || no "jq absent: C1 ($out)"

mkdir -p "$ROOT/bin-nogit"
for pair in "date:$real_date" "sort:$real_sort" "grep:$real_grep" "mktemp:$real_mktemp" \
            "cat:$real_cat" "printf:$real_printf" "tail:$real_tail"; do
  name="${pair%%:*}"; target="${pair#*:}"
  [ -n "$target" ] && ln -sf "$target" "$ROOT/bin-nogit/$name"
done
out="$(PATH="$ROOT/bin-nogit" "$real_bash" "$SUT" --corpus "$ROOT/continue" 2>&1)"; rc=$?
[ "$rc" -eq 3 ] && ok "git absent: exit 3 (degraded)" || no "git absent: exit 3, got $rc"
grep -qE '^C1 degraded git-not-found$' <<<"$out" && ok "git absent: C1 degraded git-not-found" || no "git absent: C1 ($out)"
grep -qE '^C4 degraded git-not-found$' <<<"$out" && ok "git absent: C4 degraded git-not-found" || no "git absent: C4 ($out)"

# A `date` on PATH that cannot parse ISO-8601 with -d (e.g. BSD/macOS date) must degrade
# the whole instrument (exit 3), not silently mis-parse every timestamp as unusable.
mkdir -p "$ROOT/bin-nogitdate"
cat > "$ROOT/bin-nogitdate/date" <<'FAKE_DATE'
#!/usr/bin/env bash
# Synthetic non-GNU `date`: ignores -d and always fails to produce an epoch.
exit 1
FAKE_DATE
chmod +x "$ROOT/bin-nogitdate/date"
for pair in "git:$real_git" "sort:$real_sort" "grep:$real_grep" "mktemp:$real_mktemp" \
            "cat:$real_cat" "printf:$real_printf" "tail:$real_tail"; do
  name="${pair%%:*}"; target="${pair#*:}"
  [ -n "$target" ] && ln -sf "$target" "$ROOT/bin-nogitdate/$name"
done
out="$(PATH="$ROOT/bin-nogitdate" "$real_bash" "$SUT" --corpus "$ROOT/continue" 2>&1)"; rc=$?
[ "$rc" -eq 3 ] && ok "date -d unsupported: exit 3 (degraded)" || no "date -d unsupported: exit 3, got $rc"
grep -qE '^C1 degraded date-not-supported$' <<<"$out" \
  && ok "date -d unsupported: C1 degraded date-not-supported" || no "date -d unsupported: C1 ($out)"

# ============================================================================================
# Mutation self-test (--prove-teeth): flip one matching seam per criterion, plus the two
# round-2 seams explicitly called out (the operator origin.kind filter and the span check),
# and confirm the assertion above goes red against the exact SUT bytes that would ship each
# broken behavior.
# ============================================================================================
if [ "${1:-}" = "--prove-teeth" ]; then
  mutant() {
    local name="$1" expr="$2"
    local out="$ROOT/score-loop-transcript.MUTANT-$name.sh"
    sed "$expr" "$SUT" > "$out"
    printf '%s' "$out"
  }

  echo "-- teeth-C1: neutralise the block-commit regex match; expect C1 to report 0 commits --"
  m="$(mutant c1 's/"\$subj" =~ \$BLOCK_COMMIT_REGEX/"$subj" =~ ^NEVERMATCH_MUTANT_XYZ$/')"
  if grep -qF 'NEVERMATCH_MUTANT_XYZ' "$m"; then
    mo="$(bash "$m" --corpus "$ROOT/continue" 2>&1)"
    if grep -qE '^C1 fail 0 block commits' <<<"$mo"; then
      ok "teeth-C1: block-commit match neutralised → C1 collapses to 0 commits"
    else
      no "teeth-C1: mutant did not flip C1 — no teeth ($mo)"
    fi
  else
    no "teeth-C1: mutant build failed (source line not found)"
  fi

  echo "-- teeth-C2: neutralise the question regex match; expect C2 to flip to pass --"
  m="$(mutant c2 's/"\$line" =~ \$QUESTION_REGEX/"$line" =~ ^NEVERMATCH_MUTANT_XYZ$/')"
  if grep -qF 'NEVERMATCH_MUTANT_XYZ' "$m"; then
    mo="$(RSDD_STATUS_SCRIPT="$STUB_STOP" bash "$m" --corpus "$ROOT/continue" \
      --transcript "$FIX/question-ending.jsonl" 2>&1)"
    if grep -qE '^C2 pass 0 of 2' <<<"$mo"; then
      ok "teeth-C2: question match neutralised → C2 falsely reports pass"
    else
      no "teeth-C2: mutant did not flip C2 — no teeth ($mo)"
    fi
  else
    no "teeth-C2: mutant build failed (source line not found)"
  fi

  echo "-- teeth-C3: neutralise compaction detection; expect C3 to flip to 'no compaction' pass --"
  m="$(mutant c3 's/"\$is_cx" == "true"/"$is_cx" == "MUTANT_NEVER"/')"
  if grep -qF 'MUTANT_NEVER' "$m"; then
    mo="$(RSDD_STATUS_SCRIPT="$STUB_STOP" bash "$m" --corpus "$ROOT/compaction-survive" \
      --transcript "$FIX/compaction-survive.jsonl" 2>&1)"
    if grep -qE '^C3 pass no compaction' <<<"$mo"; then
      ok "teeth-C3: compaction detection neutralised → C3 falsely reports no compaction"
    else
      no "teeth-C3: mutant did not flip C3 — no teeth ($mo)"
    fi
  else
    no "teeth-C3: mutant build failed (source line not found)"
  fi

  echo "-- teeth-C4: neutralise the STOP-token regex match; expect C4 to flip to fail --"
  m="$(mutant c4 's/"\$stop_line" =~ \$STOP_TOKEN_REGEX/"$stop_line" =~ ^NEVERMATCH_MUTANT_XYZ$/')"
  if grep -qF 'NEVERMATCH_MUTANT_XYZ' "$m"; then
    mo="$(RSDD_STATUS_SCRIPT="$STUB_STOP" bash "$m" --corpus "$ROOT/continue" \
      --transcript "$FIX/continue-clean.jsonl" 2>&1)"
    if grep -qE '^C4 fail stop_token=absent' <<<"$mo"; then
      ok "teeth-C4: STOP-token match neutralised → C4 falsely reports fail"
    else
      no "teeth-C4: mutant did not flip C4 — no teeth ($mo)"
    fi
  else
    no "teeth-C4: mutant build failed (source line not found)"
  fi

  echo "-- teeth-C4-undeclared-queue: force declared_queue always true; expect the no-queue-declared corpus to stop reporting n/a --"
  m="$(mutant c4-undeclared-queue 's/if \[\[ -n "\${pend:-}" && -n "\${act:-}" \]\]; then/if true; then/')"
  if grep -qF 'if true; then' "$m"; then
    mo="$(RSDD_STATUS_SCRIPT="$STUB_NOQUEUE" bash "$m" --corpus "$ROOT/continue" \
      --transcript "$FIX/continue-clean.jsonl" 2>&1)"
    if ! grep -qE '^C4 n/a no campaign queue declared' <<<"$mo"; then
      ok "teeth-C4-undeclared-queue: declared_queue guard neutralised → no-queue corpus no longer reports n/a"
    else
      no "teeth-C4-undeclared-queue: mutant did not flip C4 — no teeth ($mo)"
    fi
  else
    no "teeth-C4-undeclared-queue: mutant build failed (source line not found)"
  fi

  echo "-- teeth-C4-multifocus: reintroduce head -n1 on the campaign-line grep; expect a sibling focus's open queue to hide behind the first labelled line --"
  m="$(mutant c4-multifocus "s@:')\"@:' | head -n1)\"@")"
  if grep -qF "| head -n1)\"" "$m"; then
    mo="$(RSDD_STATUS_SCRIPT="$STUB_MULTIFOCUS_MIXED" bash "$m" --corpus "$ROOT/continue" \
      --transcript "$FIX/continue-clean.jsonl" 2>&1)"
    if grep -qE '^C4 pass' <<<"$mo"; then
      ok "teeth-C4-multifocus: head -n1 reintroduced → beta's non-empty queue is hidden behind alpha's drained line, false pass"
    else
      no "teeth-C4-multifocus: mutant did not flip C4 — no teeth ($mo)"
    fi
  else
    no "teeth-C4-multifocus: mutant build failed (source line not found)"
  fi

  echo "-- teeth-C4-nonempty-branch: force the empty-queue branch to always fire; expect a genuinely non-empty declared queue to falsely pass --"
  m="$(mutant c4-nonempty-branch 's/elif \[\[ "\$empty_queue" -eq 1 \]\]; then/elif true; then/')"
  if grep -qF 'elif true; then' "$m"; then
    mo="$(RSDD_STATUS_SCRIPT="$STUB_MULTIFOCUS_MIXED" bash "$m" --corpus "$ROOT/continue" \
      --transcript "$FIX/continue-clean.jsonl" 2>&1)"
    if grep -qE '^C4 pass' <<<"$mo"; then
      ok "teeth-C4-nonempty-branch: empty-queue check neutralised → a genuinely non-empty declared queue falsely passes"
    else
      no "teeth-C4-nonempty-branch: mutant did not flip C4 — no teeth ($mo)"
    fi
  else
    no "teeth-C4-nonempty-branch: mutant build failed (source line not found)"
  fi

  echo "-- teeth-operator-filter: drop the origin.kind clause; expect the false-positive noise to count as operator input again (item 9) --"
  m="$(mutant operator-filter 's/(\.origin\.kind \/\/ \\"\\")==\\"human\\"/true/')"
  if grep -qF '(.type==\"user\") and (true)' "$m"; then
    mo="$(RSDD_STATUS_SCRIPT="$STUB_STOP" bash "$m" --corpus "$ROOT/continue" \
      --transcript "$FIX/false-positive-noise.jsonl" 2>&1)"
    if grep -qE '^C1 fail' <<<"$mo"; then
      ok "teeth-operator-filter: origin.kind clause dropped → task-notification/tool_result noise wrongly counts as operator input again"
    else
      no "teeth-operator-filter: mutant did not flip C1 — no teeth ($mo)"
    fi
  else
    no "teeth-operator-filter: mutant build failed (source line not found)"
  fi

  echo "-- teeth-span: neutralise the out-of-span degrade check; expect C1 to fall through to a normal (wrong) verdict --"
  m="$(mutant span 's/"\$oos" -gt 0/"$oos" -gt 999999/g')"
  if [ "$(grep -c '"\$oos" -gt 999999' "$m")" -ge 2 ]; then
    mo="$(RSDD_STATUS_SCRIPT="$STUB_STOP" bash "$m" --corpus "$ROOT/out-of-span-repo" \
      --transcript "$FIX/out-of-span.jsonl" --since "2026-06-01T00:00:00Z" 2>&1)"
    if grep -qE '^C1 fail 2 block commits but 1 of 1 gap' <<<"$mo"; then
      ok "teeth-span: span check neutralised → C1 falls through to an unwarranted fail instead of degraded"
    else
      no "teeth-span: mutant did not flip C1 — no teeth ($mo)"
    fi
  else
    no "teeth-span: mutant build failed (both source lines not found)"
  fi

  echo "-- teeth-unrecognized-shape: neutralise the guard; expect a del(.origin)-shaped transcript to score a false clean pass (round 3 BLOCKER) --"
  # Neutralise both assignments that can ever set the guard to 1, forcing it to always read 0.
  m="$(mutant unrecognized-shape 's/UNRECOGNIZED_SHAPE=1/UNRECOGNIZED_SHAPE=0/g')"
  if [ "$(grep -c 'UNRECOGNIZED_SHAPE=0' "$m")" -ge 3 ]; then
    mo="$(RSDD_STATUS_SCRIPT="$STUB_STOP" bash "$m" --corpus "$ROOT/continue" \
      --transcript "$FIX/origin-less.jsonl" 2>&1)"
    if grep -qE '^C1 pass 2 block commits, 0 operator turns' <<<"$mo"; then
      ok "teeth-unrecognized-shape: guard neutralised → origin-less transcript falsely scores a clean C1 pass"
    else
      no "teeth-unrecognized-shape: mutant did not flip C1 — no teeth ($mo)"
    fi
  else
    no "teeth-unrecognized-shape: mutant build failed (source lines not found)"
  fi

  echo "-- teeth-block-prefix: drop 'block' from the accepted prefix alternation; expect block(...) subjects to stop counting --"
  m="$(mutant block-prefix 's/\^(research|block)\\(/^(research)\\(/')"
  if grep -qF '^(research)\(' "$m"; then
    mo="$(bash "$m" --corpus "$ROOT/block-prefix" 2>&1)"
    if grep -qE '^C1 fail 0 block commits' <<<"$mo"; then
      ok "teeth-block-prefix: 'block' alternative dropped → block(...) subject no longer counts"
    else
      no "teeth-block-prefix: mutant did not flip C1 — no teeth ($mo)"
    fi
  else
    no "teeth-block-prefix: mutant build failed (source line not found)"
  fi

  echo "-- teeth-range-cap: drop the cap; expect the implausible B1000-B1200 range to explode N_BLOCKS to 201 --"
  m="$(mutant range-cap 's/if \[\[ "\$span" -gt 50 \]\]; then/if [[ "$span" -gt 999999 ]]; then/')"
  if grep -qF 'if [[ "$span" -gt 999999 ]]; then' "$m"; then
    mo="$(bash "$m" --corpus "$ROOT/range-cap" 2>&1)"
    if grep -qE '^C1 n/a 201 block commits' <<<"$mo"; then
      ok "teeth-range-cap: cap dropped → the implausible range explodes N_BLOCKS to 201"
    else
      no "teeth-range-cap: mutant did not flip C1 — no teeth ($mo)"
    fi
  else
    no "teeth-range-cap: mutant build failed (source line not found)"
  fi

  echo "-- teeth-stderr-merge: re-merge status-script stderr into stdout; expect a stderr WARN to break the STOP match --"
  m="$(mutant stderr-merge 's/2>"\$c4_err"/2>\&1/; s/2>>"\$c4_err"/2>\&1/')"
  if grep -qF 'status_default="$(bash "$STATUS_SCRIPT" "$CORPUS" 2>&1)"' "$m"; then
    mo="$(RSDD_STATUS_SCRIPT="$STUB_WARN_STDERR" bash "$m" --corpus "$ROOT/continue" \
      --transcript "$FIX/continue-clean.jsonl" 2>&1)"
    if grep -qE '^C4 fail' <<<"$mo"; then
      ok "teeth-stderr-merge: stderr re-merged into stdout → the WARN line breaks the STOP match"
    else
      no "teeth-stderr-merge: mutant did not flip C4 — no teeth ($mo)"
    fi
  else
    no "teeth-stderr-merge: mutant build failed (source line not found)"
  fi
fi

echo "== $pass passed · $fail failed =="
[ "$fail" -eq 0 ]
