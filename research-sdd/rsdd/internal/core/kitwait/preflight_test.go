package kitwait

import (
	"os"
	"path/filepath"
	"testing"
)

func TestBadKnob(t *testing.T) {
	env := map[string]string{}
	get := func(k string) string { return env[k] }
	if got := BadKnob(get); got != "" {
		t.Errorf("nothing set: %q", got)
	}
	for _, k := range Knobs {
		env = map[string]string{k: "12"}
		if got := BadKnob(get); got != "" {
			t.Errorf("%s=12 is fine: %q", k, got)
		}
		for _, bad := range []string{"1x", "-3", " 4", "0x10"} {
			env = map[string]string{k: bad}
			if got := BadKnob(get); got != k {
				t.Errorf("%s=%q: got %q", k, bad, got)
			}
		}
	}
}

func TestMergeGateMissing(t *testing.T) {
	dir := t.TempDir()
	file := filepath.Join(dir, "gate.sh")
	if err := os.WriteFile(file, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(filepath.Join(dir, "sub"), 0o755); err != nil {
		t.Fatal(err)
	}
	for _, c := range []struct {
		name, script, self, base, want string
	}{
		{"absolute script", file, "", "/elsewhere", ""},
		{"relative script from base", "gate.sh", "", dir, ""},
		{"relative script not under base", "gate.sh", "", filepath.Join(dir, "sub"), "gate.sh"},
		{"missing script", "/nonexistent/g.sh", file, dir, "/nonexistent/g.sh"},
		{"a directory is not a script", filepath.Join(dir, "sub"), file, dir, filepath.Join(dir, "sub")},
		{"default gate: the binary", "", file, dir, ""},
		{"default gate: binary unknown", "", "", dir, "the rsdd binary (the default merge gate) cannot be located"},
		{"default gate: binary gone", "", "/nonexistent/rsdd", dir, "/nonexistent/rsdd"},
	} {
		if got := MergeGateMissing(c.script, c.self, c.base); got != c.want {
			t.Errorf("%s: %q, want %q", c.name, got, c.want)
		}
	}
}
