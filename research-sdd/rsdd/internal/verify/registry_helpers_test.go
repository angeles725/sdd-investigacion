package verify

import (
	"bytes"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// Helpers shared by the registry unit tests and the differential test. They must not live in a `!nodiff` file:
// gremlins builds the package with -tags nodiff and the unit tests still need them.

// vrKit is a sandbox: <root>/kit (with toolbelt/ and TARGETS.md) and <root>/home as RESEARCH_HOME and HOME.
type vrKit struct {
	t         *testing.T
	root, kit string
	home      string
	targetsMD string
}

func newVRKit(t *testing.T) *vrKit {
	t.Helper()
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	// The kit lives under $RESEARCH_HOME and its own TARGETS.md row is `$RESEARCH_HOME/kit`, so the row stays short however
	// long TMPDIR is (kit issue #2630: an absolute kit path made it an oversized row on a long TMPDIR).
	home := filepath.Join(root, "home")
	k := &vrKit{t: t, root: root, kit: filepath.Join(home, "kit"), home: home}
	k.targetsMD = filepath.Join(k.kit, "TARGETS.md")
	for _, d := range []string{filepath.Join(k.kit, "toolbelt"), k.home} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	return k
}

// write creates a file under the sandbox root (relative path; a trailing slash creates a directory).
func (k *vrKit) write(rel, content string) {
	k.t.Helper()
	p := filepath.Join(k.root, rel)
	if strings.HasSuffix(rel, "/") {
		if err := os.MkdirAll(p, 0o755); err != nil {
			k.t.Fatal(err)
		}
		return
	}
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		k.t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
		k.t.Fatal(err)
	}
}

// home writes relative to RESEARCH_HOME.
func (k *vrKit) put(rel, content string) { k.write("home/"+rel, content) }

// targets writes TARGETS.md; @H@ stands for $RESEARCH_HOME, @K@ for the kit path and @HOME@ for the real home dir.
func (k *vrKit) targets(body string) {
	k.t.Helper()
	body = strings.NewReplacer("@H@", "$RESEARCH_HOME", "@K@", k.kit, "@HOME@", k.home).Replace(body)
	k.write("home/kit/TARGETS.md", body)
}

func (k *vrKit) env(extra map[string]string) map[string]string {
	e := map[string]string{"HOME": k.home, "RESEARCH_HOME": k.home, "PATH": os.Getenv("PATH"), "LC_ALL": "C"}
	for kk, v := range extra {
		e[kk] = v
	}
	return e
}

type vrResult struct {
	stdout, stderr string
	rc             int
}

// run executes `rsdd verify registry --kit <kit> args...` in process.
func (k *vrKit) run(env map[string]string, args ...string) vrResult {
	k.t.Helper()
	var out, errb bytes.Buffer
	e := k.env(env)
	s := cli.Stdio{
		In: strings.NewReader(""), Out: &out, Err: &errb,
		Env:     func(key string) string { return e[key] },
		Environ: func() []string { return nil },
		Clock:   func() time.Time { return time.Unix(0, 0) },
		Cwd:     k.root,
	}
	rc := RunRegistry(append([]string{"--kit", k.kit}, args...), s)
	return vrResult{out.String(), errb.String(), rc}
}

// vrTable is a standard TARGETS.md: a header, a separator and the given rows, the kit itself registered.
func vrTable(rows ...string) string {
	return "| # | Name | Path | Maturity | Artifact | Lang |\n|---|---|---|---|---|---|\n" +
		strings.Join(rows, "\n") + "\n| 90 | kit | `@H@/kit` | (1 md / nc) | x | en |\n"
}

// vrRow is a master-table row for a $RESEARCH_HOME-relative path with the given maturity cell.
func vrRow(n, name, rel, maturity string) string {
	return "| " + n + " | " + name + " | `@H@/" + rel + "` | " + maturity + " | md | en |"
}

// blocks writes n canonical block files plus a RESEARCH-STATE.md into home/<rel>.
func (k *vrKit) blocks(rel string, n int) {
	k.t.Helper()
	k.put(rel+"/RESEARCH-STATE.md", "state\n")
	for i := 1; i <= n; i++ {
		k.put(rel+"/p-block"+strconv.Itoa(i)+".md", "b\n")
	}
}
