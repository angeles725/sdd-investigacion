// session-budget-pi.mjs — measure what the pi / gentle-shell extensions inject into the model context (kit issue #2174).
//
// Called by verify-session-budget.sh --harness pi, ALREADY inside its bwrap sandbox. It loads each extension under a FAKE `pi`
// object (the technique of tests/pi-hooks-behavior.test.mjs), fires session_start on every extension (in parallel), then
// before_agent_start on a shared event with an empty `systemPromptOptions.sections` (sequentially, in file order), and reports the
// decoded length (Unicode code points) of every section an extension added.
//
// What is counted (the forms pi-coding-agent's BeforeAgentStartEventResult accepts, checked in its types.d.ts):
//   - sections an extension adds to event.systemPromptOptions.sections            -> S record, key = the section key
//   - a returned `message` ({customType, content}) injected as a custom message    -> S record, key = message:<customType>
//   - a returned `systemPrompt` string (REPLACES the whole prompt), a mutation of event.systemPrompt, or any other returned key
//     -> U record: the extension injected through a route whose size cannot be attributed; never counted as 0-char OK.
// Emulation limits: the fake pi API is a no-op except `on`; ctx has no mode/model/tools; extensions that read those, or that call
// other pi APIs, run against stubs. session_start handlers run in parallel; before_agent_start handlers run one after another.
//
// Usage: node session-budget-pi.mjs <cwd> <ext-file>...        (needs Node's built-in TypeScript type stripping for .ts files)
// Env:   RSDD_BUDGET_PI_WAIT_MS  per-handler wait (default 60000): a slow extension yields ITS OWN E record, the run continues
// stdout, one tab-separated record per line:
//   S <ext> <section-key> <chars> <flag>   flag = ok | degraded-text | pending (the section text says it is partial)
//   U <ext> <reason>                       injected through a route that cannot be measured (typed partial)
//   E <ext> <reason>                       the extension failed to load / a handler threw or timed out (FINAL record of that extension)
//   T <ext> <count>                        the extension finished; <count> sections added (FINAL record of that extension; 0 is fine)
//   Z <n>                                  closing marker, last line: <n> extensions were processed (each has exactly one T or E)
// A caller that sees no Z, or fewer than <n> final records, knows the run ended early (process.exit mid-load or mid-handler).
// Exit: 0 always for findings; 2 usage error.
import { pathToFileURL } from 'node:url';

// The caller's per-run nonce arrives on stdin and is read BEFORE any extension is imported; every record is prefixed with it, so a line
// an extension writes to stdout itself is recognisably forged. The write function is captured now (an extension may replace console.log).
const writeOut = process.stdout.write.bind(process.stdout);
const nonce = await new Promise((res) => {
  let b = ''; process.stdin.setEncoding('utf8');
  process.stdin.on('data', (d) => { b += d; if (b.includes('\n')) { process.stdin.pause(); res(b.split('\n')[0]); } });
  process.stdin.on('end', () => res(b.trim()));
});
const [cwd, ...exts] = process.argv.slice(2);
if (!cwd || exts.length === 0) { console.error('usage: session-budget-pi.mjs <cwd> <ext-file>...'); process.exit(2); }
const waitMs = Number(process.env.RSDD_BUDGET_PI_WAIT_MS) > 0 ? Number(process.env.RSDD_BUDGET_PI_WAIT_MS) : 60000;
const one = (s) => String(s).replace(/[\t\r\n]+/g, ' ').slice(0, 200);
// The name shown for an extension: its path below the nearest `extensions` directory (sub/index.ts stays distinct from index.ts).
const nameOf = (file) => { const i = file.lastIndexOf('/extensions/'); return i >= 0 ? file.slice(i + '/extensions/'.length) : file.slice(file.lastIndexOf('/') + 1); };
const rec = (...f) => writeOut(nonce + '\t' + f.join('\t') + '\n');
const withTimeout = (p, ms) => new Promise((res, rej) => {
  const t = setTimeout(() => rej(new Error('timed out after ' + ms + 'ms')), ms);
  p.then((v) => { clearTimeout(t); res(v); }, (e) => { clearTimeout(t); rej(e); });
});
const textLen = (c) => (typeof c === 'string' ? [...c].length
  : Array.isArray(c) ? c.reduce((n, b) => n + (b && b.type === 'text' && typeof b.text === 'string' ? [...b.text].length : 0), 0) : 0);

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
    loaded.push({ file, name: nameOf(file), handlers });
  } catch (e) { rec('E', nameOf(file), one('load failed: ' + (e?.message ?? e))); }
}
const fire = async (ev, event, entry) => { const out = []; for (const fn of entry.handlers[ev] ?? []) out.push(await fn(event, ctx)); return out; };
const failed = new Set();
await Promise.all(loaded.map(async (x) => {
  try { await withTimeout(fire('session_start', { type: 'session_start', reason: 'startup' }, x), waitMs); }
  catch (e) { failed.add(x.file); rec('E', x.name, one('session_start failed: ' + (e?.message ?? e))); }
}));
const event = { type: 'before_agent_start', prompt: 'hi', systemPrompt: '', systemPromptOptions: { sections: {} } };
for (const x of loaded) {
  if (failed.has(x.file)) continue;
  const before = new Set(Object.keys(event.systemPromptOptions.sections));
  const promptBefore = event.systemPrompt;
  let results;
  try { results = await withTimeout(fire('before_agent_start', event, x), waitMs); }
  catch (e) { rec('E', x.name, one('before_agent_start failed: ' + (e?.message ?? e))); continue; }
  const keys = Object.keys(event.systemPromptOptions.sections).filter((k) => !before.has(k));
  for (const k of keys) {
    const text = String(event.systemPromptOptions.sections[k] ?? '');
    const flag = /sweeps pending/.test(text) ? 'pending' : /\bDEGRADED\b/.test(text) ? 'degraded-text' : 'ok';
    rec('S', x.name, one(k), [...text].length, flag);
  }
  let nsec = keys.length;
  for (const r of results) {
    if (r === undefined || r === null) continue;
    if (typeof r !== 'object') { rec('U', x.name, 'handler returned a non-object value; its effect on the context is unknown'); continue; }
    for (const rk of Object.keys(r)) {
      if (rk === 'message' && r.message && r.message.content !== undefined) {
        rec('S', x.name, one('message:' + (r.message.customType ?? 'custom')), textLen(r.message.content), 'ok'); nsec++;
      } else if (rk === 'systemPrompt') {
        rec('U', x.name, 'returned systemPrompt (replaces the whole prompt; the size it adds is unknowable here)');
      } else rec('U', x.name, one('returned key "' + rk + '" is not a measurable injection form'));
    }
  }
  if (event.systemPrompt !== promptBefore) rec('U', x.name, 'mutated event.systemPrompt (the size it adds is unknowable here)');
  rec('T', x.name, nsec);
}
rec('Z', exts.length);
process.exit(0);
