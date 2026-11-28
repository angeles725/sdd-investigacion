package cishard

import (
	"fmt"
	"reflect"
	"sort"
	"testing"
)

// Guard-to-test table (planassign.go): longest first -> TestAssignGreedyLongestFirst; ties by path ->
// TestAssignTiesByPath; ties by lowest shard -> TestAssignTiesToLowestShard; the 6 s default ->
// TestDefaultWeightIsSix; degraded position mod N -> TestWithoutWeightsIsPositionModN; the cover -> TestCoverEveryN.

func TestAssignGreedyLongestFirst(t *testing.T) {
	a := assign([]string{"a", "b", "c", "d"}, map[string]int{"a": 10, "b": 7, "c": 6, "d": 5}, 2)
	want := [][]string{{"a", "d"}, {"b", "c"}}
	if !reflect.DeepEqual(a.shares, want) || !reflect.DeepEqual(a.loads, []int{15, 13}) {
		t.Errorf("shares %v loads %v", a.shares, a.loads)
	}
}

func TestAssignTiesByPath(t *testing.T) {
	// equal weights: the path decides the order, so a goes first, to shard 1, whatever the input order was
	a := assign([]string{"c", "a", "b"}, map[string]int{"a": 5, "b": 5, "c": 5}, 3)
	want := [][]string{{"a"}, {"b"}, {"c"}}
	if !reflect.DeepEqual(a.shares, want) {
		t.Errorf("shares %v", a.shares)
	}
}

func TestAssignTiesToLowestShard(t *testing.T) {
	// loads after a and b are [5 5 0 0]; c is the third package and goes to the lowest empty shard (3), not 4
	a := assign([]string{"a", "b", "c"}, map[string]int{"a": 5, "b": 5, "c": 1}, 4)
	if len(a.shares[2]) != 1 || a.shares[2][0] != "c" || len(a.shares[3]) != 0 {
		t.Errorf("shares %v", a.shares)
	}
	// and a full tie of loads sends the next package to shard 1
	b := assign([]string{"a", "b", "c"}, map[string]int{"a": 5, "b": 5, "c": 5}, 2)
	if !reflect.DeepEqual(b.shares, [][]string{{"a", "c"}, {"b"}}) {
		t.Errorf("shares %v", b.shares)
	}
}

func TestDefaultWeightIsSix(t *testing.T) {
	a := assign([]string{"a", "b", "c", "d"}, map[string]int{"a": 11}, 2)
	if !reflect.DeepEqual(a.loads, []int{17, 12}) {
		t.Errorf("loads %v want [17 12]", a.loads)
	}
	if !reflect.DeepEqual(a.unlisted, []string{"b", "c", "d"}) {
		t.Errorf("unlisted %v", a.unlisted)
	}
	if defaultWeight != 6 {
		t.Errorf("defaultWeight %d", defaultWeight)
	}
}

func TestSharesAndUnlistedAreSortedWhateverTheInputOrder(t *testing.T) {
	// z is placed before a (heavier), yet the share lists a first; the unlisted names are sorted too
	a := assign([]string{"z", "a"}, map[string]int{"a": 1, "z": 9}, 1)
	if !reflect.DeepEqual(a.shares, [][]string{{"a", "z"}}) {
		t.Errorf("shares %v", a.shares)
	}
	u := assign([]string{"d", "b", "c"}, nil, 2)
	if !reflect.DeepEqual(u.unlisted, []string{"b", "c", "d"}) {
		t.Errorf("unlisted %v", u.unlisted)
	}
}

func TestAssignHeavierBeatsEarlierPath(t *testing.T) {
	// z weighs more than a: it is placed first, so it takes shard 1 although its path sorts last
	a := assign([]string{"a", "z"}, map[string]int{"a": 1, "z": 9}, 2)
	if !reflect.DeepEqual(a.shares, [][]string{{"z"}, {"a"}}) {
		t.Errorf("shares %v", a.shares)
	}
}

func TestWithoutWeightsIsPositionModN(t *testing.T) {
	// the degraded assignment: every package weighs the default, so the sorted list goes round-robin by position
	for _, size := range []int{1, 2, 5, 9, 33} {
		var pkgs []string
		for i := 0; i < size; i++ {
			pkgs = append(pkgs, fmt.Sprintf("pkg/%03d", i))
		}
		for n := 1; n <= maxShards; n++ {
			want := make([][]string, n)
			for i, p := range pkgs {
				want[i%n] = append(want[i%n], p)
			}
			if got := assign(pkgs, nil, n).shares; !reflect.DeepEqual(got, want) {
				t.Errorf("size %d N %d: %v want %v", size, n, got, want)
			}
		}
	}
}

func TestAssignmentOfOneShardTakesEverything(t *testing.T) {
	a := assign([]string{"a", "b"}, nil, 1)
	if !reflect.DeepEqual(a.shares, [][]string{{"a", "b"}}) || !reflect.DeepEqual(a.loads, []int{12}) {
		t.Errorf("%+v", a)
	}
}

// checkCover requires the shares to be pairwise disjoint and to cover exactly the input.
func checkCover(t *testing.T, label string, shares [][]string, n int, input []string) {
	t.Helper()
	if len(shares) != n {
		t.Errorf("%s: %d shares, want %d", label, len(shares), n)
		return
	}
	seen := map[string]int{}
	for _, sh := range shares {
		for _, p := range sh {
			seen[p]++
		}
	}
	var union []string
	for p, c := range seen {
		if c != 1 {
			t.Errorf("%s: %s appears in %d shares", label, p, c)
		}
		union = append(union, p)
	}
	sort.Strings(union)
	want := append([]string(nil), input...)
	sort.Strings(want)
	if !reflect.DeepEqual(union, want) {
		t.Errorf("%s: union %v want %v", label, union, want)
	}
}

func TestCoverEveryN(t *testing.T) {
	for _, size := range []int{1, 2, 5, 31, 32, 33, 64, 100} {
		var pkgs []string
		weights := map[string]int{}
		for i := 0; i < size; i++ {
			p := fmt.Sprintf("pkg/%03d", i)
			pkgs = append(pkgs, p)
			if i%3 != 0 { // every third package is unlisted
				weights[p] = 1 + (i*7)%23
			}
		}
		for n := 1; n <= maxShards; n++ {
			label := fmt.Sprintf("size %d N %d", size, n)
			checkCover(t, "weighted "+label, assign(pkgs, weights, n).shares, n, pkgs)
			checkCover(t, "no weights "+label, assign(pkgs, nil, n).shares, n, pkgs)
		}
	}
}
