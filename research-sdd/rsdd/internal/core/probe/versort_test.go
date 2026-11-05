package probe

import (
	"bufio"
	"os"
	"strconv"
	"strings"
	"testing"
)

func sign(n int) int {
	switch {
	case n < 0:
		return -1
	case n > 0:
		return 1
	}
	return 0
}

// TestFilevercmpMatchesFrozenSortV replays every ordered pair of testdata/filevercmp-sortv.tsv, frozen from GNU
// `sort -V -s`, through filevercmp. The corpus covers the suffix rule (".tar.gz", "~", a trailing '.'), letter
// boundaries (a z A Z and their neighbours @ ` [ {), leading zeros and digit runs whose first difference is
// outweighed by length ("19" vs "28" vs "9" vs "10").
func TestFilevercmpMatchesFrozenSortV(t *testing.T) {
	f, err := os.Open("testdata/filevercmp-sortv.tsv")
	if err != nil {
		t.Fatalf("frozen oracle unreadable: %v", err)
	}
	defer f.Close()
	n := 0
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := sc.Text()
		if strings.HasPrefix(line, "#") {
			continue
		}
		parts := strings.Split(line, "\t")
		if len(parts) != 3 {
			t.Fatalf("malformed oracle line %q", line)
		}
		want, err := strconv.Atoi(parts[0])
		if err != nil {
			t.Fatalf("malformed sign in %q", line)
		}
		if got := sign(filevercmp(parts[1], parts[2])); got != want {
			t.Errorf("filevercmp(%q, %q) sign = %d; sort -V says %d", parts[1], parts[2], got, want)
		}
		n++
	}
	if err := sc.Err(); err != nil {
		t.Fatal(err)
	}
	if n < 1000 {
		t.Fatalf("only %d oracle pairs replayed", n)
	}
}
