/**
 * research-sdd-sweep — OpenCode plugin adapter for the Research-SDD session-start surfacing
 *
 * Claude Code surfaces sweep results when the SUPERVISOR project (the kit repo, sdd-investigacion)
 * opens, wired from that project's `.claude/settings.json` SessionStart hooks:
 *   1. `sweep-retros.sh`          — pending §18 self-retrospective proposals across all targets.
 *   2. `sweep-audits.sh`          — pending §13 audit reports per target.
 *   3. `sweep-breakthroughs.sh`   — unindexed/drifted §22 breakthrough ledger entries.
 *   4. `verify-registry.sh`       — TARGETS.md master-table drift.
 *   5. `verify-kit-clean.sh`      — a banner ONLY when the kit is dirty / unpushed (silent when clean).
 *   6. `sweep-tools.sh`           — unrecorded tools across all targets.
 *
 * OpenCode does not fire `.claude` hooks, so those banners never appeared there — the kit
 * maintainer could open the supervisor in OpenCode and miss pending retros or a dirty tree. This
 * plugin is the OpenCode equivalent: it runs the SAME kit scripts and appends their output to
 * the model's system context, the OpenCode analog of a Claude hook's `additionalContext`.
 *
 * Canonical source lives in the KIT (`research-sdd/toolbelt/opencode/`); a symlink under
 * `~/.config/opencode/plugins/` makes OpenCode load it (one-authority-no-copies: edit it here).
 *
 * Design:
 *   - Surfaces ONLY when the session's working directory is inside the kit repo (the supervisor),
 *     mirroring the Claude hook which is wired per-project to sdd-investigacion — never for a
 *     target-corpus session.
 *   - Fires once per session (a Set guard), on the first `experimental.chat.system.transform`.
 *   - Read-only: the scripts never mutate anything; a script failure degrades to silence, never
 *     blocks OpenCode startup or a turn.
 */

import type { Plugin } from "@opencode-ai/plugin"
import { execFile } from "child_process"
import { promisify } from "util"
import { realpath } from "fs/promises"
import { realpathSync } from "fs"
import { fileURLToPath } from "url"
import path from "path"

const execFileAsync = promisify(execFile)

// Resolve the kit dir: honor $RESEARCH_SDD_KIT (points at the research-ssd dir) first.
// When unset, derive from the module's own canonical location by following any symlink
// (e.g. ~/.config/opencode/plugins/ symlink → real toolbelt/opencode/ → ../../ = research-sdd/).
// The catch MUST return a non-null string — path.join(KIT_DIR, ...) runs at module scope
// and a null/undefined KIT_DIR would throw TypeError at import time, blocking OpenCode startup.
export function deriveKitDir(): string {
  try {
    const self = realpathSync(fileURLToPath(import.meta.url))
    return path.resolve(path.dirname(self), "..", "..")
  } catch {
    return "/nonexistent-research-sdd-kit"  // benign: underKitRepo's realpath fails → false → silence
  }
}
const KIT_DIR = process.env.RESEARCH_SDD_KIT ?? deriveKitDir()
const TOOLBELT = path.join(KIT_DIR, "toolbelt")
const SWEEP = path.join(TOOLBELT, "sweep-retros.sh")
const SWEEP_AUDITS = path.join(TOOLBELT, "sweep-audits.sh")
const SWEEP_BREAKTHROUGHS = path.join(TOOLBELT, "sweep-breakthroughs.sh")
const REGISTRY = path.join(TOOLBELT, "verify-registry.sh")
const KIT_CLEAN = path.join(TOOLBELT, "verify-kit-clean.sh")
const SWEEP_TOOLS = path.join(TOOLBELT, "sweep-tools.sh")

async function underKitRepo(dir: string): Promise<boolean> {
  // The supervisor repo root = parent of the research-sdd kit dir. Surface only when the session's
  // directory is that repo (or a subdir of it), so target-corpus sessions stay quiet.
  try {
    const repoRoot = await realpath(path.dirname(KIT_DIR))
    const here = await realpath(dir)
    return here === repoRoot || here.startsWith(repoRoot + path.sep)
  } catch {
    return false
  }
}

async function run(cmd: string): Promise<{ out: string; code: number }> {
  try {
    const { stdout } = await execFileAsync(cmd, [], { timeout: 20_000, maxBuffer: 1024 * 1024 })
    return { out: stdout.trimEnd(), code: 0 }
  } catch (err: any) {
    // Non-zero exit still carries stdout on `err.stdout` (execFile convention). A genuine numeric
    // exit flows through as-is (exit 1 IS a real "not clean"); a NON-numeric err.code — a spawn
    // failure (ENOENT: script missing/not executable) or the 20s timeout, where err.code is a string
    // errno or null — maps to sentinel 2 ("could not run"), matching verify-kit-clean.sh's exit code,
    // so buildBanner() renders the "could not run — misconfigured path" banner instead of falsely
    // reporting a clean kit as "NOT clean" (which is what code:1 would trigger).
    return { out: (err?.stdout ?? "").toString().trimEnd(), code: typeof err?.code === "number" ? err.code : 2 }
  }
}

export const ResearchSddSweepPlugin: Plugin = async (input) => {
  const sessionDir = input.directory || input.worktree || process.cwd()
  const surfaced = new Set<string>()

  async function buildBanner(): Promise<string | null> {
    if (!(await underKitRepo(sessionDir))) return null

    const parts: string[] = []

    // 1. Retro sweep — always show its listing (it reports "0 pending" honestly when clean).
    const sweep = await run(SWEEP)
    if (sweep.out) parts.push("Research-SDD retro sweep (supervisor project):\n" + sweep.out)

    // 2. Audit sweep — pending §13 audit reports per target (same fail-safe: silent on error).
    const audits = await run(SWEEP_AUDITS)
    if (audits.out) parts.push("Research-SDD pending audits (per-target §13):\n" + audits.out)

    // 3. Breakthrough ledger — unindexed/drifted §22 breakthrough entries (WARN-only, exit 0).
    const breakthroughs = await run(SWEEP_BREAKTHROUGHS)
    if (breakthroughs.out) parts.push("Research-SDD breakthrough ledger (§22):\n" + breakthroughs.out)

    // 4. Registry reconcile — master-table 'N md' vs the real corpus block count (WARN-only, exit 0).
    const registry = await run(REGISTRY)
    if (registry.out) parts.push("Research-SDD registry drift (TARGETS.md vs reality):\n" + registry.out)

    // 5. Kit-clean — mirror verify-kit-clean-hook.sh: silent on clean (code 0), banner otherwise.
    const clean = await run(KIT_CLEAN)
    if (clean.code !== 0) {
      const hdr =
        clean.code === 1
          ? "Research-SDD KIT is NOT clean — commit/stash + push before staging §18 retros (else the retro branch/PR mixes unrelated history):"
          : `Research-SDD kit-clean check could not run (exit ${clean.code} — misconfigured path or not a git repo):`
      parts.push(hdr + "\n" + clean.out)
    }

    // 6. Tool ledger — mirror sweep-tools-hook.sh: silent when all tools ledgered, summary otherwise.
    const tools = await run(SWEEP_TOOLS)
    if (tools.code !== 0) {
      parts.push(`Research-SDD tools sweep could not run (exit ${tools.code}):\n` + tools.out)
    } else {
      const summaryMatch = tools.out.match(/^Summary:.*$/m)
      if (!summaryMatch) {
        if (tools.out) parts.push("Research-SDD tools sweep: missing Summary line:\n" + tools.out)
      } else {
        const unrecordedMatch = summaryMatch[0].match(/(\d+) unrecorded/)
        const unrecorded = unrecordedMatch ? parseInt(unrecordedMatch[1], 10) : 0
        if (unrecorded > 0) {
          const warnMatch = tools.out.match(/^WARN:.*$/m)
          const detail = summaryMatch[0] + (warnMatch ? "\n" + warnMatch[0] : "") +
            "\nRun toolbelt/sweep-tools.sh for per-target breakdown."
          parts.push("Research-SDD tool ledger (unrecorded tools found):\n" + detail)
        }
      }
    }

    return parts.length ? parts.join("\n\n") : null
  }

  return {
    "experimental.chat.system.transform": async (transformInput, output) => {
      const sid = transformInput.sessionID ?? "no-session"
      if (surfaced.has(sid)) return
      surfaced.add(sid)
      try {
        const banner = await buildBanner()
        if (banner) output.system.push(banner)
      } catch (err) {
        // Never let a surfacing failure break the turn.
        console.error("[research-sdd-sweep] surfacing failed:", err)
      }
    },
  }
}

export default ResearchSddSweepPlugin
