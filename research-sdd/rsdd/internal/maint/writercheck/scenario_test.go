package writercheck

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// scenario is one case of the differential and golden tests: build edits a fresh clone (the same way for both sides),
// args gives the command line (it may create log directories below the clone's root), env adds environment entries.
type scenario struct {
	name  string
	build func(k *kase)
	args  func(k *kase) []string
	env   []string
	want  int // the exit code both sides must give
}

// headerOf is the binding header of the clone, written as the first line of a valid teeth log. The differential build
// asks the frozen legacy script, the golden replay asks the Go command (see oracle_test.go and oracle_nodiff_test.go).
var headerOf func(k *kase, worktree bool) string

var logSeq int

// logs creates a directory of VALID teeth logs for the given fixture suites (names under tests/), bound to the
// clone's committed state (or its working tree).
func (k *kase) logs(worktree bool, suites ...string) string {
	logSeq++
	dir := fmt.Sprintf("%s/logs%d", k.root, logSeq)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		k.t.Fatal(err)
	}
	for _, s := range suites {
		k.logFile(dir, s, true, "-- teeth --\n  PASS  x\n== 3 passed · 0 failed ==\n", worktree)
	}
	return dir
}

// logFile writes the log of one suite: with the binding header (bound) or raw.
func (k *kase) logFile(dir, suite string, bound bool, body string, worktree bool) {
	k.t.Helper()
	text := body
	if bound {
		text = headerOf(k, worktree) + "\n" + body
	}
	if err := os.WriteFile(filepath.Join(dir, logName(pfx+suite)), []byte(text), 0o644); err != nil {
		k.t.Fatal(err)
	}
}

// chk is the common command line: --repo <clone> --base base, then extra.
func chk(extra ...string) func(*kase) []string {
	return func(k *kase) []string { return append([]string{"--repo", k.dir, "--base", "base"}, extra...) }
}

// withLogs is chk plus --teeth-log over a directory of valid logs for the suites.
func withLogs(suites ...string) func(*kase) []string {
	return func(k *kase) []string {
		return []string{"--repo", k.dir, "--base", "base", "--teeth-log", k.logs(false, suites...)}
	}
}

// touching builds a clone with a comment line appended to each file and committed.
func touching(files ...string) func(*kase) {
	return func(k *kase) { k.touch(files...) }
}

func nothing(*kase) {}

// goRunWrite writes teeth logs with the Go command (the logs a later check of the same clone reads).
func (k *kase) goRunWrite(dir string, suites ...string) int {
	return k.goRun(nil, append([]string{"--repo", k.dir, "--write-teeth-log", dir, "--base", "base"}, suites...)...).rc
}

// envFor is the environment entries of a scenario run: the impact script, then the scenario's own (the @ROOT@
// placeholder expands to the clone's root).
func (k *kase) envFor(sc scenario) []string {
	out := []string{"KIT_WRITER_CHECK_IMPACT=" + k.impact}
	for _, e := range sc.env {
		out = append(out, strings.ReplaceAll(e, "@ROOT@", k.root))
	}
	return out
}

// allScenarios is every case of the package.
func allScenarios() []scenario {
	var all []scenario
	for _, g := range [][]scenario{requiredScenarios(), nameKillScenarios(), modeScenarios()} {
		all = append(all, g...)
	}
	return all
}
