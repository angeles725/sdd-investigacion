# Dynamic phase — environment setup

Prerequisites to reach a **live system** (device / server / PLC) from this environment and probe it
READ-ONLY (METHODOLOGY §12). Verify connectivity BEFORE building or running any probe.

## 1. Network reachability (WSL2 → host LAN)

WSL2 runs in an isolated NAT network (`172.x`), so it does NOT reach the host's physical LAN
(`192.168.x`) by default — a LAN device's ports will look closed even though a route "exists".

**Fix — mirrored networking** (Win11 22H2+ / WSL 2.0.0+):
1. Create/edit `C:\Users\<user>\.wslconfig`:
   ```ini
   [wsl2]
   networkingMode=mirrored
   ```
2. From **Windows PowerShell** (NOT inside WSL):
   ```powershell
   wsl --shutdown
   wsl --list --running     # must be empty
   ```
   First close EVERYTHING using WSL (all terminals, Claude Code, **Docker Desktop** — it pins the VM
   alive). If the VM doesn't shut down, mirrored won't take effect.
3. Reopen WSL. Verify it took: `ip -4 addr show` now shows the **host LAN IP** (e.g. `192.168.0.x`),
   not `172.x`.
4. Check the device: `toolbelt/probe.sh check <ip> <port...>`.

### Common gotchas (seen in the field)
- `wsl --shutdown` is a **Windows** command. Running it **inside** WSL gives `command not found`.
  Do NOT `sudo apt install wsl` — that's an unrelated package.
- Reopening Claude Code or the terminal does NOT restart the WSL VM. Only `wsl --shutdown` (with the
  VM fully released) re-reads `.wslconfig`.
- To revert: remove `networkingMode=mirrored` and `wsl --shutdown` again.

## 1b. USB device reach (USB/IP over WSL)

`networkingMode=mirrored` mirrors NETWORK only — it does **not** cover USB. USB is an exclusive
hardware resource handed off one device at a time via `usbipd-win`.

**Prerequisite (Windows side):** install `usbipd-win` (MSI from GitHub or `winget install usbipd`).

**Workflow:**
1. From **Windows PowerShell** (NOT inside WSL): `usbipd list` — find the `BUSID` (e.g. `1-8`).
2. Bind (one-time, admin): `usbipd bind --busid <X-Y>`
3. Attach to WSL: `usbipd attach --wsl --busid <X-Y>`
   — Windows **loses** the device at this point; the printer (or other hardware) is inaccessible
   from Windows until detach.
4. Inside WSL: `lsusb` to confirm; then read sysfs descriptors at `/sys/bus/usb/devices/<X-Y>/`.
5. **Detach when done — detach-verified safe-state gate.** From Windows PowerShell:
   `usbipd detach --busid <X-Y>`. Confirm Windows regained the device (the USB analogue of
   §12's "device left safe") before ending the session.

### Common gotchas (USB/IP)
- While attached to WSL, the device is **invisible to all Windows drivers** — printing, scanning, and
  other host-side use of the device are impossible until detach.
- `usbipd bind` is a one-time admin step per device; `attach` and `detach` do not require admin.
- After `wsl --shutdown`, any active WSL USB attachment is dropped — re-attach after the VM restarts.

## 2. Protocol probe

Build a READ-ONLY probe — a byte-for-byte port of the decompiled protocol client (so frames match
exactly what the real software sends). Issue only READ commands; confirm read-only in the code first.
Run it through `toolbelt/probe.sh run <target-dir> <probe>` so the raw output is preserved in
`<target>/sources/probes/` as `[CERT-hw]` evidence.

## 3. Read-first, write-supervised

Reads against a running system are safe when the protocol is read-only in RUN. **Writes** (load
program, change config, firmware update) are invasive — do them step-by-step with explicit user OK; a
bad write can brick a real device. Never wire a writing probe into an autonomous loop.

## 4. Browser / WebGL probes (rendering targets)

A rendering target (a WebGL / three.js app) is a "live system" too, but the §1–§3 device/protocol setup
does not fit it. Gotchas from the first web dynamic phase:
- **WSL Chrome needs software-GL flags.** Default flags fail WebGL context creation
  (`BindToCurrentSequence failed`); launch with `--use-angle=swiftshader --enable-unsafe-swiftshader`.
- **`file://` cannot run ES-module prototypes** — module imports are CORS-blocked. A local HTTP server is
  MANDATORY (e.g. `python3 -m http.server 8123` → `http://localhost:8123/`), not optional.
- **Software-GPU FPS is NOT representative — exclude it.** But **draw-call and triangle API counts ARE
  exact** regardless of GPU backend. State the distinction so a future phase does not discard the good
  metrics (call/triangle counts) along with the bad (FPS). Preserve the probe (`tools/probe.mjs`) and its
  launch flags as reusable `[CERT-hw]` evidence via `probe.sh`.

### 4a. Browser appliance / SPA web GUI (chrome-devtools MCP)

An appliance's web admin GUI (a login-gated SPA behind `https://<device>/`) is a "live system" too — you
drive its real DOM through the `chrome-devtools` MCP instead of porting a protocol. Field-tested recipe:

- **⚠ It drives the USER'S REAL browser.** The chrome-devtools MCP attaches to the user's actual Chrome —
  their other tabs are visible to you and any tab you open appears in THEIR session. Before driving it,
  either launch/point it at an ISOLATED, dedicated profile, or WARN the user first. This is not a headless
  sandbox; treat everything you can see as the user's private session.
- **Log in by filling fields + clicking submit** — fill the user/password inputs and click the button; let
  the PAGE hash the password client-side. Never reconstruct the auth request by hand (and keep the password
  out of argv/corpus per PROMPT-LOOP SECRETS DISCIPLINE).
- **Navigate by CLICKING menu items, NOT hash-URLs.** An SPA router ignores a direct `#/...` hash
  navigation and leaves the last-rendered submenu on screen → you read STALE content believing you moved.
  Observed repeatedly. Click the nav element and confirm the view changed.
- **Prefer the a11y `take_snapshot` over screenshots** — the accessibility tree is greppable, stable, and
  cheap; a screenshot is a last resort for something the tree cannot express.
- **Use `evaluate_script` for bulk field reads** — one script that harvests many config fields at once beats
  N snapshot round-trips. Preserve a sanitized capture under `sources/probes/` as `[CERT-hw]`.

## 5. Serial / COM console acquisition (SSH-off device)

When a live-install device is reachable ONLY over a serial port — SSH/Telnet are disabled and the network
path (§1) fails — acquire over the console via [`toolbelt/serial-console.sh`](serial-console.sh). It preserves
each response in `<target>/sources/probes/` as `[CERT-hw]`, the same discipline as `probe.sh`/`dynamic.sh`.

- **The link is owned by Windows, not Linux.** WSL has no `/dev/ttyS` for a host COM port, so the script
  drives a Windows `System.IO.Ports.SerialPort` (open → set baud → write ONE command → read response) through
  `powershell.exe` over WSL interop. `serial-console.sh list` enumerates COM ports; `run <target-dir>
  <com-port> <baud> <command>` sends a single READ command and preserves the output.
- **WSLInterop binfmt gotcha.** If `powershell.exe` / `cmd.exe` fail with `exec format error`, the
  WSLInterop `binfmt_misc` handler was dropped (common after `wsl --shutdown`, a systemd/binfmt race, or a
  docker-desktop restart). Re-register it from INSIDE WSL as root:
  ```sh
  sudo sh -c 'echo :WSLInterop:M::MZ::/init:PF > /proc/sys/fs/binfmt_misc/register'
  # clear a stale handler first if needed: echo -1 > /proc/sys/fs/binfmt_misc/WSLInterop
  ```
  `serial-console.sh check` detects this and prints the fix instead of a false run.
- **Read-first, write-supervised (§3 applies).** The wrapper sends only the single command you hand it. A
  config-changing/reboot command over serial can brick the device just like a bad network write — explicit
  user OK only, never in an autonomous loop, and label a mutation `⚠ CONFIG MUTATION` (PROMPT-LOOP LIVE-WRITE).

## 6. Scripted SSH (paramiko-in-venv fallback)

When the device DOES expose SSH but the login is password-only and `sshpass` is absent — and PEP-668 blocks a
system `pip install` — script the session with **paramiko in a throwaway venv**. This is the SAME
venv-per-tool pattern the kit already uses for tool installs (`install-tool.sh`), applied to SSH:

```sh
python3 -m venv <dir> && <dir>/bin/pip install paramiko
```

Then authenticate INSIDE the connect call, never on a command line:

- The password goes into the `password=` argument of `client.connect(...)` in a scratchpad-only Python
  script — NEVER in argv, the shell history, a probe cmdline, `sources/`, or the corpus (PROMPT-LOOP SECRETS
  DISCIPLINE). Keep the script in scratchpad and delete it at session end.
- Run READ commands (`client.exec_command(...)`), tee stdout to `<target>/sources/probes/` as `[CERT-hw]`,
  and keep the same read-first / write-supervised discipline as §3.

For the PowerShell-over-SSH gotcha catalog (encoding, output capture, buffering, and language traps), see [`WINDOWS-SSH-PROBES.md`](WINDOWS-SSH-PROBES.md).

### 6a. Cloudflare Access tunnel connect (sandboxed shell)

When a live-install host sits behind a **Cloudflare Access tunnel** and the only path in is through
`cloudflared`, the field pattern — a persistent backgrounded `cloudflared &` plus an `ssh -M -fN`
multiplexed master — **does not survive this sandbox**: the sandbox kills the persistent master (exit 144)
once the authenticated data-path goes persistent, even with `dangerouslyDisableSandbox`. The
`cloudflared access ssh` ProxyCommand is also unreliable (intermittent `websocket: bad handshake`).
Both are OUT for sandbox use.

The proven stable method is **forward-TCP + one foreground `ssh` per read**:

```sh
# 1. Forward a local TCP port through the tunnel (background — exits with the ssh)
cloudflared access tcp --hostname <host.example.com> --url 127.0.0.1:<PORT> &
CF_PID=$!
sleep 1   # allow the tunnel to negotiate

# 2. One foreground ssh per read; service token via env, never argv
CF_ACCESS_CLIENT_ID=<client-id> \
CF_ACCESS_CLIENT_SECRET=<client-secret> \
  ssh -p <PORT> -o StrictHostKeyChecking=no <user>@127.0.0.1 '<command>'

kill "$CF_PID" 2>/dev/null
```

**Why this shape:** one `ssh` per read is lightweight and avoids `MaxStartups` limits; the backgrounded
`cloudflared` exits with it and is not subject to the sandbox's long-lived-process kill. Source:
`~/tunnel/Cliente/Panduit/pruebas/client/connect-ssh.sh` (the operator's committed wrapper for B28–B33):
*"Metodo forward-TCP (estable; el ProxyCommand 'access ssh' a veces da 'websocket: bad handshake')"*.
On a **normal interactive shell** outside the sandbox the `-M` master pattern still applies
(`TRABAJANDO-CON-TUNELES.md §5`); this section is sandbox-only.

Keep the service token out of argv: load it from a `secrets.env` (mode 600, git-ignored) and export
it into the subprocess environment — PROMPT-LOOP SECRETS DISCIPLINE.

#### Origin-signal table

`cloudflared access` edge responses indicate connector health, but `websocket: bad handshake` is
**ambiguous** — it fires for two distinct causes. Never declare a box unreachable from it alone.

| Edge response | Cloudflare API (`status` / `conns_active_at`) | Interpretation |
|---|---|---|
| `websocket: bad handshake` | `status=down` · 0 connectors | Truly no origin — connector not running or host is off |
| `websocket: bad handshake` | `status=healthy` · conns present | **Access rejected unauthenticated client** — service token missing or wrong |
| `Connection reset by peer` | `status=healthy` · conns present | Origin reachable but SSH service broken (wrong port, not listening) |

**Rule:** on `bad handshake`, cross-check `GET …/cfd_tunnel/<id>` (`status`, `conns_active_at`) AND
retry WITH the Access service token (`CF_ACCESS_CLIENT_ID` + `CF_ACCESS_CLIENT_SECRET`). Only
`bad handshake` + API `status=down` / 0 connectors = truly no origin.

Evidence: liveread session 2026-08-19 — the tunnel was healthy throughout (4 active connectors,
`conns_active_at=2026-08-18T21:02Z`, `conns_inactive_at=None`) while repeated `cloudflared access`
calls returned `bad handshake` because the service token was absent. The B16–B25 retro had codified
`bad handshake = no origin` (B23.2); the liveread session corrected it — reconciliation verdict:
never codify the bare signal as unambiguous.

## 7. L2 discovery / firewalled-host identification (bridged segment)

When probing a segment reachable only through a bridge host, IP-layer probes alone cannot distinguish
a **powered-off** host from a **firewalled** one. These demand different remediation — the only chain
that separates them:

1. **Async ping sweep** — discovers hosts that answer ICMP.
2. **Async TCP-connect sweep** — discovers hosts that drop ICMP but have open ports.
3. **`Get-NetNeighbor` (ARP table)** — the decisive probe: SEEs L2-present hosts that are IP-silent.
   A host **absent from ARP** → powered off (not a credentials problem); a host **present in ARP**
   but silent to ICMP/TCP/SNMP → firewalled.
4. **OUI vendor lookup** (e.g., `api.macvendors.com`) — manufacturer from MAC prefix; identifies
   hardware class without touching the host.
5. **Reverse DNS** (`Resolve-DnsName -Type PTR`) — names the host from its IP even when no port is open.
6. **NBNS / NetBIOS node-status** (UDP 137) — Windows machine name without SMB.

Run steps 1–3 **on the bridge host** (SSH into it first) — ARP is per-segment and cannot traverse a
router hop. Steps 4–6 can run locally once MACs and IPs are collected.

Evidence (2026-08-19 homelab session): `Get-NetNeighbor` showed `.34` ARP-absent (→ powered off, not
a credentials problem) and revealed a new `.36` (L2-present, silent on ICMP/TCP/SNMP/BACnet). Reverse
DNS named `.36` = `MXC-RAYL-T14S` — a Lenovo ThinkPad T14s laptop, identified without a single open
port.
