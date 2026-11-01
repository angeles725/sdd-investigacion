//go:build linux

package parity

import (
	"bytes"
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
	killed := map[int]bool{}
	for pass := 0; pass < maxReapPasses; pass++ {
		pids, err := markedPids(want)
		if err != nil {
			return []Problem{{KindDegraded, fmt.Sprintf("the %s run: cannot scan /proc for leaked processes: %v", side, err)}}
		}
		if len(pids) == 0 {
			break
		}
		for _, pid := range pids {
			if !hasMarker(pid, want) { // re-verify right before the kill
				continue
			}
			if p, err := os.FindProcess(pid); err == nil {
				_ = p.Kill()
			}
			killed[pid] = true
		}
		time.Sleep(20 * time.Millisecond) // let the kills land before rescanning
	}
	if len(killed) == 0 {
		return nil
	}
	list := make([]int, 0, len(killed))
	for pid := range killed {
		list = append(list, pid)
	}
	sort.Ints(list)
	ids := make([]string, len(list))
	for i, pid := range list {
		ids[i] = strconv.Itoa(pid)
	}
	// A survivor of the final pass is still reported (and was SIGKILLed).
	return []Problem{{KindLeaked, fmt.Sprintf("the %s run left %d process(es) outside its process group (killed): pids %s", side, len(list), strings.Join(ids, ", "))}}
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
