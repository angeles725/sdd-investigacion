package cli

import (
	"slices"
	"testing"
)

func TestStdioEnvironment(t *testing.T) {
	if got := (Stdio{}).Environment(); got != nil {
		t.Errorf("no Environ: got %q, want nil", got)
	}
	want := []string{"A=1", "B=2"}
	s := Stdio{Environ: func() []string { return want }}
	if got := s.Environment(); !slices.Equal(got, want) {
		t.Errorf("Environment() = %q, want %q", got, want)
	}
	if got := (Stdio{Environ: func() []string { return []string{} }}).Environment(); got == nil || len(got) != 0 {
		t.Errorf("an empty Environ is returned as is (empty, not nil): %#v", got)
	}
}
