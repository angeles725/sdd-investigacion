# Vendored third-party content: gentle-ai SDD phase agents and skills

The following kit files are copies of Spec-Driven Development (SDD) assets that `gentle-ai`
(https://github.com/Gentleman-Programming/gentle-ai) deployed into `~/.claude/` up to and including
version 4.0.0. From 4.1.0 `gentle-ai sync` retired SDD and deletes those files, so the kit versions them
here and deploys them under its own `research-sdd-phase-` namespace (kit issue #2351).

| Kit path | Upstream source (as deployed by gentle-ai <= 4.0.0) |
|---|---|
| `research-sdd/agents/claude/research-sdd-phase-<phase>.md` (11) | `~/.claude/agents/sdd-<phase>.md` |
| `research-sdd/skills/research-sdd-phase-<phase>/**` (11 dirs) | `~/.claude/skills/sdd-<phase>/**` |
| `research-sdd/skills/research-sdd-phase-shared/*.md` (8) | `~/.claude/skills/_shared/{sdd-phase-common,openspec-convention,sdd-orchestrator-sections,sdd-orchestrator-workflow,sdd-status-contract,skill-resolver,engram-convention,research-lifecycle}.md` |

`<phase>` is one of: apply, archive, design, explore, init, onboard, propose, research, spec, tasks, verify.

## Modifications

Byte copies except identifier and path renames, nothing else:

- frontmatter `name: sdd-<phase>` becomes `name: research-sdd-phase-<phase>`;
- `~/.claude/skills/sdd-<phase>/` becomes `~/.claude/skills/research-sdd-phase-<phase>/`;
- the eight shared files (the five SDD ones plus the three the phase skills reference) moved from `~/.claude/skills/_shared/` to `~/.claude/skills/research-sdd-phase-shared/`
  (file names unchanged), and every path reference to them was updated;
- an agent reference `sdd-<phase>` becomes `research-sdd-phase-<phase>`; the `sdd-*` skip pattern in the init
  registry-scan rule names the renamed skills.

Left unchanged on purpose: the concept word "SDD", openspec paths, `gentle-ai` CLI commands and schema names
(`gentle-ai sdd-status`, `sdd-continue`, `sdd-archive-compose`, `sdd-task-result`), slash-command names
(`/sdd-new`, `/sdd-explore`, `/gentle-sdd-*`), the `sdd-orchestrator-section` and `gentle-ai:sdd-session-preflight`
comment markers, and the bare file names `sdd-phase-common.md` etc. The kit test
`research-sdd/install/tests/research-sdd-install.test.sh` pins this boundary with a static guard.

## License

The vendored files are distributed under the upstream MIT license:

```
MIT License

Copyright (c) 2025 Gentleman Programming

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
