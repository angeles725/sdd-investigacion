// research-sdd-hooks.ts — pi / gentle-shell extension: the Claude Code hooks of the research-sdd kit.
//
// Deployed by research-sdd/install/research-sdd-install.sh to <agent home>/extensions/research-sdd-hooks.ts
// (pi and gentle-shell only; kit issue #2123). Pi has no settings.json hooks, so this extension gives the
// session what the Claude wiring gives a research target:
//
//   SessionStart  -> session_start        the eight compact sweep hooks (toolbelt/*-hook.sh, one of which is the
//                                         skill-drift + `research-sdd-install.sh --verify` hook) start in the background;
//                                         the session-start git sha the retro gate keys on is recorded.
//   (context)     -> before_agent_start   the sweep/drift output is injected into the MODEL's system prompt sections
//                                         on EVERY run (pi rebuilds the sections per run). The first run waits at most
//                                         RSDD_PI_SWEEP_WAIT_MS (3 s) for the sweeps; if they are not done it injects a
//                                         typed "pending" line and the next run picks the result up. The final injected
//                                         string is capped under the 8,000-char SessionStart budget.
//   Stop          -> agent_before_settle  retro-gate.sh, then return-token-gate.sh; ONLY when outcome === "completed"
//                                         and no continuation is queued; a block is returned once as {entries, continue:true}
//                                         appended to the entries other extensions already put on the event.
//   PreToolUse    -> tool_call            bash / bash_background / monitor commands that mention pkill/pgrep go through the
//                                         kit's pkill-guard script; anything but a well-formed allow is a block.
//
// Rules this file keeps (each one is a defect of the hand-written niagara-research extension, kit issue #2128):
//   - child sessions (GENTLE_PI_AGENTS_CHILD=1) register nothing;
//   - the session id, TARGET, kit and every block-once flag are recomputed on EVERY session_start, never at module load;
//   - TARGET is ctx.cwd and the kit is resolved at run time (RESEARCH_SDD_KIT, the launcher's `Kit checkout:` / `Kit path:`
//     line, the render dir's toolbelt symlink) — no path is baked in;
//   - every external call has a timeout that kills its whole process group; a missing script / unresolvable kit / failing
//     or crashing gate / empty transcript yields a typed `degraded` line (context or settle entry), never a silent allow
//     (CLAUDE.md section 7);
//   - a handler that throws never breaks the session, and the failure is surfaced (ctx.ui.notify + the next settle entries).
//
// Opt-out: RSDD_PI_HOOKS=0|off|false. Timeouts: RSDD_PI_SWEEP_TIMEOUT_MS (45000), RSDD_PI_GATE_TIMEOUT_MS (120000).
// Erasable TypeScript only (no enums / parameter properties), so Node's type stripping can run it headlessly.
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { spawn } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, realpathSync, rmSync, statSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { dirname, join } from "node:path";

const SECTION_KEY = "research-sdd-session";
const NOTICE_TYPE = "research-sdd-hooks";
const SWEEP_HOOKS = [
  "sweep-retros-hook", "sweep-audits-hook", "sweep-breakthroughs-hook", "verify-registry-hook",
  "verify-kit-clean-hook", "sweep-tools-hook", "verify-tool-catalog-hook", "verify-skill-drift-hook",
];
const DRIFT_HOOK = "verify-skill-drift-hook";
const SHELL_TOOLS = new Set(["bash", "bash_background", "monitor"]); // tools whose `command` input runs in a shell
const MAX_CONTEXT_CHARS = 7500; // the sweep text alone
const MAX_INJECT_CHARS = 7900; // the FINAL injected string (sweep + notices); openspec kit-session-cost: < 8,000 chars
const MAX_NOTICES = 5;
const MAX_NOTICE_CHARS = 300;
const MAX_REASON_CHARS = 4000;
const MAX_OUTPUT_CHARS = 4 * 1024 * 1024;
const FORCE_RESOLVE_MS = 500; // grace after a kill / an exit before run() resolves without waiting for the pipes to close

interface RunResult { code: number | null; signal: string; stdout: string; stderr: string; timedOut: boolean; error: string }
interface KitResolution { kit: string; tried: string[] }
interface HookState {
  sid: string; target: string; home: string; kit: string; tried: string[]; corpus: boolean; startedAt: string;
  startup: Promise<string>; sweepText: string | null; notices: string[]; surface: string[]; noticed: Set<string>;
  retroBlocked: boolean; tokenBlocked: boolean;
}

function envMs(name: string, dflt: number): number {
  const n = Number(process.env[name]);
  return Number.isFinite(n) && n >= 1 ? n : dflt;
}

const tailOf = (s: string): string => s.trim().split("\n").slice(-2).join(" | ").slice(0, 240);

// Async on purpose (a sync exec would freeze the pi TUI) and bounded: resolves, never rejects. The child is spawned as
// its own process group (execFile does not honour `detached`), and a timeout kills the WHOLE group, so a grandchild the
// script spawned cannot outlive it.
function run(file: string, args: string[], o: { cwd?: string; input?: string; timeoutMs: number }): Promise<RunResult> {
  return new Promise((resolve) => {
    let settled = false;
    let timedOut = false;
    let timer: ReturnType<typeof setTimeout> | undefined;
    let stdout = "";
    let stderr = "";
    const finish = (r: Partial<RunResult>) => {
      if (settled) return;
      settled = true;
      if (timer) clearTimeout(timer);
      resolve({ code: null, signal: "", stdout, stderr, timedOut, error: "", ...r });
    };
    try {
      const child = spawn(file, args, { cwd: o.cwd, detached: true, stdio: ["pipe", "pipe", "pipe"] });
      const killGroup = () => {
        try { process.kill(-(child.pid as number), "SIGKILL"); } catch { try { child.kill("SIGKILL"); } catch { /* already gone */ } }
      };
      const cap = (cur: string, chunk: Buffer) => (cur.length < MAX_OUTPUT_CHARS ? cur + chunk.toString("utf8") : cur);
      child.stdout?.on("data", (c: Buffer) => { stdout = cap(stdout, c); });
      child.stderr?.on("data", (c: Buffer) => { stderr = cap(stderr, c); });
      // A grandchild that escaped the group (setsid, a daemonizing tool) can hold stdout/stderr open forever, and then
      // 'close' never fires. So run() also resolves FORCE_RESOLVE_MS after the child's 'exit' or after the timeout kill,
      // with the output collected so far, and drops the pipes.
      const forceFinish = (r: Partial<RunResult>) => {
        const t = setTimeout(() => { child.stdout?.destroy(); child.stderr?.destroy(); finish(r); }, FORCE_RESOLVE_MS);
        t.unref?.();
      };
      child.on("error", (e: NodeJS.ErrnoException) => finish({ error: String(e.code ?? e.message) }));
      child.on("exit", (code: number | null, signal: string | null) => forceFinish({ code, signal: signal ?? "" }));
      child.on("close", (code: number | null, signal: string | null) => finish({ code, signal: signal ?? "" }));
      timer = setTimeout(() => { timedOut = true; killGroup(); forceFinish({}); }, o.timeoutMs);
      child.stdin?.on("error", () => {});
      child.stdin?.end(o.input ?? "");
    } catch (e) {
      finish({ error: String(e) });
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
  const shown = st.tried.slice(0, 4).map((t) => t.slice(0, 120));
  const more = st.tried.length > shown.length ? `; +${st.tried.length - shown.length} more` : "";
  return `Research-SDD session hooks DEGRADED: the kit is not resolvable (tried: ${shown.join("; ") || "nothing"}${more}), so the session sweeps, ` +
    `the retro gate and the pkill guard did NOT run. Fix: re-run the installer, e.g. bash <kit checkout>/install/research-sdd-install.sh --harness ${harnessOf(st.home)}.`;
}

// Notices are short typed lines shown in the context; the list is capped, and so is each line.
function pushNotice(st: HookState, msg: string): void {
  if (st.notices.length < MAX_NOTICES) st.notices.push(msg.slice(0, MAX_NOTICE_CHARS));
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
    if (r.code !== 0) return { name, degraded: r.signal ? `killed by ${r.signal}` : `exit ${r.code}`, text };
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

// The FINAL string handed to the model: notices first-class (they are short and typed), the sweep cut to what is left.
function finalContext(sweep: string, notices: string[]): string {
  const marker = "\n[truncated: SessionStart budget — run the kit's toolbelt/sweep-all.sh for the full report]";
  const noticeText = notices.map((n) => n.slice(0, MAX_NOTICE_CHARS)).slice(0, MAX_NOTICES).join("\n");
  const room = MAX_INJECT_CHARS - (noticeText ? noticeText.length + 1 : 0);
  const body = sweep.length > room ? sweep.slice(0, Math.max(0, room - marker.length)) + marker : sweep;
  return [body, noticeText].filter(Boolean).join("\n");
}

async function recordSessionSha(st: HookState): Promise<void> {
  const file = join(st.target, ".claude", `.rsdd-session-${st.sid}`);
  try { if (existsSync(file) && statSync(file).size > 0) return; } catch { /* fall through and rewrite */ }
  const r = await run("git", ["-C", st.target, "rev-parse", "HEAD"], { timeoutMs: 5000 });
  const sha = r.stdout.trim();
  if (!/^[0-9a-f]{40,64}$/.test(sha)) {
    pushNotice(st, "Research-SDD retro gate: no session-start git sha could be recorded (not a git checkout?); it will use its mtime fallback (degraded).");
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

// A gate run is a block, a typed degraded notice, or a clean allow. A non-zero exit, a signal, a timeout or a spawn
// failure without block JSON is NEVER a quiet allow, and a degraded allow the script reports on stderr is surfaced too.
function gateVerdict(label: string, r: RunResult, ms: number): { block?: string; notice?: string } {
  const block = parseBlock(r.stdout);
  if (block) return { block };
  const unchecked = `the ${label.includes("retro") ? "retro" : "continuation token"} was NOT checked`;
  if (r.timedOut) return { notice: `Research-SDD ${label} DEGRADED: timed out after ${Math.round(ms / 1000)}s; ${unchecked}.` };
  if (r.error) return { notice: `Research-SDD ${label} DEGRADED: could not run (${r.error}); ${unchecked}.` };
  if (r.code !== 0) {
    return { notice: `Research-SDD ${label} DEGRADED: ${r.signal ? `killed by ${r.signal}` : `exit ${r.code}`} without a verdict` +
      `${tailOf(r.stderr) ? ` (${tailOf(r.stderr)})` : ""}; ${unchecked}.` };
  }
  const deg = r.stderr.split("\n").find((l) => /branch=degraded/.test(l));
  if (deg) return { notice: `Research-SDD ${label} ran degraded: ${deg.trim().slice(0, 200)}` };
  return {};
}

const textOf = (content: unknown): string => {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content.filter((b) => b && b.type === "text" && typeof b.text === "string").map((b) => b.text).join("\n");
};

// Pi's session file is not Claude-shaped, and return-token-gate.sh parses `{"type":"assistant","message":{"content":[...]}}`
// lines — so the last assistant text is handed over in that shape. The file lives in a fresh 0700 directory (mkdtemp, an
// unpredictable name) and is created exclusively (flag "wx", mode 0600), so a pre-planted path or symlink is never followed.
// The caller removes the directory in a finally. null = nothing to hand over (and nothing was created).
function writeTranscript(ctx: any, event: any): { dir: string; file: string } | null {
  let msgs: any[] = [];
  try { msgs = (ctx?.sessionManager?.getBranch?.() ?? []).map((e: any) => e?.message ?? e); } catch { msgs = []; }
  if (!msgs.length) msgs = event?.context?.contextMessages ?? [];
  let last = "";
  for (const m of msgs) if (m?.role === "assistant") last = textOf(m.content) || last;
  if (!last) return null;
  const dir = mkdtempSync(join(tmpdir(), "rsdd-pi-transcript-"));
  const file = join(dir, "transcript.jsonl");
  try {
    writeFileSync(file, JSON.stringify({ type: "assistant", message: { role: "assistant", content: [{ type: "text", text: last }] } }) + "\n", { mode: 0o600, flag: "wx" });
  } catch (e) {
    rmSync(dir, { recursive: true, force: true });
    throw e;
  }
  return { dir, file };
}

const entry = (content: string) => ({ type: "custom_message" as const, customType: NOTICE_TYPE, content, display: true });

function freshState(): HookState {
  return { sid: "", target: "", home: "", kit: "", tried: [], corpus: false, startedAt: "", startup: Promise.resolve(""), sweepText: null,
    notices: [], surface: [], noticed: new Set(), retroBlocked: false, tokenBlocked: false };
}

export default function (pi: ExtensionAPI) {
  if (process.env.GENTLE_PI_AGENTS_CHILD === "1") return; // child sessions never run hooks
  if (/^(0|off|false|no)$/i.test(process.env.RSDD_PI_HOOKS ?? "")) return;

  let st = freshState();
  // A failing handler never breaks the session, but the failure is VISIBLE: ctx.ui.notify now, the next settle's entries later.
  const guard = async <T,>(name: string, fn: () => Promise<T>, ctx?: any): Promise<T | undefined> => {
    try { return await fn(); } catch (e) {
      const msg = `Research-SDD hooks DEGRADED: ${name} failed (${String((e as Error)?.message ?? e).slice(0, 200)}).`;
      pushNotice(st, msg);
      if (st.surface.length < 3) st.surface.push(msg);
      try { ctx?.ui?.notify?.(msg, "error"); } catch { /* no UI in this mode */ }
      return undefined;
    }
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
      next.sid = sid; next.target = ctx.cwd || process.cwd(); next.home = agentHome(); next.startedAt = new Date().toISOString();
      const res = resolveKit(next.home);
      next.kit = res.kit; next.tried = res.tried; next.corpus = isCorpus(next.target);
      st = next;
      const cur = st;
      cur.startup = collectStartup(cur).catch((e) => `Research-SDD session sweep DEGRADED: ${String(e).slice(0, 200)}`);
      cur.startup.then((t) => { cur.sweepText = t; });
      if (cur.corpus) await recordSessionSha(cur);
    }, ctx);
  });

  pi.on("before_agent_start", async (event, ctx) => {
    await guard("before_agent_start", async () => {
      const cur = st;
      let sweep = cur.sweepText;
      if (sweep === null) {
        sweep = await withTimeout<string | null>(cur.startup, envMs("RSDD_PI_SWEEP_WAIT_MS", 3000), null);
        if (sweep === null) sweep = `research-sdd: session-start sweeps pending (started ${cur.startedAt}); their output is injected on a later run.`;
      }
      const text = finalContext(sweep, cur.notices);
      if (!text) return;
      if (!event?.systemPromptOptions?.sections) throw new Error("event.systemPromptOptions.sections missing");
      event.systemPromptOptions.sections[SECTION_KEY] = text; // every run: pi rebuilds the sections per run
    }, ctx);
  });

  pi.on("agent_before_settle", async (event, ctx) => {
    return guard("agent_before_settle", async () => {
      if (event.outcome !== "completed" || event.continue) return undefined; // Stop-equivalent: only a real, final completion
      const cur = st;
      // pi REPLACES the entries with the handler's return, so every return carries the entries already on the event.
      const base = Array.isArray(event.entries) ? event.entries : [];
      const mine: Array<ReturnType<typeof entry>> = cur.surface.splice(0).map(entry);
      const done = (cont: boolean) => (mine.length || cont ? { entries: [...base, ...mine], ...(cont ? { continue: true } : {}) } : undefined);
      if (!cur.corpus) return done(false); // the gates are per research target (Claude wires them per target)
      if (!cur.kit) { mine.push(...noticeOnce("kit", degradedKitText(cur))); return done(false); }
      const gateMs = envMs("RSDD_PI_GATE_TIMEOUT_MS", 120000);
      const hookJson = (extra: object) => JSON.stringify({ session_id: cur.sid, cwd: cur.target, stop_hook_active: false, ...extra });

      if (!cur.retroBlocked) {
        const script = join(cur.kit, "toolbelt", "retro-gate.sh");
        if (!existsSync(script)) mine.push(...noticeOnce("retro-missing", `Research-SDD retro gate DEGRADED: script missing at ${script}; the retro was NOT checked.`));
        else {
          const r = await run("bash", [script, cur.target], { cwd: cur.target, input: hookJson({}), timeoutMs: gateMs });
          const v = gateVerdict("retro gate", r, gateMs);
          if (v.block) { cur.retroBlocked = true; mine.push(entry(v.block)); return done(true); }
          if (v.notice) mine.push(...noticeOnce("retro-run", v.notice));
        }
      }

      if (!cur.tokenBlocked) {
        const script = join(cur.kit, "toolbelt", "return-token-gate.sh");
        if (!existsSync(script)) mine.push(...noticeOnce("token-missing", `Research-SDD return-token gate DEGRADED: script missing at ${script}; the continuation token was NOT checked.`));
        else {
          let tr: { dir: string; file: string } | null = null;
          try {
            tr = writeTranscript(ctx, event);
            if (!tr) mine.push(...noticeOnce("token-transcript", "Research-SDD return-token gate skipped (degraded): pi exposed no assistant text to check the continuation token against."));
            else {
              const ms = Math.min(gateMs, 40000);
              const r = await run("bash", [script, cur.target], { cwd: cur.target, input: hookJson({ transcript_path: tr.file }), timeoutMs: ms });
              const v = gateVerdict("return-token gate", r, ms);
              if (v.block) { cur.tokenBlocked = true; mine.push(entry(v.block)); return done(true); }
              if (v.notice) mine.push(...noticeOnce("token-run", v.notice));
            }
          } finally { if (tr) rmSync(tr.dir, { recursive: true, force: true }); }
        }
      }
      return done(false);
    }, ctx);
  });

  pi.on("tool_call", async (event, ctx) => {
    if (!SHELL_TOOLS.has(event.toolName)) return undefined;
    const command = (event.input as { command?: unknown } | null)?.command;
    if (typeof command !== "string" || !/pkill|pgrep/.test(command)) return undefined;
    const cur = st;
    const degraded = (why: string) => ({ block: true, reason: `pkill-guard DEGRADED (${why}): refusing a command that mentions pkill/pgrep because it cannot be checked for a self-matching -f pattern (it would kill this session, exit 144). Use pkill -x, a PID file, or a bracket-escaped pattern.` });
    try {
      const script = cur.kit ? join(cur.kit, "templates", "hook-pretool-pkill-guard.sh") : "";
      if (!script || !existsSync(script)) return degraded(cur.kit ? `script missing at ${script}` : "kit not resolvable");
      const r = await run("bash", [script], { cwd: cur.target || undefined, input: JSON.stringify({ tool_name: "Bash", tool_input: { command }, cwd: cur.target }), timeoutMs: 5000 });
      if (r.timedOut || r.error) return degraded(r.timedOut ? "timed out" : r.error);
      if (r.code !== 0) return degraded(`${r.signal ? `killed by ${r.signal}` : `exit ${r.code}`}${tailOf(r.stderr) ? `: ${tailOf(r.stderr)}` : ""}`);
      const out = r.stdout.trim();
      if (!out) return undefined; // the guard's allow is "exit 0, no stdout"
      const verdict = JSON.parse(out)?.hookSpecificOutput;
      if (verdict && (verdict.permissionDecision === "deny" || verdict.permissionDecision === "ask")) {
        const reason = String(verdict.permissionDecisionReason ?? "pkill-guard refused this command").slice(0, MAX_REASON_CHARS);
        // The guard's "ask" (degraded: it could not inspect the command) is a confirmation when a UI can ask; otherwise a block.
        if (verdict.permissionDecision === "ask" && ctx?.hasUI && typeof ctx.ui?.confirm === "function") {
          const yes = await ctx.ui.confirm("pkill-guard", reason);
          if (yes === true) return undefined;
        }
        return { block: true, reason };
      }
      return degraded("unrecognised guard output");
    } catch (e) {
      return degraded(String((e as Error)?.message ?? e).slice(0, 120));
    }
  });
}
