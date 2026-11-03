//go:build unix

package block

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// Cases for `rsdd verify block`. testdata/block-cases.txt holds every invocation the three legacy bash suites
// (verify-block.test.sh, verify-block-backpointer.test.sh, verify-block-possibility.test.sh) made on the script, one
// case per distinct (arguments, environment, files) captured by running those suites against a recording wrapper, so
// the Go command is compared on every fixture the bash assertions used rather than on a re-typed copy of them. The
// frozen legacy script (testdata/block-legacy, bytes pinned in blocklegacy_test.go) is the oracle:
// blockdiff_oracle_test.go (!nodiff) runs it on every case, asserts the Go command prints the same stdout, the same
// stderr and exits with the same code, and asserts the outcome equals testdata/block-goldens.json (regenerate with
// RSDD_UPDATE_GOLDENS=1). TestBlockGoldens replays the Go command against those goldens without bash, so the
// mutation run (nodiff) still has teeth.
//
// File format of block-cases.txt: "%%%% case NAME", then sections "%%%% args N" / "cwd N" / "env N" (N bytes of
// text follow, then a newline), "%%%% dir REL" and "%%%% file REL N" (N bytes of content follow, then a newline).
// The text "@D@" stands for the per-run directory in every argument, environment value, cwd and file.

const (
	bkCasesFile   = "testdata/block-cases.txt"
	bkGoldenFile  = "testdata/block-goldens.json"
	bkDirToken    = "@D@"
	bkMarkerStart = "%%%% "
)

type bkFile struct {
	rel  string
	dir  bool
	data string
}

type bkCase struct {
	name  string
	args  []string
	cwd   string // relative to the run directory ("" = the directory itself)
	env   map[string]string
	files []bkFile
}

type bkGolden struct {
	Stdout string `json:"stdout"`
	Stderr string `json:"stderr"`
	Rc     int    `json:"rc"`
}

func bkLegacyDir(t *testing.T) string {
	t.Helper()
	p, err := filepath.Abs(filepath.Join("testdata", "block-legacy"))
	if err != nil {
		t.Fatal(err)
	}
	return p
}

// bkParseCases reads block-cases.txt.
func bkParseCases(t *testing.T) []bkCase {
	t.Helper()
	raw, err := os.ReadFile(bkCasesFile)
	if err != nil {
		t.Fatal(err)
	}
	s := string(raw)
	var cases []bkCase
	var cur *bkCase
	take := func(n int) string {
		if n > len(s) {
			t.Fatalf("%s: truncated section", bkCasesFile)
		}
		v := s[:n]
		s = s[n:]
		s = strings.TrimPrefix(s, "\n")
		return v
	}
	for len(s) > 0 {
		if !strings.HasPrefix(s, bkMarkerStart) {
			t.Fatalf("%s: expected a section marker at %q", bkCasesFile, s[:min(40, len(s))])
		}
		eol := strings.IndexByte(s, '\n')
		head := strings.Fields(s[len(bkMarkerStart):eol])
		s = s[eol+1:]
		switch head[0] {
		case "case":
			cases = append(cases, bkCase{name: head[1], env: map[string]string{}})
			cur = &cases[len(cases)-1]
		case "args":
			n, _ := strconv.Atoi(head[1])
			if a := take(n); a != "" {
				cur.args = strings.Split(strings.TrimSuffix(a, "\n"), "\n")
			}
		case "cwd":
			n, _ := strconv.Atoi(head[1])
			cur.cwd = strings.TrimSpace(take(n))
		case "env":
			n, _ := strconv.Atoi(head[1])
			for _, l := range strings.Split(strings.TrimSuffix(take(n), "\n"), "\n") {
				if k, v, ok := strings.Cut(l, "="); ok {
					cur.env[k] = v
				}
			}
		case "dir":
			cur.files = append(cur.files, bkFile{rel: head[1], dir: true})
		case "file":
			n, _ := strconv.Atoi(head[2])
			cur.files = append(cur.files, bkFile{rel: head[1], data: take(n)})
		default:
			t.Fatalf("%s: unknown section %q", bkCasesFile, head[0])
		}
	}
	return cases
}

// bkMaterialize writes the case's files into a fresh directory and returns the working directory, the arguments
// and the environment of the run, with the directory token substituted.
func bkMaterialize(t *testing.T, c bkCase) (dir, cwd string, args, env []string) {
	t.Helper()
	d, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	sub := func(x string) string { return strings.ReplaceAll(x, bkDirToken, d) }
	for _, f := range c.files {
		p := filepath.Join(d, f.rel)
		if f.dir {
			if err := os.MkdirAll(p, 0o755); err != nil {
				t.Fatal(err)
			}
			continue
		}
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(sub(f.data)), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	for _, a := range c.args {
		args = append(args, sub(a))
	}
	cwd = sub(c.cwd)
	if cwd == "" || !strings.HasPrefix(cwd, d) {
		cwd = d
	}
	if err := os.MkdirAll(cwd, 0o755); err != nil {
		t.Fatal(err)
	}
	env = []string{"PATH=" + os.Getenv("PATH"), "HOME=" + d, "LC_ALL=C.UTF-8"}
	if c.env["PATH"] == "@NOSHA@" { // the script's own tools, but neither sha256sum nor shasum
		bin := filepath.Join(d, "nosha-bin")
		if err := os.MkdirAll(bin, 0o755); err != nil {
			t.Fatal(err)
		}
		for _, tool := range []string{"bash", "awk", "grep", "sed", "sort", "cut", "find", "git", "head", "tr", "wc", "basename", "dirname", "readlink", "cat"} {
			p, err := exec.LookPath(tool)
			if err != nil {
				t.Fatalf("%s is required by this test: %v", tool, err)
			}
			if err := os.Symlink(p, filepath.Join(bin, tool)); err != nil {
				t.Fatal(err)
			}
		}
		env[0] = "PATH=" + bin
	}
	for _, k := range []string{"RSDD_STRICT_EPHEMERAL", "SOURCE_ROOT", "HOME"} {
		if v, ok := c.env[k]; ok {
			env = append(env, k+"="+sub(v))
		}
	}
	return d, cwd, args, env
}

func bkGetenv(env []string) func(string) string {
	return func(k string) string {
		v := ""
		for _, e := range env {
			if x, ok := strings.CutPrefix(e, k+"="); ok {
				v = x
			}
		}
		return v
	}
}

// bkGo runs the Go command.
// bkImpl is the command under test (a variable so the RED run can point it at an empty command).
var bkImpl = Run

func bkGo(cwd string, args, env []string) observed {
	var out, errb bytes.Buffer
	rc := bkImpl(args, cli.Stdio{In: strings.NewReader(""), Out: &out, Err: &errb, Env: bkGetenv(env), Environ: func() []string { return env },
		Clock: func() time.Time { return time.Time{} }, Cwd: cwd})
	return observed{out.String(), errb.String(), rc}
}

func bkScrub(o observed, dir string) bkGolden {
	return bkGolden{strings.ReplaceAll(o.stdout, dir, bkDirToken), strings.ReplaceAll(o.stderr, dir, bkDirToken), o.rc}
}

func bkLoadGoldens(t *testing.T) map[string]bkGolden {
	t.Helper()
	raw, err := os.ReadFile(bkGoldenFile)
	if err != nil {
		if os.IsNotExist(err) {
			return map[string]bkGolden{}
		}
		t.Fatal(err)
	}
	m := map[string]bkGolden{}
	if err := json.Unmarshal(raw, &m); err != nil {
		t.Fatalf("%s: %v", bkGoldenFile, err)
	}
	return m
}

// TestBlockGoldens replays the Go command on every case against the frozen outcome of the legacy script.
func TestBlockGoldens(t *testing.T) {
	goldens := bkLoadGoldens(t)
	cases := bkAllCases(t)
	if len(cases) == 0 {
		t.Fatal("no cases")
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			g, ok := goldens[c.name]
			if !ok {
				t.Fatalf("no golden for %s (regenerate with RSDD_UPDATE_GOLDENS=1)", c.name)
			}
			dir, cwd, args, env := bkMaterialize(t, c)
			got := bkScrub(bkGo(cwd, args, env), dir)
			if got != g {
				t.Errorf("%s %v:\n%s", c.name, c.args, bkDiff(g, got))
			}
		})
	}
	if len(goldens) != len(cases) {
		t.Errorf("%d goldens for %d cases: regenerate with RSDD_UPDATE_GOLDENS=1", len(goldens), len(cases))
	}
}

func bkDiff(want, got bkGolden) string {
	var b strings.Builder
	if want.Rc != got.Rc {
		fmt.Fprintf(&b, "exit: want %d, got %d\n", want.Rc, got.Rc)
	}
	for _, p := range []struct{ n, w, g string }{{"stdout", want.Stdout, got.Stdout}, {"stderr", want.Stderr, got.Stderr}} {
		if p.w == p.g {
			continue
		}
		wl, gl := strings.Split(p.w, "\n"), strings.Split(p.g, "\n")
		for i := 0; i < max(len(wl), len(gl)); i++ {
			var w, g string
			if i < len(wl) {
				w = wl[i]
			}
			if i < len(gl) {
				g = gl[i]
			}
			if w != g {
				fmt.Fprintf(&b, "%s line %d:\n  want %q\n  got  %q\n", p.n, i+1, w, g)
				break
			}
		}
	}
	return b.String()
}
