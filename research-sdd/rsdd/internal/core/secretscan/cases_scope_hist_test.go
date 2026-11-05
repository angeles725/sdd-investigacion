package secretscan

import "strings"

// Committed-mode scope is decided on the WHOLE path (legacy awk regexes over the diff-tree path), unlike the
// working-tree walk and --files-from, which test the base name only: a `config.` component anywhere in the path is
// in scope, and `.git` is not an excluded component (only the vendored/decompiled names are).

// histPlumbing is a repository whose single commit holds the files, built with tree plumbing so a path the index
// refuses (a `.git` component) can still be committed, as a hostile or hand-built history can.
func histPlumbing(name string, paths ...string) scase {
	return hist(name, func(w *world) {
		blob := w.gitIn(w.corpus, []byte("t="+fakeAWS+"\n"), "hash-object", "-w", "--stdin")
		// nest builds the tree for one path: every component becomes a one-entry tree.
		var nest func(parts []string) string
		nest = func(parts []string) string {
			if len(parts) == 1 {
				return w.gitIn(w.corpus, []byte("100644 blob "+blob+"\t"+parts[0]+"\n"), "mktree")
			}
			return w.gitIn(w.corpus, []byte("040000 tree "+nest(parts[1:])+"\t"+parts[0]+"\n"), "mktree")
		}
		var entries strings.Builder
		for _, p := range paths {
			parts := strings.Split(p, "/")
			entries.WriteString("040000 tree " + nest(parts[1:]) + "\t" + parts[0] + "\n")
		}
		tree := w.gitIn(w.corpus, []byte(entries.String()), "mktree")
		commit := w.gitIn(w.corpus, nil, "commit-tree", tree, "-m", "plumbing")
		w.git("update-ref", "refs/heads/main", commit)
	})
}

// dirConfig is a corpus with a clean note and a leak under a `config.` directory (a base-name rule scans neither).
func dirConfig(w *world) {
	w.write("notes.md", "nothing\n")
	w.write("config.d/x.txt", "t="+fakeAWS+"\n")
}

func histScopeCases() []scase {
	return []scase{
		// the working-tree walk and --files-from are base-name only in the legacy script: the leak stays unseen there
		{name: "scope-wt-config-dir-is-basename-only", build: dirConfig},
		{name: "ff-config-dir-is-basename-only", mode: "ff", build: dirConfig, list: []string{"notes.md", "config.d/x.txt"}},
		{name: "scope-wt-dot-git-dir-never-entered", build: func(w *world) {
			w.write("notes.md", "nothing\n")
			w.write("sub/.git/notes.md", "t="+fakeAWS+"\n")
		}},
		histFiles("scope-config-dir", "config.d/x.txt", "t="+fakeAWS+"\n"),
		histFiles("scope-config-dir-nested", "app/config.old/x.txt", "t="+fakeAWS+"\n"),
		histFiles("scope-config-dir-deep", "a/b/c/config.bak/d/e/x.txt", "t="+fakeAWS+"\n"),
		histFiles("scope-config-dir-beside-clean-note", "notes.md", "nothing\n", "config.d/x.txt", "t="+fakeAWS+"\n"),
		histFiles("scope-config-name-not-component-start", "notes.md", "nothing\n", "xconfig.d/x.txt", "t="+fakeAWS+"\n"),
		histFiles("scope-config-without-dot-not-in-scope", "notes.md", "nothing\n", "config/x.txt", "t="+fakeAWS+"\n"),
		histFiles("scope-config-dir-in-excluded-tree", "notes.md", "nothing\n", "node_modules/config.d/x.txt", "t="+fakeAWS+"\n"),
		histFiles("scope-excluded-dir-needs-trailing-slash", "notes.md", "nothing\n", "cfr", "t="+fakeAWS+"\n", "a/cfr.md", "t="+fakeGH+"\n"),
		histPlumbing("scope-dot-git-component-is-scanned", "sub/.git/notes.md"),
		histPlumbing("scope-dot-git-component-config", "sub/.git/config.d/x.txt"),
	}
}
