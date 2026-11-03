//go:build unix

package install

import (
	"os"
	"testing"
)

// Edge cases that pin the last mutants of the package: --prog with nothing after it, an empty first --require
// line, a glob candidate that matches nothing, and a non-executable timeout on PATH for the dotnet probe.

func TestProgAloneNamesTheProgram(t *testing.T) {
	e := newDT(t)
	e.env["RESEARCH_TOOLS_CACHE"] = e.root // a directory: the cache write fails and names the program
	_, er, code := e.run("--prog", "/kit/x.sh")
	if code != 1 || er != "x.sh: cannot write cache file: "+e.root+"\n" {
		t.Fatalf("exit %d stderr %q", code, er)
	}
}

func TestEmptyFirstRequireLineIsAnUnknownTool(t *testing.T) {
	e := newDT(t)
	_, er, code := e.run("--require", "\nobjdump")
	if code != 2 || er != "detect-tools.sh: --require: unknown tool \"\" — not in known set\n" {
		t.Fatalf("exit %d stderr %q", code, er)
	}
}

func TestUnmatchedGlobCandidateStaysLiteral(t *testing.T) {
	e := newDT(t)
	lit := e.tool(e.root+"/[a]", "exit 0") // the pattern [a] matches a file named "a", not this one
	r := &reportCtx{d: newDetector([]string{"PATH="}, e.root)}
	if got, ok := r.resolve("nothere", lit); !ok || got != lit {
		t.Fatalf("resolve = (%q, %v), want the literal %q", got, ok, lit)
	}
}

func TestDotnetProbeIsBoundedByTimeout(t *testing.T) {
	e := newDT(t)
	runtime := e.root + "/runtime"
	if err := os.MkdirAll(runtime+"/shared/Microsoft.NETCore.App", 0o755); err != nil {
		t.Fatal(err)
	}
	e.tool("ilspycmd", `sleep 2; exit 0`) // would succeed if left to finish; the bound must end it first
	d := newDetector([]string{"PATH=" + e.bin, "RSDD_PROBE_TIMEOUT=0.2"}, e.root)
	if d.dotnetProbe(runtime, e.bin+"/ilspycmd") {
		t.Fatal("a slow ilspycmd must be stopped by timeout(1) and read as unusable")
	}
}

func TestNonExecutableTimeoutOnPathIsNotUsed(t *testing.T) {
	e := newDT(t)
	runtime := e.root + "/runtime"
	if err := os.MkdirAll(runtime+"/shared/Microsoft.NETCore.App", 0o755); err != nil {
		t.Fatal(err)
	}
	e.tool("ilspycmd", `[ "$DOTNET_ROOT" = "`+runtime+`" ] && exit 0; exit 1`)
	if err := os.Remove(e.bin + "/timeout"); err != nil {
		t.Fatal(err)
	}
	// a plain file named timeout: command -v finds it, `[ -x ]` rejects it, so the probe runs the tool directly
	if err := os.WriteFile(e.bin+"/timeout", []byte("not a program"), 0o644); err != nil {
		t.Fatal(err)
	}
	d := newDetector([]string{"PATH=" + e.bin}, e.root)
	if !d.dotnetProbe(runtime, e.bin+"/ilspycmd") {
		t.Fatal("dotnetProbe must run ilspycmd directly when timeout is not executable")
	}
}
