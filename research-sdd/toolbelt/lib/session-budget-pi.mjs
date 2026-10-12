// session-budget-pi.mjs — measure what the pi / gentle-shell extensions inject into the system prompt (kit issue #2174).
//
// Called by verify-session-budget.sh --harness pi, ALREADY inside its bwrap sandbox. It loads each extension under a FAKE `pi`
// object (the technique of tests/pi-hooks-behavior.test.mjs), fires session_start on every extension, then before_agent_start
// on a shared event with an empty `systemPromptOptions.sections`, and reports the decoded length (Unicode code points) of every
// section an extension added.
//
// Usage: node session-budget-pi.mjs <cwd> <ext-file>...        (needs Node's built-in TypeScript type stripping for .ts files)
// Env:   RSDD_BUDGET_PI_WAIT_MS  how long to wait for each handler (default 60000)
// stdout, one tab-separated record per line:
//   S <ext-file> <section-key> <chars> <flag>   flag = ok | degraded-text | pending (the section text says it is partial)
//   E <ext-file> <reason>                       the extension could not be loaded / a handler threw or timed out
//   T <ext-file> <count>                        how many sections the extension added (0 is not an error)
// Exit: 0 always for findings; 2 usage error.
import { pathToFileURL } from 'node:url';
import { basename } from 'node:path';

const [cwd, ...exts] = process.argv.slice(2);
if (!cwd || exts.length === 0) { console.error('usage: session-budget-pi.mjs <cwd> <ext-file>...'); process.exit(2); }
const waitMs = Number(process.env.RSDD_BUDGET_PI_WAIT_MS) > 0 ? Number(process.env.RSDD_BUDGET_PI_WAIT_MS) : 60000;
const one = (s) => String(s).replace(/[\t\r\n]+/g, ' ').slice(0, 200);
const withTimeout = (p, ms) => new Promise((res, rej) => {
  const t = setTimeout(() => rej(new Error('timed out after ' + ms + 'ms')), ms);
  p.then((v) => { clearTimeout(t); res(v); }, (e) => { clearTimeout(t); rej(e); });
});

const ctx = {
  cwd, hasUI: false, ui: { notify() {} },
  sessionManager: { getSessionId: () => 'budget-probe', getSessionFile: () => cwd + '/session-budget-probe.jsonl', getBranch: () => [], getEntries: () => [] },
};
const loaded = [];
for (const file of exts) {
  const handlers = {};
  const base = { on(ev, fn) { (handlers[ev] ??= []).push(fn); return () => {}; } };
  const pi = new Proxy(base, { get: (t, k) => (k in t ? t[k] : () => {}) });
  try {
    const mod = await import(pathToFileURL(file).href);
    if (typeof mod.default !== 'function') throw new Error('no default export function');
    await mod.default(pi);
    loaded.push({ file, handlers });
  } catch (e) { console.log(['E', basename(file), one('load failed: ' + (e?.message ?? e))].join('\t')); }
}
const fire = async (ev, event, entry) => { for (const fn of entry.handlers[ev] ?? []) await fn(event, ctx); };
const failed = new Set();
await Promise.all(loaded.map(async (x) => {
  try { await withTimeout(fire('session_start', { type: 'session_start', reason: 'startup' }, x), waitMs); }
  catch (e) { failed.add(x.file); console.log(['E', basename(x.file), one('session_start failed: ' + (e?.message ?? e))].join('\t')); }
}));
const event = { type: 'before_agent_start', prompt: 'hi', systemPrompt: '', systemPromptOptions: { sections: {} } };
for (const x of loaded) {
  if (failed.has(x.file)) continue;
  const before = new Set(Object.keys(event.systemPromptOptions.sections));
  try { await withTimeout(fire('before_agent_start', event, x), waitMs); }
  catch (e) { console.log(['E', basename(x.file), one('before_agent_start failed: ' + (e?.message ?? e))].join('\t')); continue; }
  const keys = Object.keys(event.systemPromptOptions.sections).filter((k) => !before.has(k));
  for (const k of keys) {
    const text = String(event.systemPromptOptions.sections[k] ?? '');
    const flag = /sweeps pending/.test(text) ? 'pending' : /\bDEGRADED\b/.test(text) ? 'degraded-text' : 'ok';
    console.log(['S', basename(x.file), one(k), [...text].length, flag].join('\t'));
  }
  console.log(['T', basename(x.file), keys.length].join('\t'));
}
process.exit(0);
