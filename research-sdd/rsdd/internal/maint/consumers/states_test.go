package consumers

import (
	"os"
	"strings"
	"testing"
)

func TestDegradedWithoutGit(t *testing.T) {
	root := tempRoot(t)
	got := runIn(root, envFor(t, root, root+"/nowhere"))
	want := ran{"consumers: degraded\n", "DEGRADED: git is not installed; nothing was counted\n", 3}
	if got != want {
		t.Fatalf("got %+v, want %+v", got, want)
	}
}

func TestDegradedOutsideAWorkTree(t *testing.T) {
	root := tempRoot(t)
	plain := root + "/plain"
	if err := os.MkdirAll(plain, 0o755); err != nil {
		t.Fatal(err)
	}
	env := envFor(t, root, gitDir(t)+":/usr/bin:/bin")
	want := ran{"consumers: degraded\n", "DEGRADED: " + plain + " is not inside a git work tree; nothing was counted\n", 3}
	if got := runIn(plain, env); got != want {
		t.Fatalf("cwd outside a work tree: got %+v, want %+v", got, want)
	}
	want.err = "DEGRADED: " + root + "/missing is not inside a git work tree; nothing was counted\n"
	if got := runIn(plain, env, "--repo", "../missing"); got != want {
		t.Fatalf("--repo that does not exist: got %+v, want %+v", got, want)
	}
}

func TestAbsentInput(t *testing.T) {
	f := newFixture(t)
	f.files(map[string]string{"README": "x\n", "research-sdd/rsdd/a.sh": "x\n", "other/run.sh": "x\n"})
	f.commit()
	got := f.run()
	want := ran{"", "consumers: absent-input: no file under research-sdd/toolbelt/, research-sdd/templates/ or research-sdd/install/ in " + f.dir + "\n", 1}
	if got != want {
		t.Fatalf("got %+v, want %+v", got, want)
	}
}

func TestAbsentInputInAnEmptyRepository(t *testing.T) {
	f := newFixture(t)
	if got := f.run(); got.rc != 1 || !strings.HasPrefix(got.err, "consumers: absent-input: ") || got.out != "" {
		t.Fatalf("got %+v", got)
	}
}

func TestEmptyInput(t *testing.T) {
	const tail = " files under research-sdd/toolbelt/, research-sdd/templates/ and research-sdd/install/, none is a live script " +
		"(excluded from the script list: `.test.` in the name %d, `fixtures` directory %d, `node_modules` %d)\n"
	cases := []struct {
		name  string
		files map[string]string
		want  string
	}{
		{"files with no script extension", map[string]string{"research-sdd/toolbelt/a.md": "x", "research-sdd/templates/b.txt": "x"},
			"consumers: empty-input: 2" + sprintf(tail, 0, 0, 0)},
		{"scripts that are all excluded", map[string]string{"research-sdd/toolbelt/a.test.sh": "x", "research-sdd/toolbelt/fixtures/b.sh": "x", "research-sdd/install/node_modules/c.js": "x"},
			"consumers: empty-input: 3" + sprintf(tail, 1, 1, 1)},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			f := newFixture(t)
			f.files(c.files)
			f.commit()
			if got, want := f.run(), (ran{"", c.want, 1}); got != want {
				t.Fatalf("got %+v, want %+v", got, want)
			}
		})
	}
}
