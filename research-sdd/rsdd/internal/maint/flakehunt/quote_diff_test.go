//go:build !nodiff

package flakehunt

import (
	"os/exec"
	"testing"
)

// TestShQuoteAgainstBash asks the real bash for printf %q on every case above, every printable ASCII byte alone and
// in the leading, trailing and after-: / after-= positions (the set of specials is the oracle's, not a guess).
func TestShQuoteAgainstBash(t *testing.T) {
	words := []string{}
	for in := range quoteCases {
		words = append(words, in)
	}
	for c := 0x20; c < 0x7f; c++ {
		ch := string(rune(c))
		words = append(words, ch, "a"+ch, ch+"a", "a:"+ch, "a="+ch)
	}
	for _, in := range words {
		out, err := exec.Command("bash", "-c", `LC_ALL=en_US.UTF-8 printf '%q' "$1"`, "_", in).Output()
		if err != nil {
			t.Fatal(err)
		}
		if got := shQuote(in); got != string(out) {
			t.Errorf("shQuote(%q) = %s, bash printf %%q = %s", in, got, out)
		}
	}
}
