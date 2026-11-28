package console

import (
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"strings"
	"syscall"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kitmaint"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/probe"
)

// defaultBin is the PowerShell the command drives; POWERSHELL_BIN overrides it (portability and tests).
const defaultBin = "powershell.exe"

// The three argument lists the script passes to PowerShell, byte for byte.
var (
	checkArgs = []string{"-NoProfile", "-Command", "Write-Output OK"}
	listArgs  = []string{"-NoProfile", "-Command", "[System.IO.Ports.SerialPort]::GetPortNames()"}
)

// runArgs is the PowerShell invocation of `run`. The port name, baud rate and command are PowerShell ARGS
// ($args[0..2]), never interpolated into the script body, so a quote or newline in the command cannot break out of it.
func runArgs(port, baud, cmd string) []string {
	return []string{"-NoProfile", "-Command", psScript, port, baud, cmd}
}

// psScript drives .NET's SerialPort: open, write ONE line, drain the response, close.
const psScript = "\n" +
	"$ErrorActionPreference = \"Stop\"\n" +
	"$name = $args[0]; $baud = [int]$args[1]; $cmd = $args[2]\n" +
	"$port = New-Object System.IO.Ports.SerialPort $name, $baud, ([System.IO.Ports.Parity]::None), 8, ([System.IO.Ports.StopBits]::One)\n" +
	"$port.ReadTimeout = 4000\n" +
	"$port.NewLine = \"`n\"\n" +
	"try {\n" +
	"  $port.Open()\n" +
	"  $port.WriteLine($cmd)\n" +
	"  Start-Sleep -Milliseconds 800\n" +
	"  Write-Output $port.ReadExisting()\n" +
	"} finally {\n" +
	"  if ($port.IsOpen) { $port.Close() }\n" +
	"}"

// env is one invocation: the caller's streams and environment and the PowerShell it resolved.
type env struct {
	s      cli.Stdio
	bin    string // POWERSHELL_BIN, or powershell.exe when unset or empty
	prober *probe.Prober
}

func newEnv(s cli.Stdio) *env {
	bin := s.Env("POWERSHELL_BIN")
	if bin == "" {
		bin = defaultBin
	}
	return &env{s: s, bin: bin, prober: probe.New([]string{"PATH=" + s.Env("PATH")}, s.Cwd)}
}

// at anchors a relative path at the working directory the command was given, as the kernel would resolve it.
func (e *env) at(p string) string {
	if p == "" || strings.HasPrefix(p, "/") || e.s.Cwd == "" {
		return p
	}
	return e.s.Cwd + "/" + p
}

// have is `command -v "$bin" >/dev/null 2>&1 || [ -x "$bin" ]`.
func (e *env) have() bool {
	if _, err := e.prober.LookPath(e.bin); err == nil {
		return true
	}
	return e.prober.IsExec(e.bin)
}

// spawn runs PowerShell with the caller's stdin and environment and returns the shell's `$?`: its exit status,
// 128+N when it was killed by signal N, 126 or 127 (with the shell's own message on stderr) when it could not be
// executed. stdout and stderr may be the same writer, then the two streams keep their order like `2>&1`.
func (e *env) spawn(args []string, stdout, stderr io.Writer) int {
	path := e.bin
	if !strings.Contains(path, "/") {
		p, err := e.prober.LookPath(path)
		if err != nil { // present only as ./name in the cwd: the shell does not search there
			fmt.Fprintf(stderr, "%s: %s: command not found\n", tool, e.bin)
			return 127
		}
		path = p
	}
	cmd := &exec.Cmd{Path: path, Args: append([]string{e.bin}, args...), Dir: e.s.Cwd, Env: e.s.Environment(),
		Stdin: e.s.In, Stdout: stdout, Stderr: stderr}
	if err := cmd.Start(); err != nil {
		rc, text := e.startFailure(path, err)
		fmt.Fprintf(stderr, "%s: %s: %s\n", tool, path, text)
		return rc
	}
	_ = cmd.Wait()
	return kitmaint.ExitCode(cmd.ProcessState)
}

// startFailure is the shell's exit status and message for a program the kernel refused to execute.
func (e *env) startFailure(path string, err error) (int, string) {
	if fi, serr := os.Stat(e.at(path)); serr == nil && fi.IsDir() {
		return 126, "Is a directory"
	}
	switch {
	case errors.Is(err, syscall.ENOEXEC):
		return 126, "cannot execute binary file: Exec format error"
	case errors.Is(err, fs.ErrNotExist):
		if _, serr := os.Stat(e.at(path)); serr == nil { // the file is there: its interpreter is not
			return 127, "cannot execute: required file not found"
		}
		return 127, "No such file or directory"
	case errors.Is(err, fs.ErrPermission):
		return 126, "Permission denied"
	}
	if en, ok := errnoOf(err); ok {
		return 126, strerror(en)
	}
	return 126, err.Error()
}
