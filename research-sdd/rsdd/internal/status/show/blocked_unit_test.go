package show

import (
	"slices"
	"testing"
)

func TestIndexNeeds(t *testing.T) {
	for in, want := range map[string]int{
		"needs: x":       0,
		"a NeEdS: b":     2,
		"x needs:":       2,
		"needs":          -1,
		"needsx: y":      -1,
		"need: y":        -1,
		"":               -1,
		"a needs needs:": 8,
		"NEEDS:":         0,
		"neeDſ: ok":      -1, // not ASCII: the long s does not fold to s byte-wise
	} {
		if got := indexNeeds(in); got != want {
			t.Errorf("indexNeeds(%q) = %d, want %d", in, got, want)
		}
	}
}

func TestBlockedNamesBulletStartingWithNeeds(t *testing.T) {
	got := blockedNames("- needs: owner\n- gap-a needs: x\n- gap-b\n")
	if want := []string{"gap-a", "gap-b"}; !slices.Equal(got, want) {
		t.Fatalf("blockedNames = %q, want %q (a bullet that is only a needs: tail has no name)", got, want)
	}
}
