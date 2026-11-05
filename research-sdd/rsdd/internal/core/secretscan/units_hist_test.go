package secretscan

import (
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestValidHeaderBoundaries(t *testing.T) {
	t.Parallel()
	h := func(n int) string { return strings.Repeat("a", n) }
	hdr := func(m1, m2, s1, s2, st string) string { return ":" + m1 + " " + m2 + " " + s1 + " " + s2 + " " + st }
	good := hdr("000000", "100644", h(40), h(40), "A")
	for _, tc := range []struct {
		name, rec string
		want      bool
	}{
		{"good", good, true},
		{"sha 39", hdr("000000", "100644", h(39), h(40), "A"), false},
		{"sha 64", hdr("000000", "100644", h(64), h(64), "A"), true},
		{"sha 65", hdr("000000", "100644", h(40), h(65), "A"), false},
		{"first sha 65", hdr("000000", "100644", h(65), h(40), "A"), false},
		{"upper hex", hdr("000000", "100644", strings.ToUpper(h(40)), h(40), "A"), false},
		{"non hex g", hdr("000000", "100644", h(39)+"g", h(40), "A"), false},
		{"mode 5 digits", hdr("00000", "100644", h(40), h(40), "A"), false},
		{"mode 7 digits", hdr("000000", "1006440", h(40), h(40), "A"), false},
		{"mode digit 8", hdr("000000", "100648", h(40), h(40), "A"), false},
		{"old mode digit 8", hdr("000008", "100644", h(40), h(40), "A"), false},
		{"mode lowest 0", hdr("000000", "000000", h(40), h(40), "D"), true},
		{"status M", hdr("100644", "100644", h(40), h(40), "M"), true},
		{"status with digits", hdr("100644", "100644", h(40), h(40), "R100"), true},
		{"status lower", hdr("100644", "100644", h(40), h(40), "a"), false},
		{"status digit first", hdr("100644", "100644", h(40), h(40), "1"), false},
		{"status letter after digit", hdr("100644", "100644", h(40), h(40), "A1B"), false},
		{"status empty", hdr("100644", "100644", h(40), h(40), ""), false},
		{"four fields", ":000000 100644 " + h(40) + " " + h(40), false},
		{"six fields", good + " extra", false},
		{"tab", strings.Replace(good, " ", "\t", 1), false},
		{"double space", strings.Replace(good, " ", "  ", 1), false},
		{"trailing space", good + " ", false},
		{"leading space", " " + good, false},
	} {
		if _, ok := validHeader(tc.rec); ok != tc.want {
			t.Errorf("%s: validHeader(%q) = %v, want %v", tc.name, tc.rec, ok, tc.want)
		}
	}
	if f, ok := validHeader(good); !ok || f[3] != h(40) || f[1] != "100644" {
		t.Errorf("fields = %v", f)
	}
}

func TestShapeHelpers(t *testing.T) {
	t.Parallel()
	for s, want := range map[string]bool{"000000": true, "777777": true, "100644": true, "888888": false, "10064": false, "": false, "10064a": false} {
		if isMode(s) != want {
			t.Errorf("isMode(%q) != %v", s, want)
		}
	}
	for s, want := range map[string]bool{"A": true, "Z": true, "R99": true, "@": false, "[": false, "A9": true, "A:": false, "": false} {
		if isStatus(s) != want {
			t.Errorf("isStatus(%q) != %v", s, want)
		}
	}
	if !isSha(strings.Repeat("f", 40)) || isSha(strings.Repeat("f", 39)) || !isSha(strings.Repeat("0", 64)) || isSha(strings.Repeat("0", 65)) {
		t.Error("isSha length bounds")
	}
	if isSha(strings.Repeat("`", 40)) || isSha(strings.Repeat("g", 40)) || isSha(strings.Repeat("/", 40)) || isSha(strings.Repeat(":", 40)) {
		t.Error("isSha accepts a byte just outside 0-9a-f")
	}
}

// fakeProc is a canned Git command.
type fakeProc struct {
	out string
	rc  int
}

func (p fakeProc) Stdout() io.Reader { return strings.NewReader(p.out) }
func (p fakeProc) Wait() int         { return p.rc }

// fakeGit answers rev-list and diff-tree with canned output.
type fakeGit struct{ revs, tree fakeProc }

func (g fakeGit) Start(_ string, _ io.Reader, args ...string) (Proc, error) {
	for _, a := range args {
		switch a {
		case "rev-list":
			return g.revs, nil
		case "diff-tree":
			return g.tree, nil
		}
	}
	return nil, io.ErrUnexpectedEOF
}

func TestEnumerateFailsClosed(t *testing.T) {
	t.Parallel()
	sha := strings.Repeat("b", 40)
	hdr := ":000000 100644 " + strings.Repeat("0", 40) + " " + sha + " A\x00"
	run := func(tree string) enumResult {
		s := &session{git: fakeGit{revs: fakeProc{out: "c1\n"}, tree: fakeProc{out: tree}}}
		return s.enumerate()
	}
	if r := run(hdr + "notes.md\x00"); r.Fail != "" || r.Blobs[sha] != "notes.md" || r.Records != 2 {
		t.Errorf("well-formed: %+v", r)
	}
	if r := run(hdr + "notes.md\x00" + ":bad header\x00x.md\x00"); !strings.HasPrefix(r.Fail, "DEGRADED: malformed diff-tree header: ") {
		t.Errorf("malformed header must fail closed: %+v", r)
	}
	if r := run("stray record\x00"); !strings.HasPrefix(r.Fail, "DEGRADED: unexpected non-header record") {
		t.Errorf("a non-header record must fail closed: %+v", r)
	}
	// after a failure the stream is drained, so the count still reflects everything produced
	if r := run(":bad\x00a\x00b\x00"); r.Records != 3 || r.Fail == "" {
		t.Errorf("drain: %+v", r)
	}
	// a gitlink (mode 160000) and a deleted blob are skipped, an out-of-scope path is not listed
	gl := ":000000 160000 " + strings.Repeat("0", 40) + " " + sha + " A\x00sub.md\x00"
	del := ":100644 000000 " + sha + " " + strings.Repeat("0", 40) + " D\x00gone.md\x00"
	if r := run(gl + del); len(r.Blobs) != 0 || r.Fail != "" {
		t.Errorf("gitlink/deleted must be skipped: %+v", r)
	}
	if r := run(hdr + "dir/z.md\x00" + hdr + "a/b.md\x00" + hdr + "a/a.md\x00"); r.Blobs[sha] != "a/a.md" {
		t.Errorf("the smallest in-scope path names the blob: %+v", r.Blobs)
	}
	// exit codes of both commands are carried through
	s := &session{git: fakeGit{revs: fakeProc{out: "", rc: 128}, tree: fakeProc{out: "", rc: 1}}}
	if r := s.enumerate(); r.RC != [2]int{128, 1} || r.Records != 0 {
		t.Errorf("rc: %+v", r)
	}
}

// TestCommittedScanNeedsOnlyGit runs a history scan with a PATH that holds nothing but git and a TMPDIR that does
// not exist: the engine needs no grep, awk, tr, sort or mktemp (the legacy script needed all five).
func TestCommittedScanNeedsOnlyGit(t *testing.T) {
	gitBin, err := exec.LookPath("git")
	if err != nil {
		t.Skip("git not installed")
	}
	w := newWorld(t, scase{name: "git-only", mode: "committed", build: func(w *world) {
		w.initRepo()
		w.write("notes-block1.md", "# Block 1\n\nLeaked: "+fakeAWS+"\n")
		w.commit("add")
	}})
	only := filepath.Join(w.scratch, "only-git")
	if err := os.MkdirAll(only, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(gitBin, filepath.Join(only, "git")); err != nil {
		t.Fatal(err)
	}
	env := append([]string{}, w.env...)
	env = append(env, "PATH="+only, "TMPDIR="+filepath.Join(w.scratch, "does-not-exist"))
	w.env = env
	got := w.runGo(t)
	if got.exit != 1 || !strings.Contains(got.stdout, "AWS") && !strings.Contains(got.stdout, "notes-block1.md") {
		t.Errorf("a leak in history must be found with git alone: exit %d\nstdout:\n%s\nstderr:\n%s", got.exit, got.stdout, got.stderr)
	}
	if strings.Contains(got.stderr, "DEGRADED") {
		t.Errorf("no degraded state expected: %s", got.stderr)
	}
}
