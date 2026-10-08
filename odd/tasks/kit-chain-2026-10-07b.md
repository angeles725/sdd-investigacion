# Kit chain 2026-10-07b — ship #1660, then the open backlog by destination file

Status: **CLOSED** (2026-10-08). 25 PRs merged (incl. this document's PRs). Open issues 46 → 36 (10 new
issues were filed during the chain: 5 by this chain, 6 by a concurrent niagara-research retro).

## Objective
Ship the held #1660 flip (verify-block ephemeral cites FAIL by default), then chain the remaining open backlog
grouped by destination file so writers own disjoint file sets, including improvements surfaced in retros/reviews.

## Authorization
Maintainer, 2026-10-07: ODD + RDD (consent always `granted`) + commit + push + PR + pr view + issues + merge;
chain units automatically without asking; accept Gentle AI prompts and run the review. The #1660 hold condition
was overridden (recorded on #1660). Maintainer asked to close the session after the in-flight units (2026-10-08).

## Routes and models
Writers: sonnet, harness worktrees, disjoint file sets. Per PR: writer verification (shellcheck, pipefail lint,
focused suites + `--prove-teeth`, `run-all.sh -j 4`), RDD on the PR range, Opus adversarial review (≤3 rounds),
parent spot check, merge through `merge-gate.sh --merge` (CI green required). Strict TDD; doc-only units use
structural readback.

## Tasks (all done)
- [x] T0 feature document → #1957 (open), this PR (close).
- [x] T1 #1660 ephemeral FAIL default → #1956 (superseded held #1952; force-push is blocked).
- [x] T2 backlog mapping (read-only explorer).
- [x] #1963 parse-linked-issues dropped a valid `Closes` line → #1964 (3 Opus rounds; one-pass CommonMark tokenizer).
- [x] #1965 indented code blocks → #1975.
- [x] #1538 n4-type-catalog advisories (test-only) → #1966.
- [x] #1787 (+ #1576/#1299 parts) teeth strengthening → #1967.
- [x] #1277 slice 3 clean-check retention scans (report-only) → #1968.
- [x] #1271 doc close-out, #1550, #1159 init follow-ups → #1969 (#1159 closed by hand: item 4 lived in #1154).
- [x] #1640 covers_through retro checkpoint → #1970.
- [x] #1887 archive per-section-agent import-commit exemption → #1971.
- [x] #1536, #1645 run-all advisories, `--keep-tmp`, CLAUDE.md §5 sync → #1972.
- [x] #1517/#1548 lint-block calibration (refs; deferred items keep them open) → #1973.
- [x] #1361 verify-state unblock/stretch WARNs (+ doctrine) → #1974.
- [x] #1704 slice 2 reason-code input-class scan (refs) → #1976.
- [x] #1943 ensure-remote Layer 4c allow list (security; positive identification over all history blobs) → #1977.
- [x] #1617, #1958, #1960, #1961 doc + #1277 doctrine → #1979.
- [x] #1157 registered-never-loaded hook state (refs; TARGETS legend is maintainer-only) → #1980.
- [x] #1033 installer `--uninstall` → #1981.
- [x] #1962 verify-block back-pointer WARN (default high-confidence, 76% hand-measured precision) → #1982.
- [x] #1116 retro deltas decided, #1003 slice 1 → #1983.
- [x] #965 census `--state` cross-check (opt-in; refs) → #1984; follow-up #1986.
- [x] #1214 lint-block child-gap pack R4 (new pack) → #1985.
- [x] #1959 STOP `[backlog-unreadable: N rows]` qualifier, #1145 head family measured safe → #1987; follow-up #1995.
- [x] Doctrine/registry sync for merged instruments → #1994.
- [x] #1978 verify-skill-drift-hook load flake → #1996.
- [x] #1937 closed (already delivered).

## Decisions (defaults applied on the maintainer's "don't ask")
- #1271: pre-push hook + CI suffice, no pre-commit hook. #1277: retention scans report-only, no hard gate, 14-day default.
- #1704: "every refusal line prints its exit command" dropped. #1711 and #1787 items 5/7 closed as not applicable.
- #1943: implement the allow list. #1033: implement uninstall. #993: Qwen eval deferred to the operator.
- #1958: operator-pasted console output is `[CERT-live]` (consistent with #633). #1959: qualifier is non-terminal.
- #1960: generic plugin-channel rule. #1961: doctrine first; the `.ps1` lives only on bench pruebas-01.
- #1962: WARN-only; default prints only the high-confidence shape (`--backptr=high|all|off`).

## Remaining open (36) — next session
- Kit, ready: #1614 (status resume queue), #923 (shared blocked-rows lib), #1675 (lib resolution lint — last;
  touches many scripts), #1986, #1995, #1003 (further slices), #1365 (R2 generic, verify-block wiring),
  #1517/#1548/#1576/#1299/#1704/#1711 (deferred items), #1277 (remaining), #965 (wire `--state` into PROMPT-LOOP /
  verify-state / archive), #1157 (TARGETS legend — maintainer).
- New retro issues from a concurrent niagara-research session: #1988–#1993 (need triage; #1988 is high).
- Other repos: #1924–#1929. Operator: #1650–#1656 (ephemeral cites in target corpora, now FAIL by default), #993.

## Operator follow-ups (target corpora; the kit never edits them)
- Clean or `ephemeral-ok`-mark ephemeral cites (#1650–#1656); verify-block FAILs on them by default (opt-out
  `--ephemeral=warn`).
- Retro marker flips listed in #1983's PR body (nave-panccadia, niagara-research).
- panccadia-3d-viewer: `--next` reports `[backlog-unreadable: 29 rows]` (no-Priority-header table under a near-miss
  `## Outline` heading) — confirm whether it is a backlog.
- Still open from the previous chain: `.env` stores in mini-pc / Pancaddia / HotelHilton; niagara-research
  covered_blocks; COB-IM2 root count; three.js G71.

## Process lessons
- A PR body's `Closes #N` could be silently dropped when inline code contained `<!--` (#1963, fixed).
- CI requires the referenced issue to carry `status:approved` and exactly one `type:*` label on the PR.
- RDD stop-hook candidates during a writer's mid-edit are not reviewable; review the committed candidate.
- A low-risk RDD START can close immediately with an `acknowledgement` block (no lenses).
- Opus gates found real fail-opens in most PRs (the security gate #1977 needed 3 rounds); keep the gate.
- Concurrent doc PRs on tool-registry.md conflict at merge time; merge `origin/main` into the branch (no force push).
