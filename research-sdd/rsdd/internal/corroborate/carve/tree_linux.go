package carve

import (
	"bytes"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// procDir is where the process table is read from; tests point it at a fixture.
var procDir = "/proc"

// processTree is the number of live processes in the tree rooted at root (root included), read from /proc.
// A process whose stat cannot be read or parsed is skipped, as the script does; /proc being unreadable counts
// no process at all.
func processTree(root int) int {
	entries, err := os.ReadDir(procDir)
	if err != nil {
		return 0
	}
	parents := map[int]int{}
	for _, e := range entries {
		pid, err := strconv.Atoi(e.Name())
		if err != nil {
			continue
		}
		b, err := os.ReadFile(filepath.Join(procDir, e.Name(), "stat"))
		if err != nil {
			continue
		}
		i := bytes.LastIndexByte(b, ')')
		if i < 0 {
			continue
		}
		fields := strings.Fields(string(b[i+1:]))
		if len(fields) < 2 {
			continue
		}
		if ppid, err := strconv.Atoi(fields[1]); err == nil {
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
