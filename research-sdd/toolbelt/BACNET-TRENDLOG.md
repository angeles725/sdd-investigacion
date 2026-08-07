# Reading a BACnet trend-log buffer with ReadRange

How to pull historical samples straight out of a BACnet controller's **Trend Log** object (type 20)
instead of waiting for the head-end's historian, and — more importantly — **how far back it can
actually reach**, which is almost always less than people assume.

Evidence for every number below:
`corpus/sources/probes/trend-readrange/window-20260801T0430Z.txt` (Hilton Cancún target, 2026-08-01),
plus the per-controller harvest files beside it.

**Read-only.** ReadRange reads; it writes nothing. It is still traffic on a production fieldbus —
scope it, do not sweep blindly.

---

## 1. What you need before the first call

| Input | Where it comes from |
|---|---|
| Route to the controller (`Dnet` + `Dadr`) | the target's device census (`censo-equipos.csv`: `DeviceInstance,Dnet,Dadr,MacKind`) |
| Trend-log instance | the trend catalogue (`catalogo-tendencias.csv`: `log_device`, `log_instance`) |
| Which point that log records | same catalogue: `point_device`, `point_instance`, `interval_s` |

`Dadr` is a hex MAC. Two shapes appear and both work: a real Ethernet MAC (`00602d0570a9`) and an
Alerton virtual BACnet/IP address (`7f000001b4c3` = `127.0.0.1` + port `0xb4c3` = 46275).

A point identified as `<device>-<instance>` in a dictionary is NOT the trend-log's own address: map
`point_device/point_instance` → `log_device/log_instance` through the catalogue first.

## 2. The call

With Alerton's `bacnet_discover.ps1` (the wrapper this was measured on):

```powershell
& 'C:\rsdd-tools\bacnet_discover.ps1' -Mode trend `
    -Target 127.0.0.1 -Port 46272 `
    -Dnet 6000 -Dadr '7f000001b4c5' `
    -Ranges '1,41' -TrendCount 60 -TimeoutMs 6000
```

Returns one object per sample: `TrendInstance`, `Ts`, `Tipo`, `Valor`, `IntervaloSeg`,
`VentanaHoras`, `RegistrosEnBuffer`, `RegistrosTotales`.

`-Ranges` accepts a list, so **one call can serve several logs on the same controller** — which is
also how you avoid the non-re-entrancy trap (`REMOTE-POWERSHELL.md` §4.3).

⚠ `Ts` comes back as a **String**, not a DateTime. See `REMOTE-POWERSHELL.md` §4.1 — this silently
empties a whole harvest.

## 3. Read the metadata FIRST — it decides whether the job is possible

Three properties of the Trend Log object (type 20) tell you the reach before you pull anything:

| Prop | Name | Meaning |
|---|---|---|
| 141 | `record-count` | samples currently held in the **circular** buffer |
| 134 | `log-interval` | logging period, in **hundredths of a second** |
| 145 | `total-record-count` | lifetime count — NOT what you can read back |

**Window = `record-count` × `log-interval`.** Measured on one site, every log had a 256-record
buffer, and the interval alone decided the reach:

| interval | 256 records | reaches back |
|---|---|---|
| 3600 s (hourly) | 921,600 s | **10.7 days** |
| 600 s (10 min) | 153,600 s | **42.7 hours** |

Do not read `total-record-count` (e.g. `90873`) as depth. It is a lifetime odometer; the buffer still
holds 256.

## 4. The trap that decides what you actually get

**A large `-TrendCount` does not return the newest N records — it returns the OLDEST end.**

Same log (hourly, 256-record buffer), same session, three counts:

| `-TrendCount` | records decoded | range returned |
|---|---|---|
| 256 | 65 | 2026-07-21 10:55 → 2026-07-24 02:59 (**oldest** end) |
| 60 | 58 | 2026-07-29 11:59 → 2026-07-31 22:59 (**newest** end) |
| 20 | 20 | ends 2026-07-31 03:59 (**newest** end) |

Asking for the whole buffer got samples **ten days stale** and silently truncated at 65 — the
segmented ReadRange response is cut, and what survives is the start of the range, not the end.

**Practical ceiling: ~60 records per RESPONSE.** Not per buffer — see the next section.

**Rule**: ask for the smallest count that covers your gap, then verify the returned range covers
what you needed. A harvest that "worked" can still be answering about last week.

## 4b. Paginate, and the whole buffer is reachable

The wrapper's `trend` mode always starts at the end of the buffer (in the measured script:
`$desde = [int]$rc`). But the payload builder takes the start index as an **argument**:

```powershell
New-ReadRangePayload -Instance $inst -Index $idx -Count -60 `
                     -InvokeId $id -DestNet $script:Dnet -DestAdr $script:Dadr -HopCnt 255
```

So dot-source the script in `diag` mode (which loads the functions without running a mode), then
call `New-ReadRangePayload` / `Get-ReadRangeAck` yourself with a **decreasing** index. Measured on a
256-record, 10-minute log — the pages chain with no gap:

| `-Index` | records | range |
|---|---|---|
| 256 | 60 | 31 Jul 13:59 → 23:49 |
| 196 | 60 | 31 Jul 03:59 → 13:49 |
| 136 | 60 | 30 Jul 18:09 → 31 Jul 03:49 |
| 76 | 60 | 30 Jul 07:49 → 17:59 |
| 26 | — | no answer: `-Count -60` from index 26 runs past the start |

Stop before the count would cross index 1, or that page returns nothing at all.

With this, the reachable window is the **buffer's** (§3), not the response's. What does not change is
the hard floor: 42.7 hours on a 10-minute log. Past that the controller has overwritten the samples
and no amount of paging brings them back.

## 5. What this is good for, and what it is not

ReadRange is a **gap-filler**, not a historian:

- ✅ the collector was down for a few hours and the head-end has nothing → recover exactly the gap.
- ✅ confirm a point is still logging right now (a live `[CERT-hw]` reading).
- ❌ rebuilding weeks of history — the buffer already overwrote it.
- ❌ any point logging every 10 minutes, more than ~10 hours ago.

The consequence worth stating out loud: **with no collector running, fast-logging points lose their
history permanently every ~42 hours.** No later harvest can recover them. If a target needs that
history, the answer is a running collector, not a smarter read.

## 6. Sanity checks before you trust a harvest

1. **Empty value fields are normal and must be dropped, not parsed.** 65 of 1,403 rows came back with
   an empty value; a bare `float(...)` over the file crashes.
2. **Count the days you got, per point** — not the rows. Rows tell you the call worked; the day
   histogram tells you whether it answered the question.
3. **A partial day is worse than a missing day** if it feeds a per-day total: it lands as a real but
   short day. Decide the completeness rule before merging into any series.
