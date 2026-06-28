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

## 2. Protocol probe

Build a READ-ONLY probe — a byte-for-byte port of the decompiled protocol client (so frames match
exactly what the real software sends). Issue only READ commands; confirm read-only in the code first.
Run it through `toolbelt/probe.sh run <target-dir> <probe>` so the raw output is preserved in
`<target>/sources/probes/` as `[CERT-hw]` evidence.

## 3. Read-first, write-supervised

Reads against a running system are safe when the protocol is read-only in RUN. **Writes** (load
program, change config, firmware update) are invasive — do them step-by-step with explicit user OK; a
bad write can brick a real device. Never wire a writing probe into an autonomous loop.
