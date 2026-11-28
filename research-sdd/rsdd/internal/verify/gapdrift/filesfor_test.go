package gapdrift

import (
	"reflect"
	"regexp"
	"testing"
)

// PRESERVE (kit issue #2686): filesFor tests a literal before the regexp; the files it returns are the regexp's.
func TestFilesForMatchesTheRegexpOverEveryBlock(t *testing.T) {
	t.Parallel()
	blocks := []string{
		"/c/a-block1.md", "/c/a-block10.md", "/c/a-block11-x.md", "/c/a-bloque1.md", "/c/a-bloque10-y_z.md", "/c/b-block01.md",
		"/c/b-block1-.md", "/c/b-block1-a.b.md", "/c/b-block1.md.bak", "/c/b-bloque1é.md", "/c/ablock1.md", "/c/a-block1-block1.md",
		"/c/a-block2-block1.md", "/c/x-block12.md", "/c/x-block21.md", "/c/retros/x-bloque3-n.md",
	}
	for _, num := range []string{"1", "2", "3", "10", "01", "12", "21", "0", "9"} {
		c := &Corpus{blocks: blocks, byNum: map[string][]string{}}
		re := regexp.MustCompilePOSIX(`-(block|bloque)` + regexp.QuoteMeta(num) + `(-[[:alnum:]_-]+)?\.md$`)
		var want []string
		for _, b := range blocks {
			if re.MatchString(b) {
				want = append(want, b)
			}
		}
		if got := c.filesFor(num); !reflect.DeepEqual(got, want) {
			t.Errorf("filesFor(%q) = %q, want %q", num, got, want)
		}
		if got := c.filesFor(num); !reflect.DeepEqual(got, want) { // the memoized answer
			t.Errorf("second filesFor(%q) = %q, want %q", num, got, want)
		}
	}
}
