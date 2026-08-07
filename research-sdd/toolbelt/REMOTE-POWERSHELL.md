# Driving PowerShell on a Windows host through an SSH tunnel

How to run **non-interactive PowerShell** on a live Windows host reached through a Cloudflare Access
tunnel, get its output back intact, and not lose an hour to the five failure modes below.

Written from a real `live-install` session (Hilton Cancún, 2026-08-01) where every one of these
failures happened in sequence. Evidence:
`corpus/sources/probes/trend-readrange/window-20260801T0430Z.txt` in that target.

**Scope.** This is the transport layer — how to make a remote command run and report truthfully. It
says nothing about what to run. Pair it with the target's own wrappers (`connect-ssh.sh`, `fetch.sh`
or equivalents) and with `SECRETS DISCIPLINE` (METHODOLOGY §12) when the host is a client production
machine: enumerate structure, never read credential files.

---

## 1. The transport

A target that ships an SSH-over-Access wrapper usually exposes two entry points:

| Wrapper | Shape | Use it for |
|---|---|---|
| `connect-ssh.sh "<cmd>"` | opens a local TCP forward, runs one command, exits | any command whose output is TEXT |
| `fetch.sh '<remote path>' [dest]` | forward + `scp` on a **different** local port | pulling BINARY files back |

Two ports exist on purpose: a binary stream through the interactive path gets mangled by PowerShell.
Do not fetch binaries through `connect-ssh.sh`.

## 2. Always use `-EncodedCommand`, never a quoted string

The wrapper passes your command to the remote default shell, which re-parses it. Quotes, `$`, `|`
and `:` do not survive. A plain `powershell -c "(Get-Date).ToString('s')"` comes back as:

```
At line:1 char:9
+ 2026-07-31T23:13:47
+         ~
You must provide a value expression following the '-' operator.
```

That output is not an error in your script — it is the shell **evaluating your script's own output**
as a new command. The value is right there; it just came back as a parse error.

**The fix** — base64 the script as UTF-16LE and hand it to `-EncodedCommand`:

```bash
PS='Write-Output ("RES " + (Get-Date).ToString("s"))'
B64=$(python3 -c "import sys,base64;print(base64.b64encode(sys.argv[1].encode('utf-16-le')).decode())" "$PS")
./connect-ssh.sh "powershell -NoProfile -EncodedCommand $B64"
```

Nothing is re-parsed. Single quotes inside the PowerShell source are now safe.

## 3. Tag your output lines and filter for the tag

Remote PowerShell interleaves your stdout with a **CLIXML** envelope (progress records, verbose
streams, error records) that can run to hundreds of lines. Prefix every line you actually want and
filter on the prefix:

```bash
PS='... Write-Output ("RES " + $x.Name + " " + $x.Length) ...'
./connect-ssh.sh "powershell -NoProfile -EncodedCommand $B64" | rg "^RES"
```

Without the tag you will `tail` the output, see CLIXML, and conclude the command failed when it
succeeded.

---

## 4. The five failure modes, in the order they will bite you

### 4.1 `.ToString(<format>)` on a value that is already a String

The single most expensive one, because **it fails silently in a loop**. Many helper scripts return
`PSCustomObject`s whose date-like field is already a **String**. Calling
`$x.Ts.ToString('yyyy-MM-dd')` then raises:

```
Cannot find an overload for "ToString" and the argument count: "1".
CategoryInfo: NotSpecified: (:) [], MethodException
FullyQualifiedErrorId: MethodCountCouldNotFindBest
```

With `$ErrorActionPreference='Continue'` the loop keeps going, **your counters keep incrementing**,
and not one line is written. The run reports `1403 rows` and the file holds only its header.

**Fix**: coerce, then slice — `('' + $x.Ts).Substring(0,19)`. Check the type before formatting:
`$x.Ts.GetType().Name`.

### 4.2 A called script overwrites your variables

Invoking another script with `&` runs it in a scope that can clobber the caller's common variable
names. A run that used `$out` for its destination path lost it to the callee's own `$out`, and wrote
nothing.

**Fix**: prefix driver variables so they cannot collide (`$zzOut`, `$zzAcum`), and prefer building
the whole result in memory, writing **once** at the end:

```powershell
$zzAcum = New-Object System.Collections.Generic.List[string]
# ... $zzAcum.Add(...) ...
Set-Content -Path $zzRuta -Value $zzAcum -Encoding ASCII
```

This is also an order of magnitude faster than `Add-Content` per row.

### 4.3 Chained invocations of the same script in one process return nothing

Calling a socket-owning script 22 times in a row inside a single PowerShell process yielded **0
rows**, while the same call in isolation returned all of them. Assume any script that binds a UDP or
TCP port is **not** re-entrant within a process.

**Fix**: one invocation per connection. Batch by grouping at the *script's own* parameter level (a
range list, a multi-instance argument) rather than by looping the invocation:

```bash
# 11 connections for 22 objects, not 22 connections and not one 22-iteration loop
... -Ranges '1,41' ...
```

### 4.4 `ssh` eats the stdin of your `while read` loop

A `while read ... done < list.txt` loop that calls the wrapper inside consumes the rest of the list
on the first iteration, so the loop runs exactly once. This looks like "only the first host
answered".

**Fix**: `... | rg ... < /dev/null` on the wrapper call, or `ssh -n`.

### 4.5 `set -- $spec` inside a `for` loop (zsh)

Splitting a spec line into positional parameters inside `for spec in "a b c"` did not split under
zsh: `$1` kept the whole line, and the output file was literally named `rr60-2004 2000 7f00... .txt`.

**Fix**: use a shell function with real parameters, and quote nothing you intend to split:

```bash
cosecha () {  # $1=dev $2=net $3=addr $4=ranges $5=count
  ...
}
cosecha 6005 6000 7f000001b4c5 "1,41" 60
```

---

## 5. Clean up what you created on a client host

Anything staged on the host (a zip to pull, a CSV) must be removed in the same window, and the
removal recorded in the probe file:

```powershell
Remove-Item $zzRuta -Force -ErrorAction SilentlyContinue
Write-Output ("RES limpio=" + (-not (Test-Path $zzRuta)))
```

A probe window that created files and does not show their deletion is unfinished.

## 6. Pulling many files: stage one archive, fetch once, delete

22 files over 22 `scp` sessions is 22 tunnel setups. Compress on the host, fetch the single archive,
then delete it:

```powershell
Compress-Archive -Path ($dst + '\*.mdb') -DestinationPath $zip -Force
```

Measured: 13.2 MB of source files → a 4 MB archive → one `fetch.sh` call.
