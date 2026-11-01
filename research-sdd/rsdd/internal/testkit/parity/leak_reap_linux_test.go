//go:build linux

package parity

import (
	"errors"
	"os"
	"strings"
	"testing"
	"time"
)

type fakeProc struct {
	err   error
	kills *int
}

func (f fakeProc) Kill() error { *f.kills++; return f.err }

// withReapSeams installs fakes for one test and restores the real ones.
func withReapSeams(t *testing.T, scan func([]byte) ([]int, error), check func(int, []byte) bool,
	find func(int) (killer, error), sleep func(time.Duration)) {
	t.Helper()
	s, c, f, z := reapScan, reapCheck, reapFind, reapSleep
	reapScan, reapCheck, reapFind, reapSleep = scan, check, find, sleep
	t.Cleanup(func() { reapScan, reapCheck, reapFind, reapSleep = s, c, f, z })
}

func always(int, []byte) bool { return true }

// A marked process that never disappears is rescanned exactly maxReapPasses
// times, never forever, and each rescan waits a positive settle delay.
func TestReapStopsAfterMaxPasses(t *testing.T) {
	scans, kills := 0, 0
	var slept []time.Duration
	withReapSeams(t,
		func([]byte) ([]int, error) {
			scans++
			if scans > 50 {
				t.Fatal("reapLeaked keeps rescanning past its pass bound")
			}
			return []int{4242}, nil
		},
		always,
		func(int) (killer, error) { return fakeProc{nil, &kills}, nil },
		func(d time.Duration) { slept = append(slept, d) })
	probs := reapLeaked("legacy", "n")
	if scans != maxReapPasses {
		t.Fatalf("scans = %d, want %d", scans, maxReapPasses)
	}
	if kills != maxReapPasses {
		t.Fatalf("kills = %d, want %d", kills, maxReapPasses)
	}
	for _, d := range slept {
		if d <= 0 {
			t.Fatalf("settle delay %v must be positive", d)
		}
	}
	if len(probs) != 1 || probs[0].Kind != KindLeaked || !strings.Contains(probs[0].Detail, "killed): pids 4242") {
		t.Fatalf("problems = %+v, want one killed-leak problem naming 4242", probs)
	}
}

// A kill that fails is reported as could-NOT-be-killed, a kill that succeeds
// or finds the process already gone is reported as killed.
func TestReapSeparatesKilledFromFailed(t *testing.T) {
	kills := 0
	scanned := false
	withReapSeams(t,
		func([]byte) ([]int, error) {
			if scanned {
				return nil, nil
			}
			scanned = true
			return []int{1, 2, 3}, nil
		},
		always,
		func(pid int) (killer, error) {
			switch pid {
			case 1:
				return fakeProc{nil, &kills}, nil
			case 2:
				return fakeProc{os.ErrProcessDone, &kills}, nil
			}
			return fakeProc{errors.New("operation not permitted"), &kills}, nil
		},
		func(time.Duration) {})
	probs := reapLeaked("rsdd", "n")
	if len(probs) != 2 {
		t.Fatalf("problems = %+v, want killed + failed", probs)
	}
	if !strings.Contains(probs[0].Detail, "left 2 process(es) running after it ended") || !strings.Contains(probs[0].Detail, "pids 1, 2") {
		t.Fatalf("killed problem = %q", probs[0].Detail)
	}
	if !strings.Contains(probs[1].Detail, "could NOT be killed: pids 3") {
		t.Fatalf("failed problem = %q", probs[1].Detail)
	}
}

// The run marker nonce is 24 lowercase hex characters and differs per call.
func TestNewNonce(t *testing.T) {
	a, err := newNonce()
	if err != nil {
		t.Fatal(err)
	}
	b, _ := newNonce()
	if len(a) != 24 || strings.Trim(a, "0123456789abcdef") != "" || a == b {
		t.Fatalf("nonces %q %q: want two distinct 24-char hex strings", a, b)
	}
}
