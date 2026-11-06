package cleancheck

// span is an inclusive range of characters.
type span struct{ lo, hi rune }

// classes are bash's POSIX bracket classes in the C locale: ASCII only.
var classes = map[string][]span{
	"alpha":  {{'a', 'z'}, {'A', 'Z'}},
	"digit":  {{'0', '9'}},
	"alnum":  {{'a', 'z'}, {'A', 'Z'}, {'0', '9'}},
	"upper":  {{'A', 'Z'}},
	"lower":  {{'a', 'z'}},
	"space":  {{' ', ' '}, {'\t', '\r'}},
	"blank":  {{' ', ' '}, {'\t', '\t'}},
	"punct":  {{'!', '/'}, {':', '@'}, {'[', '`'}, {'{', '~'}},
	"xdigit": {{'0', '9'}, {'a', 'f'}, {'A', 'F'}},
}
