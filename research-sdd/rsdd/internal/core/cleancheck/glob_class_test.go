package cleancheck

import (
	"strings"
	"testing"
)

const (
	digits = "0123456789"
	upper  = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
	lower  = "abcdefghijklmnopqrstuvwxyz"
)

// classMembers lists, per POSIX class, every ASCII character bash's `[[ c == [[:class:]] ]]` accepts in the C locale
// (read off bash 5 for the characters 1..127).
var classMembers = map[string]string{
	"alpha":  upper + lower,
	"digit":  digits,
	"alnum":  digits + upper + lower,
	"upper":  upper,
	"lower":  lower,
	"space":  " \t\n\v\f\r",
	"blank":  " \t",
	"punct":  "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~",
	"xdigit": digits + "ABCDEF" + "abcdef",
}

// Every ASCII character is tested against every class, so each range's two ends and both neighbours are pinned.
func TestGlobMatchClassMembers(t *testing.T) {
	for name, members := range classMembers {
		for c := rune(1); c < 128; c++ {
			want := strings.ContainsRune(members, c)
			if got := globMatch("[[:"+name+":]]", string(c)); got != want {
				t.Errorf("[[:%s:]] against %q = %v, want %v", name, c, got, want)
			}
			if got := globMatch("[^[:"+name+":]]", string(c)); got == want {
				t.Errorf("[^[:%s:]] against %q = %v, want %v", name, c, got, !want)
			}
		}
	}
}

// Characters beyond ASCII belong to no class.
func TestGlobMatchClassesAreAscii(t *testing.T) {
	for name := range classMembers {
		for _, c := range []string{"é", "Ā", "K"} {
			if globMatch("[[:"+name+":]]", c) {
				t.Errorf("[[:%s:]] matched %q", name, c)
			}
		}
	}
}
