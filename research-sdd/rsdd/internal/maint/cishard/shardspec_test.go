package cishard

import "testing"

// Guard-to-test table (shardspec.go): the grammar, the 1 <= I <= N <= 32 bounds and leading zeros.

func TestParseShard(t *testing.T) {
	for _, c := range []struct {
		in   string
		i, n int
	}{
		{"1/1", 1, 1}, {"2/3", 2, 3}, {"32/32", 32, 32}, {"1/32", 1, 32}, {"01/02", 1, 2}, {"010/032", 10, 32},
	} {
		s, err := parseShard(c.in)
		if err != nil || s.i != c.i || s.n != c.n {
			t.Errorf("%q: %+v %v", c.in, s, err)
		}
	}
	for _, bad := range []string{"", "1", "0/1", "1/0", "2/1", "1/33", "33/33", "x/2", "1/x", "1/2/3", "/2", "1/", " 1/2", "1000/1000", "+1/2", "0001/0002", "1/0002"} {
		if _, err := parseShard(bad); err == nil {
			t.Errorf("%q accepted", bad)
		}
	}
}
