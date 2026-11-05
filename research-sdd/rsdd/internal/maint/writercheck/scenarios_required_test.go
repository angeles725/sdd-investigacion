package writercheck

// Scenarios about the required set: which suites a change requires, the FULL escalation, no-suite, docs-only and node
// suites, and the teeth-log verdicts.

const (
	alpha = tb + "/alpha.sh"
	beta  = tb + "/beta.sh"
	gamma = tb + "/gamma.sh"
)

// logCase is one teeth-log verdict: the changed script is alpha.sh, the logs cover a.test.sh and multi.test.sh, and
// a.test.sh's log is replaced by body (bound = with the binding header).
func logCase(name, body string, bound bool, want int) scenario {
	return scenario{name, touching(alpha), func(k *kase) []string {
		d := k.logs(false, "a.test.sh", "multi.test.sh")
		k.logFile(d, "a.test.sh", bound, body, false)
		return []string{"--repo", k.dir, "--base", "base", "--teeth-log", d}
	}, nil, want}
}

func requiredScenarios() []scenario {
	return []scenario{
		{"alpha-no-logs", touching(alpha), chk(), nil, 1},
		{"alpha-valid-logs", touching(alpha), withLogs("a.test.sh", "multi.test.sh"), nil, 0},
		{"beta-single", touching(beta), chk(), nil, 1},
		{"three-scripts", touching(alpha, beta, gamma), chk(), nil, 1},
		{"changed-suite", touching(ts + "/b.test.sh"), chk(), nil, 1},
		{"missing-last", touching(alpha), withLogs("a.test.sh"), nil, 1},
		{"missing-first", touching(alpha), withLogs("multi.test.sh"), nil, 1},
		{"wrong-suite-logs", touching(alpha), withLogs("b.test.sh", "c.test.sh"), nil, 1},
		logCase("log-plain", "  PASS  x\n== 3 passed · 0 failed ==\n", true, 1),
		logCase("log-failed", "-- teeth --\n== 2 passed · 1 failed ==\n", true, 1),
		logCase("log-zero", "-- teeth --\n== 0 passed · 0 failed ==\n", true, 1),
		logCase("log-failline", "-- teeth --\n  FAIL  one\n== 3 passed · 0 failed ==\n", true, 1),
		logCase("log-empty", "", false, 1),
		logCase("log-nosummary", "-- teeth --\nsome text\n", true, 1),
		logCase("log-last-summary", "-- teeth --\n== 1 passed · 2 failed ==\n== 3 passed · 0 failed ==\n", true, 0),
		logCase("log-double-zero", "-- teeth --\n== 3 passed · 00 failed ==\n", true, 1),
		logCase("log-padded-zero", "-- teeth --\n== 00 passed · 0 failed ==\n", true, 0),
		logCase("log-trailing-blank", "-- teeth --\n== 3 passed · 0 failed ==  \t\n", true, 0),
		logCase("log-banner-eq", "== Teeth ==\n== 3 passed · 0 failed ==\n", true, 0),
		logCase("log-banner-indented", "   --   teeth rounds\n== 3 passed · 0 failed ==\n", true, 0),
		logCase("log-banner-glued", "-- teethed\n== 3 passed · 0 failed ==\n", true, 1),
		logCase("log-hand-written", "-- teeth --\n== 3 passed · 0 failed ==\n", false, 1),
		logCase("log-malformed-header", "x\n", false, 1),
		{"log-bad-header-text", touching(alpha), func(k *kase) []string {
			d := k.logs(false, "a.test.sh", "multi.test.sh")
			k.logFile(d, "a.test.sh", false, "# writer-check: head=abc tree=zzz\n-- teeth --\n== 3 passed · 0 failed ==\n", false)
			return []string{"--repo", k.dir, "--base", "base", "--teeth-log", d}
		}, nil, 1},
		{"stale-after-commit", touching(alpha), func(k *kase) []string {
			d := k.logs(false, "a.test.sh", "multi.test.sh")
			k.add(alpha, "echo changed-after-the-log\n")
			k.commit("later")
			return []string{"--repo", k.dir, "--base", "base", "--teeth-log", d}
		}, nil, 1},
		{"full-newfile", func(k *kase) {
			k.write(tb+"/fresh.sh", "echo n\n")
			k.add(ts+"/c.test.sh", "\"$TB/fresh.sh\"\n")
			k.commit("new")
		}, chk(), nil, 1},
		{"full-newfile-logs", func(k *kase) {
			k.write(tb+"/fresh.sh", "echo n\n")
			k.add(ts+"/c.test.sh", "\"$TB/fresh.sh\"\n")
			k.commit("new")
		}, withLogs("c.test.sh"), nil, 0},
		{"closure-leaf", touching(tb + "/leaf.sh"), chk(), nil, 1},
		{"full-direct", func(k *kase) {
			k.add(tb+"/mid.sh", "# c\n")
			k.write(tb+"/fresh9.sh", "echo n\n")
			k.add(ts+"/c.test.sh", "\"$TB/fresh9.sh\"\n")
			k.commit("c")
		}, chk(), nil, 1},
		{"full-fallback-map", func(k *kase) {
			k.add(tb+"/leaf.sh", "# c\n")
			k.write(tb+"/fresh8.sh", "echo n\n")
			k.add(ts+"/c.test.sh", "\"$TB/fresh8.sh\"\n")
			k.commit("c")
		}, chk(), nil, 1},
		{"no-suite-solo", touching(tb + "/solo.sh"), chk(), nil, 1},
		{"no-suite-lib", touching(tb + "/lib/gl.sh"), chk(), nil, 1},
		{"harness-only", touching(ts + "/impact-always.txt"), chk(), nil, 0},
		{"docs-only", touching(tb + "/notes.md"), chk(), nil, 0},
		{"node-suite", touching(tb + "/adv.mjs"), chk(), nil, 0},
		{"no-change", nothing, chk(), nil, 0},
		{"rename", func(k *kase) { k.git("mv", beta, tb+"/beta2.sh"); k.commit("rename") }, chk(), nil, 1},
		{"deleted-script", func(k *kase) { k.git("rm", "-q", gamma); k.commit("rm") }, chk(), nil, 0},
		{"head-ref", touching(alpha), chk("--head", "HEAD"), nil, 1},
		{"head-ref-earlier", touching(alpha), func(k *kase) []string {
			k.add(beta, "# later\n")
			k.commit("later")
			return []string{"--repo", k.dir, "--base", "base", "--head", "HEAD~1"}
		}, nil, 1},
		{"manifest-dir", touching(alpha), func(k *kase) []string {
			return []string{"--repo", k.dir, "--base", "base", "--manifest-dir", k.dir + "/" + ts, "--tolerate-stale-manifest"}
		}, nil, 1},
		{"install-suite-changed", touching("research-sdd/install/tests/a.test.sh"), chk(), nil, 1},
		{"fixture-suite-not-required", touching(ts + "/fixtures/zz.test.sh"), chk(), nil, 0},
		{"waived-suite", touching(tb + "/top.sh"), chk(), nil, 0},
		{"waiver-scope", func(k *kase) { k.touch(tb+"/top.sh", alpha) }, chk(), nil, 1},
		{"waiver-no-reason", func(k *kase) {
			k.add(ts+"/writer-check-waivers.txt", "research-sdd/toolbelt/tests/t.test.sh\n")
			k.add(tb+"/top.sh", "# c\n")
			k.commit("c")
		}, chk(), nil, 1},
		{"waiver-file-absent", func(k *kase) {
			k.git("rm", "-q", ts+"/writer-check-waivers.txt")
			k.commit("nowaivers")
			k.touch(tb + "/top.sh")
		}, chk(), nil, 1},
		{"waiver-tab-free-comments", func(k *kase) {
			k.write(ts+"/writer-check-waivers.txt", "# only comments\n\n  # indented comment\nresearch-sdd/toolbelt/tests/t.test.sh why not\nresearch-sdd/toolbelt/tests/t.test.sh second wins never\n")
			k.commit("w")
			k.touch(tb + "/top.sh")
		}, chk(), nil, 0},
	}
}
