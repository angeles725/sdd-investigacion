# Kit session 2026-09-25b — chained backlog continuation

Objective: drain the "Next session" agenda of `kit-session-2026-09-25.md` plus accumulated improvement issues, in chain, automatically.
Authorization: ODD + RDD (consent granted for every candidate), commit, push, PR, issues, merge.
TDD: strict; runner `bash research-sdd/toolbelt/tests/run-all.sh [--prove-teeth]` from a normal clone root.
Delivery strategy: auto-chain; one PR per work unit, based on `origin/main`.
Base: `origin/main` = `a78b010`.

## Tasks
- [x] T1 PR #1140 (#1135 wired-off-root) r2 e745af2: fresh-clone gate, RDD, Opus re-review, merge — route: delegated (worktree writer).
- [x] T2 PR #1141 (#1128 reverse hook check) 36f8ed4 (CI failing): rebase onto #1140 after merge, gate, RDD, Opus, merge — route: delegated, serial after T1.
- [x] T3 PR #1142 (#1121 quoting lint) 496e2ff: rebase onto main (install/ scan), fresh-clone gate, RDD, Opus re-review, merge — route: delegated.
- [ ] T4 #1112 METHODOLOGY 8-delta batch — route: delegated (writer owns METHODOLOGY.md).
- [ ] T5 #1145 SIGPIPE family + review nits — route: delegated after T3 (toolbelt overlap).
- [x] T6 #1114, #1116, #1003 slice 2 — triage then writers by destination file.
- [ ] T7 quiet-tree gate on final main + session close.

## Progress / evidence
- Mapper: #1112 all 8 deltas ABSENT (writer after #1140, METHODOLOGY overlap; item 2 also touches fetch-doc.sh). #1114 open (init + PROMPT-LOOP preflight) → writer launched (disjoint). #1116: 4 markers flipped early still `applied` in target repos, 2 pending with live D1 deltas on METHODOLOGY. #1145 still open (133 sites in 2 test suites; chained). #1003: F07 item already gone; L2 split still open (400+ lines, PROMPT-LOOP overlap with #1114).
- T1 writer running on #1140 (worktree).
- T1 #1140 rebased 28a0e74 (no code change; r2 findings verified fixed), gate 134/134 suites 5069 cases 0 failed, shellcheck 0/236. RDD + Opus r3 running.
- T1 RDD lineage review-be1c6bc7dddea7df (risk high, 4R): correction_required — CRITICAL R3/R4 relative-path infinite loop in _hw_find_git_root. Correction plan captured (60 lines); writer resumed for the one bounded correction.
- T1 Opus r3 CHANGES_REQUIRED: B1 = RDD loop; B2 follow-ups untracked → filed #1150; M1 '..' false off-root, M2 symlink leaf doc, M3 ceiling trailing slash + nits → second commit after RDD correction.
- T6a #1114 → PR #1151 (9e8a0c7): --document flag + RESEARCH-STATE-document template + PROMPT-LOOP preflight; RED verified, gate 134/134 5058 cases, shellcheck 0. RDD + Opus running.
- #1151 RDD APPROVED + acknowledged (review-40b5f36317134777, high, 4R). WARNINGs: M-DOC tooth can pass if mutant crashes (x2); SUGGESTIONs: doc template required on default path, --document silently ignored on wire-only repair, 'below' comment, re-seed assertion vacuous. Waiting Opus.
- #1151 Opus CHANGES_REQUIRED (3 MEDIUM: SEED line in doc mode, Coverage metric stale-denominator WARN, status gap verdicts → follow-up #1152; 2 LOW + nits) → writer round 2.
- #1151 round 2 d9f9a19 (+288/-35): all Opus r1 + RDD warnings addressed; RED 10 fails right reason; gate 134/134 5081 cases; init suite 293/0 teeth. RDD (base 9e8a0c7) + Opus r2 running.
- #1151 RDD r2 APPROVED + acked (review-00129dc4c4e5d841). Non-blocking: WARNING <N> placeholder ambiguity (template:57); SUGGESTIONs: duplicated guard condition, review-label citations in shipped comments, GOOD 8 digit-free check timing. Waiting Opus r2.
- #1151 Opus r2 CHANGES_REQUIRED: all r1 fixed; MEDIUM-NEW-1 rejection message recommends destructive --force (wipes INDEX/hooks/backlog) + nits → writer round 3.
- #1140 RDD: correction (67d1e8a, 83 lines) validated + acked review-be1c6bc7dddea7df (full 296-line range exceeded the 200 budget → validated the correction commit alone, detached). Second commit 08456df reviewed as its own candidate: approved + acked review-bffdac5afc8a7c28. Opus r4 running.
- #1140 Opus r4 APPROVE (fleet: verify-registry byte-identical, sweep-retros only three.js lines). Non-blocking (symlink-before-.. regression, here-string read unchecked, wording) → #1153. Waiting CI then merge.
- MERGED #1140 → b49c22e (CI green). Shared checkout synced. Launched: T2 #1141 rebase writer, T4 #1112 writer (METHODOLOGY + fetch-doc.sh) — disjoint. #1142 waits for #1141 (verify-registry.sh overlap).
- #1151 RDD r3 APPROVED + acked (review-9b843bf28886c6da). Non-blocking test-quality: --force-destructive proof weak (HAND sentinel, unwired corpus so hook clobber not proven), M-MEDNEW1 hard-codes message, residual review labels, _treesum GNU sha256sum dependency. Waiting Opus r3.
- #1151 Opus r3 CHANGES_REQUIRED: MEDIUM-R3-1 note mentioning 'Coverage metric' is matched by status.sh loose grep → stale-denominator WARN returns; filed #1154 for the instrument. Round 4 sent (template reword, GOOD 8 fixture, RDD test-quality items).
- T2 #1141 rebased c961e67 (conflict in verify-registry.test.sh resolved; CI fail on 36f8ed4 was the expected pre-#1140 fixture 3s); gate 134/134 5089; fleet diff: 3 new reverse WARNs (fluke-177x-datos, nave-panccadia, panccadia-3d-viewer) — possible conflict with #1147 row vocabulary → Opus asked to decide. RDD running.
- #1141 RDD APPROVED + acked (review-59594bd66f17a83c). WARNINGs (teeth): offroot-widen tooth only echoes SKIP on baseline regression (claims fail-closed); reverse-check tooth never checks 'Registry consistent' line nor unmutated baseline WARNs; attention tooth copies the WARN block verbatim. Waiting Opus.
- T4 #1112 → PR #1155 (c85e1eb, +145): 8/8 deltas applied, fetch-doc.sh registers url_effective (RED/GREEN/mutant), hotcore 884/920, gate 134/134 5079. RDD + Opus running. Filed #1156 (install suite writes mutants into live tree).
- #1155 RDD APPROVED + acked (review-95de822e47ca28f1). WARNINGs fetch-doc.sh: registers short-lived signed redirect URLs (S3/GitHub assets); 2>/dev/null swallows curl errors (-S useless); console prints requested URL vs registry effective; wget path registers requested URL contradicting doctrine. Waiting Opus.
- #1155 Opus CHANGES_REQUIRED: R1 web mode not fixed (D4 rows are web-snapshots), R2 §5 self-contradiction, R3 §8/§18 vs §7 counter/§20b journal, R4 signed temporary URLs; S1-S3. Decision: resolve permanent redirects (301/308) only, stop at temporary; both modes; stderr notice. → writer round 2.
- #1141 Opus r3 CHANGES_REQUIRED: 3 fleet WARNs are false positives vs #1147/legend. Decision (a): narrow reverse check to 'hook no' only; vocabulary gap → #1157. Round 4 sent with RDD teeth fixes.
- #1151 RDD r4 APPROVED + acked (review-3f8dd7682541e80a); only SUGGESTIONs (leftover mlow2 var names, new round tags in comments, no mutant for the one-label guard, --sync-state exit unchecked). Waiting Opus r4.
- #1151 Opus r4 CHANGES_REQUIRED: MEDIUM-R3-1 fixed; LOW-R4-1 wired fixture made 'nothing written' check toothless → round 5 (split fixtures) + nits + RDD suggestions. #1154 addendum: stale state sticky via pick().
- #1141 r4 2edda22: reverse check narrowed to 'hook no'; fleet verify-registry byte-identical to main (0 new WARNs); teeth fixed (fail-closed, baseline asserted, sentinel-scoped sed) + case tooth 3t; gate 134/134 5092. RDD + Opus r4 running.
- #1141 RDD r4 APPROVED + acked (review-be1faef18c8f44e5). WARNINGs: 3t case tooth lacks baseline-WARN assertion + reversed label; 3s 'hook no' + wired-off-root asserts no WARN (semantics questionable). Waiting Opus r4.
- #1155 r2 a06d6f6: resolve_permanent_redirect() (301/308 only, 10-hop cap) in doc+web; §5/§8/§18 reconciled; wget notice; stderr kept; fetch-doc 35/0 teeth; hotcore 889/920; gate 134/134 5096. RDD + Opus r2 running.
- #1155 RDD r2 APPROVED + acked (review-8cc120818fbe5fe9). WARNINGs: no scheme check on Location (file:// etc.), probe is full GET w/o max-time (double download), duplicated doc/web blocks, redirect notice printed before download (contradicts wget notice), awk getline-count mutants fragile. Waiting Opus r2.
- #1155 Opus r2 CHANGES_REQUIRED: RR1 doc-mode resolution untested, RR2 tool-registry.md:83 prescribes curl -L url_effective; RS1 double download, RS2 -L untested, RS3 hop bound untested, RS4, RS5 doc overstates. Decision: HEAD probe w/ max-time, fallback ranged GET on 405/501; http/https allowlist; '|' → %7C. Round 3 sent.
- #1151 r5 3d48f16: fixtures split (M-WIRE-DOC-REJECT 3→4 failures), sticky WARN wording, renames, negative control, exit-0; gate 134/134 5095. RDD + Opus r5 running. #1155 r3 sent (HEAD probe, scheme allowlist, dedupe, tests).
- MERGED #1141 → 6369e5b (Opus r4 APPROVE, CI green; retitled; nits → #1158). #1151 Opus r5 APPROVE (nits → #1159); added type:feature + Closes #1114, waiting CI. Launched T3 #1142 writer (rebase + real-corpus enumeration).
- MERGED #1151 → 82d597b (#1114; RDD r1-r5 acked, Opus r5 APPROVE, CI green). Shared checkout synced.
- T5 #1145 slice 1 writer launched (research-sdd-status.test.sh + score-loop-transcript.test.sh). #1116 deferred until #1155 merges (its open deltas land in METHODOLOGY.md, owned by #1155 now); niagara session closed, repo still has 2 uncommitted non-retro files (not ours).
- T6b #1003 L2 slice 1 writer launched (PROMPT-LOOP split plan + first self-contained move).
- Health check: nothing frozen; load ~12 from 4 concurrent gates + a user niagara session running bfs over / (incl. /mnt/c). Filed #1161: verify-state/retro-gate hermetic-bin helpers mirror the whole ambient PATH (63 /mnt/c dirs on WSL, system32 ~5.3k entries), fork basename per exe.
- T5 #1145 slice 1 → PR #1162 (a004ee4): 195 sites (124+71) → here-strings; per-case PASS/FAIL byte-identical before/after (plain + teeth); gate 134/134 5141. No lint guard (lint-substitution owned by #1142). RDD + Opus running.
- #1162 RDD APPROVED (review-5d50ba7cad8245c0, no findings) + Opus APPROVE (195/195 1:1, per-case identical). Remaining #1145 sites commented on #1145. PR check needs Closes: created sub-issue #1163 (slice 1) and linked. Waiting CI.
- MERGED #1162 → 7925f90 (#1145 slice 1 / #1163). Shared checkout synced.
- T6b #1003 L2 slice 1 → PR #1164 (d194618): 218-line delegation/verify/model-tier block → PROMPT-LOOP-APPENDIX.md, 7-slice plan in body; gate 133/134 with score-loop-transcript failing under 4 concurrent gates — re-run 5/5 green (81/81) at load ~2; quiet-tree gate at close will re-check. RDD + Opus running (key question: are moved rules truly situational).
- #1164 first RDD (review-20e8f6e5823e5f34) diffed against main incl. #1162 → stale-base artifacts (fake here-string reverts). Rebased to fc80572 (only 2 PROMPT-LOOP files), re-running RDD. Lesson: rebase every branch onto the newest main before RDD (assess base = origin/main).
- #1164 RDD (rebased, medium, 1 lens) APPROVED + acked review-991b1a38e68ce60a. WARNING: pointer's trigger list (delegate / verify sub-agent report) + 'not needed for small inline gap' misses rules that apply inline (e.g. FALSIFY BEFORE REPORTING, REACHABLE≠REPRESENTATIVE). SUGGESTION: appendix cross-refs to PROMPT-LOOP sections unnamed. Waiting Opus.
- #1155 r3 0ef948d → rebased d2a1977 on 7925f90: HEAD probe + ranged GET fallback, http/https allowlist, shared fetch_and_register, notice after download, %7C, loop/308/303/307 tests, 26 verified mutants; gate 134/134 5123. RDD (base 2f6115d) + Opus r3 running.
- #1155 RDD r3 APPROVED + acked (review-fde064eb8b573370). WARNINGs: wget failure unchecked inside $(…) (errexit off) → registers an undownloaded doc; HEAD rejected with 403/404 or 200-without-redirect not falling back to GET; METHODOLOGY 'notices mutually exclusive' false when network down; 501/000 branches untested. Waiting Opus r3.
- #1164 Opus CHANGES_REQUIRED: F1 inline-applicable rules gated behind delegation trigger; F2 appendix read nearly every iteration (little saving); F3 breaks openspec kit-doctrine-grammar D3 (SECRETS inline override); F4 stale refs; F5 no consistency check. Decision/rule: move a rule only if trigger narrower than most iterations AND never inline. Rework sent.
- #1155 Opus r3 CHANGES_REQUIRED (Q1 §5 notices claim false; Q2 resolve-notice mutant is a syntax error) + nits N1-N4; real-curl loopback matrix OK. Round 4 sent incl. RDD wget-exit, HEAD 403/404 fallback, connect-timeout, bash -n in mkmut.
- T3 #1142 r3 b7f1ba4 → rebased 4343ddd on 7925f90: independent enumeration 0 unquoted-risk (FORM-A 158 cands, FORM-B 88); fixed run-all.test Mutations 9/10/12 flat workdir (#1144 interaction); gate 135/135 5115; fleet byte-identical. RDD + Opus running (Opus writes own tokenizer-based enumerator).
- #1142 RDD APPROVED + acked (review-da5d4dd646daadc7). WARNINGs: lint-substitution fails open on grep read/traversal errors (stderr to /dev/null, status unchecked); scan-secrets M4 awk-FS check looser than the regex it replaced (tabs accepted) while comment claims 'exactly as strict'; run-all.test case 33 cannot detect the stdout-only fix. Waiting Opus. (User asked to close session after in-flight work.)
- #1142 Opus r2 CHANGES_REQUIRED: lint misses unquoted $ after a prefix (retro-gate.sh:210) + 9 undeclared forms; fails open on unreadable files; case 13 cannot prove install/ scanned. Verified: mawk is_dirty_marker, scan-secrets fixes real SHA-256 bug on stock mawk. Round 4 sent.
- #1164 r2 46c6325: rework under the rule — 110 lines moved (7 narrow groups, named triggers), 108 back to core; SECRETS override in core (D3); SKILL.md names appendix; verify-doc-consistency covers appendix (TDD + mutant); slice plan: #1003 L2 effectively complete. Gate 134/134 5146 (score-loop-transcript flake not reproduced). RDD + Opus r2 running.
- #1164 RDD r2 APPROVED + acked (review-16421d1e8c5eb9fb). WARNING: verify-doc-consistency Summary prints the appendix as 'checked' unconditionally; test 23 'anti-silent-zero' only matches that literal. SUGGESTIONs: pointer trigger lists duplicated (already drifted), long-build pointer nested under MODEL TIER, anchors unchecked. Waiting Opus r2.
- #1164 Opus r2 CHANGES_REQUIRED: 4 blocks still apply inline (HIDDEN-FLAG CROSS-CHECK, decommission/live-state falsify, PHYSICAL-ACTION FACTS, WEB-RESEARCH DISCOVERY-ONLY) → back to core; test 23 toothless; yield −5.3% → ~−3.5% after fix; L2 close = descoping decision. Round 3 sent.
- #1155 r4 6563d82 pushed by orchestrator AFTER explicit user authorization ('sube commit'); writer's own push had been denied by the classifier. RDD (base d2a1977) + Opus r4 running.
- #1155 RDD r4 APPROVED + acked (review-ff767f26272a0200). WARNINGs: exit 28 treated as connect failure but also fires on --max-time on a slow reachable server (skips GET fallback); stale PROBE-FAIL comment; failed wget leaves partial dest file. Waiting Opus r4.
- #1155 Opus r4 CHANGES_REQUIRED: R1 failed wget leaves 0-byte dest / leaked temp (exit 1 skips cleanup); S1 5 mkmut callers score empty mutant as kill; exit-28 overclaim. Real curl/wget matrix otherwise OK. Round 5 sent (commit, one push attempt).
- User pre-authorized the orchestrator to push the #1155 round-5 commit if the writer's push is denied by the classifier (2026-09-25b, explicit message).
- #1142 r4 f095670: FORM-A any-position trigger, retro-gate.sh:210 quoted, fail-closed exit 2, case 13 independent count, M4 strictness restored + mawk test, case 33 discriminating; writer claims 2 Opus-enumerator rows are enumerator FPs (to be verified); gate 135/135 5172; fleet byte-identical. RDD (base 4343ddd) + Opus r3 running.
- #1142 RDD r4 APPROVED + acked (review-c35ef30cff0fa5df). WARNINGs: lint find captured with 2>&1 into the file list; retro-gate.sh:210 quoted replacement differs on bash <4.3; test LAST_CASE_NUM still hardcoded despite comment; mawk-absent test counted as pass. Waiting Opus r3.
- #1164 r3 e00441f: 4 inline blocks back to core (31 lines), triggers re-synced, summary derives checked/absent, test 23 real, CHECK 5 anchors; yield −3.57% lines / −3.79% bytes; L2 close recorded as descoping. Gate 134/134 5151. Final RDD + Opus running (last round before close).
- #1164 RDD r3 APPROVED (review-149d19a198211611) + Opus r3 APPROVE; created sub-issue #1165 (L2 descoped close), nits → #1166; waiting CI to merge.
- MERGED #1142 → 50a15b1 (#1121; RDD r4 acked, Opus r3 APPROVE incl. independent enumerator reconciliation; nits → #1167). Shared checkout synced.

## Close (2026-09-25b)
- Merged (6): #1140 (b49c22e, #1135), #1141 (6369e5b, #1128), #1151 (82d597b, #1114), #1162 (7925f90, #1145 slice 1 / #1163), #1142 (50a15b1, #1121), #1164 (#1003 L2 descoped close / #1165 — merged by the close job after CI).
- Open: PR #1155 (#1112 METHODOLOGY 8 deltas + fetch-doc permanent-redirect resolution). Round 4 head 6563d82 pushed with user authorization; Opus r4 CHANGES_REQUIRED (R1 failed wget leaves 0-byte dest / temp leak; S1 5 mkmut callers score empty mutant as kill; exit-28 overclaim). A round-5 writer was running at close in worktree agent-abc7e3cd6d1aba132 — check `git log origin/docs/1112-methodology-delta-batch` for a newer commit; the user pre-authorized pushing the round-5 commit if the writer's push was denied. Next: RDD (base = last reviewed commit) + Opus r5 → merge.
- Issues opened this session: #1150 #1152 #1153 #1154 #1156 #1157 #1158 #1159 #1161 #1163 #1165 #1166 #1167.
- Quiet-tree gate: not run at close (session token budget); CI toolbelt-tests + shellcheck were green on every merged PR. Run the full local gate first thing next session.

## Lessons (session 2026-09-25b)
1. Rebase every branch onto the newest main BEFORE RDD — assess diffs against origin/main, so a stale base shows fake reverts of merged work (#1164 first RDD).
2. RDD correction budget (200 lines) covers the correction diff only: validate the correction commit alone (detached at it, re-query exact-lineage STATUS), then review extra commits as their own candidate.
3. pr-check.yml requires `(closes|fixes|resolves) #N` + a type:* label + status:approved on the issue; for a slice of a larger issue create a slice sub-issue and close that.
4. A writer whose push is denied by the classifier must not be pushed for by the orchestrator without explicit user authorization (asked and received for #1155).
5. Every review round found real defects (loop hang, destructive --force advice, signed URLs, silent-zero lints, rules gated behind the wrong trigger). Keep RDD + Opus on every candidate; independent enumerators beat fixture tests (§7).
6. Long sessions are expensive: every agent notification re-reads the whole context. Keep sessions shorter and fewer concurrent writers; batch reviews.

## Next session
1. PR #1155: finish round 5 (see above), RDD + Opus, merge.
2. Run the full local quiet-tree gate on main (`run-all.sh --prove-teeth` + shellcheck toolbelt+install); investigate any score-loop-transcript flake (#129 class).
3. #1116 (retro marker corrections + 2 open niagara deltas) — unblocked once #1155 merges (METHODOLOGY).
4. #1145 remaining sites (3 decision-bearing pipe-fed guards), #1161 (hermetic-bin PATH mirroring on WSL), #1156 (install suite writes mutants into live tree), #1157 (hook vocabulary doctrine).
5. Follow-up hygiene batches: #1150 #1152 #1153 #1154 #1158 #1159 #1166 #1167 — group by destination file.
