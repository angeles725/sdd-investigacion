// Package console is `rsdd serial console`, the Go port of toolbelt/serial-console.sh (kit issue #2270, T8b): the
// READ-ONLY serial/COM acquisition helper for a live-install device reached through a Windows COM port. WSL has no
// /dev/ttyS for a host COM port, so the command drives a Windows System.IO.Ports.SerialPort from Windows PowerShell
// over WSL interop (open the port, set the baud rate, write ONE command, read the response) and preserves the raw
// response under <target-dir>/sources/probes/ as [CERT-hw] evidence.
//
//	rsdd serial console list
//	rsdd serial console check
//	rsdd serial console run <target-dir> <com-port> <baud> <command>
//
// Every byte the script printed is kept, including its "serial-console.sh:" message prefix, because callers and
// retros cite those lines. The exit codes are the script's: 0 ok, 2 bad arguments, 3 interop or powershell absent,
// 4 the preservation directory could not be made, 5 the evidence file could not be written; on a successful run the
// exit mirrors PowerShell's own. Exit 3 keeps its legacy stderr (no DEGRADED: line), so the entry is PlainExit3.
//
// SAFETY (METHODOLOGY section 12): the dynamic phase is read-first, write-supervised. The command sends ONLY the
// single command it is handed; never wire a config-changing or destructive command (or a reboot) through it without
// explicit user OK, and never into an autonomous loop. EVIDENCE INTEGRITY: the "preserved: ... [CERT-hw]" line is
// printed only after the file is confirmed on disk and the write that made it succeeded.
package console

import (
	"bytes"
	"fmt"
	"io"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// Exit codes of the script.
const (
	exitUsage    = cli.ExitUsage
	exitInterop  = 3 // interop or powershell absent: the legacy graceful degrade
	exitMkdir    = 4 // preservation setup failed
	exitEvidence = 5 // run preservation failed
)

// tool is the name every message of the script carries, whatever the entry point is called.
const tool = "serial-console.sh"

// Command is the registry entry of the serial domain.
var Command = cli.Command{
	Name: "console", Group: "serial",
	Summary:    "read-only serial/COM acquisition through Windows PowerShell over WSL interop: list, check, run (evidence under sources/probes)",
	Run:        Run,
	PlainExit3: true,
}

// Run is the command: args[0] is the mode, the rest its arguments.
func Run(args []string, s cli.Stdio) int {
	mode := ""
	if len(args) > 0 {
		mode = args[0]
	}
	if mode == "" {
		usage(s.Err)
		return exitUsage
	}
	e := newEnv(s)
	switch mode {
	case "check":
		return e.check()
	case "list":
		return e.list()
	case "run":
		return e.run(args[1:])
	}
	fmt.Fprintf(s.Err, "unknown mode: %s (list|check|run)\n", mode)
	usage(s.Err)
	return exitUsage
}

func usage(w io.Writer) {
	fmt.Fprint(w, "usage:\n  serial-console.sh list\n  serial-console.sh check\n  serial-console.sh run <target-dir> <com-port> <baud> <command>\n")
}

// interopAbsent is the WSLInterop binfmt hint: powershell cannot be reached. If it prints 'exec format error' the
// binfmt_misc handler was dropped (wsl --shutdown, a systemd/binfmt race, a docker-desktop restart) and must be
// registered again from inside WSL as root.
func (e *env) interopAbsent() int {
	fmt.Fprintf(e.s.Err, "%s: cannot reach Windows PowerShell (%s).\n", tool, e.bin)
	fmt.Fprint(e.s.Err, "  If this is 'exec format error', WSLInterop binfmt_misc was dropped. Re-register (root, inside WSL):\n"+
		"    sudo sh -c 'echo :WSLInterop:M::MZ::/init:PF > /proc/sys/fs/binfmt_misc/register'\n"+
		"  (clear a stale handler first: echo -1 > /proc/sys/fs/binfmt_misc/WSLInterop)\n")
	return exitInterop
}

// check proves the interop handler actually executes the PE with a trivial round trip, not just that the file
// exists on PATH. The output is read the way a shell command substitution reads it: both streams merged, NUL bytes
// dropped, every trailing newline stripped, then one trailing carriage return (PowerShell prints CRLF).
func (e *env) check() int {
	if !e.have() {
		return e.interopAbsent()
	}
	var buf bytes.Buffer
	rc := e.spawn(checkArgs, &buf, &buf)
	out := strings.TrimRight(strings.ReplaceAll(buf.String(), "\x00", ""), "\n")
	if rc == 0 && strings.TrimSuffix(out, "\r") == "OK" {
		fmt.Fprintf(e.s.Out, "interop: OK (%s reachable)\n", e.bin)
		return 0
	}
	fmt.Fprintf(e.s.Err, "%s: powershell.exe present but did not execute cleanly:\n", tool)
	fmt.Fprintf(e.s.Err, "  %s\n", out)
	return e.interopAbsent()
}

// list enumerates the COM ports; PowerShell's streams and exit code pass straight through.
func (e *env) list() int {
	if !e.have() {
		return e.interopAbsent()
	}
	fmt.Fprintln(e.s.Out, "== COM ports (System.IO.Ports.SerialPort::GetPortNames) ==")
	return e.spawn(listArgs, e.s.Out, e.s.Err)
}
