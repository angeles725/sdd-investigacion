// pi-hooks-behavior.test.mjs — headless behavior tests for the research-sdd pi extension
// (research-sdd/install/pi/research-sdd-hooks.ts, kit issue #2123). The handlers run against a FAKE
// `pi` object and a stub kit built in a temp dir; nothing touches the real ~/.pi or ~/.gentle-shell.
//
// Run: node research-sdd/toolbelt/tests/pi-hooks-behavior.test.mjs
// Env: RSDD_PI_HOOKS_SRC  override the extension under test (pi-hooks.test.sh --prove-teeth points it at mutants)
//
// Loading the .ts needs Node's built-in type stripping (process.features.typescript, Node >= 22.10 /
// 23.6). Without it the suite prints a typed `SKIP:` line and exits 0 (run-all counts it as skipped,
// never as passed) — the structural suite pi-hooks.test.sh still covers the source on every Node.
// Mirrors every defect class of niagara-research's hand-written extension (kit issue #2128).

import { mkdtempSync, mkdirSync, writeFileSync, chmodSync, readFileSync, existsSync, rmSync,
  symlinkSync, readdirSync, copyFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { spawnSync } from 'node:child_process';

const HERE = dirname(fileURLToPath(import.meta.url));
const KIT_REAL = join(HERE, '..', '..');
const SRC = process.env.RSDD_PI_HOOKS_SRC || join(KIT_REAL, 'install', 'pi', 'research-sdd-hooks.ts');

let pass = 0, fail = 0, skip = 0;
const ok = (m) => { console.log('  PASS  ' + m); pass++; };
const no = (m) => { console.log('  FAIL  ' + m); fail++; };
const sk = (m) => { console.log('  SKIP  ' + m); skip++; };
const check = (m, cond, detail = '') => (cond ? ok(m) : no(m + (detail ? ' — ' + detail : '')));

console.log('== pi-hooks-behavior.test.mjs ==');

if (!existsSync(SRC)) {
  console.error('FATAL: extension under test missing: ' + SRC);
  process.exit(2);
}
if (!process.features.typescript) {
  console.log('SKIP: this Node (' + process.version + ') has no built-in TypeScript type stripping; the handlers were not executed');
  process.exit(0);
}

const TMP = mkdtempSync(join(tmpdir(), 'rsdd-pi-hooks-'));
process.on('exit', () => { try { rmSync(TMP, { recursive: true, force: true }); } catch { /* best effort */ } });

const HOOKS = ['sweep-retros-hook', 'sweep-audits-hook', 'sweep-breakthroughs-hook', 'verify-registry-hook',
  'verify-kit-clean-hook', 'sweep-tools-hook', 'verify-tool-catalog-hook', 'verify-skill-drift-hook'];
const haveJq = spawnSync('jq', ['--version']).status === 0;

let seq = 0;
const fresh = (label) => { const d = join(TMP, `${label}-${++seq}`); mkdirSync(d, { recursive: true }); return d; };
const write = (p, body, exec = false) => { mkdirSync(dirname(p), { recursive: true }); writeFileSync(p, body); if (exec) chmodSync(p, 0o755); };

// A stub kit: every sweep hook prints a JSON additionalContext envelope naming itself; retro-gate and
// return-token-gate log their argv + stdin to $LOG and print $RETRO_OUT / $TOKEN_OUT (default: allow).
function makeKit(opts = {}) {
  const kit = fresh('kit');
  const log = join(kit, 'gate.log');
  for (const h of HOOKS) {
    if (opts.missing === h) continue;
    const body = opts.hookBody?.[h]
      ?? `#!/usr/bin/env bash\nprintf '%s\\n' '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"FINDING-${h}"}}'\n`;
    write(join(kit, 'toolbelt', h + '.sh'), body, true);
  }
  const gate = (name, envVar) => `#!/usr/bin/env bash\n{ printf 'GATE ${name} argv=%s\\n' "$*"; printf 'STDIN %s\\n' "$(cat)"; } >> "${log}"\n` +
    `if [ -n "\${${envVar}:-}" ]; then printf '%s' "\$${envVar}"; fi\nexit 0\n`;
  write(join(kit, 'toolbelt', 'retro-gate.sh'), gate('retro', 'RSDD_TEST_RETRO_OUT'), true);
  write(join(kit, 'toolbelt', 'return-token-gate.sh'),
    `#!/usr/bin/env bash\nin="$(cat)"\n{ printf 'GATE token argv=%s\\n' "$*"; printf 'STDIN %s\\n' "$in"; } >> "${log}"\n` +
    `tp="$(printf '%s' "$in" | sed -n 's/.*"transcript_path":"\\([^"]*\\)".*/\\1/p')"\n` +
    `[ -n "$tp" ] && [ -r "$tp" ] && printf 'TRANSCRIPT %s\\n' "$(cat "$tp")" >> "${log}"\n` +
    `if [ -n "\${RSDD_TEST_TOKEN_OUT:-}" ]; then printf '%s' "$RSDD_TEST_TOKEN_OUT"; fi\nexit 0\n`, true);
  if (opts.pkillBody) {
    write(join(kit, 'templates', 'hook-pretool-pkill-guard.sh'), opts.pkillBody, true);
  } else if (!opts.noPkillGuard && haveJq) {
    mkdirSync(join(kit, 'templates'), { recursive: true });
    copyFileSync(join(KIT_REAL, 'templates', 'hook-pretool-pkill-guard.sh'), join(kit, 'templates', 'hook-pretool-pkill-guard.sh'));
  } else if (!opts.noPkillGuard) {
    mkdirSync(join(kit, 'templates'), { recursive: true });
  }
  return { kit, log };
}

// An agent home whose AGENTS.md launcher names the kit (the resolution source the installer writes).
function makeAgentHome(kit, mode = 'checkout') {
  const home = fresh('agent');
  if (mode === 'checkout') {
    write(join(home, 'AGENTS.md'),
      `# user prompt\n<!-- research-sdd:start -->\n## Research-SDD\nKit path: ${join(home, 'research-sdd/profile/general')}\nKit checkout: ${kit}\n<!-- research-sdd:end -->\n`);
  } else if (mode === 'path-only') {
    write(join(home, 'AGENTS.md'), `<!-- research-sdd:start -->\nKit path: ${kit}\n<!-- research-sdd:end -->\n`);
  } else if (mode === 'render-link') {
    mkdirSync(join(home, 'research-sdd/profile/general'), { recursive: true });
    symlinkSync(join(kit, 'toolbelt'), join(home, 'research-sdd/profile/general/toolbelt'));
  }
  return home;
}

function makeTarget(corpus = true, git = false) {
  const t = fresh('target');
  if (corpus) write(join(t, 'RESEARCH-STATE.md'), '# state\n');
  if (git) {
    const g = (...a) => spawnSync('git', ['-C', t, '-c', 'user.name=t', '-c', 'user.email=t@t', ...a], { encoding: 'utf8' });
    g('init', '-q'); g('add', '-A'); g('commit', '-q', '-m', 'init');
  }
  return t;
}

const ENV_KEYS = ['GENTLE_PI_AGENTS_CHILD', 'GENTLE_PI_AGENT_HOME', 'PI_CODING_AGENT_DIR', 'RESEARCH_SDD_KIT', 'RSDD_PI_HOOKS',
  'RSDD_PI_SWEEP_TIMEOUT_MS', 'RSDD_PI_GATE_TIMEOUT_MS', 'RSDD_TEST_RETRO_OUT', 'RSDD_TEST_TOKEN_OUT'];
const SAVED = Object.fromEntries(ENV_KEYS.map((k) => [k, process.env[k]]));
const setEnv = (o) => {
  for (const k of ENV_KEYS) delete process.env[k];
  for (const [k, v] of Object.entries(o)) process.env[k] = v;
};
const restoreEnv = () => { for (const k of ENV_KEYS) { if (SAVED[k] === undefined) delete process.env[k]; else process.env[k] = SAVED[k]; } };

let loadN = 0;
const loadFactory = async () => (await import(pathToFileURL(SRC).href + '?t=' + ++loadN)).default;

function makePi() {
  const handlers = {};
  return { handlers, on(ev, fn) { (handlers[ev] ??= []).push(fn); return () => {}; } };
}
const fire = async (pi, ev, event, ctx) => {
  let last;
  for (const fn of pi.handlers[ev] ?? []) last = await fn(event, ctx);
  return last;
};
function makeCtx(cwd, sid, messages = []) {
  const entries = messages.map((m, i) => ({ type: 'message', id: 'e' + i, message: m }));
  return {
    cwd, hasUI: false, ui: { notify() {} },
    sessionManager: {
      getSessionId: () => sid, getSessionFile: () => join(cwd, 'session-' + sid + '.jsonl'),
      getBranch: () => entries, getEntries: () => entries,
    },
  };
}
const assistant = (text) => ({ role: 'assistant', content: [{ type: 'text', text }] });
const user = (text) => ({ role: 'user', content: text });
const settleEvent = (extra = {}) => ({ type: 'agent_before_settle', outcome: 'completed', continue: false, entries: [], context: {}, ...extra });
const readLog = (log) => (existsSync(log) ? readFileSync(log, 'utf8') : '');
const sectionOf = (ev) => Object.values(ev.systemPromptOptions.sections).join('\n');
const startEvent = () => ({ type: 'before_agent_start', prompt: 'hi', systemPrompt: '', systemPromptOptions: { sections: {} } });
const BLOCK_JSON = JSON.stringify({ decision: 'block', reason: 'RETRO-REQUIRED: write the retro' });

// Boot one extension instance: env + stub kit + agent home + target, session_start fired.
async function boot({ kitOpts = {}, mode = 'checkout', corpus = true, git = false, env = {}, sid = 'sess-A', noKit = false } = {}) {
  const { kit, log } = makeKit(kitOpts);
  const agent = noKit ? fresh('agent-empty') : makeAgentHome(kit, mode);
  const target = makeTarget(corpus, git);
  setEnv({ GENTLE_PI_AGENT_HOME: agent, ...env });
  const factory = await loadFactory();
  const pi = makePi();
  factory(pi);
  const ctx = makeCtx(target, sid, [user('go'), assistant('final report\nnext: foo')]);
  await fire(pi, 'session_start', { type: 'session_start', reason: 'startup' }, ctx);
  return { kit, log, agent, target, pi, ctx };
}

const t0 = Date.now();

// ---- 1. child guard + opt-out --------------------------------------------------------------------
{
  const { kit } = makeKit();
  setEnv({ GENTLE_PI_AGENT_HOME: makeAgentHome(kit), GENTLE_PI_AGENTS_CHILD: '1' });
  const f = await loadFactory(); const pi = makePi(); f(pi);
  check('child guard: GENTLE_PI_AGENTS_CHILD=1 registers no handler at all', Object.keys(pi.handlers).length === 0,
    'registered: ' + Object.keys(pi.handlers).join(','));
  setEnv({ GENTLE_PI_AGENT_HOME: makeAgentHome(kit), RSDD_PI_HOOKS: '0' });
  const pi2 = makePi(); (await loadFactory())(pi2);
  check('opt-out: RSDD_PI_HOOKS=0 registers no handler', Object.keys(pi2.handlers).length === 0);
  setEnv({ GENTLE_PI_AGENT_HOME: makeAgentHome(kit) });
  const pi3 = makePi(); (await loadFactory())(pi3);
  const want = ['session_start', 'before_agent_start', 'agent_before_settle', 'tool_call'];
  check('a normal session registers session_start, before_agent_start, agent_before_settle and tool_call',
    want.every((e) => (pi3.handlers[e] ?? []).length === 1), 'registered: ' + Object.keys(pi3.handlers).join(','));
}

// ---- 2. sweep + drift context: injected into the MODEL context on EVERY run -----------------------
{
  const s = await boot();
  const ev1 = startEvent();
  await fire(s.pi, 'before_agent_start', ev1, s.ctx);
  const txt1 = sectionOf(ev1);
  check('before_agent_start injects every sweep hook finding into the system prompt sections',
    HOOKS.every((h) => txt1.includes('FINDING-' + h)), txt1.slice(0, 200));
  const ev2 = startEvent(); // pi rebuilds the sections from base options on each run
  await fire(s.pi, 'before_agent_start', ev2, s.ctx);
  check('a second run is injected again (sections are rebuilt per run, #2128 item 7)', HOOKS.every((h) => sectionOf(ev2).includes('FINDING-' + h)));
  check('the section names how many hooks ran (a silent clean run is distinguishable from no run)',
    /8 of 8|8\/8/.test(txt1), txt1.slice(0, 200));
  restoreEnv();
}

// ---- 3. SessionStart budget (openspec kit-session-cost: < 8,000 chars) -----------------------------
{
  const big = {};
  for (const h of HOOKS) big[h] = `#!/usr/bin/env bash\nhead -c 6000 /dev/zero | tr '\\0' 'x'\necho\n`;
  const s = await boot({ kitOpts: { hookBody: big } });
  const ev = startEvent();
  await fire(s.pi, 'before_agent_start', ev, s.ctx);
  const txt = sectionOf(ev);
  check('injected sweep context stays under the 8,000-char SessionStart budget', txt.length > 0 && txt.length < 8000, 'length ' + txt.length);
  check('an over-budget sweep is truncated with a typed notice naming the full command', /truncated/i.test(txt) && txt.includes('sweep-all.sh'));
  restoreEnv();
}

// ---- 4. degraded states are typed, never silent (CLAUDE.md section 7) ------------------------------
{
  const s = await boot({ kitOpts: { missing: 'sweep-audits-hook' } });
  const ev = startEvent();
  await fire(s.pi, 'before_agent_start', ev, s.ctx);
  const txt = sectionOf(ev);
  check('a missing sweep script yields a typed degraded line naming it', /degraded/i.test(txt) && txt.includes('sweep-audits-hook'), txt.slice(0, 300));
  check('the other sweeps still run when one is missing', txt.includes('FINDING-sweep-retros-hook'));
  restoreEnv();
}
{
  const slow = { 'sweep-tools-hook': '#!/usr/bin/env bash\nsleep 8\n' };
  const t = Date.now();
  const s = await boot({ kitOpts: { hookBody: slow }, env: { RSDD_PI_SWEEP_TIMEOUT_MS: '700' } });
  const ev = startEvent();
  await fire(s.pi, 'before_agent_start', ev, s.ctx);
  const txt = sectionOf(ev); const dt = Date.now() - t;
  check('a hung sweep script is bounded by its timeout and reported as timed out', /timed out/i.test(txt) && txt.includes('sweep-tools-hook') && dt < 6000, `dt=${dt} ${txt.slice(0, 200)}`);
  restoreEnv();
}
{
  const s = await boot({ noKit: true });
  const ev = startEvent();
  await fire(s.pi, 'before_agent_start', ev, s.ctx);
  const txt = sectionOf(ev);
  check('no resolvable kit: context carries a typed DEGRADED notice, not silence', /DEGRADED/.test(txt) && /not resolvable/i.test(txt) && /research-sdd-install\.sh/.test(txt), txt.slice(0, 300));
  const r = await fire(s.pi, 'agent_before_settle', settleEvent(), s.ctx);
  check('no resolvable kit: the settle gate reports a typed notice entry and never forces a continuation',
    Array.isArray(r?.entries) && /DEGRADED|not resolvable/i.test(JSON.stringify(r.entries)) && r.continue !== true, JSON.stringify(r));
  const r2 = await fire(s.pi, 'agent_before_settle', settleEvent(), s.ctx);
  check('the degraded settle notice is emitted once per session, not on every settle', r2 === undefined || !r2.entries?.length, JSON.stringify(r2));
  restoreEnv();
}

// ---- 5. kit resolution: launcher Kit checkout > Kit path > render-dir symlink; never hardcoded ------
{
  const s = await boot({ mode: 'path-only' });
  const ev = startEvent(); await fire(s.pi, 'before_agent_start', ev, s.ctx);
  check('kit resolves from the launcher "Kit path:" line when there is no "Kit checkout:"', sectionOf(ev).includes('FINDING-sweep-retros-hook'));
  restoreEnv();
  const s2 = await boot({ mode: 'render-link' });
  const ev2 = startEvent(); await fire(s2.pi, 'before_agent_start', ev2, s2.ctx);
  check('kit resolves from the render dir toolbelt symlink when the launcher is absent', sectionOf(ev2).includes('FINDING-sweep-retros-hook'));
  restoreEnv();
  const { kit } = makeKit();
  setEnv({ GENTLE_PI_AGENT_HOME: fresh('agent-empty'), RESEARCH_SDD_KIT: kit });
  const pi = makePi(); (await loadFactory())(pi);
  const ctx = makeCtx(makeTarget(), 'sess-env');
  await fire(pi, 'session_start', { type: 'session_start', reason: 'startup' }, ctx);
  const ev3 = startEvent(); await fire(pi, 'before_agent_start', ev3, ctx);
  check('kit resolves from $RESEARCH_SDD_KIT first', sectionOf(ev3).includes('FINDING-sweep-retros-hook'));
  restoreEnv();
}

// ---- 6. Stop-equivalent: only on a completed, non-continuing settle ---------------------------------
{
  const s = await boot({ env: { RSDD_TEST_RETRO_OUT: BLOCK_JSON } });
  const aborted = await fire(s.pi, 'agent_before_settle', settleEvent({ outcome: 'aborted' }), s.ctx);
  const errored = await fire(s.pi, 'agent_before_settle', settleEvent({ outcome: 'error' }), s.ctx);
  const cont = await fire(s.pi, 'agent_before_settle', settleEvent({ continue: true }), s.ctx);
  check('no gate runs after an abort, an error, or when a continuation is already queued (#2128 item 6)',
    aborted === undefined && errored === undefined && cont === undefined && !/GATE/.test(readLog(s.log)), readLog(s.log).slice(0, 200));
  restoreEnv();
}
{
  const s = await boot({ env: { RSDD_TEST_RETRO_OUT: BLOCK_JSON } });
  const r = await fire(s.pi, 'agent_before_settle', settleEvent(), s.ctx);
  const e = r?.entries?.[0];
  check('retro-gate block becomes a custom_message entry with continue:true (really re-prompts)',
    r?.continue === true && e?.type === 'custom_message' && /RETRO-REQUIRED/.test(String(e?.content)) && e?.display === true, JSON.stringify(r));
  const log = readLog(s.log);
  check('retro-gate receives the target (from ctx.cwd) and a hook JSON with session_id',
    log.includes('GATE retro argv=' + s.target) && log.includes('"session_id":"sess-A"') && log.includes('"stop_hook_active":false'), log.slice(0, 300));
  const r2 = await fire(s.pi, 'agent_before_settle', settleEvent(), s.ctx);
  check('the same block is returned once per session (block-once)', r2 === undefined || r2.continue !== true, JSON.stringify(r2));
  check('after a block the gate is not re-run in the same session', (readLog(s.log).match(/GATE retro/g) ?? []).length === 1);
  // session_start again (new session in the same process): flags and session id must be recomputed (#2128 item 10)
  const ctx2 = makeCtx(s.target, 'sess-B', [user('go'), assistant('done')]);
  await fire(s.pi, 'session_start', { type: 'session_start', reason: 'new' }, ctx2);
  const r3 = await fire(s.pi, 'agent_before_settle', settleEvent(), ctx2);
  check('a new session_start re-arms the block-once flag and recomputes the session id',
    r3?.continue === true && readLog(s.log).includes('"session_id":"sess-B"'), JSON.stringify(r3));
  restoreEnv();
}
{
  const s = await boot({ corpus: false, env: { RSDD_TEST_RETRO_OUT: BLOCK_JSON } });
  const r = await fire(s.pi, 'agent_before_settle', settleEvent(), s.ctx);
  check('a cwd that is not a research corpus runs no retro gate (no stray .claude/ state)', r === undefined && !/GATE retro/.test(readLog(s.log)) && !existsSync(join(s.target, '.claude')));
  restoreEnv();
}
{
  const s = await boot({ env: { RSDD_TEST_TOKEN_OUT: JSON.stringify({ decision: 'block', reason: 'TOKEN-REQUIRED: copy next: foo' }) } });
  const r = await fire(s.pi, 'agent_before_settle', settleEvent(), s.ctx);
  const log = readLog(s.log);
  check('return-token-gate runs with a readable transcript_path whose last assistant text is the final report (#2128 item 9)',
    /GATE token argv=/.test(log) && /TRANSCRIPT .*final report/s.test(log) && /next: foo/.test(log), log.slice(0, 400));
  check('a return-token block is returned as an entry with continue:true', r?.continue === true && /TOKEN-REQUIRED/.test(JSON.stringify(r)), JSON.stringify(r));
  const r2t = await fire(s.pi, 'agent_before_settle', settleEvent(), s.ctx);
  check('the return-token block is once per session: the next settle neither blocks nor re-runs the gate',
    (r2t === undefined || r2t.continue !== true) && (readLog(s.log).match(/GATE token/g) ?? []).length === 1, JSON.stringify(r2t));
  const tmpLeft = readdirSync(tmpdir()).filter((f) => f.startsWith('rsdd-pi-transcript-'));
  check('the derived transcript temp file is removed after the gate ran', tmpLeft.length === 0, tmpLeft.join(','));
  restoreEnv();
}
{
  const { kit, log } = makeKit();
  setEnv({ GENTLE_PI_AGENT_HOME: makeAgentHome(kit), RSDD_TEST_TOKEN_OUT: BLOCK_JSON });
  const pi = makePi(); (await loadFactory())(pi);
  const ctx = makeCtx(makeTarget(), 'sess-noasst', [user('only a user message')]);
  await fire(pi, 'session_start', { type: 'session_start', reason: 'startup' }, ctx);
  const r = await fire(pi, 'agent_before_settle', settleEvent(), ctx);
  check('no assistant text to hand the token gate: typed notice, gate not run, no silent allow',
    !/GATE token/.test(readLog(log)) && /return-token/i.test(JSON.stringify(r?.entries ?? [])) && r?.continue !== true, JSON.stringify(r));
  restoreEnv();
}

// ---- 7. pkill guard delegated to the kit script ----------------------------------------------------
if (!haveJq) {
  sk('pkill guard cases need jq (the guard itself degrades without it)');
} else {
  const s = await boot();
  const bash = (command) => ({ type: 'tool_call', toolName: 'bash', toolCallId: 'c', input: { command } });
  const denied = await fire(s.pi, 'tool_call', bash('pkill -f myserver'), s.ctx);
  check('tool_call blocks a self-matching pkill -f with the guard reason', denied?.block === true && /Refused/.test(denied.reason ?? ''), JSON.stringify(denied));
  const flagged = await fire(s.pi, 'tool_call', bash("bash -c 'pkill -af myserver'"), s.ctx);
  check('the delegated guard catches combined flags and wrapped shells the niagara regex port missed (#2128 item 11)', flagged?.block === true, JSON.stringify(flagged));
  const later = await fire(s.pi, 'tool_call', bash('echo hi; pkill -f myserver'), s.ctx);
  check('the delegated guard catches a later command segment', later?.block === true, JSON.stringify(later));
  const safe = await fire(s.pi, 'tool_call', bash("pkill -f '[m]yserver'"), s.ctx);
  check('a bracket-escaped pattern is allowed', safe === undefined, JSON.stringify(safe));
  const plain = await fire(s.pi, 'tool_call', bash('ls -la'), s.ctx);
  check('a command without pkill/pgrep is allowed', plain === undefined);
  const notBash = await fire(s.pi, 'tool_call', { type: 'tool_call', toolName: 'read', toolCallId: 'c', input: { path: '/x' } }, s.ctx);
  check('a non-bash tool call is ignored', notBash === undefined);
  restoreEnv();
}
{
  // the guard's own degraded branch (no jq) answers "ask"; pi has no ask for a tool_call, so it must become a block
  const ask = `#!/usr/bin/env bash\ncat >/dev/null\nprintf '%s' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"ASK-REASON confirm the pattern"}}'\n`;
  const s = await boot({ kitOpts: { pkillBody: ask } });
  const r = await fire(s.pi, 'tool_call', { type: 'tool_call', toolName: 'bash', toolCallId: 'c', input: { command: 'pkill -f x' } }, s.ctx);
  check('a guard "ask" decision becomes a block carrying the guard reason (pi tool_call cannot ask)', r?.block === true && /ASK-REASON/.test(r.reason ?? ''), JSON.stringify(r));
  restoreEnv();
}
{
  const s = await boot({ kitOpts: { noPkillGuard: true } });
  const r = await fire(s.pi, 'tool_call', { type: 'tool_call', toolName: 'bash', toolCallId: 'c', input: { command: 'pkill -f x' } }, s.ctx);
  check('pkill with the guard script missing fails closed with a typed degraded reason', r?.block === true && /degraded/i.test(r.reason ?? ''), JSON.stringify(r));
  const plain = await fire(s.pi, 'tool_call', { type: 'tool_call', toolName: 'bash', toolCallId: 'c', input: { command: 'ls' } }, s.ctx);
  check('a command without pkill is not blocked by the missing guard', plain === undefined);
  restoreEnv();
}

// ---- 8. session-start sha for retro-gate (the Claude SessionStart hook's job), write-once -----------
{
  const s = await boot({ git: true, sid: 'sess-sha' });
  const f = join(s.target, '.claude', '.rsdd-session-sess-sha');
  const head = spawnSync('git', ['-C', s.target, 'rev-parse', 'HEAD'], { encoding: 'utf8' }).stdout.trim();
  check('session_start records the session-start git sha for the retro gate', existsSync(f) && readFileSync(f, 'utf8').trim() === head && head.length === 40);
  write(f, 'keep-me\n');
  await fire(s.pi, 'session_start', { type: 'session_start', reason: 'resume' }, makeCtx(s.target, 'sess-sha'));
  check('the recorded sha is write-once: a resume does not overwrite it', readFileSync(f, 'utf8') === 'keep-me\n');
  await fire(s.pi, 'session_start', { type: 'session_start', reason: 'new' }, makeCtx(s.target, 'sess-sha2'));
  check('a new session id gets its own sha file (id recomputed on every session_start)', existsSync(join(s.target, '.claude', '.rsdd-session-sess-sha2')));
  restoreEnv();
}

// ---- 9. a throwing handler never breaks the session --------------------------------------------------
{
  const s = await boot();
  const bad = { cwd: s.target, hasUI: false, sessionManager: { getSessionId() { throw new Error('boom'); }, getBranch() { throw new Error('boom'); } } };
  let threw = false;
  try {
    await fire(s.pi, 'session_start', { type: 'session_start', reason: 'new' }, bad);
    await fire(s.pi, 'before_agent_start', { type: 'before_agent_start', prompt: '', systemPrompt: '' }, bad); // no systemPromptOptions
    await fire(s.pi, 'agent_before_settle', settleEvent(), bad);
    await fire(s.pi, 'tool_call', { type: 'tool_call', toolName: 'bash', toolCallId: 'c', input: null }, bad);
  } catch { threw = true; }
  check('handlers swallow their own failures (throwing session manager, missing systemPromptOptions, null input)', !threw);
  restoreEnv();
}

restoreEnv();
console.log(`\n${pass} passed, ${fail} failed, ${skip} skipped (${Date.now() - t0} ms)`);
process.exit(fail > 0 ? 1 : 0);
