# Cloudflare-Tunnel + Windows-SSH bring-up

Five compiled scars from provisioning a live-install Windows SSH appliance (`sshd` +
`cloudflared`) from scratch. Each scar produced a silent failure or a multi-hour
lockout on a physically-inaccessible box; each has a one-line fix. Read these before
touching a box's SSH or tunnel configuration.

These lessons first surfaced in B16 §16.12 (self-proposed, not routed through a retro
at the time), were reinforced across B16–B23, and were compiled in B24 §24.2 as the
template for the `tunnel/Cliente/NavePanccadia/` bundle.

---

## 1. Host-key ACLs before first `Start-Service`

OpenSSH on Windows stores host keys under `C:\ProgramData\ssh\`. The service fails
silently if the ACL on that directory or the key files does not grant the `NETWORK
SERVICE` account read access. The failure looks identical to "SSH not installed".

**Fix:** before the first `Start-Service sshd`, run the ACL repair step:

```powershell
$acl = Get-Acl 'C:\ProgramData\ssh'
$rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
    'NT AUTHORITY\NETWORK SERVICE', 'Read', 'ContainerInherit,ObjectInherit',
    'None', 'Allow')
$acl.SetAccessRule($rule)
Set-Acl 'C:\ProgramData\ssh' $acl
```

Then verify: `Get-Service sshd | Select-Object Status` should show `Running` after
`Start-Service`. A service that starts then immediately stops has an ACL or key
problem, not a port conflict.

Evidence: B16 §16.12 (self-proposed; six package defects found and fixed across five
real runs).

---

## 2. Firewall rule: always `-Profile Any`

Adding a firewall rule with `-Profile Private` or `-Profile Domain` leaves the rule
inactive when the NIC is reclassified as `Public` — which Windows does silently on
reconnect, DHCP renewal, or after a suspend/resume cycle. SSH becomes unreachable from
that moment with no error; the service is running and the port is open, but the firewall
drops the packet.

**Fix:** always use `-Profile Any` for the SSH inbound rule:

```powershell
New-NetFirewallRule -DisplayName 'OpenSSH Server (sshd)' `
    -Enabled True -Direction Inbound -Protocol TCP `
    -LocalPort 22 -Action Allow -Profile Any
```

Verify the effective profile: `Get-NetFirewallRule -DisplayName 'OpenSSH*' | Select-Object Profile`.

Evidence: B16 §16.20 (`-Profile` flips to Public on reconnect; "a channel that depends
on state which silently resets").

---

## 3. `cloudflared` and `sshd` services are machine-bound

A Windows service registration (`sc.exe create` or `New-Service`) binds to the current
machine's SAM and registry hive. You cannot copy a `cloudflared` or `sshd` service
registration from one machine to another by imaging the disk or copying registry keys —
the service will fail to start on the target machine.

**Fix:** re-register the service on each machine:

```powershell
# cloudflared (example — adapt path and tunnel token)
& 'C:\cloudflared\cloudflared.exe' service install
```

```powershell
# sshd — installed by the OpenSSH feature, not sc.exe
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Start-Service sshd
Set-Service  sshd -StartupType Automatic
```

Evidence: B24 §24.2 (five compiled lessons; "cloudflared/sshd as a SERVICE not
portable across machines").

---

## 4. Never `sc.exe create` a `sshd` marked for deletion

If a previous `sc.exe delete sshd` was issued but the service process had not yet fully
stopped, Windows marks `sshd` for pending deletion. A subsequent `sc.exe create sshd`
silently fails — it returns success but the service is never actually registered and
does not appear in Services. The mark persists across reboots until the original process
exits.

**Fix:** after any `sc.exe delete`, verify the service is truly gone before re-creating:

```powershell
# Wait for the service to disappear
while (Get-Service sshd -ErrorAction SilentlyContinue) { Start-Sleep 2 }
# Now it is safe to reinstall
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
```

Never use `sc.exe create sshd` directly — use the Windows capability installer so that
the service is registered through the correct channel with correct binary paths and
security descriptors.

Evidence: B24 §24.2 ("never `sc.exe create` a `sshd` marked for deletion").

---

## 5. Verify safety-net tasks before proceeding

Any automation that is supposed to recover the box if something goes wrong (a scheduled
task that re-enables SSH, restores a firewall rule, or reverts a network change) must be
explicitly verified to exist before the risky step runs. PowerShell's
`New-ScheduledTaskAction` can silently reject its argument and return no error; the task
is never registered, and the risky action proceeds unprotected.

**Fix:** register the rescue task, read it back, and abort if absent:

```powershell
Register-ScheduledTask -TaskName 'SshRestore' -Action $action -Trigger $trigger `
    -RunLevel Highest -Force | Out-Null

$registered = Get-ScheduledTask -TaskName 'SshRestore' -ErrorAction SilentlyContinue
if (-not $registered) {
    throw 'Safety-net task not registered — aborting risky step'
}

# Only now proceed with the change that needs a net
```

Evidence: B16 §16.20 anti-pattern (`New-ScheduledTaskAction` silently rejected its
argument; the rescue task was never registered; the risky action proceeded with the
channel unprotected for ~1 minute); B24 §24.5.

---

## 6. Hung `sshd`: `Get-Service` reports Running (watchdog pattern)

On Windows OpenSSH benches `Get-Service sshd` can report `Running` while the daemon accepts the TCP
connection and never sends its banner. Service status cannot tell hung from alive, so a status check is
not a health check.

**Pattern.** Probe what a client sees: open a TCP connection to port 22 and read the SSH banner
(`SSH-2.0-...`) with a timeout (about 8 s). On a connect failure, a banner timeout or a banner that does
not start with `SSH-`, run `Restart-Service sshd` and append a line to a log (`sshd HUNG ... RECOVERED`
or `... RESTART FAILED`). Run it periodically as a scheduled task under `SYSTEM`. The task's installation
is itself verified before you rely on it: register, read back with `Get-ScheduledTask`, and abort if
absent (see section 5).

**Reference snippet (reference only, NOT a shipped tool).** The kit ships no watchdog script; adapt and
test this on the bench before trusting it.

```powershell
$log = 'C:\ProgramData\watchdog\sshd-watchdog.log'
function Test-SshBanner {
    $c = New-Object Net.Sockets.TcpClient
    try {
        $iar = $c.BeginConnect('127.0.0.1', 22, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne(8000)) { return $false }
        $c.EndConnect($iar)
        $s = $c.GetStream(); $s.ReadTimeout = 8000
        $buf = New-Object byte[] 64; $n = $s.Read($buf, 0, 64)
        return ($n -gt 0 -and [Text.Encoding]::ASCII.GetString($buf, 0, $n).StartsWith('SSH-'))
    } catch { return $false } finally { $c.Close() }
}
if (-not (Test-SshBanner)) {
    Restart-Service sshd -ErrorAction Stop
    Add-Content $log "$(Get-Date -Format o) sshd HUNG ... restarted"
}
```

**Provenance.** The probed original (`watchdog-servicios.ps1` v2) lives only on bench `pruebas-01`; on its
first run (2026-10-07) it detected and recovered a hung `sshd`. This section is the pattern, not that
file. (Kit #1961.)

---

## Scars summary

| # | Scar | Silent failure mode | Fix |
|---|---|---|---|
| 1 | Host-key ACLs missing | `sshd` starts then stops silently | Set `NETWORK SERVICE` read ACL before first `Start-Service` |
| 2 | Firewall `-Profile Private` | SSH drops on NIC reclassification | Always use `-Profile Any` |
| 3 | Service registration copied across machines | Service fails to start on target | Re-register per machine using the feature installer |
| 4 | `sc.exe create` on a pending-delete sshd | Service never registered, returns success | Wait for clean deletion; use `Add-WindowsCapability` |
| 5 | Safety-net task assumed not verified | Risky step runs unprotected | Register → read back → abort if absent |
| 6 | `sshd` hung while `Get-Service` says Running | Service status lies; SSH banner never arrives | Watchdog: TCP connect + banner read with timeout, `Restart-Service sshd` on failure (§6) |

---

## Cross-reference

- For connecting TO the bridge host from a sandbox: `DYNAMIC-SETUP.md §6`
  (forward-TCP method; backgrounded `cloudflared access tcp &` + foreground `ssh`).
- For PowerShell-over-SSH silent-failure gotchas after the channel is up:
  `WINDOWS-SSH-PROBES.md`.
- For SNMP probes run ON the bridge (no net-snmp): `snmp-ps.md`.
- METHODOLOGY §12: reboot on a physically-inaccessible host is destructive-equivalent;
  require an independent fallback confirmed to exist before issuing it.

---

*Promoted from corpus §18 retros (METHODOLOGY §20 routing rule): computadoras B16
§16.12 (self-proposed, unrouted at the time) · B16 §16.20 (firewall profile + safety-net
task anti-pattern) · B24 §24.2 (five compiled lessons) · B24 §24.5.*
