package sweep

import (
	"bytes"
	"encoding/json"
	"io/fs"
	"os"
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// tool writes <tgt>/tools/<name> (a script body), executable when exec is set.
func (w *world) tool(tgt, name string, exec bool) {
	w.t.Helper()
	p := tgt + "/tools/" + name
	w.put(p, "#!/usr/bin/env bash\n# tool "+name+"\n")
	if exec {
		w.must(os.Chmod(p, 0o755))
	}
}

// toolRetro writes <tgt>/retros/<fname>: an applied retro whose tools table has one T-row naming tool.
func (w *world) toolRetro(tgt, fname, tool string) {
	w.t.Helper()
	w.put(tgt+"/retros/"+fname, "<!-- review-status: applied 2026-01-01 -->\n# Retro\n\n## Tools built, adapted, or outgrown\n\n"+
		"| # | CREATED | ADAPTED | OUTGREW | ORACLE | VERDICT |\n|---|---|---|---|---|---|\n| T1 | `tools/"+tool+"` · purpose | — | — | — | keep-local |\n")
}

// ledger writes <tgt>/tools/README.md: a header, a separator row and one row per path.
func (w *world) ledger(tgt string, paths ...string) {
	w.t.Helper()
	var b strings.Builder
	b.WriteString("| Tool | Path | Provenance |\n|---|---|---|\n")
	for _, p := range paths {
		b.WriteString("| " + p + " | tools/" + p + " | created |\n")
	}
	w.put(tgt+"/tools/README.md", b.String())
}

// unreadableKey is the world variable that lists, comma-separated, the absolute paths a scenario makes
// unreadable. The script's side of the differential really chmods them (tools_diff_test.go); the Go side reads
// them through the readFunc seam, so a golden replay needs neither chmod nor a user other than root.
const unreadableKey = "RSDD_TOOLS_TEST_UNREADABLE"

// unreadable makes the files unreadable for the run.
func (w *world) unreadable(paths ...string) { w.env[unreadableKey] = strings.Join(paths, ",") }

// unreadablePaths is the files listed by unreadable.
func (w *world) unreadablePaths() []string {
	if v := w.env[unreadableKey]; v != "" {
		return strings.Split(v, ",")
	}
	return nil
}

// readFile is the reader a Go run gets: os.ReadFile, except that the unreadable files fail with a permission error.
func (w *world) readFile() readFunc {
	bad := w.unreadablePaths()
	return func(p string) ([]byte, error) {
		for _, b := range bad {
			if p == b {
				return nil, fs.ErrPermission
			}
		}
		return os.ReadFile(p)
	}
}

// runTools runs `rsdd sweep tools --kit <kit> <args>` in process.
func (w *world) runTools(args ...string) result {
	w.t.Helper()
	return w.runToolsCmd(false, args)
}

// runToolsHook runs `rsdd sweep tools --hook`.
func (w *world) runToolsHook(args ...string) result {
	w.t.Helper()
	return w.runToolsCmd(true, args)
}

// runToolsCmd goes through the command table, except for a world with unreadable files, which has to hand its
// reader to the sweep: the table only knows os.ReadFile.
func (w *world) runToolsCmd(hook bool, args []string) result {
	w.t.Helper()
	var o, e bytes.Buffer
	argv := []string{"sweep", "tools", "--kit", w.kit}
	if hook {
		argv = append(argv, "--hook")
	}
	argv = append(argv, args...)
	if len(w.unreadablePaths()) == 0 {
		rc := cli.Run(Commands, argv, w.stdio(&o, &e))
		return result{o.String(), e.String(), rc}
	}
	opts, err := parseOptions(argv[2:])
	w.must(err)
	var rc int
	if hook {
		rc = runToolsHook(opts, w.stdio(&o, &e), w.readFile())
	} else {
		rc = sweepTools(opts, w.stdio(&o, &e), &o, &e, w.readFile())
	}
	return result{o.String(), e.String(), rc}
}

// decodeHookCtx is the additionalContext of a hook envelope; "" for the silent hook (no envelope at all).
func decodeHookCtx(t testing.TB, out string) string {
	t.Helper()
	if out == "" {
		return ""
	}
	var env struct {
		H struct {
			Name string `json:"hookEventName"`
			Ctx  string `json:"additionalContext"`
		} `json:"hookSpecificOutput"`
	}
	if err := json.Unmarshal([]byte(out), &env); err != nil || env.H.Name != "SessionStart" {
		t.Fatalf("not a SessionStart envelope (%v): %q", err, out)
	}
	return env.H.Ctx
}
