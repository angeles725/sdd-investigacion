package console

import (
	"fmt"
	"os"
	"strings"
)

// timestampLayout is `date -u +%Y%m%dT%H%M%SZ`, the stamp probe.sh and dynamic.sh use for their evidence too.
const timestampLayout = "20060102T150405Z"

func (e *env) ts() string { return e.s.Clock().UTC().Format(timestampLayout) }

// run sends ONE command to the device and preserves the raw response as evidence:
//
//	run <target-dir> <com-port> <baud> <command>
//
// The checks run in the script's order: argument count, a dash-leading target directory (so mkdir and tee can
// never misparse a caller-supplied path as an option), the COM port, the baud rate, the command, then the
// availability of PowerShell, and only then the preservation directory.
func (e *env) run(args []string) int {
	if len(args) != 4 {
		usage(e.s.Err)
		return exitUsage
	}
	tdir, port, baud, cmd := args[0], args[1], args[2], args[3]
	switch {
	case strings.HasPrefix(tdir, "-"):
		fmt.Fprintf(e.s.Err, "%s: <target-dir> must not start with '-': %s\n", tool, tdir)
		return exitUsage
	case !isComPort(port):
		fmt.Fprintf(e.s.Err, "%s: <com-port> must be COM<N> (e.g. COM3): %s\n", tool, port)
		return exitUsage
	case !isDecimal(baud):
		fmt.Fprintf(e.s.Err, "%s: <baud> must be numeric: %s\n", tool, baud)
		return exitUsage
	case cmd == "":
		fmt.Fprintf(e.s.Err, "%s: empty <command>\n", tool)
		return exitUsage
	}
	if !e.have() {
		return e.interopAbsent()
	}

	outdir := tdir + "/sources/probes"
	if failed, err := e.mkdirAll(outdir); err != nil {
		fmt.Fprintf(e.s.Err, "mkdir: cannot create directory %s: %s\n", e.quoteC(failed), err)
		fmt.Fprintf(e.s.Err, "%s: cannot create preservation dir: %s\n", tool, outdir)
		return exitMkdir
	}
	out := outdir + "/serial-" + port + "-" + e.ts() + ".txt"

	fmt.Fprintf(e.s.Out, "== serial run: [%s @ %s] %s -> %s ==\n", port, baud, cmd, out)
	t := e.openTee(out)
	fmt.Fprintf(t, "# serial-console run %s\n# port: %s  baud: %s  cmd: %s\n---\n", e.ts(), port, baud, cmd)
	psRC := e.spawn(runArgs(port, baud, cmd), t, t)
	teeRC := t.close()
	// Evidence integrity: the citation line is printed only when the tee that wrote the file succeeded AND the file
	// is on disk.
	fi, err := os.Stat(e.at(out))
	if !evidenceWritten(teeRC, fi, err) {
		fmt.Fprintf(e.s.Err, "%s: preservation FAILED — no evidence written to %s (tee rc=%d)\n", tool, out, teeRC)
		return exitEvidence
	}
	fmt.Fprintln(e.s.Out, "---")
	fmt.Fprintf(e.s.Out, "preserved: %s  (cite as [CERT-hw] evidence; rc=%d)\n", out, psRC)
	return psRC
}

// evidenceWritten is the integrity guard: the evidence counts as preserved only when the tee that wrote it ended
// well AND a regular file is on disk. Either alone is not enough: tee can fail after creating the file, and the
// file can be gone after a clean tee.
func evidenceWritten(teeRC int, fi os.FileInfo, statErr error) bool {
	return teeRC == 0 && statErr == nil && fi.Mode().IsRegular()
}

// isComPort is `COM[0-9]|COM[0-9][0-9]`.
func isComPort(s string) bool {
	if len(s) != 4 && len(s) != 5 || s[:3] != "COM" {
		return false
	}
	return isDigits(s[3:])
}

// isDecimal is the baud check: non-empty and nothing but ASCII digits (no range check, as in the script).
func isDecimal(s string) bool { return s != "" && isDigits(s) }

func isDigits(s string) bool {
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return false
		}
	}
	return true
}
