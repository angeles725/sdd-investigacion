package corrections

import (
	"os"
	"reflect"
	"testing"
)

func readFocusesOf(t *testing.T, m map[string]string) map[string]string {
	t.Helper()
	got, err := readFocuses(corpus(t, m), func(p string) (string, error) {
		b, err := os.ReadFile(p)
		return string(b), err
	}, os.ReadDir)
	if err != nil {
		t.Fatal(err)
	}
	return got
}

func TestReadFocuses(t *testing.T) {
	row := func(slug, prefix string) string {
		return "| `" + slug + "` | s | st | `" + prefix + "-blockN.md` | q |\n"
	}
	t.Run("the last row of the same slug wins", func(t *testing.T) {
		got := readFocusesOf(t, files("FOCUSES.md", row("integ", "aa")+row("other", "zz")+row("integ", "bb")))
		if want := map[string]string{"integ": "bb", "other": "zz"}; !reflect.DeepEqual(got, want) {
			t.Errorf("got %v want %v", got, want)
		}
	})
	t.Run("files are read in sorted path order, so a later path overrides an earlier one", func(t *testing.T) {
		// "a/FOCUSES.md" sorts before "b/FOCUSES.md" and "FOCUSES.md" (uppercase F) sorts before both.
		got := readFocusesOf(t, files("b/FOCUSES.md", row("s", "second"), "a/FOCUSES.md", row("s", "first"), "FOCUSES.md", row("s", "root")))
		if got["s"] != "second" {
			t.Errorf("got %v, want the byte-last path (b/FOCUSES.md) to win", got)
		}
	})
	t.Run("the prefix may sit in any cell after the slug", func(t *testing.T) {
		got := readFocusesOf(t, files("FOCUSES.md",
			"| `late` | s | st | q | `zz-block7.md` |\n"+
				"| `two` | `aa-blockN.md` | `bb-blockN.md` | q |\n"+
				"| `none` | s | st | q |\n"))
		if want := map[string]string{"late": "zz", "two": "aa"}; !reflect.DeepEqual(got, want) {
			t.Errorf("got %v want %v (the first cell that carries a token wins; a row with none maps nothing)", got, want)
		}
	})
}
