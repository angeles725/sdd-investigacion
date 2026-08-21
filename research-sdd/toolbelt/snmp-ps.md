# SNMP v2c over PowerShell (Windows bridge, no net-snmp)

A PowerShell module for reading and writing SNMP v2c from a Windows bridge host that
ships only the `SNMPTrap` service (no `snmpget`, no `snmpwalk`, no net-snmp). Because
`ssh -L` cannot forward UDP/161, the probe runs ON the bridge over the existing SSH
channel. The module provides three functions: `Snmp-Get` (single OID), `Snmp-Walk`
(GET-NEXT loop with BER TLV decoder), and `Snmp-Set` (reversible write, saves and
restores the prior value).

This file is a `.md`, not a `.sh`. A shell test runner cannot exercise
PowerShell+UDP, so a companion `*.test.sh` would be toothless — exactly the violation
the strict-TDD mutation gate guards against (CLAUDE.md §4). Copy or dot-source the
module in a PowerShell session delivered over SSH.

---

## 1. BER helper module (dot-source before using any probe)

Paste or `scp` this block to the bridge host and dot-source it, or inline it at the
top of each probe script. Every function prefixed with `_` is internal.

```powershell
# ── BER encoding helpers ──────────────────────────────────────────────────────

function _BerLen([int]$n) {
    if ($n -lt 128) { return [byte[]]$n }
    $b = [System.Collections.Generic.List[byte]]::new()
    $t = $n
    while ($t) { $b.Insert(0, [byte]($t -band 0xFF)); $t = $t -shr 8 }
    [byte[]](0x80 -bor $b.Count) + $b.ToArray()
}

function _BerTlv([byte]$Tag, [byte[]]$Val) {
    [byte[]]$Tag + (_BerLen $Val.Length) + $Val
}

function _BerOid([string]$Dot) {
    $a = $Dot.TrimStart('.').Split('.') | ForEach-Object { [int]$_ }
    $e = [System.Collections.Generic.List[byte]]::new()
    $e.Add([byte]($a[0] * 40 + $a[1]))
    for ($i = 2; $i -lt $a.Length; $i++) {
        $v = $a[$i]
        if ($v -lt 128) { $e.Add([byte]$v); continue }
        $b = [System.Collections.Generic.List[byte]]::new()
        while ($v) { $b.Insert(0, [byte](($v -band 0x7F) -bor 0x80)); $v = $v -shr 7 }
        $b[$b.Count - 1] = $b[$b.Count - 1] -band 0x7F
        $e.AddRange($b)
    }
    _BerTlv 0x06 $e.ToArray()
}

# ── BER decoding helpers ──────────────────────────────────────────────────────

function _ReadLen([byte[]]$b, [ref]$p) {
    $f = $b[$p.Value]; $p.Value++
    if (-not ($f -band 0x80)) { return [int]$f }
    $nb = $f -band 0x7F; $L = 0
    for ($i = 0; $i -lt $nb; $i++) { $L = ($L -shl 8) -bor $b[$p.Value]; $p.Value++ }
    $L
}

function _ReadTlv([byte[]]$b, [ref]$p) {
    $tag = $b[$p.Value]; $p.Value++
    $len = _ReadLen $b $p
    $val = if ($len) { $b[$p.Value..($p.Value + $len - 1)] } else { [byte[]]@() }
    $p.Value += $len
    [pscustomobject]@{ Tag = $tag; Len = $len; Value = [byte[]]$val }
}

function _OidStr([byte[]]$e) {
    $a = [System.Collections.Generic.List[string]]::new()
    $a.Add([string][int][math]::Floor($e[0] / 40))
    $a.Add([string]($e[0] % 40))
    $v = 0
    for ($i = 1; $i -lt $e.Length; $i++) {
        $c = $e[$i]; $v = ($v -shl 7) -bor ($c -band 0x7F)
        if (-not ($c -band 0x80)) { $a.Add([string]$v); $v = 0 }
    }
    '.' + ($a -join '.')
}

function _ValStr([byte]$tag, [byte[]]$val) {
    switch ($tag) {
        0x02 { $n = 0; foreach ($b in $val) { $n = ($n -shl 8) -bor $b }; $n }       # Integer
        0x04 { [System.Text.Encoding]::UTF8.GetString($val) }                          # OctetString
        0x06 { _OidStr $val }                                                           # OID
        0x40 { ($val | ForEach-Object { "$_" }) -join '.' }                            # IpAddress
        { $_ -in 0x41, 0x42, 0x43, 0x46 } {                                           # Counter/Gauge/Ticks
            $n = 0; foreach ($b in $val) { $n = ($n -shl 8) -bor $b }; $n }
        0x05 { '(null)' }                                                               # Null
        default { '0x' + (($val | ForEach-Object { '{0:X2}' -f $_ }) -join '') }
    }
}

# ── Packet builder (shared by GET / GET-NEXT / SET) ───────────────────────────

function _SnmpPkt([string]$Comm, [byte]$PduTag, [string]$Oid, [byte[]]$ValTlv = @(0x05, 0x00)) {
    $vb  = _BerTlv 0x30 ((_BerOid $Oid) + $ValTlv)
    $vbl = _BerTlv 0x30 $vb
    $pdu = _BerTlv $PduTag (
        (_BerTlv 0x02 [byte[]](0x01)) +   # request-id
        (_BerTlv 0x02 [byte[]](0x00)) +   # error-status
        (_BerTlv 0x02 [byte[]](0x00)) +   # error-index
        $vbl)
    _BerTlv 0x30 (
        (_BerTlv 0x02 [byte[]](0x01)) +   # version = 1 (v2c)
        (_BerTlv 0x04 ([System.Text.Encoding]::ASCII.GetBytes($Comm))) +
        $pdu)
}

# ── Response decoder ──────────────────────────────────────────────────────────

function _ParseVarbinds([byte[]]$resp) {
    $p = [ref]0
    $outer = _ReadTlv $resp $p          # outer SEQUENCE
    $q = [ref]0
    $null = _ReadTlv $outer.Value $q    # version integer
    $null = _ReadTlv $outer.Value $q    # community string
    $pdu  = _ReadTlv $outer.Value $q    # GetResponse PDU (0xA2)
    $r = [ref]0
    $null = _ReadTlv $pdu.Value $r      # request-id
    $null = _ReadTlv $pdu.Value $r      # error-status
    $null = _ReadTlv $pdu.Value $r      # error-index
    $vbl  = _ReadTlv $pdu.Value $r      # varbind list
    $vp = [ref]0
    $out = [System.Collections.Generic.List[pscustomobject]]::new()
    while ($vp.Value -lt $vbl.Value.Length) {
        $vb  = _ReadTlv $vbl.Value $vp
        $wp  = [ref]0
        $oid = _ReadTlv $vb.Value $wp
        $val = _ReadTlv $vb.Value $wp
        $out.Add([pscustomobject]@{
            Oid   = _OidStr $oid.Value
            Type  = '0x{0:X2}' -f $val.Tag
            Value = _ValStr $val.Tag $val.Value
        })
    }
    , $out.ToArray()
}
```

---

## 2. GET — read a single OID

Sends one v2c GetRequest (PDU tag `0xA0`) and returns the first varbind.

```powershell
function Snmp-Get {
    param(
        [string]$Ip,
        [string]$Community = 'public',
        [string]$Oid       = '1.3.6.1.2.1.1.1.0',   # sysDescr
        [int]$Port         = 161,
        [int]$TimeoutMs    = 2000
    )
    $pkt = _SnmpPkt $Community 0xA0 $Oid
    $udp = [System.Net.Sockets.UdpClient]::new()
    $udp.Client.ReceiveTimeout = $TimeoutMs
    try {
        [void]$udp.Send($pkt, $pkt.Length, $Ip, $Port)
        $ep   = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
        $resp = $udp.Receive([ref]$ep)
        (_ParseVarbinds $resp)[0]
    } finally { $udp.Dispose() }
}
```

**Usage:**

```powershell
# sysDescr on a PDU at .53, public community
Snmp-Get -Ip '172.16.101.53' -Community 'public'
# → Oid: .1.3.6.1.2.1.1.1.0  Value: Model P24G01M, 200-240V 24A 5.0kVA
```

`[CERT-live]` liveread retro T2: GET on `.53` `public` → sysDescr `Model P24G01M,
200-240V 24A 5.0kVA`; positive control confirming `public` read risk.

---

## 3. Walk — GET-NEXT loop over an enterprise subtree

Sends repeated GetNextRequest (PDU tag `0xA1`) packets and decodes each BER TLV
response until the returned OID falls outside the root prefix. Walked 140 varbinds
of the Panduit PEN `19536.10` subtree against `.53` in one run.

```powershell
function Snmp-Walk {
    param(
        [string]$Ip,
        [string]$Community  = 'public',
        [string]$RootOid    = '1.3.6.1.2.1',   # MIB-II
        [int]$Port          = 161,
        [int]$TimeoutMs     = 2000,
        [int]$MaxVarbinds   = 1000
    )
    $udp = [System.Net.Sockets.UdpClient]::new()
    $udp.Client.ReceiveTimeout = $TimeoutMs
    $cur = $RootOid
    $out = [System.Collections.Generic.List[pscustomobject]]::new()
    try {
        while ($out.Count -lt $MaxVarbinds) {
            $pkt  = _SnmpPkt $Community 0xA1 $cur
            [void]$udp.Send($pkt, $pkt.Length, $Ip, $Port)
            $ep   = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
            $resp = $udp.Receive([ref]$ep)
            $vb   = (_ParseVarbinds $resp)[0]
            if ($null -eq $vb)                      { break }   # no response
            if (-not $vb.Oid.StartsWith($RootOid)) { break }   # past subtree
            if ($vb.Type -eq '0x82')               { break }   # endOfMibView
            $out.Add($vb)
            $cur = $vb.Oid
        }
    } finally { $udp.Dispose() }
    , $out.ToArray()
}
```

**Usage:**

```powershell
# Walk the Panduit enterprise subtree on .53
$varbinds = Snmp-Walk -Ip '172.16.101.53' -Community 'public' `
                      -RootOid '.1.3.6.1.4.1.19536.10'
$varbinds | Format-Table Oid, Type, Value -AutoSize
```

`[CERT-live]` SNMP RW retro T1 (B30 §30.2/§30.3): 140-varbind walk of
`19536.10` on `.53`; cross-validated 1:1 against Redfish (TotalVA 64/64,
TotalWatts 61/60) — the SNMP values are ground truth, not a parse artifact.
Evidence: `sources/probes/B30-snmp-2026-08-19/probe-snmp-walk-53.txt`.

---

## 4. SET — reversible write to prove write capability

Sends a v2c SetRequest (PDU tag `0xA3`) with an OctetString value. Always saves the
prior value first so a restore can be issued in any finally block. Use
`sysLocation` (`1.3.6.1.2.1.1.6.0`) as the canonical canary — it is cosmetic, but
**capture the actual current value per instance** rather than assuming a shared blank
default; a device that carries a location string will lose it if you restore to empty.

```powershell
function Snmp-Set {
    param(
        [string]$Ip,
        [string]$Community = 'private',
        [string]$Oid,
        [string]$Value,
        [int]$Port       = 161,
        [int]$TimeoutMs  = 2000
    )
    # 1. Capture current value — required for restore
    $before = Snmp-Get -Ip $Ip -Community $Community -Oid $Oid `
                       -Port $Port -TimeoutMs $TimeoutMs

    # 2. Build SET packet (OctetString value)
    $valTlv = _BerTlv 0x04 ([System.Text.Encoding]::ASCII.GetBytes($Value))
    $pkt    = _SnmpPkt $Community 0xA3 $Oid $valTlv
    $udp    = [System.Net.Sockets.UdpClient]::new()
    $udp.Client.ReceiveTimeout = $TimeoutMs
    try {
        [void]$udp.Send($pkt, $pkt.Length, $Ip, $Port)
        $ep   = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
        $resp = $udp.Receive([ref]$ep)
        $after = (_ParseVarbinds $resp)[0]
        [pscustomobject]@{
            Oid    = $Oid
            Before = $before.Value
            After  = $after.Value
        }
    } finally { $udp.Dispose() }
}
```

**Usage — reversible canary write:**

```powershell
$sysLocation = '1.3.6.1.2.1.1.6.0'
$result = Snmp-Set -Ip '172.16.101.53' -Community 'private' `
                   -Oid $sysLocation -Value 'RSDD-PROBE'
Write-Output "Before: $($result.Before) → After: $($result.After)"

# Restore in finally so the value is returned even if interrupted
try { <# other probes #> }
finally {
    Snmp-Set -Ip '172.16.101.53' -Community 'private' `
             -Oid $sysLocation -Value $result.Before | Out-Null
}
```

`[CERT-live]` SNMP RW retro T2 (B33 §33.3): reversible SET on `sysLocation` with
`private` community confirmed write capability (`private` echoed the marker; `public`
timed out — an observed fact about read/write community separation, not an inference).

---

## 5. Gotchas: SNMP-enabled ≠ SNMP-answering

Two non-obvious platform defaults that read as "this device has no SNMP" and cost
real time. Check both before concluding v2c is unavailable.

### (a) Agent version default may be v3

Some platforms default the SNMP agent to v3 only. A v2c GET is silently dropped —
no ICMP port-unreachable, no timeout error, just silence. The fix is in the device
UI: set the SNMP version to v1/v2c (the exact label varies by platform — e.g.
"Versión SNMP → V12C" on Panduit SmartZone).

### (b) Manager/allowlist IP `0.0.0.0` means deny-all, not "any"

On some UPS and FMPS platforms the v1/v2c manager allowlist entry `0.0.0.0` is
interpreted as "no manager configured" and every incoming GET is dropped regardless
of community string. The fix: set the allowlist entry to the querying host's IP
(the bridge, e.g. `172.16.101.59`).

`[CERT-live]` SNMP RW retro delta 3 (B32 §32.1): `.29` and `.42` were silent to all
v2c GETs until (a) agent version was set to V12C AND (b) the manager IP was set to
`172.16.101.59`; gen6 devices (already v1/v2c + open allowlist) were unaffected.

---

## Common gotchas summary

| # | Gotcha | Symptom | Fix |
|---|---|---|---|
| 1 | `ssh -L` used to forward SNMP | Port-forward succeeds; SNMP is silent (UDP not TCP) | Run probe ON bridge; use this module |
| 2 | `SNMPTrap` service only | `snmpget` / `snmpwalk` not found | Hand-built BER over `UdpClient` (this module) |
| 3 | Agent defaults to v3 | v2c GETs silently dropped | Set agent version to v1/v2c in device UI |
| 4 | Manager allowlist `0.0.0.0` = deny-all | All GETs silently dropped despite correct community | Set allowlist to bridge host's IP |
| 5 | `sysLocation` assumed blank across devices | Non-blank prior value lost after restore | Capture per-instance `Before` value; never assume shared default |

---

## Cross-reference

- For the SSH channel into the bridge host: `DYNAMIC-SETUP.md §6` (forward-TCP
  method; `connect-ssh.sh`).
- For general PowerShell-over-SSH gotchas (encoding, output capture, pipeline traps):
  `WINDOWS-SSH-PROBES.md`.
- For the bring-up checklist (sshd + cloudflared installation): `WINDOWS-SSH-BRINGUP.md`.
- METHODOLOGY §12 reversible-write recipe: read → SET marker → confirm → restore in
  `finally`; capture the per-instance prior value, never a shared default.

---

*Promoted from corpus §18 retros (METHODOLOGY §20 routing rule): computadoras B28–B33
(Panduit homelab SNMP integration, 2026-08-19) · liveread tool retro T2 (GET) · SNMP
RW retro T1/T2 (walk + reversible SET) · delta 3 (SNMP-enabled ≠ SNMP-answering
gotchas).*
