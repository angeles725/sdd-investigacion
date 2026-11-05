package secretscan

import "os"

const nlName = "a path with a newline is printed on one line with the newline escaped as \\n; the legacy report split it, losing the file name from the location"

// leakIn is a corpus of a single file holding a leak, to see whether the file is in scope.
func leakIn(name, file string) scase { return one(name, file, fakeAWS+"\n") }

func scopeCases() []scase {
	u := func(c scase) scase { c.unordered = true; return c }
	cs := []scase{
		leakIn("scope-md", "a.md"),
		leakIn("scope-env-suffix", "prod.env"),
		leakIn("scope-env-bare", ".env"),
		leakIn("scope-env-local", ".env.local"),
		leakIn("scope-conf", "app.conf"),
		leakIn("scope-ini", "app.ini"),
		leakIn("scope-properties", "app.properties"),
		leakIn("scope-cfg", "app.cfg"),
		leakIn("scope-config-json", "config.json"),
		leakIn("scope-config-bare-no", "config"),
		leakIn("scope-credentials", "credentials"),
		leakIn("scope-credentials-ext-no", "credentials.txt"),
		leakIn("scope-txt-no", "a.txt"),
		leakIn("scope-sh-no", "a.sh"),
		leakIn("scope-markdown-ext-no", "a.markdown"),
		leakIn("scope-uppercase-md-no", "A.MD"),
		leakIn("scope-md-only-dot", ".md"),
		leakIn("scope-nested-md", "docs/deep/a.md"),
		leakIn("scope-dir-node-modules", "node_modules/x/a.md"),
		leakIn("scope-dir-venv-dot", ".venv/a.md"),
		leakIn("scope-dir-venv", "venv/a.md"),
		leakIn("scope-dir-decompiled", "decompiled/a.md"),
		leakIn("scope-dir-vineflower", "src/vineflower/a.md"),
		leakIn("scope-dir-procyon", "procyon/a.md"),
		leakIn("scope-dir-cfr", "cfr/a.md"),
		leakIn("scope-dir-jadx", "a/b/jadx/a.md"),
		leakIn("scope-dir-dotgit", ".git/a.md"),
		leakIn("scope-dir-similar-name-kept", "node_modules2/a.md"),
		leakIn("scope-dir-excluded-name-as-file", "a/cfr"),
		u(scase{name: "scope-two-files-both-leak", build: func(w *world) { w.write("a.md", fakeAWS+"\n"); w.write("b.md", fakeGH+"\n") }}),
		u(scase{name: "scope-first-middle-last", build: func(w *world) {
			w.write("a.md", fakeAWS+"\n")
			w.write("m/b.md", "clean\n")
			w.write("z.md", fakeGH+"\n")
		}}),
		{name: "scope-symlink-file-skipped", build: func(w *world) {
			w.write("real.txt", fakeAWS+"\n")
			w.symlink("real.txt", "link.md")
		}},
		{name: "scope-symlink-dir-not-followed", build: func(w *world) {
			w.write("realdir/a.md", fakeAWS+"\n")
			w.symlink("realdir", "linkdir")
		}, intended: nil},
		{name: "scope-dangling-symlink", build: func(w *world) { w.symlink("nowhere", "dangling.md"); w.write("ok.md", "clean\n") }},
		{name: "scope-nul-byte-file", build: func(w *world) { w.writeBytes("bin.md", []byte("a\x00b "+fakeAWS+"\n")) },
			intended: []intended{{"stdout", "a NUL-bearing file is also scanned (raw and NUL-stripped) for high-confidence values; grep -I skipped it whole, so a token in it was reported only as binary-skipped"}, {"exit", "the leak in a NUL-bearing file now fails the scan instead of exiting 0"}}},
		{name: "scope-nul-byte-clean", build: func(w *world) { w.writeBytes("bin.md", []byte("hello\x00world\n")) }},
		{name: "scope-nul-two-files", build: func(w *world) {
			w.writeBytes("a.md", []byte("x\x00y\n"))
			w.writeBytes("b.cfg", []byte("p\x00q\n"))
			w.write("c.md", "clean\n")
		}},
		{name: "scope-utf16le-token", build: func(w *world) { w.writeBytes("u.env", utf16le(fakeGH+"\n")) },
			intended: []intended{{"stdout", "a UTF-16 file in the working tree is scanned NUL-stripped like a committed blob; grep -I skipped it, so the token was missed"}, {"exit", "the token in a UTF-16 working-tree file now fails the scan"}}},
		{name: "scope-file-named-with-newline", build: func(w *world) { w.write("a\nb.md", fakeAWS+"\n") },
			intended: []intended{{"stdout", nlName}}},
		{name: "scope-file-named-with-space-and-colon", build: func(w *world) { w.write("my notes: v1.md", fakeAWS+"\n") }},
		{name: "scope-unreadable-file", skipRoot: true, build: func(w *world) { w.write("a.md", fakeAWS+"\n"); w.chmod("a.md", 0) }},
		{name: "scope-unreadable-dir", skipRoot: true, build: func(w *world) {
			w.write("locked/a.md", fakeAWS+"\n")
			w.chmod("locked", 0)
			w.t.Cleanup(func() { _ = os.Chmod(w.abs("locked"), 0o755) })
		}},
		{name: "scope-relative-target", target: "corpus", build: func(w *world) { w.write("a.md", fakeAWS+"\n") }},
		{name: "scope-dot-slash-target", target: "./corpus", build: func(w *world) { w.write("a.md", fakeAWS+"\n") }},
		{name: "scope-trailing-slash-target", target: "corpus/", build: func(w *world) { w.write("a.md", fakeAWS+"\n") }},
		{name: "scope-double-slash-target", target: "corpus//", build: func(w *world) { w.write("a.md", fakeAWS+"\n") }},
		{name: "scope-empty-corpus", build: func(w *world) {}},
		{name: "scope-only-out-of-scope", build: func(w *world) { w.write("a.txt", fakeAWS+"\n") }},
		{name: "scope-target-named-cfr", build: func(w *world) {
			w.corpus = w.scratch + "/cfr"
			w.mkdir("cfr")
			w.write("a.md", fakeAWS+"\n")
		}, intended: []intended{{"stdout", "the target directory itself is never excluded by name: grep --exclude-dir also matched the command-line directory, so a target named cfr, jadx or venv was reported clean"}, {"exit", "a leak under a target named like an excluded directory now fails the scan"}}},
		{name: "scope-live-install-banner", build: func(w *world) {
			w.write("a.md", "clean\n")
			w.write("../TARGETS.md", "| corpus | live-install |\n| other | none |\n")
		}},
		{name: "scope-banner-other-target-no", build: func(w *world) {
			w.write("a.md", "clean\n")
			w.write("../TARGETS.md", "| elsewhere | live-install |\n")
		}},
	}
	return cs
}

// utf16le encodes s as UTF-16LE with a BOM (what Windows tools write).
func utf16le(s string) []byte {
	out := []byte{0xFF, 0xFE}
	for _, r := range s {
		out = append(out, byte(r), 0)
	}
	return out
}
