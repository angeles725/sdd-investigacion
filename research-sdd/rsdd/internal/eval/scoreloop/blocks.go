package scoreloop

import (
	"math"
	"math/big"
	"regexp"
	"strings"
)

// blockEntry is one block commit: its commit epoch and its weight (the number of blocks the subject cites).
type blockEntry struct{ epoch, weight int64 }

// idRegionCuts end the part of a subject that names what was committed: a parenthetical, an em dash or an arrow
// starts the descriptive title and citations, so a retro that merely cites a closed range is not counted.
var idRegionCuts = []string{"(", "—", "→"}

// idRegion is rest up to its first cut.
func idRegion(rest string) string {
	cut := len(rest)
	for _, c := range idRegionCuts {
		if i := strings.Index(rest, c); i >= 0 && i < cut {
			cut = i
		}
	}
	return rest[:cut]
}

// weighed is the verdict on one commit subject.
type weighed struct {
	matched     bool
	weight      int64
	implausible bool   // the range was wider than the cap and counts as one block
	start, end  string // the block numbers as written (leading zeros kept)
}

var blockNumber = regexp.MustCompile(`^[0-9]+$`)

// weigh decides whether subject is a block commit and what it weighs. The block reference is looked for only in
// the region before the first cut. A B<n>-B<m> range weighs m-n+1, capped: a span over the cap (a typo, a
// non-block numeric range) is ONE block with a warning, and a reversed range is one block.
func (c *Config) weigh(subject string) weighed {
	m := c.BlockCommit.FindStringSubmatch(subject)
	if m == nil {
		return weighed{}
	}
	id := c.BlockID.FindStringSubmatch(idRegion(m[2]))
	if id == nil {
		return weighed{}
	}
	start, end := id[1], id[1]
	if len(id) > 3 && id[3] != "" {
		end = id[3]
	}
	if !blockNumber.MatchString(start) || !blockNumber.MatchString(end) {
		return weighed{}
	}
	span := new(big.Int).Sub(parseBig(end), parseBig(start))
	w := weighed{matched: true, weight: 1, start: start, end: end}
	switch {
	case span.Cmp(c.RangeCap) > 0:
		w.implausible = true
	case span.Sign() >= 0:
		w.weight = satWeight(span)
	}
	return w
}

// satWeight is span+1, saturating at the int64 maximum.
func satWeight(span *big.Int) int64 {
	if !span.IsInt64() || span.Int64() == math.MaxInt64 {
		return math.MaxInt64
	}
	return span.Int64() + 1
}

func parseBig(digits string) *big.Int {
	n, _ := new(big.Int).SetString(digits, 10)
	return n
}

// totalWeight is the number of blocks the entries cite.
func totalWeight(entries []blockEntry) int64 {
	var n int64
	for _, e := range entries {
		n += e.weight
	}
	return n
}
