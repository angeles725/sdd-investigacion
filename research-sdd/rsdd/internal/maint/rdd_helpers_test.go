package maint

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// The fixtures are the ones the bash suites tests/kit-rdd-start.test.sh and tests/kit-rdd-drive.test.sh use.
const fixDir = "../../../toolbelt/tests/fixtures/kit-pr-pipeline"

func fixture(t *testing.T, name string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(fixDir, name))
	if err != nil {
		t.Fatalf("fixture %s: %v", name, err)
	}
	return string(b)
}

// rule answers every gentle-ai call whose argument text (after "gentle-ai ") starts with prefix.
type rule struct {
	prefix  string
	rc      int
	out     string
	times   int // 0: unlimited
	barrier int // >0: wait until this many callers are inside at once
	hits    int
	err     error // when set, the call fails with it instead of answering
}

// fake is the in-process gentle-ai.
type fake struct {
	mu      sync.Mutex
	rules   []*rule
	calls   []string
	dirs    []string
	absent  bool
	runErr  error
	arrived int
	release chan struct{}
}

func newFake() *fake { return &fake{release: make(chan struct{})} }

func (f *fake) on(prefix string, rc int, out string) *rule {
	r := &rule{prefix: prefix, rc: rc, out: out}
	f.rules = append(f.rules, r)
	return r
}

func (f *fake) present() error {
	if f.absent {
		return errors.New("not found")
	}
	return nil
}

func (f *fake) run(argv []string, dir string) (result, error) {
	line := strings.Join(argv, " ")
	f.mu.Lock()
	f.calls = append(f.calls, line)
	f.dirs = append(f.dirs, dir)
	if f.runErr != nil {
		f.mu.Unlock()
		return result{}, f.runErr
	}
	args := strings.TrimPrefix(line, "gentle-ai ")
	for _, r := range f.rules {
		if !strings.HasPrefix(args, r.prefix) || (r.times > 0 && r.hits >= r.times) {
			continue
		}
		r.hits++
		if r.barrier > 0 {
			f.arrived++
			if f.arrived == r.barrier {
				close(f.release)
			}
			f.mu.Unlock()
			select {
			case <-f.release:
			case <-time.After(3 * time.Second):
				return result{rc: 98, stderr: "barrier timeout (not concurrent)"}, nil
			}
		} else {
			f.mu.Unlock()
		}
		if r.err != nil {
			return result{}, r.err
		}
		return result{stdout: r.out, rc: r.rc}, nil
	}
	f.mu.Unlock()
	return result{rc: 97, stderr: "unscripted call: " + line}, nil
}

func (f *fake) callLines() string { return strings.Join(f.calls, "\n") }

type outcome struct{ out, err string }

func stdio(cwd string) (cli.Stdio, *bytes.Buffer, *bytes.Buffer) {
	var o, e bytes.Buffer
	return cli.Stdio{In: strings.NewReader(""), Out: &o, Err: &e, Env: func(string) string { return "" }, Environ: func() []string { return nil },
		Clock: time.Now, Cwd: cwd}, &o, &e
}

func runStart(t *testing.T, f *fake, args ...string) (string, string, int, string) {
	t.Helper()
	outfile := filepath.Join(t.TempDir(), "rdd.json")
	s, o, e := stdio("/work")
	full := append(append([]string{}, args...), "/wt", outfile)
	rc := rddStart(full, s, f)
	return o.String(), e.String(), rc, outfile
}

func runDrive(t *testing.T, f *fake, first string, args ...string) (string, string, int) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "first.json")
	if err := os.WriteFile(path, []byte(first), 0o600); err != nil {
		t.Fatal(err)
	}
	s, o, e := stdio("/work")
	rc := rddDrive(append(append([]string{}, args...), "/wt", path), s, f)
	return o.String(), e.String(), rc
}

func (f *fake) due(t *testing.T) {
	f.on("review assess", 0, fixture(t, "assess-due.json"))
	f.on("review status", 0, fixture(t, "status-start.json"))
}

func writeFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
}
