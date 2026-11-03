// Package gitfixture is the environment for git commands that tests run against their own fixture repositories.
package gitfixture

import (
	"fmt"
	"strconv"
	"strings"
)

// Env returns a copy of base that turns off git's background maintenance. With git 2.56, every commit starts
// `git maintenance run --auto --detach`, which takes .git/objects/maintenance.lock and removes it later, so a test
// that commits and then copies, walks or fingerprints the repository races it (kit issue #2624). The settings are
// maintenance.auto=false and gc.auto=0, passed through GIT_CONFIG_COUNT/KEY_n/VALUE_n:
//   - An existing GIT_CONFIG_COUNT (the last entry, as exec reads it) is extended: the two keys take the next
//     indexes and the count grows by two, so the caller's own config entries stay in force.
//   - A GIT_CONFIG_COUNT that is not a non-negative integer panics, as does a nil base. A nil exec.Cmd.Env inherits
//     the parent environment, and `cmd.Env = gitfixture.Env(cmd.Env)` would replace it with these five entries;
//     pass os.Environ() or an explicit list.
func Env(base []string) []string {
	if base == nil {
		panic("gitfixture.Env: nil base would replace the inherited environment; pass os.Environ() or an explicit list")
	}
	n := 0
	for i := len(base) - 1; i >= 0; i-- {
		if v, ok := strings.CutPrefix(base[i], "GIT_CONFIG_COUNT="); ok {
			c, err := strconv.Atoi(v)
			if err != nil || c < 0 {
				panic(fmt.Sprintf("gitfixture.Env: GIT_CONFIG_COUNT=%q is not a non-negative integer", v))
			}
			n = c
			break
		}
	}
	out := make([]string, 0, len(base)+5)
	for _, kv := range base {
		if !strings.HasPrefix(kv, "GIT_CONFIG_COUNT=") {
			out = append(out, kv)
		}
	}
	return append(out,
		fmt.Sprintf("GIT_CONFIG_KEY_%d=maintenance.auto", n), fmt.Sprintf("GIT_CONFIG_VALUE_%d=false", n),
		fmt.Sprintf("GIT_CONFIG_KEY_%d=gc.auto", n+1), fmt.Sprintf("GIT_CONFIG_VALUE_%d=0", n+1),
		fmt.Sprintf("GIT_CONFIG_COUNT=%d", n+2))
}
