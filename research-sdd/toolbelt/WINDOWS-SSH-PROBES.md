# Windows/PowerShell-over-SSH probes

A documented pattern for driving PowerShell commands over SSH from this toolbelt.
Entry point: `connect-ssh.sh "powershell -NoProfile -EncodedCommand <b64>"` for
one-shot encoded invocations, or `scp` + file invocation for longer scripts.
Eight silent-failure gotchas have cost real time across multiple runs against live
Windows hosts (hilton-bms integration, compass-discover B1-B17).

---

## 1. Sending the script

### UTF-16LE base64 encoding for `-EncodedCommand`

Bash → SSH → PowerShell is three levels of quote interpretation. `-EncodedCommand`
eliminates all of them by encoding the script before it crosses any shell boundary:

```sh
b64=$(printf '%s' "$PS_SCRIPT" | iconv -f UTF-8 -t UTF-16LE | base64 -w0)
ssh host "powershell -NoProfile -EncodedCommand $b64"
```

`-w0` suppresses line-wrap in `base64`'s output; a wrapped base64 string is silently
truncated or causes a parse error on the PowerShell side. `iconv` must produce
UTF-16LE **without a BOM** — verify if quoting breaks after encoding.

### `-EncodedCommand` has a ~32 KB ceiling — fall back to `scp`

Windows' command-line limit is ~32 KB. A script larger than roughly 22 KB (after
base64 expansion) will be silently truncated or fail with an unhelpful PowerShell
parse error. The fix is to push the script to the host as a file and invoke it
directly:

```sh
scp script.ps1 host:C:\\temp\\script.ps1
ssh host "powershell -NoProfile -File C:\\temp\\script.ps1"
```

Use `push.sh` (the toolbelt's inverse of `fetch.sh`) to preserve the scp discipline;
delete the script from the host at session end.

---

## 2. Capturing output

### `Write-Host` produces CLIXML noise on the SSH channel

Over an SSH-hosted PowerShell session, `Write-Host` output is serialized as a CLIXML
`<Objs>` blob mixed into stdout. A probe whose output was ~80 % CLIXML XML was
effectively unreadable.

**Fix:** use bare strings or `Write-Output` for DATA you intend to parse. For
diagnostic or progress messages, use `Write-Verbose -Verbose` and merge streams
with `*>&1` when you want them in the same capture:

```powershell
# Data — captured cleanly
Write-Output "device=$id addr=$addr"

# Progress — survives capture with *>&1
Write-Verbose "scanning $id ..." -Verbose
```

Never `Write-Host` a value you plan to parse.

### `Out-String -Width N` buffers all output until the command ends

`Out-String -Width N` at the tail of a pipeline holds every converted line in
memory and flushes only when the command completes. In a sweep running hours over
SSH, a session cut before completion loses all work.

**Fix:** for any sweep that may run more than a few minutes, do NOT terminate the
output pipeline with `Out-String`. Emit objects or raw strings directly and add a
partial checkpoint every N iterations:

```powershell
foreach ($batch in $batches) {
    $batch | Export-Csv -Append -Path $outFile -NoTypeInformation
}
```

A session cut at any point then preserves results up to the last checkpoint. The
`-Width` flag is still valid for single-shot diagnostic output that completes quickly.

---

## 3. Pipeline traps

### `Select-Object -First N` terminates the upstream command

`Select-Object -First N` sends a **stop-processing** signal to the upstream command
the moment it has received N objects. When the upstream is a long-running native
(e.g. `tar`, a compression job, or a remote archiver), it receives SIGPIPE and exits
early — and reports success.

Evidence: a `tar` invocation piped through `Select-Object -First` produced a
2,691-of-23,678-entry archive that returned exit 0. The truncation was only caught by
an independent entry-count check taken BEFORE transfer.

**Fix:** never pipe a side-effecting upstream command through `Select-Object -First`.
Isolate long-running natives with `Start-Process -Wait -PassThru -RedirectStandardError`
so they run to completion before any downstream filtering:

```powershell
$p = Start-Process tar -ArgumentList $args -Wait -PassThru -RedirectStandardError stderr.log
if ($p.ExitCode -ne 0) { Get-Content stderr.log; throw "tar failed" }
```

Verify the entry count of the output before treating the run as complete.

---

## 4. PowerShell language traps (all silent)

These produce plausible wrong results instead of errors — the failure class that is
hardest to detect.

### Array-unroll trap — `,$x.ToArray()`

`return $list.ToArray()` delivers an `Object[]` to the caller, not the original
typed array. Passing an `Object[]` to `List[byte].AddRange()` throws
`Cannot convert "System.Object[]"` — which killed every APDU built in an affected
run by silently dropping the byte-level content.

**Fix:** suppress unrolling with a leading unary comma at the sender AND cast at the
receiver; one side alone does not reliably prevent the coercion:

```powershell
# sender
return ,$list.ToArray()

# receiver
[byte[]](Invoke-Builder $args)
```

### `$PID` and reserved automatic variables

PowerShell reserves several names as read-only automatic variables. Assigning to them
(e.g. as a loop variable) throws a non-obvious exception that kills the enclosing code
path with no operator-visible message. Common collision points:

| Reserved | Common collision |
|---|---|
| `$PID` | `foreach ($pid in $deviceList)` |
| `$Host` | remote-host tracking variable |
| `$Input` | pipeline input |
| `$Args` | function arguments |
| `$Error` | last error collection |

**Fix:** prefix loop and local variables with a short unique token (`$dev`, `$ep`,
`$item`). Treat the table above as a blocklist, not an exhaustive list.

### Variable names are case-insensitive

`$script:routeCache` and `$RouteCache` are the SAME variable. Initialising the
internal script-level copy to `$null` silently erases a parameter default that shared
the same spelling in different casing.

**Fix:** give internal state a prefix that never coincides with parameter names:

```powershell
param([hashtable]$RouteMap)        # caller-visible
$script:_routeMap = @{}            # internal — underscore prefix never clashes
```

---

## 5. Binary parsing trap

### Never delimit a binary or ASN.1 region by its closing-tag byte

Scanning a byte stream for a specific closing-tag value (e.g. BACnet context-closing
tag `0x4F`) finds that byte inside ANY payload — `0x4F` is ASCII `'O'` and appears
in every text field or string value. Every record after a false match desyncs silently.

This is not unique to BACnet: the same trap applies to any TLV format (ASN.1,
BER/DER, custom framing) where a terminal byte can appear in the data region.

**Fix:** walk tags by their **length** field. Advance the cursor by the declared field
length at each step; never scan forward for a terminal byte value.

---

## 6. Windows-native CLI from WSL (interop staging)

When a **Windows-native binary** (e.g. `kicad-cli.exe`, TIA Portal CLI, any IDE packaged for Windows only)
must be invoked from WSL, its output path MUST reside on the Windows filesystem. Two failure modes:

### UNC path failure — error 67

A Windows-native binary writing to a UNC path (`\\wsl.localhost\Ubuntu\home\...`) receives
**error 67 ("The network name cannot be found")** or silently discards its output. This is an
OS-level constraint on Windows native file I/O, not a bug in the tool.

**Fix:** stage both input and output under a Windows filesystem mount (`/mnt/c/tmp/<work>/`).
Copy Linux-resident source files there first, invoke the binary with a Windows-native path, then
copy results back to the Linux tree:

```sh
cp "$LINUX_SRC" /mnt/c/tmp/rsdd_work/input
cmd.exe /c "kicad-cli.exe pcb drc --input C:\\tmp\\rsdd_work\\input --output C:\\tmp\\rsdd_work\\out.json"
cp /mnt/c/tmp/rsdd_work/out.json "$RESULT_DIR/"
```

Use `cmd.exe /c` for plain invocations (one fewer quoting layer than `powershell -Command`).
Delete the staging directory at session end. Evidence: kidcad B50 — `kicad-cli.exe` refused DRC output
to `\\wsl.localhost\...`; routing via `/mnt/c` resolved error 67.

---

## Common gotchas summary

| # | Gotcha | Silent failure mode | Fix |
|---|---|---|---|
| 1 | UTF-16LE encoding omitted | Quoting corruption, parse error | `iconv -f UTF-8 -t UTF-16LE \| base64 -w0` |
| 2 | Script >~22 KB base64 | Silent truncation or parse error | Push with `scp`, invoke as `-File` |
| 3 | `Write-Host` on SSH channel | CLIXML `<Objs>` noise in stdout | Use `Write-Output` for data |
| 4 | `Out-String -Width` in long sweep | All output lost on session cut | Emit directly + partial checkpoint |
| 5 | `Select-Object -First N` on native | Upstream exits early, reports success | `Start-Process -Wait -PassThru` |
| 6 | `return $list.ToArray()` | `Object[]` coercion, `AddRange` throws | `,$list.ToArray()` + `[byte[]]()` cast |
| 7 | Reserved variable name (`$PID`, etc.) | Exception kills code path silently | Prefix loop vars: `$dev`, `$ep` |
| 8 | Case-insensitive shadowing | Internal init erases parameter default | Distinct prefix for internal state |
| 9 | Tag-byte scan for region end | Desync on first false match in payload | Walk by length field |
| 10 | Windows-native binary writing to UNC path (`\\wsl.localhost\...`) | Error 67 or silent output loss | Stage under `/mnt/c/...`; use `cmd.exe /c` for invocation |

---

## Cross-reference

- For serial-console one-shot PowerShell over WSL interop (not full SSH), see `DYNAMIC-SETUP.md §5`.
- For paramiko-based SSH (password-only, no `-EncodedCommand`), see `DYNAMIC-SETUP.md §6`.
- `push.sh` / `fetch.sh` — scp wrappers in the target's `tools/` directory.
- **Pre-flight syntax check before pushing any `.ps1`**: `pslint.sh <file.ps1>` (kit toolbelt) — parses the
  on-disk source with the same grammar Windows PowerShell 5.1 uses, so an author's own syntax error is caught
  locally instead of on a production host.
  **It does NOT catch gotchas #1 and #2.** Those are *transit-introduced*: #1 corrupts the script during the
  `-EncodedCommand` send, #2 truncates it there. `pslint.sh` runs on the pristine file BEFORE transit and
  structurally cannot see damage the channel inflicts afterwards. What it gives you against #1/#2 is
  **disambiguation**: if the source lints clean here and the remote still reports a parse error, the fault is
  the channel, not the script — which is the difference between re-reading your code and fixing your transport.

---

*Promoted from corpus §18 retros (METHODOLOGY §20 routing rule): integration P2 ·
compass-discover D5 / D10 / D19 · kidcad B50 (§6 Windows-native CLI staging).*
