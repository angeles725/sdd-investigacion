//go:build linux

package adapter

import (
	"bytes"
	"crypto/sha256"
	hexenc "encoding/hex"
	"encoding/json"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// step is one recorded action of a world; the driver replays the list under its own root.
type step struct {
	Kind   string            `json:"kind"`
	Path   string            `json:"path,omitempty"`
	Text   string            `json:"text,omitempty"`
	Hex    string            `json:"hex,omitempty"`
	Target string            `json:"target,omitempty"`
	Mode   int               `json:"mode,omitempty"`
	Argv   []string          `json:"argv,omitempty"`
	Env    map[string]string `json:"env,omitempty"`
	Cwd    string            `json:"cwd,omitempty"`
}

type runResult struct {
	RC    int    `json:"rc"`
	Out   string `json:"out"`
	Err   string `json:"err"`
	Crash string `json:"crash"`
}

// world is a scratch directory the Go port runs in, with every action recorded so the
// real Python can replay it from scratch under another root.
type world struct {
	t       *testing.T
	root    string
	steps   []step
	results []runResult
	env     map[string]string
	cwd     string
}

func newWorld(t *testing.T, base string) *world {
	t.Helper()
	root := filepath.Join(base, "w")
	if err := os.MkdirAll(root, 0o755); err != nil {
		t.Fatal(err)
	}
	return &world{t: t, root: root, env: map[string]string{"HOME": "/nonexistent-home"}}
}

func (w *world) tok(s string) string { return strings.ReplaceAll(s, w.root, "{root}") }
func (w *world) abs(rel string) string {
	if filepath.IsAbs(rel) {
		return rel
	}
	return filepath.Join(w.root, rel)
}

func (w *world) fatal(err error) {
	w.t.Helper()
	if err != nil {
		w.t.Fatal(err)
	}
}

func (w *world) file(rel, data string, mode os.FileMode) {
	w.t.Helper()
	p := w.abs(rel)
	w.fatal(os.MkdirAll(filepath.Dir(p), 0o755))
	w.fatal(os.WriteFile(p, []byte(data), mode))
	w.fatal(os.Chmod(p, mode))
	w.steps = append(w.steps, step{Kind: "write", Path: w.tok(p), Text: w.tok(data), Mode: int(mode)})
}

func (w *world) bytes(rel string, data []byte, mode os.FileMode) {
	w.t.Helper()
	p := w.abs(rel)
	w.fatal(os.MkdirAll(filepath.Dir(p), 0o755))
	w.fatal(os.WriteFile(p, data, mode))
	w.fatal(os.Chmod(p, mode))
	w.steps = append(w.steps, step{Kind: "write", Path: w.tok(p), Hex: hexenc.EncodeToString(data), Mode: int(mode)})
}

func (w *world) json(rel string, v any) {
	w.t.Helper()
	b, err := json.Marshal(v)
	w.fatal(err)
	w.file(rel, string(b), 0o644)
}

func (w *world) mkdir(rel string) {
	w.t.Helper()
	p := w.abs(rel)
	w.fatal(os.MkdirAll(p, 0o755))
	w.steps = append(w.steps, step{Kind: "mkdir", Path: w.tok(p)})
}

func (w *world) symlink(rel, target string) {
	w.t.Helper()
	p := w.abs(rel)
	w.fatal(os.MkdirAll(filepath.Dir(p), 0o755))
	w.fatal(os.Symlink(target, p))
	w.steps = append(w.steps, step{Kind: "symlink", Path: w.tok(p), Target: w.tok(target)})
}

func (w *world) chmod(rel string, mode os.FileMode) {
	w.t.Helper()
	p := w.abs(rel)
	w.fatal(os.Chmod(p, mode))
	w.steps = append(w.steps, step{Kind: "chmod", Path: w.tok(p), Mode: int(mode)})
}

func (w *world) remove(rel string) {
	w.t.Helper()
	p := w.abs(rel)
	w.fatal(os.Remove(p))
	w.steps = append(w.steps, step{Kind: "remove", Path: w.tok(p)})
}

func (w *world) read(rel string) []byte {
	w.t.Helper()
	b, err := os.ReadFile(w.abs(rel))
	w.fatal(err)
	return b
}

// run executes the command under the Go port and records it for replay.
func (w *world) run(args ...string) runResult {
	w.t.Helper()
	var out, errb bytes.Buffer
	env := map[string]string{}
	for k, v := range w.env {
		env[k] = v
	}
	cwd := w.cwd
	if cwd == "" {
		cwd = w.root
	}
	s := cli.Stdio{In: bytes.NewReader(nil), Out: &out, Err: &errb, Env: func(k string) string { return env[k] }, Clock: time.Now, Cwd: cwd}
	rc := ManifestRun(args, s)
	toks := make([]string, len(args))
	for i, a := range args {
		toks[i] = w.tok(a)
	}
	w.steps = append(w.steps, step{Kind: "run", Argv: toks, Env: env, Cwd: w.tok(cwd)})
	res := runResult{RC: rc, Out: out.String(), Err: errb.String()}
	w.results = append(w.results, res)
	return res
}

// tree is a comparable snapshot of everything under a root, with the root path normalised.
func (w *world) tree(root string) map[string]string {
	w.t.Helper()
	snap := map[string]string{}
	err := filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(root, p)
		info, err := d.Info()
		if err != nil {
			return err
		}
		switch {
		case d.Type()&fs.ModeSymlink != 0:
			t, _ := os.Readlink(p)
			snap[rel] = "link " + showRoot(t, root)
		case d.IsDir():
			snap[rel] = "dir"
		default:
			b, _ := os.ReadFile(p)
			// The digest is taken over the text with the root shown as "@" and the manifest identity (a hash
			// over absolute paths) masked, so a tree is comparable across roots and recorded goldens stay valid.
			text := identityHash.ReplaceAllString(showRoot(string(b), root), `"identity":"sha256:ID"`)
			sum := sha256.Sum256([]byte(text))
			snap[rel] = "file " + info.Mode().Perm().String() + " " + hexenc.EncodeToString(sum[:8]) + " " + text
		}
		return nil
	})
	w.fatal(err)
	return snap
}

var randomTemp = regexp.MustCompile(`\.[a-z0-9_]{8}\.tmp`)

// showRoot shows a world's root as "@" and its parent (where the cases put files outside the root) as
// "@@", so output and trees compare across roots and a recorded golden stays valid.
func showRoot(s, root string) string {
	return strings.ReplaceAll(strings.ReplaceAll(s, root, "@"), filepath.Dir(root), "@@")
}

var identityHash = regexp.MustCompile(`"identity":"sha256:[0-9a-f]{64}"`)

// norm shows a root as "@" and the random part of mkstemp names as "RAND".
func norm(s, root string) string {
	return randomTemp.ReplaceAllString(showRoot(s, root), ".RAND.tmp")
}

func lastLine(s string) string {
	lines := strings.Split(strings.TrimRight(s, "\n"), "\n")
	return lines[len(lines)-1]
}

type pyWorld struct {
	Root  string `json:"root"`
	Steps []step `json:"steps"`
}

// pyOutcome is what the Python port produced for one world: the result of every run (the root shown as
// "@") and the final tree it left under its root.
type pyOutcome struct {
	Results []runResult       `json:"results"`
	Tree    map[string]string `json:"tree"`
}

// compareWorlds checks every recorded world against the Python port's outcome and requires the same
// exit code, stdout, stderr (last traceback line for an uncaught exception) and final tree. The outcome
// comes from replaying the world under the frozen Python (pythonOutcomes in world_oracle_test.go) or,
// in a nodiff build, from the golden recorded from that replay (world_golden_test.go).
func compareWorlds(t *testing.T, worlds map[string]*world) {
	t.Helper()
	names := make([]string, 0, len(worlds))
	for n := range worlds {
		names = append(names, n)
	}
	sort.Strings(names)
	// The Python replay runs under the SAME root path as the Go world, so every path (and every
	// identity hash computed over paths) is byte-comparable. The Go tree is snapshotted first and
	// removed, which leaves the path free for the replay.
	goTrees := map[string]map[string]string{}
	for _, n := range names {
		w := worlds[n]
		goTrees[n] = w.tree(w.root)
		w.fatal(os.RemoveAll(w.root))
	}
	outcomes := pythonOutcomes(t, names, worlds)
	diverged := map[string]bool{}
	for _, n := range names {
		w := worlds[n]
		py := outcomes[n].Results
		if len(py) != len(w.results) {
			t.Errorf("%s: %d runs in go, %d in python", n, len(w.results), len(py))
			continue
		}
		for j, g := range w.results {
			p := py[j]
			label := n + " run " + itoa(j) + " " + strings.Join(runArgs(w.steps, j), " ")
			if declaredDivergence(n, g, p) {
				diverged[n] = true
				continue
			}
			if g.RC != p.RC {
				t.Errorf("%s: exit go %d python %d\n go stderr: %s\n py stderr: %s", label, g.RC, p.RC, norm(g.Err, w.root), p.Err)
				continue
			}
			if norm(g.Out, w.root) != p.Out {
				t.Errorf("%s: stdout\n go     %q\n python %q", label, norm(g.Out, w.root), p.Out)
			}
			if p.Crash != "" {
				if got := lastLine(g.Err); got != p.Crash && norm(got, w.root) != p.Crash {
					t.Errorf("%s: uncaught exception\n go     %q\n python %q", label, got, p.Crash)
				}
				continue
			}
			if norm(g.Err, w.root) != p.Err {
				t.Errorf("%s: stderr\n go     %q\n python %q", label, norm(g.Err, w.root), p.Err)
			}
		}
		if diverged[n] {
			continue // the runs ended differently by a declared divergence, so the trees are not comparable
		}
		gt, pt := goTrees[n], outcomes[n].Tree
		for k, v := range gt {
			if pt[k] != v {
				t.Errorf("%s: %s differs\n go     %.200q\n python %.200q", n, k, v, pt[k])
			}
		}
		for k := range pt {
			if _, ok := gt[k]; !ok {
				t.Errorf("%s: %s exists only in python's world", n, k)
			}
		}
	}
}

func runArgs(steps []step, nth int) []string {
	for _, s := range steps {
		if s.Kind == "run" {
			if nth == 0 {
				return s.Argv
			}
			nth--
		}
	}
	return nil
}

func itoa(i int) string {
	b := []byte{}
	if i == 0 {
		return "0"
	}
	for ; i > 0; i /= 10 {
		b = append([]byte{byte('0' + i%10)}, b...)
	}
	return string(b)
}

var _ = io.EOF

var (
	jsonSyntaxMessage = regexp.MustCompile(`(line \d+ column \d+ \(char \d+\)|Unexpected UTF-8 BOM|codec can't decode|Exceeds the limit)`)
	timestampMessage  = regexp.MustCompile(`must be in|out of range|Invalid isoformat|not supported`)
)

// declaredDivergence reports a Go/Python difference the port declares (see the file header of
// manifest.go and the out-of-scope list in the PR): JSON syntax errors and undecodable bytes carry Go's
// text, timestamps are RFC 3339 only, and the inputs that crash Python with a traceback are an ordinary
// failure (exit 2) here.
func declaredDivergence(world string, g, p runResult) bool {
	if p.Crash != "" {
		return g.RC == 2 && strings.HasPrefix(g.Err, "analysis-manifest: ")
	}
	if g.RC == 2 && p.RC == 2 && strings.HasPrefix(g.Err, "analysis-manifest: ") {
		return jsonSyntaxMessage.MatchString(p.Err) || strings.Contains(world, "run-") && timestampMessage.MatchString(p.Err+g.Err)
	}
	// RFC 3339 only: the other ISO 8601 spellings Python accepts are rejected here.
	return strings.Contains(world, "run-") && g.RC == 2 && p.RC == 0
}
