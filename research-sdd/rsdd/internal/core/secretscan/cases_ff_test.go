package secretscan

import "os"

// narrowCases pin the legacy corpus-root narrowing of the default mode (--files-from and --committed never narrow).
func narrowCases() []scase {
	leaks := func(w *world, files ...string) {
		for _, f := range files {
			w.write(f, fakeAWS+"\n")
		}
	}
	return []scase{
		{name: "narrow-block-at-root", build: func(w *world) { w.write("t-block1.md", "# B\n"); leaks(w, "notes.md", "sub/x.md") }, unordered: true},
		{name: "narrow-block-in-sub-outside-unscanned", build: func(w *world) { w.write("sub/t-block1.md", "# B\n"); leaks(w, "notes.md", "sub/in.md") }},
		{name: "narrow-bloque-uppercase", build: func(w *world) { w.write("sub/T-BLOQUE1.MD", "# B\n"); leaks(w, "notes.md") }},
		{name: "narrow-bloque-lowercase", build: func(w *world) { w.write("sub/t-bloque1.md", "# B\n"); leaks(w, "notes.md", "sub/in.md") }},
		{name: "narrow-template-never-anchors", build: func(w *world) { w.write("a-templates/x-block1.template.md", "# B\n"); leaks(w, "notes.md") }},
		{name: "narrow-depth-two", build: func(w *world) { w.write("a/b/t-block1.md", "# B\n"); leaks(w, "notes.md", "a/b/in.md") }},
		{name: "narrow-depth-three", build: func(w *world) { w.write("a/b/c/t-block1.md", "# B\n"); leaks(w, "notes.md", "a/b/c/in.md") }},
		{name: "narrow-depth-four-too-deep", build: func(w *world) { w.write("a/b/c/d/t-block1.md", "# B\n"); leaks(w, "notes.md", "a/b/c/d/in.md") }, unordered: true},
		{name: "narrow-shallowest-wins", build: func(w *world) {
			w.write("a/b/t-block1.md", "# B\n")
			w.write("z/t-block1.md", "# B\n")
			leaks(w, "z/in.md", "a/b/in.md")
		}},
		{name: "narrow-tie-lexical", build: func(w *world) {
			w.write("m/t-block1.md", "# B\n")
			w.write("b/t-block1.md", "# B\n")
			leaks(w, "m/in.md", "b/in.md")
		}},
		{name: "narrow-not-md-ext", build: func(w *world) { w.write("sub/block.txt", "x\n"); leaks(w, "notes.md", "sub/in.md") }, unordered: true},
		{name: "narrow-inside-dotgit-dir-ignored", build: func(w *world) { w.write(".git/t-block1.md", "# B\n"); leaks(w, "notes.md") }},
		{name: "narrow-symlinked-target", target: "link", build: func(w *world) {
			w.write("sub/t-block1.md", "# B\n")
			leaks(w, "notes.md", "sub/in.md")
			if err := os.Symlink(w.corpus, w.scratch+"/link"); err != nil {
				w.t.Fatal(err)
			}
		}, unordered: true},
	}
}

// ffCases are the --files-from cases: first, middle, last and single entries, and every input state.
func ffCases() []scase {
	two := func(w *world) {
		w.write("a.md", fakeAWS+"\n")
		w.write("b.md", "clean\n")
		w.write("c.md", fakeGH+"\n")
	}
	return []scase{
		{name: "ff-first-entry-leaks", mode: "ff", build: two, list: []string{"a.md", "b.md", "c.md"}},
		{name: "ff-middle-only", mode: "ff", build: two, list: []string{"b.md"}},
		{name: "ff-last-only", mode: "ff", build: two, list: []string{"c.md"}},
		{name: "ff-single-clean", mode: "ff", build: two, list: []string{"b.md"}},
		{name: "ff-order-follows-list", mode: "ff", build: two, list: []string{"c.md", "a.md"}},
		{name: "ff-stdin", mode: "ff", build: two, list: []string{"a.md", "b.md"}, stdin: true},
		{name: "ff-stdin-empty", mode: "ff", build: two, stdin: true},
		{name: "ff-no-narrowing", mode: "ff", build: func(w *world) { w.write("sub/t-block1.md", "# B\n"); w.write("notes.md", fakeAWS+"\n") }, list: []string{"notes.md"}},
		{name: "ff-list-absent", mode: "ff", build: two, listFile: "absent"},
		{name: "ff-list-is-directory", mode: "ff", build: two, listFile: "dir"},
		{name: "ff-list-empty", mode: "ff", build: two, rawList: ptr("")},
		{name: "ff-list-only-empty-entries", mode: "ff", build: two, rawList: ptr("\x00\x00")},
		{name: "ff-all-out-of-scope", mode: "ff", build: func(w *world) { w.write("a.txt", fakeAWS+"\n") }, list: []string{"a.txt"}},
		{name: "ff-excluded-dir-entry", mode: "ff", build: func(w *world) { w.write("node_modules/a.md", fakeAWS+"\n") }, list: []string{"node_modules/a.md"}},
		{name: "ff-no-trailing-nul", mode: "ff", build: two, rawList: ptr("{{T}}/a.md\x00{{T}}/b.md")},
		{name: "ff-empty-entries-between", mode: "ff", build: two, rawList: ptr("\x00{{T}}/a.md\x00\x00{{T}}/c.md\x00")},
		{name: "ff-newline-in-name", mode: "ff", build: func(w *world) { w.write("a\nb.md", fakeAWS+"\n") }, list: []string{"a\nb.md"},
			intended: []intended{{"stdout", nlName}}},
		{name: "ff-newline-name-not-split", mode: "ff", build: two, rawList: ptr("{{T}}/a.md\n{{T}}/c.md\x00")},
		{name: "ff-entry-outside-target", mode: "ff", build: two, list: []string{"!/etc/passwd.md"}},
		{name: "ff-entry-relative", mode: "ff", build: two, list: []string{"!a.md"}},
		{name: "ff-entry-dotdot", mode: "ff", build: two, list: []string{"x/../a.md"}},
		{name: "ff-entry-dot", mode: "ff", build: two, list: []string{"./a.md"}},
		{name: "ff-entry-double-slash", mode: "ff", build: two, list: []string{"x//a.md"}},
		{name: "ff-entry-missing", mode: "ff", build: two, list: []string{"gone.md"}},
		{name: "ff-entry-directory", mode: "ff", build: func(w *world) { w.mkdir("corpus/d.md"); w.write("a.md", "x\n") }, list: []string{"d.md", "a.md"}},
		{name: "ff-entry-symlink-skipped", mode: "ff", build: func(w *world) { w.write("real.txt", fakeAWS+"\n"); w.symlink("real.txt", "l.md") }, list: []string{"l.md"}},
		{name: "ff-entry-symlink-dir", mode: "ff", build: func(w *world) {
			w.write("real/a.md", fakeAWS+"\n")
			w.symlink("real", "link")
		}, list: []string{"link/a.md"}},
		{name: "ff-entry-dangling-symlink", mode: "ff", build: func(w *world) { w.symlink("nowhere", "d.md") }, list: []string{"d.md"}},
		{name: "ff-entry-symlink-before-leak", mode: "ff", build: func(w *world) { w.symlink("nowhere", "d.md"); w.write("a.md", fakeAWS+"\n") }, list: []string{"d.md", "a.md"}},
		{name: "ff-entry-unreadable", mode: "ff", skipRoot: true, build: func(w *world) { w.write("a.md", fakeAWS+"\n"); w.chmod("a.md", 0) }, list: []string{"a.md"}},
		{name: "ff-entry-unreadable-out-of-scope-ok", mode: "ff", skipRoot: true, build: func(w *world) { w.write("a.txt", "x\n"); w.chmod("a.txt", 0) }, list: []string{"a.txt"}},
		{name: "ff-target-via-symlink", mode: "ff", target: "link", build: func(w *world) {
			w.write("a.md", fakeAWS+"\n")
			if err := os.Symlink(w.corpus, w.scratch+"/link"); err != nil {
				w.t.Fatal(err)
			}
		}, list: []string{"a.md"}},
		{name: "ff-nul-file-in-list", mode: "ff", build: func(w *world) { w.writeBytes("a.md", []byte("x\x00y\n")) }, list: []string{"a.md"}},
		{name: "ff-nul-file-with-token", mode: "ff", build: func(w *world) { w.writeBytes("a.md", []byte("x\x00y "+fakeAWS+"\n")) }, list: []string{"a.md"},
			intended: []intended{{"stdout", "a NUL-bearing listed file is also scanned for high-confidence values"}, {"exit", "the leak in a NUL-bearing file now fails the scan"}}},
		{name: "ff-advisory-warn", mode: "ff", build: func(w *world) { w.write("a.md", "password = Abc12345xyz\n") }, list: []string{"a.md"}},
		{name: "ff-config-file-entry", mode: "ff", build: func(w *world) { w.write("deep/config.json", fakeAWS+"\n") }, list: []string{"deep/config.json"}},
		{name: "ff-stdin-bad-entry", mode: "ff", build: two, rawList: ptr("{{T}}/../x.md\x00"), stdin: true},
	}
}
