package parity

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"time"
)

const defaultTimeout = 60 * time.Second

// maxOutput caps each captured stream; a variable so a test can lower it.
var maxOutput = 8 << 20

// Config locates everything a run needs.
type Config struct {
	LegacyRoot string        // pinned origin/main kit worktree (holds toolbelt/)
	Bin        string        // rsdd binary
	Work       string        // parent of the sandbox
	Timeout    time.Duration // per run; <= 0 means the default
	Path       string        // PATH handed to both sides; empty means defaultPath
}

// defaultPath is the PATH both sides get when Config.Path is empty. The caller's
// PATH arrives only through ConfigFromEnv's getenv (archtest: no ambient reads).
const defaultPath = "/usr/local/bin:/usr/bin:/bin"

// Degraded is a typed "could not run" result (absent-input or degraded). It
// is never a pass.
type Degraded struct{ Kind, Detail string }

func (d *Degraded) Error() string { return d.Kind + ": " + d.Detail }

// Runner executes cases. Cfg.Timeout may be adjusted between runs.
type Runner struct{ Cfg Config }

// ConfigFromEnv reads RSDD_PARITY_LEGACY, RSDD_BIN and RSDD_PARITY_TIMEOUT.
// Unset roots stay empty so NewRunner can type them as absent-input.
func ConfigFromEnv(getenv func(string) string, work string) (Config, error) {
	cfg := Config{LegacyRoot: getenv("RSDD_PARITY_LEGACY"), Bin: getenv("RSDD_BIN"), Work: work, Timeout: defaultTimeout, Path: getenv("PATH")}
	if s := getenv("RSDD_PARITY_TIMEOUT"); s != "" {
		d, err := time.ParseDuration(s)
		if err != nil || d <= 0 {
			return Config{}, fmt.Errorf("%s: RSDD_PARITY_TIMEOUT=%q is not a positive duration", KindSpecInvalid, s)
		}
		cfg.Timeout = d
	}
	return cfg, nil
}

// NewRunner validates the configuration. A missing legacy root, binary or
// work dir is a typed *Degraded error.
func NewRunner(cfg Config) (*Runner, error) {
	if cfg.Timeout <= 0 {
		cfg.Timeout = defaultTimeout
	}
	var err error
	if cfg.LegacyRoot, err = needDir("legacy kit root (RSDD_PARITY_LEGACY)", cfg.LegacyRoot); err != nil {
		return nil, err
	}
	if cfg.Work, err = needDir("work dir", cfg.Work); err != nil {
		return nil, err
	}
	if cfg.Bin == "" {
		return nil, &Degraded{KindAbsentInput, "rsdd binary not configured (RSDD_BIN)"}
	}
	if cfg.Bin, err = filepath.Abs(cfg.Bin); err != nil {
		return nil, &Degraded{KindAbsentInput, err.Error()}
	}
	st, err := os.Stat(cfg.Bin)
	switch {
	case err != nil:
		return nil, &Degraded{KindAbsentInput, fmt.Sprintf("rsdd binary %s: %v", cfg.Bin, err)}
	case !st.Mode().IsRegular() || st.Mode()&0o111 == 0:
		return nil, &Degraded{KindAbsentInput, fmt.Sprintf("rsdd binary %s is not an executable file", cfg.Bin)}
	}
	return &Runner{Cfg: cfg}, nil
}

func needDir(what, p string) (string, error) {
	if p == "" {
		return "", &Degraded{KindAbsentInput, what + " not configured"}
	}
	abs, err := filepath.Abs(p)
	if err != nil {
		return "", &Degraded{KindAbsentInput, fmt.Sprintf("%s %s: %v", what, p, err)}
	}
	st, err := os.Stat(abs)
	if err != nil {
		return "", &Degraded{KindAbsentInput, fmt.Sprintf("%s %s: %v", what, abs, err)}
	}
	if !st.IsDir() {
		return "", &Degraded{KindAbsentInput, fmt.Sprintf("%s %s is not a directory", what, abs)}
	}
	return abs, nil
}

// BuildBinary builds ./cmd/rsdd of the module at moduleRoot into dstDir.
func BuildBinary(moduleRoot, dstDir string) (string, error) {
	name := "rsdd"
	if runtime.GOOS == "windows" {
		name += ".exe"
	}
	out := filepath.Join(dstDir, name)
	cmd := exec.Command("go", "build", "-o", out, "./cmd/rsdd")
	cmd.Dir = moduleRoot
	cmd.Env = append(os.Environ(), "CGO_ENABLED=0")
	b, err := cmd.CombinedOutput()
	if err != nil {
		msg := strings.TrimSpace(string(b))
		if len(msg) > 2000 {
			msg = msg[:2000] + "..."
		}
		return "", &Degraded{KindDegraded, fmt.Sprintf("go build ./cmd/rsdd in %s failed: %v\n%s", moduleRoot, err, msg)}
	}
	return out, nil
}

// Result is the verdict for one case (and corpus, when set).
type Result struct {
	Case     string
	Corpus   string
	Status   Status
	Problems []Problem
	Note     string
}

func (r Result) describe() string {
	var sb strings.Builder
	fmt.Fprintf(&sb, "%s: %s", r.Status, r.Case)
	if r.Corpus != "" {
		fmt.Fprintf(&sb, " [corpus %s]", r.Corpus)
	}
	if r.Note != "" {
		fmt.Fprintf(&sb, " (%s)", r.Note)
	}
	for _, p := range r.Problems {
		fmt.Fprintf(&sb, "\n  %s", strings.ReplaceAll(p.String(), "\n", "\n  "))
	}
	return sb.String()
}

// RunCase runs one case: legacy first, then rsdd, each in the same freshly
// wiped sandbox. corpus is the real corpus path for a corpus spec, else "".
func (r *Runner) RunCase(c Case, corpus string) Result {
	res := Result{Case: c.Name, Corpus: corpus, Status: StatusFailed}
	fail := func(p ...Problem) Result {
		res.Problems = append(res.Problems, p...)
		return res
	}
	if len(c.Problems) > 0 {
		return fail(c.Problems...)
	}
	if c.Spec.Corpus != (corpus != "") {
		return fail(Problem{KindSpecInvalid, "a corpus spec needs a corpus path and a plain spec must not get one"})
	}
	var before Tree
	if corpus != "" {
		var err error
		if before, err = Fingerprint(corpus); err != nil {
			return fail(Problem{KindCorpusRead, err.Error()})
		}
	}
	var obs [2]Observed
	for i, side := range []string{"legacy", "rsdd"} {
		o, probs := r.runSide(c, side, corpus)
		obs[i] = o
		if corpus != "" {
			probs = append(probs, checkCorpus(side, corpus, before)...)
		}
		if len(probs) > 0 {
			return fail(probs...)
		}
	}
	status, probs := Judge(obs[0], obs[1], c.Intended)
	res.Status, res.Problems = status, probs
	return res
}

func checkCorpus(side, corpus string, before Tree) []Problem {
	after, err := Fingerprint(corpus)
	if err != nil {
		return []Problem{{KindCorpusRead, fmt.Sprintf("after the %s run: %v", side, err)}}
	}
	if d := before.Diff(after); len(d) > 0 {
		return []Problem{{KindCorpusMod, fmt.Sprintf("the %s run modified the read-only corpus %s:\n  %s", side, corpus, strings.Join(d, "\n  "))}}
	}
	return nil
}

func (r *Runner) sandbox() string { return filepath.Join(r.Cfg.Work, "sandbox") }

// runSide wipes and rebuilds the sandbox, then runs one side in it.
func (r *Runner) runSide(c Case, side, corpus string) (Observed, []Problem) {
	sb := r.sandbox()
	if err := prepareSandbox(sb, c); err != nil {
		return Observed{}, []Problem{{KindSandbox, fmt.Sprintf("%s: %v", side, err)}}
	}
	rep := strings.NewReplacer(placeholderInput, filepath.Join(sb, "input"), placeholderCorpus, corpus, placeholderSbx, sb)
	sub := func(in []string) []string {
		out := make([]string, len(in))
		for i, a := range in {
			out[i] = rep.Replace(a)
		}
		return out
	}
	path, args := r.Cfg.Bin, sub(c.Spec.Rsdd)
	if side == "legacy" {
		path, args = filepath.Join(r.Cfg.LegacyRoot, c.Spec.Legacy[0]), sub(c.Spec.Legacy[1:])
	}
	pathEnv := r.Cfg.Path
	if pathEnv == "" {
		pathEnv = defaultPath
	}
	env := []string{"PATH=" + pathEnv, "LC_ALL=C", "TZ=UTC", "HOME=" + filepath.Join(sb, "home"), "TMPDIR=" + filepath.Join(sb, "tmp")}
	keys := make([]string, 0, len(c.Spec.Env))
	for k := range c.Spec.Env {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		env = append(env, k+"="+rep.Replace(c.Spec.Env[k]))
	}

	o := r.execute(path, args, env, sb, c.Stdin)
	switch {
	case o.timedOut:
		return Observed{}, []Problem{{KindTimeout, fmt.Sprintf("the %s run exceeded %s and was killed", side, r.Cfg.Timeout)}}
	case o.startErr != nil:
		return Observed{}, []Problem{{KindExecFailed, fmt.Sprintf("the %s run: %v", side, o.startErr)}}
	case o.truncated:
		return Observed{}, []Problem{{KindOutputTooBig, fmt.Sprintf("the %s run wrote more than %d bytes to a stream", side, maxOutput)}}
	}
	return Observed{Stdout: o.stdout, Stderr: o.stderr, Exit: o.exit}, nil
}

func prepareSandbox(sb string, c Case) error {
	if err := os.RemoveAll(sb); err != nil {
		return fmt.Errorf("wipe sandbox: %w", err)
	}
	for _, d := range []string{"home", "tmp"} {
		if err := os.MkdirAll(filepath.Join(sb, d), 0o755); err != nil {
			return err
		}
	}
	if c.HasInputs {
		return copyTree(filepath.Join(c.Dir, "inputs"), filepath.Join(sb, "input"))
	}
	return nil
}

func copyTree(src, dst string) error {
	return filepath.WalkDir(src, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(src, p)
		if err != nil {
			return err
		}
		target := filepath.Join(dst, rel)
		info, err := d.Info()
		if err != nil {
			return err
		}
		switch {
		case d.IsDir():
			return os.MkdirAll(target, 0o755)
		case info.Mode()&fs.ModeSymlink != 0:
			link, err := os.Readlink(p)
			if err != nil {
				return err
			}
			return os.Symlink(link, target)
		default:
			b, err := os.ReadFile(p)
			if err != nil {
				return err
			}
			return os.WriteFile(target, b, info.Mode().Perm())
		}
	})
}

type outcome struct {
	stdout, stderr []byte
	exit           int
	timedOut       bool
	truncated      bool
	startErr       error
}

// capBuf keeps the first max bytes and remembers whether it dropped any.
type capBuf struct {
	buf       bytes.Buffer
	max       int
	truncated bool
}

func (c *capBuf) Write(p []byte) (int, error) {
	n := len(p)
	if room := max(c.max-c.buf.Len(), 0); n > room {
		c.truncated = true
		p = p[:room]
	}
	c.buf.Write(p)
	return n, nil
}

func (r *Runner) execute(path string, args, env []string, dir string, stdin []byte) outcome {
	ctx, cancel := context.WithTimeout(context.Background(), r.Cfg.Timeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, path, args...)
	cmd.Dir, cmd.Env = dir, env
	cmd.Stdin = bytes.NewReader(stdin)
	var so, se = &capBuf{max: maxOutput}, &capBuf{max: maxOutput}
	cmd.Stdout, cmd.Stderr = io.Writer(so), io.Writer(se)
	setProcAttrs(cmd)
	cmd.WaitDelay = 2 * time.Second
	err := cmd.Run()

	o := outcome{stdout: so.buf.Bytes(), stderr: se.buf.Bytes(), truncated: so.truncated || se.truncated}
	var ee *exec.ExitError
	switch {
	case errors.Is(ctx.Err(), context.DeadlineExceeded):
		o.timedOut = true
	case err == nil:
	case errors.As(err, &ee):
		o.exit = ee.ExitCode()
	default:
		o.startErr = err
	}
	return o
}
