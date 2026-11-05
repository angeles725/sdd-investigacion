package cleancheck

import "os"

// scanScenarios are the untracked-file and keep-list cases (a).
func scanScenarios() []scenario {
	return []scenario{
		{name: "clean-with-empty-keeplist", build: func(w *world) { keep(w, "# nothing kept\n") }, args: std(), want: 0},
		{name: "absent-keeplist", args: std(), want: 0},
		{name: "untracked-ignored-and-directory", build: func(w *world) {
			w.write(".gitignore", "ignored.log\n")
			w.git("add", ".gitignore")
			w.write("ignored.log", "x")
			w.write("stray.json", "x")
			w.write("dir/sub/deep.txt", "x")
			w.write("dir/other.txt", "x")
		}, args: std(), want: 1},
		{name: "keeplist-globs-reasons-comments", build: func(w *world) {
			keep(w, "# a comment\n\nkeep/ # a tree\none.txt # one file\n  indented.txt  \nnotes/*.md\r\nq?.dat\n*.log\n")
			for _, f := range []string{"keep/sub/f", "one.txt", "indented.txt", "notes/a.md", "notes/deep/b.md", "q1.dat", "q10.dat", "a/b/c.log", "stray.json", "keepx/f"} {
				w.write(f, "x")
			}
		}, args: std(), want: 1},
		{name: "keeplist-is-a-directory", build: func(w *world) { w.mkdir(w.repo + "/.research-sdd/keep.txt") }, args: std(), want: 2},
		{name: "keeplist-last-line-without-newline", build: func(w *world) {
			keep(w, "one.txt")
			w.write("one.txt", "x")
			w.write("two.txt", "x")
		}, args: std(), want: 1},
		{name: "keeplist-star-crosses-slash-hash-in-name", build: func(w *world) {
			keep(w, "a/*/z\nname#hash.txt\n")
			w.write("a/b/c/z", "x")
			w.write("name#hash.txt", "x")
			w.write("name", "x")
		}, args: std(), want: 1},
		{name: "target-is-a-subdirectory", build: func(w *world) {
			w.write("sub/tracked.txt", "t")
			w.git("add", "sub/tracked.txt")
			w.commit("sub")
			w.write("sub/.research-sdd/keep.txt", "kept.txt\n")
			w.write("sub/kept.txt", "x")
			w.write("sub/stray.txt", "x")
			w.write("outside.txt", "x")
		}, args: func(w *world) []string { return []string{"--target", w.repo + "/sub", "--tmp", w.tmp} }, want: 1},
		{name: "target-relative-and-dotdot", build: func(w *world) { w.write("stray.txt", "x") },
			args: func(w *world) []string { return []string{"--target", "repo/../repo", "--tmp", "tmp"} }, want: 1},
		{name: "target-through-a-symlink", build: func(w *world) {
			w.write("stray.txt", "x")
			if err := os.Symlink(w.repo, w.root+"/link"); err != nil {
				w.t.Fatal(err)
			}
		}, args: func(w *world) []string { return []string{"--target", w.root + "/link", "--tmp", w.tmp} }, want: 1},
		{name: "untracked-with-newline-and-space-names", build: func(w *world) {
			w.write("a b.txt", "x")
			w.write("line\nbreak.txt", "x")
		}, args: std(), want: 1},
		{name: "findings-and-warnings-together", build: func(w *world) {
			w.write("stray.txt", "x")
			w.git("branch", "merged-one")
		}, args: std(), want: 1},
	}
}
