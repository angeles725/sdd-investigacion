package sweep

import (
	"bytes"
	"io/fs"
	"os"
	"strings"
	"testing"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// Boundary and unit tests of the pure parts of `sweep tools`. The scenario table (tools_scenarios_test.go)
// drives whole sweeps; these pin the edges a hand mutant would move: every range check, every boundary
// character, every counter.

func TestToolsInDepDir(t *testing.T) {
	for rel, want := range map[string]bool{
		"node_modules/x.js": true, "a/node_modules/x.js": true, "__pycache__/m.pyc": true, ".venv/bin/x.py": true,
		".git/hooks/h.sh": true, "a/b/.git/x": true,
		"x.py": false, "node_modules": false, "xnode_modules/y.js": false, "node_modules.js": false, "my.git/x": false,
		".venv": false, "a/.venvx/y": false, "pycache/m": false,
	} {
		if got := inDepDir(rel); got != want {
			t.Errorf("inDepDir(%q) = %v, want %v", rel, got, want)
		}
	}
}

func TestToolsIsToolFile(t *testing.T) {
	dir := t.TempDir()
	for name, want := range map[string]bool{
		"a.py": true, "a.sh": true, "a.mjs": true, "a.js": true, "a.ts": true, "a.ps1": true, ".sh": true,
		"A.PY": false, "a.sh~": false, "a.pyc": false, "a.json": false, "sh": false, "a.tsx": false, "a.mjs.map": false,
	} {
		p := dir + "/" + name
		if err := os.WriteFile(p, []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
		if got := isToolFile(p); got != want {
			t.Errorf("isToolFile(%q) = %v, want %v", name, got, want)
		}
	}
	p := dir + "/run-me"
	if err := os.WriteFile(p, []byte("x"), 0o755); err != nil {
		t.Fatal(err)
	}
	if !isToolFile(p) {
		t.Error("an executable of any name is a tool")
	}
	if isToolFile(dir + "/absent") {
		t.Error("a file that does not exist is not an executable")
	}
}

func TestToolsIsLibModule(t *testing.T) {
	root := t.TempDir()
	tdir := root + "/tools"
	for _, f := range []string{
		"top.py", "x_lib/a.py", "x_lib/deep/a.py", "deep/x_lib/a.py", "xlib/a.py", "_lib/a.py", "lib/a.py", "x_libs/a.py",
		"pkg/__init__.py", "pkg/mod.py", "pkg/sub/mod.py", "nopkg/mod.py",
	} {
		if err := os.MkdirAll(tdir+"/"+f[:strings.LastIndex(f, "/")+1], 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(tdir+"/"+f, []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.MkdirAll(tdir+"/dirinit/__init__.py", 0o755); err != nil { // a directory is no package marker
		t.Fatal(err)
	}
	if err := os.WriteFile(tdir+"/dirinit/m.py", []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	for f, want := range map[string]bool{
		"top.py": false, "x_lib/a.py": true, "x_lib/deep/a.py": true, "deep/x_lib/a.py": true, "xlib/a.py": false, "_lib/a.py": true,
		"lib/a.py": false, "x_libs/a.py": false, "pkg/__init__.py": true, "pkg/mod.py": true, "pkg/sub/mod.py": false,
		"nopkg/mod.py": false, "dirinit/m.py": false,
	} {
		if got := isLibModule(tdir+"/"+f, tdir); got != want {
			t.Errorf("isLibModule(%q) = %v, want %v", f, got, want)
		}
	}
}

// The exclusion is judged below tools/: a target that lives under a dependency directory keeps its tools, and
// a tools/ that is a symbolic link is followed.
func TestToolsFilesIgnoreTargetPrefix(t *testing.T) {
	root := t.TempDir()
	tdir := root + "/.venv/node_modules/target/tools"
	for _, f := range []string{"a.py", "node_modules/skip.js", "sub/b.sh"} {
		if err := os.MkdirAll(tdir+"/"+f[:max(0, strings.LastIndex(f, "/"))], 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(tdir+"/"+f, []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	r, files := toolsFiles(tdir)
	if r != tdir || len(files) != 2 {
		t.Errorf("toolsFiles = %q %v, want the two files outside node_modules", r, files)
	}
	if err := os.Symlink(tdir, root+"/linked"); err != nil {
		t.Fatal(err)
	}
	if r, files := toolsFiles(root + "/linked"); r != tdir || len(files) != 2 {
		t.Errorf("a symlinked tools/ must be walked at its target: %q %v", r, files)
	}
}

func TestToolsInLedger(t *testing.T) {
	for _, c := range []struct {
		row, base string
		want      bool
	}{
		{"| a.py | tools/a.py | created |", "a.py", true},
		{"a.py x", "a.py", true},         // the start of the line is a boundary
		{"a.py", "a.py", false},          // the end of the line is not
		{"| a.py", "a.py", false},        // the script's pattern needs a character after the name
		{"| xa.py |", "a.py", false},     // a name inside a longer name
		{"| a.pyc |", "a.py", false},     // and a longer name that starts with it
		{"| xa.py a.py |", "a.py", true}, // the second occurrence counts
		{"| tools/a.py: |", "a.py", true},
		{"| `a.py` |", "a.py", true},
		{"|a.py|", "a.py", true},
		{"| (a.py) |", "a.py", false},
		{"|\ta.py |", "a.py", false}, // a tab is not a boundary
		{"| a.py\t|", "a.py", false},
		{"| xa a a |", "a a", true}, // the second occurrence overlaps the first
		{"| a+b.sh |", "a+b.sh", true},
		{"| aab.sh |", "a+b.sh", false},
		{"| a[1].sh |", "a[1].sh", true},
		{"", "a.py", false},
	} {
		if got := inLedger([]string{c.row}, c.base); got != c.want {
			t.Errorf("inLedger(%q, %q) = %v, want %v", c.row, c.base, got, c.want)
		}
	}
	if inLedger(nil, "a.py") {
		t.Error("no rows record nothing")
	}
	if !inLedger([]string{"| other |", "| a.py |"}, "a.py") || inLedger([]string{"| a.py", "| x |"}, "a.py") {
		t.Error("the rows are searched one by one, and a name never spans two lines")
	}
}

func TestToolsInTRows(t *testing.T) {
	rows := []string{"| T1 | `tools/scan.py` · purpose |", "| T2 | other |"}
	for base, want := range map[string]bool{"scan.py": true, "can.py": true, "tools/scan.py": true, "other": true, "-x.sh": false, "scan.pyc": false, "T3": false} {
		if got := inTRows(rows, base); got != want {
			t.Errorf("inTRows(%q) = %v, want %v", base, got, want)
		}
	}
	if inTRows(nil, "a") || !inTRows([]string{"| T1 | -x.sh |"}, "-x.sh") {
		t.Error("no rows record nothing; a name that starts with a dash is a literal")
	}
}

func TestToolsRowFilters(t *testing.T) {
	data := []byte("| T1 | a |\n| T |\n | T2 |\n|T3|\n| t4 |\n| T12x | b |\nprose | T5\r\n| T7 | crlf |\r\n")
	got := retroTRows(data)
	if len(got) != 3 || got[0] != "| T1 | a |" || got[1] != "| T12x | b |" || got[2] != "| T7 | crlf |\r" {
		t.Errorf("retroTRows = %q", got)
	}
	if len(retroTRows([]byte("| T1 | a |\x00\n"))) != 0 || len(retroTRows(nil)) != 0 {
		t.Error("a binary file and an empty one hold no T-row")
	}
	led := ledgerRows([]byte("| Tool | Path |\n|---|---|\n| - | x |\n|:--|--:|\n| :-: |\n | x |\n|| y |\n|\t-\t|\n| a.py | tools/a.py |\n| -- a | b |\n"))
	want := []string{"| Tool | Path |", "|| y |", "| a.py | tools/a.py |", "| -- a | b |"}
	if strings.Join(led, "\n") != strings.Join(want, "\n") {
		t.Errorf("ledgerRows = %q, want %q", led, want)
	}
	if len(ledgerRows([]byte("| a |\x00"))) != 0 {
		t.Error("a binary ledger holds no row")
	}
}

// readerOf is a readFunc over a map that records the paths it was asked for (the wrapper must be the one in use).
type readerOf struct {
	bad   map[string]bool
	asked []string
}

func (r *readerOf) read(p string) ([]byte, error) {
	r.asked = append(r.asked, p)
	if r.bad[p] {
		return nil, fs.ErrPermission
	}
	return os.ReadFile(p)
}

func TestToolsReadLedgerStates(t *testing.T) {
	dir := t.TempDir()
	put := func(name, body string) string {
		p := dir + "/" + name
		if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
		return p
	}
	table, bare, seps := put("table.md", "| a.py |\n"), put("bare.md", "no table\n"), put("seps.md", "|---|\n")
	if err := os.Mkdir(dir+"/isdir.md", 0o755); err != nil {
		t.Fatal(err)
	}
	for _, c := range []struct {
		path string
		bad  bool
		want ledgerState
	}{{dir + "/absent.md", false, ledgerNone}, {dir + "/isdir.md", false, ledgerNone}, {table, true, ledgerError},
		{bare, false, ledgerNoTable}, {seps, false, ledgerNoTable}, {table, false, ledgerParsed}} {
		r := &readerOf{bad: map[string]bool{c.path: c.bad}}
		st, rows := readLedger(c.path, r.read)
		if st != c.want {
			t.Errorf("readLedger(%s, bad=%v) = %d, want %d", c.path, c.bad, st, c.want)
		}
		if (st == ledgerParsed) != (len(rows) > 0) {
			t.Errorf("readLedger rows %q for state %d", rows, st)
		}
		if c.want != ledgerNone && len(r.asked) != 1 {
			t.Errorf("readLedger must read through the seam: asked %v", r.asked)
		}
		if c.want == ledgerNone && len(r.asked) != 0 {
			t.Errorf("a missing or non-regular ledger is not read: asked %v", r.asked)
		}
	}
}

func TestToolsRetroRowsCounts(t *testing.T) {
	w := newWorld(t)
	a := w.tgt("targetA")
	w.toolRetro(a, "ok.md", "a.py")
	w.toolRetro(a, "bad.md", "b.py")
	w.toolRetro(a, "TOOLS-INDEX.md", "c.py")
	w.put(a+"/retros/plain.md", "no rows\n")
	r := &readerOf{bad: map[string]bool{a + "/retros/bad.md": true}}
	rows, found, withTable, unreadable := retroRows(a, r.read)
	if found != 3 || withTable != 1 || unreadable != 1 || len(rows) != 1 || !strings.Contains(rows[0], "a.py") {
		t.Errorf("retroRows = %q found=%d withTable=%d unreadable=%d", rows, found, withTable, unreadable)
	}
	if len(r.asked) != 3 {
		t.Errorf("every retro but the index goes through the seam: %v", r.asked)
	}
}

func TestToolsUnreadableThroughTheSeam(t *testing.T) {
	w := newWorld(t)
	a := w.tgt("targetA")
	w.tool(a, "scan.py", false)
	w.ledger(a, "scan.py")
	w.targets(a)
	r := &readerOf{bad: map[string]bool{a + "/tools/README.md": true}}
	var o, e bytes.Buffer
	rc := sweepTools(options{kit: w.kit}, w.stdio(&o, &e), &o, &e, r.read)
	if rc != 0 || !strings.Contains(o.String(), "        WARN: tools/README.md scan FAILED (grep error) — ledger count unavailable\n        recorded (retro): 0  ·  unrecorded: 1") {
		t.Errorf("rc=%d out=%s", rc, o.String())
	}
	if len(r.asked) != 1 {
		t.Errorf("the seam is not the reader in use: %v", r.asked)
	}
}

func TestToolsKitFlagNeedsAValue(t *testing.T) {
	w := newWorld(t)
	var o, e bytes.Buffer
	rc := cli.Run(Commands, []string{"sweep", "tools", "--kit"}, w.stdio(&o, &e))
	if rc != cli.ExitUsage || !strings.Contains(e.String(), "sweep-tools: --kit needs a directory") || o.String() != "" {
		t.Errorf("rc=%d out=%q err=%q", rc, o.String(), e.String())
	}
}

const absentFooter = "INFO: 2 target(s) not traversed (absent-input) — corpus directory not found; see INFO lines above."

func TestToolsHookContext(t *testing.T) {
	sum := func(n string) string {
		return "Summary: 5 tool(s) across 3 target(s) · 2 recorded (retro) · 1 recorded (ledger) · " + n + " unrecorded."
	}
	for _, c := range []struct {
		name, out string
		rc        int
		want      string
		emit      bool
	}{
		{"failure is reported unfiltered", "sweep-tools: cannot find /k/TARGETS.md", 1,
			"Research-SDD tools sweep could not run (exit 1 — check TARGETS.md and lib/ helper):\nsweep-tools: cannot find /k/TARGETS.md", true},
		{"failure keeps its exit code", "boom", 7, "Research-SDD tools sweep could not run (exit 7 — check TARGETS.md and lib/ helper):\nboom", true},
		{"no Summary line is a broken instrument", "TARGET  demo\n        no tools", 0,
			"Research-SDD tools sweep: missing Summary line — unexpected output from sweep-tools.sh:\nTARGET  demo\n        no tools", true},
		{"all ledgered and reached is silent", "TARGET  x\n\n" + sum("0"), 0, "", false},
		{"unrecorded is surfaced", "TARGET  x\n\n" + sum("2"), 0,
			"Research-SDD tool ledger (unrecorded tools found):\n" + sum("2") + "\nRun toolbelt/sweep-tools.sh for per-target breakdown.", true},
		{"a multi-digit count is not zero", sum("10"), 0,
			"Research-SDD tool ledger (unrecorded tools found):\n" + sum("10") + "\nRun toolbelt/sweep-tools.sh for per-target breakdown.", true},
		{"a count ending in zero is not zero", sum("20"), 0,
			"Research-SDD tool ledger (unrecorded tools found):\n" + sum("20") + "\nRun toolbelt/sweep-tools.sh for per-target breakdown.", true},
		{"absent targets alone are not silent", sum("0") + "\n" + absentFooter, 0,
			"Research-SDD tool ledger (targets not traversed):\n" + sum("0") + "\n" + absentFooter + "\nRun toolbelt/sweep-tools.sh for per-target breakdown.", true},
		{"absent targets with the PARTIAL warning", sum("0") + "\n" + absentFooter + "\nWARN: 1 target(s) skipped — x; this sweep is PARTIAL: y", 0,
			"Research-SDD tool ledger (targets not traversed):\n" + sum("0") + "\n" + absentFooter + "\nWARN: 1 target(s) skipped — x; this sweep is PARTIAL: y\nRun toolbelt/sweep-tools.sh for per-target breakdown.", true},
		{"unrecorded orders warn before absent", sum("3") + "\n" + absentFooter + "\nWARN: 1 target(s) skipped — x", 0,
			"Research-SDD tool ledger (unrecorded tools found):\n" + sum("3") + "\nWARN: 1 target(s) skipped — x\n" + absentFooter + "\nRun toolbelt/sweep-tools.sh for per-target breakdown.", true},
		{"a partial warning with nothing else is silent", sum("0") + "\nWARN: 1 target(s) skipped — x", 0, "", false},
		{"indented lines are not the footer", "        INFO: not traversed\n   WARN: indented\n" + sum("0"), 0, "", false},
		{"a Summary that is not at the line start is no summary", "x " + sum("4"), 0,
			"Research-SDD tools sweep: missing Summary line — unexpected output from sweep-tools.sh:\nx " + sum("4"), true},
	} {
		got, emit := toolsHookContext(c.out, c.rc)
		if got != c.want || emit != c.emit {
			t.Errorf("%s:\n got %q (emit %v)\nwant %q (emit %v)", c.name, got, emit, c.want, c.emit)
		}
	}
}

func TestToolsLinesWith(t *testing.T) {
	if got := linesWith("a\nb\na2\n", func(l string) bool { return strings.HasPrefix(l, "a") }); got != "a\na2" {
		t.Errorf("linesWith = %q", got)
	}
	if got := linesWith("", func(string) bool { return true }); got != "" && got != "\n" {
		t.Errorf("an empty output: %q", got)
	}
}
