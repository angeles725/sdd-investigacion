# DEPLOY-CLOUDFLARE-WORKERS — deploying Cloudflare Workers via the REST API (no wrangler)

Gotchas and recipe for building and deploying a Cloudflare Worker directly against the Cloudflare
API, without `wrangler`: `node_modules/.bin/esbuild` for the build, a multipart request for the
deploy. Complements [`DEPLOY-STATIC-VERCEL-CLOUDFLARE.md`](DEPLOY-STATIC-VERCEL-CLOUDFLARE.md)
(Pages / static assets) and [`WINDOWS-SSH-BRINGUP.md`](WINDOWS-SSH-BRINGUP.md) (cloudflared
tunnels) — this file covers Worker **scripts** deployed by API.

_Source: pancaddia-leon-tunnel (TARGETS #32) corpus/retros/2026-09-14-incidente-pipeline-jace.md (A-1);
pancaddia-leon-tunnel (TARGETS #32) corpus/retros/2026-09-16-rediseno-reporte-html-pdf.md (R-1..R-4)._

## 1. Build with esbuild directly (no wrangler)

_Source: 2026-09-14-incidente-pipeline-jace.md · A-1(a)_

Run the vendored `esbuild` binary directly instead of going through `wrangler`:

```sh
node_modules/.bin/esbuild <entry.js> <your usual bundle flags> --external:'node:*'
```

`--external:'node:*'` is **mandatory** whenever the bundle imports a `node:` builtin (e.g.
`@cloudflare/puppeteer` imports `node:buffer`) — without it, esbuild fails to resolve the import at
**build** time. The `nodejs_compat` compatibility flag on the Worker resolves it at **runtime**
only; it does not substitute for the esbuild flag. (Source:
2026-09-16-rediseno-reporte-html-pdf.md · R-2)

## 2. Multipart deploy: the uploaded filename must match `main_module`

_Source: 2026-09-14-incidente-pipeline-jace.md · A-1(b)_

The multipart upload resolves the entry module **by filename**, not by field order: the uploaded
file's name must match the `main_module` value declared in the deploy metadata, or the API returns
error `10021`.

## 3. Secrets in a multipart deploy

_Source: 2026-09-14-incidente-pipeline-jace.md · A-1(c)_

Pass secrets as `secret_text` bindings inline in the deploy metadata (`metadata.bindings`), not as a
separate `wrangler secret put` step.

## 4. `inherit` bindings — redeploy without rotating secrets

_Source: 2026-09-16-rediseno-reporte-html-pdf.md · R-3_

To preserve a secret whose value is not available at deploy time (e.g. a redeploy from a build step
that never sees the secret), use an `inherit` binding in the deploy metadata instead of
`secret_text`:

```json
{"type": "inherit", "name": "SECRET_NAME"}
```

The runtime keeps the previously active binding for that name — a safe pattern for redeploys that
must not rotate or clear existing secrets.

## 5. `send_email` binding — one `EmailMessage` per recipient

_Source: 2026-09-14-incidente-pipeline-jace.md · A-1(d)_

Build the message as raw MIME and construct one `new EmailMessage(from, to, raw)` **per
recipient** (the pattern the source run used and verified).

## 6. Recovering the deployed ESM source: `/content/v2`, not `/content`

_Source: 2026-09-16-rediseno-reporte-html-pdf.md · R-1_

`GET /workers/scripts/{name}/content` returns **10405 "Method not allowed"** for ESM-module Workers
when called with an API token. This is **not** a permissions problem. The endpoint that recovers the
deployed source of an ESM module is:

```
GET /workers/scripts/{name}/content/v2
```

It returns the bundle as multipart, unminified. Pull the currently-deployed source back with it
before diffing or redeploying — the same discipline
[`DEPLOY-WINDOWS-MINIPC.md`](DEPLOY-WINDOWS-MINIPC.md) applies before overwriting a mini-PC deploy.

## 7. Pre-production review endpoint

_Source: 2026-09-16-rediseno-reporte-html-pdf.md · R-4_

Expose a review query parameter on the Worker itself (e.g. `?pdf=1` / `?html=1`) to render current
output on demand for visual inspection, without touching the cron trigger or sending anything.
Protect it with a simple review token; cost is zero when unused. Verify the render (e.g. with
`pdftoppm` for a PDF output) before trusting it against real recipients.
