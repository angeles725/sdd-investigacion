//go:build linux

package parity

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"sort"
	"strconv"
	"strings"
	"time"
)

const maxReapPasses = 5

// reapLeaked finds every process whose environment carries the exact entry
// RSDD_PARITY_RUN=nonce (found through /proc), SIGKILLs it and reports the
// pids as a leaked-process problem. Nothing is ever matched by name, and the
// marker is re-read right before each kill to narrow pid reuse. Entries that
// cannot be read (another user's process, a process that just exited) are
// skipped; a /proc that cannot be listed is reported, never a silent pass.
func reapLeaked(side, nonce string) []Problem {
	want := []byte(runMarkerEnv + "=" + nonce)
	killed, failed := map[int]bool{}, map[int]bool{}
	var scanErr error
	for pass := 0; pass < maxReapPasses; pass++ {
		pids, err := markedPids(want)
		if err != nil {
			scanErr = err
			break
		}
		if len(pids) == 0 {
			break
		}
		for _, pid := range pids {
			// Take the handle (a pidfd on Linux) first, then re-verify the
			// marker, then kill through that same handle: a pid reused after
			// the check cannot be the one signalled.
			p, err := os.FindProcess(pid)
			if err != nil || !hasMarker(pid, want) {
				continue
			}
			if err := p.Kill(); err != nil && !errors.Is(err, os.ErrProcessDone) {
				failed[pid] = true
				continue
			}
			killed[pid] = true
		}
		time.Sleep(20 * time.Millisecond) // let the kills land before rescanning
	}
	var out []Problem
	if len(killed) > 0 {
		out = append(out, Problem{KindLeaked, fmt.Sprintf("the %s run left %d process(es) running after it ended (outside its group or surviving it; killed): pids %s", side, len(killed), pidList(killed))})
	}
	if len(failed) > 0 {
		out = append(out, Problem{KindLeaked, fmt.Sprintf("the %s run left %d process(es) running that could NOT be killed: pids %s", side, len(failed), pidList(failed))})
	}
	if scanErr != nil { // reported with, never instead of, the pids already found
		out = append(out, Problem{KindDegraded, fmt.Sprintf("the %s run: cannot scan /proc for leaked processes: %v", side, scanErr)})
	}
	return out
}

func pidList(set map[int]bool) string {
	list := make([]int, 0, len(set))
	for pid := range set {
		list = append(list, pid)
	}
	sort.Ints(list)
	ids := make([]string, len(list))
	for i, pid := range list {
		ids[i] = strconv.Itoa(pid)
	}
	return strings.Join(ids, ", ")
}

func markedPids(want []byte) ([]int, error) {
	ents, err := os.ReadDir("/proc")
	if err != nil {
		return nil, err
	}
	self := os.Getpid()
	var out []int
	for _, e := range ents {
		pid, err := strconv.Atoi(e.Name())
		if err != nil || pid == self {
			continue
		}
		if hasMarker(pid, want) {
			out = append(out, pid)
		}
	}
	return out, nil
}

func hasMarker(pid int, want []byte) bool {
	b, err := os.ReadFile("/proc/" + strconv.Itoa(pid) + "/environ")
	if err != nil {
		return false
	}
	for _, kv := range bytes.Split(b, []byte{0}) {
		if bytes.Equal(kv, want) {
			return true
		}
	}
	return false
}
