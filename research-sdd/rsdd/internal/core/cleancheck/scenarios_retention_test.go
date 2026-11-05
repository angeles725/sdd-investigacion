package cleancheck

import (
	"os"
	"os/exec"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/testkit/execfile"
)

// gitStub puts a git in front of the real one that fails (exit 128, "fatal: boom") for every call whose arguments
// contain match, and runs the real git otherwise. The scenarios use it for the failures a repository cannot be made to
// produce on demand.
func gitStub(w *world, match string) {
	real, err := exec.LookPath("git")
	if err != nil {
		w.t.Fatal(err)
	}
	execfile.Write(w.t, w.root+"/bin/git", "#!/bin/sh\ncase \" $* \" in *\" "+match+" \"*) echo 'fatal: boom' >&2; exit 128;; esac\nexec "+real+" \"$@\"\n")
}

func stubPath(w *world) []string {
	return []string{"PATH=" + w.root + "/bin:" + os.Getenv("PATH")}
}

// addWorktree creates a linked worktree at root/<name> on a new branch of the same name.
func addWorktree(w *world, name string) string {
	p := w.root + "/" + name
	w.git("worktree", "add", "-q", p, "-b", name)
	return p
}

func worktreeScenarios() []scenario {
	return []scenario{
		{name: "worktree-live-checked-out-branch-hidden", build: func(w *world) { keep(w, ""); addWorktree(w, "wtlive") }, args: std(), want: 0},
		{name: "worktree-missing", build: func(w *world) {
			keep(w, "")
			if err := os.RemoveAll(addWorktree(w, "wtgone")); err != nil {
				w.t.Fatal(err)
			}
		}, args: std(), want: 0},
		{name: "worktree-prunable-gitfile-removed", build: func(w *world) {
			keep(w, "")
			if err := os.Remove(addWorktree(w, "wtbad") + "/.git"); err != nil {
				w.t.Fatal(err)
			}
		}, args: std(), want: 0},
		{name: "worktree-locked-and-missing", build: func(w *world) {
			keep(w, "")
			p := addWorktree(w, "wtlock")
			w.git("worktree", "lock", p)
			if err := os.RemoveAll(p); err != nil {
				w.t.Fatal(err)
			}
		}, args: std(), want: 0},
		{name: "worktree-path-with-newline", build: func(w *world) {
			keep(w, "")
			p := w.root + "/wt\nnl"
			w.git("worktree", "add", "-q", p, "-b", "wtnl")
			if err := os.RemoveAll(p); err != nil {
				w.t.Fatal(err)
			}
		}, args: std(), want: 0},
		{name: "worktree-bare-main-repository", build: func(w *world) { keep(w, "") }, args: func(w *world) []string { return []string{"--target", w.repo, "--tmp", w.tmp} }, want: 0},
		{name: "worktree-scan-degraded", build: func(w *world) { keep(w, ""); gitStub(w, "worktree list"); w.git("branch", "m1") }, args: std(), env: stubPath, want: 3},
		{name: "worktree-old-git-has-no-nul-mode", build: func(w *world) {
			keep(w, "")
			gitStub(w, "worktree list --porcelain -z")
			if err := os.RemoveAll(addWorktree(w, "wtold")); err != nil {
				w.t.Fatal(err)
			}
		}, args: std(), env: stubPath, want: 0},
	}
}

// withOrigin gives the repository an origin (a bare clone), fetched, with origin/HEAD set.
func withOrigin(w *world) {
	bare := w.root + "/origin.git"
	w.git("branch", "r-merged")
	w.git("checkout", "-q", "-b", "r-ahead")
	w.write("ahead.txt", "a")
	w.git("add", "ahead.txt")
	w.commit("ahead")
	w.git("checkout", "-q", "main")
	w.gitIn(w.root, "init", "-q", "--bare", bare)
	w.git("remote", "add", "origin", bare)
	w.git("push", "-q", "origin", "main", "r-merged", "r-ahead")
	w.git("fetch", "-q", "origin")
	w.git("remote", "set-head", "origin", "main")
}

func branchScenarios() []scenario {
	return []scenario{
		{name: "branches-merged-and-unmerged", build: func(w *world) {
			keep(w, "")
			w.git("branch", "m1")
			w.git("branch", "m2")
			w.git("checkout", "-q", "-b", "ahead")
			w.commit("ahead")
			w.git("checkout", "-q", "main")
		}, args: std(), want: 0},
		{name: "branches-base-is-origin-head", build: func(w *world) { keep(w, ""); withOrigin(w) }, args: std(), want: 0},
		{name: "branches-checked-out-elsewhere-hidden", build: func(w *world) {
			keep(w, "")
			w.git("branch", "m1")
			p := addWorktree(w, "wtb")
			_ = p
		}, args: std(), want: 0},
		{name: "branches-head-on-merged-branch-hidden", build: func(w *world) { keep(w, ""); w.git("checkout", "-q", "-b", "onhead") }, args: std(), want: 0},
		{name: "branches-explicit-base", build: func(w *world) {
			keep(w, "")
			w.git("checkout", "-q", "-b", "feature")
			w.commit("f1")
			w.git("branch", "mf")
			w.git("checkout", "-q", "main")
		}, args: std("--base", "feature"), want: 0},
		{name: "branches-explicit-base-a-tag", build: func(w *world) { keep(w, ""); w.git("tag", "v1"); w.git("branch", "m1") }, args: std("--base", "v1"), want: 0},
		{name: "branches-unresolvable-base", build: func(w *world) { keep(w, "") }, args: std("--base", "nope"), want: 2},
		{name: "branches-base-not-a-commit-ref-name", build: func(w *world) { keep(w, "") }, args: std("--base", "main:tracked.txt"), want: 2},
		{name: "branches-no-base-at-all", build: func(w *world) { keep(w, ""); w.git("branch", "-m", "trunk"); w.git("branch", "m1") }, args: std(), want: 0},
		{name: "branches-master-fallback", build: func(w *world) { keep(w, ""); w.git("branch", "-m", "master"); w.git("branch", "m1") }, args: std(), want: 0},
		{name: "branches-main-wins-over-master", build: func(w *world) { keep(w, ""); w.git("branch", "master"); w.git("branch", "m1") }, args: std(), want: 0},
		{name: "branches-scan-degraded", build: func(w *world) { keep(w, ""); gitStub(w, "for-each-ref"); w.git("branch", "m1") }, args: std(), env: stubPath, want: 3},
		{name: "branches-worktree-and-branch-scan-degraded", build: func(w *world) {
			keep(w, "")
			gitStub(w, "worktree")
			w.git("branch", "m1")
			withOrigin(w)
		}, args: std(), env: stubPath, want: 3},
		{name: "branches-degraded-with-a-finding-still-exits-1", build: func(w *world) { keep(w, ""); gitStub(w, "for-each-ref"); w.write("stray.txt", "x") }, args: std(), env: stubPath, want: 1},
		{name: "branches-slash-names-and-remote-twin-of-base", build: func(w *world) {
			keep(w, "")
			w.git("branch", "topic/one")
			w.git("branch", "main2")
			withOrigin(w)
		}, args: std("--base", "origin/main"), want: 0},
	}
}

func evidenceScenarios() []scenario {
	backups := func(w *world, ev string) {
		for _, n := range []string{"rollback-1", "Backup.tar", "x.BACKUP", "backup-new", "other", "ROLLBACK_old"} {
			w.writeAt(ev+"/"+n+"/inner", "x")
		}
		w.writeAt(ev+"/x.BACKUP/nested-backup/f", "x")
		w.writeAt(ev+"/plain/backup-inner", "x")
		w.writeAt(ev+"/plain/deep/rollback-too-deep", "x")
		for _, n := range []string{"rollback-1", "Backup.tar", "x.BACKUP", "ROLLBACK_old", "x.BACKUP/nested-backup", "plain/backup-inner", "plain/deep/rollback-too-deep"} {
			w.ago(24*30, ev+"/"+n)
		}
		w.ago(1, ev+"/backup-new")
	}
	return []scenario{
		{name: "evidence-explicit-absent", build: func(w *world) { keep(w, "") }, args: stdW(func(w *world) []string { return []string{"--evidence", w.root + "/nope"} }), want: 0},
		{name: "evidence-explicit-with-backups", build: func(w *world) { keep(w, ""); backups(w, w.root+"/ev") }, args: stdW(func(w *world) []string { return []string{"--evidence", w.root + "/ev/"} }), want: 0},
		{name: "evidence-explicit-empty", build: func(w *world) { keep(w, ""); w.mkdir(w.root + "/ev") }, args: stdW(func(w *world) []string { return []string{"--evidence", w.root + "/ev"} }), want: 0},
		{name: "evidence-none-found", build: func(w *world) { keep(w, "") }, args: std(), want: 0},
		{name: "evidence-discovered-below-the-target", unordered: true, build: func(w *world) {
			keep(w, "_evidence/\na/\n")
			backups(w, w.repo+"/_evidence")
			backups(w, w.repo+"/a/b/_evidence")
			w.writeAt(w.repo+"/_evidence/sub/_evidence/rollback-nested/x", "x")
			w.ago(24*30, w.repo+"/_evidence/sub/_evidence/rollback-nested")
			w.writeAt(w.repo+"/a/b/c/d/_evidence/rollback-deep/x", "x")
			w.ago(24*30, w.repo+"/a/b/c/d/_evidence/rollback-deep")
			w.writeAt(w.repo+"/.git/_evidence/rollback-in-git/x", "x")
		}, args: std(), want: 0},
		{name: "evidence-backup-days-zero", build: func(w *world) {
			keep(w, "")
			w.writeAt(w.root+"/ev/backup-fresh/x", "x")
			w.writeAt(w.root+"/ev/backup-hour/x", "x")
			w.ago(1, w.root+"/ev/backup-hour")
		}, args: stdW(func(w *world) []string { return []string{"--evidence", w.root + "/ev", "--backup-days", "0"} }), want: 0},
		{name: "evidence-backup-days-boundary", build: func(w *world) {
			keep(w, "")
			w.writeAt(w.root+"/ev/backup-a/x", "x")
			w.writeAt(w.root+"/ev/backup-b/x", "x")
			w.ago(24*3.002, w.root+"/ev/backup-a")
			w.ago(24*3.2, w.root+"/ev/backup-b")
		}, args: stdW(func(w *world) []string { return []string{"--evidence", w.root + "/ev", "--backup-days", "3"} }), want: 0},
		{name: "evidence-explicit-is-a-file", build: func(w *world) { keep(w, ""); w.writeAt(w.root+"/evfile", "x") }, args: stdW(func(w *world) []string { return []string{"--evidence", w.root + "/evfile"} }), want: 0},
		{name: "evidence-unreadable-outside-an-evidence-dir", root: true, build: func(w *world) {
			keep(w, "_evidence/\n.gitignore\n")
			w.write(".gitignore", "locked/\n")
			w.writeAt(w.repo+"/locked/f", "x")
			backups(w, w.repo+"/_evidence")
			if err := os.Chmod(w.repo+"/locked", 0); err != nil {
				w.t.Fatal(err)
			}
			w.t.Cleanup(func() { _ = os.Chmod(w.repo+"/locked", 0o755) })
		}, args: std(), want: 0},
		{name: "evidence-unreadable-and-none-found", root: true, build: func(w *world) {
			keep(w, "_evidence/\n.gitignore\n")
			w.write(".gitignore", "locked/\n")
			w.writeAt(w.repo+"/locked/f", "x")
			if err := os.Chmod(w.repo+"/locked", 0); err != nil {
				w.t.Fatal(err)
			}
			w.t.Cleanup(func() { _ = os.Chmod(w.repo+"/locked", 0o755) })
		}, args: std(), want: 0},
		{name: "evidence-unreadable-inside-an-evidence-dir", root: true, build: func(w *world) {
			keep(w, "_evidence/\n.gitignore\n")
			w.write(".gitignore", "locked/\n")
			w.writeAt(w.repo+"/_evidence/locked/f", "x")
			if err := os.Chmod(w.repo+"/_evidence/locked", 0); err != nil {
				w.t.Fatal(err)
			}
			w.t.Cleanup(func() { _ = os.Chmod(w.repo+"/_evidence/locked", 0o755) })
		}, args: std(), want: 3},
		{name: "evidence-unreadable-explicit-backup-dir", root: true, build: func(w *world) {
			keep(w, "")
			w.writeAt(w.root+"/ev/locked/f", "x")
			if err := os.Chmod(w.root+"/ev/locked", 0); err != nil {
				w.t.Fatal(err)
			}
			w.t.Cleanup(func() { _ = os.Chmod(w.root+"/ev/locked", 0o755) })
		}, args: stdW(func(w *world) []string { return []string{"--evidence", w.root + "/ev"} }), want: 3},
	}
}

func refusalScenarios() []scenario {
	return []scenario{
		{name: "refuse-target-absent", args: func(w *world) []string { return []string{"--target", w.root + "/nope", "--tmp", w.tmp} }, want: 2},
		{name: "refuse-target-not-a-git-tree", build: func(w *world) { w.mkdir(w.root + "/plain") }, args: func(w *world) []string { return []string{"--target", w.root + "/plain", "--tmp", w.tmp} }, want: 2},
		{name: "refuse-target-is-a-file", build: func(w *world) { w.writeAt(w.root+"/afile", "x") }, args: func(w *world) []string { return []string{"--target", w.root + "/afile", "--tmp", w.tmp} }, want: 2},
		{name: "refuse-target-inside-the-git-dir", args: func(w *world) []string { return []string{"--target", w.repo + "/.git", "--tmp", w.tmp} }, want: 2},
		{name: "refuse-tmp-absent", args: func(w *world) []string { return []string{"--target", w.repo, "--tmp", w.root + "/nope"} }, want: 2},
		{name: "refuse-tmp-is-a-file", build: func(w *world) { w.writeAt(w.root+"/afile", "x") }, args: func(w *world) []string { return []string{"--target", w.repo, "--tmp", w.root + "/afile"} }, want: 2},
		{name: "refuse-uid-not-a-number", args: std(), env: func(*world) []string { return []string{"CLEAN_CHECK_UID=abc"} }, want: 2},
		{name: "refuse-ls-files-fails", build: func(w *world) { keep(w, ""); gitStub(w, "ls-files") }, args: std(), env: stubPath, want: 2},
		{name: "refuse-rev-parse-fails", build: func(w *world) { gitStub(w, "rev-parse") }, args: std(), env: stubPath, want: 2},
		{name: "degraded-git-missing", build: func(w *world) { w.mkdir(w.root + "/empty") }, args: std(), env: func(w *world) []string { return []string{"PATH=" + w.root + "/empty"} }, want: 3},
		{name: "refuse-scratchpad-block-list-fails", build: func(w *world) { keep(w, ""); gitStub(w, "-co"); w.writeAt(w.scratch+"/a.txt", "x") }, args: withScratch(), env: stubPath, want: 2},
		{name: "refuse-manifest-outside-probes-is-fine", build: func(w *world) {
			keep(w, "")
			w.write("docs/SCRIPTS-MANIFEST.md", "| a.sh | "+sum("a")+" |\n")
			w.writeAt(w.scratch+"/a.sh", "x")
		}, args: withScratch(), want: 1},
		{name: "refuse-strings-cheap-check", build: func(w *world) { keep(w, "") }, args: func(w *world) []string {
			return []string{"--target", strings.TrimSuffix(w.repo, "/") + "/", "--tmp", w.tmp}
		}, want: 0},
	}
}
