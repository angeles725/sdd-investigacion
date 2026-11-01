package verify

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// Port of research-sdd/toolbelt/verify-block.sh: the mechanical self-verify aid for a Research-SDD block
// (METHODOLOGY section 11).
//
//	rsdd verify block [--strict-ephemeral | --ephemeral=warn|fail] [--extern-check] [--backptr=high|all|off] <block.md> [target-dir]
//	rsdd verify block --possibility-sweep <corpus-dir>
//
// Exit: 0 no verifiable contradiction - 1 a cited line is out of range, an evidence artifact is not
// preserved, an empty-input digest or an ephemeral path is cited, a preserved script has no valid manifest
// row, or an instrument degraded - 2 bad arguments. The report text is byte-identical to the script's.
//
// The script's tools are reproduced with the semantics the script saw on its reference environment (GNU grep,
// gawk, sed, sort and cut in a UTF-8 locale whose collation is the code-point order):
//
//   - regular expressions are leftmost-longest, character classes are the glibc ones, and `\b` is checked
//     against the previous character (blocksh.go);
//   - `sort -u` is a byte-order sort, `cut -c` counts bytes, gawk positions count characters.
//
// Differences, by design (the differential test pins every other byte):
//
//   - The script loads lib/scripts-manifest.sh and lib/block-files.sh from its own directory and degrades
//     when they are missing; both are compiled in here, so those DEGRADED branches do not exist.
//   - An awk or grep that fails reading the block (the script's typed DEGRADED lines for a failed detector) has
//     no equivalent: the block is read once, and a block that cannot be read is an operational failure
//     (exit 1, one stderr line) instead of a report full of failed detectors.
//   - A cited line number past the integer range makes the script's `[` print "integer expression expected" on
//     stderr and read the test as false; here the test is false and nothing is printed.
//   - The line counter is not an external awk: a read failure of a cited file is the typed DEGRADED state.

// vb is one run.
type vb struct {
	s      cli.Stdio
	out    *strings.Builder
	errw   io.Writer
	rc     int
	cwd    string
	strict bool
	extern bool
	bpMode string

	block, target string
	text          string
	ls            []string

	gitRoot, targetRoot string

	certTotal, codeCert, adjInfer int
	epLines                       []string
	typ                           typeInfo
}

// say is `echo "..."`.
func (v *vb) say(format string, a ...any) {
	fmt.Fprintf(v.out, format, a...)
	v.out.WriteByte('\n')
}

// abs resolves a path argument against the working directory the way the shell's own file tests do.
func (v *vb) abs(p string) string {
	if filepath.IsAbs(p) {
		return p
	}
	return filepath.Join(v.cwd, p)
}

// join is `$root/$f` for a file test: relative roots resolve against the working directory.
func (v *vb) join(root, f string) string { return v.abs(root + "/" + f) }

func (v *vb) isFile(p string) bool {
	if p == "" {
		return false
	}
	st, err := os.Stat(v.abs(p))
	return err == nil && st.Mode().IsRegular()
}

func (v *vb) isDir(p string) bool {
	if p == "" {
		return false
	}
	st, err := os.Stat(v.abs(p))
	return err == nil && st.IsDir()
}

// envLookup reports a variable and whether it is set (cli.Stdio.Env cannot tell empty from unset; Environ can).
func envLookup(s cli.Stdio, key string) (string, bool) {
	if s.Environ == nil {
		val := s.Env(key)
		return val, val != ""
	}
	for _, kv := range s.Environ() {
		if k, val, ok := strings.Cut(kv, "="); ok && k == key {
			return val, true
		}
	}
	return "", false
}

const blockUsage = "usage: verify-block.sh [--strict-ephemeral | --ephemeral=warn|fail] [--extern-check] [--backptr=high|all|off] <block.md> [target-dir]  (sources/… cites resolve against target-dir: for a NESTED corpus pass the corpus root)"

// RunBlock is the `verify block` command.
func RunBlock(args []string, s cli.Stdio) int {
	v := &vb{s: s, out: &strings.Builder{}, errw: s.Err, cwd: s.Cwd, strict: true, bpMode: "high"}
	envEP, epSet := envLookup(s, "RSDD_STRICT_EPHEMERAL")
	if envEP == "0" {
		v.strict = false
	}
	if epSet && envEP != "0" && envEP != "1" {
		fmt.Fprintf(s.Err, "verify-block.sh: RSDD_STRICT_EPHEMERAL='%s' is not 0 or 1 — ignored, ephemeral cites FAIL (set 0 to opt out)\n", envEP)
	}
	var rest []string
	for _, a := range args {
		switch {
		case a == "--strict-ephemeral" || a == "--ephemeral=fail":
			v.strict = true
		case a == "--ephemeral=warn":
			v.strict = false
		case a == "--ephemeral" || strings.HasPrefix(a, "--ephemeral="):
			fmt.Fprintf(s.Err, "verify-block.sh: unknown --ephemeral value '%s' (expected --ephemeral=warn or --ephemeral=fail)\n", strings.TrimPrefix(a, "--ephemeral"))
			return 2
		case a == "--extern-check":
			v.extern = true
		case a == "--backptr=high" || a == "--backptr=all" || a == "--backptr=off":
			v.bpMode = strings.TrimPrefix(a, "--backptr=")
		case a == "--backptr" || strings.HasPrefix(a, "--backptr="):
			fmt.Fprintf(s.Err, "verify-block.sh: unknown --backptr value '%s' (expected --backptr=high, --backptr=all or --backptr=off)\n", strings.TrimPrefix(a, "--backptr"))
			return 2
		default:
			rest = append(rest, a)
		}
	}
	if len(rest) > 0 && rest[0] == "--possibility-sweep" {
		dir := ""
		if len(rest) > 1 {
			dir = rest[1]
		}
		return v.possibilitySweep(dir)
	}
	block := ""
	if len(rest) > 0 {
		block = rest[0]
	}
	if !v.isFile(block) {
		fmt.Fprintln(s.Err, blockUsage)
		return 2
	}
	v.block = block
	v.target = dirnameSh(block)
	if len(rest) > 1 && rest[1] != "" {
		v.target = rest[1]
	}
	raw, err := os.ReadFile(v.abs(block))
	if err != nil {
		fmt.Fprintf(s.Err, "verify-block.sh: cannot read %s: %v\n", block, err)
		return 1
	}
	v.text = string(raw)
	v.ls = fileLines(v.text)
	v.resolveRoots()
	v.say("== verify-block: %s (target: %s) ==", basenameSh(block), v.target)
	v.tally()
	v.ratio()
	v.citations()
	v.possibilityFirst()
	v.ocr()
	v.emptyDigests()
	v.ephemeral()
	v.manifest()
	v.backPointers()
	v.say("== exit %d ==", v.rc)
	io.WriteString(s.Out, v.out.String())
	return v.rc
}
