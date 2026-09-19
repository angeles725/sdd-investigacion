# DEPLOY-STATIC-VERCEL-CLOUDFLARE — deploying static sites / Cloudflare Pages / Vercel

Gotchas and rules for deploying static assets, CDN-backed dashboards, and Cloudflare Pages /
Vercel projects from a WSL/sandbox environment.

---

## 1. CDN asset verification before deploy

_Source: fluke-177x-datos/retros/2026-09-14-entrega-dashboard-supabase-pages.md · row 2_

Before depending on a CDN-hosted asset (JavaScript, CSS), verify that the exact pinned URL
returns HTTP 200. A version pin that does not exist on the CDN fails silently: the asset is
missing, the dependent feature breaks, and **no error appears in the rest of the page**.

**Evidence:** Chart.js 4.4.3 returned 404 on cdnjs; the chart rendered blank with no visible
JavaScript error.

**Check:**
```bash
curl -o /dev/null -sw '%{http_code}' <cdn-url>   # must be 200
```
Run this for every pinned CDN URL before deploying. A 404 must be resolved (pick a version that
exists) before publishing.

## 2. Prefer self-contained SVG over CDN libraries in dashboard artifacts

_Source: fluke-177x-datos/retros/2026-09-13-camino-b-end-to-end-completo.md · row 4_

When building a dashboard artifact with charts, prefer **self-contained SVG** rendered without
external CDN libraries over importing a chart library from a CDN. Do not assume a CDN library
will draw correctly — a missing or broken CDN reference fails silently, producing a blank chart
with no JavaScript error.

**Preference order:**
1. Self-contained SVG (inline; no network dependency at render time).
2. CDN library with §1 URL verification before every deploy.

**Evidence:** Dashboard published with Chart.js 4.4.3 from cdnjs came out blank; rewritten in
self-contained SVG rendered correctly.

## 3. Configure managed-backend schema via admin endpoint to avoid materializing keys

_Source: fluke-177x-datos/retros/2026-09-14-entrega-dashboard-supabase-pages.md · row 3_

When setting up a managed backend (Supabase, Firebase, etc.) during a deployment, use the
**administrative SQL/API endpoint** to create schema and load data, rather than materializing
the project's private keys into scripts or the environment.

- The **public `anon` key** is public by design; embed it only with explicit user authorization.
- The **service-role / admin key** must never be materialized in scripts, argv, or `sources/`.
  Use the provider's management API directly from a secrets.env (mode 600, git-ignored) — the
  PROMPT-LOOP SECRETS DISCIPLINE applies.

**Evidence:** The secrets classifier blocked fetching the service-role key; using the Supabase
Management API's SQL endpoint (`/rest/v1/`) created the full schema and loaded data without
requiring the service key to be materialized in the tool session.

## 4. wrangler Singleton-symlink failure (Cloudflare Pages deploy)

_Source: api-paneles/retros/2026-09-11-paneles-completion.md · row 4_

`wrangler pages deploy` fails when scanning the current working directory if Playwright's
`.userdata/` directory contains dangling `Singleton*` symlinks left by a previous Playwright
session. The error manifests as a symlink traversal failure during the directory scan, not as a
wrangler-specific error message.

**Fix:** run `wrangler pages deploy` from a **subdirectory** that does not contain `.userdata/`:
```bash
cd <project-subdirectory-without-userdata>
npx wrangler pages deploy
```
Or remove the dangling symlinks first:
```bash
find .userdata -name 'Singleton*' -type l -delete
```
**Evidence:** B9 §9.5; the failure reproduced in `refresh-loop.sh:36-37` (api-paneles).
