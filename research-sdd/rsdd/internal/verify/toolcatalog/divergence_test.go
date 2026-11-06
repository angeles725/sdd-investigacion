package toolcatalog

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The intended divergences from the scripts (doc.go, tool-registry.d/verify-tool-catalog.md), pinned on the Go side.
// divergence_diff_test.go shows what the scripts did instead.

func skipIfRoot(t *testing.T) {
	t.Helper()
	if os.Geteuid() == 0 {
		t.Skip("running as root: a mode 000 file is still readable, so the unreadable-input cases cannot be built")
	}
}

// D1: an input that exists but cannot be read is an operational failure, never an empty log or every tool missing.
func TestUnreadableInputIsOperational(t *testing.T) {
	t.Parallel()
	skipIfRoot(t)
	for _, name := range []string{installedFile, registryFile} {
		t.Run(name, func(t *testing.T) {
			dir := kit(t, files(logOf("alpha"), regOf("alpha")))
			if err := os.Chmod(filepath.Join(dir, name), 0); err != nil {
				t.Fatal(err)
			}
			got := runGo(dir, "C", Run, dir)
			if got.code != 1 || got.stdout != "" || !strings.HasPrefix(got.stderr, "verify-tool-catalog: ERROR — cannot read "+dir+"/"+name+": ") ||
				!strings.HasSuffix(got.stderr, " (unreadable-input)\n") {
				t.Errorf("got %+v, want exit 1, nothing on stdout and the unreadable-input ERROR", got)
			}
		})
	}
}

// D2: binary data in the log (a NUL byte, or in a UTF-8 locale an invalid sequence) does not stop the reading, and the
// rows after it still count.
func TestBinaryLogKeepsEveryRow(t *testing.T) {
	t.Parallel()
	for _, bad := range []string{"b\x00c", "b\xffc"} {
		for _, loc := range locales {
			log := "| a | x |\n| " + bad + " | x |\n| d | x |\n"
			got := runGo(kit(t, files(log, "")), loc, Run, ".")
			if got.code != 0 || !strings.Contains(got.stdout, "Summary: 3 distinct tool(s) logged in INSTALLED-TOOLS.md · 0 cataloged · 3 not cataloged.") {
				t.Errorf("%q [%s]: got %+v, want three tools counted", bad, loc, got)
			}
		}
	}
}

// D2 for the hook: a WARN line holding an invalid sequence is not dropped as binary data.
func TestHookKeepsAnInvalidWarnLine(t *testing.T) {
	t.Parallel()
	out := "WARN  odd \xff line\n" + warn("t") + "\n" + summary("2", "1", "1")
	ctx, _ := hookContext(out, 0, false)
	if !strings.Contains(ctx, "WARN  odd \xff line\n") {
		t.Errorf("the WARN line with an invalid byte is gone: %q", ctx)
	}
}

// D5: the check takes one argument at most.
func TestRunRejectsExtraArguments(t *testing.T) {
	t.Parallel()
	got := runGo(kit(t, files(logOf("a"), regOf("a"))), "C", Run, "x", "y")
	if got.code != 2 || got.stdout != "" || got.stderr != "usage: rsdd verify tool-catalog [<toolbelt-dir>]\n" {
		t.Errorf("got %+v, want the usage line on stderr and exit 2", got)
	}
}

// The directory defaults to the working directory, and a relative one resolves against it; paths print as written.
func TestDirectoryArgument(t *testing.T) {
	t.Parallel()
	dir := kit(t, map[string]string{"sub/INSTALLED-TOOLS.md": logOf("a"), "sub/tool-registry.md": regOf("a"), "bare/": ""})
	if got := runGo(filepath.Join(dir, "sub"), "C", Run); got.code != 0 || !strings.Contains(got.stdout, "1 cataloged") {
		t.Errorf("default directory: got %+v", got)
	}
	if got := runGo(dir, "C", Run, "sub"); got.code != 0 || !strings.Contains(got.stdout, "1 cataloged") {
		t.Errorf("relative directory: got %+v", got)
	}
	want := "verify-tool-catalog: ERROR — cannot find bare/INSTALLED-TOOLS.md (absent-input)\n"
	if got := runGo(dir, "C", Run, "bare/"); got.stderr != want || got.code != 1 {
		t.Errorf("trailing slash: got %+v, want stderr %q", got, want)
	}
}
