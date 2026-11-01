package bog

import (
	"reflect"
	"strings"
	"testing"
)

func TestDecodeReplace(t *testing.T) {
	const rep = "�"
	tests := []struct {
		name string
		in   []byte
		want string
	}{
		{"ascii", []byte("abc"), "abc"},
		{"valid multibyte", []byte("é€😀"), "é€😀"},
		{"lone continuation", []byte{0x80}, rep},
		{"two lone continuations", []byte{0x80, 0x80}, rep + rep},
		{"overlong lead C0", []byte{0xC0, 0x80}, rep + rep},
		{"truncated 3-byte is one replacement", []byte{0xE2, 0x82, 'A'}, rep + "A"},
		{"truncated 4-byte is one replacement", []byte{0xF0, 0x9F, 0x98, 'A'}, rep + "A"},
		{"surrogate ED A0 is three replacements", []byte{0xED, 0xA0, 0x80}, rep + rep + rep},
		{"F4 90 is out of range", []byte{0xF4, 0x90, 0x80, 0x80}, rep + rep + rep + rep},
		{"lead at end of input", []byte{'a', 0xE2}, "a" + rep},
		{"FF byte", []byte{0xFF, 'x'}, rep + "x"},
		{"BOM is kept", []byte("\xEF\xBB\xBF<"), string(rune(0xFEFF)) + "<"},
		{"E0 needs A0 or above", []byte{0xE0, 0x80, 0x80}, rep + rep + rep},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := DecodeReplace(tt.in); got != tt.want {
				t.Errorf("DecodeReplace(% x) = %q, want %q", tt.in, got, tt.want)
			}
		})
	}
}

func TestIsSpaceFollowsPythonStrIsspace(t *testing.T) {
	for _, r := range []rune{' ', '\t', '\n', '\v', '\f', '\r', 0x1c, 0x1d, 0x1e, 0x1f, 0x85, 0xA0, 0x2028, 0x2029, 0x3000} {
		if !IsSpace(r) {
			t.Errorf("IsSpace(%U) = false, want true", r)
		}
	}
	for _, r := range []rune{'a', '0', 0x200B, 0xFEFF, 0x180E, 0x1b, 0x20} {
		if r == 0x20 {
			continue
		}
		if IsSpace(r) {
			t.Errorf("IsSpace(%U) = true, want false", r)
		}
	}
}

func TestSplitLines(t *testing.T) {
	tests := []struct {
		name string
		in   string
		want []string
	}{
		{"empty", "", []string{}},
		{"lf", "a\nb", []string{"a", "b"}},
		{"trailing lf has no empty tail", "a\n", []string{"a"}},
		{"crlf is one break", "a\r\nb", []string{"a", "b"}},
		{"lone cr", "a\rb", []string{"a", "b"}},
		{"vt ff", "a\vb\fc", []string{"a", "b", "c"}},
		{"file group record separators", "a\x1cb\x1dc\x1ed", []string{"a", "b", "c", "d"}},
		{"nel and unicode separators", "a\u0085b c d", []string{"a", "b", "c", "d"}},
		{"blank lines are kept", "a\n\nb", []string{"a", "", "b"}},
		{"only a break", "\n", []string{""}},
		{"cr then lf then cr", "a\r\n\rb", []string{"a", "", "b"}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := SplitLines(tt.in)
			if got == nil {
				got = []string{}
			}
			if !reflect.DeepEqual(got, tt.want) {
				t.Errorf("SplitLines(%q) = %q, want %q", tt.in, got, tt.want)
			}
		})
	}
	if got := SplitLines(strings.Repeat("x\n", 3)); len(got) != 3 {
		t.Errorf("trailing newline produced %d lines, want 3", len(got))
	}
}

func TestIsWordFollowsPythonRegexW(t *testing.T) {
	for _, r := range []rune{'a', 'Z', '0', '_', 'é', '\u0660', '\u00b2', '\u2160', '\u4e2d'} { // letters, Nd, No, Nl, CJK
		if !IsWord(r) {
			t.Errorf("IsWord(%U) = false, want true", r)
		}
	}
	for _, r := range []rune{'-', ' ', '.', '=', '\'', '\u0301', '\u2014'} { // punctuation, space, combining mark
		if IsWord(r) {
			t.Errorf("IsWord(%U) = true, want false", r)
		}
	}
}
