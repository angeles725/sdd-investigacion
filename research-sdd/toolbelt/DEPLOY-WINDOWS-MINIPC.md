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
