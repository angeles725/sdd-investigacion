package serial

import (
	"testing"
	"unicode"
)

// Every Unicode decimal digit, in code point order, runs 0..9 and starts again (Python's int() reads them all):
// the value digitValue gives must follow that, including the last digit of every range.
func TestDigitValueAllNd(t *testing.T) {
	i := 0
	for r := rune(0); r <= unicode.MaxRune; r++ {
		if unicode.Is(unicode.Nd, r) {
			if got := digitValue(r); got != i%10 {
				t.Fatalf("digitValue(%U) = %d, want %d", r, got, i%10)
			}
			i++
		}
	}
	if i < 700 {
		t.Fatalf("only %d decimal digits found", i)
	}
}

func TestPyDecodeReplaceLeads(t *testing.T) {
	for _, tc := range []struct{ in, want string }{
		{"\xc1\x80", "��"},           // C1 is never a lead: its continuation byte stands alone
		{"\xf5\x80\x80\x80", "����"}, // F5 is above the last lead
		{"\xe0\xa0", "�"},            // truncated after a valid second byte
		{"\xe0\x9f\x80", "���"},      // second byte below the E0 range
		{"\xee\x80", "�"},
		{"\xef\xbf", "�"},
		{"\xec\x80x", "�x"},
		{"\xed\x9f", "�"},
		{"\xed\xa0", "��"},
		{"\xf0\x90", "�"},
		{"\xf0\x8f", "��"},
		{"\xf3\xbf\xbf", "�"},
		{"\xf4\x8f\xbf", "�"},
		{"\xf4\x90", "��"},
	} {
		if got := pyDecodeReplace([]byte(tc.in)); got != tc.want {
			t.Errorf("pyDecodeReplace(%q) = %q, want %q", tc.in, got, tc.want)
		}
	}
}
