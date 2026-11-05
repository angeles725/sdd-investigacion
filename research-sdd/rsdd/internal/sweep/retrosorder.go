package sweep

import (
	"cmp"
	"slices"
	"strings"
)

// sortOldestFirst is `sort -n -k1,1` over the joined rows of the sweep scripts: oldest first by the numeric
// epoch, equal epochs in the byte order of the whole serialized row (the last-resort comparison of sort in the
// C locale). The sort is stable.
func sortOldestFirst[T any](rows []T, epoch func(T) int64, serial func(T) string) {
	slices.SortStableFunc(rows, func(a, b T) int {
		return cmp.Or(cmp.Compare(epoch(a), epoch(b)), strings.Compare(serial(a), serial(b)))
	})
}
