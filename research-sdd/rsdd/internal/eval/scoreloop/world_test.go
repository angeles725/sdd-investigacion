package scoreloop

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/gitfixture"
)

// A scase is one black-box scenario: a fixture repository, an optional transcript and status stub, the argument
// list and the environment. The same case runs through the Go command (golden replay, nodiff-visible) and through
// the frozen legacy script (differential, !nodiff). Placeholders in args and env values: {{CORPUS}} the fixture
// repository, {{TRANSCRIPT}} the transcript file, {{S}} the per-case scratch directory, {{STUB}} the status stub.
type scase struct {
	name       string
	commits    []commit
	corpus     string  // "" a repository of commits; "absent", "nogit", "file" are the non-repository states
	transcript *string // nil: no transcript file
	args       []string
	env        map[string]string
	stub       bool // RSDD_STATUS_SCRIPT is the generic stub (always on with a transcript unless noStub)
	noStub     bool
	tools      string // "" the host PATH; "jq", "base64" or "date": a PATH without that tool
	toolbelt   bool   // the Go side gets --toolbelt {{S}} (the legacy script always runs from {{S}})
	sibling    bool   // the stub is also installed as {{S}}/research-sdd-status.sh and the Go side gets --toolbelt
	intended   []intended
}

type commit struct{ date, subject string }

type intended struct{ field, reason string }

type obs struct {
	stdout, stderr string
	exit           int
}

// stubScript stands in for research-sdd-status.sh: $STUB_ERR on stderr, then STUB_NEXT (with --next) or STUB_DEF.
const stubScript = `#!/usr/bin/env bash
[ -n "${STUB_ERR:-}" ] && printf '%s\n' "$STUB_ERR" >&2
if [ "${2:-}" = "--next" ]; then
  [ -n "${STUB_RC_NEXT:-}" ] && exit "$STUB_RC_NEXT"
  printf '%s\n' "${STUB_NEXT-STOP | read-only-investigable exhausted (0)}"
else
  [ -n "${STUB_RC_DEF:-}" ] && exit "$STUB_RC_DEF"
  printf '%s\n' "${STUB_DEF-  campaign        : pending=0 active=0 done=2 bound-stopped=0 rejected=0}"
fi
`

var (
	repoMu   sync.Mutex
	repoRoot string
	repoDirs = map[string]string{}
	shaRe    = regexp.MustCompile(`[0-9a-f]{40}`)
)

// repoFor builds (once per distinct history) the fixture repository of commits with git fast-import, so the
// commit dates, and therefore the shas, are deterministic.
func repoFor(t testing.TB, commits []commit) string {
	t.Helper()
	repoMu.Lock()
	defer repoMu.Unlock()
	key := fmt.Sprint(commits)
	if d, ok := repoDirs[key]; ok {
		return d
	}
	dir := filepath.Join(repoRoot, fmt.Sprintf("repo%d", len(repoDirs)))
	var stream bytes.Buffer
	for i, c := range commits {
		ts, err := time.Parse(time.RFC3339, c.date)
		if err != nil {
			t.Fatalf("fixture date %q: %v", c.date, err)
		}
		who := fmt.Sprintf("t <t@example.com> %d %s", ts.Unix(), ts.Format("-0700"))
		fmt.Fprintf(&stream, "commit refs/heads/master\nauthor %s\ncommitter %s\ndata %d\n%s\nM 100644 inline f.txt\ndata 2\n%d\n", who, who, len(c.subject), c.subject, i%10)
	}
	gitDo(t, "", nil, "init", "-q", "-b", "master", dir)
	if len(commits) > 0 {
		gitDo(t, dir, stream.Bytes(), "fast-import", "--quiet")
	}
	repoDirs[key] = dir
	return dir
}

func gitDo(t testing.TB, dir string, stdin []byte, args ...string) {
	t.Helper()
	cmd := exec.Command("git", args...)
	cmd.Dir = dir
	cmd.Env = gitfixture.Env(os.Environ())
	cmd.Stdin = bytes.NewReader(stdin)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("git %v: %v\n%s", args, err, out)
	}
}

// world is one case materialised on disk.
type world struct {
	c        scase
	scratch  string
	corpus   string
	env      []string
	toolsDir string
}

func newWorld(t testing.TB, c scase) *world {
	t.Helper()
	w := &world{c: c, scratch: t.TempDir()}
	switch c.corpus {
	case "":
		w.corpus = repoFor(t, c.commits)
	case "absent":
		w.corpus = filepath.Join(w.scratch, "no-such-corpus")
	case "nogit":
		w.corpus = filepath.Join(w.scratch, "plain")
		mustWrite(t, filepath.Join(w.corpus, "x"), "")
	case "file":
		w.corpus = filepath.Join(w.scratch, "afile")
		mustWrite(t, w.corpus, "")
	}
	if c.transcript != nil {
		mustWrite(t, filepath.Join(w.scratch, "transcript.jsonl"), *c.transcript)
	}
	mustWrite(t, filepath.Join(w.scratch, "stub-status.sh"), stubScript)
	if c.sibling {
		mustWrite(t, filepath.Join(w.scratch, "research-sdd-status.sh"), stubScript)
	}
	mustWrite(t, filepath.Join(w.scratch, "emptybin", "keep"), "")
	if c.tools != "" {
		w.toolsDir = mkTools(t, w.scratch, c.tools)
	}
	w.env = w.buildEnv()
	return w
}

func mustWrite(t testing.TB, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func (w *world) sub(s string) string {
	return strings.NewReplacer("{{CORPUS}}", w.corpus, "{{S}}", w.scratch,
		"{{TRANSCRIPT}}", filepath.Join(w.scratch, "transcript.jsonl"),
		"{{STUB}}", filepath.Join(w.scratch, "stub-status.sh")).Replace(s)
}

func (w *world) buildEnv() []string {
	env := []string{"PATH=" + os.Getenv("PATH"), "HOME=" + w.scratch, "LC_ALL=C.UTF-8", "TZ=UTC",
		"GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_NOSYSTEM=1", "TMPDIR=" + w.scratch}
	if w.c.stub || (w.c.transcript != nil && !w.c.noStub) {
		env = append(env, "RSDD_STATUS_SCRIPT="+w.sub("{{STUB}}"))
	}
	if w.c.tools != "" {
		env = append(env, "PATH="+w.toolsDir)
	}
	for k, v := range w.c.env {
		env = append(env, k+"="+w.sub(v))
	}
	return gitfixture.Env(env)
}

// argv is the argument list the legacy script receives.
func (w *world) argv() []string {
	args := w.c.args
	if args == nil {
		args = []string{"--corpus", "{{CORPUS}}"}
		if w.c.transcript != nil {
			args = append(args, "--transcript", "{{TRANSCRIPT}}")
		}
	}
	out := make([]string, len(args))
	for i, a := range args {
		out[i] = w.sub(a)
	}
	return out
}

// norm replaces the machine-specific parts of an output with stable placeholders.
func (w *world) norm(s string) string {
	s = strings.ReplaceAll(s, w.corpus, "{{CORPUS}}")
	s = strings.ReplaceAll(s, w.scratch, "{{S}}")
	return shaRe.ReplaceAllString(s, "{{SHA}}")
}

func (w *world) runGo(t testing.TB) obs {
	t.Helper()
	args := []string{"eval", "score-loop"}
	if w.c.sibling || w.c.toolbelt {
		args = append(args, "--toolbelt", w.scratch)
	}
	args = append(args, w.argv()...)
	var out, errb bytes.Buffer
	getenv := func(k string) string {
		for i := len(w.env) - 1; i >= 0; i-- {
			if v, ok := strings.CutPrefix(w.env[i], k+"="); ok {
				return v
			}
		}
		return ""
	}
	s := cli.Stdio{In: strings.NewReader(""), Out: &out, Err: &errb, Env: getenv,
		Environ: func() []string { return append([]string(nil), w.env...) },
		Clock:   func() time.Time { return time.Date(2000, 1, 1, 0, 0, 0, 0, time.UTC) }, Cwd: w.scratch}
	code := cli.Run([]cli.Command{Command}, args, s)
	return obs{w.norm(out.String()), w.norm(errb.String()), code}
}
