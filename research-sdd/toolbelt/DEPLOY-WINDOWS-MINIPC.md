# DEPLOY-WINDOWS-MINIPC — deploying Node code to a Windows site mini-PC

Reusable recipe for shipping a pipeline delta (`*.mjs`, `*.json`) to an on-site
Windows mini-PC managed by Windows **Scheduled Tasks**, reached through a **Cloudflare Access
SSH tunnel**. Applies to any Niagara client whose data pipeline runs on a Windows site box.

_Source: panccadia-3d-viewer/retros/2026-09-04-deploy-windows-minipc.md; panccadia-3d-viewer/retros/2026-09-04-session-delta-b7-b9.md (PROMOTE candidate)._

## Target shape (assumptions)

- Remote host: Windows (default SSH shell is **PowerShell**).
- Code directory: `C:\<project>\pipeline\` (forward slashes in remote paths for `scp`).
- Processes managed by **Windows Scheduled Tasks** + optional watchdog — never launched manually.
- Reachable via Cloudflare Access SSH (`cloudflared access ssh --hostname %h` ProxyCommand).

## Recipe (step-by-step)

1. **Refresh the Access cert.** Short-lived certs expire between connections; a stale cert gives
   `Permission denied (publickey,...)`. Always run before connecting:
   ```sh
   cloudflared access ssh-gen --hostname <host>
   ```

2. **Open one multiplexed SSH master** and reuse it for every copy/command — survives tunnel
   flakiness, authenticates once:
   ```sh
   ssh -i ~/.cloudflared/<host>-cf_key \
       -o 'ProxyCommand=cloudflared access ssh --hostname %h' \
       -M -S /tmp/<host>.ctl \
       -o ControlPersist=180 -o ServerAliveInterval=15 -fN <user>@<host>
   ssh -S /tmp/<host>.ctl -O check <user>@<host>   # confirm master up
   ```

3. **Back up remote files** before overwriting (PowerShell via the master):
   ```sh
   ssh -S /tmp/<host>.ctl <user>@<host> \
       'Copy-Item C:\<project>\poller.mjs C:\<project>\poller.mjs.bak -Force'
   ```

4. **Copy with `scp -O`** (legacy SCP protocol — the sftp default fails to Windows OpenSSH
   when the remote path starts with a drive letter):
   ```sh
   scp -O -o ControlPath=/tmp/<host>.ctl \
       poller.mjs points.json write-server.mjs \
       <user>@<host>:C:/pancaddia/pipeline/
   ```
   Use **forward slashes** in the remote path; backslashes confuse zsh quoting.

5. **Verify byte sizes** remote vs local before restarting:
   ```sh
   ssh -S /tmp/<host>.ctl <user>@<host> \
       'Get-ChildItem C:\<project>\pipeline\poller.mjs,... | Select Name,Length,LastWriteTime'
   ```

6. **Restart via Scheduled Tasks** — not `taskkill` / manual node:
   ```sh
   ssh -S /tmp/<host>.ctl <user>@<host> \
       'Stop-ScheduledTask -TaskName PancaddiaPoller; Start-Sleep 2; Start-ScheduledTask -TaskName PancaddiaPoller'
   ```
   Confirm new PIDs: `Get-CimInstance Win32_Process | ? { $_.Name -eq "node.exe" } | Select ProcessId,CommandLine`.

7. **Verify end-to-end at the data layer** — not just "task is Running". Query the backend
   (e.g. Supabase `latest`) for a new record with a fresh timestamp and expected value. Do NOT
   touch `config.env` (holds secrets and the LAN `OBIX_BASE`).

## Gotchas

- **`schtasks /End` + `/Run` does NOT kill a detached `node` child.** The old process keeps the port and keeps
  serving stale code while the task reports "restarted". Kill the child first —
  `Get-CimInstance Win32_Process | Where-Object CommandLine -like '*<script>*' | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }`
  — then `schtasks /Run`, then verify the change took effect LIVE (a request against the served copy), not by
  the task status. (Source: panccadia-3d-viewer/retros/2026-09-05-kit-retro-document-runs-b10-b19.md D2; B17 §17.2)

- **`rc=$?` after a pipe reports the last command's exit, not the pipe's.** Piping `scp ... | grep`
  made a successful transfer appear as `rc=1` (grep matched nothing). This is the **exit-code-laundering
  family** documented in CLAUDE.md §7 (`rc=$?` after a producer/consumer pipe reports the consumer's
  exit, not the producer's). Verify transfer by effect: remote file sizes match, new PIDs, backend rows
  advance — not the piped rc.
- **PowerShell is the remote shell**, so `&` chaining fails (`AmpersandNotAllowed`); use `;`.
  Wrap the remote command in **zsh single quotes**; use **double quotes inside** for PowerShell strings,
  so `$_` reaches PowerShell literally instead of expanding in zsh.
- **oBIX forward and deploy are independent.** The mini-PC poller reads oBIX over the **LAN** directly,
  so the deploy does not need the WSL oBIX forward (`localhost:18443`) up. That forward is only for
  local inspection from WSL; relaunch it (`instalacion/.../tunnel-jace.sh`) when needed separately.
- **GitHub push may fail transiently over Cloudflare SSH** — retry once before diagnosing.

- **oBIX StatusNumeric write: use the `/value` child slot, not the parent.** A PUT to the parent
  `StatusNumeric` slot fails with `"Cannot translate"` and the parent never advertises its `/value`
  child in the oBIX discovery response. Write the setpoint with a bare real to the child slot:
  `PUT …/StatusNumeric/value` with body `<real val="<N>"/>`. An attribute-only form
  (`<obj val="<N>"/>` at the parent) is silently accepted but zeroes the setpoint instead of setting
  it. (Source: panccadia)

- **PowerShell 5.1 `Invoke-WebRequest` cannot reach a JACE self-signed TLS endpoint**, even with a
  custom `ServerCertificateValidationCallback` that unconditionally returns `$true` — the .NET
  `ServicePointManager` callback is ignored in non-interactive PS 5.1 sessions over SSH. Use Node.js
  for oBIX probes instead: `https.request({ rejectUnauthorized: false, … })` in a `.mjs` script works
  reliably. To avoid CLIXML noise from `powershell -EncodedCommand` over SSH, prefer `scp`-ing the
  `.mjs` to the remote and running `node script.mjs` directly rather than passing the script inline.
  (Source: panccadia)

- **`Win32_Process.CommandLine` returns `null` for SYSTEM-owned processes queried by a non-admin
  user** (e.g. `asus`) — filtering with `Where-Object CommandLine -like '*<script>*'` (as in step 6
  above) then silently matches nothing: a **false empty**, not a real absence. To detect/count a
  known process (e.g. the poller's `node`) instead, use `Get-Process -Name node` (returns PIDs
  without `CommandLine`, and does not require admin rights). After restart, confirm the expected
  `NODE_COUNT` (e.g. poller + write-server) to avoid leaving duplicate processes running, and verify
  by **telemetry** — a backend row's timestamp advancing — not by reading `poller.log`.
  (Source: Pancaddia-Leon-Guanajuato/corpus/retros/2026-09-22-monitor-jace-y-diagnostico-datos.md)
- **Diff before overwrite, not just byte-size.** Before step 4's copy, pull the currently-deployed
  file back and diff it against the repo copy — not just compare sizes (step 5) — to confirm the
  ONLY change is the intended one before touching production.
  (Source: Pancaddia-Leon-Guanajuato/corpus/retros/2026-09-22-monitor-jace-y-diagnostico-datos.md)

- **A long `wrangler pages deploy` can outlive the OAuth token** — the upload phase can take several
  minutes on a slow connection, and a short-lived browser OAuth session expires mid-flight, causing a
  mysterious auth error late in the upload rather than at the start. Recover with `wrangler login`
  (re-opens the SSO browser flow) rather than assuming credentials were absent or mismatched. Retry
  the deploy immediately after; credentials are cached and the second attempt completes without
  interruption. (Source: panccadia)
