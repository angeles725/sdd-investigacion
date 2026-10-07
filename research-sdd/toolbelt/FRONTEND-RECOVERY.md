# Frontend recovery ladder — jar-shipped web clients

How to recover the structure and behaviour of a web UI that ships inside a jar (Vite/webpack bundle) when
the original source is not available. Ordered from cheapest and most faithful to most lossy. Stop at the first
rung that answers the question, and say which rung produced each claim.

**Source.** Kit issue #1930 (retro 2026-10-06 reflow bypass bench; worked example
`reflow-frontend/reconstructed/CAMINO-RECORRIDO.md` on the bench). Only the rungs named in that issue are
listed; nothing here was added beyond it. Items marked `[unverified]` are not confirmed by the issue text.

## Rung 0 — Is there a sourcemap? (always first)

`grep sourceMappingURL` over the shipped `.js` files. A present, resolvable sourcemap carries the original
sources and makes every later rung unnecessary. An absent or stripped map means the ladder continues.
Evidence yielded: presence/absence of a map per bundle file. Cite the grep command and its hit/no-hit count; a
zero count is only meaningful if a known-hit control (a bundle file you know ends with the comment) was run.

## Rung 1 — Vite manifest

When the jar contains a Vite build manifest, it maps entry/chunk names to emitted file names.
Evidence yielded: the chunk list and the entry-to-chunk structure. Cite the manifest path inside the jar.

## Rung 2 — Chunk to source-path map plus literal mining

Use the manifest/chunk names to map each chunk back to its likely source path, then mine the chunk text for
literals that survive minification: `defineStore` (store names), `name:` (route/component names),
`path:` (routes), and endpoint strings. Evidence yielded: route table, store inventory, and the API
endpoints the UI calls. Cite chunk file plus the literal; mark route-to-component pairings `[INFER]`
unless the literal and its neighbour appear together in the same chunk.

## Rung 3 — webcrack (deobfuscation/unpack)

Run webcrack on the bundles that remain unreadable. Limitation recorded in the issue: webcrack does not
unpack ESM/Vite-style bundles (it targets webpack-style bundles); on an ESM/Vite bundle expect pretty-printing
at best, not module recovery. `[unverified]` beyond that statement: exact version and flags. Evidence yielded:
readable but non-original code; cite it as reconstructed, never as the original source.

## Rung 4 — Unminified `rc`/i18n resources as the UI functional map

Resource and i18n files in the jar are usually shipped unminified. Their keys and strings describe the screens
and actions the UI offers, so they serve as a functional map of the UI independent of the bundle. Evidence
yielded: screen/label/action inventory. Cite the resource path and key.

## Citing the result

State the rung used, the file inside the jar, and the command. Reconstructed code from rungs 2-3 is evidence of
shape, not of original source; use `[INFER]` for anything that depends on a pairing the artifacts do not state.
