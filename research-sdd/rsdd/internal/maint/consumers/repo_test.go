package consumers

import (
	"os"
	"strings"
	"testing"
)

func TestRepoThatIsNotADirectoryIsAbsentInput(t *testing.T) {
	root := tempRoot(t)
	env := envFor(t, root, gitDir(t)+":/usr/bin:/bin")
	if err := os.WriteFile(root+"/afile", []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	cases := []struct{ name, arg, shown string }{
		{"missing, relative", "missing", root + "/missing"},
		{"missing, with dots", "../missing", filepathDir(root) + "/missing"},
		{"missing, absolute", root + "/nowhere/deeper", root + "/nowhere/deeper"},
		{"a regular file", "afile", root + "/afile"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			want := ran{"", "consumers: absent-input: --repo " + c.shown + " is not a directory (missing, a file, or unreachable)\n", 1}
			if got := runIn(root, env, "--repo", c.arg); got != want {
				t.Fatalf("got %+v\nwant %+v", got, want)
			}
		})
	}
}

func TestRepoSelectorsInTheEnvironmentDoNotOverrideRepo(t *testing.T) {
	first := newFixture(t)
	first.files(map[string]string{"research-sdd/toolbelt/a.sh": "x"})
	first.commit()
	second := newFixture(t)
	second.files(map[string]string{"research-sdd/toolbelt/b.sh": "x", "research-sdd/toolbelt/c.sh": "x", "research-sdd/templates/d.py": "x"})
	second.commit()
	env := append(append([]string(nil), first.env...), "GIT_DIR="+second.dir+"/.git", "GIT_WORK_TREE="+second.dir,
		"GIT_INDEX_FILE="+second.dir+"/.git/index", "GIT_COMMON_DIR="+second.dir+"/.git")
	got := runIn(first.root, env, "--repo", first.dir)
	if got.rc != 0 || got.err != "" {
		t.Fatalf("%+v", got)
	}
	for k, v := range map[string]string{"consumers: ": "consumers: repository " + first.dir, "files: ": "files: 1 listed (tracked, and untracked but not ignored)", "scripts: ": "scripts: 1 (sh 1)"} {
		if l := line(got.out, k); l != v {
			t.Fatalf("%q, want %q", l, v)
		}
	}
}

func filepathDir(p string) string { return p[:strings.LastIndexByte(p, '/')] }
