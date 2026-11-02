package firmware

import (
	"bytes"
	"os"
	"strconv"
	"strings"
)

// processTree is the number of live processes in the tree rooted at root (root included), read from /proc.
// A process whose stat cannot be read or parsed is skipped, as the script does; /proc being unreadable counts
// no process at all.
func processTree(root int) int {
	entries, err := os.ReadDir("/proc")
	if err != nil {
		return 0
	}
	parents := map[int]int{}
	for _, e := range entries {
		pid, err := strconv.Atoi(e.Name())
		if err != nil {
			continue
		}
		b, err := os.ReadFile("/proc/" + e.Name() + "/stat")
		if err != nil {
			continue
		}
		if ppid, ok := parentOf(b); ok {
			parents[pid] = ppid
		}
	}
	tree := map[int]bool{root: true}
	for grew := true; grew; {
		grew = false
		for pid, ppid := range parents {
			if !tree[pid] && tree[ppid] {
				tree[pid], grew = true, true
			}
		}
	}
	n := 0
	for pid := range tree {
		if _, alive := parents[pid]; alive {
			n++
		}
	}
	return n
}

// parentOf is the parent pid in the text of a /proc/<pid>/stat file: the second field after the last ")" (the
// command name may itself contain parentheses and spaces). ok is false when the text does not hold one.
func parentOf(stat []byte) (ppid int, ok bool) {
	i := bytes.LastIndexByte(stat, ')')
	if i < 0 {
		return 0, false
	}
	fields := strings.Fields(string(stat[i+1:]))
	if len(fields) < 2 {
		return 0, false
	}
	ppid, err := strconv.Atoi(fields[1])
	return ppid, err == nil
}
