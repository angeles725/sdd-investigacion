package cleancheck

import (
	"errors"
	"io/fs"
	"os"
	"reflect"
	"syscall"
	"testing"
	"time"
)

func TestParseKeep(t *testing.T) {
	src := "# comment\n\n  # indented comment\nkeep/ # a tree\n\tone.txt\t\n a #b # c\r\nname#hash\n x \\ # reason\nlast-no-newline"
	want := []string{"keep/", "one.txt", "a", "name#hash", "x \\", "last-no-newline"}
	if got := parseKeep(src); !reflect.DeepEqual(got, want) {
		t.Errorf("parseKeep = %q, want %q", got, want)
	}
	if got := parseKeep("a\x00b\n"); !reflect.DeepEqual(got, []string{"ab"}) {
		t.Errorf("NUL bytes must vanish as in a shell read: %q", got)
	}
	if got := parseKeep(" #only a reason\n #\n"); got != nil {
		t.Errorf("%q", got)
	}
	if got := parseKeep("\r\n \r\n"); got != nil {
		t.Errorf("blank CR lines are not entries: %q", got)
	}
}

func TestKept(t *testing.T) {
	k := keepList{globs: []string{"keep/", "one.txt", "notes/*.md"}}
	for rel, want := range map[string]bool{
		".research-sdd/keep.txt": true, "keep/sub/f": true, "keep/": true, "keepx/f": false, "keep": false,
		"one.txt": true, "one.txt2": false, "notes/a.md": true, "notes/d/b.md": true, "notes/a.txt": false, "stray": false,
	} {
		if got := k.kept(rel); got != want {
			t.Errorf("kept(%q) = %v, want %v", rel, got, want)
		}
	}
	if (keepList{}).kept("x") {
		t.Error("an empty keep-list keeps nothing")
	}
}

func TestMentions(t *testing.T) {
	for _, c := range []struct {
		name, body string
		want       bool
	}{
		{"run.sh", "run.sh", true}, {"run.sh", "see run.sh.", true}, {"run.sh", "see run.sh. Next", true}, {"run.sh", "run.sh.x", false},
		{"run.sh", "prerun.sh", false}, {"run.sh", "run.shx", false}, {"out", "the layout", false}, {"out", "out of", true},
		{"a", "x/a", true}, {"a", "a/x", false}, {"a", "(a)", true}, {"a", "`a`", true}, {"a", "\"a\"", true}, {"a", "'a'", true},
		{"a", "|a|", true}, {"a", "<a>", true}, {"a", "[a]", true}, {"a", "a,b", true}, {"a", "a:b", true}, {"a", "a;b", true},
		{"a", "a!", true}, {"a", "a?", true}, {"a", "-a", false}, {"a", "a-", false}, {"a", "a_", false}, {"a", "_a", false}, {"a", "=a", false},
		{"a", "a\tb", true}, {"a", "\ta", true}, {"a", "a\rb", true}, {"a", "a\vb", true}, {"a", "a\fb", true},
		{"a.b", "aXb a.b", true}, {"a.b", "aXb", false},
		{"a", "xa a", true}, {"a", "ax ax a", true}, {"x.sh", "first\nsecond x.sh\n", true}, {"x.sh", "x.\nsh", false},
		{"a", "a.", true}, {"a", "a. ", true}, {"a", "a.b", false}, {"a", "a.\t", true}, {"a", "a.\n", true}, {"a", "a..", false},
		{"x y", "a x y b", true}, {"a", "", false}, {"a", "\n\n", false},
	} {
		if got := mentions(c.name, []byte(c.body)); got != c.want {
			t.Errorf("mentions(%q, %q) = %v, want %v", c.name, c.body, got, c.want)
		}
	}
}

func TestGitEnvironment(t *testing.T) {
	in := []string{"A=1", "GIT_DIR=/x", "B=2", "GIT_WORK_TREE=/y", "GIT_COMMON_DIR=/z", "GIT_INDEX_FILE=/i", "A=3", "GIT_AUTHOR_NAME=n", "noequals", "C="}
	want := []string{"B=2", "A=3", "GIT_AUTHOR_NAME=n", "noequals", "C="}
	if got := gitEnvironment(in); !reflect.DeepEqual(got, want) {
		t.Errorf("gitEnvironment = %q, want %q", got, want)
	}
	if got := gitEnvironment(nil); got != nil {
		t.Errorf("%q", got)
	}
}

func TestEnvValue(t *testing.T) {
	env := []string{"A=1", "A=2", "B=", "C=x=y"}
	for key, want := range map[string]string{"A": "2", "B": "", "C": "x=y", "D": ""} {
		got, _ := envValue(env, key)
		if got != want {
			t.Errorf("envValue(%q) = %q, want %q", key, got, want)
		}
	}
	if _, set := envValue(env, "B"); !set {
		t.Error("an empty value is set")
	}
	if _, set := envValue(env, "D"); set {
		t.Error("a missing name is not set")
	}
}

func TestNulFields(t *testing.T) {
	for in, want := range map[string][]string{"": nil, "a\x00": {"a"}, "a\x00b\x00": {"a", "b"}, "a\x00\x00": {"a", ""}, "a": {"a"}} {
		if got := nulFields(in); !reflect.DeepEqual(got, want) {
			t.Errorf("nulFields(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestOlderThan(t *testing.T) {
	now := time.Unix(1_000_000, 0)
	for _, c := range []struct {
		age   time.Duration
		limit int64
		want  bool
	}{
		{0, 0, false}, {time.Nanosecond, 0, true}, {3 * time.Second, 0, true}, {time.Minute, 1, false}, {time.Minute + time.Nanosecond, 1, true},
		{61 * time.Second, 1, true}, {59 * time.Second, 1, false}, {24 * time.Hour, 1440, false}, {24*time.Hour + time.Second, 1440, true},
		{3659 * time.Second, 60, true}, {3600 * time.Second, 60, false}, {-time.Hour, 0, false},
	} {
		if got := olderThan(now, now.Add(-c.age), c.limit); got != c.want {
			t.Errorf("olderThan(age %v, +%d) = %v, want %v", c.age, c.limit, got, c.want)
		}
	}
}

func TestFindErrorText(t *testing.T) {
	for _, c := range []struct {
		err    error
		denied bool
		line   string
	}{
		{&fs.PathError{Op: "open", Path: "/p", Err: syscall.EACCES}, true, "find: '/p': Permission denied"},
		{&fs.PathError{Op: "open", Path: "/p", Err: syscall.ENOTDIR}, false, "find: '/p': Not a directory"},
		{&fs.PathError{Op: "open", Path: "/p", Err: syscall.EIO}, false, "find: '/p': Input/output error"},
		{errors.New("boom"), false, "find: '/p': Boom"},
	} {
		e := newFindError("/p", c.err)
		if e.denied != c.denied || e.line() != c.line {
			t.Errorf("%v: %+v %q, want denied=%v %q", c.err, e, e.line(), c.denied, c.line)
		}
	}
	if capitalize("") != "" || capitalize("x") != "X" {
		t.Error("capitalize")
	}
	if !vanished(&fs.PathError{Err: syscall.ENOENT}) || vanished(syscall.EACCES) {
		t.Error("vanished is ENOENT only")
	}
}

func TestJoinAndFold(t *testing.T) {
	if join("/", "a") != "/a" || join("/x", "a") != "/x/a" || join("", "a") != "/a" && join("", "a") != "a" {
		t.Error("join")
	}
	if asciiFold("ABCxyz-K") != "abcxyz-K" {
		t.Errorf("asciiFold folds ASCII only: %q", asciiFold("ABCxyz-K"))
	}
	if oneLine("a\nb\n") != "a b " || oneLine("x") != "x" {
		t.Error("oneLine")
	}
}

func TestScriptExtensions(t *testing.T) {
	for name, want := range map[string]bool{
		"a.sh": true, "a.ps1": true, "a.py": true, "a.java": true, "a.js": true, "a.rb": true, "a.pl": true, "a.bat": true, "a.cmd": true,
		"a.groovy": true, "a.kts": true, "a.SH": false, "a.txt": false, "sh": false, "a.shx": false, ".sh": true, "a.sh.txt": false, "a.kt": false,
	} {
		if isScript(name) != want {
			t.Errorf("isScript(%q) = %v", name, !want)
		}
	}
}

func TestSplitRefAndTwin(t *testing.T) {
	for _, c := range []struct {
		ref, name, bare, kind string
		ok                    bool
	}{
		{"refs/heads/x", "x", "x", localBranch, true}, {"refs/heads/a/b", "a/b", "a/b", localBranch, true},
		{"refs/remotes/origin/x", "origin/x", "x", remoteBranch, true}, {"refs/remotes/origin/a/b", "origin/a/b", "a/b", remoteBranch, true},
		{"refs/remotes/origin/HEAD", "origin/HEAD", "HEAD", remoteBranch, false}, {"refs/remotes/origin", "origin", "origin", remoteBranch, true},
		{"refs/heads/HEAD", "HEAD", "HEAD", localBranch, true}, {"refs/tags/v1", "", "", "", false}, {"main", "", "", "", false},
	} {
		name, bare, kind, ok := splitRef(c.ref)
		if name != c.name || bare != c.bare || kind != c.kind || ok != c.ok {
			t.Errorf("splitRef(%q) = %q %q %q %v", c.ref, name, bare, kind, ok)
		}
	}
	for full, want := range map[string]string{"refs/heads/main": "main", "refs/heads/a/b": "a/b", "refs/remotes/origin/main": "main", "refs/remotes/o/a/b": "a/b", "refs/tags/v1": "", "": ""} {
		if got := (baseRef{full: full}).twinName(); got != want {
			t.Errorf("twinName(%q) = %q, want %q", full, got, want)
		}
	}
	if (baseRef{}).found() || !(baseRef{commit: "c"}).found() {
		t.Error("found")
	}
}

func TestUnderEvidence(t *testing.T) {
	for rel, want := range map[string]bool{"_evidence": true, "_evidence/x": true, "a/_evidence/x": true, "a/_evidence": true, "x_evidence/y": false, "_evidencex": false, "a/b": false, "": false} {
		if underEvidence(rel) != want {
			t.Errorf("underEvidence(%q) = %v", rel, !want)
		}
	}
}

func TestResultViews(t *testing.T) {
	r := Result{Lines: []Line{{Out, "a"}, {Err, "b"}, {Out, "c\nd"}}}
	if r.Stdout() != "a\nc\nd\n" || r.Stderr() != "b\n" || r.Merged() != "a\nb\nc\nd\n" {
		t.Errorf("%q %q %q", r.Stdout(), r.Stderr(), r.Merged())
	}
	if (Result{}).Merged() != "" {
		t.Error("an empty result prints nothing")
	}
}

func TestWalkTree(t *testing.T) {
	w := newWorld(t)
	for _, f := range []string{"a/1", "a/b/2", "a/b/c/3", "z"} {
		w.writeAt(w.root+"/walk/"+f, "x")
	}
	if err := os.Symlink(w.root+"/walk/a", w.root+"/walk/link"); err != nil {
		t.Fatal(err)
	}
	var seen []string
	depths := map[string]int{}
	errs := walkTree(w.root+"/walk", -1, func(p string, d int, e entry) bool {
		seen = append(seen, p[len(w.root+"/walk/"):])
		depths[seen[len(seen)-1]] = d
		return true
	})
	want := []string{"a", "a/1", "a/b", "a/b/2", "a/b/c", "a/b/c/3", "link", "z"}
	if len(errs) != 0 || !reflect.DeepEqual(seen, want) {
		t.Fatalf("%v %v", seen, errs)
	}
	if depths["a"] != 1 || depths["a/b/c/3"] == 0 || depths["a/b/c/3"] != 4 || depths["z"] != 1 {
		t.Errorf("depths %v", depths)
	}
	seen = nil
	walkTree(w.root+"/walk", 2, func(p string, d int, e entry) bool { seen = append(seen, p[len(w.root+"/walk/"):]); return true })
	if !reflect.DeepEqual(seen, []string{"a", "a/1", "a/b", "link", "z"}) {
		t.Errorf("maxDepth 2: %v", seen)
	}
	seen = nil
	walkTree(w.root+"/walk", -1, func(p string, d int, e entry) bool {
		seen = append(seen, p[len(w.root+"/walk/"):])
		return p[len(p)-1] != 'b'
	})
	if !reflect.DeepEqual(seen, []string{"a", "a/1", "a/b", "link", "z"}) {
		t.Errorf("a declined directory is not read: %v", seen)
	}
	errs = walkTree(w.root+"/missing", -1, func(string, int, entry) bool { return true })
	if len(errs) != 0 {
		t.Errorf("a root that vanished is benign: %v", errs)
	}
	errs = walkTree(w.root+"/walk/z", -1, func(string, int, entry) bool { return true })
	if len(errs) != 1 || errs[0].denied || errs[0].line() != "find: '"+w.root+"/walk/z': Not a directory" {
		t.Errorf("a file as root is an error: %v", errs)
	}
	if got := findStderr(errs); len(got) != 1 || got[0] != errs[0].line() {
		t.Errorf("%v", got)
	}
	if findStderr(nil) == nil || len(findStderr(nil)) != 0 {
		t.Errorf("findStderr(nil) = %v", findStderr(nil))
	}
}
