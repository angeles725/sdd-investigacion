package parity

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestJudgeTable(t *testing.T) {
	base := Observed{Stdout: []byte("o"), Stderr: []byte("e"), Exit: 0}
	with := func(f func(*Observed)) Observed {
		o := base
		f(&o)
		return o
	}
	decl := func(fields ...string) []Intended {
		var out []Intended
		for _, f := range fields {
			out = append(out, Intended{Field: f, Reason: "r"})
		}
		return out
	}
	tests := []struct {
		name     string
		other    Observed
		declared []Intended
		status   Status
		kinds    []string
	}{
		{"identical", base, nil, StatusEqual, nil},
		{"stdout declared", with(func(o *Observed) { o.Stdout = []byte("x") }), decl("stdout"), StatusDeclared, nil},
		{"stderr declared", with(func(o *Observed) { o.Stderr = []byte("x") }), decl("stderr"), StatusDeclared, nil},
		{"exit declared", with(func(o *Observed) { o.Exit = 9 }), decl("exit"), StatusDeclared, nil},
		{"all three declared", Observed{Stdout: []byte("a"), Stderr: []byte("b"), Exit: 1}, decl("stdout", "stderr", "exit"), StatusDeclared, nil},
		{"stderr undeclared", with(func(o *Observed) { o.Stderr = []byte("x") }), decl("stdout"), StatusFailed, []string{KindStale, KindUndeclared}},
		{"exit undeclared", with(func(o *Observed) { o.Exit = 9 }), nil, StatusFailed, []string{KindUndeclared}},
		{"stale stdout", base, decl("stdout"), StatusFailed, []string{KindStale}},
		{"stale exit", base, decl("exit"), StatusFailed, []string{KindStale}},
		{"empty vs missing stdout", with(func(o *Observed) { o.Stdout = nil }), nil, StatusFailed, []string{KindUndeclared}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			st, probs := Judge(base, tt.other, tt.declared)
			if st != tt.status || len(probs) != len(tt.kinds) {
				t.Fatalf("got %s %v, want %s %v", st, probs, tt.status, tt.kinds)
			}
			for i, k := range tt.kinds {
				if probs[i].Kind != k {
					t.Errorf("problem %d: kind %s, want %s", i, probs[i].Kind, k)
				}
			}
		})
	}
}

func TestDiffBytesEdges(t *testing.T) {
	tests := []struct {
		name, a, b string
		want       []string
	}{
		{"equal", "same", "same", nil},
		{"both empty", "", "", nil},
		{"legacy is a prefix", "abc", "abcdef", []string{"offset 3 (line 1)", "legacy 3 bytes, rsdd 6 bytes", "ends before this offset"}},
		{"rsdd is a prefix", "abcdef", "abc", []string{"offset 3", "legacy 6 bytes, rsdd 3 bytes", "ends before this offset"}},
		{"empty vs text", "", "x", []string{"offset 0 (line 1)", "legacy 0 bytes, rsdd 1 bytes"}},
		{"first byte", "Xbc", "Ybc", []string{"offset 0 (line 1)"}},
		{"last byte", "abX", "abY", []string{"offset 2 (line 1)"}},
		{"newline counts", "l1\nl2\nXY", "l1\nl2\nXZ", []string{"offset 7 (line 3)"}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := diffBytes("stdout", []byte(tt.a), []byte(tt.b))
			if tt.want == nil {
				if got != "" {
					t.Fatalf("equal input must give an empty diff, got %q", got)
				}
				return
			}
			for _, w := range tt.want {
				if !strings.Contains(got, w) {
					t.Errorf("diff lacks %q:\n%s", w, got)
				}
			}
		})
	}
}

func TestExcerptWindow(t *testing.T) {
	long := []byte(strings.Repeat("0123456789", 20)) // 200 bytes
	got := excerpt(long, 100)
	if !strings.HasPrefix(got, `..."`) || !strings.HasSuffix(got, `"...`) {
		t.Fatalf("a mid-stream excerpt is cut on both sides: %s", got)
	}
	if n := strings.Count(got, "0123456789"); n > 6 {
		t.Fatalf("excerpt is not bounded: %s", got)
	}
	if got := excerpt([]byte("short"), 0); got != `"short"` {
		t.Fatalf("a short stream is shown whole without ellipses, got %s", got)
	}
	if got := excerpt([]byte("short"), 5); !strings.Contains(got, "ends before this offset") {
		t.Fatalf("offset at len must say the stream ended: %s", got)
	}
	if got := excerpt(nil, 3); !strings.Contains(got, "ends before this offset") {
		t.Fatalf("offset beyond the end must not panic and must say so: %s", got)
	}
}

func TestCapBuf(t *testing.T) {
	c := &capBuf{max: 5}
	if n, _ := c.Write([]byte("abc")); n != 3 || c.truncated {
		t.Fatalf("under the cap: n=%d truncated=%v", n, c.truncated)
	}
	if n, _ := c.Write([]byte("de")); n != 2 || c.truncated || c.buf.String() != "abcde" {
		t.Fatalf("exactly at the cap is not truncation: n=%d truncated=%v %q", n, c.truncated, c.buf.String())
	}
	if n, _ := c.Write([]byte("fgh")); n != 3 || !c.truncated || c.buf.String() != "abcde" {
		t.Fatalf("overflow keeps the prefix, reports full length, flags truncation: n=%d %v %q", n, c.truncated, c.buf.String())
	}
	d := &capBuf{max: 4}
	d.Write([]byte("abcdef"))
	if d.buf.String() != "abcd" || !d.truncated {
		t.Fatalf("a single oversized write keeps exactly max bytes: %q", d.buf.String())
	}
}

func TestCopyTree(t *testing.T) {
	src := filepath.Join(t.TempDir(), "in")
	if err := os.MkdirAll(filepath.Join(src, "a", "b"), 0o755); err != nil {
		t.Fatal(err)
	}
	os.WriteFile(filepath.Join(src, "a", "b", "x.sh"), []byte("#!/bin/sh\n"), 0o755)
	os.WriteFile(filepath.Join(src, "plain.txt"), []byte("p"), 0o644)
	os.Symlink("plain.txt", filepath.Join(src, "link"))
	dst := filepath.Join(t.TempDir(), "out")
	if err := copyTree(src, dst); err != nil {
		t.Fatal(err)
	}
	st, err := os.Stat(filepath.Join(dst, "a", "b", "x.sh"))
	if err != nil || st.Mode().Perm() != 0o755 {
		t.Fatalf("exec bit not preserved: %v %v", st, err)
	}
	if b, _ := os.ReadFile(filepath.Join(dst, "plain.txt")); string(b) != "p" {
		t.Fatalf("content lost: %q", b)
	}
	if l, err := os.Readlink(filepath.Join(dst, "link")); err != nil || l != "plain.txt" {
		t.Fatalf("symlink not preserved: %q %v", l, err)
	}
	if err := copyTree(filepath.Join(src, "missing"), dst); err == nil {
		t.Fatal("an absent source must be an error")
	}
}

func TestFingerprintDiffCapBoundary(t *testing.T) {
	mk := func(n int) []string {
		b := Tree{}
		for i := range n {
			b[filepath.Join("f", string(rune('a'+i)))] = "x"
		}
		return Tree{}.Diff(b)
	}
	if d := mk(maxDiffLines); len(d) != maxDiffLines || strings.Contains(d[len(d)-1], "more") {
		t.Fatalf("exactly the cap is shown whole: %v", d)
	}
	d := mk(maxDiffLines + 1)
	if len(d) != maxDiffLines+1 || d[len(d)-1] != "... and 1 more" {
		t.Fatalf("one over the cap says so: %v", d)
	}
}

func TestLoadCasesSortedAndStrict(t *testing.T) {
	r := newRig(t)
	r.addCase("b-second", []string{"out=1"}, []string{"out=1"}, false, map[string]string{})
	r.addCase("a-first", []string{"out=1"}, []string{"out=1"}, false, map[string]string{})
	cases := r.load()
	if len(cases) != 2 || cases[0].Name != "a-first" || cases[1].Name != "b-second" {
		t.Fatalf("cases must load sorted by name: %v", cases)
	}
	r.addRaw("c-bad-intended", `{"legacy":["a.sh"],"rsdd":["x"]}`, map[string]string{"intended.json": `{"field":"stdout"}`})
	r.addRaw("d-bad-intended-field", `{"legacy":["a.sh"],"rsdd":["x"]}`, map[string]string{"intended.json": `[{"field":"stdout","reason":"r","extra":1}]`})
	for _, c := range r.load()[2:] {
		if !hasKind(c.Problems, KindSpecInvalid) {
			t.Errorf("%s: an intended.json off golden's schema must be spec-invalid: %v", c.Name, c.Problems)
		}
	}
}

func TestResultDescribe(t *testing.T) {
	res := Result{Case: "k", Corpus: "/c", Status: StatusFailed, Note: "n", Problems: []Problem{{KindTimeout, "line1\nline2"}}}
	got := res.describe()
	for _, w := range []string{"failed: k", "[corpus /c]", "(n)", "timeout: line1", "\n  line2"} {
		if !strings.Contains(got, w) {
			t.Errorf("describe lacks %q:\n%s", w, got)
		}
	}
}

// The caller's PATH reaches both sides only through ConfigFromEnv (archtest bans
// os.Getenv here); an empty Config.Path falls back to defaultPath.
func TestConfigFromEnvCarriesPath(t *testing.T) {
	env := map[string]string{"PATH": "/opt/x/bin:/usr/bin"}
	cfg, err := ConfigFromEnv(func(k string) string { return env[k] }, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Path != "/opt/x/bin:/usr/bin" {
		t.Fatalf("Path = %q, want the getenv PATH", cfg.Path)
	}
}
