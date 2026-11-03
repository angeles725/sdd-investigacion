package formats

import (
	"slices"
	"testing"
)

// invalidPrefixLen is what the replace-decoder measures; a complete, well-formed sequence is not a case the
// decoder feeds it, but the helper's contract is "the length of the longest prefix of a well-formed sequence".
func TestInvalidPrefixLenBounds(t *testing.T) {
	for name, c := range map[string]struct {
		in   []byte
		want int
	}{
		"complete two byte":       {[]byte{0xC3, 0xA9}, 2},
		"complete three byte":     {[]byte{0xE2, 0x82, 0xAC}, 3},
		"complete four byte":      {[]byte{0xF0, 0x9F, 0x98, 0x80}, 4},
		"two of three":            {[]byte{0xE2, 0x82}, 2},
		"two of three then ascii": {[]byte{0xE2, 0x82, 'a'}, 2},
		"lead only":               {[]byte{0xE2}, 1},
		"lead then ascii":         {[]byte{0xE2, 'a'}, 1},
		"three of four":           {[]byte{0xF0, 0x9F, 0x98}, 3},
		"stray continuation":      {[]byte{0x80, 0x80}, 1},
	} {
		if got := invalidPrefixLen(c.in); got != c.want {
			t.Errorf("%s: invalidPrefixLen(% x) = %d, want %d", name, c.in, got, c.want)
		}
	}
}

func TestZipDecodeCP437HighHalf(t *testing.T) {
	for b := 0x80; b <= 0xFF; b++ {
		want := string(zipCP437[b-0x80])
		if got := zipDecodeCP437([]byte{byte(b)}); got != want {
			t.Errorf("byte %#x -> %+q, want %+q", b, got, want)
		}
	}
	for b, want := range map[byte]string{0x00: "\x00", 0x41: "A", 0x7f: "\x7f", 0x80: "Ç", 0x81: "ü", 0xb0: "░", 0xe1: "ß", 0xfe: "■", 0xff: " "} {
		if got := zipDecodeCP437([]byte{b}); got != want {
			t.Errorf("byte %#x -> %+q, want %+q", b, got, want)
		}
	}
}

func TestZipDecomposeHangulRange(t *testing.T) {
	const first, last = hangulSBase, hangulSBase + hangulSCount - 1
	for name, c := range map[string]struct {
		in   rune
		want []rune
	}{
		"below the block":    {first - 1, []rune{first - 1}},
		"first syllable":     {first, []rune{0x1100, 0x1161}},
		"first LVT":          {first + 1, []rune{0x1100, 0x1161, 0x11a8}},
		"last syllable":      {last, []rune{0x1112, 0x1175, 0x11c2}},
		"just past the last": {last + 1, []rune{last + 1}},
	} {
		if got := zipDecompose(nil, c.in); !slices.Equal(got, c.want) {
			t.Errorf("%s: decompose(%U) = %U, want %U", name, c.in, got, c.want)
		}
	}
}

func TestZipPairComposeHangulBounds(t *testing.T) {
	const lastLV = hangulSBase + (hangulLCount*hangulVCount-1)*hangulTCount
	for name, c := range map[string]struct {
		a, b rune
		want rune // 0: must not compose
	}{
		"first L+V":                {hangulLBase, hangulVBase, hangulSBase},
		"last L":                   {hangulLBase + hangulLCount - 1, hangulVBase, hangulSBase + (hangulLCount-1)*hangulNCount},
		"past last L":              {hangulLBase + hangulLCount, hangulVBase, 0},
		"below first L":            {hangulLBase - 1, hangulVBase, 0},
		"last V":                   {hangulLBase, hangulVBase + hangulVCount - 1, hangulSBase + (hangulVCount-1)*hangulTCount},
		"past last V":              {hangulLBase, hangulVBase + hangulVCount, 0},
		"below first V":            {hangulLBase, hangulVBase - 1, 0},
		"LV + first T":             {hangulSBase, hangulTBase + 1, hangulSBase + 1},
		"LV + last T":              {hangulSBase, hangulTBase + hangulTCount - 1, hangulSBase + hangulTCount - 1},
		"LV + T base (no trail)":   {hangulSBase, hangulTBase, 0},
		"LV + past last T":         {hangulSBase, hangulTBase + hangulTCount, 0},
		"last LV + first T":        {lastLV, hangulTBase + 1, lastLV + 1},
		"just past the last LV":    {hangulSBase + hangulSCount, hangulTBase + 1, 0},
		"LVT does not take a T":    {hangulSBase + 1, hangulTBase + 1, 0},
		"below the syllable block": {hangulSBase - hangulTCount, hangulTBase + 1, 0},
	} {
		got, ok := zipPairCompose(c.a, c.b)
		if c.want == 0 {
			if ok {
				t.Errorf("%s: compose(%U, %U) = %U, want no composition", name, c.a, c.b, got)
			}
			continue
		}
		if !ok || got != c.want {
			t.Errorf("%s: compose(%U, %U) = %U,%v, want %U", name, c.a, c.b, got, ok, c.want)
		}
	}
}

func TestZipNFCHangulEdges(t *testing.T) {
	for _, r := range []rune{hangulSBase, hangulSBase + 1, hangulSBase + hangulSCount - 1, hangulSBase + hangulSCount, hangulSBase - 1} {
		if got := zipNFC(string(r)); got != string(r) {
			t.Errorf("NFC(%U) = %+q", r, got)
		}
	}
	if got := zipNFC("힣"); got != string(rune(hangulSBase+hangulSCount-1)) {
		t.Errorf("last syllable composed = %+q", got)
	}
}
