# Dynamic phase — environment setup

## 0. First-run install (WSL2 Ubuntu)

Before anything else, run the kit installer to satisfy BASELINE dependencies and wire the
skill into your AI harness. This is idempotent — safe to re-run.

```bash
# BASELINE only (git, python3, jq, node ≥20, shellcheck, pipx, skill wiring):
bash research-sdd/install/install.sh

# With dynamic/network analysis tools:
bash research-sdd/install/install.sh --with-net --with-pcap

source ~/.bashrc   # reload env vars set by the installer
```

Use `--dry-run` to preview the full plan without touching anything.
See `research-sdd/install/install.sh --help` for all flags and heavy tiers.

---

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
- **WSL PATH clobber (LOW).** A Bash step can lose its `PATH` mid-run so core tools (`rg`, `head`,
  `tr`, etc.) report "command not found" unexpectedly. Defensively prepend
  `export PATH=/usr/local/bin:/usr/bin:/bin` at the top of each Bash invocation on WSL targets.

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

## 1c. Raw-image a physical/removable disk (when `wsl --mount` fails)

_Source: niagara-research/retros/2026-08-30-jace8000-sd-focus-retro.md (delta D1, HIGH)_

WSL auto-mounts only `C:`. A removable disk (SD card in a reader, USB stick) often cannot be reached
by `drvfs`, and `wsl --mount --bare \\.\PhysicalDrive<N>` frequently fails on removable media
(`error 0x8007000f — device not ready / not found`). §1b (usbipd) attaches the device but leaves
WSL without a driver for an exotic on-disk filesystem (→ §1d / no-mount parser). The reliable path is
**raw-image on the Windows side, analyze on the WSL side**:

1. From **Windows PowerShell** (elevated), find the disk: `Get-Disk` / `Get-Disk | Get-Partition` —
   note the `Number` and total `Size`. Confirm it is the right disk by size **before** touching it.
2. Raw-read the whole physical disk with a **robust** FileStream loop. Three gotchas make the naive
   loop silently wrong:
   - **A 0-length read is NOT EOF on `\\.\PhysicalDrive`.** The naive `while (($n = $fs.Read(...)) -gt 0)`
     stops early on a spurious short read → TRUNCATED image that looks complete. Drive the loop by the
     known total size (`Get-Disk.Size`), not by "read returned 0".
   - **Int32 overflow on a >2 GB disk.** `[Math]::Min($remaining, $chunk)` binds the `int,int` overload
     and silently caps any size above 2,147,483,647 to Int32. Cast every size/offset to `[long]`.
   - **Seek per chunk.** Seek to the running byte offset before each `Read` — never trust sequential
     position across a raw device handle.
   Record `errs=0` / exact byte count vs `Get-Disk.Size` as the completeness oracle
   (jace8000-sd B673: `4,018,143,232 B, errs=0`).
3. From **WSL**, analyze the `.img` read-only (partition table, per-partition offsets, `file`,
   `strings`, a userspace FS parser). Never write back to the physical device.

**The raw `.img` is secret-bearing** (it contains every partition's keyrings, shadow, config files) —
keep it in the scratchpad only; never commit it to `sources/` or the repo. Commit only the derived
tree/manifest (names + sizes + sha256 per file, identifiers masked). See PROMPT-LOOP SECRETS DISCIPLINE.

## 1d. USB-serial converter bridge (FTDI / CP210x → WSL `/dev/ttyUSB0`)

_Source: niagara-research retros, niagara jace9000 serial-capture work._

When a serial-only device (e.g. a Niagara JACE 9000 console port) must be captured from WSL and the
adapter is an FTDI or CP210x USB-serial converter, bridge it from the Windows COM port into WSL via
`usbipd` — the same mechanism as §1b, but the target is the USB-serial adapter rather than a storage
device.

**Workflow:**
1. From **Windows PowerShell** (NOT inside WSL): `usbipd list` — find the USB-serial adapter's `BUSID`
   (look for "USB Serial Converter", "Silicon Labs CP210x", or "FTDI"). Note the `BUSID` (e.g. `3-2`).
2. Bind (one-time, admin): `usbipd bind --busid <X-Y>`
3. Attach to WSL: `usbipd attach --wsl --busid <X-Y>`
4. Inside WSL: confirm with `ls /dev/ttyUSB*` — the adapter appears as `/dev/ttyUSB0` (or `ttyUSB1`
   if another is present). Verify with `udevadm info /dev/ttyUSB0 | grep -i serial`.
5. Run the capture: use `toolbelt/serial-frame-capture.sh` or `minicom`/`picocom` on the device.
6. **Detach when done — detach-verified safe-state gate.** From Windows PowerShell:
   `usbipd detach --busid <X-Y>`. Confirm the COM port reappears in Windows Device Manager before
   ending the session (the serial analogue of "device left safe").

### Operator-coordination obligation

Bridging a USB-serial adapter **disconnects it from Windows entirely** for the duration of the
attachment. If an operator is using the same adapter (e.g. their own terminal emulator on the JACE
console port), attaching it to WSL drops their session.

**Required before every attach:**
1. **Get explicit consent** from the operator that they are not using the adapter.
2. **Detach immediately** after capture is complete — do not leave it attached between sessions.
3. **Confirm the operator regained the device**: ask them to verify the COM port is visible again in
   Device Manager or their terminal emulator before the session ends.

Never attach without consent; never leave the adapter bridged overnight or across sessions.

### Common gotchas (USB-serial via USB/IP)
- `/dev/ttyUSB0` may need group permission: add your user to `dialout` (`sudo usermod -aG dialout $USER`,
  then re-login) or run capture tools with `sudo`.
- After `wsl --shutdown`, any active WSL USB attachment is dropped — re-attach after the VM restarts.
- On reattach, the device node index may change (`ttyUSB0` → `ttyUSB1`): always verify with `ls /dev/ttyUSB*`.
- `usbipd bind` is a one-time admin step per adapter; `attach` and `detach` do not require admin.

## 2. Protocol probe

Build a READ-ONLY probe — a byte-for-byte port of the decompiled protocol client (so frames match
exactly what the real software sends). Issue only READ commands; confirm read-only in the code first.
Run it through `toolbelt/probe.sh run <target-dir> <probe>` so the raw output is preserved in
`<target>/sources/probes/` as `[CERT-hw]` evidence.

### 2a. Binary-format RE tips

**Grep decompiled C source for `.cpp`/`.h` strings to map module structure.**
_Source: fluke-177x-datos/retros/2026-09-13-fluke-177x-protocol-re-campaign.md · prose delta 5_

Compiled Go and C++ binaries embed source-path strings in log/error messages. Before reading
function bodies, run:
```bash
grep '\.cpp"' <decompiled.c>   # or .h", .go, etc.
```
This yields a free module map — class names, file owners, call relationships — accelerating
directed sweeps with zero extra tooling.

**Rosetta-stone method for binary-format RE (input+output, full-diff validation).**
_Source: fluke-177x-datos/retros/2026-09-13-doctrina-detenerse-corto-y-explorar.md · row 5_

When reverse-engineering a binary format, look for an artifact that bundles BOTH the raw INPUT
and the parsed OUTPUT (e.g. an app-internal `.fca2` bundle that carries a `.fel.raw` alongside
its parquet export). This gives a 100 %-validatable ground truth: parse the raw input with your
decoder and compare byte-for-byte with the known-good output. Use this as the primary acceptance
gate before relying on partial structural observations alone.

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
- **`page.screenshot` times out on a live WebGL scene under software GL** — use CDP
  `Page.captureScreenshot` as the fallback (no stability wait; fires immediately).
  Alternatively, switch off the WebGL tab and screenshot a non-3D view first.
- **Relaunch the browser per viewport** — never reuse a Playwright browser context across viewport
  changes; context reuse reliably throws "Failed to open a new tab" on the software-GL path. One
  `chromium.launch()` per viewport measurement.
- **Confirm what the server is actually serving before each run.** A stale HTTP server left from a
  prior run can serve the wrong file on a reused port (e.g. `8791` still serving the 2D module while
  the 3D viewer is on `8799`). Start a fresh server on a fresh port and verify the `Content-Type`
  header or a known token in the page body.
- **CORS/origin boundary in e2e checks.** When the verified endpoint enforces an origin allowlist
  (e.g. only the production URL), a headless-from-localhost Playwright test is CORS-blocked by design —
  this is not a code bug. Confirm the backend contract out-of-band with `curl` (non-browser),
  and verify CORS headers separately. Source: niagara-research/retros/2026-09-03-live-cutover-and-authenticated-control-retro.md (#3).

_Source: niagara-research/retros/2026-09-03-research-sdd-document-mode-live-subject-retro.md (#3 T2); niagara-research/retros/2026-09-03-live-cutover-and-authenticated-control-retro.md (#3); panccadia-3d-viewer/retros/2026-09-03-panccadia-3d-viewer-document-run.md (T2)._

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

### 4b. Pre-deploy syntax check for a standalone HTML whose main `<script>` is `type="module"`

Validate the inline block AS A MODULE, not as a classic script: extract it and feed it to
`node --check --input-type=module` on STDIN (`--input-type=module` on a FILE path errors with
`ERR_INPUT_TYPE_NOT_ALLOWED`). Byte identity between local and served copies (md5) and matched `</script>` counts
do NOT catch a parse-MODE error — a mismatched quote passed a script-mode `node --check` and blanked the page in
production. Run the module-mode check as the last step before every deploy of such a viewer.
(Source: panccadia-3d-viewer/retros/2026-09-05-kit-retro-document-runs-b10-b19.md D1; B17 §17.3)

### 4c. Egress-heavy live viewer on a Realtime-backed table (reusable pattern)

When a viewer polls a hosted Realtime/database table and the plan is quota-bound, write only the rows that
CHANGED since the last cycle to the live table and debounce the client's per-change re-reads; the "live" feel
survives and egress/messages drop by about an order of magnitude (337 → ~17 rows per cycle in the field).
(Source: same retro, D5; B15 §15.2–§15.3)

### 4d. Managed background for persistent servers (run_in_background, not nohup)

_Source: fluke-177x-datos/retros/2026-09-13-replica-fea-dashboard-e-install.md · row 3_

For any server or process that must survive across multiple tool turns — a local HTTP server, a
dashboard, a polling loop — use the **managed background mechanism** (`run_in_background` parameter
on the Bash tool) instead of `nohup &`.

A process launched with `nohup &` inside a tool wrapper is killed when the wrapper exits (exit 144
in the sandbox). A process launched via `run_in_background` is handed off to the harness and survives
between turns.

**Rule:** if a process must be alive for the next tool call, `nohup &` is wrong; `run_in_background`
is the correct shape.

### 4e. pgrep self-match (daemon health checks)

_Source: api-paneles/retros/2026-09-11-paneles-completion.md · row 3_

`pgrep -f <pattern>` matches itself when the pattern string appears in the `pgrep` command's own
argv. This is common in zsh and silently returns a PID even when the target process is dead, making
daemon health checks falsely report "alive".

**Fix — prefer name-exact match:**
```bash
pgrep -x node          # exact process name; no self-match risk
```
When `-f` is unavoidable, filter the pgrep's own PID from the result:
```bash
pgrep -f <pattern> | grep -v "^$$\$"
```
**Evidence:** the pattern reproduced in `refresh-loop.sh` (api-paneles B9 §9.4).

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

### 6b. Persistent SSH local forwards (ssh -L) fail in the sandbox

_Source: fluke-177x-datos/retros/2026-09-13-fluke-177x-protocol-re-campaign.md · prose delta 3_

`ssh -L <local-port>:<host>:<remote-port>` requires keeping a persistent listening socket open.
The tool sandbox kills any such persistent process on exit (exit 144) — the same mechanism as the
`-M` master documented in §6a. One-shot remote commands (`ssh host "cmd"`) work; persistent
tunnels/listeners do not.

**Fix — sandbox shape:**
Any persistent tunnel or listener must be launched from the operator's real terminal (`wsl.exe`
or a `.bat` file), not from a Bash tool call. Then use `ssh host "cmd"` (one-shot per turn) to
send individual commands through the already-running tunnel.

**WSL2 note:** WSL2 only forwards `localhost` to listeners started via `wsl.exe`; a listener
started inside WSL via the Bash tool is not reachable from Windows at `localhost`.

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
