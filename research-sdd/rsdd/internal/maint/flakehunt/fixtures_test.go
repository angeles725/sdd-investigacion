package flakehunt

// The fake suites of the scenarios (bodies of bash scripts). None of them burns CPU.
const (
	bodyStable = `printf '== s ==\n  PASS  a\n== 1 passed · 0 failed ==\n'; exit 0`
	bodyFlaky  = `if [ $((FLAKE_HUNT_RUN % 2)) -eq 1 ]; then echo '  FAIL  odd run broke'; exit 1; fi; echo '  PASS  ok'; echo '== 1 passed · 0 failed =='`
	bodyBroken = `echo '  FAIL  always'; exit 1`
	bodySkip   = `echo 'SKIP: tool absent'; exit 0`
	argsBody   = `echo "args=[$*]"; echo '== 1 passed · 0 failed =='; exit 0`
)

// standard writes the four suites most scenarios hunt.
func (w *world) standard() {
	w.suite("stable.test.sh", bodyStable)
	w.suite("flaky.test.sh", bodyFlaky)
	w.suite("broken.test.sh", bodyBroken)
	w.suite("skip.test.sh", bodySkip)
}

// suiteArgs is `--suite s/<name>.test.sh` for each name.
func suiteArgs(names ...string) []string {
	var a []string
	for _, n := range names {
		a = append(a, "--suite", "s/"+n+".test.sh")
	}
	return a
}

func cat(parts ...[]string) []string {
	var out []string
	for _, p := range parts {
		out = append(out, p...)
	}
	return out
}

func sl(a ...string) []string { return a }
