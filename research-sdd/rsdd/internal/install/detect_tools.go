package install

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// `rsdd install detect-tools` is the Go port of toolbelt/detect-tools.sh: probe the REAL availability of the
// RE/decompile tools (never `which` alone: a tool can sit in a linuxbrew Cellar, a dotnet tools dir or a jar path
// and be absent from PATH) and print a capability report, cached to a file. Read-only: it installs nothing.
//
// Contract, unchanged from the script: exit 0 = report produced; 1 = a --require gate failed or the cache could not
// be written; 2 = usage error or an unknown --require tool. Status values: AVAILABLE | UNUSABLE | MISSING |
// PROBE_FAILED (the probe could not complete: timeout or no timeout(1), distinct from MISSING). Tool resolution is
// core/probe (the lib/tool-env.sh port); the run-probes live in detect_probe.go.
//
// Differences from the script, by design: the usage line and the "cannot ..." messages name the program the shim
// passes as --prog (the shim's own path), a bare `--cache`/`--cache ''` prints a plain message instead of bash's
// "line N: 2: path" (exit 1 kept), the report date comes from the clock, not date(1), and probe children read
// /dev/null as stdin.

// detectName is the program name used when none is passed with --prog.
const detectName = "detect-tools.sh"

const detectUsageArgs = "[--cache <file>] [--quiet] [--require <tool>[,<tool>...]]"

// detectToolsRun is the Main contract of `rsdd install detect-tools`.
func detectToolsRun(args []string, s cli.Stdio) int { return runDetect(args, s, nil) }

// runDetect is detectToolsRun with a hook that adjusts the detector (tests relocate the fixed host paths and
// replace the Java and Ghidra resolvers).
func runDetect(args []string, s cli.Stdio, tweak func(*detector)) int {
	prog := detectName
	if len(args) >= 2 && args[0] == "--prog" {
		prog, args = args[1], args[2:]
	}
	d := newDetector(s.Environment(), s.Cwd)
	if tweak != nil {
		tweak(d)
	}

	cache := d.get("RESEARCH_TOOLS_CACHE")
	if cache == "" {
		base := d.get("XDG_CACHE_HOME")
		if base == "" {
			base = d.get("HOME") + "/.cache"
		}
		cache = base + "/research-sdd/tool-capabilities.txt"
	}
	quiet, require := false, ""
	usage := func() int {
		fmt.Fprintf(s.Err, "usage: %s %s\n", prog, detectUsageArgs)
		return cli.ExitUsage
	}
	for i := 0; i < len(args); {
		switch args[i] {
		case "--cache":
			if i+1 >= len(args) || args[i+1] == "" {
				fmt.Fprintf(s.Err, "%s: --cache: a path is required\n", prog)
				return cli.ExitOperational
			}
			cache, i = args[i+1], i+2
		case "--quiet":
			quiet, i = true, i+1
		case "--require":
			if i+1 >= len(args) || args[i+1] == "" {
				return usage()
			}
			require, i = args[i+1], i+2
		default:
			return usage()
		}
	}

	// The script ran under `set -u`: an unset HOME ended it with exit 1. An empty HOME is set and allowed.
	if _, set := d.env["HOME"]; !set {
		fmt.Fprintf(s.Err, "%s: HOME: unbound variable\n", filepath.Base(prog))
		return cli.ExitOperational
	}
	var errw bytes.Buffer
	out := d.report(s.Clock(), &errw)
	_, _ = s.Err.Write(errw.Bytes())

	name := filepath.Base(prog)
	dir := dirname(cache)
	if err := os.MkdirAll(d.abs(dir), 0o777); err != nil {
		fmt.Fprintf(s.Err, "%s: cannot create cache directory: %s\n", name, dir)
		return cli.ExitOperational
	}
	if err := os.WriteFile(d.abs(cache), []byte(out+"\n"), 0o666); err != nil {
		fmt.Fprintf(s.Err, "%s: cannot write cache file: %s\n", name, cache)
		return cli.ExitOperational
	}
	if quiet {
		fmt.Fprintf(s.Out, "tool capability report cached → %s\n", cache)
	} else {
		fmt.Fprintf(s.Out, "%s\n", out)
	}
	if require == "" {
		return cli.ExitOK
	}
	return requireGate(out, require, name, s)
}

// dirname is dirname(1): trailing slashes do not count, no slash gives ".".
func dirname(p string) string {
	if t := strings.TrimRight(p, "/"); t != "" {
		p = t
	}
	return filepath.Dir(p)
}

var statusWord = regexp.MustCompile(`AVAILABLE|UNUSABLE|MISSING|PROBE_FAILED`)

// statusOf is the status of a label in the report: the first status word of the first line holding
// "  <label> " (`grep -F | grep -oE | head -1`), "" when no such line carries one.
func statusOf(report, label string) string {
	for _, ln := range strings.Split(report, "\n") {
		if strings.Contains(ln, "  "+label+" ") {
			if w := statusWord.FindString(ln); w != "" {
				return w
			}
		}
	}
	return ""
}

// requireGate is the --require gate: evaluated after the report is produced so --quiet and --cache still work.
// Every named tool is judged in order; an unknown name ends the run with exit 2 at once.
func requireGate(report, require, name string, s cli.Stdio) int {
	rc := cli.ExitOK
	list, _, _ := strings.Cut(require, "\n") // `read` takes the first line only
	tools := strings.Split(list, ",")
	if n := len(tools); n > 1 && tools[n-1] == "" {
		tools = tools[:n-1] // read drops one trailing separator
	}
	for _, tool := range tools {
		label, ok := requireLabels[tool]
		if !ok {
			fmt.Fprintf(s.Err, "%s: --require: unknown tool \"%s\" — not in known set\n", name, tool)
			return cli.ExitUsage
		}
		switch statusOf(report, label) {
		case "AVAILABLE":
		case "MISSING":
			fmt.Fprintf(s.Err, "REQUIRE FAILED [%s] MISSING — install it and re-run detect-tools.sh\n", tool)
			rc = cli.ExitOperational
		case "UNUSABLE":
			fmt.Fprintf(s.Err, "REQUIRE FAILED [%s] UNUSABLE — found but smoke test failed (present but broken is not usable)\n", tool)
			rc = cli.ExitOperational
		case "PROBE_FAILED":
			fmt.Fprintf(s.Err, "REQUIRE FAILED [%s] could not determine — probe failed (timeout or environment error); treating as unavailable\n", tool)
			rc = cli.ExitOperational
		default:
			fmt.Fprintf(s.Err, "REQUIRE FAILED [%s] — label \"%s\" not found in report (internal error)\n", tool, label)
			rc = cli.ExitOperational
		}
	}
	return rc
}

// report is report(): the whole capability report without its trailing newline (`OUT="$(report)"`).
func (d *detector) report(now time.Time, errw *bytes.Buffer) string {
	r := &reportCtx{d: d, errw: errw, now: now}
	r.brew, _ = d.p.BrewPrefix()
	hb := func(suffix string) string { return r.brewBin(suffix) }
	plain := rowOpts{}
	home := d.get("HOME")
	fx := d.fixed

	r.line("== Research-SDD tool capability report ==")
	r.line("host: %s · date: %s · brew: %s", r.uname(), now.UTC().Format("2006-01-02T15:04:05Z"), r.brew)
	r.line("")
	r.line("[ native / binary ]")
	r.ghidraRow()
	r.row(plain, "radare2", "r2", "-v", hb("/bin/r2"), fx("/usr/bin/r2"))
	r.row(plain, "objdump", "objdump", "--version", hb("/bin/objdump"), fx("/usr/bin/objdump"))
	r.row(plain, "readelf", "readelf", "--version", hb("/bin/readelf"), fx("/usr/bin/readelf"))
	r.row(plain, "nm", "nm", "--version", hb("/bin/nm"), fx("/usr/bin/nm"))
	r.row(plain, "strings", "strings", "--version", hb("/bin/strings"), fx("/usr/bin/strings"))
	r.line("")
	r.line("[ hex ]")
	r.row(plain, "hexedit", "hexedit", "--help", hb("/bin/hexedit"))
	r.row(plain, "bvi", "bvi", "--help", hb("/bin/bvi"))
	r.line("")
	r.line("[ dynamic / network / emulation ]")
	r.row(plain, "tshark", "tshark", "--version", fx("/usr/bin/tshark"))
	r.row(plain, "tcpdump", "tcpdump", "--version", fx("/usr/bin/tcpdump"))
	r.row(plain, "capinfos", "capinfos", "-v", fx("/usr/bin/capinfos"), hb("/bin/capinfos"))
	r.row(plain, "gdb", "gdb", "--version", fx("/usr/bin/gdb"))
	r.row(plain, "gdb-multiarch", "gdb-multiarch", "--version", fx("/usr/bin/gdb-multiarch"))
	r.row(plain, "strace", "strace", "--version", fx("/usr/bin/strace"))
	r.row(plain, "ltrace", "ltrace", "--version", fx("/usr/bin/ltrace"))
	r.row(plain, "QEMU system", "qemu-system-x86_64", "--version", fx("/usr/bin/qemu-system-x86_64"))
	r.row(plain, "QEMU user-static", "qemu-arm-static", "--version", fx("/usr/bin/qemu-arm-static"))
	r.row(plain, "QEMU image", "qemu-img", "--version", fx("/usr/bin/qemu-img"))
	r.line("")
	r.line("[ java ]")
	r.javaRows()
	r.jarRow("Vineflower (jar)", "vineflower")
	r.jarRow("CFR (jar)", "cfr")
	r.jarRow("Procyon (jar)", "procyon")
	r.line("")
	r.line("[ android ]")
	r.row(plain, "jadx", "jadx", "--version", hb("/bin/jadx"), fx("/usr/bin/jadx"))
	r.row(plain, "apktool", "apktool", "--version", hb("/bin/apktool"))
	r.line("")
	r.line("[ .net ]")
	r.ilspyRow()
	// pwsh is dotnet-hosted: a probe killed by the timeout leaves clr-debug-pipe-* in TMPDIR (#2085); the
	// diagnostics switch is scoped to this row only.
	r.row(rowOpts{extraEnv: []string{"DOTNET_EnableDiagnostics=0"}}, "pwsh", "pwsh", "--version", hb("/bin/pwsh"))
	r.line("")
	r.line("[ firmware ]")
	// binwalk: corroborate-firmware selects RSDD_BINWALK (explicit absolute path) or the PATH-selected binwalk
	// (kit issue #1641); only binwalk major 2 output is supported, so binwalkNote WARNs on any other major.
	r.row(plain, "binwalk", "binwalk", "--help", d.get("RSDD_BINWALK"), fx("/usr/bin/binwalk"), hb("/bin/binwalk"))
	r.binwalkNote()
	r.row(plain, "unblob", "unblob", "--help", home+"/.local/bin/unblob", hb("/bin/unblob"))
	r.row(plain, "kaitai-struct-compiler", "kaitai-struct-compiler", "--version", hb("/bin/kaitai-struct-compiler"), fx("/usr/bin/kaitai-struct-compiler"))
	r.row(plain, "yara", "yara", "--version", hb("/bin/yara"), fx("/usr/bin/yara"))
	r.row(plain, "unsquashfs", "unsquashfs", "-v", fx("/usr/bin/unsquashfs"), fx("/usr/sbin/unsquashfs"), hb("/bin/unsquashfs"))
	if v, ok := d.pkgConfigVersion("libhs"); ok {
		r.line("  %-22s AVAILABLE   libhs %s (command-local system pkg-config path)", "Hyperscan pkg-config", v)
	} else {
		r.line("  %-22s MISSING     (libhs.pc not usable through pkg-config)", "Hyperscan pkg-config")
	}
	r.line("")
	r.line("[ docs / web ]")
	r.row(plain, "pdftotext", "pdftotext", "-v", hb("/bin/pdftotext"), fx("/usr/bin/pdftotext"))
	r.row(plain, "pdfinfo", "pdfinfo", "-v", hb("/bin/pdfinfo"), fx("/usr/bin/pdfinfo"))
	r.row(plain, "tesseract", "tesseract", "--version", hb("/bin/tesseract"), fx("/usr/bin/tesseract"))
	r.row(plain, "pandoc", "pandoc", "--version", hb("/bin/pandoc"), fx("/usr/bin/pandoc"))
	// extract-pdf.sh Tier-1 stack. pymupdf4llm is a venv module, not a CLI: probed by import, as extract-pdf.sh gates it.
	venv := d.get("RESEARCH_SDD_VENV")
	if venv == "" {
		venv = home + "/.local/share/research-sdd-tools/venv"
	}
	if d.p.IsExec(venv+"/bin/python") && d.runProbe(nil, d.probeTimeout(), venv+"/bin/python", "-c", "import pymupdf4llm") == 0 {
		r.line("  %-22s AVAILABLE   %s", "pymupdf4llm", venv+"/bin/python")
	} else {
		r.line("  %-22s MISSING     (%s — extract-pdf.sh Tier 1)", "pymupdf4llm", venv)
	}
	r.row(plain, "ocrmypdf", "ocrmypdf", "--version", venv+"/bin/ocrmypdf", hb("/bin/ocrmypdf"), fx("/usr/bin/ocrmypdf"))
	py := rowOpts{python: true, timeout: d.pythonTimeout(), extraEnv: []string{"RSDD_PROBE_TIMEOUT=" + d.pythonTimeout()}}
	r.row(py, "marker", "marker_single", "--help", venv+"/bin/marker_single", hb("/bin/marker_single"))
	r.row(py, "docling", "docling", "--help", venv+"/bin/docling", hb("/bin/docling"))
	r.line("")
	r.line("[ deliverable / render ]")
	r.row(plain, "latex", "pdflatex", "--version", fx("/usr/bin/pdflatex"), hb("/bin/pdflatex"))
	// circuitikz is a LaTeX package, not a binary: probed through kpsewhich.
	if kpse, err := d.p.LookPath("kpsewhich"); err == nil {
		var out bytes.Buffer
		c := d.command(nil, d.abs(kpse), "circuitikz.sty")
		c.Stdout = &out
		_ = c.Run()
		if p := strings.TrimRight(out.String(), "\n"); p != "" {
			r.line("  %-22s AVAILABLE   %s", "circuitikz", p)
		} else {
			r.circuitikzMissing()
		}
	} else {
		r.circuitikzMissing()
	}
	// ezdxf is a system python3 library used by render-drawing.sh, probed through the same python3.
	py3, _ := d.p.LookPath("python3")
	if py3 != "" && d.runProbe(nil, d.probeTimeout(), py3, "-c", "import ezdxf") == 0 {
		r.line("  %-22s AVAILABLE   %s", "ezdxf", py3)
	} else {
		r.line("  %-22s MISSING     (python3 -c \"import ezdxf\" failed — pip install ezdxf)", "ezdxf")
	}
	r.line("")
	r.line("[ python bytecode ]")
	r.row(plain, "pycdc", "pycdc", "--help", home+"/dev/pycdc/pycdc")
	r.line("")
	r.line("[ isolation / sandbox ]")
	// bwrap gates the ENTIRE slow test lane: absent, RSDD_TEST_LANE=slow skips whole suites and exits 0.
	r.row(plain, "bwrap (sandbox)", "bwrap", "--version", fx("/usr/bin/bwrap"), hb("/bin/bwrap"))
	r.line("")
	r.line("[ triage / capability ]")
	r.row(plain, "capa", "capa", "--version", home+"/.local/bin/capa", hb("/bin/capa"))
	r.row(plain, "floss", "floss", "--version", home+"/.local/bin/floss", hb("/bin/floss"))
	r.row(plain, "diec", "diec", "--version", fx("/usr/bin/diec"), hb("/bin/diec"))
	r.line("")
	r.line("[ dynamic / instrumentation ]")
	r.row(plain, "frida", "frida", "--version", home+"/.local/bin/frida", hb("/bin/frida"))
	r.row(plain, "frida-trace", "frida-trace", "--version", home+"/.local/bin/frida-trace", hb("/bin/frida-trace"))
	r.line("")
	r.line("[ modify / patch ]")
	r.row(plain, "krak2", "krak2", "--version", home+"/.local/bin/krak2", hb("/bin/krak2"))
	r.line("")
	r.line("Note: AVAILABLE means the resolver found the tool AND its bounded validation passed.")
	r.line("UNUSABLE means found but not runnable; MISSING means not detected.")
	return strings.TrimRight(r.b.String(), "\n")
}

func (r *reportCtx) circuitikzMissing() {
	r.line("  %-22s MISSING     (kpsewhich circuitikz.sty not found — install texlive-pictures)", "circuitikz")
}

// pythonTimeout is "${RSDD_PYTHON_PROBE_TIMEOUT:-20}".
func (d *detector) pythonTimeout() string {
	if t := d.get("RSDD_PYTHON_PROBE_TIMEOUT"); t != "" {
		return t
	}
	return "20"
}
