//go:build !nodiff

package retrogrammar

import (
	"flag"
	"fmt"
	"os"
	"sync"
	"testing"
)

// Live mode of the differential. The bash differential forks bash for every case and takes about 80 s, so it is
// opt-in: RSDD_LIVE_DIFF=1 runs it, RETROGRAMMAR_UPDATE=1 runs it and rewrites the frozen goldens (oracle_test.go)
// from what bash answered. In live mode every bash result is also compared with its frozen case, so a golden that
// went stale (the bash lib or a fixture changed) fails here with an instruction instead of rotting.
const (
	envLive   = "RSDD_LIVE_DIFF"
	envUpdate = "RETROGRAMMAR_UPDATE"
)

var (
	recMu    sync.Mutex
	recorded = map[string]oracleCase{}

	frozenOnce sync.Once
	frozen     map[string]oracleCase
	frozenErr  error
)

func updating() bool { return os.Getenv(envUpdate) == "1" }

// liveOnly skips the calling test unless the live differential was asked for.
func liveOnly(t *testing.T) {
	t.Helper()
	if os.Getenv(envLive) != "1" && !updating() {
		t.Skipf("live bash differential skipped: set %s=1 to run it (the frozen oracle replay, TestOracleReplay, covers the same inputs)", envLive)
	}
}

// fileKey is the golden key of a file-mode input path: the path's content, or the kind of path it is.
func fileKey(t *testing.T, p string) string {
	t.Helper()
	if p == "" {
		return "s:emptypath"
	}
	fi, err := os.Stat(p)
	switch {
	case err != nil:
		return "s:missing"
	case fi.IsDir():
		return "s:dir"
	}
	b, err := os.ReadFile(p)
	if err != nil {
		return "s:locked"
	}
	return "d:" + string(b)
}

// record freezes (update) or checks (live) one bash result. p is the input path of a file mode ("" otherwise): it
// is replaced by a placeholder inside stderr, since the golden must not carry a machine path.
func record(t *testing.T, mode, key, p string, bash bashOut) {
	t.Helper()
	bash = anonymize(bash, p)
	id := oracleID(mode, key)
	if updating() {
		recMu.Lock()
		recorded[id] = oracleCase{mode: mode, key: key, out: bash}
		recMu.Unlock()
		return
	}
	frozenOnce.Do(func() {
		cs, err := loadOracle()
		frozenErr = err
		frozen = map[string]oracleCase{}
		for _, c := range cs {
			frozen[oracleID(c.mode, c.key)] = c
		}
	})
	if frozenErr != nil {
		t.Fatalf("frozen oracle unreadable: %v", frozenErr)
	}
	c, ok := frozen[id]
	switch {
	case !ok:
		t.Errorf("%s %.80q: no frozen case; regenerate with %s=1", mode, key, envUpdate)
	case c.out != bash:
		t.Errorf("%s %.80q: frozen case is stale (frozen=%+v bash=%+v); regenerate with %s=1", mode, key, c.out, bash, envUpdate)
	}
}

// TestMain writes the goldens after a fully green update run (never from a partial one).
func TestMain(m *testing.M) {
	flag.Parse()
	code := m.Run()
	if updating() && code == 0 {
		if r := flag.Lookup("test.run"); r != nil && r.Value.String() != "" || testing.Short() {
			fmt.Fprintln(os.Stderr, "retrogrammar: refusing to freeze goldens from a partial run (-run or -short set)")
			os.Exit(1)
		}
		recMu.Lock()
		have := map[string]bool{}
		for _, c := range recorded {
			have[c.mode] = true
		}
		for _, mode := range oracleModes() {
			if !have[mode] { // a skipped live test (no bash) must not freeze a corpus without its mode
				fmt.Fprintf(os.Stderr, "retrogrammar: refusing to freeze goldens: no live case recorded for mode %s\n", mode)
				os.Exit(1)
			}
		}
		docs, cases := formatOracle(recorded)
		recMu.Unlock()
		if err := os.WriteFile(oracleDocsFile, []byte(docs), 0o644); err != nil {
			fmt.Fprintln(os.Stderr, "retrogrammar:", err)
			os.Exit(1)
		}
		if err := os.WriteFile(oracleCasesFile, []byte(cases), 0o644); err != nil {
			fmt.Fprintln(os.Stderr, "retrogrammar:", err)
			os.Exit(1)
		}
		fmt.Fprintf(os.Stderr, "retrogrammar: froze %d cases\n", len(recorded))
	}
	os.Exit(code)
}
