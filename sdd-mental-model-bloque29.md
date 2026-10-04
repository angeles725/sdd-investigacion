# Block 29 — How gentle-ai manages issues and pull requests: templates, CI gates, parse-linked-issues, size policy, labels, measured tracker, triage skills

> **WHAT IT DOCUMENTS**: The human and CI machinery that governs issues and PRs in `Gentleman-Programming/gentle-ai` at v4.0.0: issue-first contribution rule, issue templates, the label taxonomy, the `pr-check.yml` jobs, the single parse seam `parse-linked-issues.cjs`, the two size gates (inline and `pull_request_target`), the AI-assistance policy, the triage skills that encode the maintainers' method, and a measured sample of the live tracker. It also compares each piece with the research-sdd kit's own `.github/`.
> **SCOPE**: Process and enforcement. It does NOT cover issues filed automatically by agents (see [Block 30]) nor the review lifecycle between components ([Block 31]).
> **SUBJECT VERSION**: gentle-ai v4.0.0 · tag sha `ff77164d` · 2026-10-01 (code and docs). Tracker samples taken 2026-10-04 (a snapshot; the tracker moves ~15 issues/day). Kit side: `origin/main` of the research-sdd kit at the time of writing.
> **SOURCES**: `CONTRIBUTING.md`, `AI_POLICY.md`, `.github/ISSUE_TEMPLATE/*`, `.github/PULL_REQUEST_TEMPLATE.md`, `.github/workflows/{pr-check,pr-size-policy,discord-notifications,release,promote-stable-rc}.yml`, `.github/scripts/{parse-linked-issues,check-pr-size}.cjs` and their tests, `.github/grandfather-size-exceptions.json`, `skills/*` and `internal/assets/skills/*` in the gentle-ai clone; live `gh label list` and `gh api` samples of the last 100 issues and 60 PRs (2026-09-28..10-04). Kit side: `.github/workflows/pr-check.yml`, `.github/PULL_REQUEST_TEMPLATE.md`, `.github/labels.yml`, `.github/ISSUE_TEMPLATE/`.
> **METHOD**: `[CERT]` = source bytes read (`path:line`), or a count computed in this session from the saved `gh` JSON; `[CERT-a]` = upstream-stated or fetched from GitHub but not recomputed; `[INFER]` = deduction. Sample figures are `measured` with the date, never persisted as constants (CLAUDE.md §5).
> **Type:** mixed

---

## 29.1 — The human workflow: issue first, approval second, PR third `[CERT]`

`CONTRIBUTING.md:24-41`: "No PR without an issue. No exceptions." Flow: open an issue from a template, wait for `status:approved`, comment to claim it, then open the PR. The bug template (`.github/ISSUE_TEMPLATE/bug_report.yml:1-24`) auto-applies `bug` + `status:needs-review` and makes the reporter tick a required checkbox "PRs will be rejected if the linked issue does not have status:approved". Blank issues are disabled and questions are routed to Discussions (`.github/ISSUE_TEMPLATE/config.yml:1-5`).

Label taxonomy (live `gh label list`, 30 labels at 2026-10-04) `[CERT]`:

| Family | Labels | Applied to |
|---|---|---|
| `type:*` | bug, feature, docs, refactor, chore, breaking-change | PRs (exactly one) |
| `status:*` | needs-review, approved, needs-design, needs-info | issues |
| `priority:*` | — | issues |
| gates and flow | `size:exception`, `no-merge`, `up-for-grabs` ("scoped, approved, ready for community"), `slop` (no description) | PRs/issues |
| machine origin | `gentle-report` ("Automated defect report"), `source:guided-report` ("in-product blocked-flow report guidance"), `rc-feedback` | issues |

`CONTRIBUTING.md:62-95` documents the first four groups. `[INFER]` The machine-origin labels are a newer layer: issue #5198 ("standardize taxonomy producers and contributor guidance", closed) is the visible origin `[CERT-a]`.

## 29.2 — AI policy `[CERT]`

`AI_POLICY.md` (62 lines): AI use is allowed and the human owns everything; the PR declaration states tool/model, scope and verification (`AI_POLICY.md:16-24`); AI must never receive `Co-Authored-By` or Signed-off-by credit (`AI_POLICY.md:28`); enforcement is "reviewer judgment only; no automated AI detection or disclosure gate" (`AI_POLICY.md:60-62`). The PR template has an exactly-one-of "None / Material assistance used" section (`.github/PULL_REQUEST_TEMPLATE.md:46-52`). `[INFER]` Agreement with the kit: CLAUDE.md §10 bans attribution trailers too.

## 29.3 — `pr-check.yml`: five jobs on every PR event `[CERT]`

Triggered on `pull_request` [opened, edited, synchronize, labeled, unlabeled]; 201 lines.

| Job | What it enforces | Lines |
|---|---|---|
| Check PR Cognitive Load | additions+deletions <= 400 unless label `size:exception` | `pr-check.yml:13-45` |
| Check Workflow Scripts | `node --test` on the two `.cjs` parsers | `:47-54` |
| Check Issue Reference | parses the PR body with `parseLinkedIssues`; fails closed on any error; needs >= 1 reference | `:56-95` |
| Check Issue Has status:approved | `needs: check-issue-reference`; fetches each referenced issue and fails unless it carries `status:approved` | `:97-139` |
| Check PR Has exactly one `type:*` label | label count == 1 | `:141-181` |

Design notes `[CERT]`: the approval job consumes the parser's JSON output rather than re-scanning the body, with a comment citing issue #1770 (`pr-check.yml:105-106`); the reference job parses the event payload, not a refetched body, because CodeRabbit rewrites the body after the event (`:72-75`). The failure text at `:128-130` points to the "canonical issue-creation workflow contract" and tells agents to "comment and wait" unless they hold a direct instruction and host capability `[CERT]` — the gate message is addressed to AI agents as much as to humans `[INFER]`.

## 29.4 — `parse-linked-issues.cjs`: the single parse seam `[CERT]`

102 lines, with a test file beside it (`.github/scripts/parse-linked-issues.test.cjs`), run by the "Check Workflow Scripts" job.

| Behaviour | Line |
|---|---|
| Keywords: closing `closes\|fixes\|resolves`, non-closing `refs` | `parse-linked-issues.cjs:5-8` |
| HTML comments stripped to `-->` or end of input so hidden references do not count (an unclosed `<!--` hides the rest, matching GitHub's rendering) | `:38-47` |
| Colon form accepted | — |
| Cross-repository `owner/repo#N` fails closed | `:27-31`, `:70-76` |
| Malformed `#12/extra` fails closed | `:33-36` |
| Same number as closing and non-closing: "ambiguous" error | `:78-93` |

`[INFER]` The two-class keyword set is what lets a PR reference an issue without closing it (`Refs #N`).

## 29.5 — Two size gates; the trusted one is dormant `[CERT]`

1. Inline gate: the 400-line check inside `pr-check.yml` (§29.3). `CONTRIBUTING.md:310` and `:330-349` bake the same 400-line heuristic into ODD forecasting and the PR checklist — the origin of the ~400-line work-unit rule seen in [Block 28] §28.3.
2. Trusted gate `pr-size-policy.yml` runs on `pull_request_target`, sparse-checks-out only `check-pr-size.cjs` and `grandfather-size-exceptions.json` from the DEFAULT branch (a PR cannot edit its own gate), reads live PR facts through the API and fails closed on any error (`pr-size-policy.yml:3-53`). The policy file schema is strictly validated: fixed version, limit fixed at 400, `enforcement` in {dormant, enforcing}, grandfathered PRs must lie inside an activation snapshot, duplicate JSON keys detected (`check-pr-size.cjs:5-60`).
3. State at v4.0.0: `enforcement` is `dormant` with empty lists (`.github/grandfather-size-exceptions.json:1-7`), so enforcement still comes from the inline check. `[INFER]` The dormant policy is infrastructure for a future "enforce on new PRs, grandfather in-flight ones" switch. The `.github` diff v2.2.0..v4.0.0 is +1648/−37 over 13 files, mostly this plus `windows-full-suite.yml` `[CERT-a]`.

Other workflows: `discord-notifications.yml` forwards release events (stable vs prerelease to different webhooks) and issue opened/closed/reopened only, with permissions `{}` and a regex-validated, masked webhook URL (`discord-notifications.yml:1-50`); `promote-stable-rc.yml` (workflow_dispatch with `source_prerelease_tag`, `stable_tag`, `release_environment_policy_id`) implements RC→stable promotion with provenance preflight (`promote-stable-rc.yml:1-30`). Those two are release management, not issue management; the `rc-feedback` label ties RC-window bug reports to the release flow `[INFER]`.

## 29.6 — Measured tracker sample (2026-09-28..2026-10-04) `[CERT]`

Raw JSON from `gh` was saved during the sweep; the figures below were re-computed with `jq` in this session unless marked.

| Measure | Value | Marker |
|---|---|---|
| Issues in sample | 100 (all states), created 2026-09-28T18:43Z .. 2026-10-04T18:54Z, ~15/day | measured |
| Distinct issue authors | 70 | measured |
| Carry `status:approved` | 24 of 100 | measured |
| Carry no label at all | 70 of 100 | measured |
| `type(scope): ...` titles | 77/100 by the sweep's regex; 82/100 by a looser regex re-run here (regex-dependent) | measured |
| Titles starting `[Automated provider defect]` | 9 of 100 | measured |
| Closed issues in sample | 23, median time-to-close 4.4 h | measured |
| PRs in sample | 60, created 2026-09-29..10-04, 16 authors | measured |
| PRs carrying `size:exception` | 16 of 60 | measured |
| PRs over 400 changed lines | 30 of 60; median size 404 | measured |
| Merged PRs | 33; median open-to-merge 0.63 h, p90 10.2 h | measured (median re-computed; p90 from sweep) |

Interpretation `[INFER]`: labels are applied mostly to maintainer-authored or approved issues, community bug reports sit unlabeled; the 400-line budget is routinely waived (27% of PRs; largest sampled #5242 at 13,095 lines, feature + exception), so the size gate is a speed bump with a maintainer-owned escape hatch, not a hard cap. Closed issues in the window were mostly maintainer work items closed by their own PR; one "filed from the wrong account" was closed. Duplicates are NOT closed with the `duplicate` label in this sample; the mechanism is "canonical tracker + occurrence comments" ([Block 30] §30.7). Visible parallel clusters by title: Pi review relay (#5233, #5226, #5225, #5206, #5201), OpenCode transport/plugin (#5213, #5208, #5192, #5185, #5184), `sync` re-adding/removing managed files (#5246, #5220, #5219, #5205) `[CERT-a]`; consolidation is done by the maintainer lane through the skills below, not by a bot `[INFER]`.

Limits: a 6.5-day window; most community reports were still open, so time-to-close for them is unmeasured (gap in RESEARCH-STATE).

## 29.7 — Skills that encode the triage method `[CERT]`

| Skill | Size | Method |
|---|---|---|
| `systemic-issue-triage` (`skills/systemic-issue-triage/SKILL.md:12-30`) | 52 lines | every issue goes in exactly one bucket: A superseded-by-design, B duplicate of a canonical tracker, C real new bug → root-cause cluster, D feature, E unclear; 2+ issues sharing a root get ONE fix; issues close against NAMED tests; over-engineering test: does it add a state, verb, flag, gate or parallel representation? |
| `issue-root-resolution` (`skills/issue-root-resolution/SKILL.md:12-55`) | 55 lines | read full bodies and comments; verify against current `origin/main` on the day; mechanism map with one `file:line` anchor per claim; rank fixes by what they DELETE; closure rules A fixed (commit AND test), B superseded by a recorded decision, C surface gone, D duplicate of a fixed issue; "when in doubt do not close" (borderline list); cluster meta-issue (#2471 style) with a row per root |
| `branch-pr` | 269 lines | issue-first PR creation |
| `chained-pr` | 50 lines | PRs over 400 lines → stacked slices |
| `work-unit-commits` | 98 lines | a commit is a reviewable unit with tests and docs |
| `comment-writer` | 74 lines | warm, direct comments |

`issue-creation` is cited by the CI error text but has no directory under the repo-root `skills/`; it ships instead as a bundled asset at `internal/assets/skills/issue-creation/SKILL.md` `[CERT]` (resolves the "external skill" suspicion of the sweep; see [Block 30] §30.6). "Closing while half is still true strands reporters" — the skill's rule is to comment naming both modes and close neither `[CERT]`.

## 29.8 — Kit comparison `[CERT]`

| Aspect | gentle-ai v4.0.0 | Kit (`origin/main`) |
|---|---|---|
| `pr-check.yml` | 201 lines, 5 jobs | 129 lines: Issue Reference, Issue Has status:approved, `type:*` label |
| Issue-reference parse | `parse-linked-issues.cjs` seam: strips HTML comments, `Refs`, fail-closed | inline `github-script`: `const issuePattern = /(?:closes\|fixes\|resolves)\s+#(\d+)/gi;` over the raw `body` (`.github/workflows/pr-check.yml`, Check Issue Reference step) |
| Size gate | inline 400 + dormant trusted policy | none (400 lines is doctrine only, CLAUDE.md §6) |
| Script tests | `node --test` job | none |
| Issue forms | bug, feature (+ config) | bug, feature, config, plus `kit_defect.yml` (agent-fileable) |
| Labels | 30 live, documented | `.github/labels.yml` (90 lines), documented, not auto-synced |
| Duplicate handling | canonical tracker + occurrence comments | per-retro issues deduped by signature (`stage-retro-issues.sh`); no occurrence comment |

**Verified kit finding (latent false-pass).** The kit's Check Issue Reference scans the raw PR body including HTML comments. `.github/PULL_REQUEST_TEMPLATE.md` carries instructional HTML comments at lines 14-16 and the line `Closes #` at line 18 with no number. Because the regex requires `\s+#(\d+)`, the bare template does not satisfy the gate today, but a comment such as `<!-- Closes #123 -->` (for example an example left in the template, or text pasted from a bot) WOULD satisfy it, since nothing strips comments; the Check Issue Has status:approved job repeats the same regex at lines 49-51, so a commented reference to ANY approved issue satisfies both gates `[CERT]` (workflow lines 24-26, template lines 14-18). gentle-ai closed the same hole in `parse-linked-issues.cjs:38-47`. The failure mode is a silent pass in an instrument whose job is to refuse (CLAUDE.md §7). It is latent: no mutation of the template has been shown to trigger it in production; the claim is about the gate's behaviour on that input, which is evident from the regex `[INFER]` (no executed repro here — an executed repro belongs to the adopting PR, [Block 33] rank 3).

## 29.9 — Open questions

- `[GAP]` Who applies `status:approved` (human, bot or agent)? Needs issue timeline events (`labeled` actor).
- `[GAP]` How duplicates actually close over 90 days: needs `closedAt` plus `state_reason` over a longer window.
- `[GAP]` Why `size:exception` is 27% and whether `pr-size-policy.yml` ever flips to `enforcing`: needs the commit history of `grandfather-size-exceptions.json`.
- `[GAP]` Label vs title-prefix coverage over 500+ issues (only a 200-issue label query was done; 4 labelled `gentle-report`).

## 29.10 — Connections

- **[Block 28]** — the 400-line work-unit heuristic and chained PRs (§28.3) are enforced here (§29.3, §29.5); B17 is the SDD-era description.
- **[Block 30]** — automated reports are 9% of the sample's titles; the machine-origin labels (§29.1) and the dedup path (§29.6) are analysed there.
- **[Block 31]** — the "comment and wait" agent-addressed gate text (§29.3) is the same design principle as provider authority over prompt prose.
- **[Block 32]** — the skills of §29.7 are part of the bundled install; the AI policy (§29.2) matches the kit's attribution rule.
- **[Block 33]** — adoption candidates: port the parse seam and fix the kit's comment-blind regex, the closure-evidence rule and cluster meta-issue.
- **[Block 24]** — `judgment-day` is a sibling review skill that this process does not replace.
