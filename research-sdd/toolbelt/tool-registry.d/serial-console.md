### serial-console (#2270, T8b)

| Tool | Description |
|---|---|
| `rsdd serial console list` / `check` / `run <target-dir> <com-port> <baud> <command>` | Go port (epic #2270, task T8b) of `serial-console.sh` (`rsdd/internal/serial/console`, registered in the `serial` domain next to `frame-analyze` and `frame-capture`). The row `serial-console.sh list \| check \| run ...` in the dynamic-phase table above still describes the modes, the evidence file under `sources/probes/` (`[CERT-hw]`), the WSLInterop binfmt gotcha (`DYNAMIC-SETUP.md` §5) and the exit contract: 0 ok, 2 bad arguments, 3 interop or `powershell.exe` absent, 4 the preservation directory could not be made, 5 the evidence file could not be written, otherwise PowerShell's own exit code (128+N when it was killed by signal N). `serial-console.sh` is now a compatibility shim (`rsdd_exec serial console "$@"`, same PID); `POWERSHELL_BIN` still overrides the binary. Every message keeps the script's `serial-console.sh:` prefix, and exit 3 keeps its legacy stderr verbatim (the entry is `PlainExit3`: no `DEGRADED:` line is added, because callers and retros cite those lines). The command sends ONLY the one command it is given and never opens a port by itself: the dynamic phase stays read-first, write-supervised (METHODOLOGY §12). |

The frozen pre-port script is `rsdd/internal/serial/console/testdata/legacy/serial-console.sh` (sha256 pinned by `TestFrozenLegacyScriptIsByteIdentical`).
`TestDifferential` runs every scenario of the table (usage and validation errors, a missing or non-executable binary, every `check` output
shape, `list`, `run`, the preservation failures, the exec failures, signals, stdin and environment pass-through, the target-directory
spellings) against that script and the Go command in two identical worlds, with `powershell.exe` replaced by shell stubs on a private
`PATH`, and requires the same stdout, stderr, exit code and file tree. `TestReplay` runs the same scenarios against the answers the
differential recorded (`testdata/recorded/scenarios.json`), so the checks also run without bash (the mutation run); `TestGolden` replays
`testdata/golden/<case>/` through the registry entry. Hand mutants of every guard are listed in the guard table at the head of
`scenario_test.go`.

The two messages of the script that name a path are written by coreutils (`mkdir -p` and `tee`), not by the script, and depend on the
locale; the port reproduces both, in the C locale and in a UTF-8 one (`LC_ALL`, then `LC_CTYPE`, then `LANG`): `mkdir: cannot create
directory '<dir>': <reason>` names the first component `mkdir -p` could not make, quoted in its locale style, and `tee: <path>: <reason>`
names the evidence file in its shell-escape style.

Intended divergences from the retired script (the first four are pinned: by the `exec-*` scenarios, `exec-noshebang-script-*`, the `*-killed-by-signal` scenarios and `TestCheckDropsNULBytes`):

- **A command that cannot be executed prints `serial-console.sh: <path>: <reason>`.** Bash prefixed the same text with its own script path and
  line (`<script>: line N: `), which has no equivalent. The reasons, the exit codes (126, 127) and everything else are the script's
  (`Is a directory`, `Permission denied`, `cannot execute binary file: Exec format error`, `cannot execute: required file not found`,
  `command not found`, `No such file or directory`). Under `run` the line still lands in the evidence file and on stdout, as before.
- **Text without a `#!` line is not run as a shell script.** Bash fell back to running a non-binary file the kernel refused (`ENOEXEC`) as a
  shell script; the port reports exit 126 and `cannot execute binary file: Exec format error`. A real PE binary (the WSLInterop case)
  gets the same text and code as before.
- **No job notice for a killed child.** Bash printed `<script>: line N: <pid> Killed ...` on stderr when PowerShell died from a signal;
  the port prints nothing and returns the same 128+N.
- **NUL bytes** in the output of `check` are dropped as a shell command substitution drops them, without bash's warning line.
- **stdout is released when the command ends** (the rsdd output contract: a panic must not leave a partial report); stderr is written
  immediately, and the evidence file is written as the response arrives. The script streamed stdout through `tee`.
- **`POWERSHELL_BIN` is resolved through `PATH` and `./path` only.** A shell builtin or function of the same name was found by
  `command -v` and ran in bash; the port does not look for one.
- **Locale texts are English** (`strerror`); a UTF-8 locale name that is not installed is treated as UTF-8, where coreutils falls back to C.
- **A `mkdir -p` parent directory gets the mode `0777` under the umask**, where coreutils adds owner write and execute; the two differ only
  under a umask that clears them.
