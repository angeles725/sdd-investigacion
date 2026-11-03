//go:build linux && !nodiff

package adapter

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
)

func mustAbs(t *testing.T, p string) string {
	t.Helper()
	a, err := filepath.Abs(p)
	if err != nil {
		t.Fatal(err)
	}
	return a
}

// runDriver runs testdata/manifest_driver.py (the REAL analysis_manifest.py and
// isolation_profile.py) for a batch of cases. A missing python3 FAILS the test.
func runDriver[T any](t *testing.T, op string, cases any) []T {
	t.Helper()
	py, err := exec.LookPath("python3")
	if err != nil {
		t.Fatalf("python3 is required for the parity tests and was not found: %v", err)
	}
	in, err := json.Marshal(cases)
	if err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command(py, "-I", "testdata/manifest_driver.py", mustAbs(t, toolbeltDir), op)
	var out, stderr bytes.Buffer
	cmd.Stdin, cmd.Stdout, cmd.Stderr = bytes.NewReader(in), &out, &stderr
	if err := cmd.Run(); err != nil {
		t.Fatalf("driver %s failed: %v\n%s", op, err, stderr.String())
	}
	var rs []T
	if err := json.Unmarshal(out.Bytes(), &rs); err != nil {
		t.Fatalf("driver output: %v", err)
	}
	return rs
}

// toolbeltAbs is the absolute toolbelt path the parallel driver hands to each worker.
var toolbeltAbs string

// runDriverParallel splits cases into at most k chunks and runs one driver per chunk concurrently
// (each case is independent: its own root and steps), then returns the results in case order.
// Failures are reported from the test goroutine, never from the workers.
func runDriverParallel[T any, C any](t *testing.T, op string, cases []C, k int) []T {
	t.Helper()
	py, err := exec.LookPath("python3")
	if err != nil {
		t.Fatalf("python3 is required for the parity tests and was not found: %v", err)
	}
	if k > len(cases) {
		k = len(cases)
	}
	if k < 1 {
		return nil
	}
	type part struct {
		rs  []T
		err error
	}
	parts := make([]part, k)
	size := (len(cases) + k - 1) / k
	var wg sync.WaitGroup
	for i := 0; i < k; i++ {
		lo, hi := i*size, min((i+1)*size, len(cases))
		if lo >= hi {
			continue
		}
		wg.Add(1)
		go func(i int, chunk []C) {
			defer wg.Done()
			in, err := json.Marshal(chunk)
			if err != nil {
				parts[i].err = err
				return
			}
			cmd := exec.Command(py, "-I", "testdata/manifest_driver.py", toolbeltAbs, op)
			var out, stderr bytes.Buffer
			cmd.Stdin, cmd.Stdout, cmd.Stderr = bytes.NewReader(in), &out, &stderr
			if err := cmd.Run(); err != nil {
				parts[i].err = fmt.Errorf("driver %s failed: %v\n%s", op, err, stderr.String())
				return
			}
			if err := json.Unmarshal(out.Bytes(), &parts[i].rs); err != nil {
				parts[i].err = fmt.Errorf("driver output: %v", err)
			}
		}(i, cases[lo:hi])
	}
	wg.Wait()
	var all []T
	for _, p := range parts {
		if p.err != nil {
			t.Fatal(p.err)
		}
		all = append(all, p.rs...)
	}
	if len(all) != len(cases) {
		t.Fatalf("driver %s: %d results for %d cases", op, len(all), len(cases))
	}
	return all
}

func unmarshalString(raw json.RawMessage, dst *string) error { return json.Unmarshal(raw, dst) }

// The port follows CPython 3.15. CI's oracle is Python 3.12, which differs in the places declared
// below; on an older oracle (oracleInfo.older) the parity tests hold the declared divergences to the
// weaker check named at each site and still hold everything else to byte equality:
//   - datetime.fromisoformat: 3.12 has a narrower grammar and different messages (run.* timestamps);
//   - json: 3.13 added the "Illegal trailing comma" messages;
//   - argparse: 3.13/3.14 changed usage wrapping, "maybe you meant", "--" and negative-number rules;
//   - TypeError text for an unhashable set member;
//   - NFKC: code points assigned after the oracle's Unicode version.
type oracleInfo struct {
	minor   int
	unidata string
}

var (
	oracleOnce sync.Once
	oracleVal  oracleInfo
)

func pyOracle(t *testing.T) oracleInfo {
	t.Helper()
	oracleOnce.Do(func() {
		out, err := exec.Command("python3", "-I", "-c", "import sys,unicodedata;print(sys.version_info.minor, unicodedata.unidata_version)").Output()
		if err != nil {
			return
		}
		f := strings.Fields(string(out))
		if len(f) == 2 {
			oracleVal.minor, _ = strconv.Atoi(f[0])
			oracleVal.unidata = f[1]
		}
	})
	if oracleVal.minor == 0 {
		t.Fatal("cannot determine the Python oracle version")
	}
	return oracleVal
}

// older reports an oracle that predates the CPython the port follows.
func (o oracleInfo) older() bool { return o.minor < 15 }
