package secretscan

import (
	"os"
	"path/filepath"
	"strings"
)

// hist is a --committed case: the corpus is initialised as a repository, then steps run.
func hist(name string, steps func(w *world)) scase {
	return scase{name: "hist-" + name, mode: "committed", build: func(w *world) { w.initRepo(); steps(w) }}
}

// histFiles is a repository with one commit holding the files (path, content pairs).
func histFiles(name string, kv ...string) scase {
	return hist(name, func(w *world) {
		for i := 0; i < len(kv); i += 2 {
			w.write(kv[i], kv[i+1])
		}
		w.commit("c1")
	})
}

func histBasicCases() []scase {
	return []scase{
		histFiles("clean", "notes.md", "nothing here\n"),
		histFiles("all-seven-rules", "notes.md", strings.Join([]string{fakePEM, fakeAWS, fakeGH, fakeSlack, fakeGoog, fakeSK, fakeJWT}, "\n")+"\n"),
		histFiles("aws", "notes.md", "k "+fakeAWS+"\n"),
		histFiles("pem-first-dash-pattern", "notes.md", fakePEM+"\n"),
		histFiles("two-rules-one-line", "notes.md", fakeAWS+" "+fakeGH+"\n"),
		histFiles("two-tokens-one-line-one-entry", "notes.md", fakeAWS+" "+fakeAWS+"\n"),
		histFiles("nested-env", "a/b/.env.prod", "t="+fakeGH+"\n"),
		histFiles("nested-config", "a/config.yaml", "t="+fakeGH+"\n"),
		histFiles("nested-credentials", "a/credentials", "t="+fakeGH+"\n"),
		histFiles("conf-ini-properties-cfg", "a.conf", fakeAWS+"\n", "b.ini", fakeGH+"\n", "c.properties", fakeSK+"\n", "d.cfg", fakeJWT+"\n"),
		histFiles("advisory-warn", "notes.md", "password = Abc12345xyz\n"),
		histFiles("advisory-uppercase", "notes.md", "PASSWORD = Abc12345xyz\n"),
		histFiles("advisory-and-leak", "notes.md", fakeAWS+"\ntoken: Tk99abcdefgh\n"),
		histFiles("advisory-order-bytewise", "notes.md", strings.Repeat("x\n", 8)+"password = Abc12345xyz\ntoken = Tk99abcdefgh\n"),
		histFiles("out-of-scope-only-degraded", "a.txt", fakeAWS+"\n"),
		histFiles("excluded-dir-only-degraded", "decompiled/x.md", fakeAWS+"\n"),
		histFiles("excluded-dir-plus-clean", "decompiled/x.md", fakeAWS+"\n", "ok.md", "clean\n"),
		histFiles("symlink-target-text", "x.txt", "plain\n"),
		hist("empty-commit-only", func(w *world) { w.commit("empty") }),
		hist("deleted-from-head", func(w *world) {
			w.write("notes.md", "t "+fakeGH+"\n")
			w.commit("add")
			w.write("notes.md", "t REDACTED\n")
			w.commit("redact")
		}),
		hist("redacted-uncommitted-still-leaks", func(w *world) {
			w.write("notes.md", "t "+fakeGH+"\n")
			w.commit("add")
			w.write("notes.md", "t REDACTED\n")
		}),
		hist("uncommitted-secret-not-seen", func(w *world) {
			w.write("notes.md", "clean\n")
			w.commit("add")
			w.write("notes.md", fakeAWS+"\n")
		}),
		hist("same-blob-excluded-and-inscope", func(w *world) {
			w.write("a.txt", "t "+fakeGH+"\n")
			w.write("notes.md", "t "+fakeGH+"\n")
			w.commit("add")
		}),
		hist("same-blob-decompiled-and-zz", func(w *world) {
			w.write("decompiled/x.md", "t "+fakeGH+"\n")
			w.write("zz.md", "t "+fakeGH+"\n")
			w.commit("add")
		}),
		hist("same-blob-two-inscope-smallest-path", func(w *world) {
			w.write("zz.md", "t "+fakeGH+"\n")
			w.write("aa.md", "t "+fakeGH+"\n")
			w.commit("add")
		}),
		hist("renamed-out-of-scope", func(w *world) {
			w.write("n.md", "t "+fakeGH+"\n")
			w.commit("add")
			w.git("mv", "n.md", "n.txt")
			w.commit("rename")
		}),
		hist("two-versions-one-file", func(w *world) {
			w.write("notes.md", "token = Tk99abcdefgh\n")
			w.commit("v1")
			w.write("notes.md", "token = Tk99abcdefgh\nmore\n")
			w.commit("v2")
		}),
		withDivergence(hist("many-hits-cap", func(w *world) {
			w.write("notes.md", strings.Repeat(fakeAWS+"\n", 55))
			w.commit("c1")
		}), "the cut of a rule past 50 hits is announced instead of silent"),
		hist("symlink-blob", func(w *world) {
			w.symlink(fakeAWS, "notes.md")
			w.commit("c1")
		}),
		hist("merge-commit", func(w *world) {
			w.write("a.md", "one\n")
			w.commit("base")
			w.git("checkout", "-q", "-b", "side")
			w.write("b.md", "t "+fakeGH+"\n")
			w.commit("side")
			w.git("checkout", "-q", "main")
			w.write("c.md", "two\n")
			w.commit("main")
			w.git("merge", "-q", "--no-ff", "-m", "merge", "side")
		}),
		hist("path-with-pipe", func(w *world) { w.write("a|b\\1.md", "t "+fakeGH+"\n"); w.commit("c1") }),
		hist("path-with-newline", func(w *world) { w.write("a\nb.md", "t "+fakeGH+"\n"); w.commit("c1") }),
		withDivergence(hist("path-with-space-and-leading-space", func(w *world) { w.write(" lead.md", "t "+fakeGH+"\n"); w.commit("c1") }),
			"the path is reported exactly; the legacy read loop trimmed its leading blank"),
		hist("path-leading-colon", func(w *world) { w.write(":notes.md", "t "+fakeGH+"\n"); w.commit("c1") }),
		hist("path-leading-colon-nested", func(w *world) { w.write(":dir/x.md", "t "+fakeGH+"\n"); w.commit("c1") }),
		hist("path-leading-colon-with-clean-sibling", func(w *world) {
			w.write(":notes.md", "t "+fakeGH+"\n")
			w.write("ok.md", "clean\n")
			w.commit("c1")
		}),
		hist("gitlink-at-md-path", func(w *world) {
			w.write("ok.md", "clean\n")
			w.git("add", "ok.md")
			w.git("update-index", "--add", "--cacheinfo", "160000,"+strings.Repeat("a", 40)+",notes.md")
			w.git("commit", "-q", "-m", "gitlink")
		}),
	}
}

const nulOnce = "a hit on a line that also holds a NUL byte is reported once; the raw and the NUL-stripped scan each reported it, so the legacy report printed the same leak twice"

func histEncodingCases() []scase {
	utf16be := func(s string) []byte {
		var out []byte
		for _, r := range s {
			out = append(out, 0, byte(r))
		}
		return out
	}
	utf32le := func(s string) []byte {
		var out []byte
		for _, r := range s {
			out = append(out, byte(r), 0, 0, 0)
		}
		return out
	}
	bin := func(name, file string, b []byte) scase {
		return hist(name, func(w *world) { w.writeBytes(file, b); w.commit("c1") })
	}
	return []scase{
		bin("latin1-byte-same-line", "notes.md", []byte("t "+fakeGH+" \xf1\n")),
		bin("pem-crlf-latin1", "notes.md", []byte(fakePEM+"\r \xe9\n")),
		bin("utf16le-env", ".env", utf16le("t="+fakeGH+"\n")),
		bin("utf16be-env", ".env", utf16be("t="+fakeGH+"\n")),
		bin("utf32le-env", ".env", utf32le("t="+fakeGH+"\n")),
		withDivergence(bin("nul-md-token", "notes.md", []byte("a\x00b "+fakeAWS+"\n")), nulOnce),
		bin("nul-md-advisory", "notes.md", []byte("a\x00b\npassword = Abc12345xyz\n")),
		withDivergence(bin("nul-in-matching-line", "notes.md", []byte(fakeAWS+" \x00\n")), nulOnce),
	}
}

func histMetaCases() []scase {
	return []scase{
		hist("commit-message-token", func(w *world) {
			w.write("a.md", "clean\n")
			w.commit("fix " + fakeGH)
		}),
		hist("commit-message-many-commits-line-numbers", func(w *world) {
			for i := 0; i < 3; i++ {
				w.write("a.md", strings.Repeat("x\n", i+1))
				w.commit("c")
			}
			w.commit("leak " + fakeAWS)
			w.commit("tail")
		}),
		hist("commit-message-multiline", func(w *world) {
			w.write("a.md", "clean\n")
			w.commit("subject\n\nbody line\n" + fakeSlack + "\nlast")
		}),
		hist("author-name-token", func(w *world) {
			w.write("a.md", "clean\n")
			w.git("add", "-A")
			w.gitEnv([]string{"GIT_AUTHOR_NAME=" + fakeGH}, "commit", "-q", "-m", "c1")
		}),
		hist("committer-name-token", func(w *world) {
			w.write("a.md", "clean\n")
			w.git("add", "-A")
			w.gitEnv([]string{"GIT_COMMITTER_NAME=" + fakeAWS}, "commit", "-q", "-m", "c1")
		}),
		hist("commit-message-two-tokens-one-line", func(w *world) { w.commit(fakeAWS + " " + fakeAWS) }),
		hist("show-signature-config", func(w *world) {
			w.write("a.md", "t "+fakeGH+"\n")
			w.commit("c1")
			w.git("config", "log.showSignature", "true")
		}),
		hist("diff-merges-off-evil-merge", func(w *world) {
			w.write("a.md", "one\n")
			w.commit("base")
			w.git("checkout", "-q", "-b", "side")
			w.write("b.md", "side\n")
			w.commit("side")
			w.git("checkout", "-q", "main")
			w.write("c.md", "main\n")
			w.commit("main")
			w.git("merge", "-q", "--no-ff", "--no-commit", "side")
			w.write("evil.md", "t "+fakeGH+"\n")
			w.git("add", "-A")
			w.git("commit", "-q", "-m", "merge")
			w.git("config", "log.diffMerges", "off")
		}),
		hist("log-output-encoding-utf16", func(w *world) {
			w.write("a.md", "t "+fakeGH+"\n")
			w.commit("c1 " + fakeAWS)
			w.git("config", "i18n.logOutputEncoding", "UTF-16")
		}),
		hist("commit-encoding-utf16", func(w *world) {
			w.git("config", "i18n.commitEncoding", "UTF-16")
			w.write("a.md", "t "+fakeGH+"\n")
			w.commit("c1 " + fakeAWS)
		}),
		hist("replace-ref-hides-secret-commit", func(w *world) {
			w.write("a.md", "clean\n")
			w.commit("base")
			w.write("a.md", "t "+fakeGH+"\n")
			w.commit("leak")
			leak := w.git("rev-parse", "HEAD")
			w.git("reset", "-q", "--hard", "HEAD~1")
			w.write("a.md", "clean2\n")
			w.commit("clean stand-in")
			w.git("replace", leak, w.git("rev-parse", "HEAD"))
		}),
	}
}

func histRefusalCases() []scase {
	return []scase{
		{name: "hist-not-a-repository", mode: "committed", build: func(w *world) { w.write("a.md", "x\n") }},
		{name: "hist-no-commits", mode: "committed", build: func(w *world) { w.initRepo(); w.write("a.md", "x\n") }},
		{name: "hist-git-absent", mode: "committed", noGit: true, build: func(w *world) { w.initRepo(); w.write("a.md", "x\n"); w.commit("c1") }},
		{name: "hist-subdirectory-target", mode: "committed", target: "corpus/sub", build: func(w *world) {
			w.initRepo()
			w.write("sub/a.md", "x\n")
			w.commit("c1")
		}},
		{name: "hist-grafts-nonempty", mode: "committed", build: func(w *world) {
			w.initRepo()
			w.write("a.md", "x\n")
			w.commit("c1")
			if err := os.MkdirAll(filepath.Join(w.corpus, ".git/info"), 0o755); err != nil {
				w.t.Fatal(err)
			}
			w.write(".git/info/grafts", strings.Repeat("a", 40)+"\n")
		}},
		{name: "hist-grafts-empty-file-ok", mode: "committed", build: func(w *world) {
			w.initRepo()
			w.write("a.md", "x\n")
			w.commit("c1")
			w.write(".git/info/grafts", "")
		}},
		{name: "hist-graft-file-env", mode: "committed", env: []string{"GIT_GRAFT_FILE=/dev/null"}, build: func(w *world) {
			w.initRepo()
			w.write("a.md", "x\n")
			w.commit("c1")
		}},
		{name: "hist-graft-file-env-empty-ok", mode: "committed", env: []string{"GIT_GRAFT_FILE="}, build: func(w *world) {
			w.initRepo()
			w.write("a.md", "x\n")
			w.commit("c1")
		}},
		{name: "hist-corrupt-blob", mode: "committed", build: func(w *world) {
			w.initRepo()
			w.write("notes.md", "t "+fakeGH+"\n")
			w.commit("c1")
			sha := w.git("rev-parse", "HEAD:notes.md")
			p := filepath.Join(w.corpus, ".git/objects", sha[:2], sha[2:])
			if err := os.Chmod(p, 0o644); err != nil {
				w.t.Fatal(err)
			}
			if err := os.WriteFile(p, []byte("garbage"), 0o644); err != nil {
				w.t.Fatal(err)
			}
		}},
		{name: "hist-missing-commit-object", mode: "committed", build: func(w *world) {
			w.initRepo()
			w.write("notes.md", "x\n")
			w.commit("c1")
			head := w.git("rev-parse", "HEAD")
			p := filepath.Join(w.corpus, ".git/objects", head[:2], head[2:])
			if err := os.Chmod(p, 0o644); err != nil {
				w.t.Fatal(err)
			}
			if err := os.Remove(p); err != nil {
				w.t.Fatal(err)
			}
		}},
	}
}
