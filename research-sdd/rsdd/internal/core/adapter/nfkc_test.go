//go:build linux

package adapter

import "testing"

func TestNFKCFoldsCompatibilityASCIIAndNothingElse(t *testing.T) {
	for in, want := range map[string]string{
		"abc": "abc", "": "", "\ufb01": "fi", "\uff41\uff42": "ab", "\uff12": "2", "\u2025": "..", "\uff0f": "/", "\uff3c": "\\",
		"\u2024": ".", "\u2215": "\u2215", "\u00e9": "\u00e9", "e\u0301": "e\u0301", "\uac01": "\uac01", "\u212b": "\u212b",
	} {
		if got := nfkc(in); got != want {
			t.Errorf("nfkc(%+q) = %+q, want %+q", in, got, want)
		}
	}
}
