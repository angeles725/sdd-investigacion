package writercheck

import (
	"os"
	"path/filepath"
)

// Scenarios about the modes: --worktree, --format json, --print-binding, --write-teeth-log, --classify, and the
// degraded and usage states.

func modeScenarios() []scenario {
	a, m := ts+"/a.test.sh", ts+"/multi.test.sh"
	wl := func(name string, suites ...string) func(*kase) []string {
		return func(k *kase) []string {
			return append([]string{"--repo", k.dir, "--write-teeth-log", k.root + "/" + name, "--base", "base"}, suites...)
		}
	}
	return []scenario{
		{"worktree-edit", func(k *kase) { k.add(alpha, "# w\n") }, chk("--worktree"), nil, 1},
		{"worktree-staged-new", func(k *kase) { k.write(tb+"/fresh.sh", "echo n\n"); k.git("add", "-A") }, chk("--worktree"), nil, 1},
		{"worktree-clean", nothing, chk("--worktree"), nil, 0},
		{"worktree-and-head", nothing, chk("--worktree", "--head", "HEAD"), nil, 2},
		{"worktree-stale-logs", func(k *kase) { k.touch(alpha) }, func(k *kase) []string {
			d := k.logs(false, "a.test.sh", "multi.test.sh")
			k.add(alpha, "echo uncommitted-edit\n")
			return []string{"--repo", k.dir, "--base", "base", "--worktree", "--teeth-log", d}
		}, nil, 1},
		{"worktree-fresh-logs", func(k *kase) { k.add(alpha, "# w\n") }, func(k *kase) []string {
			return []string{"--repo", k.dir, "--base", "base", "--worktree", "--teeth-log", k.logs(true, "a.test.sh", "multi.test.sh")}
		}, nil, 0},
		{"worktree-waiver-edit", func(k *kase) {
			k.write(ts+"/writer-check-waivers.txt", "research-sdd/toolbelt/tests/a.test.sh edited in the working tree\n")
			k.add(alpha, "# w\n")
		}, chk("--worktree"), nil, 1},
		{"json-findings", touching(alpha), chk("--format", "json"), nil, 1},
		{"json-ok", touching(alpha), func(k *kase) []string {
			return []string{"--repo", k.dir, "--base", "base", "--format", "json", "--teeth-log", k.logs(false, "a.test.sh", "multi.test.sh")}
		}, nil, 0},
		{"json-escapes", func(k *kase) {
			k.add(ts+"/writer-check-waivers.txt", "research-sdd/toolbelt/tests/q\"x.test.sh quote\\back\n")
			k.add(alpha, "pkill a\n")
			k.commit("c")
		}, chk("--format", "json"), nil, 1},
		{"json-full-gate", touching(ts + "/impact-always.txt"), chk("--format", "json"), nil, 0},
		{"print-binding", touching(alpha), chk("--print-binding"), nil, 0},
		{"print-binding-worktree", func(k *kase) { k.add(alpha, "# w\n"); k.write(tb+"/u.sh", "echo u\n") }, chk("--print-binding", "--worktree"), nil, 0},
		{"print-binding-rename-delete", func(k *kase) {
			k.git("mv", beta, tb+"/beta2.sh")
			k.git("rm", "-q", gamma)
			k.commit("rm")
		}, chk("--print-binding"), nil, 0},
		{"print-binding-other-contents", touching(beta), chk("--print-binding"), nil, 0},
		{"print-binding-empty", nothing, chk("--print-binding"), nil, 0},
		{"write-logs", nothing, wl("wl", a, m), nil, 0},
		{"write-logs-failing-suite", func(k *kase) {
			k.write(ts+"/red.test.sh", "#!/usr/bin/env bash\necho \"-- teeth --\"; echo \"  FAIL  boom\"; echo \"== 1 passed · 1 failed ==\"; exit 1\n")
		}, wl("wl3", ts+"/red.test.sh"), nil, 1},
		{"write-logs-timeout", func(k *kase) { k.write(ts+"/slow.test.sh", "#!/usr/bin/env bash\nsleep 5\n") },
			wl("wl4", ts+"/slow.test.sh"), []string{"KIT_WRITER_CHECK_TIMEOUT=1"}, 1},
		{"write-logs-bad-timeout", nothing, wl("wl5", a), []string{"KIT_WRITER_CHECK_TIMEOUT=abc"}, 2},
		{"write-logs-zero-timeout", nothing, wl("wl5", a), []string{"KIT_WRITER_CHECK_TIMEOUT=0"}, 2},
		{"write-logs-leading-zero-timeout", nothing, wl("wl5", a), []string{"KIT_WRITER_CHECK_TIMEOUT=08"}, 2},
		{"write-logs-empty-timeout", nothing, wl("wl5", a), []string{"KIT_WRITER_CHECK_TIMEOUT="}, 0},
		{"write-logs-missing-suite", nothing, wl("wl6", ts+"/nope.test.sh"), nil, 1},
		{"write-logs-node-suite", nothing, wl("wl7", ts+"/pi.test.mjs"), nil, 1},
		{"write-logs-no-suites", nothing, wl("wl8"), nil, 2},
		{"write-logs-no-base", nothing, func(k *kase) []string { return []string{"--repo", k.dir, "--write-teeth-log", k.root + "/wl9", a} }, nil, 2},
		{"write-logs-two-corpora", nothing, wl("two", a, "research-sdd/install/tests/a.test.sh"), nil, 0},
		{"write-logs-absolute", nothing, func(k *kase) []string {
			return []string{"--repo", k.dir, "--write-teeth-log", k.root + "/abs", "--base", "base", k.dir + "/" + a}
		}, nil, 0},
		{"write-logs-bad-base", nothing, func(k *kase) []string {
			return []string{"--repo", k.dir, "--write-teeth-log", k.root + "/wl", "--base", "nosuchref", a}
		}, nil, 2},
		{"write-logs-then-check", touching(alpha), func(k *kase) []string {
			d := k.root + "/wlc"
			r := k.goRunWrite(d, a, m)
			if r != 0 {
				k.t.Fatalf("writing the logs failed: %d", r)
			}
			return []string{"--repo", k.dir, "--base", "base", "--teeth-log", d}
		}, nil, 0},
		{"write-logs-nested-dir", nothing, wl("deep/er/logs", a), nil, 0},
		{"degraded-bad-base", nothing, func(k *kase) []string { return []string{"--repo", k.dir, "--base", "nosuchref"} }, nil, 2},
		{"degraded-bad-head", nothing, chk("--head", "nosuchref"), nil, 2},
		{"degraded-not-a-repo", nothing, func(k *kase) []string { return []string{"--repo", k.root, "--base", "base"} }, nil, 2},
		{"degraded-missing-logdir", nothing, chk("--teeth-log", "/nonexistent-dir-for-wck"), nil, 2},
		{"degraded-impact-absent", nothing, chk(), []string{"KIT_WRITER_CHECK_IMPACT=/nonexistent/suite-impact.sh"}, 2},
		{"degraded-impact-fails", nothing, func(k *kase) []string {
			if err := os.WriteFile(k.root+"/bad.sh", []byte("#!/usr/bin/env bash\necho boom >&2\nexit 2\n"), 0o755); err != nil {
				k.t.Fatal(err)
			}
			return []string{"--repo", k.dir, "--base", "base"}
		}, []string{"KIT_WRITER_CHECK_IMPACT=@ROOT@/bad.sh"}, 2},
		{"usage-no-base", nothing, func(k *kase) []string { return []string{"--repo", k.dir} }, nil, 2},
		{"usage-bad-format", nothing, chk("--format", "xml"), nil, 2},
		{"usage-unknown-flag", nothing, chk("--bogus"), nil, 2},
		{"usage-stray-positional", nothing, chk("stray"), nil, 2},
		{"usage-help", nothing, func(*kase) []string { return []string{"--help"} }, nil, 2},
		{"usage-h", nothing, func(*kase) []string { return []string{"-h"} }, nil, 2},
		{"usage-base-without-value", nothing, func(*kase) []string { return []string{"--base"} }, nil, 2},
		{"usage-classify-empty", nothing, func(*kase) []string { return []string{"--classify"} }, nil, 2},
		{"usage-no-args", nothing, func(*kase) []string { return nil }, nil, 2},
		{"bad-format-wins-over-base", nothing, func(k *kase) []string { return []string{"--format", "xml"} }, nil, 2},
		{"classify-all", nothing, func(*kase) []string { return classifyPaths() }, nil, 0},
		{"classify-format-ignored", nothing, func(*kase) []string { return []string{"--format", "xml", "--classify", tb + "/x.sh"} }, nil, 0},
		{"relative-repo-arg", touching(alpha), func(k *kase) []string {
			rel, err := filepath.Rel(k.root, k.dir)
			if err != nil {
				k.t.Fatal(err)
			}
			return []string{"--repo", rel, "--base", "base"}
		}, nil, 1},
		{"subdirectory-repo-arg", touching(alpha), func(k *kase) []string { return []string{"--repo", k.dir + "/" + tb, "--base", "base"} }, nil, 1},
	}
}
