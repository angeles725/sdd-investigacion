package corpus

// The case table. Every entry is one fixture of the retired research-sdd-archive.test.sh (legacy = its case number);
// want replicates that case's assertions and is checked on the frozen legacy script AND on the Go command, so the
// mapping is itself proven against the oracle. rc -1 means the old case did not assert the exit code.

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"
)

var archiveNumRow = regexp.MustCompile(`^\| [0-9]+ \|`)

type archiveBuild = func(f *archiveFx) string

func archiveGood(sub string) archiveBuild {
	return func(f *archiveFx) string { d := f.path(sub); f.mkgood(d); return d }
}

func archiveGoodThen(edit func(f *archiveFx, d string)) archiveBuild {
	return func(f *archiveFx) string { d := f.path("c"); f.mkgood(d); edit(f, d); return d }
}

func archiveGitClean(edit func(f *archiveFx, d string)) archiveBuild {
	return func(f *archiveFx) string {
		d := f.path("c")
		f.mkgoodGitClean(d)
		if edit != nil {
			edit(f, d)
		}
		return d
	}
}

func archiveWith(extra ...string) func(f *archiveFx, d string) []string {
	return func(_ *archiveFx, d string) []string { return append([]string{d}, extra...) }
}

func archiveStubDir(f *archiveFx, name, file, body string) string {
	dir := filepath.Join(f.root, name)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		f.t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, file), []byte(body), 0o755); err != nil {
		f.t.Fatal(err)
	}
	return dir
}

func archivePathWith(dir string) string { return "PATH=" + dir + ":" + os.Getenv("PATH") }

func archiveFindStub(f *archiveFx, mode string) []string {
	real, _ := lookExec("find")
	var body string
	switch mode {
	case "fail":
		body = `echo "find: simulated failure" >&2; exit 1`
	case "empty":
		body = `exit 0`
	case "perm":
		body = `"` + real + `" "$@"; echo "find: ./locked: Permission denied" >&2; exit 1`
	case "other":
		body = `"` + real + `" "$@"; echo "find: ./x: Input/output error" >&2; exit 1`
	case "silent":
		body = `"` + real + `" "$@"; exit 1`
	}
	script := "#!/bin/bash\ncase \" $* \" in *\" -prune -o -type f -print0 \"*)\n  " + body + ";;\nesac\nexec \"" + real + "\" \"$@\"\n"
	return []string{archivePathWith(archiveStubDir(f, "findstub-"+mode, "find", script))}
}

func lookExec(name string) (string, error) {
	for _, d := range filepath.SplitList(os.Getenv("PATH")) {
		p := filepath.Join(d, name)
		if st, err := os.Stat(p); err == nil && !st.IsDir() && st.Mode()&0o111 != 0 {
			return p, nil
		}
	}
	return "", errors.New("not found")
}

func archiveFindSeam(mode string) func(f *archiveFx, h *archiveHooks) {
	return func(_ *archiveFx, h *archiveHooks) {
		real := h.walk
		switch mode {
		case "fail", "other", "silent":
			h.walk = func(string) ([]string, int, error) { return nil, 0, errors.New("find failed") }
		case "empty":
			h.walk = func(string) ([]string, int, error) { return nil, 0, nil }
		case "perm":
			h.walk = func(r string) ([]string, int, error) { p, _, e := real(r); return p, 1, e }
		}
	}
}

func archiveChmod(rel string, mode os.FileMode) func(f *archiveFx, d string) {
	return func(f *archiveFx, d string) {
		if err := os.Chmod(filepath.Join(d, rel), mode); err != nil {
			f.t.Fatal(err)
		}
	}
}

func archiveRootSkip(*archiveFx) string {
	if os.Geteuid() == 0 {
		return "running as root: permission bits are bypassed"
	}
	return ""
}

func archiveDeletedSecret(f *archiveFx, d string) {
	f.write(filepath.Join(d, "leaked-notes.md"), "Leaked on deploy: AKIAIOSFODNN7EXAMPLE\n")
	f.git(d, "add", "leaked-notes.md")
	f.commit(d, "2026-06-02T00:00:00", "add leaked-notes.md (secret)")
	f.git(d, "rm", "-q", "leaked-notes.md")
	f.commit(d, "2026-06-03T00:00:00", "remove leaked-notes.md")
}

func archiveAppend(rel, text string) func(f *archiveFx, d string) {
	return func(f *archiveFx, d string) {
		p := filepath.Join(d, rel)
		f.write(p, f.read(p)+text)
	}
}

func archiveStubVC(body string) func(f *archiveFx, tb string) {
	return func(f *archiveFx, tb string) {
		archiveFarmStub(f.t, tb, "verify-corrections.sh", "#!/usr/bin/env bash\n"+body+"\n")
	}
}

func archiveRetroFile(name, content string) func(f *archiveFx, d string) {
	return func(f *archiveFx, d string) { f.write(filepath.Join(d, "retros", name), content) }
}

func archiveCases() []archiveCase {
	good := archiveGood("c")
	var cs []archiveCase
	add := func(c ...archiveCase) { cs = append(cs, c...) }

	add(
		archiveCase{name: "good", legacy: "1", build: good, want: archiveWant{rc: 0, has: []string{`archived`}}},
		archiveCase{name: "stale", legacy: "2,3", build: archiveGoodThen(func(f *archiveFx, d string) {
			f.replaceIn(filepath.Join(d, "RESEARCH-STATE.md"), "2 / 3 closed", "3 / 3 closed")
		}), want: archiveWant{rc: 3, noFiles: []string{"CATALOG.md"}}},
		archiveCase{name: "nosrc", legacy: "4", build: archiveGoodThen(archiveAppend("t-block1.md", "\nThis leans on a datasheet [CERT-doc].\n")),
			want: archiveWant{rc: 3}},
		archiveCase{name: "regen", legacy: "5,5a", build: good, want: archiveWant{rc: 0, files: []string{"CATALOG.md"}, has: []string{`via kit generator`}, fileHas: [][2]string{{"CATALOG.md", "the first thing"}}}},
		archiveCase{name: "preferlocal", legacy: "5b", build: archiveGoodThen(func(f *archiveFx, d string) {
			f.write(filepath.Join(d, "tools", "gen-catalog.py"), "import sys\nfrom pathlib import Path\nROOT = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent\n(ROOT / \"CATALOG.md\").write_text(\"BESPOKE-LOCAL-GENERATOR-RAN\\n\", encoding=\"utf-8\")\n")
		}), want: archiveWant{rc: 0, has: []string{`via local generator`}, fileHas: [][2]string{{"CATALOG.md", "BESPOKE-LOCAL-GENERATOR-RAN"}}}},
		archiveCase{name: "symlinkgen", legacy: "5c", build: archiveGoodThen(func(f *archiveFx, d string) {
			f.write(filepath.Join(d, "..", "fakekit", "gen-catalog.py"), "import sys\nfrom pathlib import Path\nROOT = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 and sys.argv[1] else Path(__file__).resolve().parent.parent\n(ROOT / \"CATALOG.md\").write_text(\"SYMLINKED-GEN-RAN\\n\", encoding=\"utf-8\")\n")
			f.mkdir(filepath.Join(d, "tools"))
			if err := os.Symlink(filepath.Join(d, "..", "fakekit", "gen-catalog.py"), filepath.Join(d, "tools", "gen-catalog.py")); err != nil {
				f.t.Fatal(err)
			}
		}), want: archiveWant{rc: 0, fileHas: [][2]string{{"CATALOG.md", "SYMLINKED-GEN-RAN"}}, noFiles: []string{"../CATALOG.md"}}},
		// kit issue #2535: a dangling tools/gen-catalog.py symlink (a corpus that linked the deleted kit template) is not a
		// local generator, so the close falls through to the Go command and still regenerates.
		archiveCase{name: "dangling-gen", legacy: "5e", build: archiveGoodThen(func(f *archiveFx, d string) {
			f.mkdir(filepath.Join(d, "tools"))
			if err := os.Symlink(filepath.Join(d, "..", "no-such-kit", "gen-catalog.py"), filepath.Join(d, "tools", "gen-catalog.py")); err != nil {
				f.t.Fatal(err)
			}
		}), want: archiveWant{rc: 0, has: []string{`via kit generator`}, lacks: []string{`via local generator`}, fileHas: [][2]string{{"CATALOG.md", `(?m)^Total: \*\*1 blocks\*\*$`}}}},
		// A failing `rsdd corpus catalog` step (CATALOG.md is a directory, so the write fails) is reported by name with a
		// rerun hint, CATALOG.md stays stale, and the close still exits 0 (consolidate is best-effort).
		archiveCase{name: "catalog-fail", legacy: "5f", build: archiveGoodThen(func(f *archiveFx, d string) {
			f.mkdir(filepath.Join(d, "CATALOG.md"))
		}), want: archiveWant{rc: 0, has: []string{`ERROR — kit generator \(rsdd corpus catalog\) failed`, `run: rsdd corpus catalog `}, lacks: []string{`gen-catalog.py failed`}, errHas: []string{`CATALOG regen failed`}}},
		archiveCase{name: "dry", legacy: "6", build: good, args: archiveWith("--dry-run"), want: archiveWant{rc: 0, noFiles: []string{"CATALOG.md"}}},
		archiveCase{name: "empty", legacy: "7", build: func(f *archiveFx) string { d := f.path("c"); f.mkdir(d); return d }, want: archiveWant{rc: 2}},
		archiveCase{name: "nested", legacy: "8", build: func(f *archiveFx) string {
			d := f.path("c")
			f.mkgood(filepath.Join(d, "corpus"))
			f.write(filepath.Join(d, "app.html"), "")
			return d
		}, want: archiveWant{rc: 0, files: []string{"corpus/CATALOG.md"}}},
		archiveCase{name: "bighist", legacy: "9", build: archiveGoodThen(func(f *archiveFx, d string) {
			var b strings.Builder
			for i := 2; i <= 30; i++ {
				fmt.Fprintf(&b, "| %d | 2026-07-07 | gap %d | B%d | no · inline | 0 |\n", i, i, i)
			}
			archiveAppend("RESEARCH-STATE.md", b.String())(f, d)
		}), want: archiveWant{rc: -1, has: []string{`(?i)collapse|iteration.history`}}},
		archiveCase{name: "checklist", legacy: "10", build: good, want: archiveWant{rc: 0, has: []string{`(?i)retro`}}},
		archiveCase{name: "parity-reminder", legacy: "10a", build: archiveGoodThen(func(f *archiveFx, d string) { f.mkdir(filepath.Join(d, "codegen")) }),
			want: archiveWant{rc: 0, has: []string{`(?i)PARITY.*verify-parity`}, errHas: []string{`(?i)WARN:.*deliverable.*verify-parity`}}},
		archiveCase{name: "no-codegen", legacy: "10a,10b", build: good,
			want: archiveWant{rc: 0, lacks: []string{`(?i)PARITY.*verify-parity`}, errNot: []string{`(?i)WARN:.*deliverable.*verify-parity`}}},
		archiveCase{name: "noargs", legacy: "11", build: good, args: func(*archiveFx, string) []string { return nil }, want: archiveWant{rc: 2}},
		archiveCase{name: "lockedtree", legacy: "12", build: archiveGoodThen(func(f *archiveFx, d string) { f.mkdir(filepath.Join(d, "lockeddir")) }),
			skip: archiveRootSkip, arm: archiveChmod("lockeddir", 0), disarm: archiveChmod("lockeddir", 0o755),
			want: archiveWant{rc: 0, has: []string{`research-sdd-archive:`}}},
		archiveCase{name: "brokenlinter", legacy: "13", build: good,
			farm: func(f *archiveFx, tb string) {
				_ = os.Remove(filepath.Join(tb, "verify-state.sh"))
				_ = os.Remove(filepath.Join(tb, "verify-corrections.sh"))
			}, want: archiveWant{rc: 3, has: []string{`(?i)did not run`}, noFiles: []string{"CATALOG.md"}}},
		archiveCase{name: "decoy", legacy: "14", build: archiveGoodThen(func(f *archiveFx, d string) {
			f.write(filepath.Join(d, "blocked-notes.md"), "# not a block\n")
			f.sync(d)
		}), want: archiveWant{rc: -1, has: []string{`blocks on disk : 1( |$|·)`}}},
		archiveCase{name: "rotouch", legacy: "15", build: good,
			lenv: func(f *archiveFx) []string {
				real, _ := lookExec("touch")
				body := "#!/bin/bash\ncase \"$*\" in *INDEX.md*) exit 1;; esac\nexec \"" + real + "\" \"$@\"\n"
				return []string{archivePathWith(archiveStubDir(f, "touchstub", "touch", body))}
			},
			seam: func(_ *archiveFx, h *archiveHooks) {
				h.touch = func(string, time.Time) error { return errors.New("touch failed") }
			},
			want: archiveWant{rc: 0, has: []string{`archived`, `could not touch INDEX.md`}}},
		archiveCase{name: "secret", legacy: "16", build: archiveGoodThen(archiveAppend("t-block1.md", "\nLeaked on deploy: AKIAIOSFODNN7EXAMPLE\n")),
			want: archiveWant{rc: 3, has: []string{`(?i)scan-secrets .*FAIL`}}},
		archiveCase{name: "nosecret", legacy: "17", build: good, want: archiveWant{rc: 0, has: []string{`scan-secrets .*: ok`}}},
	)

	// ---- secrets gate over git states (17a-17x) ----
	scanOK := archiveWant{rc: 0, has: []string{`scan-secrets .*: ok`}}
	gitFail := func(extra ...string) archiveWant {
		return archiveWant{rc: 3, has: append([]string{`(?i)scan-secrets .*FAIL`}, extra...)}
	}
	gitProbeErr := archiveWant{rc: 3, has: []string{`(?i)scan-secrets .*ERROR.*could not determine`}, lacks: []string{`(?i)not a git repository`}}
	add(
		archiveCase{name: "committed-clean", legacy: "17a", build: archiveGitClean(nil), want: scanOK},
		archiveCase{name: "committed-deleted-secret", legacy: "17b,17w", build: archiveGitClean(archiveDeletedSecret),
			want: archiveWant{rc: 3, has: []string{`(?i)scan-secrets .*FAIL`, `history must be rewritten`}, lacks: []string{`OUTSIDE the target directory`}}},
		archiveCase{name: "committed-uncommitted-secret", legacy: "17c", build: archiveGitClean(func(f *archiveFx, d string) { f.write(filepath.Join(d, "uncommitted-notes.md"), archiveSecretLine) }),
			want: gitFail(`(?i)scan-secrets .*FAIL.*the working tree`)},
		archiveCase{name: "committed-uncommitted-nosecret", legacy: "17d", build: archiveGitClean(func(f *archiveFx, d string) {
			f.write(filepath.Join(d, "scratch.md"), "just a scratch note, nothing sensitive\n")
		}), want: scanOK},
		archiveCase{name: "realflow", legacy: "17e", twice: true, build: func(f *archiveFx) string {
			d := f.path("c")
			f.mkgoodGitPresync(d)
			f.sync(d)
			return d
		}, want: archiveWant{rc: 0, has: []string{`scan-secrets .*: ok`}, files: []string{"CATALOG.md"}}},
		archiveCase{name: "showuntracked-no", legacy: "17f", build: archiveGitClean(func(f *archiveFx, d string) {
			f.git(d, "config", "status.showUntrackedFiles", "no")
			f.write(filepath.Join(d, "hidden-by-config.md"), archiveSecretLine)
		}), want: gitFail(`(?i)scan-secrets .*FAIL.*the working tree`)},
		archiveCase{name: "opus-f1-repro", legacy: "17f-opus1", build: archiveGitClean(func(f *archiveFx, d string) {
			f.write(filepath.Join(d, "focusA", "a-block3.md"), "# fake nested block\nBody.\n")
			f.write(filepath.Join(d, "notes.md"), archiveSecretLine)
		}), want: gitFail()},
		archiveCase{name: "gitignored-env", legacy: "17f-opus2", build: archiveGitClean(func(f *archiveFx, d string) {
			f.write(filepath.Join(d, ".gitignore"), "*.env\n")
			f.git(d, "add", ".gitignore")
			f.commit(d, "2026-06-02T00:00:00", "add gitignore for *.env")
			f.write(filepath.Join(d, "secret.env"), "AWS_KEY=AKIAIOSFODNN7EXAMPLE\n")
		}), want: gitFail()},
		archiveCase{name: "symlink-outside", legacy: "17f-opus4", build: archiveGitClean(func(f *archiveFx, d string) {
			f.write(filepath.Join(d, "..", "outside-secret", "real.md"), archiveSecretLine)
			if err := os.Symlink(filepath.Join(d, "..", "outside-secret", "real.md"), filepath.Join(d, "link-to-outside.md")); err != nil {
				f.t.Fatal(err)
			}
		}), want: scanOK},
		archiveCase{name: "gitstub", legacy: "17g", build: archiveGitClean(nil), env: func(f *archiveFx) []string {
			return []string{archivePathWith(archiveStubDir(f, "stubbin", "git", "#!/usr/bin/env bash\nexit 127\n"))}
		}, want: gitProbeErr},
		archiveCase{name: "dubious", legacy: "17h", build: archiveGitClean(nil), env: func(*archiveFx) []string { return []string{"GIT_TEST_ASSUME_DIFFERENT_OWNER=1"} },
			skip: archiveDubiousSkip, want: gitProbeErr},
		archiveCase{name: "badconfig", legacy: "17i", build: archiveGitClean(nil), env: func(f *archiveFx) []string {
			p := filepath.Join(f.root, "bad.gitconfig")
			if err := os.WriteFile(p, []byte("[core\nthis is not valid config syntax at all !!!\n"), 0o644); err != nil {
				f.t.Fatal(err)
			}
			return []string{"GIT_CONFIG_GLOBAL=" + p}
		}, want: gitProbeErr},
		archiveCase{name: "nested-clean", legacy: "17j", build: func(f *archiveFx) string {
			o := f.path("outer")
			n := filepath.Join(o, "corpus-nested")
			f.mkNestedTarget(o, n)
			return n
		}, want: archiveWant{rc: 0, has: []string{`(?i)WARN: history not scanned`, `@ROOT@/work/case/outer`}, lacks: []string{`(?i)check git/awk/tr`}}},
		archiveCase{name: "nested-secret", legacy: "17k", build: func(f *archiveFx) string {
			o := f.path("outer")
			n := filepath.Join(o, "corpus-nested")
			f.mkNestedTarget(o, n)
			archiveAppend("t-block1.md", "\n"+archiveSecretLine)(f, n)
			return n
		}, want: archiveWant{rc: 3, has: []string{`(?i)WARN: history not scanned`, `(?i)scan-secrets .*FAIL`}, lacks: []string{`(?i)check git/awk/tr`}}},
		archiveCase{name: "narrow-clean", legacy: "17m", build: archiveGoodThen(func(f *archiveFx, d string) {
			f.mkdir(filepath.Join(d, "blocks"))
			if err := os.Rename(filepath.Join(d, "t-block1.md"), filepath.Join(d, "blocks", "t-block1.md")); err != nil {
				f.t.Fatal(err)
			}
			f.sync(d)
		}), args: archiveWith("--dry-run"), want: archiveWant{rc: 0}},
		archiveCase{name: "narrow-secret", legacy: "17m", build: archiveGoodThen(func(f *archiveFx, d string) {
			f.mkdir(filepath.Join(d, "blocks"))
			if err := os.Rename(filepath.Join(d, "t-block1.md"), filepath.Join(d, "blocks", "t-block1.md")); err != nil {
				f.t.Fatal(err)
			}
			f.sync(d)
			f.write(filepath.Join(d, "notes.md"), archiveSecretLine)
		}), want: gitFail()},
		archiveCase{name: "narrow-scope", legacy: "17n", build: archiveGoodThen(func(f *archiveFx, d string) {
			f.write(filepath.Join(d, "node_modules", "pkg", "readme.md"), "AKIAIOSFODNN7EXAMPLE\n")
			f.write(filepath.Join(d, "scratch.txt"), "AKIAIOSFODNN7EXAMPLE\n")
		}), want: scanOK},
		archiveCase{name: "symlinked-root-leak", legacy: "17o", build: func(f *archiveFx) string {
			d := f.path("symparent/hs")
			f.mkgoodGitClean(d)
			archiveDeletedSecret(f, d)
			if err := os.Symlink(f.path("symparent"), f.path("symparent-link")); err != nil {
				f.t.Fatal(err)
			}
			return f.path("symparent-link/hs")
		}, want: archiveWant{rc: 3, has: []string{`(?i)scan-secrets .*FAIL.*committed history`}, lacks: []string{`(?i)history not scanned`}}},
		archiveCase{name: "symlinked-root-clean", legacy: "17o", build: func(f *archiveFx) string {
			f.mkgoodGitClean(f.path("symclean/hs"))
			if err := os.Symlink(f.path("symclean"), f.path("symclean-link")); err != nil {
				f.t.Fatal(err)
			}
			return f.path("symclean-link/hs")
		}, want: archiveWant{rc: 0, has: []string{`scan-secrets .*: ok$`}, lacks: []string{`(?i)history not scanned`}}},
		archiveCase{name: "unborn", legacy: "17p", build: archiveGoodThen(func(f *archiveFx, d string) { f.git(d, "init", "-q", "-b", "main") }),
			want: archiveWant{rc: 0, has: []string{`WARN: history not scanned — repository has no commits yet`, `scan-secrets .*: ok .*no commits yet`}}},
		archiveCase{name: "unborn-secret", legacy: "17p", build: archiveGoodThen(func(f *archiveFx, d string) {
			f.git(d, "init", "-q", "-b", "main")
			f.write(filepath.Join(d, "notes.md"), "Leaked: AKIAIOSFODNN7EXAMPLE\n")
		}), want: archiveWant{rc: 3, has: []string{`(?i)scan-secrets .*FAIL.*the working tree`, `no commits yet`}}},
	)
	listErr := archiveWant{rc: 3, has: []string{`scan-secrets +: ERROR — the packaging list could not be computed`}}
	for _, m := range []string{"fail", "empty", "perm", "other", "silent"} {
		m := m
		w := listErr
		legacy := "17q"
		switch m {
		case "empty":
			w = archiveWant{rc: 3, has: []string{`scan-secrets +: ERROR — the packaging list is EMPTY`}}
		case "perm":
			w = archiveWant{rc: 0, has: []string{`scan-secrets +: ok, 1 unreadable path\(s\) not scanned`}, errHas: []string{`WARN: scan-secrets packaging list skipped 1 unreadable path\(s\)`}}
		case "silent":
			legacy = "17u"
		}
		add(archiveCase{name: "list-" + m, legacy: legacy, build: good, lenv: func(f *archiveFx) []string { return archiveFindStub(f, m) }, seam: archiveFindSeam(m), want: w})
	}
	add(
		archiveCase{name: "list-fail-git", legacy: "17q", build: archiveGitClean(nil), lenv: func(f *archiveFx) []string { return archiveFindStub(f, "fail") }, seam: archiveFindSeam("fail"), want: listErr},
		archiveCase{name: "hint-root", legacy: "17r", build: archiveGitClean(func(f *archiveFx, d string) { f.write(filepath.Join(d, "notes.md"), "Leaked: AKIAIOSFODNN7EXAMPLE\n") }),
			want: archiveWant{rc: 3, has: []string{`-print0 \| `, `scan-secrets\.sh --files-from -`, `scan-secrets\.sh --committed`}}},
		archiveCase{name: "unreadable-dir", legacy: "17s", build: archiveGoodThen(func(f *archiveFx, d string) { f.write(filepath.Join(d, "locked", "inner.md"), "x\n") }),
			skip: archiveRootSkip, arm: archiveChmod("locked", 0), disarm: archiveChmod("locked", 0o755),
			want: archiveWant{rc: 0, has: []string{`scan-secrets +: ok, 1 unreadable path\(s\) not scanned`}}},
		archiveCase{name: "unreadable-file", legacy: "17t", build: archiveGoodThen(func(f *archiveFx, d string) { f.write(filepath.Join(d, "notes.md"), "Leaked: AKIAIOSFODNN7EXAMPLE\n") }),
			skip: archiveRootSkip, arm: archiveChmod("notes.md", 0), disarm: archiveChmod("notes.md", 0o644),
			want: archiveWant{rc: 3, has: []string{`scan-secrets +: ERROR — scan-secrets.sh did not run cleanly \(exit 3\).*DEGRADED`}, lacks: []string{`scan-secrets +: ok`}}},
		archiveCase{name: "hint-space", legacy: "17v,17w", build: func(f *archiveFx) string {
			d := f.path("hint space")
			f.mkgoodGitClean(d)
			f.write(filepath.Join(d, "secret.env"), "Leaked: AKIAIOSFODNN7EXAMPLE\n")
			f.write(filepath.Join(d, ".gitignore"), "secret.env\n")
			return d
		}, want: archiveWant{rc: 3, has: []string{`OUTSIDE the target directory`, `hint\\ space`}, lacks: []string{`--files-from - @ROOT@/work/case/hint space`, `AKIAIOSFODNN7`, `history must be rewritten`}}},
		archiveCase{name: "leak-both", legacy: "17w", build: archiveGitClean(func(f *archiveFx, d string) {
			f.write(filepath.Join(d, "old.md"), "Leaked: AKIAIOSFODNN7EXAMPLE\n")
			f.git(d, "add", "old.md")
			f.commit(d, "2026-06-02T00:00:00", "add old.md (secret)")
			f.write(filepath.Join(d, "notes.md"), "Leaked: AKIAIOSFODNN7EXAMPLE\n")
		}), want: archiveWant{rc: 3, has: []string{`history must be rewritten`, `OUTSIDE the target directory`}}},
		archiveCase{name: "unresolvable", legacy: "17x", build: good,
			lenv: func(f *archiveFx) []string {
				p := filepath.Join(f.root, "cdfail.env")
				if err := os.WriteFile(p, []byte("cd(){ if [ \"${1:-}\" = \"-P\" ]; then return 1; fi; builtin cd \"$@\"; }\n"), 0o644); err != nil {
					f.t.Fatal(err)
				}
				return []string{"BASH_ENV=" + p}
			},
			seam: func(_ *archiveFx, h *archiveHooks) { h.phys = func(string) (string, bool) { return "", false } },
			want: archiveWant{rc: 3, has: []string{`the target directory could not be resolved physically`, `target unresolvable`}, lacks: []string{`find '' `}}},
	)

	// ---- templates, retros, git dates ----
	tmpl := "# <SUBJECT> — Research State\n\n## Coverage\n\n- **Coverage metric**: 16 / 16 closed  (e.g. 16/16 then 26/26)\n\n## Gap-backlog (prioritized)\n\n| Priority | Gap | Artifact type / source | Status |\n|---|---|---|---|\n| high | <research question> | web | pending |\n\n## Stop control\n\n- **Open gaps — read-only investigable**: 1\n"
	missing := `(?i)MISSING-RETRO.*REFUSE`
	rmRetros := func(f *archiveFx, d string) {
		_ = os.RemoveAll(filepath.Join(d, "retros"))
		f.mkdir(filepath.Join(d, "retros"))
	}
	add(
		archiveCase{name: "tmplonly", legacy: "18", build: func(f *archiveFx) string {
			d := f.path("c")
			f.write(filepath.Join(d, "RESEARCH-STATE.template.md"), tmpl)
			return d
		}, want: archiveWant{rc: 2}},
		archiveCase{name: "real-plus-template", legacy: "19", build: archiveGoodThen(func(f *archiveFx, d string) {
			f.write(filepath.Join(d, "RESEARCH-STATE.template.md"), "# <SUBJECT> — Research State\n- **Coverage metric**: 16 / 16 closed  (e.g. 16/16 then 26/26)\n| high | <placeholder> | web | pending |\n")
		}), want: archiveWant{rc: 0}},
		archiveCase{name: "missingretro", legacy: "20,37", build: archiveGoodThen(func(f *archiveFx, d string) { _ = os.RemoveAll(filepath.Join(d, "retros")) }),
			want: archiveWant{rc: 3, has: []string{missing}}},
		archiveCase{name: "oldretro", legacy: "20a", build: archiveGoodThen(func(f *archiveFx, d string) {
			rmRetros(f, d)
			p := filepath.Join(d, "retros", "2020-01-01-focus.md")
			f.write(p, "")
			f.chtimes(p, "2020-01-01")
		}), want: archiveWant{rc: 3, has: []string{`(?i)MISSING-RETRO`, `2020-01-01`}}},
		archiveCase{name: "freshretro", legacy: "20b", build: good, want: archiveWant{rc: 0, lacks: []string{`(?i)MISSING-RETRO`}}},
		archiveCase{name: "excluded-retro", legacy: "20c", build: archiveGoodThen(func(f *archiveFx, d string) {
			rmRetros(f, d)
			f.write(filepath.Join(d, "retros", "client.md"), "<!-- kit-retro: exclude -->\n# client retro — not §18\n")
		}), want: archiveWant{rc: 3, has: []string{`(?i)MISSING-RETRO`}}},
		archiveCase{name: "git-warn", legacy: "21", build: func(f *archiveFx) string {
			d := f.path("c")
			f.mkgoodGit(d, "2026-01-10T00:00:00", "2026-03-01T00:00:00", "2030-01-01", "2020-01-01")
			return d
		}, want: archiveWant{rc: 3, has: []string{`(?i)MISSING-RETRO`, `2026-01-10`}}},
		archiveCase{name: "git-nowarn", legacy: "21a", build: func(f *archiveFx) string {
			d := f.path("c")
			f.mkgoodGit(d, "2026-03-01T00:00:00", "2026-01-10T00:00:00", "2020-01-01", "2030-01-01")
			return d
		}, want: archiveWant{rc: 0, lacks: []string{`(?i)MISSING-RETRO`}}},
		archiveCase{name: "git-warn-rel", legacy: "21b", build: func(f *archiveFx) string {
			d := f.path("git-warn-rel")
			f.mkgoodGit(d, "2026-01-10T00:00:00", "2026-03-01T00:00:00", "2030-01-01", "2020-01-01")
			return d
		}, args: func(_ *archiveFx, d string) []string { return []string{filepath.Base(d)} },
			cwd: func(f *archiveFx, _ string) string { return f.cdir }, want: archiveWant{rc: 3, has: []string{`(?i)MISSING-RETRO`}}},
		archiveCase{name: "rename-tradeoff", legacy: "36", build: func(f *archiveFx) string {
			d := f.path("c")
			f.gitInit(d)
			f.write(filepath.Join(d, "RESEARCH-STATE.md"), archiveStateText)
			f.write(filepath.Join(d, "INDEX.md"), "")
			f.git(d, "add", "-A")
			f.commit(d, "2026-01-01T00:00:00", "baseline")
			f.write(filepath.Join(d, "t-block1.md"), "# Block 1\nBody.\n")
			f.git(d, "add", "t-block1.md")
			f.commit(d, "2026-01-10T00:00:00", "add block1")
			f.write(filepath.Join(d, "retros", "orig-retro.md"), "# retro\n")
			f.git(d, "add", "retros/orig-retro.md")
			f.commit(d, "2000-01-01T00:00:00", "add orig-retro.md (deep-past)")
			f.git(d, "mv", "retros/orig-retro.md", "retros/retro-focus.md")
			f.commit(d, "2026-02-01T00:00:00", "rename orig-retro.md to retro-focus.md")
			f.sync(d)
			return d
		}, want: archiveWant{rc: 0, lacks: []string{`(?i)MISSING-RETRO`}}},
		archiveCase{name: "missing-retro-neg", legacy: "37a", build: archiveGoodThen(func(f *archiveFx, d string) {
			rmRetros(f, d)
			p := filepath.Join(d, "retros", "2030-01-01-fresh.md")
			f.write(p, "")
			f.chtimes(p, "2030-01-01")
		}), want: archiveWant{rc: 0, lacks: []string{missing}}},
	)

	// ---- ONE-BLOCK-PER-COMMIT ----
	obpc := `WARN: ONE-BLOCK-PER-COMMIT`
	exempt := `(?i)exempt from ONE-BLOCK-PER-COMMIT`
	run := func(together bool) archiveBuild {
		return func(f *archiveFx) string { d := f.path("c"); f.mkrunGit(d, together, ""); return d }
	}
	psa := func(marker, date, raw, pre string) archiveBuild {
		return func(f *archiveFx) string { d := f.path("c"); f.mkrunGitPSA(d, marker, date, raw, pre); return d }
	}
	warns := archiveWant{rc: 0, has: []string{obpc}, lacks: []string{exempt}}
	pre20 := "| 2 | 2026-02-01 | old | B0 | no · inline · method: per-section-agent · 20 sections | 0 |"
	add(
		archiveCase{name: "one-block-violation", legacy: "22", build: run(true), want: archiveWant{rc: 0, has: []string{`(?i)ONE-BLOCK-PER-COMMIT`}}},
		archiveCase{name: "one-block-clean", legacy: "23", build: run(false), want: archiveWant{rc: 0, lacks: []string{`(?i)ONE-BLOCK-PER-COMMIT`}}},
		archiveCase{name: "one-block-psa", legacy: "22a", build: psa("method: per-section-agent · 2 sections", "", "", ""), want: archiveWant{rc: 0, lacks: []string{obpc}, has: []string{exempt}}},
		archiveCase{name: "one-block-psa-short", legacy: "22b", build: psa("method: per-section-agent · 1 sections", "", "", ""), want: warns},
		archiveCase{name: "one-block-seq", legacy: "22c", build: psa("method: sequential · 2 sections", "", "", ""), want: warns},
		archiveCase{name: "one-block-psa-stale", legacy: "22d", build: run2(pre20), want: warns},
		archiveCase{name: "one-block-psa-sameday", legacy: "22d2", build: psa("method: per-section-agent · 2 sections", "2026-02-01", "", ""), want: archiveWant{rc: 0, lacks: []string{obpc}, has: []string{exempt}}},
		archiveCase{name: "one-block-psa-both", legacy: "22d3", build: psa("method: per-section-agent · 1 sections", "2026-07-08", "", pre20), want: warns},
		archiveCase{name: "one-block-psa-prose", legacy: "22e", build: psa("", "", "> e.g. method: per-section-agent · 40 sections", ""), want: warns},
		archiveCase{name: "one-block-psa-fence", legacy: "22e2", build: psa("", "", "```\n| 2 | 2026-07-08 | x | B1,B2 | method: per-section-agent · 40 sections | 0 |\n```", ""), want: warns},
		archiveCase{name: "one-block-psa-nonnum", legacy: "22e3", build: psa("", "", "| n/a | 2026-07-08 | x | B1,B2 | method: per-section-agent · 40 sections | 0 |", ""), want: warns},
		archiveCase{name: "one-block-psa-nopipe", legacy: "22e4", build: psa("", "", "2 | 2026-07-08 | x | B1,B2 | method: per-section-agent · 40 sections | 0", ""), want: warns},
		archiveCase{name: "one-block-psa-spell", legacy: "22f", build: psa("method: per-section-agent - 2 sections", "", "", ""), want: warns},
		archiveCase{name: "one-block-backlink", legacy: "23a", build: func(f *archiveFx) string { d := f.path("c"); f.mkrunGitBacklink(d); return d }, want: archiveWant{rc: 0, lacks: []string{`(?i)ONE-BLOCK-PER-COMMIT`}}},
		archiveCase{name: "one-block-rename", legacy: "23b", build: func(f *archiveFx) string { d := f.path("c"); f.mkrunGitRename(d); return d }, want: archiveWant{rc: 0, lacks: []string{`(?i)ONE-BLOCK-PER-COMMIT`}}},
	)

	// ---- retro format lint ----
	add(
		archiveCase{name: "lint-bare", legacy: "24", build: archiveGoodThen(archiveRetroFile("2026-07-25-bad-format.md", "# Retro §18 — some-target · focus · 2026-07-25\n\nreview-status: pending\n\nRun summary: bad format.\n")),
			want: archiveWant{rc: 0, errHas: []string{`(?i)WARN.*2026-07-25-bad-format`, `(?i)bare text|bare-text|malform|wrap.*<!--|not.*HTML`}}},
		archiveCase{name: "lint-absent", legacy: "24a", build: archiveGoodThen(archiveRetroFile("2026-07-25-no-marker.md", "# Retro §18 — some-target · focus · 2026-07-25\n\nRun summary: completely absent marker.\n")),
			want: archiveWant{rc: 0, errHas: []string{`(?i)WARN.*2026-07-25-no-marker`}}},
		archiveCase{name: "lint-ok", legacy: "24b", build: archiveGoodThen(archiveRetroFile("2026-07-25-good-format.md", "<!-- review-status: pending -->\n# Retro §18 — some-target · focus · 2026-07-25\n\nRun summary: correct format.\n")),
			want: archiveWant{rc: 0, errNot: []string{`(?i)WARN.*2026-07-25-good-format`}}},
		archiveCase{name: "lint-index", legacy: "25", build: archiveGoodThen(archiveRetroFile("RETROS-INDEX.md", "# Retros index\n\n| # | file |\n|---|---|\n| 1 | r1.md |\n")),
			want: archiveWant{rc: 0, errNot: []string{`(?i)WARN.*RETROS-INDEX`}}},
	)

	// ---- undocumented_findings ----
	rs := "RESEARCH-STATE.md"
	ufset := func(n int, files ...string) archiveBuild {
		return archiveGoodThen(func(f *archiveFx, d string) {
			for _, fl := range files {
				f.setUF(filepath.Join(d, fl), n)
			}
		})
	}
	multi := func(edit func(f *archiveFx, d string)) archiveBuild {
		return func(f *archiveFx) string { d := f.path("c"); f.mkmulti(d); edit(f, d); return d }
	}
	ufRefuse := archiveWant{rc: 3, has: []string{`(?i)undocumented_findings`}}
	add(
		archiveCase{name: "uf-ok", legacy: "26", build: ufset(0, rs), want: archiveWant{rc: 0}},
		archiveCase{name: "uf-refuse", legacy: "27", build: ufset(1, rs), want: ufRefuse},
		archiveCase{name: "uf-absent", legacy: "28", build: archiveGoodThen(func(f *archiveFx, d string) { f.dropUF(filepath.Join(d, rs)) }), want: archiveWant{rc: 0}},
		archiveCase{name: "mf-uf-ok", legacy: "29", build: multi(func(*archiveFx, string) {}), want: archiveWant{rc: 0}},
		archiveCase{name: "mf-uf-refuse", legacy: "30", build: multi(func(f *archiveFx, d string) { f.setUF(filepath.Join(d, "RESEARCH-STATE-alpha.md"), 1) }), want: ufRefuse},
		archiveCase{name: "mf-uf-beta", legacy: "31", build: multi(func(f *archiveFx, d string) { f.setUF(filepath.Join(d, "RESEARCH-STATE-beta.md"), 2) }), want: ufRefuse},
		archiveCase{name: "mf-uf-absent", legacy: "32", build: multi(func(f *archiveFx, d string) {
			f.dropUF(filepath.Join(d, "RESEARCH-STATE-alpha.md"))
			f.dropUF(filepath.Join(d, "RESEARCH-STATE-beta.md"))
		}), want: archiveWant{rc: 0}},
		archiveCase{name: "uf-empty-enum", legacy: "33", build: ufset(1, rs),
			farm: func(f *archiveFx, tb string) {
				archiveFarmLib(f.t, tb)
				archiveFarmStubLib(f.t, tb, "state-files.sh", "list_state_files() { return 0; }")
			},
			seam: func(_ *archiveFx, h *archiveHooks) { h.listState = func(string) ([]string, error) { return nil, nil } },
			want: archiveWant{rc: 3, has: []string{`(?i)undocumented_findings.*(no state file|could not|enumerat)`}}},
		archiveCase{name: "uf-noexist-paths", legacy: "34", build: good,
			farm: func(f *archiveFx, tb string) {
				archiveFarmLib(f.t, tb)
				d := f.path("c")
				archiveFarmStubLib(f.t, tb, "state-files.sh", "list_state_files() { printf '%s\\n' \""+d+"/DOES-NOT-EXIST-1.md\" \""+d+"/DOES-NOT-EXIST-2.md\"; }")
			},
			seam: func(f *archiveFx, h *archiveHooks) {
				d := f.path("c")
				h.listState = func(string) ([]string, error) {
					return []string{d + "/DOES-NOT-EXIST-1.md", d + "/DOES-NOT-EXIST-2.md"}, nil
				}
			},
			want: archiveWant{rc: 3, has: []string{`(?i)undocumented_findings.*(no state file|could not|enumerat)`}}},
		archiveCase{name: "split-uf", legacy: "35", build: func(f *archiveFx) string {
			d := f.path("c")
			f.mksplit(d)
			f.setUF(filepath.Join(d, "beta", rs), 1)
			return d
		}, want: ufRefuse},
		archiveCase{name: "ar1-focus", legacy: "38", build: multi(func(f *archiveFx, d string) { f.setUF(filepath.Join(d, "RESEARCH-STATE-beta.md"), 1) }),
			args: archiveWith("--focus", "alpha", "--dry-run"), want: archiveWant{rc: 0, has: []string{`scoped to focus alpha`}}},
		archiveCase{name: "ar1-unknown", legacy: "39", build: multi(func(*archiveFx, string) {}), args: archiveWith("--focus", "unknown-slug"),
			want: archiveWant{rc: 2, has: []string{`unknown-slug`}}},
		archiveCase{name: "ar1-default", legacy: "40", build: good, args: archiveWith("--dry-run"), want: archiveWant{rc: 0}},
		archiveCase{name: "ar-1818-rootpref", legacy: "40b", build: archiveGoodThen(func(f *archiveFx, d string) {
			f.write(filepath.Join(d, "RESEARCH-STATE-aaa.md"), strings.Replace(f.read(filepath.Join(d, rs)), "| 1 | 2026-07-07 | first gap | B1 | no · inline | 1 |\n", "| 1 | 2026-07-07 | first gap | B1 | no · inline | 1 |\n| 2 | 2026-07-08 | second | B1 | no · inline | 0 |\n", 1))
			f.sync(d, "aaa")
		}), args: archiveWith("--dry-run"), want: archiveWant{rc: 0, has: []string{`iteration-history rows: 1$`}}},
	)

	// ---- AR2 and the verify-corrections gate ----
	beta := func(f *archiveFx, d string) {
		p := filepath.Join(d, "RESEARCH-STATE-beta.md")
		f.write(p, strings.Replace(f.read(p), "| Priority | Gap | Artifact type / source | Status |\n", "| Priority | Gap | Artifact type / source | Status |\n| high | beta-open-gap | web | pending |\n", 1))
		f.sync(d, "beta")
	}
	vc := `verify-corrections +: `
	vcBad := archiveWant{rc: 3, has: []string{`verify-corrections : FAIL — 1 one-directional`, `FAIL   B2 corrects \[Block 1\]`, `REFUSED: reconcile`}, lacks: []string{`verify-corrections : ok`}}
	mkv := func(edit func(f *archiveFx, d string)) archiveBuild {
		return func(f *archiveFx) string {
			d := f.path("c")
			f.mkvcorr(d)
			if edit != nil {
				edit(f, d)
			}
			return d
		}
	}
	vcFocus := func(focus string, edit func(f *archiveFx, d string)) archiveBuild {
		return func(f *archiveFx) string {
			d := f.path("c")
			f.mkvfocus(d, focus)
			if edit != nil {
				edit(f, d)
			}
			return d
		}
	}
	stubRC := func(rc string) func(*archiveFx, string) {
		return archiveStubVC(`echo "usage: verify-corrections.sh <target-dir>" >&2; exit ` + rc)
	}
	ovr := "--allow-unreciprocated-corrections"
	add(
		archiveCase{name: "ar2-baseline", legacy: "AR2", build: multi(beta), args: archiveWith("--dry-run"), want: archiveWant{rc: 3}},
		archiveCase{name: "ar2-focus", legacy: "AR2", build: multi(beta), args: archiveWith("--focus", "alpha", "--dry-run"), want: archiveWant{rc: 0}},
		archiveCase{name: "vcorr-bad", legacy: "AR-VCORR", build: mkv(nil), args: archiveWith("--dry-run"), want: vcBad},
		archiveCase{name: "vcorr-override", legacy: "AR-VCORR", build: mkv(nil), args: archiveWith("--dry-run", ovr),
			want: archiveWant{rc: 0, has: []string{`verify-corrections : OVERRIDDEN — 1 one-directional`}, lacks: []string{`REFUSED: reconcile`}, errHas: []string{`WARN: verify-corrections gate overridden`}}},
		archiveCase{name: "vcorr-ok", legacy: "AR-VCORR", build: mkv(archiveAppend("t-block1.md", "Corrected in B2.\n")), args: archiveWith("--dry-run"),
			want: archiveWant{rc: 0, has: []string{`verify-corrections : ok`}, lacks: []string{`one-directional`}}},
		archiveCase{name: "vcorr-clean", legacy: "AR-VCORR", build: good, args: archiveWith("--dry-run"), want: archiveWant{rc: 0, has: []string{`verify-corrections : ok`}}},
		archiveCase{name: "vcorr-partial", legacy: "AR-VCORR", build: archiveGoodThen(func(f *archiveFx, d string) {
			f.write(filepath.Join(d, "t-block2.md"), "# Block 2 — correction\nCorrects [Block 9] §1.1 — the earlier claim was wrong.\n")
			f.sync(d)
		}), args: archiveWith("--dry-run"), want: archiveWant{rc: 0, has: []string{`verify-corrections : PARTIAL — 1 declared correction\(s\) NOT checked`}, lacks: []string{`verify-corrections : ok`}, errHas: []string{`WARN: verify-corrections ok-partial`}}},
		archiveCase{name: "vcorr-noblocks", legacy: "AR-VCORR", build: archiveGoodThen(func(f *archiveFx, d string) { _ = os.Remove(filepath.Join(d, "t-block1.md")) }),
			args: archiveWith("--dry-run"), want: archiveWant{rc: -1, has: []string{`verify-corrections : n/a`}, lacks: []string{`verify-corrections : (ERROR|WARN|FAIL)`}}},
		archiveCase{name: "vcorr-stub7", legacy: "AR-VCORR", build: good, farm: stubRC("7"), args: archiveWith("--dry-run"),
			want: archiveWant{rc: 3, has: []string{`verify-corrections : ERROR — verify-corrections.sh did not run`}, lacks: []string{`verify-corrections : n/a`}}},
		archiveCase{name: "vcorr-stub7-ovr", legacy: "AR-VCORR", build: good, farm: stubRC("7"), args: archiveWith("--dry-run", ovr),
			want: archiveWant{rc: 0, has: []string{`verify-corrections : OVERRIDDEN — verify-corrections.sh did not run`}}},
		archiveCase{name: "vcorr-stub2", legacy: "AR-VCORR", build: good, farm: stubRC("2"), args: archiveWith("--dry-run"),
			want: archiveWant{rc: 3, has: []string{`verify-corrections : ERROR — verify-corrections.sh did not run`}, lacks: []string{`verify-corrections : n/a`}}},
		archiveCase{name: "vcorr-stub2-ovr", legacy: "AR-VCORR", build: good, farm: stubRC("2"), args: archiveWith("--dry-run", ovr),
			want: archiveWant{rc: 0, has: []string{`verify-corrections : OVERRIDDEN — verify-corrections.sh did not run`}}},
		archiveCase{name: "vcorr-drift", legacy: "AR-VCORR", build: good, farm: archiveStubVC(`echo "ISSUE B2 corrects B1" >&2; exit 1`), args: archiveWith("--dry-run"),
			want: archiveWant{rc: 3, has: []string{`verify-corrections : ERROR — verify-corrections exited 1 with no findings \(could not run\?\)`}, lacks: []string{`one-directional`, `verify-corrections : FAIL`}}},
		archiveCase{name: "vcorr-degraded", legacy: "AR-VCORR", build: good, farm: archiveStubVC(`echo "verify-corrections: degraded: awk not found on PATH; the corpus was NOT checked" >&2; exit 1`), args: archiveWith("--dry-run"),
			want: archiveWant{rc: 3, has: []string{`verify-corrections : DEGRADED — `}, lacks: []string{`one-directional`}}},
		archiveCase{name: "vcorr-degraded-ovr", legacy: "AR-VCORR", build: good, farm: archiveStubVC(`echo "verify-corrections: degraded: awk not found on PATH; the corpus was NOT checked" >&2; exit 1`), args: archiveWith("--dry-run", ovr),
			want: archiveWant{rc: 0, has: []string{`verify-corrections : OVERRIDDEN — .*degraded`}}},
		archiveCase{name: "vcorr-missing", legacy: "AR-VCORR", build: good, farm: func(f *archiveFx, tb string) { _ = os.Remove(filepath.Join(tb, "verify-corrections.sh")) }, args: archiveWith("--dry-run"),
			want: archiveWant{rc: 3, has: []string{`verify-corrections : ERROR — verify-corrections.sh did not run \(exit 127\)`}}},
		archiveCase{name: "vcorr-bare0", legacy: "AR-VCORR", build: good, farm: archiveStubVC(`echo "nothing useful"; exit 0`), args: archiveWith("--dry-run"),
			want: archiveWant{rc: 3, has: []string{`verify-corrections : ERROR — verify-corrections.sh exited 0 without an 'ok' verdict line`}, lacks: []string{`verify-corrections : ok`}}},
		archiveCase{name: "vcorr-ovr-other", legacy: "AR-VCORR", build: mkv(func(f *archiveFx, d string) { f.replaceIn(filepath.Join(d, rs), "2 / 3 closed", "3 / 3 closed") }), args: archiveWith("--dry-run", ovr),
			want: archiveWant{rc: 3, has: []string{`verify-corrections : OVERRIDDEN`, `verify-state   : FAIL`, `REFUSED: reconcile`}}},
		archiveCase{name: "vcorr-focus-sib", legacy: "AR-VCORR", build: vcFocus("beta", nil), args: archiveWith("--dry-run", "--focus", "alpha"),
			want: archiveWant{rc: 0, has: []string{`verify-corrections : SIBLING — 1 pair\(s\) outside focus alpha not enforced`}, lacks: []string{`verify-corrections : FAIL`, `REFUSED: reconcile`}, errHas: []string{`WARN: verify-corrections found 1 one-directional pair`}}},
		archiveCase{name: "vcorr-focus-nofocus", legacy: "AR-VCORR", build: vcFocus("beta", nil), args: archiveWith("--dry-run"),
			want: archiveWant{rc: 3, has: []string{`verify-corrections : FAIL — 1 one-directional`}}},
		archiveCase{name: "vcorr-focus-failing", legacy: "AR-VCORR", build: vcFocus("beta", nil), args: archiveWith("--dry-run", "--focus", "beta"),
			want: archiveWant{rc: 3, has: []string{`verify-corrections : FAIL — 1 one-directional`, `FAIL   B2 corrects \[Block 1\] but beta-block1.md`}, lacks: []string{`SIBLING`}}},
		archiveCase{name: "vcorr-focus-unres", legacy: "AR-VCORR", build: vcFocus("alpha", func(f *archiveFx, d string) { _ = os.Remove(filepath.Join(d, "beta-block1.md")) }), args: archiveWith("--dry-run", "--focus", "beta"),
			want: archiveWant{rc: 3, has: []string{`verify-corrections : ERROR — cannot scope the §14 gate to focus beta`}, lacks: []string{`verify-corrections : (SIBLING|ok)`}}},
		archiveCase{name: "vcorr-focus-num", legacy: "AR-VCORR#1857", build: vcFocus("beta", func(f *archiveFx, d string) {
			f.write(filepath.Join(d, "alpha-block2.md"), "# Alpha Block 2\nBody.\n")
			f.sync(d, "alpha")
		}), args: archiveWith("--dry-run", "--focus", "alpha"),
			want: archiveWant{rc: 0, has: []string{`verify-corrections : SIBLING — 1 pair\(s\) outside focus alpha not enforced`}, lacks: []string{`verify-corrections : FAIL`}}},
		archiveCase{name: "vcorr-focus-xcorr", legacy: "AR-VCORR#1857", build: multi(func(f *archiveFx, d string) {
			f.write(filepath.Join(d, "alpha-block7.md"), "# Alpha Block 7\nCorrects `beta` [Block 1] §1.1 — the earlier claim was wrong.\n")
			f.sync(d, "alpha")
		}), args: archiveWith("--dry-run", "--focus", "alpha"),
			want: archiveWant{rc: 3, has: []string{`FAIL   B7 corrects \[Block 1\] but beta-block1.md`}, lacks: []string{`SIBLING`}}},
		archiveCase{name: "vcorr-focus-dirname", legacy: "AR-VCORR#1857", build: func(f *archiveFx) string {
			d := f.path("alpha-block9-dir/corpus")
			f.mkvfocus(d, "beta")
			return d
		}, args: archiveWith("--dry-run", "--focus", "alpha"), want: archiveWant{rc: 0, has: []string{`verify-corrections : SIBLING — 1 pair\(s\)`}}},
		archiveCase{name: "vcorr-focus-nocf", legacy: "AR-VCORR#1857", build: vcFocus("beta", nil),
			farm: archiveStubVC(`echo "   FAIL   B2 corrects [Block 1] but beta-block1.md has no reciprocal backlink to B2 (§14)"; exit 1`), args: archiveWith("--dry-run", "--focus", "alpha"),
			want: archiveWant{rc: 3, has: []string{`verify-corrections : FAIL — 1 one-directional`}, lacks: []string{`SIBLING`}}},
		archiveCase{name: "vcorr-ambig", legacy: "AR-VCORR#1868", build: archiveGoodThen(func(f *archiveFx, d string) {
			f.write(filepath.Join(d, "t-block2.md"), "# Block 2 — correction\nCorrects B1 §1.1 — the earlier claim was wrong.\n")
			f.sync(d)
		}), args: archiveWith("--dry-run"), want: archiveWant{rc: 0, has: []string{`verify-corrections : PARTIAL — 1 declared correction\(s\) NOT checked \(1 typed ambiguous`}, lacks: []string{`verify-corrections : FAIL`}}},
	)
	_ = vc
	return cs
}

// run2 builds the stale-marker fixture of case 22d: mkrun_git with a pre-existing per-section-agent row.
func run2(pre string) archiveBuild {
	return func(f *archiveFx) string { d := f.path("c"); f.mkrunGit(d, true, pre); return d }
}

func archiveFarmStubLib(t testing.TB, tb, name, body string) {
	t.Helper()
	p := filepath.Join(tb, "lib", name)
	_ = os.Remove(p)
	src := "# shellcheck disable=SC2148\n. \"" + realLibPath(name) + "\"\n" + body + "\n"
	if err := os.WriteFile(p, []byte(src), 0o644); err != nil {
		t.Fatal(err)
	}
}

func realLibPath(name string) string {
	p, _ := filepath.Abs(archiveKitRel + "/toolbelt/lib/" + name)
	return p
}

func archiveDubiousSkip(f *archiveFx) string {
	d := filepath.Join(f.root, "dubious-probe")
	f.gitInit(d)
	c := exec.Command("git", "-C", d, "rev-parse", "--show-toplevel")
	c.Env = append(os.Environ(), "GIT_TEST_ASSUME_DIFFERENT_OWNER=1")
	out, err := c.CombinedOutput()
	if err == nil || !strings.Contains(strings.ToLower(string(out)), "dubious ownership") {
		return "GIT_TEST_ASSUME_DIFFERENT_OWNER=1 does not reproduce dubious ownership on this host"
	}
	return ""
}
