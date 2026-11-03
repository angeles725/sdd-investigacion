package verify

import (
	"strings"
	"testing"
)

func TestCompactCountsCharactersUnderAUTF8Locale(t *testing.T) {
	line := "WARN  " + strings.Repeat("é", 100) // 106 characters, 206 bytes
	// bytes mode cuts at 97 bytes (6 + 91, the last é split) and the split sequence is dropped before "..."
	if got, want := compactRegistry(line, false), "WARN  "+strings.Repeat("é", 45)+"...\n"; !strings.HasPrefix(got, want) {
		t.Errorf("bytes mode got %q, want prefix %q", got, want)
	}
	if got, want := compactRegistry(line, true), "WARN  "+strings.Repeat("é", 91)+"...\n"; !strings.HasPrefix(got, want) {
		t.Errorf("chars mode got %q, want prefix %q", got, want)
	}
	short := "WARN  " + strings.Repeat("é", 94) // 100 characters: whole in chars mode, cut in bytes mode
	if !strings.HasPrefix(compactRegistry(short, true), short+"\n") {
		t.Error("a 100-character WARN must pass whole under a UTF-8 locale")
	}
	for env, want := range map[string]awkChars{"en_US.UTF-8": true, "C.utf8": true, "C": false, "": false} {
		e := map[string]string{"LC_ALL": env}
		if got := localeCounts(func(k string) string { return e[k] }); got != want {
			t.Errorf("LC_ALL=%q counts chars = %v, want %v", env, got, want)
		}
	}
	e := map[string]string{"LC_ALL": "C", "LANG": "en_US.UTF-8"}
	if localeCounts(func(k string) string { return e[k] }) {
		t.Error("LC_ALL wins over LANG")
	}
}
