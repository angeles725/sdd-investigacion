// research-sdd-hooks.ts — pi / gentle-shell extension: the Claude Code hooks of the research-sdd kit.
//
// Deployed by research-sdd/install/research-sdd-install.sh to <agent home>/extensions/research-sdd-hooks.ts
// (pi and gentle-shell only; kit issue #2123). Pi has no settings.json hooks, so this extension gives the
// session what the Claude wiring gives a research target:
//
//   SessionStart  -> session_start        the eight compact sweep hooks (toolbelt/*-hook.sh, one of which is the
//                                         skill-drift + `research-sdd-install.sh --verify` hook) run in the background;
//                                         the session-start git sha the retro gate keys on is recorded.
//   (context)     -> before_agent_start   the stored sweep/drift output is injected into the MODEL's system prompt
//                                         sections on EVERY run (pi rebuilds the sections per run), bounded < 8,000 chars.
//   Stop          -> agent_before_settle  retro-gate.sh, then return-token-gate.sh; ONLY when outcome === "completed"
//                                         and no continuation is queued; a block is returned once as {entries, continue:true}.
//   PreToolUse    -> tool_call            bash commands that mention pkill/pgrep go through the kit's pkill-guard script.
//
// Rules this file keeps (each one is a defect of the hand-written niagara-research extension, kit issue #2128):
//   - child sessions (GENTLE_PI_AGENTS_CHILD=1) register nothing;
//   - the session id, TARGET, kit and every block-once flag are recomputed on EVERY session_start, never at module load;
//   - TARGET is ctx.cwd and the kit is resolved at run time (RESEARCH_SDD_KIT, the launcher's `Kit checkout:` / `Kit path:`
//     line, the render dir's toolbelt symlink) — no path is baked in;
//   - every external call has a timeout, and a missing script / unresolvable kit / empty transcript yields a typed
//     `degraded` line in the context (or a notice entry), never a silent allow (CLAUDE.md section 7);
//   - a handler that throws never breaks the session.
//
// Opt-out: RSDD_PI_HOOKS=0|off|false. Timeouts: RSDD_PI_SWEEP_TIMEOUT_MS (45000), RSDD_PI_GATE_TIMEOUT_MS (120000).
// Erasable TypeScript only (no enums / parameter properties), so Node's type stripping can run it headlessly.
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { execFile } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, readdirSync, realpathSync, statSync, unlinkSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { dirname, join } from "node:path";

const SECTION_KEY = "research-sdd-session";
const NOTICE_TYPE = "research-sdd-hooks";
const SWEEP_HOOKS = [
  "sweep-retros-hook", "sweep-audits-hook", "sweep-breakthroughs-hook", "verify-registry-hook",
  "verify-kit-clean-hook", "sweep-tools-hook", "verify-tool-catalog-hook", "verify-skill-drift-hook",
];
const DRIFT_HOOK = "verify-skill-drift-hook";
const MAX_CONTEXT_CHARS = 7500; // openspec/specs/kit-session-cost/spec.md: SessionStart output < 8,000 chars in total
const MAX_REASON_CHARS = 4000;

interface RunResult { code: number | null; stdout: string; stderr: string; timedOut: boolean; error: string }
interface KitResolution { kit: string; tried: string[] }
interface HookState {
  sid: string; target: string; home: string; kit: string; tried: string[]; corpus: boolean;
  startup: Promise<string>; notices: string[]; noticed: Set<string>; retroBlocked: boolean; tokenBlocked: boolean;
}

function envMs(name: string, dflt: number): number {
  const n = Number(process.env[name]);
  return Number.isFinite(n) && n >= 1 ? n : dflt;
}

// Async on purpose (a sync exec would freeze the pi TUI) and bounded: resolves, never rejects.
function run(file: string, args: string[], o: { cwd?: string; input?: string; timeoutMs: number }): Promise<RunResult> {
  return new Promise((resolve) => {
    try {
      const child = execFile(file, args, { cwd: o.cwd, timeout: o.timeoutMs, killSignal: "SIGKILL", maxBuffer: 4 * 1024 * 1024, encoding: "utf8" },
        (err, stdout, stderr) => {
          const e = err as { code?: unknown; killed?: boolean } | null;
          resolve({
            code: e ? (typeof e.code === "number" ? e.code : null) : 0,
            stdout: String(stdout ?? ""), stderr: String(stderr ?? ""),
            timedOut: !!e?.killed, error: e && typeof e.code === "string" ? e.code : "",
          });
        });
      child.stdin?.on("error", () => {});
      child.stdin?.end(o.input ?? "");
    } catch (e) {
      resolve({ code: null, stdout: "", stderr: "", timedOut: false, error: String(e) });
    }
  });
}

function withTimeout<T>(p: Promise<T>, ms: number, fallback: T): Promise<T> {
  return new Promise((resolve) => {
    const t = setTimeout(() => resolve(fallback), ms);
    t.unref?.();
    p.then((v) => { clearTimeout(t); resolve(v); }, () => { clearTimeout(t); resolve(fallback); });
  });
}

const safeId = (raw: unknown): string => String(raw).replace(/[^A-Za-z0-9._-]/g, "_").slice(0, 80);

function agentHome(): string {
  return process.env.GENTLE_PI_AGENT_HOME || process.env.PI_CODING_AGENT_DIR || join(homedir(), ".pi", "agent");
}

function isDir(p: string): boolean {
  try { return statSync(p).isDirectory(); } catch { return false; }
}

// Kit resolution, first hit wins: $RESEARCH_SDD_KIT, the launcher block's `Kit checkout:` then `Kit path:` line in
// <agent home>/AGENTS.md (written by the installer), then the render dir's toolbelt symlink. The result is the
// CANONICAL checkout (the realpath of its toolbelt dir's parent), so a stale render copy is never run.
function resolveKit(home: string): KitResolution {
  const tried: string[] = [];
  const cands: Array<[string, string]> = [];
  if (process.env.RESEARCH_SDD_KIT) cands.push(["$RESEARCH_SDD_KIT", process.env.RESEARCH_SDD_KIT]);
  try {
    const text = readFileSync(join(home, "AGENTS.md"), "utf8");
    const block = text.match(/<!-- research-sdd:start -->([\s\S]*?)<!-- research-sdd:end -->/);
    for (const key of ["Kit checkout", "Kit path"]) {
      const m = block?.[1].match(new RegExp("^" + key + ":\\s*(.+?)\\s*$", "m"));
      if (m) cands.push([`${join(home, "AGENTS.md")} "${key}:"`, m[1].replace(/^~(?=\/|$)/, homedir())]);
    }
  } catch { tried.push(`${join(home, "AGENTS.md")} (no readable launcher block)`); }
  try {
    const pdir = join(home, "research-sdd", "profile");
    for (const name of readdirSync(pdir)) cands.push([`render dir ${join(pdir, name)}`, join(pdir, name)]);
  } catch { /* no render dir: the profile may be "claude" */ }
  for (const [label, dir] of cands) {
    if (!isDir(join(dir, "toolbelt"))) { tried.push(`${label} -> ${dir} (no toolbelt/)`); continue; }
    let canon = dir;
    try { canon = dirname(realpathSync(join(dir, "toolbelt"))); } catch { /* keep the unresolved path */ }
    return { kit: canon, tried };
  }
  if (!cands.length) tried.push("$RESEARCH_SDD_KIT unset");
  return { kit: "", tried };
}

function isCorpus(target: string): boolean {
  try { return readdirSync(target).some((n) => /^RESEARCH-STATE.*\.md$/.test(n) && !n.endsWith(".template.md")); } catch { return false; }
}

const harnessOf = (home: string): string => (home.includes(".gentle-shell") ? "gentle-shell" : "pi");

function degradedKitText(st: HookState): string {
  return `Research-SDD session hooks DEGRADED: the kit is not resolvable (tried: ${st.tried.join("; ") || "nothing"}), so the session sweeps, ` +
    `the retro gate and the pkill guard did NOT run. Fix: re-run the installer, e.g. bash <kit checkout>/install/research-sdd-install.sh --harness ${harnessOf(st.home)}.`;
}

function additionalContextOf(out: string): string {
  const t = out.trim();
  if (t.startsWith("{")) {
    try {
      const j = JSON.parse(t);
      const c = j?.hookSpecificOutput?.additionalContext ?? j?.additionalContext;
      if (typeof c === "string") return c.trim();
    } catch { /* plain text that merely starts with a brace */ }
  }
  return t;
}

async function collectStartup(st: HookState): Promise<string> {
  if (!st.kit) return degradedKitText(st);
  const timeoutMs = envMs("RSDD_PI_SWEEP_TIMEOUT_MS", 45000);
  const results = await Promise.all(SWEEP_HOOKS.map(async (name) => {
    const script = join(st.kit, "toolbelt", name + ".sh");
    if (!existsSync(script)) return { name, degraded: `script missing at ${script}`, text: "" };
    const r = await run("bash", [script], { cwd: st.target, timeoutMs });
    if (r.timedOut) return { name, degraded: `timed out after ${Math.round(timeoutMs / 1000)}s`, text: "" };
    if (r.error) return { name, degraded: `could not run (${r.error})`, text: "" };
    const text = additionalContextOf(r.stdout) || additionalContextOf(r.stderr);
    if (r.code !== 0) return { name, degraded: `exit ${r.code}`, text };
    return { name, degraded: "", text };
  }));
  const bad = results.filter((r) => r.degraded);
  const withText = results.filter((r) => r.text);
  const lines = [
    `Research-SDD session sweep (kit ${st.kit}): ${results.length - bad.length} of ${results.length} hooks ran, ${withText.length} with findings` +
      (bad.length ? `, ${bad.length} DEGRADED` : "") + ".",
  ];
  for (const r of bad) lines.push(`[${r.name}] degraded: ${r.degraded}` + (r.text ? ` — ${r.text.split("\n")[0].slice(0, 160)}` : ""));
  // Fair share when over budget: each hook is cut to its slice, then the whole is cut as a last resort.
  const budget = MAX_CONTEXT_CHARS - lines.join("\n").length - 300;
  const total = withText.reduce((n, r) => n + r.text.length + r.name.length + 4, 0);
  const slice = Math.max(200, Math.floor(budget / Math.max(1, withText.length)));
  let cut = false;
  for (const r of withText) {
    if (r.degraded) continue;
    let body = r.text;
    if (total > budget && body.length > slice) { body = body.slice(0, slice) + `\n…[truncated +${r.text.length - slice} chars]`; cut = true; }
    lines.push(`[${r.name}] ${body}`);
  }
  if (results.find((r) => r.name === DRIFT_HOOK && r.text)) {
    lines.push(`Drift fix (re-renders the deployed skill, launcher and this extension): bash ${st.kit}/install/research-sdd-install.sh --harness ${harnessOf(st.home)}`);
  }
  let out = lines.join("\n");
  if (out.length > MAX_CONTEXT_CHARS) { out = out.slice(0, MAX_CONTEXT_CHARS - 200); cut = true; }
  if (cut) out += `\n[truncated to fit the SessionStart budget — run bash ${st.kit}/toolbelt/sweep-all.sh for the full report]`;
  return out;
}

async function recordSessionSha(st: HookState): Promise<void> {
  const file = join(st.target, ".claude", `.rsdd-session-${st.sid}`);
  try { if (existsSync(file) && statSync(file).size > 0) return; } catch { /* fall through and rewrite */ }
  const r = await run("git", ["-C", st.target, "rev-parse", "HEAD"], { timeoutMs: 5000 });
  const sha = r.stdout.trim();
  if (!/^[0-9a-f]{40,64}$/.test(sha)) {
    st.notices.push("Research-SDD retro gate: no session-start git sha could be recorded (not a git checkout?); it will use its mtime fallback (degraded).");
    return;
  }
  mkdirSync(dirname(file), { recursive: true });
  writeFileSync(file, sha + "\n");
}

function parseBlock(out: string): string | null {
  const i = out.indexOf("{");
  if (i < 0) return null;
  try {
    const j = JSON.parse(out.slice(i));
    if (j?.decision === "block") return String(j.reason ?? "blocked (no reason given)").slice(0, MAX_REASON_CHARS);
    return null;
  } catch {
    return /"decision"\s*:\s*"block"/.test(out) ? out.slice(0, 600) : null;
  }
}

const textOf = (content: unknown): string => {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content.filter((b) => b && b.type === "text" && typeof b.text === "string").map((b) => b.text).join("\n");
};

// Pi's session file is not Claude-shaped, and return-token-gate.sh parses `{"type":"assistant","message":{"content":[...]}}`
// lines — so the last assistant text is handed over in that shape in a private temp file. null = nothing to hand over.
function writeTranscript(sid: string, ctx: any, event: any): string | null {
  let msgs: any[] = [];
  try { msgs = (ctx?.sessionManager?.getBranch?.() ?? []).map((e: any) => e?.message ?? e); } catch { msgs = []; }
  if (!msgs.length) msgs = event?.context?.contextMessages ?? [];
  let last = "";
  for (const m of msgs) if (m?.role === "assistant") last = textOf(m.content) || last;
  if (!last) return null;
  const file = join(tmpdir(), `rsdd-pi-transcript-${sid}-${process.pid}.jsonl`);
  writeFileSync(file, JSON.stringify({ type: "assistant", message: { role: "assistant", content: [{ type: "text", text: last }] } }) + "\n", { mode: 0o600 });
  return file;
}

const entry = (content: string) => ({ type: "custom_message" as const, customType: NOTICE_TYPE, content, display: true });

function freshState(): HookState {
  return { sid: "", target: "", home: "", kit: "", tried: [], corpus: false, startup: Promise.resolve(""), notices: [], noticed: new Set(),
    retroBlocked: false, tokenBlocked: false };
}

export default function (pi: ExtensionAPI) {
  if (process.env.GENTLE_PI_AGENTS_CHILD === "1") return; // child sessions never run hooks
  if (/^(0|off|false|no)$/i.test(process.env.RSDD_PI_HOOKS ?? "")) return;

  let st = freshState();
  const note = (msg: string) => { if (st.notices.length < 5) st.notices.push(msg); };
  const guard = async <T,>(name: string, fn: () => Promise<T>): Promise<T | undefined> => {
    try { return await fn(); } catch (e) { note(`Research-SDD hooks DEGRADED: ${name} failed (${String((e as Error)?.message ?? e).slice(0, 200)}).`); return undefined; }
  };
  const noticeOnce = (key: string, msg: string) => {
    if (st.noticed.has(key)) return [];
    st.noticed.add(key);
    return [entry(msg)];
  };

  pi.on("session_start", async (_event, ctx) => {
    await guard("session_start", async () => {
      let sid = "";
      try { sid = safeId(ctx.sessionManager.getSessionId()); } catch { /* fall back below */ }
      if (!sid) sid = safeId(`pi-${Date.now()}-${process.pid}`);
      const next = freshState(); // session id, kit, flags: recomputed on EVERY session_start (never at module load)
      next.sid = sid; next.target = ctx.cwd || process.cwd(); next.home = agentHome();
      const res = resolveKit(next.home);
      next.kit = res.kit; next.tried = res.tried; next.corpus = isCorpus(next.target);
      st = next;
      st.startup = collectStartup(st).catch((e) => `Research-SDD session sweep DEGRADED: ${String(e).slice(0, 200)}`);
      if (st.corpus) await recordSessionSha(st);
    });
  });

  pi.on("before_agent_start", async (event) => {
    await guard("before_agent_start", async () => {
      const cur = st;
      const wait = envMs("RSDD_PI_SWEEP_TIMEOUT_MS", 45000) + 5000;
      const sweep = await withTimeout(cur.startup, wait, "Research-SDD session sweep DEGRADED: still running after the timeout; its output is not in this context.");
      const text = [sweep, ...cur.notices].filter(Boolean).join("\n");
      if (!text) return;
      if (!event?.systemPromptOptions?.sections) throw new Error("event.systemPromptOptions.sections missing");
      event.systemPromptOptions.sections[SECTION_KEY] = text; // every run: pi rebuilds the sections per run
    });
  });

  pi.on("agent_before_settle", async (event, ctx) => {
    return guard("agent_before_settle", async () => {
      if (event.outcome !== "completed" || event.continue) return undefined; // Stop-equivalent: only a real, final completion
      const cur = st;
      if (!cur.corpus) return undefined; // the gates are per research target (Claude wires them per target)
      if (!cur.kit) {
        const e = noticeOnce("kit", degradedKitText(cur));
        return e.length ? { entries: e } : undefined;
      }
      const gateMs = envMs("RSDD_PI_GATE_TIMEOUT_MS", 120000);
      const notices: ReturnType<typeof entry>[] = [];
      const hookJson = (extra: object) => JSON.stringify({ session_id: cur.sid, cwd: cur.target, stop_hook_active: false, ...extra });

      if (!cur.retroBlocked) {
        const script = join(cur.kit, "toolbelt", "retro-gate.sh");
        if (!existsSync(script)) notices.push(...noticeOnce("retro-missing", `Research-SDD retro gate DEGRADED: script missing at ${script}; the retro was NOT checked.`));
        else {
          const r = await run("bash", [script, cur.target], { cwd: cur.target, input: hookJson({}), timeoutMs: gateMs });
          const reason = parseBlock(r.stdout);
          if (reason) { cur.retroBlocked = true; return { entries: [entry(reason)], continue: true }; }
          if (r.timedOut || r.error) notices.push(...noticeOnce("retro-run", `Research-SDD retro gate DEGRADED: ${r.timedOut ? `timed out after ${Math.round(gateMs / 1000)}s` : `could not run (${r.error})`}; the retro was NOT checked.`));
        }
      }

      if (!cur.tokenBlocked) {
        const script = join(cur.kit, "toolbelt", "return-token-gate.sh");
        let transcript: string | null = null;
        try { transcript = writeTranscript(cur.sid, ctx, event); } catch { transcript = null; }
        if (!existsSync(script)) notices.push(...noticeOnce("token-missing", `Research-SDD return-token gate DEGRADED: script missing at ${script}; the continuation token was NOT checked.`));
        else if (!transcript) notices.push(...noticeOnce("token-transcript", "Research-SDD return-token gate skipped (degraded): pi exposed no assistant text to check the continuation token against."));
        else {
          try {
            const r = await run("bash", [script, cur.target], { cwd: cur.target, input: hookJson({ transcript_path: transcript }), timeoutMs: Math.min(gateMs, 40000) });
            const reason = parseBlock(r.stdout);
            if (reason) { cur.tokenBlocked = true; return { entries: [entry(reason)], continue: true }; }
            if (r.timedOut || r.error) notices.push(...noticeOnce("token-run", `Research-SDD return-token gate DEGRADED: ${r.timedOut ? "timed out" : `could not run (${r.error})`}; the continuation token was NOT checked.`));
          } finally { try { unlinkSync(transcript); } catch { /* already gone */ } }
        }
      }
      return notices.length ? { entries: notices } : undefined;
    });
  });

  pi.on("tool_call", async (event) => {
    if (event.toolName !== "bash") return undefined;
    const command = (event.input as { command?: unknown } | null)?.command;
    if (typeof command !== "string" || !/pkill|pgrep/.test(command)) return undefined;
    const cur = st;
    const degraded = (why: string) => ({ block: true, reason: `pkill-guard DEGRADED (${why}): refusing a command that mentions pkill/pgrep because it cannot be checked for a self-matching -f pattern (it would kill this session, exit 144). Use pkill -x, a PID file, or a bracket-escaped pattern.` });
    try {
      const script = cur.kit ? join(cur.kit, "templates", "hook-pretool-pkill-guard.sh") : "";
      if (!script || !existsSync(script)) return degraded(cur.kit ? `script missing at ${script}` : "kit not resolvable");
      const r = await run("bash", [script], { cwd: cur.target || undefined, input: JSON.stringify({ tool_name: "Bash", tool_input: { command }, cwd: cur.target }), timeoutMs: 5000 });
      if (r.timedOut || r.error) return degraded(r.timedOut ? "timed out" : r.error);
      const out = JSON.parse(r.stdout.trim() || "null")?.hookSpecificOutput;
      if (out && (out.permissionDecision === "deny" || out.permissionDecision === "ask")) {
        return { block: true, reason: String(out.permissionDecisionReason ?? "pkill-guard refused this command").slice(0, MAX_REASON_CHARS) };
      }
      return undefined;
    } catch (e) {
      return degraded(String((e as Error)?.message ?? e).slice(0, 120));
    }
  });
}
