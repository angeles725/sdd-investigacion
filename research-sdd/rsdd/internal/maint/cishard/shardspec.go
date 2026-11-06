package cishard

import (
	"fmt"
	"strconv"
	"strings"
)

// maxShards is the largest N, as MAX_SHARDS in run-all.sh.
const maxShards = 32

// shardSpec is --shard I/N.
type shardSpec struct{ i, n int }

// digits reports whether s is one to three ASCII digits (the grammar of run-all.sh: ^[0-9]{1,3}/[0-9]{1,3}$).
func digits(s string) bool {
	if len(s) < 1 || len(s) > 3 {
		return false
	}
	for _, r := range s {
		if r < '0' || r > '9' {
			return false
		}
	}
	return true
}

// parseShard reads I/N with 1 <= I <= N <= maxShards. Leading zeros are decimal, as run-all.sh reads them.
func parseShard(v string) (shardSpec, error) {
	a, b, found := strings.Cut(v, "/")
	if !found || !digits(a) || !digits(b) {
		return shardSpec{}, fmt.Errorf("invalid --shard value %q: need I/N with integers 1 <= I <= N <= %d", v, maxShards)
	}
	i, _ := strconv.Atoi(a)
	n, _ := strconv.Atoi(b)
	if n < 1 || n > maxShards || i < 1 || i > n {
		return shardSpec{}, fmt.Errorf("invalid --shard value %q: need 1 <= I <= N <= %d", v, maxShards)
	}
	return shardSpec{i: i, n: n}, nil
}
