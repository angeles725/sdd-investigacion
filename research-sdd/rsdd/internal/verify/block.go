package verify

import (
	"fmt"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/fsview"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/shellx"
)

// Port of research-sdd/toolbelt/verify-block.sh: the mechanical self-verify aid for a Research-SDD block
// (METHODOLOGY section 11).
//
//	rsdd verify block [--strict-ephemeral | --ephemeral=warn|fail] [--extern-check] [--backptr=high|all|off] <block.md> [target-dir]
//	rsdd verify block --possibility-sweep <corpus-dir>
//
// Exit and report are the script's, byte for byte: 0 no verifiable contradiction, 1 a cite out of range / unpreserved
// artifact / empty-input digest / ephemeral path / manifest mismatch / degraded scan, 2 bad arguments.
//
// Where to change what (one file per concern):
//
//	block.go            arguments, header, run order, exit code
//	blocktext.go        grep/awk/sort/cut primitives shared by every check
//	blocktally.go       section 1-2: marker tally, [INFER]/[CERT] ratio, the Type: grammar
//	blockroots.go       target-root / git-root fallbacks, the line counter
//	blockcites.go       section 3: file:line citation resolution and the P6/P9 verdict lines
//	blocknonpath.go     the ip:port / host:port / Class.method:N tokens split off from the cites
//	blockpossibility.go section 3b and --possibility-sweep
//	blockocr.go         section 4: OCR-provenance flag
//	blockdigest.go      section 9: empty-input digests
//	blockephemeral.go   section 10: ephemeral-path cites
//	blockmanifest.go    section 11: SCRIPTS-MANIFEST rows and sha256
//	blockbackptr.go     section 12: the section-14 back-pointer check
//
// Differences, by design (as the state port): the helper libraries (lib/scripts-manifest.sh, lib/block-files.sh) are
// compiled in, so their "cannot find helper" degraded lines cannot occur; sha256 is computed in process (the "neither
// sha256sum nor shasum on PATH" line is still reported when neither is on PATH, as the script's check did); bash's
// "[: N: integer expression expected" stderr line for a cited number beyond int64 is not reproduced (the comparison
// is false in both). Collation is codepoint order (sort in a C or C.UTF-8 locale) and text is read as UTF-8 characters.

const blockUsage = "usage: verify-block.sh [--strict-ephemeral | --ephemeral=warn|fail] [--extern-check] [--backptr=high|all|off] <block.md> [target-dir]  (sources/… cites resolve against target-dir: for a NESTED corpus pass the corpus root)"

type blockRun struct {
	s  cli.Stdio
	fs fsView

	block, target string
	lines         []string // the block's records
	unreadable    bool     // the block exists but could not be read
	rc            int

	strictEP    bool
	backptr     string
	externCheck bool

	gitRoot, targetRoot, sourceRoot string

	// from blocktally.go
	typeRaw, typeToken, typeStripped, typeClass, typeWarnName string
	certTotal, codeCertTotal, infer                           int

	// section 3 counters: ok/total attempted/extern/failed/degraded, probe-file cites resolved, nonpath tokens, --extern-check
	ok, m, e, f, dN, probeOK, npN, xa, xr, xrel int
}

func (b *blockRun) echo(format string, a ...any) { fmt.Fprintf(b.s.Out, format+"\n", a...) }

// RunBlock is `rsdd verify block`.
func RunBlock(args []string, s cli.Stdio) int {
	b := &blockRun{s: s, fs: fsView{View: fsview.View{Cwd: s.Cwd}}, strictEP: true, backptr: "high"}
	// Ephemeral-path cites FAIL by default (kit #1660); only the exact value 0 opts out.
	if s.Env("RSDD_STRICT_EPHEMERAL") == "0" {
		b.strictEP = false
	}
	for _, e := range s.Environ() {
		if v, ok := strings.CutPrefix(e, "RSDD_STRICT_EPHEMERAL="); ok && v != "0" && v != "1" { // VB-EP-ENVNOTICE
			fmt.Fprintf(s.Err, "verify-block.sh: RSDD_STRICT_EPHEMERAL='%s' is not 0 or 1 — ignored, ephemeral cites FAIL (set 0 to opt out)\n", v)
		}
	}
	var pos []string
	for _, a := range args {
		switch {
		case a == "--strict-ephemeral" || a == "--ephemeral=fail":
			b.strictEP = true
		case a == "--ephemeral=warn":
			b.strictEP = false
		case a == "--ephemeral" || strings.HasPrefix(a, "--ephemeral="):
			fmt.Fprintf(s.Err, "verify-block.sh: unknown --ephemeral value '%s' (expected --ephemeral=warn or --ephemeral=fail)\n", strings.TrimPrefix(a, "--ephemeral"))
			return cli.ExitUsage
		case a == "--extern-check":
			b.externCheck = true
		case a == "--backptr=high" || a == "--backptr=all" || a == "--backptr=off":
			b.backptr = strings.TrimPrefix(a, "--backptr=")
		case a == "--backptr" || strings.HasPrefix(a, "--backptr="):
			fmt.Fprintf(s.Err, "verify-block.sh: unknown --backptr value '%s' (expected --backptr=high, --backptr=all or --backptr=off)\n", strings.TrimPrefix(a, "--backptr"))
			return cli.ExitUsage
		default:
			pos = append(pos, a)
		}
	}
	arg := func(i int) string {
		if i < len(pos) {
			return pos[i]
		}
		return ""
	}
	if arg(0) == "--possibility-sweep" {
		return b.runPossibilitySweep(arg(1))
	}
	b.block = arg(0)
	if !b.fs.IsFile(b.block) {
		fmt.Fprintln(s.Err, blockUsage)
		return cli.ExitUsage
	}
	b.target = arg(1)
	if b.target == "" {
		b.target = shellx.DirName(b.block)
	}
	if src, err := b.fs.Read(b.block); err == nil {
		b.lines = shellx.RecordLines(string(src))
	} else {
		// An unreadable block is never a clean one (CLAUDE.md §7): the scans that read it report DEGRADED and exit 1.
		b.unreadable = true
		fmt.Fprintf(s.Err, "verify-block.sh: cannot read %s: %v\n", b.block, err)
	}
	b.sourceRoot = s.Env("SOURCE_ROOT")
	b.gitRoot = b.gitTopLevel()
	b.targetRoot = b.deriveTargetRoot()

	b.echo("== verify-block: %s (target: %s) ==", shellx.BaseName(b.block), b.target)
	b.sectionTally()
	b.sectionRatio()
	b.sectionCites()
	b.sectionPossibility()
	b.sectionOCR()
	b.sectionEmptyDigest()
	b.sectionEphemeral()
	b.sectionManifest()
	b.sectionBackptr()
	b.echo("== exit %d ==", b.rc)
	return b.rc
}

// gitTopLevel is `git -C "$target" rev-parse --show-toplevel 2>/dev/null` (empty on any failure).
func (b *blockRun) gitTopLevel() string {
	cmd := exec.Command("git", "-C", b.target, "rev-parse", "--show-toplevel")
	cmd.Dir = b.s.Cwd
	cmd.Env = b.s.Environ()
	out, err := cmd.Output()
	if err != nil {
		return ""
	}
	return strings.TrimRight(string(out), "\n")
}

// physical is `cd P && pwd -P`: the logical path made absolute and lexically cleaned (cd's own order), then with
// symbolic links resolved. ok is false where cd fails.
func (b *blockRun) physical(p string) (string, bool) {
	abs := p
	if !strings.HasPrefix(abs, "/") {
		abs = b.s.Cwd + "/" + p
	}
	abs = filepath.Clean(abs)
	if !b.fs.IsDir(abs) {
		return "", false
	}
	r, err := filepath.EvalSymlinks(abs)
	if err != nil {
		return "", false
	}
	return r, true
}

// deriveTargetRoot is the TARGET-ROOT fallback (#1325): the parent of the nearest `corpus` ancestor-or-self of the
// target, refused when it is / or an ancestor of $HOME, accepted only when it holds a project marker.
func (b *blockRun) deriveTargetRoot() string {
	d, ok := b.physical(b.target)
	if !ok {
		d = ""
	}
	c := ""
	for d != "" && d != "/" {
		if shellx.BaseName(d) == "corpus" {
			c = shellx.DirName(d)
			break
		}
		d = shellx.DirName(d)
	}
	if c != "" && c != "/" {
		home := b.s.Env("HOME")
		if home == "" {
			home = "/"
		}
		h, ok := b.physical(home)
		if !ok {
			h = ""
		}
		if strings.HasPrefix(h+"/", c+"/") { // TARGET-ROOT-HOME-GUARD
			c = ""
		}
	}
	if c != "" && c != "/" {
		for _, m := range []string{"package.json", "pyproject.toml", "pom.xml", "build.gradle", "go.mod", "Cargo.toml", "Makefile", ".git"} { // TARGET-ROOT-MARKERS
			if b.fs.exists(c + "/" + m) {
				return c
			}
		}
	}
	return ""
}
