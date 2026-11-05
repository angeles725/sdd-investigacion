package flakehunt

// scenario is one case of the differential test: the same world is built twice, the frozen legacy script runs in one
// and the Go command in the other, and everything observable must agree (golden_test.go replays the legacy answers).
type scenario struct {
	name  string
	setup func(w *world)
	args  []string // after the standard prefix `--repo @R@ --out @O@`
	raw   bool     // no standard prefix
	env   []string // extra environment (placeholders expanded)
	cwd   string   // "R": run inside the repository
	want  int      // the exit code both sides must give

	// diverges marks a declared divergence (tool-registry.d/kit-flake-hunt.md): only the exit code is compared with the
	// legacy script, and a Go test pins what the Go command prints instead.
	diverges bool
}

func scenarios() []scenario {
	var all []scenario
	for _, g := range [][]scenario{huntScenarios(), loadScenarios(), usageScenarios(), outScenarios(), selectionScenarios(), issueScenarios(), issueEdgeScenarios()} {
		all = append(all, g...)
	}
	return all
}

func std(w *world) { w.standard() }

// huntScenarios: classification, the results file, timeouts, skips, summaries and list edges.
func huntScenarios() []scenario {
	zero := sl("--load", "0")
	return []scenario{
		{name: "classify", setup: std, want: 1, args: cat(sl("--runs", "4"), zero, suiteArgs("stable", "flaky", "broken", "skip"))},
		{name: "clean", setup: std, want: 0, args: cat(sl("--runs", "2"), zero, suiteArgs("stable", "skip"))},
		{name: "broken-only", setup: std, want: 1, args: cat(sl("--runs", "3"), zero, suiteArgs("broken"))},
		{name: "timeout", want: 1, setup: func(w *world) { w.suite("slow.test.sh", "exec sleep 9.211") },
			args: cat(sl("--runs", "2", "--suite-timeout", "1"), zero, suiteArgs("slow"))},
		{name: "skip-mixed", want: 0, setup: func(w *world) {
			w.standard()
			w.suite("mixed.test.sh", `if [ "$FLAKE_HUNT_RUN" = 1 ]; then echo 'SKIP: first'; else echo '== 1 passed · 0 failed =='; fi; exit 0`)
		}, args: cat(sl("--runs", "2"), zero, suiteArgs("mixed", "skip"))},
		{name: "prove-off", want: 0, setup: func(w *world) { w.suite("args.test.sh", argsBody) },
			args: cat(sl("--runs", "1"), zero, suiteArgs("args"))},
		{name: "prove-on", want: 0, setup: func(w *world) { w.suite("args.test.sh", argsBody) },
			args: cat(sl("--runs", "1", "--prove-teeth"), zero, suiteArgs("args"))},
		{name: "summary-variants", want: 1, setup: func(w *world) {
			w.suite("nosum.test.sh", `echo '  PASS  a'; exit 0`)
			w.suite("failsum.test.sh", `echo '== 3 passed · 1 failed =='; exit 0`)
			w.suite("malformed.test.sh", `echo '== 3 passed · x failed =='; exit 0`)
			w.suite("zero.test.sh", `echo '== 0 passed · 0 failed =='; exit 0`)
			w.suite("good.test.sh", `echo '== 3 passed · 0 failed =='; exit 0`)
			w.suite("padded.test.sh", `echo '== 3 passed · 007 failed =='; exit 0`)
			w.suite("lastwins.test.sh", `echo '== 3 passed · 1 failed =='; echo '== 2 passed · 0 failed =='; exit 0`)
			w.suite("bigzero.test.sh", `echo '== 0007 passed · 000 failed =='; exit 0`)
		}, args: cat(sl("--runs", "2"), zero, suiteArgs("nosum", "failsum", "malformed", "zero", "good", "padded", "lastwins", "bigzero"))},
		{name: "nothing-measured", setup: std, want: 2, args: cat(sl("--runs", "2"), zero, suiteArgs("skip"))},
		{name: "list-file-edges", want: 1, setup: func(w *world) {
			w.standard()
			w.file("list", "# header\n\n  s/stable.test.sh  # trailing\ns/skip.test.sh\r\n\ts/flaky.test.sh")
		}, args: cat(sl("--runs", "2"), zero, sl("--suites", "@W@/list"))},
		{name: "order-first", setup: std, want: 1, args: cat(sl("--runs", "2"), zero, suiteArgs("flaky", "stable", "skip"))},
		{name: "order-middle", setup: std, want: 1, args: cat(sl("--runs", "2"), zero, suiteArgs("stable", "flaky", "skip"))},
		{name: "order-last", setup: std, want: 1, args: cat(sl("--runs", "2"), zero, suiteArgs("stable", "skip", "flaky"))},
		{name: "single-suite", setup: std, want: 1, args: cat(sl("--runs", "2"), zero, suiteArgs("flaky"))},
		{name: "runs-one", setup: std, want: 1, args: cat(sl("--runs", "1"), zero, suiteArgs("flaky"))},
		{name: "duplicate-suite", setup: std, want: 1, args: cat(sl("--runs", "2"), zero, suiteArgs("flaky", "flaky"))},
		{name: "absolute-suite", want: 0, setup: func(w *world) { w.standard() },
			args: cat(sl("--runs", "1"), zero, sl("--suite", "@R@/s/stable.test.sh"))},
		{name: "node-suite", want: 0, setup: func(w *world) {
			w.standard()
			w.stubNode()
			w.suite("m.test.mjs", `if [ "$#" -gt 1 ]; then echo "  FAIL  got args $*"; exit 1; fi; echo '== 1 passed · 0 failed =='`)
		}, args: cat(sl("--runs", "2", "--prove-teeth"), zero, suiteArgs("stable"), sl("--suite", "s/m.test.mjs"))},
		{name: "tmpdir", want: 0, setup: func(w *world) {
			body := `echo "tmp=$TMPDIR run=$FLAKE_HUNT_RUN suite=$FLAKE_HUNT_SUITE out=$FLAKE_HUNT_OUT"; [ -d "$TMPDIR" ] || exit 1; touch "$TMPDIR/junk"; echo '== 1 passed · 0 failed =='`
			w.suite("t1.test.sh", body)
			w.suite("t2.test.sh", body)
		}, args: cat(sl("--runs", "2"), zero, suiteArgs("t1", "t2"))},
		{name: "tokens", want: 1, setup: func(w *world) {
			w.stubGH()
			w.suite("tok.test.sh", `echo "gh=${GH_TOKEN-unset} gt=${GITHUB_TOKEN-unset}"; echo '  FAIL x'; exit 1`)
		}, env: sl("GH_TOKEN=secret-gh", "GITHUB_TOKEN=secret-gt"), args: cat(sl("--runs", "2", "--file-issues=apply"), zero, suiteArgs("tok"))},
	}
}

// loadScenarios: the busy-loop workers (a tiny count; the suites only look, they burn nothing).
func loadScenarios() []scenario {
	return []scenario{
		{name: "load-default-timeout", want: 0, setup: func(w *world) {
			w.suite("dflt.test.sh", `n=0; for _ in $(seq 1 30); do n=$({ for f in /proc/[0-9]*/cmdline; do tr '\0' ' ' <"$f"; echo; done; } 2>/dev/null | grep -c '^timeout 314 bash -c .*kit-flake-hunt-load:'); [ "$n" -ge 1 ] && break; sleep 0.1; done; echo "workers=$n"; echo '== 1 passed · 0 failed =='`)
		}, args: sl("--runs", "2", "--load", "1", "--suite-timeout", "7", "--suite", "s/dflt.test.sh")},
		{name: "load-expiry", want: 2, setup: func(w *world) {
			w.standard()
			w.suite("first.test.sh", `echo '== 1 passed · 0 failed =='; sleep 2; exit 0`)
		}, args: sl("--runs", "1", "--load", "1", "--load-timeout", "1", "--suite", "s/first.test.sh", "--suite", "s/stable.test.sh")},
		{name: "load-long-timeout", want: 0, setup: func(w *world) {
			w.standard()
			w.suite("first.test.sh", `echo '== 1 passed · 0 failed =='; sleep 0.3; exit 0`)
		}, args: sl("--runs", "1", "--load", "1", "--load-timeout", "30", "--suite", "s/first.test.sh", "--suite", "s/stable.test.sh")},
		{name: "load-zero-never-expires", want: 0, setup: func(w *world) {
			w.standard()
			w.suite("first.test.sh", `echo '== 1 passed · 0 failed =='; sleep 1.2; exit 0`)
		}, args: sl("--runs", "1", "--load", "0", "--load-timeout", "1", "--suite", "s/first.test.sh", "--suite", "s/stable.test.sh")},
	}
}
