package writercheck

import "os"

// Scenarios about the name-kill scan over ADDED lines. Fixture text only; nothing here is executed.

type nkCase struct {
	name, file, content string
	want                int // 1: a finding (a changed script always misses its teeth logs too), 1 with a name-kill line or without
}

func nkCases() []nkCase {
	return []nkCase{
		{"pkill", alpha, "echo start\npkill -f myloop", 1},
		{"killall", alpha, "killall python3", 1},
		{"kill-9-1", alpha, "kill -9 -1", 1},
		{"kill-1", alpha, "kill -1", 1},
		{"kill-dashdash-1", alpha, "kill -- -1", 1},
		{"kill-term-1", alpha, "kill -TERM -1", 1},
		{"kill-s-1", alpha, "kill -s KILL -1", 1},
		{"kill-pid-ok", alpha, "kill 1234", 1},
		{"kill-9-pid-ok", alpha, "kill -9 4321", 1},
		{"kill-minus-12-ok", alpha, "kill -12", 1},
		{"pgrep-xargs", alpha, "pgrep -f loop | xargs kill", 1},
		{"pidof-xargs-kill9", alpha, "pidof loop | xargs kill -9", 1},
		{"pidof-xargs-r", alpha, "pidof loop | xargs -r kill", 1},
		{"pgrep-while", alpha, "pgrep -f loop | while read p; do kill $p; done", 1},
		{"kill-subst", alpha, "kill $(pgrep -f loop)", 1},
		{"kill-subst-pidof", alpha, "kill $(pidof loop)", 1},
		{"kill-backtick", alpha, "kill `pidof loop`", 1},
		{"allow-comment", alpha, "pkill -f x  # writer-check: allow-name-kill reaper owns this host", 1},
		{"allow-comment-tight", alpha, "pkill -f x # writer-check:allow-name-kill because", 1},
		{"comment-line", alpha, "# cleanup; pkill -f loop", 1},
		{"indented-comment-line", alpha, "   # pkill -f loop", 1},
		{"markdown", tb + "/notes.md", "pkill -f anything", 0},
		{"text-file", tb + "/notes.txt", "pkill -f anything", 0},
		{"bash-ext", tb + "/x.bash", "pkill -f anything", 1},
		{"guard-token", alpha, "source hook-pretool-pkill-guard.sh", 1},
		{"similar-words", alpha, "echo skill killing-time pkillx", 1},
		{"in-test-file", ts + "/a.test.sh", "pkill -f loop", 1},
		{"after-and", alpha, "make && pkill -f x", 1},
		{"after-sudo", alpha, "sudo -n killall python3", 1},
		{"abs-path", alpha, "FOO=1 /usr/bin/pkill -9 loop", 1},
		{"after-timeout", alpha, "timeout 5 pkill -f loop", 1},
		{"in-subst", alpha, "x=$(pkill -f loop)", 1},
		{"bash-c", alpha, "bash -c 'pkill -f foo'", 1},
		{"if-then", alpha, "if pkill -f foo; then :; fi", 1},
		{"exec-prefix", alpha, "exec pkill foo", 1},
		{"xargs-killall", alpha, "ls | xargs killall", 1},
		{"pipe-after", alpha, "echo x | pkill -f y", 1},
		{"grep-pattern", alpha, "grep -Eq 'pkill|pgrep' file", 1},
		{"echo-prose", alpha, "echo \"never use pkill -f on loops\"", 1},
		{"json-fixture", alpha, "STDIN='{\"tool_input\":{\"command\":\"pkill -f foo\"}}'", 1},
		{"identifier", alpha, "case_pkill_closed() { :; }", 1},
		{"py-argv", tb + "/helper.py", "cmd = [\"pkill\", \"-f\", \"x\"]", 1},
		{"py-argv-killall", tb + "/helper.py", "subprocess.run(['killall', 'x'])", 1},
		{"py-system", tb + "/helper.py", "import os; os.system('pkill -f x')", 1},
		{"py-comment", tb + "/helper.py", "# pkill -f x", 1},
		{"js-spawn", tb + "/helper.js", "spawnSync('pkill', ['-f', 'x'])", 1},
		{"js-exec", tb + "/helper.js", "execSync('pkill -f x')", 1},
		{"js-slashes-comment", tb + "/helper.js", "// pkill -f x", 1},
		{"ts-call", tb + "/helper.ts", "run(\"pkill -f x\")", 1},
		{"mjs-argv", tb + "/helper.mjs", "const a = ['killall'];", 1},
		{"sh-argv-form-not-a-kill", alpha, "x=['pkill']", 1},
		{"two-lines", alpha, "pkill a\nkillall b", 1},
		{"pipe-into-sh-ok", alpha, "echo pkill | cat", 1},
		{"dollar-paren-prose", alpha, "echo $(date) pkillx", 1},
		{"killall-dot-suffix", alpha, "killall.sh --all", 1},
	}
}

func nameKillScenarios() []scenario {
	var out []scenario
	for _, c := range nkCases() {
		out = append(out, scenario{"nk-" + c.name, func(k *kase) { k.add(c.file, c.content+"\n"); k.commit("c") }, chk(), nil, c.want})
	}
	out = append(out, scenario{"nk-pre-existing", touching(tb + "/old.sh"), chk(), nil, 1})
	out = append(out, scenario{"nk-later-hunk", func(k *kase) {
		k.write(tb+"/hk.sh", "x1\nx2\nx3\nx4\nx5\nx6\nx7\nx8\nx9\nx10\n")
		k.commit("hk")
		k.git("tag", "base2")
		k.write(tb+"/hk.sh", "x1\nx2\nx3\nx4\nx5\nx6\nx7\nx8\npkill -x y\nx10\n")
		k.commit("hk2")
	}, func(k *kase) []string { return []string{"--repo", k.dir, "--base", "base2"} }, nil, 1})
	out = append(out, scenario{"nk-corpus", func(k *kase) {
		k.write(tb+"/corpus.sh", corpusText())
		k.commit("corpus")
	}, chk(), nil, 1})
	out = append(out, scenario{"nk-worktree-untracked", func(k *kase) {
		k.add(alpha, "# w\n")
		k.write(tb+"/untracked.sh", "pkill -f stray\n")
		k.write(tb+"/untracked.txt", "pkill -f stray\n")
		k.write(tb+"/untracked.py", "ok = 1\nos.system('killall x')\n")
	}, chk("--worktree"), nil, 1})
	out = append(out, scenario{"nk-worktree-tracked-edit", func(k *kase) {
		k.add(alpha, "pkill -f edit\n")
	}, chk("--worktree"), nil, 1})
	out = append(out, scenario{"nk-untracked-dir-symlink", func(k *kase) {
		if err := os.Symlink(".", k.dir+"/"+tb+"/linkdir"); err != nil {
			k.t.Fatal(err)
		}
		k.write(tb+"/ok.sh", "pkill z\n")
	}, chk("--worktree"), nil, 1})
	return out
}
